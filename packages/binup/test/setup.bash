#!/usr/bin/env bash
# binup 测试共用环境：各 bats 文件先 load 'test_helper/common-setup'，再 load 'setup.bash'

# 指向临时配置与临时下载目录，并以 in-process 方式加载 binup（含配置注册）
_binup_setup() {
	_common_setup
	cd "$PROJECT_ROOT"
	export GITHUB_TOKEN=dummy
	unset BINUP_REGISTRY_URL
	export _CONFIG_PATH="$BATS_TEST_TMPDIR/config.toml"
	printf 'download_dir = "%s/dl"\nlog_level = "info"\n' "$BATS_TEST_TMPDIR" > "$_CONFIG_PATH"
	mkdir -p "$BATS_TEST_TMPDIR/dl"
	# 入口必须走 _fast_load：bats 开着 functrace，直接 source 会让加载慢几百倍
	# （见 test_helper/common-setup.bash 里的说明）
	_fast_load source "$PROJECT_ROOT/binup.sh"
	# init_settings 内部会逐行解析 TOML，同样吃 trap 开销，一并包起来
	_fast_load init_settings
}

# 造一份假的包目录缓存；registry_url 指向关闭端口，让回源立即失败
_binup_seed_registry() {
	export SCRIPT_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
	unset BINUP_REGISTRY_URL
	REGISTRY_URL="http://127.0.0.1:9/registry.toml"
	local cache
	cache=$(requests.cache.path "$REGISTRY_URL")
	mkdir -p "${cache%/*}"
	cat > "$cache" << 'EOF'
[packages.lf]
repo = "gokcehan/lf"
file_pattern = "lf-{os}-{arch}"
file_extension = "tar.gz"
description = "终端文件管理器"

[packages.uv]
repo = "astral-sh/uv"
file_pattern = "uv-{arch}-unknown-{os}-gnu"
file_extension = "tar.gz"
description = "极快的 Python 包管理器"
EOF
	printf 'registry_url = "%s"\n' "$REGISTRY_URL" >> "$_CONFIG_PATH"
}
