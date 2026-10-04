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
