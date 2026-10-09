#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# 包内共享小工具：网络入口、公共选项、查询词与数值配置读取。

import core/args
import core/log
import ext/requests
import std/string
import std/system
import std/cache

import schema
import source

# 最后一次请求的 HTTP 状态码（失败时也能读到，供调用方区分 429 与网络不通）
declare -g _DIG_HTTP_STATUS=""

# 统一的网络入口：DIG_PROXY 显式覆盖，其次 curl 原生继承 https_proxy / http_proxy。
# DIG_COOKIE / DIG_AUTH 是源自己设的头（用户在环境变量里提供，dig 不抓浏览器 cookie）。
# 凭证走请求头而不是 query 串：URL 会进重试/失败日志，放 URL 等于把 key 打进终端与日志。
#
# 缺 curl/jq 时先判断再返回 3（requests.init 本身是 exit 语义，doctor/probe 靠 rc=3 区分「缺依赖」）；
# 判断通过才调 init，那时它不可能失败。
# 参数 --no-creds：只带代理，不带 DIG_COOKIE / DIG_AUTH —— 给第三方镜像用（站点凭证不发往无关域名）。
dig.requests.init() {
	local no_creds=false
	[[ ${1:-} == "--no-creds" ]] && no_creds=true

	requests.available || return 3

	local -a extra=()
	[[ -n ${DIG_PROXY:-} ]] && extra+=(--proxy "$DIG_PROXY")
	if [[ $no_creds == false ]]; then
		[[ -n ${DIG_COOKIE:-} ]] && extra+=(-H "Cookie: $DIG_COOKIE")
		[[ -n ${DIG_AUTH:-} ]] && extra+=(-H "Authorization: $DIG_AUTH")
	fi
	# bash 4.3 + set -u 下，空数组直接展开 "${extra[@]}" 会报 unbound：用 + 展开兜住
	requests.init ${extra[@]+"${extra[@]}"} 2> /dev/null
}

# 入口依赖检查：缺 jq/curl 就报出来再退。
# 放 source handler 入口而不是让失败渗透进调用链 —— 链上的失败会被 `$(...)` / `|| return 1`
# 吞掉，用户只看到空结果或误报（如把解析失败报成「数据不存在」）。
# doctor 不调它：探活要用 rc=3 把「缺什么」显示在表里。
dig.require.deps() {
	# 一次把缺的都列出来（缺两个时用户能一次装齐，不用跑两遍）
	local missing=""
	json.available || missing+="${missing:+, }jq"
	requests.curl.available || missing+="${missing:+, }curl"
	[[ -z $missing ]] || {
		log.error "缺少依赖：$missing"
		exit 1
	}
}

# 最后一次请求的 HTTP 状态码（调用方用来区分失败类型）
dig.http.status() { printf '%s' "$_DIG_HTTP_STATUS"; }

# 设定后续请求携带的 Cookie（空串等于不带）
dig.cookie.set() { export DIG_COOKIE="${1:-}"; }

# 设定后续请求携带的 Authorization 头（给 API key 用，避免 key 出现在 URL 里）
dig.auth.set() { export DIG_AUTH="${1:-}"; }

# 把要发给上游的条数夹到它的单次上限内；真夹了才告警，不静默改掉用户的意图
dig.clamp() { # <请求值> <上限> <上游名>
	local want="$1" max="$2" who="$3"
	if ((want > max)); then
		log.warn "$who 单次最多 $max 条，请求的 $want 按 $max 处理"
		printf '%s' "$max"
	else
		printf '%s' "$want"
	fi
}

# 失败响应体里的前 200 字（多行压成一行）：4xx/5xx 常在体里写真正的原因
# （如 Arctic Shift 的 {"error":"Timeout. Maybe slow down a bit"}），只报状态码会被读成「源不可用」。
# 先删 C0 控制字符（保留 \t \n \r 供下一步压成空格）：响应体是远端可控的，原样打到终端
# 可注入 ANSI/OSC 转义序列（改标题、写剪贴板、伪造输出）。
dig.http.body_snippet() {
	local s
	s="$(requests.text "$1" 2> /dev/null || true)"
	s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037\177' | tr -s '[:space:]' ' ')"
	# 用 bash 子串（按当前 locale 的字符）而不是 cut -c（C locale 下会从多字节字符中间截断）
	printf '%s' "${s:0:200}"
}

