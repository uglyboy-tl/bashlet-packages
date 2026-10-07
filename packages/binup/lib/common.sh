#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

import core/log
import core/config
import std/ansi.powerline
import std/array

# 包目录缓存的默认有效期（小时），供 search/add 在配置值非法时兜底
DEFAULT_REGISTRY_TTL=24

# ===== 包属性 =====

get_package_property() { config.array.get "packages" "$1" "$2" || true; }

declare -ga _DEFAULT_REGISTERED_PACKAGES=()
declare -g _DEFAULT_PACKAGES_LOADED=false

# 让「已注册包」缓存失效；写入配置后必须调用，否则同进程内看不到新包
package_reset_cache() {
	_DEFAULT_REGISTERED_PACKAGES=()
	_DEFAULT_PACKAGES_LOADED=false
}

# 惰性取 GitHub token：只有真正要访问 GitHub 时才调 pass，
# 避免每次启动（含 --version）都执行一次外部命令。
github_token() {
	[[ -n ${GITHUB_TOKEN:-} ]] && return 0
	GITHUB_TOKEN=$(pass "github" 2> /dev/null) || GITHUB_TOKEN=""
	return 0
}

# 首次调用时从配置收集「含 repo 字段」的包
_load_registered_packages() {
	[[ $_DEFAULT_PACKAGES_LOADED == true ]] && return 0
	local -a all=()
	read -ra all <<< "$(config.array.items "packages")"
	local key
	for key in "${all[@]}"; do
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

# ===== 文件名拼装 =====

build_filename() { printf '%s' "${1}-${2}${3:+.${3}}"; }
