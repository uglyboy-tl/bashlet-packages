#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_binup_setup
}

@test "add: 把包定义写入本地配置" {
	_binup_seed_registry

	run bash binup.sh add uv
	assert_success

	run grep -q '^\[packages.uv\]$' "$_CONFIG_PATH"
	assert_success

	run grep -q 'uv-{arch}-unknown-{os}-gnu' "$_CONFIG_PATH"
	assert_success
}


@test "add: 目录中不存在的包报错" {
	_binup_seed_registry

	run bash binup.sh add nope
	assert_failure
	assert_output --partial "包目录中不存在"
}

@test "add: safe_value 拦下的包不写入本地配置" {
	_binup_seed_registry
	local cache
	cache=$(requests.cache.path "$REGISTRY_URL")
	printf '\n[packages.evil]\nrepo = "a/b$X"\nfile_pattern = "x$RECORD"\n' >> "$cache"

	run bash binup.sh add evil
	assert_failure
	assert_output --partial "含非法字符"

	run grep -q '^\[packages.evil\]$' "$_CONFIG_PATH"
	assert_failure
}

