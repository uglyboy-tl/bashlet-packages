#!/usr/bin/env bash

set -euo pipefail
SCRIPT_NAME="Package"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

import std/ansi
import std/console
import core/log
import core/args

# 配置
declare -g _APT_LOG="/var/log/apt/history.log"
declare -gi _DAYS=7 _SHOW_AUTO=0 _SHOW_REMOVED=0
declare -g _START_DATE=""

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

	_DAYS=$(args.get "-d" "--days") 2>/dev/null || _DAYS=7
	_APT_LOG=$(args.get "-l" "--log") 2>/dev/null || _APT_LOG="/var/log/apt/history.log"
	args.has "-a" "--auto" && _SHOW_AUTO=1
	args.has "-r" "--removed" && _SHOW_REMOVED=1

	[[ -f "$_APT_LOG" ]] || { log.error "找不到 apt 日志文件: $_APT_LOG"; exit 1; }
	_START_DATE=$(date -d "-${_DAYS} days" +"%Y-%m-%d" 2>/dev/null) || _START_DATE="1970-01-01"

	((_SHOW_REMOVED)) && show_removed || show_installed
}

# 显示已安装的包（使用原脚本的mawk逻辑，但保持优化脚本的结构）
show_installed() {
	log.info "分析最近 ${_DAYS} 天的安装记录..."
	log.info "开始日期: $_START_DATE"

	printf "\n${BRIGHT_BLUE}安装的软件包:${NC}\n"
	printf "${BRIGHT_BLACK}==============${NC}\n"

	# 使用原脚本验证过的mawk逻辑
	local output
	output=$(mawk -v start_date="$_START_DATE" -v show_auto="$_SHOW_AUTO" '
	BEGIN {
		delete installed
		delete is_auto
	}

	/^Start-Date:/ { date = $2 }

	/^Install:/ {
		line = substr($0, 9)
		gsub(/ \([0-9][^)]*, automatic\)/, " PLACEHOLDER_AUTO", line)
		gsub(/ \([0-9][^)]*\)/, " PLACEHOLDER_MANUAL", line)
		n = split(line, parts, ",")
		for (i = 1; i <= n; i++) {
			pkg = parts[i]
			gsub(/^[ \t]+|[ \t]+$/, "", pkg)
			if (pkg == "") continue

			auto = 0
			if (pkg ~ /PLACEHOLDER_AUTO/) {
				auto = 1
				gsub(/ PLACEHOLDER_AUTO$/, "", pkg)
			} else {
				gsub(/ PLACEHOLDER_MANUAL$/, "", pkg)
			}

			if (pkg == "") continue
			sub(/:[a-z0-9]+$/, "", pkg)

			if (date >= start_date) {
				installed[pkg] = date
				is_auto[pkg] = auto
			}
		}
	}

	/^(Purge:|Remove:)/ {
		line = $0
		sub(/^(Purge:|Remove:)[ \t]*/, "", line)
		n = split(line, parts, ",")
		for (i = 1; i <= n; i++) {
			pkg = parts[i]
			gsub(/^[ \t]+|[ \t]+$/, "", pkg)
			if (pkg == "") continue
			gsub(/ \([0-9][^)]*\)/, "", pkg)
			if (pkg == "") continue
			sub(/:[a-z0-9]+$/, "", pkg)
			delete installed[pkg]
			delete is_auto[pkg]
		}
	}

	END {
		for (pkg in installed) {
			if (show_auto || !is_auto[pkg]) {
				marker = ""
				if (is_auto[pkg]) marker = " (自动)"
				printf "%s %s%s\n", pkg, installed[pkg], marker
			}
		}
	}
	' "$_APT_LOG" | sort -k2,2 -k1)

	# 使用优化脚本的格式化输出
	if [[ -n "$output" ]]; then
		while IFS=' ' read -r pkg date marker; do
			# 处理可能的自动标记
			local color_marker=""
			if [[ "$marker" == "(自动)" ]]; then
				color_marker="${YELLOW} (自动)${NC}"
			fi
			console.align 50 "  ${BRIGHT_CYAN}$pkg${NC}" "${BRIGHT_GREEN}$date${NC}$color_marker"
		done <<< "$output"
	else
		console.align 50 "  ${BRIGHT_BLACK}无结果${NC}" ""
	fi
}

# 显示已卸载的包（使用原脚本的mawk逻辑，但保持优化脚本的结构）
show_removed() {
	log.info "分析最近 ${_DAYS} 天的卸载记录..."
	log.info "开始日期: $_START_DATE"

	printf "\n${BRIGHT_BLUE}已卸载的软件包:${NC}\n"
	printf "${BRIGHT_BLACK}==============${NC}\n"

	# 使用原脚本验证过的mawk逻辑
	local output
	output=$(mawk -v start_date="$_START_DATE" '
	BEGIN {
		# 获取当前已安装的包列表
		while (("dpkg -l" | getline line) > 0) {
			# dpkg -l 格式: ii  pkg-name  version  ...
			if (line ~ /^ii  [a-z]/) {
				split(line, fields)
				pkg_name = fields[2]
				# 去掉架构后缀
				sub(/:[a-z0-9]+$/, "", pkg_name)
				installed[pkg_name] = 1
			}
		}
		close("dpkg -l")
	}

	/^Start-Date:/ { date = $2 }

	/^(Purge:|Remove:)/ {
		line = $0
		sub(/^(Purge:|Remove:)[ \t]*/, "", line)
		n = split(line, parts, ",")
		for (i = 1; i <= n; i++) {
			pkg = parts[i]
			gsub(/^[ \t]+|[ \t]+$/, "", pkg)
			if (pkg == "") continue
			gsub(/ \([0-9][^)]*\)/, "", pkg)
			if (pkg == "") continue
			sub(/:[a-z0-9]+$/, "", pkg)
			# 只记录指定日期之后的卸载，且当前已卸载
			if (date >= start_date && !(pkg in installed)) {
				removed[pkg] = date
			}
		}
	}

	END {
		for (pkg in removed) {
			printf "%s %s\n", pkg, removed[pkg]
		}
	}
	' "$_APT_LOG" | sort -k2,2 -k1)

	# 使用优化脚本的格式化输出
	if [[ -n "$output" ]]; then
		while IFS=' ' read -r pkg date; do
			console.align 50 "  ${BRIGHT_CYAN}$pkg${NC}" "${BRIGHT_RED}$date${NC}"
		done <<< "$output"
	else
		console.align 50 "  ${BRIGHT_BLACK}无结果${NC}" ""
	fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi