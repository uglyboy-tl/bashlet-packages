#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

import core/args
import core/log
import core/config.persist
import ext/requests
import ext/github
import std/fs
import std/console
import std/console.layout
import common

_save_version_info() {
	[[ -z $1 ]] && return 1
	config.persist.update "packages" "$1" "current_version" "$2" "$VERSIONS_FILE"
}

# ===== 下载与备份 =====

_download_file() {
	local url
	url=$(github.url.proxied "$1" "${SETTINGS_PROXY_PREFIX:-}")
	log.debug "[URL] $url"
	requests.download "$url" "$2"
}

_backup_file() {
	local package="$1" version="$2" filename="$3" ext="${4:-}"
	local source_file="$SETTINGS_DOWNLOAD_DIR/$filename"
	local backup_dir="$SETTINGS_DOWNLOAD_DIR/backups"
	local timestamp
	timestamp=$(date +%Y.%m.%d)
	local _backup_path="${backup_dir}/${package}-${version}-${timestamp}${ext:+.${ext}}"

	mkdir -p "$backup_dir"
	mv "$source_file" "$_backup_path"
	fs.cleanup "${backup_dir}/${package}-"
	log.debug "[Backup] $_backup_path"
}

cmd_upgrade() {
	args.init
	args.add_options "arg" "待更新的二进制包" "可选：指定需要更新的二进制包名，支持多个包名"
	args.process "$@"

	ensure_download_dir

	requests.available || {
		log.error "缺少依赖：curl 或 jq"
		exit 1
	}
	requests.init 2> /dev/null

	local -n target_packages="$(args.args)"
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

	local packages_skipped=0 packages_failed=0 packages_updated=0
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
			[[ -f "$SETTINGS_DOWNLOAD_DIR/$old_file" ]] && _backup_file "$package" "$current_version" "$old_file" "$file_extension" > /dev/null
		fi

		filename=$(build_filename "$package" "$latest_version" "$file_extension")
		output_file="$SETTINGS_DOWNLOAD_DIR/$filename"

		console.layout.item.item "[下载] $filename"
		if _download_file "$download_url" "$output_file"; then
			console.layout.item.item "[完成] 下载成功"
			_save_version_info "$package" "$latest_version"
			((packages_updated++)) || true
		else
			console.layout.item.item "$package: 下载失败"
			rm -f "$output_file"
			((packages_failed++)) || true
		fi
	done

	local total=${#packages_to_upgrade[@]}
	if ((total > 0)); then
		local summary="共 $total 个包，$packages_updated 个已更新，$packages_skipped 个跳过"
		((packages_failed > 0)) && summary+="，$packages_failed 个失败"
		console.layout.footer "$summary"
	fi

	((packages_failed == 0))
}
