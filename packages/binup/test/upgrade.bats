#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_binup_setup
	SETTINGS_DOWNLOAD_DIR="$BATS_TEST_TMPDIR/dl"
}

@test "upgrade: _download_file 把 GitHub 直链改写成代理 URL" {
	log.setLevel ERROR
	SETTINGS_PROXY_PREFIX="https://proxy.example/gh/"
	requests.download() { printf '%s\n' "$1"; }

	run _download_file "https://github.com/a/b/releases/download/v1/x.tar.gz" /tmp/x
	assert_output "https://proxy.example/gh/a/b/releases/download/v1/x.tar.gz"
}

@test "upgrade: _download_file 把 raw 直链也走代理" {
	log.setLevel ERROR
	SETTINGS_PROXY_PREFIX="https://proxy.example/gh/"
	requests.download() { printf '%s\n' "$1"; }

	run _download_file "https://raw.githubusercontent.com/a/b/main/x.toml" /tmp/x
	assert_output "https://proxy.example/gh/a/b/raw/main/x.toml"
}

@test "upgrade: _download_file 未配代理时原样下载" {
	log.setLevel ERROR
	SETTINGS_PROXY_PREFIX=""
	requests.download() { printf '%s\n' "$1"; }

	run _download_file "https://github.com/a/b/releases/download/v1/x.tar.gz" /tmp/x
	assert_output "https://github.com/a/b/releases/download/v1/x.tar.gz"
}

@test "upgrade: _save_version_info 写入 current_version" {
	run _save_version_info lf 1.2.3
	assert_success

	run grep 'current_version = "1.2.3"' "$SETTINGS_DOWNLOAD_DIR/versions.toml"
	assert_success
}

@test "upgrade: _backup_file 把旧文件移进 backups 并带版本与日期" {
	printf 'x' > "$SETTINGS_DOWNLOAD_DIR/lf-1.0.tar.gz"

	run _backup_file lf 1.0 "lf-1.0.tar.gz" tar.gz
	assert_success

	# 原位置的文件已移走
	[[ ! -f $SETTINGS_DOWNLOAD_DIR/lf-1.0.tar.gz ]]

	local -a backups=("$SETTINGS_DOWNLOAD_DIR"/backups/lf-1.0-*.tar.gz)
	((${#backups[@]} == 1))
	[[ -f ${backups[0]} ]]
}
