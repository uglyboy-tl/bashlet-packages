#!/usr/bin/env bash

import core/args
import core/config
import utils

cmd_list() {
  args.init
  args.process "$@"

  console.section "已下载的包"

  for package in $(config.array.items "packages"); do
    current_version=$(get_package_property "$package" "current_version")
    latest_version=$(get_package_property "$package" "latest_version")
    file_extension=$(get_package_property "$package" "file_extension")
    # 构建精确文件名（使用当前版本号，有扩展名时自动追加）
    file_path="$SETTINGS_DOWNLOAD_DIR/${package}-${current_version}${file_extension:+.$file_extension}"

    console.item.title 0 "$POWERLINE_STAR $package"
    [[ -z $latest_version ]] && console.item.end "状态: $POWERLINE_WARN 运行 \'update\' 获取版本信息" && continue
    [[ -z $current_version ]] || [[ ! -f $file_path ]] && console.item.mid "状态: $POWERLINE_COG 未下载 (最新: $latest_version)" && console.item.end "运行 \`upgrade $package\` 下载" && continue

    # 使用 stat 直接格式化时间输出：YYYY-MM-DD HH:MM:SS
    download_time=$(stat -c "%.19y" "$file_path" 2> /dev/null || stat -c "%y" "$file_path" 2> /dev/null | cut -d'.' -f1)
    console.item.mid "当前版本: $current_version"
    console.item.mid "文件: $(basename "$file_path")"
    console.item.mid "下载时间: $download_time"

    [[ $current_version == "$latest_version" ]] && console.item.end "状态: $POWERLINE_OK 已是最新" || console.item.end "状态: $POWERLINE_STAR 有新版本 $latest_version"
  done
}
