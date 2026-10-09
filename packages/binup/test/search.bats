#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_binup_setup
}

@test "search: 命中缓存并标记已配置" {
	_binup_seed_registry
	printf '\n[packages.lf]\nrepo = "gokcehan/lf"\n' >> "$_CONFIG_PATH"

	run bash binup.sh search lf
	assert_success
	assert_output --partial "lf"
	assert_output --partial "已配置"
	assert_output --partial "终端文件管理器"
	refute_output --partial "origin fetch failed"
}


@test "search: 关键词无匹配时不报错" {	_binup_seed_registry

	run bash binup.sh search zzzz
	assert_success
	assert_output --partial "没有匹配的包"
}

@test "search: 明细最后一行用结尾符号" {
	_binup_seed_registry

	run bash binup.sh search lf
	assert_success
	assert_output --partial "└─ 说明"
}

