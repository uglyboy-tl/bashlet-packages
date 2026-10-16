#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

import core/log
import core/config
import std/ansi.powerline
import std/array

# 包目录缓存的默认有效期（小时），供 search/add 在配置值非法时兜底
DEFAULT_REGISTRY_TTL=24

# 解析真实配置路径：配置常是 dotbot 软链，就地改写（sed -i / awk + mv）会把软链换成普通文件，
# 所以写盘前统一走这里
resolve_config_file() {
	local config_file
	config_file="$(config.path)" || return 1
	readlink -f "$config_file"
}

# ===== 包属性 =====

get_package_property() { config.array.get "packages" "$1" "$2" || true; }

declare -ga _DEFAULT_REGISTERED_PACKAGES=()
declare -g _DEFAULT_PACKAGES_LOADED=false

# 让「已注册包」缓存失效；写入配置后必须调用，否则同进程内看不到新包
package_reset_cache() {
	_DEFAULT_REGISTERED_PACKAGES=()
	_DEFAULT_PACKAGES_LOADED=false
}

# 惰性取 GitHub token：只有真正要访问 GitHub 时才调外部命令，
# 避免每次启动（含 --version）都执行一次。来源优先级：环境变量 > gh > pass。
github_token() {
	[[ -n ${GITHUB_TOKEN:-} ]] && return 0
	GITHUB_TOKEN=$(gh auth token 2> /dev/null) || GITHUB_TOKEN=""
	[[ -n ${GITHUB_TOKEN:-} ]] && return 0
	GITHUB_TOKEN=$(pass "github" 2> /dev/null) || GITHUB_TOKEN=""
	return 0
}

# 包名白名单（与 registry.name.valid 同规则，规则单点定义在这里）：包名会进 TOML section 头、
# 下载文件名与 `remove --purge` 的删除 glob，含 / 或 .. 的键能拼出 download_dir 之外的路径
package_name_is_valid() { [[ $1 =~ ^[A-Za-z0-9_-]+$ ]]; }

# 首次调用时从配置收集「含 repo 字段」的包
_load_registered_packages() {
	[[ $_DEFAULT_PACKAGES_LOADED == true ]] && return 0
	local -a all=()
	read -ra all <<< "$(config.array.items "packages")"
	local key
	for key in "${all[@]}"; do
		# 包名白名单：配置键可能来自手写或第三方 registry（如 ../x），非法键绝不能进已注册列表——
		# `remove --purge` 会拿包名拼删除 glob，穿越的键会扫到 download_dir 之外
		package_name_is_valid "$key" || continue
		config.has "packages.$key.repo" && _DEFAULT_REGISTERED_PACKAGES+=("$key")
	done
	_DEFAULT_PACKAGES_LOADED=true
}

get_default_registered_packages() {
	_load_registered_packages
	((${#_DEFAULT_REGISTERED_PACKAGES[@]})) && printf '%s\n' "${_DEFAULT_REGISTERED_PACKAGES[@]}"
	return 0
}

is_package_in_default_config_with_repo() {
	_load_registered_packages
	array.contains _DEFAULT_REGISTERED_PACKAGES "$1"
}

# 是否参与 `update` 的更新检查。enabled 字段缺省视为启用（老配置无需迁移），
# 只有显式写 "false" 才算禁用；禁用不影响 upgrade/install 手动指定该包。
package_is_enabled() {
	local value
	value="$(get_package_property "$1" "enabled")"
	[[ $value != "false" ]]
}

# 只列启用（参与更新检查）的包
list_enabled_packages() {
	local package
	while IFS= read -r package; do
		[[ -n $package ]] || continue
		package_is_enabled "$package" && printf '%s\n' "$package"
	done < <(get_default_registered_packages)
	return 0
}

# ===== 文件名拼装 =====

build_filename() { printf '%s' "${1}-${2}${3:+.${3}}"; }
