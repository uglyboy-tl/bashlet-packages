#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_binup_setup
}

# 造一个含单个可执行文件的 tar.gz
_make_archive() {
	local src="$1" name="$2"
	mkdir -p "$src"
	printf '#!/bin/sh\necho hi\n' > "$src/$name"
	chmod +x "$src/$name"
	tar -czf "$BATS_TEST_TMPDIR/t.tar.gz" -C "$src" "$name"
}

# 造一个单文件 bz2（模拟 restic 那种 <包>-<版本>.bz2）：解压产物名带版本号的点、且没有执行位
_make_bz2() {
	local src="$1" archive_name="$2"
	mkdir -p "$src"
	printf '#!/bin/sh\necho bz2payload\n' > "$src/payload"
	bzip2 -c "$src/payload" > "$BATS_TEST_TMPDIR/$archive_name"
}

# 造一个含两个可执行文件的 tar.gz（模拟 wordcraft 的 GUI + CLI 同包）
_make_two_bin_archive() {
	local src="$1" n
	mkdir -p "$src"
	for n in gui-app cli-tool; do
		printf '#!/bin/sh\necho %s\n' "$n" > "$src/$n"
		chmod +x "$src/$n"
	done
	tar -czf "$BATS_TEST_TMPDIR/t.tar.gz" -C "$src" gui-app cli-tool
}

@test "install: binary_name 命中归档内某个可执行文件时只装那一个" {
	mkdir -p "$BATS_TEST_TMPDIR/work" "$BATS_TEST_TMPDIR/dest"
	_make_two_bin_archive "$BATS_TEST_TMPDIR/src"

	run _install_archive demo "$BATS_TEST_TMPDIR/t.tar.gz" "t.tar.gz" "cli-tool" "$BATS_TEST_TMPDIR/dest" "$BATS_TEST_TMPDIR/work"
	assert_success
	[[ -x $BATS_TEST_TMPDIR/dest/cli-tool ]]
	[ ! -e "$BATS_TEST_TMPDIR/dest/gui-app" ]
}

@test "install: binary_name 没命中任何文件时仍按原名全装" {
	mkdir -p "$BATS_TEST_TMPDIR/work" "$BATS_TEST_TMPDIR/dest"
	_make_two_bin_archive "$BATS_TEST_TMPDIR/src"

	run _install_archive demo "$BATS_TEST_TMPDIR/t.tar.gz" "t.tar.gz" "other-name" "$BATS_TEST_TMPDIR/dest" "$BATS_TEST_TMPDIR/work"
	assert_success
	[[ -x $BATS_TEST_TMPDIR/dest/gui-app ]]
	[[ -x $BATS_TEST_TMPDIR/dest/cli-tool ]]
}

@test "install: 目标是符号链接时换掉链接本身，不穿透覆盖原文件" {
	mkdir -p "$BATS_TEST_TMPDIR/work" "$BATS_TEST_TMPDIR/dest" "$BATS_TEST_TMPDIR/real"
	_make_archive "$BATS_TEST_TMPDIR/src" mytool
	printf 'original\n' > "$BATS_TEST_TMPDIR/real/managed-by-uv"
	ln -s "$BATS_TEST_TMPDIR/real/managed-by-uv" "$BATS_TEST_TMPDIR/dest/mytool"

	run _install_archive demo "$BATS_TEST_TMPDIR/t.tar.gz" "t.tar.gz" "mytool" "$BATS_TEST_TMPDIR/dest" "$BATS_TEST_TMPDIR/work"
	assert_success
	[ ! -L "$BATS_TEST_TMPDIR/dest/mytool" ]
	[[ -x $BATS_TEST_TMPDIR/dest/mytool ]]
	[ "$(cat "$BATS_TEST_TMPDIR/real/managed-by-uv")" = "original" ]
}

