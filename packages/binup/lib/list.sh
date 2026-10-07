#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

import core/args
import core/log
import std/array
import std/console
import std/console.layout
import common

cmd_list() {
	args.init
	args.process "$@"

	console.layout.section "已下载的包"

	local -a registered_packages=()
	mapfile -t registered_packages < <(get_default_registered_packages)

	local package current_version latest_version file_extension file_path download_time
	for package in "${registered_packages[@]}"; do
		current_version=$(get_package_property "$package" "current_version")
		latest_version=$(get_package_property "$package" "latest_version")
		file_extension=$(get_package_property "$package" "file_extension")
		file_path="$SETTINGS_DOWNLOAD_DIR/$(build_filename "$package" "$current_version" "$file_extension")"

		console.layout.item.title 0 "$POWERLINE_STAR $package"
		[[ -n $latest_version ]] || {
			console.layout.item.end "状态: $POWERLINE_WARN 运行 \`$_USAGE_SCRIPT_FILENAME update\` 获取版本信息"
			continue
		}
		[[ -n $current_version && -f $file_path ]] || {
			console.layout.item.mid "状态: $POWERLINE_COG 未下载 (最新: $latest_version)"
			console.layout.item.end "运行 \`$_USAGE_SCRIPT_FILENAME upgrade $package\` 下载"
			continue
		}

		# 两个分支都是 GNU stat（BSD 是 stat -f），兜底分支永不生效
		download_time=$(stat -c "%.19y" "$file_path" 2> /dev/null || true)
		console.layout.item.mid "当前版本: $current_version"
		console.layout.item.mid "文件: $(basename "$file_path")"
		console.layout.item.mid "下载时间: $download_time"

		if [[ $current_version == "$latest_version" ]]; then
			console.layout.item.end "状态: $POWERLINE_OK 已是最新"
		else
			console.layout.item.end "状态: $POWERLINE_STAR 有新版本 $latest_version"
		fi
	done
	return 0
}
