#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2004,SC2178

set -euo pipefail
SCRIPT_NAME="AptHist"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

# 包目录的本地环境（在 import 之前加载：core/log 在顶层读 _LOG_LEVEL）
.env

import std/ansi
import std/string
import std/console
import std/console.layout
import core/log
import core/args

declare -g _DAYS=7
declare -gi _SHOW_AUTO=0 _SHOW_REMOVED=0
declare -g _START_DATE=""
declare -g _LOG_OVERRIDE=""

# ===== 解析工具 =====

# "pkg:arch (ver, automatic)" -> "pkg"
_parse_pkg_name() {
	local pkg="${1%% (*}"
	string.trim "${pkg%%:*}"
}

_is_auto_install() { [[ $1 == *", automatic)" ]]; }

# 拆分 "a (1.0), b (2.0, automatic)"；分隔符是 "), "（版本串内的 ", " 不算）
_split_pkg_entries() {
	local rest="$1"
	local -n _out="$2"
	local piece
	_out=()
	while [[ $rest == *"), "* ]]; do
		piece="${rest%%), *})"
		_out+=("$piece")
		rest="${rest#*), }"
	done
	[[ -n $rest ]] && _out+=("$rest")
}

# ===== 日志文件发现与读取 =====

# 输出可读的 $1 及其轮转（最旧 -> 最新）
_log_candidates() {
	local base="$1" f
	local -a found=()
	for f in "$base" "$base".[0-9]*; do
		[[ -r $f ]] && found+=("$f")
	done
	((${#found[@]})) && printf '%s\n' "${found[@]}" | sort -Vr
	return 0
}

_cat_logs() {
	local f
	for f in "$@"; do
		[[ $f == *.gz ]] && gzip -dc "$f" 2> /dev/null || cat "$f"
	done
}

# ===== 日志解析（填充 nameref 关联数组: pkg -> "date|auto|status"）=====

_parse_history_stream() {
	local -n _st="$1"
	local line date pkg entry
	local -a entries=()
	while IFS= read -r line; do
		case "$line" in
			"Start-Date: "*)
				date="${line#Start-Date: }"
				date="${date%% *}"
				;;
			"Install: "*)
				[[ $date < $_START_DATE ]] && continue
				_split_pkg_entries "${line#Install: }" entries
				for entry in "${entries[@]}"; do
					pkg=$(_parse_pkg_name "$entry")
					[[ -n $pkg ]] || continue
					_is_auto_install "$entry" && _st[$pkg]="$date|1|1" || _st[$pkg]="$date|0|1"
				done
				;;
			"Remove: "* | "Purge: "*)
				[[ $date < $_START_DATE ]] && continue
				_split_pkg_entries "${line#*: }" entries
				for entry in "${entries[@]}"; do
					pkg=$(_parse_pkg_name "$entry")
					[[ -n $pkg ]] && _st[$pkg]="$date|0|0"
				done
				;;
		esac
	done
}

_parse_dpkg_stream() {
	local -n _st="$1"
	local line d _t action rest pkg
	while IFS= read -r line; do
		read -r d _t action rest <<< "$line"
		[[ $d < $_START_DATE ]] && continue
		case "$action" in
			install)
				pkg="${rest%% *}"
				pkg="${pkg%%:*}"
				[[ -n $pkg ]] && _st[$pkg]="$d|0|1"
				;;
			remove | purge)
				pkg="${rest%% *}"
				pkg="${pkg%%:*}"
				[[ -n $pkg ]] && _st[$pkg]="$d|0|0"
				;;
		esac
	done
}

