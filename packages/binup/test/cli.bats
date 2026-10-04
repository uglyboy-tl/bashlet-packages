#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_binup_setup
}

@test "cli: --version 输出版本" {
	run bash binup.sh --version
	assert_success
	assert_output --partial "BinUp"
}

@test "cli: upgrade 未知包报错" {
	run bash binup.sh upgrade nope
	assert_failure
	assert_output --partial "Unknown package"
}

@test "cli: install 未知包报错" {
	run bash binup.sh install nope
	assert_failure
	assert_output --partial "Unknown package"
}
