#!/usr/bin/env bats

# lib/browser.sh：云端无头浏览器能力（Cloudflare Browser Run /markdown）。
# 离线测：只桩掉网络层（dig.http.post_json），其余都是纯函数。

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

CF_MD='---
title: 万字长文总结提示词技巧
meta:
  author: 新智元
  description: 摘要在这里
  "og:title": 重复的标题
---

正文第一段

正文第二段'

@test "browser.parse: 拆 front-matter 的 title/author/description，正文是其后部分" {
	printf '%s' "$CF_MD" > "$BATS_TEST_TMPDIR/md.txt"
	run browser.parse < "$BATS_TEST_TMPDIR/md.txt"
	assert_success
	assert_jq '[.title, .author, .description]'
	assert_output '["万字长文总结提示词技巧","新智元","摘要在这里"]'

	local body
	body="$(browser.parse < "$BATS_TEST_TMPDIR/md.txt" | jq -r .text)"
	[[ $body == *"正文第一段"* ]]
}

@test "browser.parse: 没有 front-matter 时整篇当正文" {
	printf '%s' "just text" > "$BATS_TEST_TMPDIR/plain.txt"
	run browser.parse < "$BATS_TEST_TMPDIR/plain.txt"
	assert_success
	assert_jq '.text'
	assert_output '"just text"'
}

@test "browser.available / browser.creds.check: 缺凭证时说清缺哪个" {
	CLOUDFLARE_ACCOUNT_ID="" CLOUDFLARE_API_TOKEN="" run browser.available
	assert_failure

	CLOUDFLARE_API_TOKEN="" run browser.creds.check
	assert_failure
	assert_output --partial "CLOUDFLARE_API_TOKEN"
}

@test "browser.probe: 缺凭证返回 3（doctor 的「缺前置」）" {
	CLOUDFLARE_ACCOUNT_ID="" run browser.probe
	[ "$status" -eq 3 ]
	assert_output --partial "CLOUDFLARE_ACCOUNT_ID"
}

@test "browser.markdown: POST /browser-run/markdown，成功时只回 result" {
	dig.http.post_json() {
		echo "$1" > "$BATS_TEST_TMPDIR/url"
		printf '%s' '{"success":true,"result":"hello"}'
	}
	run browser.markdown "https://example.com"
	assert_success
	assert_output "hello"
	grep -q "browser-run/markdown" "$BATS_TEST_TMPDIR/url"
}

@test "browser.markdown: success=false 时报 CF 详情并点出权限问题" {
	dig.http.post_json() {
		printf '%s' '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}'
	}
	run browser.markdown "https://example.com"
	assert_failure
	assert_output --partial "Authentication error"
	assert_output --partial "Browser Rendering - Edit"
}

@test "browser.throttle.wait: 距上次不足最小间隔就给剩余秒数（纯函数）" {
	_BROWSER_MIN_INTERVAL=10
	run browser.throttle.wait 100 95
	assert_output "5"

	run browser.throttle.wait 100 80
	assert_output "0"

	run browser.throttle.wait 100 ""
	assert_output "0"

	_BROWSER_MIN_INTERVAL=0
	run browser.throttle.wait 100 99
	assert_output "0"
}

@test "browser.throttle: 首次不等待并写时间戳；间隔 0 时什么都不做" {
	local stamp
	stamp="$(cache.dir browser)/last-call"
	rm -f "$stamp"

	_BROWSER_MIN_INTERVAL=0
	run browser.throttle
	assert_success
	[ ! -f "$stamp" ] || { echo "间隔 0 不该写时间戳"; return 1; }

	_BROWSER_MIN_INTERVAL=10
	run browser.throttle
	assert_success
	[ -f "$stamp" ] || { echo "没写时间戳"; return 1; }
}

@test "browser.throttle: 距上次太近时等够剩余秒数并打一行 INFO" {
	local dir stamp
	dir="$(cache.dir browser)"
	stamp="$dir/last-call"
	printf "%s" "$(($(date +%s) - 8))" > "$stamp"

	_BROWSER_MIN_INTERVAL=9
	run browser.throttle
	assert_success
	assert_output --partial "限流"
}

@test "browser.markdown: 用完恢复 DIG_AUTH，不把 CF 的头留给后续请求" {
	dig.http.post_json() { printf '%s' '{"success":true,"result":"ok"}'; }
	# 不要用 `VAR=x run ...`：那只在 run 的环境里生效，回不到本 shell 的断言
	DIG_AUTH="Bearer 别人的"
	export DIG_AUTH
	out="$(browser.markdown "https://example.com")"
	[ "$out" = "ok" ]
	[ "$DIG_AUTH" = "Bearer 别人的" ] || {
		echo "DIG_AUTH 没恢复：$DIG_AUTH"
		return 1
	}
}
