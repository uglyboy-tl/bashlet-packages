#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_binup_setup
}

@test "list: list 显示已注册包" {
	printf '\n[packages.lf]\nrepo = "gokcehan/lf"\nfile_pattern = "lf-{os}-{arch}*"\nfile_extension = "tar.gz"\n' >> "$_CONFIG_PATH"

	run bash binup.sh list
	assert_success
	assert_output --partial "lf"
}


@test "list: 未下载的包提示先 update" {
	printf '\n[packages.lf]\nrepo = "gokcehan/lf"\nfile_pattern = "lf-{os}-{arch}"\n' >> "$_CONFIG_PATH"

	run bash binup.sh list
	assert_success
	assert_output --partial "update"
}
