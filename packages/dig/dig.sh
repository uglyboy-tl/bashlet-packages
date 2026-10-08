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
import core/log
import std/string

import browser
import common
import fetch
import schema
import source
import sources/index
import std/cache
import doctor

# 默认值只来自环境变量，**不读任何配置文件**。
#
# 为什么不留 config.toml：dig 是 skill 配套脚本，tools/build 产出的是单文件，包内的
# config.toml 不会跟着走 —— 原来那两个 config.load（包内 + ~/.config/dig/config.toml）
# 在产物里只会静默失败（都带 2>/dev/null || true），比报错更糟：开发时以为配置生效了。
# 想持久化就写包内 .env（dig.sh 带 `# build:keep-env`，产物也会加载同目录的 .env）。
dig.settings.load() {
	_DIG_DEFAULT_LIMIT="${DIG_DEFAULT_LIMIT:-20}"
	_DIG_DEFAULT_PERIOD="${DIG_DEFAULT_PERIOD:-pastmonth}"
	_DIG_DISCOURSE_SITES="${DIG_DISCOURSE_SITES:-discuss.python.org,community.openai.com,discuss.huggingface.co,discuss.pytorch.org,users.rust-lang.org,meta.discourse.org,community.fly.io,discuss.elastic.co}"

	# DIG_RETRY 必须是自然数：非法值要么在 $(( )) 里抛语法错（"1 2"），要么被当 0（abc）
	if [[ -n ${DIG_RETRY:-} ]] && ! string.natural.check "$DIG_RETRY"; then
		log.warn "DIG_RETRY 需要非负整数，得到：$DIG_RETRY；按默认 2 处理"
		DIG_RETRY=2
	fi

	# DIG_CACHE_TTL 同理：abc 会让 ((_DIG_CACHE_TTL > 0)) 把值当变量名（set -u 下直接致命）
	if [[ -n ${DIG_CACHE_TTL:-} ]] && ! string.natural.check "$DIG_CACHE_TTL"; then
		log.warn "DIG_CACHE_TTL 需要非负整数（秒），得到：$DIG_CACHE_TTL；按默认 86400 处理"
		_DIG_CACHE_TTL=86400
	fi

	# 云端浏览器的本地排队间隔（免费档 6 次/分钟）：同理校验，非法值会砸在 (( )) 上
	if [[ -n ${DIG_BROWSER_MIN_INTERVAL:-} ]] && ! string.natural.check "$DIG_BROWSER_MIN_INTERVAL"; then
		log.warn "DIG_BROWSER_MIN_INTERVAL 需要非负整数（秒），得到：$DIG_BROWSER_MIN_INTERVAL；按默认 12 处理"
		_BROWSER_MIN_INTERVAL=12
	fi

	export _DIG_DEFAULT_LIMIT _DIG_DEFAULT_PERIOD _DIG_DISCOURSE_SITES DIG_RETRY
}

# 所有源共用的执行骨架。模块名取自 args 选中的子命令，所以注册表加一个词就够了。
_dig_source() {
	local mod="$_ARGS_CURRENT_SUBCOMMAND"
	args.init
	dig.options.common
	# 有 URL 直取能力的源由框架统一给出 -u/--url，各源不用自己注册一遍
	if declare -F "${mod}.search_url" > /dev/null; then
		args.add_options "url" "u" "按 URL 直取这一条（dig fetch 用）" "URL"
	fi
	if declare -F "${mod}.options" > /dev/null; then
		"${mod}.options"
	fi
	args.add_options "ARG" "查询词" "要搜索的关键词"
	args.process "$@"

	dig.common.apply "$mod" || exit 1

	# 给了 -u 就直取这一条（URL 形式的校验在 search_url 里，报错更具体），否则走检索；
	# 缓存与输出两条路共用，所以键、--json、-o、--no-cache 的行为完全一致。
	#
	# 键要盖住所有影响结果的输入——源名 / 查询词 / 条数 / 窗口，加上该源的全部实参
	# （`-T issues`、`-u <url>`、`-r 3` 这类开关都在 "$*" 里）。也含 `--json` / `-o` 这种只影响
	# 输出的开关——宁可多算一份缓存，也不漏掉任何可能影响结果的入参。
	# 带副作用的调用（如 `x --update-ids`）不该进结果缓存：否则第二次跑会被缓存挡住，
	# 看起来执行了其实什么都没做。源可以声明 <源>.cache.bypass 来跳过这一层。
	if declare -F "${mod}.cache.bypass" > /dev/null 2>&1 && "${mod}.cache.bypass"; then
		DIG_NO_CACHE=1
	fi

	local key
	local -a action=("${mod}.search")
	[[ -n $DIG_URL ]] && action=("${mod}.search_url" "$DIG_URL")
	# 会话类输入也要进键：BILI_SESSDATA 决定有没有字幕、DIG_COOKIE 会改变部分源的内容
	key="$(cache.key "$mod" "$DIG_QUERY" "$DIG_LIMIT" "$DIG_PERIOD" "$*" "${BILI_SESSDATA:+sess}" "${DIG_COOKIE:+cookie}")"
	dig.cached "$key" -- "${action[@]}" | dig.output
}