@test "install: 复制失败时清掉 .tmp，原目标不被破坏" {
	# 目标目录不可写让复制失败；root 会绕过目录权限，直接跳过
	[ "$(id -u)" -ne 0 ] || skip "root 不受目录权限限制"

	mkdir -p "$BATS_TEST_TMPDIR/work" "$BATS_TEST_TMPDIR/dest"
	_make_archive "$BATS_TEST_TMPDIR/src" mytool
	printf 'old\n' > "$BATS_TEST_TMPDIR/dest/mytool"
	chmod 500 "$BATS_TEST_TMPDIR/dest"

	run _install_archive demo "$BATS_TEST_TMPDIR/t.tar.gz" "t.tar.gz" "mytool" "$BATS_TEST_TMPDIR/dest" "$BATS_TEST_TMPDIR/work"
	assert_failure
	[ ! -e "$BATS_TEST_TMPDIR/dest/mytool.tmp" ]
	[ "$(cat "$BATS_TEST_TMPDIR/dest/mytool")" = "old" ]
	chmod 700 "$BATS_TEST_TMPDIR/dest"
}

@test "install: _get_install_dir 返回可写的 bin 目录" {
	run _get_install_dir
	assert_success
	[ -n "$output" ]
	[ -w "$output" ]
}

@test "install: _install_archive 解压并把可执行文件装到目标目录" {
	_make_archive "$BATS_TEST_TMPDIR/src" mytool
	mkdir -p "$BATS_TEST_TMPDIR/work" "$BATS_TEST_TMPDIR/dest"

	run _install_archive demo "$BATS_TEST_TMPDIR/t.tar.gz" "t.tar.gz" "mytool" "$BATS_TEST_TMPDIR/dest" "$BATS_TEST_TMPDIR/work"
	assert_success
	[[ -x $BATS_TEST_TMPDIR/dest/mytool ]]
}

@test "install: 归档内没有可执行文件时报错" {
	local src="$BATS_TEST_TMPDIR/src"
	mkdir -p "$src" "$BATS_TEST_TMPDIR/work" "$BATS_TEST_TMPDIR/dest"
	printf 'plain text\n' > "$src/readme.txt"
	tar -czf "$BATS_TEST_TMPDIR/t.tar.gz" -C "$src" readme.txt

	run _install_archive demo "$BATS_TEST_TMPDIR/t.tar.gz" "t.tar.gz" "" "$BATS_TEST_TMPDIR/dest" "$BATS_TEST_TMPDIR/work"
	assert_failure
	assert_output --partial "未找到可执行文件"
}

@test "install: _install_archive 支持单文件压缩包（.bz2）" {
	_make_bz2 "$BATS_TEST_TMPDIR/src" "demo-1.2.3.bz2"
	mkdir -p "$BATS_TEST_TMPDIR/work" "$BATS_TEST_TMPDIR/dest"

	run _install_archive demo "$BATS_TEST_TMPDIR/demo-1.2.3.bz2" "demo-1.2.3.bz2" "mytool" "$BATS_TEST_TMPDIR/dest" "$BATS_TEST_TMPDIR/work"
	assert_success
	[[ -x $BATS_TEST_TMPDIR/dest/mytool ]]
	run "$BATS_TEST_TMPDIR/dest/mytool"
	assert_output "bz2payload"
}

@test "install: 安装失败时清掉 current_version，避免 upgrade 永远跳过" {
	# 归档内容不是 tar.gz，解压必失败
	printf '\n[packages.demo]\nrepo = "a/demo"\nfile_pattern = "demo-{os}-{arch}"\nfile_extension = "tar.gz"\n' >> "$_CONFIG_PATH"
	printf '\n[packages.demo]\ncurrent_version = "1.0.0"\n' >> "$VERSIONS_FILE"
	printf 'not an archive\n' > "$SETTINGS_DOWNLOAD_DIR/demo-1.0.0.tar.gz"
	init_settings

	run _do_install_package demo
	assert_failure

	# 不清掉的话，`binup upgrade demo` 会因为 current == latest 而跳过，坏归档永远修不回来
	run grep -c '^current_version = ""$' "$VERSIONS_FILE"
	assert_output "1"
}
