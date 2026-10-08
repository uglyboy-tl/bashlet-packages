#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "dig: --version 输出版本" {
	run bash dig.sh --version
	assert_success
	assert_output --partial "Dig"
}

@test "dig: 无参数打印帮助并列出子命令" {
	run bash dig.sh
	assert_success
	assert_output --partial "weread"
	assert_output --partial "doctor"
}

@test "dig: 顶层描述由注册表拼出，不是写死的旧源清单" {
	run bash dig.sh
	assert_success
	local first="${lines[0]}"
	[[ $first == *"按站点取数的工具箱"* ]]
	[[ $first == *"openalex"* && $first == *"wechat"* ]]
	refute_output --partial "Stack Overflow"
}

@test "dig: 未知子命令报错" {
	run bash dig.sh nosuchcmd
	assert_failure
}

@test "dig: merge 子命令已移除" {
	run bash dig.sh merge
	assert_failure
}
