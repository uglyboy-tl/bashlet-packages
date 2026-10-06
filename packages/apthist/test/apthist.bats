#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() { _apthist_setup; }

_apt() { run bash apthist.sh -l "$LOG" "$@"; }

@test "apthist: 默认只列出手动安装且仍在装的包" {
	_apt -d 3650
	assert_success
	assert_output --partial "foo"
	assert_output --partial "baz"
	refute_output --partial "bar"
	refute_output --partial "qux"
}

@test "apthist: -a 显示自动安装的包" {
	_apt -d 3650 -a
	assert_output --partial "qux"
}

@test "apthist: -r 列出手动卸载的包" {
	_apt -d 3650 -r
	assert_output --partial "bar"
	refute_output --partial "baz"
}

@test "apthist: 输出按日期升序" {
	_apt -d 3650
	local a b
	a=$(printf '%s\n' "$output" | grep -n 'foo' | cut -d: -f1)
	b=$(printf '%s\n' "$output" | grep -n 'baz' | cut -d: -f1)
	[ "$a" -lt "$b" ]
}

@test "apthist: 时间范围外无结果" {
	_apt -d 1
	assert_success
	assert_output --partial "无结果"
}

@test "apthist: 非法天数回退默认而非报错" {
	_apt -d abc
	assert_success
	assert_output --partial "baz"
	refute_output --partial "foo"
}
