#!/usr/bin/env bash

import std/fs
import std/system
import ext/requests

# 下载文件（支持代理前缀，自动选择工具）
download_file() {
	local url="$1"
	local output_file="$2"

	# 如果配置了代理前缀，修改 URL
	local actual_url="$url"
	if [[ -n "$SETTINGS_PROXY_PREFIX" ]]; then
		actual_url="${SETTINGS_PROXY_PREFIX}${url#https://github.com/}"
	fi

	# 输出下载 URL
	log.debug "[URL] $actual_url"

	requests.download "$actual_url" "$output_file"
}

# 备份文件到 downloads/backups 目录（使用移动而非复制）
backup_file() {
	local package="$1"
	local version="$2"
	local filename="$3"

	local source_file="$SETTINGS_DOWNLOAD_DIR/$filename"
	local backup_dir="$SETTINGS_DOWNLOAD_DIR/backups"
	local timestamp=$(date +%Y%m%d-%H%M%S)

	# 检查文件名是否有后缀
	if [[ "$filename" =~ \. ]]; then
		local backup_file="${backup_dir}/${package}-${version}-${timestamp}.${filename##*.}"
	else
		# 无后缀文件
		local backup_file="${backup_dir}/${package}-${version}-${timestamp}"
	fi

	mkdir -p "$backup_dir"
	mv "$source_file" "$backup_file"
	log.debug "[Backup] $backup_file"
}

# 解压文件
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
