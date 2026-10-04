#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_binup_setup
}

@test "edit: 缺失配置时先创建再用 EDITOR 打开" {
	local path="$BATS_TEST_TMPDIR/edited.toml"
	export _CONFIG_PATH="$path"
	export EDITOR=true

	run bash binup.sh edit
	assert_success
	[[ -f $path ]]

	run grep -q 'download_dir' "$path"
	assert_success
}

@test "edit: _create_default_config 写入默认配置模板" {
	local path="$BATS_TEST_TMPDIR/generated.toml"

	run _create_default_config "$path"
	assert_success

	run grep -q '^download_dir = "downloads"$' "$path"
	assert_success

	run grep -q 'registry_url' "$path"
	assert_success
}
