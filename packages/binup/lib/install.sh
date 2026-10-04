#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

import core/args
import core/log
import std/fs
import std/console
import std/console.layout
import common

# ===== 安装 =====

_get_install_dir() {
	local system_bin="/usr/local/bin" user_bin="$HOME/.local/bin"
	[[ -w $system_bin ]] && echo "$system_bin" || echo "$user_bin"
}

# 从 $work_dir 解压 $archive_file 并安装可执行文件，返回 0/1
_install_archive() {
	local package="$1" archive_file="$2" filename="$3" binary_name="$4" install_dir="$5" work_dir="$6"
	local -a no_ext_files=() binary_files=() failed_packages=()
	local binary_file binary_count target_file installed_count=0 name

	console.layout.item.item "[解压] $filename"
	if ! fs.file.extract "$archive_file" "$work_dir"; then
		console.layout.item.item "$package: 解压失败"
		return 1
	fi

	mapfile -t no_ext_files < <(find "$work_dir" -maxdepth 1 -type f ! -name "*.*" 2> /dev/null)
	[[ ${#no_ext_files[@]} -eq 1 ]] && chmod +x "${no_ext_files[0]}"

	mapfile -d '' -t binary_files < <(find "$work_dir" -type f -executable ! -name "*.*" -print0 2> /dev/null)
	binary_count=${#binary_files[@]}
	((binary_count == 0)) && {
		log.warn "$package: 未找到可执行文件"
		return 1
	}

	for binary_file in "${binary_files[@]}"; do
		if ((binary_count == 1)); then
			target_file="$install_dir/${binary_name:-$(basename "$binary_file")}"
		else
			target_file="$install_dir/$(basename "$binary_file")"
		fi
		console.layout.item.item "[安装] 到 $target_file"
		if cp "$binary_file" "$target_file" 2> /dev/null; then
			((installed_count++)) || true
		else
			name="$(basename "$binary_file")"
			log.warn "$name: 复制失败"
			failed_packages+=("$name")
		fi
	done

	[[ ${#failed_packages[@]} -eq 0 ]] || {
		console.layout.item.item "[失败] 安装 ${failed_packages[*]} 时出现错误"
		return 1
	}
	console.layout.item.item "[完成] 安装成功 ($installed_count 个文件)"
	console.layout.item.item "[路径] 已安装到 $install_dir"
	return 0
}

_do_install_package() {
	local package="$1"
	local current_version file_extension binary_name filename archive_file install_dir work_dir rc

	current_version=$(get_package_property "$package" "current_version")
	[[ -n $current_version ]] || {
		console.layout.item.title 1 "$package: 未下载，请先运行 \`$_USAGE_SCRIPT_FILENAME upgrade\`"
		return 1
	}

	file_extension=$(get_package_property "$package" "file_extension")
	binary_name=$(get_package_property "$package" "binary_name")
	filename=$(build_filename "$package" "$current_version" "$file_extension")
	archive_file="$SETTINGS_DOWNLOAD_DIR/$filename"
	[[ -f $archive_file ]] || {
		console.layout.item.title 1 "$package: 文件不存在: $archive_file"
		return 1
	}

	console.layout.item.title 1 "$package: 开始安装 (版本: $current_version)..."

	work_dir=$(fs.mktemp "-d") || return 1
	install_dir=$(_get_install_dir)
	log.debug "安装目录: $install_dir"
	mkdir -p "$install_dir"

	_install_archive "$package" "$archive_file" "$filename" "$binary_name" "$install_dir" "$work_dir"
	rc=$?
	rm -rf "$work_dir"
	return $rc
}

cmd_install() {
	args.init
	args.add_options "arg" "待安装的二进制包" "可选：指定需要安装的二进制包名，支持多个包名"
	args.process "$@"

	local -n target_packages="$(args.args)"

	console.layout.section "安装包"

	local success_count=0 fail_count=0 package
	for package in "${target_packages[@]}"; do
		if ! is_package_in_default_config_with_repo "$package"; then
			log.error "Unknown package: $package"
			log.error "Available packages: $(get_default_registered_packages)"
			exit 1
		elif _do_install_package "$package"; then
			((success_count++)) || true
		else
			((fail_count++)) || true
		fi
		console.stdout ""
	done

	console.layout.footer "共 ${#target_packages[@]} 个包，$success_count 个成功，$fail_count 个失败"
}
