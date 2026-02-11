#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$PROJECT_ROOT/lib/std/import.sh"

import std/init
import std/ansi.sh
import core/log
import core/args
import core/config
import github
import versions
import download

UNDERLINE_CACHE=$(printf '%*s' 20 "" | tr ' ' '=')

title.format() {
	console.stdout "$1:"
	console.stdout "=${UNDERLINE_CACHE:0:$(console.mixed_width $1)}"
}


item.format() {
	local level=$1
	console.align $(( ${level}*2 )) "" "${*:2}"
}

# Command: list - 列出已下载的包和更新状态
cmd_list() {
	args.init
	args.process "$@"

	title.format "已下载的包"

	for package in $(config.array.items "packages"); do
		current_version=$(get_package_property "$package" "current_version")
		latest_version=$(get_package_property "$package" "latest_version")
		downloaded=$(get_package_property "$package" "downloaded")
		file_extension=$(get_package_property "$package" "file_extension")

		item.format 1 "$package:"
		[[ ! -n "$latest_version" ]] && item.format 2 "状态: $POWERLINE_WARN 运行 'update' 获取版本信息" && continue
		[[ ! -n "$current_version" ]] || [[ "$downloaded" != "true" ]] && item.format 2 "状态: $POWERLINE_COG 未下载 (最新: $latest_version)" && item.format 2 "运行 'upgrade $package' 下载" && continue

		item.format 2 "当前版本: $current_version"

		# 构建精确文件名（使用当前版本号，有扩展名时自动追加）
		file_path="$SETTINGS_DOWNLOAD_DIR/${package}-${current_version}${file_extension:+.$file_extension}"

		if [[ -f "$file_path" ]]; then
			# 使用 stat 直接格式化时间输出：YYYY-MM-DDTHH:MM:SS
			download_time=$(stat -c "%.19y" "$file_path" 2>/dev/null || stat -c "%y" "$file_path" 2>/dev/null | cut -d'.' -f1)
			item.format 2 "下载时间: $download_time"
			item.format 2 "文件: $(basename "$file_path")"
		fi

		[[ "$current_version" == "$latest_version" ]] && item.format 2 "状态: $POWERLINE_OK 已是最新" || item.format 2 "状态: $POWERLINE_STAR 有新版本 $latest_version"
	done
}

# Command: update - 检查更新并保存云端信息
cmd_update() {
	args.init
	args.process "$@"

	title.format "检查更新"

	local has_updates=false

	for package in $(config.array.items "packages"); do
		repo=$(get_package_property "$package" "repo")
		version_type=""
		file_pattern=$(get_package_property "$package" "file_pattern")
		file_extension=$(get_package_property "$package" "file_extension")
		current_version=$(get_package_property "$package" "current_version")
		downloaded=$(get_package_property "$package" "downloaded")

		# 获取云端最新信息并保存
		latest_info=$(get_latest_version_and_url "$repo" "$version_type" "$file_pattern" "$file_extension") || {
			item.format 1 "$package: 获取版本失败"
			continue
		}

		latest_version="${latest_info%%|||*}"
		download_url="${latest_info#*|||}"

		if [[ -z "$latest_version" || -z "$download_url" ]]; then
			item.format 1 "$package: 获取版本信息失败"
			continue
		fi

		# 保存云端信息到本地
		save_latest_info "$package" "$latest_version" "$download_url"

		# 显示更新状态
		if [[ "$downloaded" != "true" ]]; then
			item.format 1 "$package: 未下载 (最新: $latest_version)"
			has_updates=true
		elif [[ -z "$current_version" ]]; then
			item.format 1 "$package: 最新版本 $latest_version"
		elif [[ "$current_version" != "$latest_version" ]]; then
			item.format 1 "$package: 有新版本 $current_version $POWERLINE_POINTING_ARROW  $latest_version"
			has_updates=true
		else
			item.format 1 "$package: 已是最新版本 $current_version"
		fi
	done

	if [[ "$has_updates" == "true" ]]; then
		console.stdout "========="
		console.stdout "运行 './bin-updater.sh upgrade' 下载更新"
	fi
}

