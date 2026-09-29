#!/usr/bin/env bats

load 'test_helper/common-setup'

setup() {
	_common_setup
	cd "$PROJECT_ROOT"
	export GITHUB_TOKEN=dummy
	export _CONFIG_PATH="$BATS_TEST_TMPDIR/config.toml"
	printf 'download_dir = "%s/dl"\nlog_level = "info"\n' "$BATS_TEST_TMPDIR" > "$_CONFIG_PATH"
	mkdir -p "$BATS_TEST_TMPDIR/dl"
	source "$PROJECT_ROOT/src/binup.sh"
}

@test "binup: build_filename 带扩展名" {
	run build_filename pkg 1.0 tar.gz
	assert_output "pkg-1.0.tar.gz"
}

@test "binup: build_filename 无扩展名" {
	run build_filename pkg 1.0 ""
	assert_output "pkg-1.0"
}

@test "binup: _get_arch_regex 覆盖当前架构" {
	run _get_arch_regex
	assert_success
	[[ $output == *"$(system.arch)"* ]]
}

@test "binup: _build_pattern 替换 {os}/{arch} 占位符" {
	run _build_pattern 'foo-{os}-{arch}*' ''
	assert_output --partial "foo-$(system.os)"
	[[ $output == *"$(system.arch)"* ]]
}

@test "binup: --version 输出版本" {
	run bash src/binup.sh --version
	assert_success
	assert_output --partial "BinUp"
}

@test "binup: list 显示已注册包" {
	printf '\n[packages.lf]\nrepo = "gokcehan/lf"\nfile_pattern = "lf-{os}-{arch}*"\nfile_extension = "tar.gz"\n' >> "$_CONFIG_PATH"
	run bash src/binup.sh list
	assert_success
	assert_output --partial "lf"
}

@test "binup: upgrade 未知包报错" {
	run bash src/binup.sh upgrade nope
	assert_failure
	assert_output --partial "Unknown package"
}
