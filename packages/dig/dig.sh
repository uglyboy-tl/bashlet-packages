#!/usr/bin/env bash
# build:keep-env

set -euo pipefail
SCRIPT_NAME="Dig"
VERSION="0.1.0"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

# 包内本地环境（在 import 之前加载：core/log 在顶层读 _LOG_LEVEL）
.env

import core/args
import core/config
import core/log
import std/string

import common
import schema
import source
import sources
import doctor

# 注册配置项、载入 config.toml
dig.settings.load() {
	config.register "defaults.limit" "20" "number" "默认条目上限"
	config.register "defaults.period" "pastmonth" "string" "默认时间窗口"
	config.register "proxy.url" "" "string" "网络代理（DIG_PROXY 环境变量优先）"
	config.register "discourse.sites" "discuss.python.org,community.openai.com,discuss.huggingface.co,discuss.pytorch.org,users.rust-lang.org,meta.discourse.org,community.fly.io,discuss.elastic.co" "string" "dig discourse 默认搜的实例列表"

	# 包内默认值，再叠用户级配置（后者可覆盖，用于代理/默认值这种跟机器绑的东西）
	config.load "$PROJECT_ROOT/config.toml" 2> /dev/null || true
	config.load "${XDG_CONFIG_HOME:-$HOME/.config}/dig/config.toml" 2> /dev/null || true

	_DIG_DEFAULT_LIMIT="$(dig.num "defaults.limit" 20)"
	_DIG_DEFAULT_PERIOD="$(config.get "defaults.period" 2> /dev/null || true)"
	[[ -n $_DIG_DEFAULT_PERIOD ]] || _DIG_DEFAULT_PERIOD="pastmonth"

	if [[ -z ${DIG_PROXY:-} ]]; then
		DIG_PROXY="$(config.get "proxy.url" 2> /dev/null || true)"
	fi
	_DIG_DISCOURSE_SITES="$(config.get "discourse.sites" 2> /dev/null || true)"

	# DIG_RETRY 必须是自然数：非法值要么在 $(( )) 里抛语法错（"1 2"），要么被当 0（abc）
	if [[ -n ${DIG_RETRY:-} ]] && ! string.natural.check "$DIG_RETRY"; then
		log.warn "DIG_RETRY 需要非负整数，得到：$DIG_RETRY；按默认 2 处理"
		DIG_RETRY=2
	fi

	export _DIG_DEFAULT_LIMIT _DIG_DEFAULT_PERIOD DIG_PROXY _DIG_DISCOURSE_SITES DIG_RETRY
}

# 所有源共用的执行骨架。模块名取自 args 选中的子命令，所以注册表加一个词就够了。
_dig_source() {
	local mod="$_ARGS_CURRENT_SUBCOMMAND"
	args.init
	dig.options.common
	if declare -F "${mod}.options" > /dev/null; then
		"${mod}.options"
	fi
	args.add_options "ARG" "查询词" "要搜索的关键词"
	args.process "$@"

	dig.common.apply "$mod" || exit 1
	"${mod}.search" | dig.output
}

cmd_sources() {
	args.init
	args.process "$@"

	local -a srcs=()
	mapfile -t srcs < <(source.list)

	local -A label=(
		[core]="核心 — 几乎每次调研都该跑"
		[topic]="按话题选 — 只在匹配的话题类型上用"
		[niche]="特定场景 — 极少用，但用了不可替代"
	)
	local t src tier creds deps caps printed
	for t in core topic niche; do
		printed=0
		for src in "${srcs[@]}"; do
			tier="$(source.cap "$src" tier 2> /dev/null || true)"
			[[ $tier == "$t" ]] || continue
			if ((printed == 0)); then
				printf '\n%s\n' "${label[$t]}"
				printed=1
			fi
			creds="$(source.creds "$src")"
			deps="$(source.requires "$src")"
			# 分组标题已经说明了 tier，这里从展示串里去掉它（register 保证 tier 在首位）
			caps="$(source.caps "$src")"
			caps="$(string.trim "${caps//tier:$tier/}")"
			printf '  %-10s %s\n' "$src" "$(source.desc "$src")"
			printf '             %s\n' "$(string.trim "$caps 凭证: ${creds:-免} 依赖: ${deps:-无}")"
		done
	done
	printf '\n'
}

cmd_doctor() {
	args.init "探活：逐个源检查外部命令、凭证与可达性"
	args.process "$@"
	doctor.run
}

main() {
	args.init "按站点取数的工具箱：HN / GitHub / Stack Overflow / arXiv / 知乎 / 微信读书"
	args.add_options "version" "v" "显示版本信息"

	local src
	local -a srcs=()
	mapfile -t srcs < <(source.list)
	for src in "${srcs[@]}"; do
		args.add_subcommand "$src" "$(source.desc "$src")" "_dig_source"
	done
	args.add_subcommand "sources" "列出所有源及其凭证 / 依赖 / 能力" "cmd_sources"
	args.add_subcommand "doctor" "探活：哪个源缺密钥 / 缺代理 / 不可达" "cmd_doctor"

	dig.settings.load
	args.process "$@"
	args.has "-v" "--version" && usage.version && exit 0
	(($# == 0)) && args.show_help && exit 0
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then main "$@"; fi
