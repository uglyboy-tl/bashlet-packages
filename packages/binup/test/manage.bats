#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_binup_setup
}

_binup_add_local() {
	local name="$1" extra="${2:-}"
	printf '\n[packages.%s]\nrepo = "owner/%s"\n%s\n' "$name" "$name" "$extra" >> "$_CONFIG_PATH"
}

@test "disable: 写入 enabled = false" {
	_binup_add_local lf

	run bash binup.sh disable lf
	assert_success

	run grep -q 'enabled = "false"' "$_CONFIG_PATH"
	assert_success
}

@test "enable: 把 enabled 改回 true" {
	_binup_add_local lf 'enabled = "false"'

	run bash binup.sh enable lf
	assert_success

	run grep -q 'enabled = "true"' "$_CONFIG_PATH"
	assert_success
}

@test "disable: 未知包报错且不改配置" {
	run bash binup.sh disable nope
	assert_failure
	assert_output --partial "Unknown package"

	run grep -q 'nope' "$_CONFIG_PATH"
	assert_failure
}

@test "disable: 保留包的其他字段" {
	_binup_add_local lf 'file_pattern = "lf-{os}-{arch}"'

	run bash binup.sh disable lf
	assert_success

	run grep -q 'repo = "owner/lf"' "$_CONFIG_PATH"
	assert_success
	run grep -q 'file_pattern = "lf-{os}-{arch}"' "$_CONFIG_PATH"
	assert_success
}

@test "remove: 删掉目标段并保留其他段" {
	_binup_add_local lf
	_binup_add_local uv

	run bash binup.sh remove lf
	assert_success

	run grep -q 'packages.lf' "$_CONFIG_PATH"
	assert_failure
	run grep -q 'packages.uv' "$_CONFIG_PATH"
	assert_success
}

@test "remove: 同时清掉 versions.toml 里的同名段" {
	_binup_add_local lf
	{
		echo "[packages.lf]"
		echo 'latest_version = "1.0"'
	} >> "$BATS_TEST_TMPDIR/dl/versions.toml"

	run bash binup.sh remove lf
	assert_success

	run grep -q 'latest_version' "$BATS_TEST_TMPDIR/dl/versions.toml"
	assert_failure
}

@test "remove: 未知包报错" {
	run bash binup.sh remove nope
	assert_failure
	assert_output --partial "Unknown package"
}

@test "remove: 默认不动已下载的归档" {
	_binup_add_local lf
	touch "$BATS_TEST_TMPDIR/dl/lf-1.0.tar.gz"

	run bash binup.sh remove lf
	assert_success
	refute_output --partial "归档与备份已删除"
	[[ -f "$BATS_TEST_TMPDIR/dl/lf-1.0.tar.gz" ]]
}

@test "remove --purge: 删除归档与备份，不误伤同前缀包" {
	_binup_add_local uv
	mkdir -p "$BATS_TEST_TMPDIR/dl/backups"
	touch "$BATS_TEST_TMPDIR/dl/uv-1.0.tar.gz"
	touch "$BATS_TEST_TMPDIR/dl/backups/uv-0.9-2024.01.01.tar.gz"
	touch "$BATS_TEST_TMPDIR/dl/uvx-1.0.tar.gz"

	run bash binup.sh remove --purge uv
	assert_success
	assert_output --partial "归档与备份已删除"
	refute_output --partial "未受影响"

	[[ ! -f "$BATS_TEST_TMPDIR/dl/uv-1.0.tar.gz" ]]
	[[ ! -f "$BATS_TEST_TMPDIR/dl/backups/uv-0.9-2024.01.01.tar.gz" ]]
	[[ -f "$BATS_TEST_TMPDIR/dl/uvx-1.0.tar.gz" ]]
}
