#!/usr/bin/env bash
# shellcheck disable=SC2034

set -euo pipefail

SCRIPT_NAME="Monitor"
VERSION="2.0.0"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

import std/markdown
import std/system
import core/log
import core/args
import core/config
import core/report

DEFAULT_OUTPUT_DIR="monitor"
OPT_OUTPUT_DIR=""
OPT_CONFIG_FILE=""
OPT_FORCE_RUN=false
OPT_MAX_AGE_HOURS=24

declare -gA _MONITOR_CHECKS=()
declare -gA _MONITOR_CACHE=()

run() {
  local result=$(bash -c "$1" 2>&1)
  log.debug "$1 (exit=$?): $result"
  echo "$result"
}

file.need_fresh() {
  [[ $OPT_FORCE_RUN == true ]] && log.info "强制重新采集数据" && return

  # shellcheck disable=SC2012
  local latest_file=$(ls "$OPT_OUTPUT_DIR"/*.md 2> /dev/null | tail -1)
  [[ -z $latest_file ]] && log.info "未找到历史记录文件" && return

  local name=$(basename "$latest_file" .md)
  local file_timestamp=$(date -d "${name:0:4}-${name:4:2}-${name:6:2} ${name:9:2}:${name:11:2}:${name:13:2}" +%s)
  local age_hours=$((($(date +%s) - file_timestamp) / 3600))
  ((age_hours < OPT_MAX_AGE_HOURS)) && log.info "数据有效（${age_hours} 小时前）" && echo "跳过采集（最近报告: $latest_file）" && return 1

  log.info "数据已过期（${age_hours} 小时）"
}

data.cache() { _MONITOR_CACHE["$1"]=$(run "$2" 2> /dev/null); }
data.get_cache() { [[ -v "_MONITOR_CACHE[$1]" ]] && echo "${_MONITOR_CACHE[$1]}" || echo ""; }

data.vars() {
  local key

  for key in "${!_CONFIG_VALUES[@]}"; do
    [[ $key == *".var:"* ]] && data.cache "${key##*.var:}" "${_CONFIG_VALUES[$key]}"
  done
}

data.add() {
  local name="$1"
  local raw_value="$2"
  local cmd unit=""

  # 解析单位分离语法
  [[ $raw_value =~ ^\"(.*)\"$ ]] && raw_value="${BASH_REMATCH[1]}"
  [[ $raw_value =~ ^(.+)[[:space:]]+::[[:space:]]+(.+)$ ]] && cmd="${BASH_REMATCH[1]}" && unit="${BASH_REMATCH[2]}" || cmd="$raw_value"

  local result
  # 替换 @缓存名 为缓存的命令结果
  while [[ $cmd =~ @([a-zA-Z_][a-zA-Z0-9_]*) ]]; do
    local cache_name="${BASH_REMATCH[1]}"
    local cache_value="$(data.get_cache "$cache_name")"
    cmd="${cmd//@${cache_name}/${cache_value}}"
  done
  result=$(run "$cmd")
  result=$(string.trim "$result")
  [[ -n $unit && -n $result && $result != "N/A" && $unit != "status" ]] && result="$result $unit"
  _MONITOR_CHECKS["${name}"]="${result:-N/A}"
}

data.show() {
  report.table.begin "名称" "值"
  for name in "${!_MONITOR_CHECKS[@]}"; do
    report.table.add "$name" "${_MONITOR_CHECKS[${name}]:-N/A}"
  done
  report.table.end
  _MONITOR_CHECKS=()
}

data.exec() {
  local prefix="$1."
  local key value count=0 has_code=0

  # 再处理普通项和 code 项
  for key in "${!_CONFIG_VALUES[@]}"; do
    if [[ $key == "$prefix"* ]] && [[ $key != "$prefix"*.* ]]; then
      value="${_CONFIG_VALUES[$key]}"
      key="${key#"$prefix"}"
      if [[ $key == "code" ]]; then
        has_code=1
        code_value="$value"
      elif [[ $key != var:* ]]; then
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
    [[ $key == dynamic:* ]] && dynamic_values["${key#dynamic:}"]="$(run "${_CONFIG_VALUES[$key]}")"
  done

  # 如果没有动态变量，直接返回
  [[ ${#dynamic_values[@]} -eq 0 ]] && return 0

  # 展开动态节和项
  local -A new_config=()
  for key in "${!_CONFIG_VALUES[@]}"; do
    # 跳过 dynamic 声明本身
    [[ $key == dynamic:* ]] && continue

    value="${_CONFIG_VALUES[$key]}"

    # 检查键名中是否包含动态变量（如 @device）
    if [[ $key == *@* ]]; then
      # 这是一个动态模板，需要展开
      for var_name in "${!dynamic_values[@]}"; do
        local pattern="@${var_name}"
        [[ $key == *"$pattern"* ]] || continue

        # 对每个设备值展开模板
        local devices_list="${dynamic_values[$var_name]}"
        [[ -n $devices_list ]] || continue

        while IFS= read -r item; do
          [[ -z $item ]] && continue
          local new_key="${key//$pattern/$item}"
          new_config["$new_key"]="${value//$pattern/$item}"
        done <<< "$devices_list"
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
  # 收集所有可能的四级节（包含3个点的键）
  local -A four_level_sections=()
  for key in "${!_CONFIG_VALUES[@]}"; do
    [[ $key == *.*.*.* ]] && four_level_sections["${key%.*}"]=1
  done

  # 如果没有四级节，直接返回
  [[ ${#four_level_sections[@]} -eq 0 ]] && return 0

  # 处理每个四级节
  for section_prefix in "${!four_level_sections[@]}"; do
    # 解析节前缀
    local section1="${section_prefix%%.*}"
    local remaining="${section_prefix#*.}"
    local section2="${remaining%%.*}"
    local condition_name="${remaining#*.}"

    # 获取 condition 值
    local condition_key="$section_prefix.condition"
    if [[ -v "_CONFIG_VALUES[$condition_key]" ]]; then
      # 执行 condition 命令（先进行缓存替换）
      local cmd="${_CONFIG_VALUES[$condition_key]}"
      while [[ $cmd =~ @([a-zA-Z_][a-zA-Z0-9_]*) ]]; do
        local cache_name="${BASH_REMATCH[1]}"
        cmd="${cmd//@${cache_name}/$(data.get_cache "$cache_name")}"
      done

      # 如果 condition 结果匹配条件名，则合并配置
      if [[ "$(run "$cmd")" == "$condition_name" ]]; then
        # 将该条件分支的所有项（除 condition 外）合并到三级节
        for subkey in "${!_CONFIG_VALUES[@]}"; do
          [[ $subkey == "$section_prefix".* ]] && [[ $subkey != "$condition_key" ]] &&
            _CONFIG_VALUES["$section1.$section2.${subkey##"$section_prefix."}"]="${_CONFIG_VALUES[$subkey]}"
        done
      fi
    fi
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
    if [[ -n $section ]]; then
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
  local size=$(stat -c%s "$file" 2> /dev/null || stat -f%z "$file" 2> /dev/null || echo "未知")
  console.stdout "报告已生成: $file ($size 字节)"
}

cli.handle() {
  args.init
  args.add_options "verbose" "v" "详细输出模式"
  args.add_options "force" "f" "强制重新采集（忽略时效性检查）"
  args.add_options "output" "o" "指定输出目录（默认: $DEFAULT_OUTPUT_DIR）" "DIR"
  args.add_options "config" "c" "指定配置文件" "FILE"
  args.process "$@"

  OPT_OUTPUT_DIR=$(args.get "-o" "--output") 2> /dev/null || OPT_OUTPUT_DIR="${DEFAULT_OUTPUT_DIR}/${_ARGS_CURRENT_SUBCOMMAND}/records"
  report.dir.set "$OPT_OUTPUT_DIR"
  OPT_CONFIG_FILE=$(args.get "-c" "--config") 2> /dev/null || OPT_CONFIG_FILE="${DEFAULT_OUTPUT_DIR}/${_ARGS_CURRENT_SUBCOMMAND}.toml"

  args.has "-v" "--verbose" && log.setLevel info || log.setLevel warn
  args.has "-f" "--force" && OPT_FORCE_RUN=true

  file.need_fresh || return

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

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
fi
