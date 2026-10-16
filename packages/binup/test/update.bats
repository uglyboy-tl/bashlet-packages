#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_binup_setup
}

@test "update: 把资产模式展成正则，并以 stable 模式查 release" {
	github.release.pick() { printf '%s|%s\n' "$2" "$3"; }

	run _get_latest_version_and_url "a/b" release 'app-{os}-{arch}' tar.gz
	assert_output "$(github.asset.pattern 'app-{os}-{arch}' tar.gz)|stable"
}

@test "update: 非 release 版本类型改用 any 模式" {
	github.release.pick() { printf '%s\n' "$3"; }

	run _get_latest_version_and_url "a/b" prerelease 'app-{os}'
	assert_output "any"
}

@test "update: _save_latest_info 写入 versions.toml" {
	run _save_latest_info lf 1.2.3 "https://example.com/lf.tar.gz"
	assert_success

	run grep 'latest_version = "1.2.3"' "$BATS_TEST_TMPDIR/dl/versions.toml"
	assert_success

	run grep 'download_url = "https://example.com/lf.tar.gz"' "$BATS_TEST_TMPDIR/dl/versions.toml"
	assert_success
}

@test "update: _check_package_latest 把结果写成制表符分隔的行" {
	printf '\n[packages.lf]\nrepo = "gokcehan/lf"\nfile_pattern = "lf-{os}"\n' >> "$_CONFIG_PATH"
	config.load "$_CONFIG_PATH"
	_get_latest_version_and_url() { printf '1.2.3|||https://example.com/lf.tar.gz\n'; }

	run _check_package_latest lf "$BATS_TEST_TMPDIR/out"
	assert_success

	run cat "$BATS_TEST_TMPDIR/out"
	assert_output "$(printf 'ok\t1.2.3\thttps://example.com/lf.tar.gz')"
}

@test "update: _check_package_latest 取不到版本时标记 fetch-fail" {
	printf '\n[packages.lf]\nrepo = "gokcehan/lf"\n' >> "$_CONFIG_PATH"
	config.load "$_CONFIG_PATH"
	_get_latest_version_and_url() { return 1; }

	run _check_package_latest lf "$BATS_TEST_TMPDIR/out"
	assert_success

	run cat "$BATS_TEST_TMPDIR/out"
	assert_output "$(printf 'fetch-fail\t\t')"
}

@test "update: cmd_update 并发检查后仍按注册顺序输出并汇总" {
	local p
	for p in alpha beta gamma; do
		printf '\n[packages.%s]\nrepo = "o/%s"\n' "$p" "$p" >> "$_CONFIG_PATH"
	done
	config.load "$_CONFIG_PATH"
	package_reset_cache
	args.process() { :; }
	args.has() { return 1; }
	_get_latest_version_and_url() { printf '1.0|||https://example.com/1.0.tar.gz\n'; }
	export BINUP_UPDATE_CONCURRENCY=2

	run cmd_update
	assert_success
	assert_output --partial "alpha: 未下载 (最新: 1.0)"
	assert_output --partial "共 3 个包：3 个待下载，0 个失败，0 个已是最新"

	# 并发写入不保证完成顺序，但输出必须按注册顺序
	local alpha_line beta_line gamma_line
	alpha_line=$(printf '%s\n' "$output" | grep -n 'alpha:' | cut -d: -f1)
	beta_line=$(printf '%s\n' "$output" | grep -n 'beta:' | cut -d: -f1)
	gamma_line=$(printf '%s\n' "$output" | grep -n 'gamma:' | cut -d: -f1)
	[[ $alpha_line -lt $beta_line && $beta_line -lt $gamma_line ]]
}

@test "update: --all 时已禁用的包也参与检查" {
	printf '\n[packages.on]\nrepo = "o/on"\n\n[packages.off]\nrepo = "o/off"\nenabled = "false"\n' >> "$_CONFIG_PATH"
	config.load "$_CONFIG_PATH"
	package_reset_cache
	args.process() { :; }
	args.has() { [[ $1 == "-a" ]]; }
	_get_latest_version_and_url() { printf '1.0|||https://example.com/1.0.tar.gz\n'; }

	run cmd_update
	assert_success
	assert_output --partial "on: 未下载"
	assert_output --partial "off: 未下载"
	refute_output --partial "跳过"
}

@test "update: 取版本失败的包计入失败数" {
	printf '\n[packages.lf]\nrepo = "gokcehan/lf"\n' >> "$_CONFIG_PATH"
	config.load "$_CONFIG_PATH"
	package_reset_cache
	args.process() { :; }
	args.has() { return 1; }
	_get_latest_version_and_url() { return 1; }

	run cmd_update
	assert_success
	assert_output --partial "lf: 获取版本失败"
	assert_output --partial "1 个失败"
}