# 主源 history.log（含轮转），缺失时回退 dpkg.log
_parse_log_state() {
	local -a files=()

	if [[ -n $_LOG_OVERRIDE ]]; then
		[[ -r $_LOG_OVERRIDE ]] || return 1
		_parse_history_stream "$1" < <(_cat_logs "$_LOG_OVERRIDE")
		return 0
	fi

	mapfile -t files < <(_log_candidates "/var/log/apt/history.log")
	if ((${#files[@]})); then
		_parse_history_stream "$1" < <(_cat_logs "${files[@]}")
		return 0
	fi

	mapfile -t files < <(_log_candidates "/var/log/dpkg.log")
	((${#files[@]})) || return 1
	log.warn "未找到 apt history.log，回退解析 dpkg.log（无 auto 标记）"
	_parse_dpkg_stream "$1" < <(_cat_logs "${files[@]}")
	return 0
}

# ===== 数据整理与显示 =====

get_packages() {
	local -n _packages_ref="$1"
	declare -A final_state=()
	_parse_log_state final_state || return 1

	_packages_ref=()
	local pkg data status auto
	for pkg in "${!final_state[@]}"; do
		data="${final_state[$pkg]}"
		auto="${data#*|}"
		auto="${auto%%|*}"
		status="${data##*|}"
		((status == _SHOW_REMOVED)) && continue
		((_SHOW_REMOVED == 0 && _SHOW_AUTO == 0 && auto)) && continue
		_packages_ref["$pkg"]="${data%|*}"
	done
	return 0
}

display_packages() {
	local title="$1" date_color="$2"
	local -n _pkgs="$3"
	console.layout.section "$title"

	[[ ${#_pkgs[@]} -eq 0 ]] && {
		console.align 50 "  ${BRIGHT_BLACK}无结果${NC}" ""
		return 0
	}

	# 按最长包名动态决定左栏宽度（2 缩进 + 2 间隔）
	local width=0 name len
	for name in "${!_pkgs[@]}"; do
		len=$((${#name} + 4))
		((len > width)) && width=$len
	done

	local d auto suffix
	while IFS=$'\t' read -r d name auto; do
		[[ -n $name ]] || continue
		suffix=""
		((auto)) && suffix="${YELLOW} (自动)${NC}"
		console.align "$width" "  ${BRIGHT_CYAN}${name}${NC}" "${date_color}${d}${NC}${suffix}"
	done < <(
		for name in "${!_pkgs[@]}"; do
			printf '%s\t%s\t%s\n' "${_pkgs[$name]%%|*}" "$name" "${_pkgs[$name]#*|}"
		done | sort
	)
}

main() {
	args.init "分析最近安装/卸载的软件包"

	args.add_options "days" "d" "分析最近多少天的记录 (默认: 7)" "DAYS"
	args.add_options "log" "l" "apt 日志文件路径 (指定时覆盖多源探测)" "FILE"
	args.add_options "auto" "a" "显示自动安装的包"
	args.add_options "removed" "r" "显示已卸载的包"

	args.add_options "EXAMPLE" "-d 7" "分析最近7天安装的手动包"
	args.add_options "EXAMPLE" "-d 14 -a" "分析最近14天安装的所有包"
	args.add_options "EXAMPLE" "-d 7 -r" "分析最近7天卸载的包"

	args.add_options "NOTICE" "默认只显示当前仍然安装且手动安装的包"

	args.process "$@"

	_DAYS=$(args.get "-d" "--days") 2> /dev/null || _DAYS=7
	string.natural.check "$_DAYS" || _DAYS=7
	_LOG_OVERRIDE=$(args.get "-l" "--log") 2> /dev/null || _LOG_OVERRIDE=""
	args.has "-a" "--auto" && _SHOW_AUTO=1 || true
	args.has "-r" "--removed" && _SHOW_REMOVED=1 || true

	_START_DATE=$(date -d "-${_DAYS} days" +"%Y-%m-%d" 2> /dev/null) || _START_DATE="1970-01-01"

	((_SHOW_REMOVED)) && log.info "分析最近 ${_DAYS} 天的卸载记录..." || log.info "分析最近 ${_DAYS} 天的安装记录..."
	log.info "开始日期: $_START_DATE"

	declare -A packages=()
	get_packages packages || {
		log.error "未找到可读取的 apt/dpkg 日志"
		[[ -e /var/log/dpkg.log && ! -r /var/log/dpkg.log ]] && log.error "dpkg.log 需要 root 权限，试试 sudo"
		exit 1
	}

	((_SHOW_REMOVED)) && display_packages "已卸载的软件包" "${BRIGHT_RED}" packages || display_packages "安装的软件包" "${BRIGHT_GREEN}" packages
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	main "$@"
fi
