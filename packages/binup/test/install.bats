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
