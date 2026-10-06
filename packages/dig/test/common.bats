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

@test "dig.requests.init: 缺 jq 时返回非 0 而不是 exit" {
	# 覆盖 system.command.exist 假装没装 jq；若 init 直接 exit，本测试会整体终止
	run bash -c '
		source dig.sh
		system.command.exist() { [[ $1 != jq ]]; }
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
