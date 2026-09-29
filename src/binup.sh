#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

set -euo pipefail
SCRIPT_NAME="BinUp"
VERSION="2.2.0"
PROJECT_ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

import std/system
import std/array
import std/console
import std/console.layout
import std/fs
import std/path
import core/log
import core/args
import core/config
import core/config.persist
import ext/requests

: "${GITHUB_TOKEN:=$(pass "github")}"

# ===== 包属性 =====

get_package_property() { config.array.get "packages" "$1" "$2" || true; }

declare -ga _DEFAULT_REGISTERED_PACKAGES=()
declare -g _DEFAULT_PACKAGES_LOADED=false

# 首次调用时从配置收集「含 repo 字段」的包
_load_registered_packages() {
	[[ $_DEFAULT_PACKAGES_LOADED == true ]] && return 0
	local -a all=()
	read -ra all <<< "$(config.array.items "packages")"
	local key
	for key in "${all[@]}"; do
		config.has "packages.$key.repo" && _DEFAULT_REGISTERED_PACKAGES+=("$key")
	done
	_DEFAULT_PACKAGES_LOADED=true
}

get_default_registered_packages() {
	_load_registered_packages
	((${#_DEFAULT_REGISTERED_PACKAGES[@]})) && printf '%s\n' "${_DEFAULT_REGISTERED_PACKAGES[@]}"
	return 0
}

is_package_in_default_config_with_repo() {
	_load_registered_packages
	array.contains _DEFAULT_REGISTERED_PACKAGES "$1"
}

# ===== 平台与文件名匹配 =====

_get_arch_regex() {
	case "$(system.arch)" in
		amd64) echo "(x86_64|x64|amd64)" ;;
		arm64) echo "(aarch64|arm64)" ;;
		armhf) echo "(armv7l|armhf|armv7hl|armv7l-unknown)" ;;
		i386) echo "(i686|i386|i586)" ;;
		*) system.arch ;;
	esac
}

_build_pattern() {
	local pattern="$1" ext="${2:-}"
	pattern="${pattern//\{os\}/$(system.os)}"
	pattern="${pattern//\{arch\}/$(_get_arch_regex)}"
	pattern="${pattern//\*/.*}"
	pattern="${pattern//\?/.}"
	[[ -n $ext ]] && echo "${pattern}[.][^.]*${ext}$" || echo "${pattern}$"
}

build_filename() { printf '%s' "${1}-${2}${3:+.${3}}"; }

# ===== GitHub 发布 =====

_github_fetch_release() {
	local repo="$1" version_type="${2:-release}" response
	local endpoint="releases/latest" filter="."
	if [[ $version_type != "release" ]]; then
		endpoint="releases"
		filter=".[0]"
	fi
	response=$(requests.get "https://api.github.com/repos/$repo/$endpoint")
	requests.raise_for_status "$response" || return 1
	requests.json "$response" "$filter"
}

