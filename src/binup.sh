#!/usr/bin/env bash
# shellcheck disable=SC2034

set -euo pipefail
SCRIPT_NAME="BinUp"
VERSION="2.2.0"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

import std/system
import std/console
import std/fs
import core/log
import core/args
import core/config
import ext/requests

get_package_property() { config.array.get "packages" "$1" "$2"; }

# 架构正则映射
_get_arch_regex() {
	case "$(system.arch)" in
	amd64) echo "(x86_64|x64|amd64)" ;;
	arm64) echo "(aarch64|arm64)" ;;
	armhf) echo "(armv7l|armhf|armv7hl|armv7l-unknown)" ;;
	i386) echo "(i686|i386|i586)" ;;
	*) system.arch ;;
	esac
}

# 构建匹配模式
_build_pattern() {
	local pattern="$1"
	pattern="${pattern//\{os\}/$(system.os)}"
	pattern="${pattern//\{arch\}/$(_get_arch_regex)}"
	pattern="${pattern//\*/.*}"
	pattern="${pattern//\?/.}"
	[[ -n ${2:-} ]] && echo "${pattern}[.][^.]*${2}$" || echo "${pattern}$"
}

# 获取 GitHub Release
_github_fetch_release() {
	local response=$(requests.get "https://api.github.com/repos/$1/releases")
	requests.raise_for_status "$response" || return 1
	[[ ${2:-release} == "release" ]] && requests.json "$response" '[.[] | select(.prerelease == false)][0]' || requests.json "$response" '.[0]'
}

# 获取最新版本和下载 URL (输出: VERSION|||URL)
get_latest_version_and_url() {
	local latest=$(_github_fetch_release "$1" "${2:-release}") || return 1
	local version=$(echo "$latest" | jq -r '.tag_name // .name')
	[[ $version =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]] && version="${BASH_REMATCH[1]}"
	[[ -z $version || $version == "null" ]] && return 1

	local pattern=$(_build_pattern "$3" "${4:-}")
	local url=$(echo "$latest" | jq -r ".assets[] | select(.name | test(\"$pattern\"; \"i\")) | .browser_download_url" | head -1)
	log.debug "Matching regex: $pattern"

	[[ -z $url || $url == "null" ]] && return 1

	echo "${version}|||${url}"
}

# 保存最新版本信息
save_latest_info() {
	[[ $# -lt 3 ]] && return 1
	if system.command.exist "yq"; then
		[[ -s $VERSIONS_FILE ]] || echo "[packages]" > "$VERSIONS_FILE"
		yq -o toml -i ".packages.$1.latest_version = \"$2\" | .packages.$1.download_url = \"$3\"" "$VERSIONS_FILE"
	else
		config.update "packages" "$1" "latest_version" "$2" "$VERSIONS_FILE"
		config.update "packages" "$1" "download_url" "$3" "$VERSIONS_FILE"
	fi
}

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

cmd_update() {
	args.init
	args.process "$@"

	# 初始化
	requests.init "-4" 2> /dev/null || { log.error "Failed to initialize requests module" && exit 1; }

	[[ -n ${GITHUB_TOKEN:-} ]] && requests.headers.append "Authorization" "token $GITHUB_TOKEN"

	console.section "检查更新"

	local has_updates=false

	for package in $(config.array.items "packages"); do
		# 批量获取包属性
		local -a props=()
		for prop in repo version_type file_pattern file_extension current_version; do
			props+=("$(get_package_property "$package" "$prop")")
		done
		local repo="${props[0]}" version_type="${props[1]}" file_pattern="${props[2]}" \
			file_extension="${props[3]}" current_version="${props[4]}"

		# 获取云端最新信息
		local latest_info=$(get_latest_version_and_url "$repo" "$version_type" "$file_pattern" "$file_extension") || {
			console.item.title 1 "$package: 获取版本失败"
			continue
		}

		local latest_version="${latest_info%%|||*}" download_url="${latest_info#*|||}"
		[[ -z $latest_version || -z $download_url ]] && {
			console.item.title 1 "$package: 获取版本信息失败"
			continue
		}

		# 保存并显示状态
		save_latest_info "$package" "$latest_version" "$download_url"
		has_updates=true

		if [[ -z $current_version ]]; then
			console.item.title 1 "$package: 未下载 (最新: $latest_version)"
		elif [[ $current_version != "$latest_version" ]]; then
			console.item.title 1 "$package: 有新版本 $current_version $POWERLINE_POINTING_ARROW  $latest_version"
		else
			console.item.title 1 "$package: 已是最新版本 $current_version"
			has_updates=false
		fi
	done

	[[ $has_updates == "true" ]] && {
		console.footer '运行 `./bin-updater.sh upgrade` 下载更新'
	}
}

cmd_upgrade() {
	args.init
	args.add_options "arg" "待更新的二进制包" "可选：指定需要更新的二进制包名，支持多个包名"
	args.process "$@"

	# 初始化
	requests.init 2> /dev/null || { log.error "Failed to initialize requests module" && exit 1; }

	local -n target_packages=$(args.args)
	local packages_to_upgrade=()

	if [[ ${#target_packages[@]} -eq 0 ]]; then
		IFS=" " read -r -a packages_to_upgrade <<< "$(config.array.items "packages")"
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

cmd_edit() {
	args.init
	args.process "$@"

	local -r config_path=$(config.path)

	# Create default config if it doesn't exist
	if [[ ! -f $config_path ]]; then
		create_default_config "$config_path"
	fi

	log.debug "配置文件: $config_path"

	# Open the editor
	"${EDITOR:-vi}" "$config_path" || (log.error "编辑器打开失败: ${EDITOR:-vi} $config_path" && exit 1)
}

main() {
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
	config.array.register "packages" "version_type" ""
	config.array.register "packages" "file_pattern"
	config.array.register "packages" "file_extension"
	config.array.register "packages" "binary_name"
	config.array.register "packages" "current_version"
	config.array.register "packages" "latest_version"
	config.array.register "packages" "download_url"

	config.load
	SETTINGS_DOWNLOAD_DIR="$(config.get "download_dir")"
	SETTINGS_PROXY_PREFIX=$(config.get proxy_prefix)
	VERSIONS_FILE="$SETTINGS_DOWNLOAD_DIR/versions.toml"
	[[ -f $VERSIONS_FILE ]] || touch "$VERSIONS_FILE"
	config.load "$VERSIONS_FILE"
	log.setLevel "$(config.get log_level)"

	args.process "$@"
	args.has "-v" "--version" && usage.version && exit 0
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	main "$@"
fi
