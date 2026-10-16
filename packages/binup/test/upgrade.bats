#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_binup_setup
	SETTINGS_DOWNLOAD_DIR="$BATS_TEST_TMPDIR/dl"
}

@test "upgrade: _download_file 无 git 映射时原样下载" {
	log.setLevel ERROR
	requests.download() { printf '%s\n' "$1"; }

	run _download_file "https://github.com/a/b/releases/download/v1/x.tar.gz" /tmp/x
	assert_output "https://github.com/a/b/releases/download/v1/x.tar.gz"
}

@test "upgrade: 用宿主机 git 的 insteadOf 改写下载地址" {
	log.setLevel ERROR
	printf '[url "https://gh-proxy.com/https://github.com/"]\n\tinsteadOf = https://github.com/\n' > "$BATS_TEST_TMPDIR/gitconfig"
	export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
	requests.download() { printf '%s\n' "$1"; }

	run _download_file "https://github.com/a/b/releases/download/v1/x.tar.gz" /tmp/x
	assert_output "https://gh-proxy.com/https://github.com/a/b/releases/download/v1/x.tar.gz"
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

@test "upgrade: 已是最新的包不逐包展示，只在 footer 汇总" {
	printf '\n[packages.lf]\nrepo = "gokcehan/lf"\nfile_extension = "tar.gz"\n' >> "$_CONFIG_PATH"
	printf '\n[packages.lf]\nlatest_version = "1.0"\ncurrent_version = "1.0"\ndownload_url = "https://example.com/lf.tar.gz"\n' >> "$BATS_TEST_TMPDIR/dl/versions.toml"

	run bash binup.sh upgrade
	assert_success
	refute_output --partial "已是最新版本"
	assert_output --partial "1 个已是最新"
	assert_output --partial "逐包详情"
}
