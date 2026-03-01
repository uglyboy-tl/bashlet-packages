#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="Monitor"
VERSION="2.0.0"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

import std/markdown
import std/system
import core/log
import core/args
import core/config
import core/report

DEFAULT_OUTPUT_DIR="logs"
OPT_OUTPUT_DIR=""
OPT_CONFIG_FILE=""
OPT_FORCE_RUN=false
OPT_MAX_AGE_HOURS=24

declare -gA MONITOR_CHECKS=()
declare -gA MONITOR_CACHE=()

run() {
	local result=$(bash -c "$1" 2>&1)
	log.debug "$1 (exit=$?): $result"
	echo "$result"
}

file.age() {
	local name=$(basename "$1" .md)
	local now=$(date +"%Y%m%d_%H%M%S")

	local file_day=${name:0:8}
	local file_time=${name:9:6}
	local now_day=${now:0:8}
	local now_time=${now:9:6}

	local days=$((now_day - file_day))
	local time_val=$((10#${now_time:0:2} * 10000 + 10#${now_time:2:2} * 100 + 10#${now_time:4:2}))
	local file_val=$((10#${file_time:0:2} * 10000 + 10#${file_time:2:2} * 100 + 10#${file_time:4:2}))

	echo $((days * 24 + (time_val - file_val) / 10000))
}

file.fresh() {
	[[ "$OPT_FORCE_RUN" == true ]] && log.info "强制重新采集数据" && return

	local latest_file=$(ls "$OPT_OUTPUT_DIR"/*.md 2>/dev/null | tail -1)
	[[ -z "$latest_file" ]] && log.info "未找到历史记录文件" && return

	local age_hours=$(file.age "$latest_file")
	((age_hours < OPT_MAX_AGE_HOURS)) && log.info "数据有效（${age_hours} 小时前）" && echo "跳过采集（最近报告: $latest_file）" && return 1

	log.info "数据已过期（${age_hours} 小时）"
}

data.cache() { MONITOR_CACHE["$1"]=$(run "$2" 2>/dev/null); }
data.get_cache() { echo "${MONITOR_CACHE["$1"]}"; }

data.vars() {
	local key

	for key in "${!_CONFIG_VALUES[@]}"; do
		[[ "$key" == *".var:"* ]] && data.cache "${key##*.var:}" "${_CONFIG_VALUES[$key]}"
	done
}

data.add() {
	local name="$1"
	local raw_value="$2"
	local cmd unit=""

	# 解析单位分离语法
	[[ "$raw_value" =~ ^\"(.*)\"$ ]] && raw_value="${BASH_REMATCH[1]}"
	[[ "$raw_value" =~ ^(.+)[[:space:]]+::[[:space:]]+(.+)$ ]] && cmd="${BASH_REMATCH[1]}" && unit="${BASH_REMATCH[2]}" || cmd="$raw_value"

	local result
	# 替换 @缓存名 为缓存的命令结果
	while [[ "$cmd" =~ @([a-zA-Z_][a-zA-Z0-9_]*) ]]; do
		local cache_name="${BASH_REMATCH[1]}"
		local cache_value="$(data.get_cache "$cache_name")"
		cmd="${cmd//@${cache_name}/${cache_value}}"
	done
	result=$(run "$cmd")
	result=$(string.trim "$result")
	[[ -n "$unit" && -n "$result" && "$result" != "N/A" && "$unit" != "status" ]] && result="$result $unit"
	MONITOR_CHECKS["${name}"]="${result:-N/A}"
}

data.show() {
	report.table.begin "名称" "值"
	for name in "${!MONITOR_CHECKS[@]}"; do
		report.table.add "$name" "${MONITOR_CHECKS[${name}]:-N/A}"
	done
	report.table.end
	MONITOR_CHECKS=()
}

data.exec() {
	local prefix="$1."
	local key value count=0 has_code=0

	# 再处理普通项和 code 项
	for key in "${!_CONFIG_VALUES[@]}"; do
		if [[ "$key" == "$prefix"* ]] && [[ "$key" != "$prefix"*.* ]]; then
			value="${_CONFIG_VALUES[$key]}"
			key="${key#"$prefix"}"
			if [[ "$key" == "code" ]]; then
				has_code=1
				code_value="$value"
			elif [[ "$key" != var:* ]]; then
				data.add "$key" "$value"
				((count++))
			fi
		fi
	done

	# 显示非 code 项
	((count > 0)) && data.show

	# 执行 code 项
	((has_code > 0)) && report.code "$code_value"

	return 0
}

data.unfold() {
	local -A dynamic_values=()
	local key value

	# 执行所有 dynamic:* 声明并存储结果
	for key in "${!_CONFIG_VALUES[@]}"; do
		if [[ "$key" == dynamic:* ]]; then
			local var_name="${key#dynamic:}"
			value="${_CONFIG_VALUES[$key]}"
			dynamic_values["$var_name"]="$(run "$value")"
			log.debug "Dynamic var $var_name: [${dynamic_values[$var_name]}]" >&2
		fi
	done

	# 如果没有动态变量，直接返回
	[[ ${#dynamic_values[@]} -eq 0 ]] && return 0

	# 展开动态节和项
	local -A new_config=()
	local template_count=0
	local expanded_count=0
	for key in "${!_CONFIG_VALUES[@]}"; do
		# 跳过 dynamic 声明本身
		[[ "$key" == dynamic:* ]] && continue

		value="${_CONFIG_VALUES[$key]}"

		# 检查键名中是否包含动态变量（如 @device）
		if [[ "$key" == *@* ]]; then
			((template_count++))
			# 这是一个动态模板，需要展开
			for var_name in "${!dynamic_values[@]}"; do
				local pattern="@${var_name}"
				if [[ "$key" == *"$pattern"* ]]; then
					# 对每个设备值展开模板
					local devices_list="${dynamic_values[$var_name]}"
					log.debug "Devices list for $var_name: [$devices_list]" >&2
					if [[ -n "$devices_list" ]]; then
						while IFS= read -r item; do
							log.debug "Processing item: [$item]" >&2
							[[ -z "$item" ]] && continue
							local new_key="${key//$pattern/$item}"
							new_config["$new_key"]="${value//$pattern/$item}"
							((expanded_count++))
						done <<<"$devices_list"
					fi
				fi
			done
		else
			# 静态配置项，直接复制
			new_config["$key"]="$value"
		fi
	done

	# 更新全局配置
	_CONFIG_VALUES=()
	for key in "${!new_config[@]}"; do
		_CONFIG_VALUES["$key"]="${new_config[$key]}"
	done
}

data.contitional() {
	local -A new_config=()
	local key value

	# 复制所有现有配置
	for key in "${!_CONFIG_VALUES[@]}"; do
		new_config["$key"]="${_CONFIG_VALUES[$key]}"
	done

	# 收集所有可能的四级节（包含3个点的键）
	local -A four_level_sections=()
	for key in "${!_CONFIG_VALUES[@]}"; do
		if [[ "$key" == *.*.*.* ]]; then
			# 提取节前缀（去掉最后一部分）
			local section_prefix="${key%.*}"
			four_level_sections["$section_prefix"]=1
		fi
	done

	# 处理每个四级节
	for section_prefix in "${!four_level_sections[@]}"; do
		# 解析节前缀
		local section1="${section_prefix%%.*}"
		local remaining="${section_prefix#*.}"
		local section2="${remaining%%.*}"
		local section3="${remaining#*.}"
		local condition_name="$section3"

		log.debug "Processing condition section: $section_prefix -> $condition_name" >&2

		# 获取 condition 值
		local condition_key="$section_prefix.condition"
		if [[ -v "_CONFIG_VALUES[$condition_key]" ]]; then
			local condition_cmd="${_CONFIG_VALUES[$condition_key]}"
			log.debug "Condition command: $condition_cmd" >&2

			# 执行 condition 命令（先进行缓存替换）
			local cmd="$condition_cmd"
			log.debug "Before cache replacement: $cmd" >&2
			while [[ "$cmd" =~ @([a-zA-Z_][a-zA-Z0-9_]*) ]]; do
				local cache_name="${BASH_REMATCH[1]}"
				local cache_value="$(data.get_cache "$cache_name")"
				log.debug "Cache lookup: $cache_name = [$cache_value]" >&2
				cmd="${cmd//@${cache_name}/${cache_value}}"
			done
			log.debug "After cache replacement: $cmd" >&2

			local condition_result=$(run "$cmd")
			log.debug "Condition result: [$condition_result] vs expected: [$condition_name]" >&2

			# 如果 condition 结果匹配条件名，则合并配置
			if [[ "$condition_result" == "$condition_name" ]]; then
				log.debug "Condition matched for $section_prefix, merging items..." >&2
				# 将该条件分支的所有项（除 condition 外）合并到三级节
				for subkey in "${!_CONFIG_VALUES[@]}"; do
					if [[ "$subkey" == "$section_prefix".* ]] && [[ "$subkey" != "$condition_key" ]]; then
						local item_name="${subkey##"$section_prefix."}"
						local target_key="$section1.$section2.$item_name"
						new_config["$target_key"]="${_CONFIG_VALUES[$subkey]}"
						log.debug "Merged: $subkey -> $target_key" >&2
					fi
				done
			else
				log.debug "Condition not matched for $section_prefix" >&2
			fi
		else
			log.debug "No condition found for section: $section_prefix" >&2
		fi
	done

	# 更新全局配置
	_CONFIG_VALUES=()
	for key in "${!new_config[@]}"; do
		_CONFIG_VALUES["$key"]="${new_config[$key]}"
	done
}

output.make() {
	local title
	title=$(config.get "title") || title="检测报告"
	report.init "$title"

	# 处理动态配置
	data.unfold
	# 处理变量声明
	data.vars
	# 处理条件分支
	data.contitional

	mapfile -t sections < <(config.sections | sort)

	for section in "${sections[@]}"; do
		if [[ -n "$section" ]]; then
			# 移除序号前缀用于显示
			local display_name="${section#*-}"
			report.section "$display_name"
			data.exec "$section"

			# 处理子子类别
			mapfile -t subsections < <(config.sections "$section")
			for subsection in "${subsections[@]}"; do
				[[ -n ${subsection} ]] || continue
				report.subsection "$subsection"
				data.exec "$section.$subsection"
			done
		fi
	done

	local file=$(report.export)
	local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "未知")
	console.stdout "报告已生成: $file ($size 字节)"
}

cli.handle() {
	args.init
	args.add_options "verbose" "v" "详细输出模式"
	args.add_options "force" "f" "强制重新采集（忽略时效性检查）"
	args.add_options "output" "o" "指定输出目录（默认: $DEFAULT_OUTPUT_DIR）" "DIR"
	args.add_options "config" "c" "指定配置文件" "FILE"
	args.process "$@"

	OPT_OUTPUT_DIR=$(args.get "-o" "--output") 2>/dev/null || OPT_OUTPUT_DIR="${DEFAULT_OUTPUT_DIR}/${_ARGS_CURRENT_SUBCOMMAND}/records"
	report.dir.set "$OPT_OUTPUT_DIR"
	OPT_CONFIG_FILE=$(args.get "-c" "--config") 2>/dev/null || OPT_CONFIG_FILE="${_ARGS_CURRENT_SUBCOMMAND}.toml"

	args.has "-v" "--verbose" && log.setLevel info || log.setLevel warn
	args.has "-f" "--force" && OPT_FORCE_RUN=true

	file.fresh || return

	config.loose
	config.load "$OPT_CONFIG_FILE"

	output.make
}

main() {
	args.init

	args.add_options "version" "v" "显示版本信息"
	args.add_subcommand "storage" "监控存储信息" "cli.handle"
	args.add_subcommand "network" "监控网络信息" "cli.handle"
	args.add_subcommand "system" "监控系统信息" "cli.handle"
	args.add_subcommand "performance" "监控性能信息" "cli.handle"

	args.process "$@"

	args.has "-v" "--version" && usage.version && exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
