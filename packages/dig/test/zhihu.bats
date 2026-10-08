#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "zhihu.fetch: 传输层失败报「网络不通」，不是 HTTP 0（经由 dig.http.request）" {
	export ZHIHU_ACCESS_SECRET=x
	# 桩掉底层请求，模拟 curl exit 7（连接被拒）：status_code 是 0，不是 000
	requests.request() { printf '%s' '{"status_code":0,"curl_exit":7,"body":"","headers":{}}'; }
	DIG_RETRY=0 run zhihu.fetch /x
	assert_failure
	assert_output --partial "网络不通"
	refute_output --partial "HTTP 0"
}

@test "zhihu.check: Code 非 0 报错并给出对应提示" {
	run zhihu.check <<< '{"Code":30002,"Message":"quota"}'
	assert_failure
	assert_output --partial "30002"
	assert_output --partial "当日配额用尽"
}

@test "zhihu.check: Code 0 原样通过" {
	run zhihu.check <<< '{"Code":0,"Data":{"ok":1}}'
	assert_success
	assert_output --partial '"ok":1'
}

@test "zhihu.credential: 环境变量优先" {
	export ZHIHU_ACCESS_SECRET=from-env
	run zhihu.credential
	assert_success
	assert_output "from-env"
}

@test "zhihu.credential: 没设时给出怎么配的指引（不再有文件回退）" {
	unset ZHIHU_ACCESS_SECRET
	run zhihu.credential
	assert_failure
	assert_output --partial "ZHIHU_ACCESS_SECRET"
	assert_output --partial "developer.zhihu.com"
	# 回退来源已移除：不该再出现这类字眼
	[[ $output != *credentials.json* ]]
}
