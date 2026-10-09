#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

import core/args
import core/log
import core/config
import ext/requests
import std/array
import std/console
import std/console.layout
import common
import registry

cmd_search() {
	args.init
	args.add_options "arg" "搜索关键词，留空列出全部" "可选：多个关键词按 AND 匹配包名/仓库/说明"
	args.add_options "refresh" "r" "忽略缓存有效期，强制刷新包目录"
	args.process "$@"

	github_token
	requests.available || {
		log.error "缺少依赖：curl 或 jq"
		exit 1
	}
	requests.init 2> /dev/null

	local -n keywords="$(args.args)"
	local url ttl
	url=$(registry_source)
	ttl="$(config.get registry_ttl)"
	[[ $ttl =~ ^[0-9]+$ ]] || ttl="$DEFAULT_REGISTRY_TTL"
	args.has "-r" "--refresh" && ttl=0

	console.layout.section "搜索包目录"

	registry_ensure "$url" "$((ttl * 3600))" || return 1

	local -a names=() hits=()
	mapfile -t names < <(registry_names "$url")

	local name lower keyword matched
	local repo description
	for name in "${names[@]}"; do
		# 直接读解析好的 _REGISTRY_ENTRIES：每个包 4 次 $( ) 会把 search 拖成 N 倍的 fork 开销
		repo="${_REGISTRY_ENTRIES["packages.$name.repo"]:-}"
		description="${_REGISTRY_ENTRIES["packages.$name.description"]:-}"
		lower="${name,,} ${repo,,} ${description,,}"
		matched=true
		for keyword in "${keywords[@]}"; do
			[[ $lower == *"${keyword,,}"* ]] || {
				matched=false
				break
			}
		done
		[[ $matched == true ]] && hits+=("$name")
	done

	if ((${#hits[@]} == 0)); then
		console.layout.footer "没有匹配的包"
		return 0
	fi

	local status
	for name in "${hits[@]}"; do
		repo="${_REGISTRY_ENTRIES["packages.$name.repo"]:-}"
		description="${_REGISTRY_ENTRIES["packages.$name.description"]:-}"
		if is_package_in_default_config_with_repo "$name"; then
			status=" $POWERLINE_OK 已配置"
		else
			status=""
		fi
		console.layout.item.title 0 "$POWERLINE_STAR $name$status"

		local -a details=()
		[[ -n $repo ]] && details+=("仓库: $repo")
		[[ -n $description ]] && details+=("说明: $description")

		local i
		for ((i = 0; i < ${#details[@]}; i++)); do
			if ((i == ${#details[@]} - 1)); then
				console.layout.item.end "${details[i]}"
			else
				console.layout.item.mid "${details[i]}"
			fi
		done
		((${#details[@]})) || echo ""
	done
	console.layout.footer "共 ${#hits[@]} 个包，运行 \`$_USAGE_SCRIPT_FILENAME add <包名>\` 添加到本地配置"
	return 0
}
