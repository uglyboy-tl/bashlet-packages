#!/usr/bin/env bats

# lib/fetch.sh：URL → 源 的路由框架。框架不含站点知识——路由表由各源的
# source.url.register（或 <源>.url.hosts 动态清单）声明，所以这里全部用桩源测。

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "fetch.host: 去掉 scheme / userinfo / 端口，host 转小写" {
	run fetch.host "https://www.example.com/a/b?c=1"
	assert_output "www.example.com"

	run fetch.host "http://user:pw@Example.COM:8080/x"
	assert_output "example.com"

	run fetch.host "example.com/path"
	assert_output "example.com"

	# 没有路径时 ?/# 紧跟在 host 后面，不能污染 host
	run fetch.host "https://reddit.com?x=1"
	assert_output "reddit.com"

	run fetch.host "https://news.ycombinator.com#x"
	assert_output "news.ycombinator.com"
}

@test "fetch.host.any: 命中子域，但不把 example.com.evil.com 当子域" {
	run fetch.host.any "https://old.reddit.com/r/x" reddit.com
	assert_success

	run fetch.host.any "https://reddit.com/r/x" reddit.com
	assert_success

	run fetch.host.any "https://example.com.evil.com/" example.com
	assert_failure

	run fetch.host.any "https://notreddit.com/" reddit.com
	assert_failure
}

@test "fetch.route: 按注册的 host 表路由（含子域），认不出返回 1" {
	source.url.register stub stub.test
	source.register stub "桩源" "tier:niche period:no proxy:no key:none" ""

	run fetch.route "https://stub.test/x"
	assert_success
	assert_output $'stub\t-u\thttps://stub.test/x'

	run fetch.route "https://www.stub.test/x"
	assert_success

	run fetch.route "https://unknown.test/x"
	assert_failure
}

@test "fetch.route: <源>.url.hosts 动态清单优先于静态注册（discourse 的多实例形态）" {
	stub.url.hosts() { printf 'a.test\nb.test\n'; }
	source.register stub "桩源" "tier:niche period:no proxy:no key:none" ""

	run fetch.route "https://b.test/t/1"
	assert_success
	assert_output $'stub\t-u\thttps://b.test/t/1'

	run fetch.route "https://c.test/t/1"
	assert_failure
}

@test "dig fetch: 认不出的 URL 报错，并给出替代做法" {
	run main fetch "https://unknown.test/x"
	assert_failure
	assert_output --partial "认不出这个 URL"
	assert_output --partial "dig <源>"
}

@test "dig fetch: URL 之后的实参原样转给源的解析器（--no-cache 不再被外层拒掉）" {
	source.url.register stub stub.test
	stub.search_url() {
		printf '{"source":"stub","title":"nc=%s","url":"","text":"","author":"","created_at":"","engagement":{},"tags":[],"query":""}\n' "${DIG_NO_CACHE:-0}"
	}
	source.register stub "桩源" "tier:niche period:no proxy:no key:none" ""

	run main fetch "https://stub.test/x" --no-cache
	assert_success
	assert_output --partial "nc=1"
}

@test "dig fetch: 不给 URL 时报错而不是静默成功" {
	run main fetch
	assert_failure
	assert_output --partial "需要 URL"
}

# ========== 路由表（接线清单；加一个源的 URL 覆盖时同步这里）==========

