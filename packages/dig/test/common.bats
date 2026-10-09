#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "dig.http.request: 传输层失败会重试，并打印每轮日志" {
	# 127.0.0.1:9 必然拒绝连接；DIG_PROXY 置空否则会被代理拦成 503
	DIG_PROXY= DIG_RETRY=1 run dig.http.get "http://127.0.0.1:9/"
	assert_failure
	assert_output --partial "后重试（1/1）"
	assert_output --partial "网络不通"
}

@test "dig.http.request: DIG_RETRY=0 时只试一次，不出现重试日志" {
	DIG_PROXY= DIG_RETRY=0 run dig.http.get "http://127.0.0.1:9/"
	assert_failure
	refute_output --partial "后重试"
	assert_output --partial "网络不通"
}

@test "dig.http.status: 失败后仍能读到状态码" {
	DIG_PROXY= DIG_RETRY=0 run dig.http.get "http://127.0.0.1:9/"
	assert_failure
	# 连接失败时 curl 不给 HTTP 码，status 应为 000 或空
	run dig.http.status
	assert_success
	[[ "$output" == "000" || -z "$output" ]]
}

@test "dig.requests.init: 缺 curl 时返回非 0 而不是 exit" {
	# 覆盖 system.command.exist 假装没装 curl；若 init 直接 exit，本测试会整体终止
	# （jq 归 ext/json，在模块加载时就探活了，不归 init 管）
	run bash -c '
		source dig.sh
		system.command.exist() { [[ $1 != curl ]]; }
		rc=0
		dig.requests.init || rc=$?
		echo "rc=$rc"
	'
	assert_output --partial "缺少依赖"
	assert_output --partial "rc=3"
}

@test "dig: 非法 -n 报错而不是静默回落" {
	run bash dig.sh hn "bash" -n abc
	assert_failure
	assert_output --partial "选项 -n 需要正整数"
}

@test "dig: -n 0 也报错（各源的 API 参数需要正整数）" {
	run bash dig.sh hn "bash" -n 0
	assert_failure
	assert_output --partial "选项 -n 需要正整数"
}

@test "dig.http.body_snippet: 多行响应体压成一行并截到 200 字" {
	requests.init 2> /dev/null
	local b64
	b64="$(printf '%s\n%s' '{"error":"Timeout.' 'Maybe slow down a bit"}' | base64 -w0)"
	run dig.http.body_snippet "{\"status_code\":422,\"curl_exit\":0,\"headers\":{},\"body\":\"$b64\",\"success\":false}"
	assert_success
	assert_output '{"error":"Timeout. Maybe slow down a bit"}'
}

@test "dig.http.body_snippet: 删掉 ANSI 转义等控制字符（远端响应体不可信）" {
	requests.init 2> /dev/null
	local b64
	b64="$(printf '%b' 'evil\033]0;pwned\007END' | base64 -w0)"
	run dig.http.body_snippet "{\"status_code\":422,\"curl_exit\":0,\"headers\":{},\"body\":\"$b64\",\"success\":false}"
	assert_success
	assert_output 'evil]0;pwnedEND'
}

@test "dig.requests.init: --no-creds 不带 Cookie/Authorization，但保留代理" {
	export DIG_COOKIE='c=1' DIG_AUTH='Bearer x' DIG_PROXY='http://p:1'
	dig.requests.init --no-creds
	local extra=" ${_REQUESTS_CURL_EXTRA[*]} "
	[[ $extra != *"Cookie"* ]]
	[[ $extra != *"Authorization"* ]]
	[[ $extra == *"--proxy"* ]]
}

@test "dig.http.get_public: 请求不带凭证，用完恢复 _REQUESTS_CURL_EXTRA" {
	export DIG_COOKIE='c=1' DIG_AUTH='Bearer x'
	dig.requests.init
	local before="${_REQUESTS_CURL_EXTRA[*]}"

	dig.http.request() { printf '%s' "${_REQUESTS_CURL_EXTRA[*]}"; return 0; }
	local out
	out="$(dig.http.get_public "https://api.fxtwitter.com/a/status/1")"
	[[ $out != *"Cookie"* && $out != *"Authorization"* ]]

	dig.http.get_public "https://api.fxtwitter.com/a/status/1" > /dev/null || true
	assert_equal "${_REQUESTS_CURL_EXTRA[*]}" "$before"
}

@test "dig.http.probe: 传输层失败报「网络不通」rc=2，而不是 HTTP 0" {
	# 关闭端口 = 立刻连接被拒（curl exit 7），不用等超时
	run dig.http.probe "http://127.0.0.1:9/x"
	assert_equal "$status" 2
	assert_output --partial "网络不通"
}

@test "dig.clamp: 没超上限时原样返回且不告警" {
	local got
	got="$(dig.clamp 50 100 "上游" 2> /dev/null)"
	[ "$got" = "50" ]
}

@test "dig.clamp: 超上限时夹到上限并告警说明" {
	local got warning
	got="$(dig.clamp 200 100 "上游" 2> /dev/null)"
	[ "$got" = "100" ]

	warning="$(dig.clamp 200 100 "上游" 2>&1 > /dev/null)"
	[[ $warning == *"单次最多 100 条"* ]]
	[[ $warning == *"按 100 处理"* ]]
}

@test "dig: 源特有的可选数字参数非法时报错" {
	run bash dig.sh hn "bash" -c xyz
	assert_failure
	assert_output --partial "需要正整数"
}

# ========== 结果缓存（策略层，存储在 std/cache）==========

@test "dig.cached: 第二次命中缓存，不再执行命令" {
	local calls="$BATS_TEST_TMPDIR/calls"
	run dig.cached key1 -- bash -c "echo x >> '$calls'; printf 'line1\nline2'"
	assert_success
	assert_output --partial 'line1'

	run dig.cached key1 -- bash -c "echo x >> '$calls'; printf 'other'"
	assert_success
	assert_output --partial 'line1'
	refute_output --partial 'other'
	[ "$(wc -l < "$calls")" -eq 1 ]
}

@test "dig.cached: 命令失败不写缓存，第二次仍会执行" {
	local calls="$BATS_TEST_TMPDIR/calls2"
	run dig.cached key2 -- bash -c "echo x >> '$calls'; exit 3"
	assert_failure
	run dig.cached key2 -- bash -c "echo x >> '$calls'; printf 'ok'"
	assert_success
	[ "$(wc -l < "$calls")" -eq 2 ]
}

@test "dig.cached: DIG_NO_CACHE=1 时每次都跑命令" {
	local calls="$BATS_TEST_TMPDIR/calls3"
	DIG_NO_CACHE=1 run dig.cached key3 -- bash -c "echo x >> '$calls'; printf 'd'"
	DIG_NO_CACHE=1 run dig.cached key3 -- bash -c "echo x >> '$calls'; printf 'd'"
	[ "$(wc -l < "$calls")" -eq 2 ]
}

@test "dig.cached: 空结果也缓存（合法的「真的没有」不该反复重查）" {
	local calls="$BATS_TEST_TMPDIR/calls4"
	run dig.cached key4 -- bash -c "echo x >> '$calls'"
	assert_success
	run dig.cached key4 -- bash -c "echo x >> '$calls'"
	assert_success
	[ "$(wc -l < "$calls")" -eq 1 ]
}

