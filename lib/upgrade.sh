#!/usr/bin/env bash

import std/console
import std/fs
import core/log
import core/args
import core/config
import ext/requests
import utils

save_version_info() {
  [[ -z $1 ]] && return 1

  if system.command.exist "yq"; then
    yq -o toml -i ".packages.$1.current_version = \"$2\"" "$VERSIONS_FILE"
  else
    config.update "packages" "$1" "current_version" "$2" "$VERSIONS_FILE"
  fi
}

download_file() {
  local url="${SETTINGS_PROXY_PREFIX:+${SETTINGS_PROXY_PREFIX}${1#https://github.com/}}"
  log.debug "[URL] ${url:-$1}"
  requests.download "${url:-$1}" "$2"
}

# 备份文件到 downloads/backups 目录（使用移动而非复制）
backup_file() {
  local package="$1" version="$2" filename="$3" ext="${4:-${3##*.}}"
  local source_file="$SETTINGS_DOWNLOAD_DIR/$filename"
  local backup_dir="$SETTINGS_DOWNLOAD_DIR/backups"
  local timestamp=$(date +%Y.%m.%d)

  # 使用参数扩展获取文件后缀（如果有的话）
  local backup_file="${backup_dir}/${package}-${version}-${timestamp}${ext:+.${ext}}"

  mkdir -p "$backup_dir"
  mv "$source_file" "$backup_file"
  fs.cleanup "${backup_dir}/${package}-"
  log.debug "[Backup] $backup_file"
}

build_filename() {
  printf '%s' "${1}-${2}${3:+.${3}}"
}

cmd_upgrade() {
  args.init
  args.add_options "arg" "待更新的二进制包" "可选：指定需要更新的二进制包名，支持多个包名"
  args.process "$@"

  local -n target_packages=$(args.args)
  local packages_to_upgrade=()

  if [[ ${#target_packages[@]} -eq 0 ]]; then
    IFS=" " read -r -a packages_to_upgrade  <<< "$(config.array.items "packages")"
  else
    local all_packages
    all_packages=$(config.array.items "packages")
    for package in "${target_packages[@]}"; do
      if [[ " $all_packages " != *" $package "* ]]; then
        log.error "Unknown package: $package"
        log.error "Available packages: $all_packages"
        exit 1
      fi
      packages_to_upgrade+=("$package")
    done
  fi

  local packages_skipped=0

  console.section "下载更新"

  for package in "${packages_to_upgrade[@]}"; do
    local file_extension current_version latest_version download_url
    file_extension=$(get_package_property "$package" "file_extension")
    current_version=$(get_package_property "$package" "current_version")
    latest_version=$(get_package_property "$package" "latest_version")
    download_url=$(get_package_property "$package" "download_url")

    if [[ -z $latest_version ]]; then
      console.item.title 1 "$package: 没有云端信息，请先运行 'update'"
      continue
    fi

    if [[ -z $download_url ]]; then
      console.item.title 1 "$package: 没有下载链接，请先运行 'update'"
      continue
    fi

    if [[ -z $current_version ]]; then
      console.item.title 1 "$package: 未下载，将下载 $latest_version"
    elif [[ $current_version != "$latest_version" ]]; then
      console.item.title 1 "$package: 有新版本 $current_version -> $latest_version"
    else
      console.item.title 1 "$package: 已是最新版本 $current_version"
      ((packages_skipped++)) || true
      continue
    fi

    # 备份旧版本
    if [[ -n $current_version ]]; then
      local old_file=$(build_filename "$package" "$current_version" "$file_extension")
      [[ -f "$SETTINGS_DOWNLOAD_DIR/$old_file" ]] && backup_file "$package" "$current_version" "$old_file" "$file_extension" > /dev/null
    fi

    local filename=$(build_filename "$package" "$latest_version" "$file_extension")
    local output_file="$SETTINGS_DOWNLOAD_DIR/$filename"

    console.item.item "[下载] $filename"
    if download_file "$download_url" "$output_file"; then
      console.item.item "[完成] 下载成功"
      save_version_info "$package" "$latest_version"
    else
      console.item.item "$package: 下载失败"
      rm -f "$output_file"
    fi
  done

  local total=${#packages_to_upgrade[@]}
  local updated=$((total - packages_skipped))
  ((total > 0)) && console.footer "共 $total 个包，$updated 个已更新，$packages_skipped 个跳过"
}
