#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

import core/args
import core/log
import core/config.persist
import ext/requests
import std/array
import std/console
import std/console.layout
import common
import registry

cmd_add() {
	args.init
	args.add_options "arg" "待添加的包名" "必填：指定需要添加的包名，支持多个包名"
	args.add_options "force" "f" "覆盖已存在的本地配置"
	args.process "$@"

	github_token
	requests.init 2> /dev/null || {
		log.error "Failed to initialize requests module"
		exit 1
	}

	local -n targets="$(args.args)"
	((${#targets[@]})) || {
		log.error "请指定包名: $_USAGE_SCRIPT_FILENAME add <包名>"
		return 1
	}

	local url ttl
	url=$(registry_source)
	ttl="$(config.get registry_ttl)"
	[[ $ttl =~ ^[0-9]+$ ]] || ttl="$DEFAULT_REGISTRY_TTL"
	registry_ensure "$url" "$((ttl * 3600))" || return 1

	local config_file
	config_file="$(config.path)" || return 1
	# readlink -f：配置常是 dotbot 软链，sed -i 会把软链替换成普通文件，先解析到真实路径再就地更新
	config_file="$(readlink -f "$config_file")"
	log.debug "本地配置: $config_file"

	console.layout.section "添加包"

	local -a names=()
	mapfile -t names < <(registry_names "$url")

	local package field value count=0
	for package in "${targets[@]}"; do
		if ! array.contains names "$package"; then
			if registry.name.valid "$package"; then
				log.error "包目录中不存在: $package"
				log.error "运行 \`$_USAGE_SCRIPT_FILENAME search\` 查看可用包"
			else
				log.error "包名非法（只允许字母/数字/下划线/连字符）: $package"
			fi
			continue
		fi
		if is_package_in_default_config_with_repo "$package" && ! args.has "-f" "--force"; then
			log.warn "$package 已在本地配置中（-f 覆盖）"
			continue
		fi

		local written=0
		for field in "${REGISTRY_FIELDS[@]}"; do
			value="$(registry_get "$url" "$package" "$field")"
			[[ -n $value ]] || continue
			if ! registry_safe_value "$value"; then
				log.error "$package.$field 含非法字符，已跳过: $value"
				continue
			fi
			config.persist.update "packages" "$package" "$field" "$value" "$config_file" || continue
			((written++)) || true
		done
		if ((written == 0)); then
			log.error "$package: 没有字段通过校验，未写入配置"
			continue
		fi
		console.layout.item.title 0 "$POWERLINE_OK $package 已写入本地配置"
		((count++)) || true
	done

	((count > 0)) || {
		log.error "没有包被写入本地配置"
		return 1
	}
	package_reset_cache
	console.layout.footer "运行 \`$_USAGE_SCRIPT_FILENAME update\` 检查版本，再 \`upgrade\` 下载"
	return 0
}
