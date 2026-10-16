#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_binup_setup
}

@test "list: list 显示已注册包" {
	printf '\n[packages.lf]\nrepo = "gokcehan/lf"\nfile_pattern = "lf-{os}-{arch}*"\nfile_extension = "tar.gz"\n' >> "$_CONFIG_PATH"

	run bash binup.sh list
	assert_success
	assert_output --partial "lf"
}

@test "list: 未下载的包提示先 update" {
	printf '\n[packages.lf]\nrepo = "gokcehan/lf"\nfile_pattern = "lf-{os}-{arch}"\n' >> "$_CONFIG_PATH"

	run bash binup.sh list
	assert_success
	assert_output --partial "update"
}

@test "list: 默认不列已禁用的包，--all 才列出并标注状态" {
	printf '\n[packages.lf]\nrepo = "gokcehan/lf"\n\n[packages.uv]\nrepo = "astral-sh/uv"\nenabled = "false"\n' >> "$_CONFIG_PATH"

	run bash binup.sh list
	assert_success
	assert_output --partial "lf"
	# list 只打印裸包名，不会出现 "packages.uv"，必须断言裸名
	refute_output --partial "uv"

	run bash binup.sh list --all
	assert_success
	assert_output --partial "uv"
	assert_output --partial "已禁用"
}

@test "list: 默认过滤时给出已禁用包的数量提示" {
	printf '\n[packages.lf]\nrepo = "gokcehan/lf"\n\n[packages.uv]\nrepo = "astral-sh/uv"\nenabled = "false"\n' >> "$_CONFIG_PATH"

	run bash binup.sh list
	assert_success
	assert_output --partial "1 个已禁用"
}

@test "list: 没有配置任何包时给出引导而不是只留标题" {
	run bash binup.sh list
	assert_success
	assert_output --partial "还没有配置任何包"
	assert_output --partial "binup.sh search"
}

@test "list: 全部包都被禁用时提示用 --all 查看" {
	printf '\n[packages.uv]\nrepo = "astral-sh/uv"\nenabled = "false"\n' >> "$_CONFIG_PATH"

	run bash binup.sh list
	assert_success
	assert_output --partial "全部 1 个包都已禁用"

	run bash binup.sh list --all
	assert_success
	assert_output --partial "uv"
}