# 带重试的请求：传输层失败（连不上/DNS/证书/超时）与 429 / 5xx 才重试，退避 2s、4s…
# 其余 4xx 不重试 —— 那是参数或凭证问题，重试没用；
# 站点把背压信号放在别的状态码上时（如 Arctic Shift 的 422），用 DIG_HTTP_RETRY_CODES 追加。
dig.http.request() {
	local method="$1" url="$2" body="${3:-}" ctype="${4:-}"
	local tries=$((${DIG_RETRY:-2} + 1)) i=0 resp code rc
	local retry_re='^(429|5[0-9][0-9])$'
	# 源可以追加要重试的状态码（Arctic Shift 用 422 表背压）。拼进正则前先校验：
	# 写入元字符（"4|2"）会改变匹配意图，拼坏了 [[ =~ ]] 返回 2 被当假，反而少重试。
	if [[ -n ${DIG_HTTP_RETRY_CODES:-} ]]; then
		if [[ $DIG_HTTP_RETRY_CODES =~ ^[0-9]+([[:space:]]+[0-9]+)*$ ]]; then
			retry_re="^(429|5[0-9][0-9]|$(printf '%s' "${DIG_HTTP_RETRY_CODES// /|}"))$"
		else
			log.warn "DIG_HTTP_RETRY_CODES 只接受空格分隔的状态码数字，忽略：$DIG_HTTP_RETRY_CODES"
		fi
	fi

	while :; do
		i=$((i + 1))
		# 每轮开头清空：否则重试失败时日志会显示上一轮的陈旧状态码，而空响应时 dig.http.status
		# 会把上一次请求的状态码留给调用方（x 的自愈会因此误判成 403/404 而多刷一次 queryId）
		resp="" code="" rc="" _DIG_HTTP_STATUS=""
		resp="$(requests.request "$method" "$url" "$body" "$ctype")" || resp=""
		if [[ -n $resp ]]; then
			code="$(requests.status_code "$resp")"
			rc="$(requests.exit_code "$resp")"
			_DIG_HTTP_STATUS="$code"
			if [[ $(requests.success "$resp") == "true" ]]; then
				requests.text "$resp"
				return 0
			fi
			if [[ $rc == "0" && $code != "000" && $code != "0" && ! $code =~ $retry_re ]]; then
				local early_snippet
				early_snippet="$(dig.http.body_snippet "$resp")"
				log.error "请求被拒：$url (HTTP $code)${early_snippet:+：$early_snippet}"
				return 1
			fi
		fi

		if ((i < tries)); then
			log.warn "请求失败（HTTP ${code:-?} curl ${rc:-?}），$((i * 2))s 后重试（$i/$((tries - 1))）：$url"
			sleep $((i * 2))
			continue
		fi

		if [[ -z $resp ]]; then
			log.error "无法连接 $url：请求未产生响应"
		elif [[ $rc != "0" || $code == "000" || $code == "0" ]]; then
			log.error "无法连接 $url：网络不通（curl exit $rc）。若该站点需代理，设 DIG_PROXY（要持久化就写进包内 .env）"
		else
			local snippet
			snippet="$(dig.http.body_snippet "$resp")"
			log.error "请求被拒：$url (HTTP $code)，已重试 $((i - 1)) 次${snippet:+：$snippet}"
		fi
		return 1
	done
}

# GET 并取回响应体（参数走 query.build，与 ext/requests 一致）
dig.http.get() {
	local url="$1"
	shift
	dig.requests.init || return $?
	dig.http.request GET "$url$(requests.query.build "$@")" "" ""
}

# 面向第三方镜像的 GET：带代理（可达性），但不带 DIG_COOKIE / DIG_AUTH。
# 临时改全局 _REQUESTS_CURL_EXTRA，用完恢复，免得影响同进程后续请求。
dig.http.get_public() {
	local url="$1"
	shift

	local -a saved=()
	# ${var+set} 而不是 ${#arr[@]}：后者在变量未定义时会被 set -u 当致命错误
	if [[ ${_REQUESTS_CURL_EXTRA+set} ]]; then saved=("${_REQUESTS_CURL_EXTRA[@]}"); fi

	dig.requests.init --no-creds || return $?
	local rc=0
	dig.http.request GET "$url$(requests.query.build "$@")" "" "" || rc=$?

	_REQUESTS_CURL_EXTRA=()
	if ((${#saved[@]})); then _REQUESTS_CURL_EXTRA=("${saved[@]}"); fi
	return $rc
}

# POST JSON 并取回响应体
dig.http.post_json() {
	dig.requests.init || return $?
	dig.http.request POST "$1" "$2" "application/json"
}

# 通用探活：GET 一个 URL。0=可达 1=被拒 2=网络不通 3=缺 curl；stdout 给一行说明。
# 供源适配器的 <源>.probe 复用；探活不打日志，避免 doctor 时刷 error。
dig.http.probe() {
	json.available || {
		printf '缺少 jq'
		return 3
	}

	local url="$1" host
	host="$(printf '%s' "$url" | sed -E 's#^https?://([^/]+).*#\1#')"
	dig.requests.init || {
		printf '缺少 curl'
		return 3
	}
	# 探活要快：默认 30s 超时下，被污染的域名会让 doctor 逐个卡住
	requests.timeout "${DIG_PROBE_TIMEOUT:-5}"

	local resp code rc
	resp="$(requests.get "$url")" || {
		printf '%s 网络不通' "$host"
		return 2
	}
	code="$(requests.status_code "$resp")"
	rc="$(requests.exit_code "$resp")"
	# 传输层失败时 status_code 是 0（不是 000）、curl 退出码非 0。只认 000 会把「不通」
	# 误报成「返回 HTTP 0」，doctor 于是把它归到「接口异常」而不是「不可达 + 设代理」。
	if [[ -n $rc && $rc != 0 ]] || [[ $code == 0 || $code == 000 ]]; then
		printf '%s 网络不通（curl exit %s）' "$host" "${rc:-未知}"
		return 2
	fi
	if [[ $(requests.success "$resp") == "true" ]]; then
		printf '%s 可达' "$host"
		return 0
	fi
	printf '%s 返回 HTTP %s' "$host" "$code"
	return 1
}

# 读取选项值，缺失时返回空串而不是非零退出（供 set -e 下的赋值使用）
dig.opt() { args.get "$@" || true; }

# 读一个「可选正整数」选项：未给时输出 $1（默认值），给了但非法则报错返回非 0。
# 避免各源各写一遍 `[[ -n $v ]] && check || 默认值` —— 那种写法会给非法值静默回落。
dig.opt.natural() {
	local default="$1"
	shift
	local v
	v="$(dig.opt "$@")"
	if [[ -z $v ]]; then
		printf '%s' "$default"
	elif string.natural.check "$v"; then
		printf '%s' "$v"
	else
		log.error "选项 $1 需要正整数，得到：$v"
		return 1
	fi
}

# 位置参数拼成查询词
dig.query() {
	local -n _dig_args_ref="$(args.args)"
	string.trim "${_dig_args_ref[*]:-}"
}

# 所有源一致的公共选项
dig.options.common() {
	args.add_options "limit" "n" "返回条目上限" "NUMBER"
	args.add_options "period" "p" "时间窗口 last24h|pastweek|pastmonth|pastyear|all" "WINDOW"
	args.add_options "json" "" "输出 JSONL（默认人类可读）"
	args.add_options "output" "o" "结果落盘文件" "FILE"
	args.add_options "no-cache" "" "跳过结果缓存，强制走网络"
}

# 解析公共选项到 DIG_* 全局。$1 为源模块名（可用 <源>.period 声明自己的默认窗口）。
dig.common.apply() {
	local mod="${1:-}"
	local explicit period_override=""

	# 给了但不是正整数就报错，不静默回落（否则用户以为生效了）——dig.opt.natural 已含这套语义
	DIG_LIMIT="$(dig.opt.natural "$_DIG_DEFAULT_LIMIT" -n --limit)" || return 1

	# 源的默认窗口写在注册表 caps 里（period:pastyear 这种具体窗口名）；yes/no 只是描述。
	# 用户显式给的 -p 仍然优先。
	if [[ -n $mod ]]; then
		local declared
		declared="$(source.cap "$mod" period 2> /dev/null || true)"
		case $declared in
			yes | no | "") ;;
			*) period_override="$declared" ;;
		esac
	fi
	explicit="$(dig.opt -p --period)"
	if [[ -n $explicit ]]; then
		DIG_PERIOD="$explicit"
	elif [[ -n $period_override ]]; then
		DIG_PERIOD="$period_override"
	else
		DIG_PERIOD="$_DIG_DEFAULT_PERIOD"
	fi
	DIG_AFTER="$(schema.period.after "$DIG_PERIOD")" || return 1

	DIG_JSON=false
	args.has "--json" && DIG_JSON=true

	DIG_OUTPUT="$(dig.opt -o --output)"
	DIG_QUERY="$(dig.query)"

	# 按 URL 直取（-u）：只有实现了 search_url 的源才有这个选项，其余源拿到空串
	DIG_URL="$(dig.opt -u --url)"

	# --no-cache 走环境变量而不是全局：cache 模块只读它，不关心命令是怎么传进来的
	args.has "--no-cache" && DIG_NO_CACHE=1

	export DIG_LIMIT DIG_PERIOD DIG_AFTER DIG_JSON DIG_OUTPUT DIG_QUERY DIG_URL DIG_NO_CACHE
}

# 输出：--json 直出 JSONL，否则渲染成人类可读；给了 -o 就先落盘原始 JSONL
dig.output() {
	if [[ -n ${DIG_OUTPUT:-} ]]; then
		mkdir -p "$(dirname "$DIG_OUTPUT")"
		tee "$DIG_OUTPUT" | schema.output
	else
		schema.output
	fi
}

# ── 结果缓存（策略层；存储在 bashlet 的 std/cache）──────────────────────────────
# 只缓存**成功**结果 —— 失败缓存下来会把一次网络抖动记一整天，那是「失败要响」的反面。
# 命中时打一行 INFO：让调用方知道这是缓存、要最新数据得加 --no-cache。
_DIG_CACHE_TTL="${DIG_CACHE_TTL:-86400}"

dig.cache.enabled() { [[ ${DIG_NO_CACHE:-} != 1 ]] && ((_DIG_CACHE_TTL > 0)); }

# dig.cached <结果键> -- <命令...>：命中就回放，未命中才跑命令并缓存它的输出
dig.cached() {
	local key="$1"
	shift
	[[ ${1:-} == "--" ]] && shift

	if dig.cache.enabled; then
		local hit
		if hit="$(cache.get result "$key" "$_DIG_CACHE_TTL")"; then
			log.info "结果缓存命中（${_DIG_CACHE_TTL}s 内）：要最新数据加 --no-cache"
			[[ -n $hit ]] && printf '%s\n' "$hit"
			return 0
		fi
	fi

	local out
	out="$("$@")" || return 1
	# 缓存只是附加收益：写不进去（目录不可写、磁盘满）不该把已经拿到的结果连带丢掉
	if dig.cache.enabled; then
		cache.put result "$key" "$out" || log.warn "结果缓存写入失败，忽略（不影响本次输出）"
	fi
	[[ -n $out ]] && printf '%s\n' "$out"
	return 0
}
