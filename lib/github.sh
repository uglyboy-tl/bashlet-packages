#!/usr/bin/env bash

# ============================================
# GitHub Releases API - 精简版
# 仅用于 update 命令获取云端信息
# ============================================

import std/fs
import std/system
import ext/requests

declare -g OS ARCH

system.os.init
system.arch.init
requests.init 2>/dev/null || { log.error "Failed to initialize requests module" && exit 1; }

[[ -n "${GITHUB_TOKEN:-}" ]] && requests.headers.append "Authorization" "token $GITHUB_TOKEN"

_get_arch_regex() {
	declare -g ARCH
	: ${ARCH:=$(system.arch)}
	case "$ARCH" in
	amd64) echo "(x86_64|x64|amd64)" ;;
	arm64) echo "(aarch64|arm64)" ;;
	armhf) echo "(armv7l|armhf|armv7hl|armv7l-unknown)" ;;
	i386) echo "(i686|i386|i586)" ;;
	*) echo "$ARCH" ;;
	esac
}

_build_pattern() {
	declare -g OS
	: ${OS:=$(system.os)}
	local pattern="$1"
	[[ "$pattern" == *"{os}"* ]] && pattern="${pattern//\{os\}/$OS}"
	[[ "$pattern" == *"{arch}"* ]] && pattern="${pattern//\{arch\}/$(_get_arch_regex)}"
	# 正则转义
	pattern="${pattern//\*/.*}"
	pattern="${pattern//\?/.}"

	# 构建完整的正则表达式用于匹配
	local full_pattern
	[[ -n "${2:-}" ]] && full_pattern="${pattern}[.][^.]*${2}$" || full_pattern="${pattern}$"

	echo "$full_pattern"
}

_github_fetch_release() {
	local response=$(requests.get ""https://api.github.com/repos/$1/releases"")
	requests.raise_for_status "$response" || return 1
	[[ "${2:-release}" == "release" ]] && requests.json "$response" '[.[] | select(.prerelease == false)][0]' || requests.json "$response" '.[0]'
}

# 获取最新版本和下载 URL
# 参数: $1=仓库名, $2=版本类型, $3=file_pattern, $4=file_extension
# 输出: VERSION|||URL
get_latest_version_and_url() {
	local latest=$(_github_fetch_release "$1" "${2:-release}") || return 1

	local version=$(echo "$latest" | jq -r '.tag_name // .name')
	[[ "$version" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]] && version="${BASH_REMATCH[1]}"
	[[ -z "$version" || "$version" == "null" ]] && return 1

	# 构建完整的正则表达式用于匹配
	local -r full_pattern=$(_build_pattern "$3" "${4:-}")
	local -r download_url=$(echo "$latest" | jq -r ".assets[] | select(.name | test(\"$full_pattern\"; \"i\")) | .browser_download_url" | head -1)
	log.debug "Matching regex: $full_pattern"
	[[ -z "$download_url" || "$download_url" == "null" ]] && return 1

	echo "${version}|||${download_url}"
}
