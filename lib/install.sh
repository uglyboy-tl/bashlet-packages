#!/usr/bin/env bash

import std/console
import std/fs
import core/log
import core/args
import core/config
import utils

# 确定安装目录
_get_install_dir() {
  local system_bin="/usr/local/bin" user_bin="$HOME/.local/bin"
  if [[ -w $system_bin ]]; then
    echo "$system_bin"
    log.debug "有系统目录写入权限，使用系统目录"
  else
    echo "$user_bin"
    log.debug "无系统目录写入权限，使用用户目录"
  fi
}

# 安装单个包的核心逻辑
_do_install_package() {
  local package="$1"

  current_version=$(get_package_property "$package" "current_version")
  [[ -z $current_version ]] && console.item.title 1 "$package: 未下载，请先运行 upgrade" && return 1

  file_extension=$(get_package_property "$package" "file_extension")
  binary_name=$(get_package_property "$package" "binary_name")

  console.item.title 1 "$package: 开始安装 (版本: $current_version)..."

  # 构建文件名
  filename="${package}-${current_version}${file_extension:+.${file_extension}}"
  archive_file="$SETTINGS_DOWNLOAD_DIR/$filename"
  [[ ! -f $archive_file ]] && console.item.title 1 "$package: 文件不存在: $archive_file" && return 1

  # 确定安装目录
  install_dir=$(_get_install_dir)
  mkdir -p "$install_dir"

  local work_dir="$(fs.mktemp "-d")" || return 1
  trap 'rm -rf "${work_dir:-}"' RETURN

  console.item.item "[解压] $filename"
  if ! fs.file.extract "$SETTINGS_DOWNLOAD_DIR/$filename" "$work_dir"; then
    console.item.item "$package: 解压失败"
    return 1
  fi

  local no_ext_files=("$(find "$work_dir" -maxdepth 1 -type f ! -name "*.*" 2> /dev/null)")
  [[ ${#no_ext_files[@]} -eq 1 ]] && chmod +x "${no_ext_files[0]}"

  binary_files=()
  while IFS= read -r -d '' file; do
    binary_files+=("$file")
  done < <(find "$work_dir" -type f \( -executable -o -perm /111 \) ! -name "*.*" -print0 2> /dev/null)

  binary_count=${#binary_files[@]}
  if [[ $binary_count -eq 0 ]]; then
    log.warn "$package: 未找到可执行文件"
    return 1
  fi

  installed_count=0
  failed_packages=()
  for binary_file in "${binary_files[@]}"; do
    if [[ $binary_count -eq 1 ]]; then
      target_file="$install_dir/${binary_name:-$(basename "$binary_file")}"
    else
      target_file="$install_dir/$(basename "$binary_file")"
    fi
    console.item.item "[安装] 到 $target_file"
    cp "$binary_file" "$target_file" 2> /dev/null || {
      file_name="$(basename "$binary_file")"
      log.warn "$file_name: 复制失败"
      failed_packages+=("$file_name")
      continue
    }
    ((installed_count++))
  done

  if [[ ${#failed_packages[@]} -eq 0 ]]; then
    console.item.item "[完成] 安装成功 ($installed_count 个文件)"
    console.item.item "[路径] $install_dir 已添加到 PATH"
    return 0
  else
    console.item.item "[失败] 安装 ${failed_packages[*]} 时出现错误"
    return 1
  fi
}

# Command: install - 安装已下载的包
cmd_install() {
  args.init
  args.add_options "arg" "待安装的二进制包" "可选：指定需要安装的二进制包名，支持多个包名"
  args.process "$@"

  local -n target_packages=$(args.args)

  console.section "安装包"

  local success_count=0 fail_count=0

  for package in "${target_packages[@]}"; do
    read -ra packages < <(config.array.items "packages")
    if ! printf '%s\n' "${packages[@]}" | grep -q "^${package}$"; then
      log.error "Unknown package: $package"
      log.error "Available packages: $(config.array.items "packages")"
      exit 1
    elif _do_install_package "$package"; then
      ((success_count++))
    else
      ((fail_count++))
    fi
    console.stdout ""
  done

  console.footer "共 ${#target_packages[@]} 个包，$success_count 个成功，$fail_count 个失败"
}
