#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_binup_setup
}

@test "registry: safe_value 拒绝可注入字符" {
	run registry_safe_value 'a"b'
	assert_failure

	run registry_safe_value 'a$b'
	assert_failure

	# 换行与回车会被原样写进 TOML 破坏配置文件
	run registry_safe_value $'a\nb'
	assert_failure

	run registry_safe_value $'a\rb'
	assert_failure

	run registry_safe_value 'lf-{os}-{arch}'
	assert_success

	# # 在 TOML 引号内合法，不该被拒
	run registry_safe_value 'app #1'
	assert_success
}

@test "registry: 缓存过期且回源失败时降级使用" {
	_binup_seed_registry
	printf 'registry_ttl = "0"\n' >> "$_CONFIG_PATH"

	run bash binup.sh search lf
	assert_success
	assert_output --partial "回源失败"
	assert_output --partial "lf"
}

@test "registry: search -r 忽略 TTL 强制回源" {
	_binup_seed_registry

	run bash binup.sh search -r lf
	assert_success
	assert_output --partial "回源失败"
}

@test "registry: 无缓存且回源失败时报错" {
	export SCRIPT_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
	printf 'registry_url = "http://127.0.0.1:9/registry.toml"\n' >> "$_CONFIG_PATH"

	run bash binup.sh search lf
	assert_failure
	assert_output --partial "回源失败"
}

@test "registry: 缓存内容缺少 packages 段时视为无效并报错" {
	export SCRIPT_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
	local url cache
	url="http://127.0.0.1:9/registry.toml"
	cache=$(requests.cache.path "$url")
	mkdir -p "${cache%/*}"
	printf 'not a registry at all\n' > "$cache"
	printf 'registry_url = "%s"\n' "$url" >> "$_CONFIG_PATH"

	run bash binup.sh search
	assert_failure
	assert_output --partial "包目录内容无效"
}

@test "registry: registry_url 可由环境变量覆盖" {
	export SCRIPT_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
	export BINUP_REGISTRY_URL="http://127.0.0.1:9/from-env.toml"
	printf 'registry_url = "http://127.0.0.1:9/from-config.toml"\n' >> "$_CONFIG_PATH"

	run bash binup.sh search lf
	assert_failure
	assert_output --partial "from-env.toml"
}

