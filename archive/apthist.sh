#!/usr/bin/env bash
# shellcheck disable=SC2034

set -euo pipefail
SCRIPT_NAME="AptHist"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

import std/ansi
import std/string
import std/console
import core/log
import core/args

declare -g _APT_LOG="/var/log/apt/history.log"
declare -gi _DAYS=7 _SHOW_AUTO=0 _SHOW_REMOVED=0
declare -g _START_DATE=""

_parse_pkg_name() {
	local pkg="${1%% (*}"
	string.trim "${pkg%%:*}"
}

_is_auto_install() { [[ $1 == *", automatic)" ]]; }

_split_pkg_entries() {
	local line="$1"
	local -n _entries_ref="$2"
	local entry

	line="${line#Install: }"
	line="${line#Remove: }"
	line="${line#Purge: }"
	line="${line%), }"

	_entries_ref=()
	while [[ -n $line ]]; do
		entry="${line%%), *}"
		if [[ $entry == "$line" ]]; then
			[[ -n $line ]] && _entries_ref+=("$line")
			break
		fi
		_entries_ref+=("$entry)")
		line="${line#*), }"
	done
}

_parse_apt_log_state() {
	local -n _final_state_ref="$1"
	local line date
	local -a entries
	local pkg auto_flag

	while IFS= read -r line; do
		case "$line" in
			"Start-Date: "*)
				date="${line#Start-Date: }"
				date="${date%% *}"
				;;
			"Install: "*)
				[[ $date < $_START_DATE ]] && continue
				_split_pkg_entries "$line" entries
				for entry in "${entries[@]}"; do
					pkg="$(_parse_pkg_name "$entry")"
					[[ -z $pkg ]] && continue
					auto_flag=$(_is_auto_install "$entry" && echo 1 || echo 0)
					_final_state_ref["$pkg"]="$date|$auto_flag|1"
				done
				;;
			"Remove: "* | "Purge: "*)
				[[ $date < $_START_DATE ]] && continue
				_split_pkg_entries "$line" entries
				for entry in "${entries[@]}"; do
					pkg="$(_parse_pkg_name "$entry")"
					[[ -n $pkg ]] && _final_state_ref["$pkg"]="$date|0|0"
				done
				;;
		esac
	done < "$_APT_LOG"
}

display_packages() {
	local title="$1"
	local date_color="$2"
	local -n _packages_ref="$3"

	console.section "$title"

	[[ ${#_packages_ref[@]} -eq 0 ]] && console.align 50 "  ${BRIGHT_BLACK}无结果${NC}" "" && return

	for pkg_name in "${!_packages_ref[@]}"; do
		local data="${_packages_ref[$pkg_name]}"
		local date="${data%%|*}"
		local auto_flag="${data#*|}"
		((auto_flag)) && auto_flag="${YELLOW} (自动)" || auto_flag=""
		console.align 50 "  ${BRIGHT_CYAN}$pkg_name${NC}" "${date_color}${date}${NC}${auto_flag}${NC}"
	done
}

get_packages() {
	local -n _packages_ref="$1"

	declare -A final_state=()
	_parse_apt_log_state final_state

	_packages_ref=()
	for pkg in "${!final_state[@]}"; do
		local pkg_status="${final_state[$pkg]##*|}"
		# 跳过不符合模式的包：安装包状态应为1，卸载包状态应为0
		((pkg_status == _SHOW_REMOVED)) && continue

		local data="${final_state[$pkg]%|*}"

		# 只有在显示安装包且不显示自动包时才检查是否为自动包
		((_SHOW_REMOVED == 0 && _SHOW_AUTO == 0 && ${data#*|})) && continue

		_packages_ref["$pkg"]="$data"
	done
}

validate_apt_log() {
	[[ -f $_APT_LOG && -r $_APT_LOG ]] || {
		log.error "找不到或无法读取 apt 日志文件: $_APT_LOG"
		return 1
	}
	head -20 "$_APT_LOG" | grep -q "Start-Date:" || log.warn "日志文件格式可能不正确，继续处理..."
}

main() {
	args.init "分析最近安装/卸载的软件包"

	args.add_options "days" "d" "分析最近多少天的记录 (默认: 7)" "DAYS"
	args.add_options "log" "l" "apt 日志文件路径 (默认: /var/log/apt/history.log)" "FILE"
	args.add_options "auto" "a" "显示自动安装的包"
	args.add_options "removed" "r" "显示已卸载的包"
	args.add_options "help" "h" "显示帮助信息"

	args.add_options "EXAMPLE" "-d 7" "分析最近7天安装的手动包"
	args.add_options "EXAMPLE" "-d 14 -a" "分析最近14天安装的所有包"
	args.add_options "EXAMPLE" "-d 7 -r" "分析最近7天卸载的包"

	args.add_options "NOTICE" "默认只显示当前仍然安装且手动安装的包"

	args.process "$@"

	_DAYS=$(args.get "-d" "--days") 2> /dev/null || _DAYS=7
	_APT_LOG=$(args.get "-l" "--log") 2> /dev/null || _APT_LOG="/var/log/apt/history.log"
	args.has "-a" "--auto" && _SHOW_AUTO=1
	args.has "-r" "--removed" && _SHOW_REMOVED=1

	validate_apt_log || exit 1
	_START_DATE=$(date -d "-${_DAYS} days" +"%Y-%m-%d" 2> /dev/null) || _START_DATE="1970-01-01"

	# 直接处理日志信息和显示
	((_SHOW_REMOVED)) && log.info "分析最近 ${_DAYS} 天的卸载记录..." || log.info "分析最近 ${_DAYS} 天的安装记录..."
	log.info "开始日期: $_START_DATE"

	# 获取包数据
	declare -A packages=()
	get_packages packages

	# 直接显示
	((_SHOW_REMOVED)) && display_packages "已卸载的软件包" "${BRIGHT_RED}" packages || display_packages "安装的软件包" "${BRIGHT_GREEN}" packages
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	main "$@"
fi
