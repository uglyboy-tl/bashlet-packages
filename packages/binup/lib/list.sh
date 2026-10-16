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
	args.add_options "all" "a" "包含已禁用的包（默认只列参与更新检查的）"
	args.process "$@"

	local show_all=false
	args.has "-a" "--all" && show_all=true

	local -a all_packages=() registered_packages=()
	mapfile -t all_packages < <(get_default_registered_packages)

	local package
	for package in "${all_packages[@]}"; do
		if [[ $show_all == true ]] || package_is_enabled "$package"; then
			registered_packages+=("$package")
		fi
	done
	local disabled_count
	disabled_count=$((${#all_packages[@]} - ${#registered_packages[@]}))

	console.layout.section "已配置的包"

	if ((${#registered_packages[@]} == 0)); then
		((disabled_count > 0)) &&
			console.layout.footer "全部 $disabled_count 个包都已禁用（\`$_USAGE_SCRIPT_FILENAME list --all\` 查看）" ||
			console.layout.footer "还没有配置任何包（\`$_USAGE_SCRIPT_FILENAME search <关键词>\` 找到后用 \`add <包名>\` 添加）"
		return 0
	fi

	local current_version latest_version file_extension file_path download_time enabled
	for package in "${registered_packages[@]}"; do
		enabled=true
		package_is_enabled "$package" || enabled=false

		if [[ $enabled == true ]]; then
			console.layout.item.title 0 "$POWERLINE_STAR $package"
		else
			console.layout.item.title 0 "$POWERLINE_STAR $package [已禁用]"
			console.layout.item.end "状态: $POWERLINE_COG 已禁用，不参与 \`$_USAGE_SCRIPT_FILENAME update\` 检查"
			continue
		fi

		current_version=$(get_package_property "$package" "current_version")
		latest_version=$(get_package_property "$package" "latest_version")
		file_extension=$(get_package_property "$package" "file_extension")
		file_path="$SETTINGS_DOWNLOAD_DIR/$(build_filename "$package" "$current_version" "$file_extension")"

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

	if [[ $show_all == false ]] && ((disabled_count > 0)); then
		console.layout.footer "另有 $disabled_count 个已禁用的包（\`$_USAGE_SCRIPT_FILENAME list --all\` 查看）"
	fi
	return 0
}
