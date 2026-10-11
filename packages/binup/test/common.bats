#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_binup_setup
}

@test "common: build_filename 带扩展名" {
	run build_filename pkg 1.0 tar.gz
	assert_output "pkg-1.0.tar.gz"
}

@test "common: build_filename 无扩展名" {
	run build_filename pkg 1.0 ""
	assert_output "pkg-1.0"
}

@test "common: get_package_property 读取已注册包的字段" {
	printf '\n[packages.lf]\nrepo = "gokcehan/lf"\nfile_pattern = "lf-{os}-{arch}"\n' >> "$_CONFIG_PATH"
	config.load "$_CONFIG_PATH"

	run get_package_property lf repo
	assert_output "gokcehan/lf"

	run get_package_property lf file_pattern
	assert_output "lf-{os}-{arch}"
}

@test "common: github_token 优先取 gh，gh 无 token 时回退 pass" {
	unset GITHUB_TOKEN
	gh() { printf 'gh-token\n'; }
	pass() { printf 'pass-token\n'; }

	github_token
	run printf '%s' "$GITHUB_TOKEN"
	assert_output "gh-token"

	gh() { return 1; }
	unset GITHUB_TOKEN
	github_token
	run printf '%s' "$GITHUB_TOKEN"
	assert_output "pass-token"
}

@test "common: 只把带 repo 的包算作已注册" {
	printf '\n[packages.lf]\nrepo = "gokcehan/lf"\n\n[packages.empty]\nfile_extension = "tar.gz"\n' >> "$_CONFIG_PATH"
	config.load "$_CONFIG_PATH"

	run is_package_in_default_config_with_repo lf
	assert_success

	run is_package_in_default_config_with_repo empty
	assert_failure

	run get_default_registered_packages
	assert_output "lf"
}