cmd_doctor() {
	args.init "探活：逐个源检查外部命令、凭证与可达性"
	args.process "$@"
	doctor.run
}

dig.fetch.usage() {
	args.init '给 URL 取这一条：自动判断属于哪个源'
	args.add_options "ARG" "URL" "页面地址，必须是第一个实参"
	# 这里的 example 不用写 "dig fetch"：usage 渲染时会自动加上子命令前缀
	args.add_options "EXAMPLE" "https://github.com/curl/curl" "取仓库详情"
	args.add_options "EXAMPLE" "https://arxiv.org/abs/1706.03762" "取论文摘要"
	args.add_options "EXAMPLE" "https://www.reddit.com/r/linux/comments/<id> -r 3" "取帖子 + 评论树"
	args.add_options "NOTICE" "URL 之后的实参原样转给认领它的源，所以该源自己的选项（-r 3、--no-cache）都能照用"
	args.show_help
}

# dig fetch <url> [该源的选项…]：URL 交给「认领它的源」，之后的解析/取数/缓存/输出全走那条源自己的路径。
# 路由只回传参数（如 `so -u <url>`），所以这里等于替用户输入了一次子命令。
#
# 这里特意不走 args.process：源特有的选项（`-r 3`、`-T issues`）只有源的解析器认得，
# 在外层先解析会把它们当未知选项拒掉。约定 URL 必须是第一个实参，其余原样转给源。
cmd_fetch() {
	if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
		dig.fetch.usage
		return 0
	fi

	local url="${1:-}"
	[[ -n $url ]] || {
		log.error '需要 URL：dig fetch "<url>" [该源自己的选项…]'
		return 1
	}
	shift

	local route
	route="$(fetch.route "$url")" || {
		if fetch.fallback.enabled; then
			browser.creds.check || return 1
			fetch.fallback "$url" | dig.output || return 1
			return 0
		fi
		log.error "认不出这个 URL 属于哪个源：$url"
		log.error 'dig fetch 只处理已知站点：这个 URL 没有对应的源。按关键词检索用 dig <源> "<词>"（或用 DIG_FETCH_FALLBACK=1 让云端浏览器兜底）'
		return 1
	}

	local -a argv=()
	IFS=$'\t' read -r -a argv <<< "$route"
	_ARGS_CURRENT_SUBCOMMAND="${argv[0]}"
	_dig_source "${argv[@]:1}" "$@"
}

main() {
	local src
	local -a srcs=()
	mapfile -t srcs < <(source.list)

	# 顶层描述由注册表拼出来：之前写死 6 个名字，实际有 16 个源，加源时必然忘了同步
	local desc="按站点取数的工具箱：" sep=""
	for src in "${srcs[@]}"; do
		desc+="$sep$src"
		sep=" / "
	done
	args.init "$desc"
	args.add_options "version" "v" "显示版本信息"

	for src in "${srcs[@]}"; do
		args.add_subcommand "$src" "$(source.desc "$src")" "_dig_source"
	done
	args.add_subcommand "doctor" "探活：哪个源缺密钥 / 缺代理 / 不可达" "cmd_doctor"
	args.add_subcommand "fetch" "给 URL 取这一条（自动判断属于哪个源）" "cmd_fetch"

	dig.settings.load
	args.process "$@"
	args.has "-v" "--version" && usage.version && exit 0
	(($# == 0)) && args.show_help && exit 0
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then main "$@"; fi
