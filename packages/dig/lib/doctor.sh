#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# 探活：遍历源注册表，逐个检查依赖命令与可达性，直接给结论而不是让用户对着空结果猜。
# 探活逻辑归各源自己（<源>.probe），这里只负责调度与排版 —— 加源不需要改本文件。

import core/log
import std/system

import common
import source

doctor.row() { printf '%-8s  %-10s %s\n' "$1" "$2" "$3"; }

doctor.source() {
	local src="$1" cmd
	for cmd in $(source.requires "$src"); do
		system.command.exist "$cmd" || {
			doctor.row "$src" "缺少 $cmd" "先安装 $cmd，再重跑 doctor"
			return 0
		}
	done

	if ! declare -F "${src}.probe" > /dev/null; then
		doctor.row "$src" "无探活" "该源未提供 <源>.probe"
		return 0
	fi

	local detail rc=0
	detail="$("${src}.probe")" || rc=$?
	case $rc in
		0) doctor.row "$src" "ok" "$detail" ;;
		2) doctor.row "$src" "不可达" "${detail:-网络不通}；需代理时设置 DIG_PROXY 或 https_proxy" ;;
		3) doctor.row "$src" "缺前置" "$detail" ;;
		*) doctor.row "$src" "失败" "${detail:-凭证或接口异常}" ;;
	esac
}

doctor.run() {
	doctor.row "源" "状态" "说明"
	printf '%s\n' "------------------------------------------------------------"

	local src
	local -a srcs=()
	mapfile -t srcs < <(source.list)
	for src in "${srcs[@]}"; do
		doctor.source "$src"
	done

	printf '\n'
	log.info "不可达的源若属本机 DNS 污染站点，设置 DIG_PROXY 或 https_proxy 后重跑；源清单见 docs/sources.md"
}