@test "fetch.route: 每个接线源的 URL 都归到正确的源" {
	local -A cases=(
		[hn]="https://news.ycombinator.com/item?id=12345"
		[github]="https://github.com/torvalds/linux/issues/42"
		[so]="https://stackoverflow.com/questions/12345/how-to"
		[arxiv]="https://arxiv.org/abs/2103.00112v1"
		[openalex]="https://openalex.org/W12345"
		[reddit]="https://www.reddit.com/r/linux/comments/abc123/title/"
		[bilibili]="https://www.bilibili.com/video/BV1xx411c7mD"
		[discourse]="https://discuss.python.org/t/some-slug/12345"
		[hf]="https://huggingface.co/BAAI/bge-m3"
		[polymarket]="https://polymarket.com/event/some-slug"
		[wechat]="https://mp.weixin.qq.com/s/AWnQL3forAP-gB7e2ZEXdQ"
		[v2ex]="https://www.v2ex.com/t/1000000"
	)
	local src url
	for src in "${!cases[@]}"; do
		url="${cases[$src]}"
		run fetch.route "$url"
		assert_success
		[[ $output == "$src"$'\t'* ]] || {
			echo "$url 归到了「$output」，期望 $src"
			return 1
		}
	done
}

@test "fetch.route: 不相干 URL 认不出来（含别的站、短链、未接线的源）" {
	local url
	for url in \
		"https://example.com/" \
		"https://notreddit.com/" \
		"https://b23.tv/abc" \
		"https://unix.stackexchange.com/questions/1/x" \
		"https://example.org/"; do
		run fetch.route "$url"
		assert_failure
	done
}

@test "fetch: 有 search_url 的源由框架给出 -u/--url（源不必自己注册）" {
	stub.search_url() {
		printf '{"source":"stub","title":"来自 search_url","url":"%s","text":"","author":"","created_at":"","engagement":{},"tags":[],"query":""}\n' "$1"
	}
	stub.search() { echo "不该走到 search"; }
	source.url.register stub stub.test
	source.register stub "桩源" "tier:niche period:no proxy:no key:none" ""

	run main stub -u "https://stub.test/x"
	assert_success
	assert_output --partial "来自 search_url"
	refute_output --partial "不该走到"
}

# 原来是 lib/source.sh 里的 source.url.has，只供本文件使用，已移入测试
url_has() { [[ -n ${_SOURCE_URL_HOSTS[$1]:-} ]] || declare -F "$1.url.hosts" > /dev/null 2>&1; }

@test "fetch: 声明了 URL 覆盖的源都实现了 search_url（否则 -u 会打到不存在的函数）" {
	local src
	for src in $(source.list); do
		url_has "$src" || continue
		declare -F "$src.search_url" > /dev/null 2>&1 || {
			echo "$src 声明了 host 却没有 search_url"
			return 1
		}
	done
}

@test "fetch: 路由表里的源集合与已接线清单一致" {
	local -a wired=(hn github so arxiv openalex reddit bilibili discourse hf polymarket wechat v2ex)
	local -A want=()
	local src
	for src in "${wired[@]}"; do
		want[$src]=1
		url_has "$src" || {
			echo "$src 在接线清单里，但没有声明 host"
			return 1
		}
	done

	local -a got=()
	mapfile -t got < <(
		for src in $(source.list); do
			url_has "$src" && printf '%s\n' "$src"
		done
	)
	for src in "${got[@]}"; do
		[[ -n ${want[$src]:-} ]] || {
			echo "$src 声明了 host 却不在测试清单里（加了覆盖要同步测试）"
			return 1
		}
	done
}

@test "fetch.fallback: 默认关（dig fetch 认不出就报错，不偷偷用云端浏览器）" {
	source.url.register faxtest faxtest.invalid
	source.register faxtest "桩源" "tier:niche period:no proxy:no key:none" ""
	run fetch.fallback.enabled
	assert_failure
}

@test "fetch.fallback: 开了开关才用云端浏览器取一页，且过缓存" {
	browser.page() {
		printf '%s' '{"title":"某页","author":"某人","description":"","text":"正文"}'
	}
	run fetch.fallback.item "https://unknown.invalid/x"
	assert_success
	assert_jq '[.source, .title, .author, .text]'
	assert_output '["browser","某页","某人","正文"]'

	DIG_FETCH_FALLBACK=1 run fetch.fallback.enabled
	assert_success
	DIG_FETCH_FALLBACK=0 run fetch.fallback.enabled
	assert_failure
}
