#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

set -euo pipefail
SCRIPT_NAME="BinUp"
VERSION="2.3.0"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

# 包目录的本地环境（在 import 之前加载：core/log 在顶层读 _LOG_LEVEL）
.env

_DEFAULT_REGISTRY_URL="https://github.com/uglyboy-tl/bashlet-packages/raw/HEAD/packages/binup/registry.toml"

import core/log
import core/args
import core/config
import ext/requests

import common
import registry
import list
import update
import upgrade
import install
import search
import add
import edit

# 注册配置项、加载配置并设好全局设置变量（测试可单独调用，跳过 args 解析）
init_settings() {
	config.register "download_dir" "downloads" "string" "下载目录"
	config.register "proxy_prefix" ""
	config.register "log_level" "info"
	config.register "registry_url" "$_DEFAULT_REGISTRY_URL" "string" "包目录 URL（可换成第三方源）"
	config.register "registry_ttl" "24" "string" "包目录缓存有效期（小时）"
	config.array.register "packages" "repo"
	# description 只在远端：保留注册是为了让 registry 的严格模式能解析出它（dump 走同一个 config.load），
	# 但不放进 REGISTRY_FIELDS，所以 add 不会把它写进本地配置
	config.array.register "packages" "description" ""
	config.array.register "packages" "version_type" ""
	config.array.register "packages" "file_pattern"
	config.array.register "packages" "file_extension"
	config.array.register "packages" "binary_name"
	config.array.register "packages" "current_version"
	config.array.register "packages" "latest_version"
	config.array.register "packages" "download_url"

	local main_config
	main_config=$(config.path 2> /dev/null) || main_config=""
	[[ -n $main_config && -f $main_config ]] && config.load "$main_config"
	SETTINGS_DOWNLOAD_DIR="$(config.get "download_dir")"
	SETTINGS_PROXY_PREFIX="$(config.get proxy_prefix)"
	VERSIONS_FILE="$SETTINGS_DOWNLOAD_DIR/versions.toml"
	config.load "$VERSIONS_FILE" 2> /dev/null || true
	log.setLevel "$(config.get log_level)"
}

# 下载目录/版本文件只有会落盘的子命令需要；不发生副作用的命令（--version、search、add）不该建目录
ensure_download_dir() {
	mkdir -p "$SETTINGS_DOWNLOAD_DIR"
	[[ -f $VERSIONS_FILE ]] || touch "$VERSIONS_FILE"
}

main() {
	args.init 命令行程序下载管理器

	args.add_options "version" "v" "显示版本信息"
	args.add_subcommand "list" "列出项目" "cmd_list"
	args.add_subcommand "update" "检查更新" "cmd_update"
	args.add_subcommand "upgrade" "下载二进制文件包" "cmd_upgrade"
	args.add_subcommand "install" "安装二进制文件" "cmd_install"
	args.add_subcommand "search" "搜索远端包目录" "cmd_search"
	args.add_subcommand "add" "从包目录添加包到本地配置" "cmd_add"
	args.add_subcommand "edit" "编辑配置文件" "cmd_edit"

	init_settings
	args.process "$@"
	args.has "-v" "--version" && usage.version && exit 0
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	main "$@"
fi
