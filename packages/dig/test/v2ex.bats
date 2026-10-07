#!/usr/bin/env bats

# lib/sources/v2ex.sh：搜索走 sov2ex（离线测映射），按 URL 取主题走云端浏览器（桩掉 browser.page）。

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "v2ex.map_search: 北京时间字符串按 UTC-8 归一" {
	run v2ex.map_search <<< '{"hits":[{"_source":{"id":1,"title":"t","content":"c","member":"m","created":"2017-05-04T09:38:57","replies":3}}]}'
	assert_success
	assert_jq '[.source, .id, .author, .created_at, .engagement.replies]'
	assert_output '["v2ex","1","m","2017-05-04T01:38:57Z",3]'
}

@test "v2ex.url.id: /t/<id> 取 id，认不出返回 1" {
	run v2ex.url.id "https://www.v2ex.com/t/1000000"
	assert_success
	assert_output "1000000"

	run v2ex.url.id "https://www.v2ex.com/"
	assert_failure
}

@test "v2ex.map_topic: 裁掉导航/广告与页脚，标题/楼主/回复数都从正文取" {
	run v2ex.map_topic "1000000" <<< '{
	  "title": "程序员如何从公司上班转型 - V2EX",
	  "author": "",
	  "description": "",
	  "text": "[way to explore](/)\n\n[Sign In](https://edge.v2ex.com/signin)\n\n[赞助商](https://www.v2ex.com/member/sponsor)\n\n# 程序员如何从公司上班转型\n\n  [toubi](https://www.v2ex.com/member/toubi) · Dec 13, 2023\n\n正文\n\n903 replies\n\nVERSION: 3.9.8.5 · 174ms\n"
	}'
	assert_success
	assert_jq '[.source, .id, .title, .author, .engagement.replies, (.text | startswith("# 程序员"))]'
	assert_output '["v2ex","1000000","程序员如何从公司上班转型 - V2EX","toubi",903,true]'

	run bash -c 'jq -r .text <<< "$1"' _ "$output"
	refute_output --partial "VERSION:"
	refute_output --partial "way to explore"
}

@test "v2ex.search_url: 打 www.v2ex.com/t/<id> 并过 map_topic" {
	browser.page() {
		echo "$1" > "$BATS_TEST_TMPDIR/url"
		printf '%s' '{"title":"T","author":"","description":"","text":"# T\n\n[me](https://www.v2ex.com/member/me)\n\n5 replies\n"}'
	}
	DIG_LIMIT=5 DIG_QUERY="" run v2ex.search_url "https://www.v2ex.com/t/42"
	assert_success
	assert_output --partial '"source":"v2ex"'
	assert_output --partial '"id":"42"'
	assert_output --partial '"author":"me"'
	grep -q "www.v2ex.com/t/42" "$BATS_TEST_TMPDIR/url"
}

@test "v2ex.search_url: 缺云端浏览器凭证时说清为什么需要它" {
	CLOUDFLARE_ACCOUNT_ID="" CLOUDFLARE_API_TOKEN="" DIG_LIMIT=5 run v2ex.search_url "https://www.v2ex.com/t/42"
	assert_failure
	assert_output --partial "www.v2ex.com"
	assert_output --partial "Cloudflare Browser Run"
}

@test "v2ex.search_url: URL 不是主题页时报错" {
	run v2ex.search_url "https://www.v2ex.com/about"
	assert_failure
	assert_output --partial "不是合法的 V2EX 主题 URL"
}