# 输出: VERSION|||URL
get_latest_version_and_url() {
	local repo="$1" version_type="${2:-release}" pattern="$3" ext="${4:-}"
	local latest version url build_pattern
	latest=$(_github_fetch_release "$repo" "$version_type") || return 1

	build_pattern=$(_build_pattern "$pattern" "$ext")
	log.debug "Matching regex: $build_pattern"

	local -a fields=()
	mapfile -t fields < <("$_REQUESTS_JQ" -r --arg pat "$build_pattern" '
		(.tag_name // .name // ""),
		(first(.assets[]? | select(.name | test($pat; "i")) | .browser_download_url) // "")
	' <<< "$latest")
	version="${fields[0]:-}"
	url="${fields[1]:-}"

	[[ $version =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]] && version="${BASH_REMATCH[1]}"
	[[ -z $version || $version == "null" || -z $url || $url == "null" ]] && return 1

	echo "${version}|||${url}"
}

# ===== 版本信息持久化 =====

save_latest_info() {
	[[ $# -lt 3 ]] && return 1
	config.persist.update "packages" "$1" "latest_version" "$2" "$VERSIONS_FILE"
	config.persist.update "packages" "$1" "download_url" "$3" "$VERSIONS_FILE"
}

save_version_info() {
	[[ -z $1 ]] && return 1
	config.persist.update "packages" "$1" "current_version" "$2" "$VERSIONS_FILE"
}

# ===== 下载与备份 =====

download_file() {
	local url="${SETTINGS_PROXY_PREFIX:+${SETTINGS_PROXY_PREFIX}${1#https://github.com/}}"
	log.debug "[URL] ${url:-$1}"
	requests.download "${url:-$1}" "$2"
}

backup_file() {
	local package="$1" version="$2" filename="$3" ext="${4:-${3##*.}}"
	local source_file="$SETTINGS_DOWNLOAD_DIR/$filename"
	local backup_dir="$SETTINGS_DOWNLOAD_DIR/backups"
	local timestamp=$(date +%Y.%m.%d)
	local backup_file="${backup_dir}/${package}-${version}-${timestamp}${ext:+.${ext}}"

	mkdir -p "$backup_dir"
	mv "$source_file" "$backup_file"
	fs.cleanup "${backup_dir}/${package}-"
	log.debug "[Backup] $backup_file"
}

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
	console.layout.item.item "[路径] $install_dir 已添加到 PATH"
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

# ===== 子命令 =====

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
		file_path="$SETTINGS_DOWNLOAD_DIR/${package}-${current_version}${file_extension:+.$file_extension}"

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

		download_time=$(stat -c "%.19y" "$file_path" 2> /dev/null || stat -c "%y" "$file_path" 2> /dev/null | cut -d'.' -f1)
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

cmd_update() {
	args.init
	args.process "$@"

	requests.init "-4" 2> /dev/null || {
		log.error "Failed to initialize requests module"
		exit 1
	}
	[[ -n ${GITHUB_TOKEN:-} ]] && requests.headers.append "Authorization" "token $GITHUB_TOKEN"

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

		latest_info=$(get_latest_version_and_url "$repo" "$version_type" "$file_pattern" "$file_extension") || {
			console.layout.item.title 1 "$package: 获取版本失败"
			continue
		}
		latest_version="${latest_info%%|||*}"
		download_url="${latest_info#*|||}"
		[[ -n $latest_version && -n $download_url ]] || {
			console.layout.item.title 1 "$package: 获取版本信息失败"
			continue
		}

		save_latest_info "$package" "$latest_version" "$download_url"

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

cmd_upgrade() {
	args.init
	args.add_options "arg" "待更新的二进制包" "可选：指定需要更新的二进制包名，支持多个包名"
	args.process "$@"

	requests.init 2> /dev/null || {
		log.error "Failed to initialize requests module"
		exit 1
	}

	local -n target_packages=$(args.args)
	local -a packages_to_upgrade=()
	local package

	if ((${#target_packages[@]} == 0)); then
		mapfile -t packages_to_upgrade < <(get_default_registered_packages)
	else
		for package in "${target_packages[@]}"; do
			is_package_in_default_config_with_repo "$package" || {
				log.error "Unknown package: $package"
				log.error "Available packages: $(get_default_registered_packages)"
				exit 1
			}
			packages_to_upgrade+=("$package")
		done
	fi

	local packages_skipped=0
	local file_extension current_version latest_version download_url filename output_file old_file
	console.layout.section "下载更新"

	for package in "${packages_to_upgrade[@]}"; do
		file_extension=$(get_package_property "$package" "file_extension")
		current_version=$(get_package_property "$package" "current_version")
		latest_version=$(get_package_property "$package" "latest_version")
		download_url=$(get_package_property "$package" "download_url")

		[[ -n $latest_version ]] || {
			console.layout.item.title 1 "$package: 没有云端信息，请先运行 \`$_USAGE_SCRIPT_FILENAME update\`"
			continue
		}
		[[ -n $download_url ]] || {
			console.layout.item.title 1 "$package: 没有下载链接，请先运行 \`$_USAGE_SCRIPT_FILENAME update\`"
			continue
		}

		if [[ -z $current_version ]]; then
			console.layout.item.title 1 "$package: 未下载，将下载 $latest_version"
		elif [[ $current_version != "$latest_version" ]]; then
			console.layout.item.title 1 "$package: 有新版本 $current_version $POWERLINE_POINTING_ARROW $latest_version"
		else
			console.layout.item.title 1 "$package: 已是最新版本 $current_version"
			((packages_skipped++)) || true
			continue
		fi

		if [[ -n $current_version ]]; then
			old_file=$(build_filename "$package" "$current_version" "$file_extension")
			[[ -f "$SETTINGS_DOWNLOAD_DIR/$old_file" ]] && backup_file "$package" "$current_version" "$old_file" "$file_extension" > /dev/null
		fi

		filename=$(build_filename "$package" "$latest_version" "$file_extension")
		output_file="$SETTINGS_DOWNLOAD_DIR/$filename"

		console.layout.item.item "[下载] $filename"
		if download_file "$download_url" "$output_file"; then
			console.layout.item.item "[完成] 下载成功"
			save_version_info "$package" "$latest_version"
		else
			console.layout.item.item "$package: 下载失败"
			rm -f "$output_file"
		fi
	done

	local total=${#packages_to_upgrade[@]}
	local updated=$((total - packages_skipped))
	((total > 0)) && console.layout.footer "共 $total 个包，$updated 个已更新，$packages_skipped 个跳过"

	return 0
}

cmd_install() {
	args.init
	args.add_options "arg" "待安装的二进制包" "可选：指定需要安装的二进制包名，支持多个包名"
	args.process "$@"

	local -n target_packages=$(args.args)

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

cmd_edit() {
	args.init
	args.process "$@"

	local config_path
	config_path=$(config.path 2> /dev/null) || config_path="${_CONFIG_PATH:-$(path.config_dir)/config.toml}"
	[[ -f $config_path ]] || create_default_config "$config_path"

	log.debug "配置文件: $config_path"

	"${EDITOR:-vi}" "$config_path" || {
		log.error "编辑器打开失败: ${EDITOR:-vi} $config_path"
		return 1
	}
}

create_default_config() {
	local path="$1" dir="${1%/*}"
	[[ $dir != "$path" ]] && mkdir -p "$dir"
	cat > "$path" << 'EOF'
# BinUp 配置
# 每个包声明在 [packages.<名称>] 段中:
#   repo           = "owner/repo"           # GitHub 仓库
#   version_type   = "release"              # release(默认) | 其他(取 releases 列表首个)
#   file_pattern   = "<名称>-{os}-{arch}*"  # 占位符 {os}/{arch};支持 * 与 ?
#   file_extension = "tar.gz"               # 归档扩展名(可省略)
#   binary_name    = "<名称>"               # 归档内可执行文件名(单文件时可省略)
download_dir = "downloads"
log_level = "info"
EOF
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
	config.register "proxy_prefix" ""
	config.register "log_level" "info"
	config.array.register "packages" "repo"
	config.array.register "packages" "version_type" ""
	config.array.register "packages" "file_pattern"
	config.array.register "packages" "file_extension"
	config.array.register "packages" "binary_name"
	config.array.register "packages" "current_version"
	config.array.register "packages" "latest_version"
	config.array.register "packages" "download_url"

	local main_config
	main_config=$(config.path 2> /dev/null) || main_config=""
	[[ -n $main_config && -f $main_config ]] && config.load "$main_config"
	SETTINGS_DOWNLOAD_DIR="$(config.get "download_dir")"
	SETTINGS_PROXY_PREFIX="$(config.get proxy_prefix)"
	mkdir -p "$SETTINGS_DOWNLOAD_DIR"
	VERSIONS_FILE="$SETTINGS_DOWNLOAD_DIR/versions.toml"
	[[ -f $VERSIONS_FILE ]] || touch "$VERSIONS_FILE"
	config.load "$VERSIONS_FILE" || true
	log.setLevel "$(config.get log_level)"

	args.process "$@"
	args.has "-v" "--version" && usage.version && exit 0
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	main "$@"
fi
