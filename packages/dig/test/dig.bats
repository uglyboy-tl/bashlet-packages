#!/usr/bin/env bats

load 'test_helper/common-setup'

setup() {
	_common_setup
	cd "$PROJECT_ROOT"
	source "$PROJECT_ROOT/dig.sh"
}

@test "dig: --version 输出版本" {
	run bash dig.sh --version
	assert_success
	assert_output --partial "Dig"
}
