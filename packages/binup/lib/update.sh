#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

import core/args
import core/log
import core/config.persist
import ext/github
import std/array
import std/console
import std/console.layout
import common

# ===== GitHub 发布 =====

# 输出: VERSION|||URL
_get_latest_version_and_url() {
	local repo="$1" version_type="${2:-release}" pattern="$3" ext="${4:-}"
	local build_pattern mode="any"

	build_pattern=$(github.asset.pattern "$pattern" "$ext")
	log.debug "Matching regex: $build_pattern"

	[[ $version_type == "release" ]] && mode="stable"
	github.release.pick "$repo" "$build_pattern" "$mode"
}

# ===== 版本信息持久化 =====

_save_latest_info() {
	[[ $# -lt 3 ]] && return 1
	config.persist.update "packages" "$1" "latest_version" "$2" "$VERSIONS_FILE"
	config.persist.update "packages" "$1" "download_url" "$3" "$VERSIONS_FILE"
}

cmd_update() {
	args.init
	args.process "$@"

	github_token
	requests.init "-4" 2> /dev/null || {
		log.error "Failed to initialize requests module"
		exit 1
	}

	console.layout.section "检查更新"

	local has_updates=false
	local -a registered_packages=()
	mapfile -t registered_packages < <(get_default_registered_packages)

	local package repo version_type file_pattern file_extension current_version
	local latest_info latest_version download_url prop
	for package in "${registered_packages[@]}"; do
		local -a props=()
		for prop in repo version_type file_pattern file_extension current_version; do
			props+=("$(get_package_property "$package" "$prop")")
		done
		repo="${props[0]}"
		version_type="${props[1]}"
		file_pattern="${props[2]}"
		file_extension="${props[3]}"
		current_version="${props[4]}"

		latest_info=$(_get_latest_version_and_url "$repo" "$version_type" "$file_pattern" "$file_extension") || {
			console.layout.item.title 1 "$package: 获取版本失败"
			continue
		}
		latest_version="${latest_info%%|||*}"
		download_url="${latest_info#*|||}"
		[[ -n $latest_version && -n $download_url ]] || {
			console.layout.item.title 1 "$package: 获取版本信息失败"
			continue
		}

		_save_latest_info "$package" "$latest_version" "$download_url"

		if [[ -z $current_version ]]; then
			console.layout.item.title 1 "$package: 未下载 (最新: $latest_version)"
			has_updates=true
		elif [[ $current_version != "$latest_version" ]]; then
			console.layout.item.title 1 "$package: 有新版本 $current_version $POWERLINE_POINTING_ARROW $latest_version"
			has_updates=true
		else
			console.layout.item.title 1 "$package: 已是最新版本 $current_version"
		fi
	done

	[[ $has_updates == "true" ]] && console.layout.footer "运行 \`$_USAGE_SCRIPT_FILENAME upgrade\` 下载更新"
	return 0
}
