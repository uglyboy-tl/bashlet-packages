#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

# 用一个假源把 doctor 的每条分支都走一遍（真源的 probe 要联网，测不了确定性行为）

@test "doctor.source: 缺依赖命令时提示先安装" {
	source.register fakedep "测试" "tier:core" "nosuchcmd-xyz" ""
	run doctor.source fakedep
	assert_success
	assert_output --partial "缺少 nosuchcmd-xyz"
}

@test "doctor.source: 没提供 probe 的源显示「无探活」" {
	source.register fakeprobe0 "测试" "tier:core" "" ""
	run doctor.source fakeprobe0
	assert_success
	assert_output --partial "无探活"
}

@test "doctor.source: probe rc=0 显示 ok 与该源的说明" {
	source.register fakeok "测试" "tier:core" "" ""
	fakeok.probe() {
		printf 'example.com 可达'
		return 0
	}
	run doctor.source fakeok
	assert_success
	assert_output --partial "ok"
	assert_output --partial "example.com 可达"
}

@test "doctor.source: probe rc=2 归为不可达并提示可能是代理" {
	source.register fakedown "测试" "tier:core" "" ""
	fakedown.probe() {
		printf 'example.com 网络不通'
		return 2
	}
	run doctor.source fakedown
	assert_success
	assert_output --partial "不可达"
	assert_output --partial "DIG_PROXY"
}

@test "doctor.source: probe rc=3 归为缺前置" {
	source.register fakemissing "测试" "tier:core" "" ""
	fakemissing.probe() {
		printf '缺少 curl 或 jq'
		return 3
	}
	run doctor.source fakemissing
	assert_success
	assert_output --partial "缺前置"
}

@test "doctor.source: probe 其它非零归为失败并保留原文" {
	source.register fakefail "测试" "tier:core" "" ""
	fakefail.probe() {
		printf 'example.com 返回 HTTP 403'
		return 1
	}
	run doctor.source fakefail
	assert_success
	assert_output --partial "失败"
	assert_output --partial "HTTP 403"
}