# Command: upgrade - 下载更新（使用本地保存的信息）
cmd_upgrade() {
	args.init
	args.add_options "arg" "待更新的二进制包" "可选：指定需要更新的二进制包名，支持多个包名"
	args.process "$@"

	local -n target_packages=$(args.args)
	local packages_to_upgrade=()

	if [[ ${#target_packages[@]} -eq 0 ]]; then
		packages_to_upgrade=($(config.array.items "packages"))
	else
		for package in "${target_packages[@]}"; do
			if ! printf '%s\n' $(config.array.items "packages") | grep -q "^${package}$"; then
				log.error "Unknown package: $package"
				log.error "Available packages: ${PACKAGES[*]}"
				exit 1
			fi
			packages_to_upgrade+=("$package")
		done
	fi

	local packages_skipped=0

	title.format "下载更新"

	for package in "${packages_to_upgrade[@]}"; do
		file_extension=$(get_package_property "$package" "file_extension")

		current_version=$(get_package_property "$package" "current_version")
		latest_version=$(get_package_property "$package" "latest_version")
		download_url=$(get_package_property "$package" "download_url")
		downloaded=$(get_package_property "$package" "downloaded")

		if [[ -z "$latest_version" ]]; then
			item.format 1 "$package: 没有云端信息，请先运行 'update'"
			continue
		fi

		if [[ -z "$download_url" ]]; then
			item.format 1 "$package: 没有下载链接，请先运行 'update'"
			continue
		fi

		local needs_download=false
		local msg=""
		if [[ "$downloaded" != "true" ]]; then
			needs_download=true
			msg="未下载，将下载 $latest_version"
		elif [[ -z "$current_version" ]]; then
			needs_download=true
			msg="无版本记录，将下载 $latest_version"
		elif [[ "$current_version" != "$latest_version" ]]; then
			needs_download=true
			msg="有新版本 $current_version -> $latest_version"
		else
			item.format 1 "$package: 已是最新版本 $current_version"
			((packages_skipped++)) || true
			continue
		fi

		item.format 1 "$package: $msg"

		if [[ "$needs_download" == "true" ]]; then
			if [[ "$downloaded" == "true" && -n "$current_version" ]]; then
				if [[ -n "$file_extension" ]]; then
					old_file="${package}-${current_version}.${file_extension}"
				else
					old_file="${package}-${current_version}"
				fi
				if [[ -f "$SETTINGS_DOWNLOAD_DIR/$old_file" ]]; then
					backup_file "$package" "$current_version" "$old_file" >/dev/null
				fi
			fi

			if [[ -n "$file_extension" ]]; then
				filename="${package}-${latest_version}.${file_extension}"
			else
				filename="${package}-${latest_version}"
			fi
			output_file="$SETTINGS_DOWNLOAD_DIR/$filename"

			item.format 1 "[下载] $filename"
			if download_file "$download_url" "$output_file"; then
				item.format 1 "[完成] 下载成功"
				save_version_info "$package" "$latest_version" "true"
			else
				item.format 1 "$package: 下载失败"
				rm -f "$output_file"
			fi
		fi
	done

	console.stdout "========="
	local total=${#packages_to_upgrade[@]}
	local updated=$((total - packages_skipped))
	if [[ $total -gt 0 ]]; then
		console.stdout "共 $total 个包，$updated 个已更新，$packages_skipped 个跳过"
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

# Command: edit - 使用系统编辑器编辑配置文件
cmd_edit() {
	args.init
	args.process "$@"

	local -r config_path=$(config.path)

	# Create default config if it doesn't exist
	if [[ ! -f "$config_path" ]]; then
		create_default_config "$config_path"
	fi

	log.debug "配置文件: $config_path"

	# Open the editor
	"${EDITOR:-vi}" "$config_path" || ( log.error "编辑器打开失败: ${EDITOR:-vi} $config_path" && exit 1 )
}

# Main entry point
main() {
	args.name "$SCRIPT_NAME"
	args.init 命令行程序下载管理器

	args.add_options "version" "v" "显示版本信息"
	args.add_subcommand "list" "列出项目" "cmd_list"
	args.add_subcommand "update" "检查更新" "cmd_update"
	args.add_subcommand "upgrade" "下载二进制文件包" "cmd_upgrade"
	args.add_subcommand "install" "安装二进制文件" "cmd_install"
	args.add_subcommand "edit" "编辑配置文件" "cmd_edit"

	config.register "download_dir" "downloads" "string" "下载目录"
	config.register "proxy_prefix"
	config.register "log_level" "info"
	config.array.register "packages" "repo"
	config.array.register "packages" "file_pattern"
	config.array.register "packages" "file_extension"
	config.array.register "packages" "binary_name"
	config.array.register "packages" "current_version"
	config.array.register "packages" "latest_version"
	config.array.register "packages" "download_url"
	config.array.register "packages" "downloaded"

	config.load
	SETTINGS_DOWNLOAD_DIR="$(config.get "download_dir")"
	SETTINGS_PROXY_PREFIX=$(config.get proxy_prefix)
	VERSIONS_FILE="$SETTINGS_DOWNLOAD_DIR/versions.toml"
	[[ -f "$VERSIONS_FILE" ]] || touch "$VERSIONS_FILE"
	config.load "$VERSIONS_FILE"
	log.setLevel $(config.get log_level)

	args.process "$@"
	args.has "-v" "--version" && usage.version && exit 0
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
