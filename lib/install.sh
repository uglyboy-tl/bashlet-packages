#!/usr/bin/env bash

import std/console
import core/log
import core/args
import core/config
import utils

extract_file() {
	local filename="$1"
	local extract_dir="$2"

	local file_path="$SETTINGS_DOWNLOAD_DIR/$filename"
	mkdir -p "$extract_dir"

	# 检查是否是无后缀的二进制文件（直接提供的可执行文件）
	if [[ ! "$filename" =~ \. ]]; then
		# 无后缀文件，直接复制到解压目录
		cp "$file_path" "$extract_dir/"
		chmod +x "$extract_dir/$(basename "$filename")"
		return 0
	fi

	# 根据文件扩展名选择解压方式
	if [[ "$filename" == *.zip ]]; then
		unzip -q "$file_path" -d "$extract_dir"
	elif [[ "$filename" == *.tar.gz ]] || [[ "$filename" == *.tgz ]]; then
		tar -xzf "$file_path" -C "$extract_dir"
	elif [[ "$filename" == *.tar.xz ]] || [[ "$filename" == *.txz ]]; then
		tar -xJf "$file_path" -C "$extract_dir"
	elif [[ "$filename" == *.tar.bz2 ]] || [[ "$filename" == *.tbz2 ]]; then
		tar -xjf "$file_path" -C "$extract_dir"
	else
		return 1
	fi
}

# 安装单个包的内部函数
_do_install_package() {
	local package="$1"
	local show_header="${2:-true}"

	current_version=$(get_package_property "$package" "current_version")
	if [[ -z "$current_version" ]]; then
		item.format 1 "$package: 未下载，请先运行 upgrade"
		return 1
	fi

	file_extension=$(get_package_property "$package" "file_extension")
	binary_name=$(get_package_property "$package" "binary_name")

	if [[ "$show_header" == "true" ]]; then
		item.format 1 "安装 $package (版本: $current_version)..."
	fi

	# 构建文件名（无后缀时直接用包名-版本）
	if [[ -n "$file_extension" ]]; then
		filename="${package}-${current_version}.${file_extension}"
	else
		filename="${package}-${current_version}"
	fi
	archive_file="$SETTINGS_DOWNLOAD_DIR/$filename"

	if [[ ! -f "$archive_file" ]]; then
		item.format 1 "$package: 文件不存在: $archive_file"
		return 1
	fi

	# 确定安装目录
	system_bin="/usr/local/bin"
	user_bin="$HOME/.local/bin"

	if [[ -w "$system_bin" ]]; then
		install_dir="$system_bin"
		item.format 1 "[检测] 有系统目录写入权限，使用系统目录"
	else
		install_dir="$user_bin"
		item.format 1 "[检测] 无系统目录写入权限，使用用户目录"
	fi
	mkdir -p "$install_dir"

	# 无后缀名二进制文件，直接安装
	if [[ -z "$file_extension" ]]; then
		local target_file="$install_dir/$binary_name"
		item.format 1 "[安装] $binary_name"
		cp "$archive_file" "$target_file"
		chmod +x "$target_file"
		item.format 1 "[完成] 安装成功"
		item.format 1 "[路径] $install_dir 已添加到 PATH"
		return 0
	fi

	extract_dir="$SETTINGS_DOWNLOAD_DIR/${package}-${current_version}"
	rm -rf "$extract_dir"
	item.format 1 "[解压] $filename"
	if ! extract_file "$filename" "$extract_dir"; then
		item.format 1 "$package: 解压失败"
		rm -rf "$extract_dir"
		return 1
	fi

	local binary_files=()
	while IFS= read -r -d '' binary_file; do
		binary_files+=("$binary_file")
	done < <(find "$extract_dir" -type f -executable -print0 2>/dev/null)

	if [[ ${#binary_files[@]} -eq 0 ]]; then
		while IFS= read -r -d '' binary_file; do
			binary_files+=("$binary_file")
		done < <(find "$extract_dir" -type f -perm /111 -print0 2>/dev/null)
	fi

	if [[ ${#binary_files[@]} -gt 0 ]]; then
		local installed_count=0
		for binary_file in "${binary_files[@]}"; do
			local target_file="$install_dir/$(basename "$binary_file")"
			item.format 1 "[安装] 到 $target_file"
			cp "$binary_file" "$target_file"
			chmod +x "$target_file"
			((installed_count++)) || true
		done
		rm -rf "$extract_dir"
		item.format 1 "[完成] 安装成功 ($installed_count 个文件)"
		item.format 1 "[路径] $install_dir 已添加到 PATH"
		return 0
	else
		item.format 1 "$package: 未找到可执行文件"
		rm -rf "$extract_dir"
		return 1
	fi
}

# Command: install - 安装已下载的包
cmd_install() {
	args.init
	args.add_options "arg" "待安装的二进制包" "可选：指定需要安装的二进制包名，支持多个包名"
	args.process "$@"

	local -n target_packages=$(args.args)

	title.format "安装包"

	local success_count=0
	local fail_count=0

	for package in "${target_packages[@]}"; do
		if ! printf '%s\n' $(config.array.items "packages") | grep -q "^${package}$"; then
			log.error "Unknown package: $package"
			log.error "Available packages: ${PACKAGES[*]}"
			exit 1
		elif _do_install_package "$package" "true"; then
			((success_count++)) || true
		else
			((fail_count++)) || true
		fi
		console.stdout ""
	done

	console.stdout "========="
	console.stdout "共 ${#target_packages[@]} 个包，$success_count 个成功，$fail_count 个失败"
}
