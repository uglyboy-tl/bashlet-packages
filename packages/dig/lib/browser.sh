#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# 云端无头浏览器（后端：Cloudflare Browser Run 的 /markdown quick action）。
#
# 定位：本机 curl 拿不到正文时的**最后一条路**——被风控挡（微信 302 到滑块验证）、
# 或正文要 JS 渲染的页面。实测边界：微信公众号正文能拿到；知乎在同一出口回 40362，
# 拿不到——所以它不是通用抓取器，只服务确实过得去的站点。
# 免费档限流 REST 6 次/分钟（1 次/10 秒）：只适合单条取，不做批量。
#
# 凭证：CLOUDFLARE_ACCOUNT_ID + CLOUDFLARE_API_TOKEN，token 要授
# Account · Browser Rendering · Edit。注意「凭证有效」和「有权限」是两回事：
# 只授别的权限时 /user/tokens/verify 是绿的，这个接口回 10000——所以探活必须实测。

import core/log
import std/cache

import common
import schema

read -r -d '' _BROWSER_PARSE_JQ << 'JQ' || true
    def grab($s; $re): if ($s | test($re)) then ($s | capture($re) | .v) else "" end;
    def clean: gsub("^\"|\"$"; "") | sub("[ ]+$"; "");
    . as $md
    | (if ($md | test("(?s)^---\n.*?\n---\n"))
       then ($md | capture("(?s)^---\n(?<fm>.*?)\n---\n(?<body>.*)$"))
       else { fm: "", body: $md } end) as $m
    | {
        title: (grab($m.fm; "(?m)^title:[ ]*(?<v>.*)$") | clean),
        author: (grab($m.fm; "(?m)^[ ]+author:[ ]*(?<v>.*)$") | clean),
        description: (grab($m.fm; "(?m)^[ ]+description:[ ]*(?<v>.*)$") | clean),
        text: $m.body
      }
JQ

_BROWSER_API="https://api.cloudflare.com/client/v4/accounts"

# 免费档限流 REST 6 次/分钟：与其等上游回 429 再靠退避重试，不如本地先排队（时间戳落缓存目录，跨进程生效）。
# 12 秒而不是 10：10 秒正好卡在 6 次/分钟的边界上，稍有抖动就还是会 429。
# DIG_BROWSER_MIN_INTERVAL 在 dig.settings.load 里校验过（非法值会砸在 (( )) 上）。
_BROWSER_MIN_INTERVAL="${DIG_BROWSER_MIN_INTERVAL:-12}"
_BROWSER_PROBE_MSG=""
_BROWSER_PROBE_RC=""

# 凭证是否齐（纯静态检查，不触网）
browser.available() { [[ -n ${CLOUDFLARE_ACCOUNT_ID:-} && -n ${CLOUDFLARE_API_TOKEN:-} ]]; }

browser.creds.check() {
	browser.available || {
		log.error "需要 Cloudflare Browser Run 凭证：CLOUDFLARE_ACCOUNT_ID 与 CLOUDFLARE_API_TOKEN（写进脚本同目录的 .env）"
		return 1
	}
}

# 探活：0 可达 / 1 失败 / 3 缺凭证，stdout 一行说明（源直接转发即可）
browser.probe() {
	# doctor 会让 wechat 与能力行各问一次：同一进程里只真打一次（也省一次限流等待）
	if [[ -n $_BROWSER_PROBE_MSG ]]; then
		printf '%s' "$_BROWSER_PROBE_MSG"
		return "${_BROWSER_PROBE_RC:-1}"
	fi
	if ! browser.available; then
		local missing=""
		[[ -n ${CLOUDFLARE_ACCOUNT_ID:-} ]] || missing+="${missing:+, }CLOUDFLARE_ACCOUNT_ID"
		[[ -n ${CLOUDFLARE_API_TOKEN:-} ]] || missing+="${missing:+, }CLOUDFLARE_API_TOKEN"
		_BROWSER_PROBE_MSG="缺 $missing"
		_BROWSER_PROBE_RC=3
		printf '%s' "$_BROWSER_PROBE_MSG"
		return 3
	fi
	if browser.markdown "https://example.com" > /dev/null; then
		_BROWSER_PROBE_MSG="凭证有效，云端浏览器可达"
		_BROWSER_PROBE_RC=0
	else
		_BROWSER_PROBE_MSG="Cloudflare Browser Run 调用失败（见上面的错误）"
		_BROWSER_PROBE_RC=1
	fi
	printf '%s' "$_BROWSER_PROBE_MSG"
	return "$_BROWSER_PROBE_RC"
}

# browser.throttle.wait <now> <上次调用时刻> → 还要等几秒（纯函数，好测）
browser.throttle.wait() {
	local now="$1" last="$2"
	((_BROWSER_MIN_INTERVAL > 0)) || {
		printf '0'
		return 0
	}
	[[ $last =~ ^[0-9]+$ ]] || {
		printf '0'
		return 0
	}
	local wait=$((_BROWSER_MIN_INTERVAL - (now - last)))
	((wait > 0)) && printf '%s' "$wait" || printf '0'
}

browser.throttle() {
	# 间隔 0 = 完全不参与排队（连时间戳都不写）
	((_BROWSER_MIN_INTERVAL > 0)) || return 0
	local dir stamp now last wait
	dir="$(cache.dir browser 2> /dev/null)" || return 0
	stamp="$dir/last-call"
	now="$(date +%s)"
	last="$(cat "$stamp" 2> /dev/null || true)"
	wait="$(browser.throttle.wait "$now" "$last")"
	if ((wait > 0)); then
		log.info "云端浏览器免费档限流 6 次/分钟：等 ${wait}s（DIG_BROWSER_MIN_INTERVAL 可调）"
		sleep "$wait"
		now="$(date +%s)"
	fi
	printf '%s' "$now" > "$stamp" 2> /dev/null || true
}

# browser.markdown <url> → markdown 原文（头部是 title / meta 的 YAML front-matter）
browser.markdown() {
	local url="$1" payload raw md err
	browser.throttle
	payload="$(json.run -nc --arg u "$url" '{url:$u, gotoOptions:{waitUntil:"networkidle0"}}')" || return 1

	# 用完恢复 DIG_AUTH：别把 CF 的 Authorization 头留给同进程后面的请求
	local prev_auth="${DIG_AUTH:-}" i=0
	dig.auth.set "Bearer ${CLOUDFLARE_API_TOKEN}"
	while :; do
		i=$((i + 1))
		if raw="$(dig.http.post_json "${_BROWSER_API}/${CLOUDFLARE_ACCOUNT_ID}/browser-run/markdown" "$payload")"; then
			break
		fi
		# 通用退避是 2s/4s，对「按分钟」的限流太短：429 自己多等一会儿再试一次。
		# 也把这次重试写进时间戳，免得下一次调用又按原间隔再去撞一次。
		if [[ $(dig.http.status) == 429 && $i -lt 3 ]]; then
			log.warn "云端浏览器限流（HTTP 429）：等 ${_BROWSER_MIN_INTERVAL}s 再试（$i/2）"
			sleep "$_BROWSER_MIN_INTERVAL"
			browser.throttle
			continue
		fi
		dig.auth.set "$prev_auth"
		return 1
	done
	dig.auth.set "$prev_auth"

	md="$(printf '%s' "$raw" | json.run -r 'if .success == true then (.result // "") else "" end' 2> /dev/null || true)"
	[[ -n $md ]] || {
		err="$(printf '%s' "$raw" | json.run -c '.errors // .messages // "未知原因"' 2> /dev/null | cut -c1-200)"
		log.error "Cloudflare Browser Run 没返回内容：$err"
		log.error '（10000 Authentication error = token 没授「Browser Rendering - Edit」，或 account 与 token 不匹配）'
		return 1
	}
	printf '%s' "$md"
}

# browser.page <url> → 一行 JSON {title, author, description, text}
browser.page() {
	local url="$1" md
	md="$(browser.markdown "$url")" || return 1
	printf '%s' "$md" | browser.parse
}

# markdown 的 front-matter 拆成字段；没有 front-matter 时整篇当正文（YAML 值可能带引号）
#
# 注：jq 的 capture 在**不匹配时返回 empty 而不是报错**，所以不能用 try/catch 兑——
# 那会让整个对象变成 empty（一条输出都没有）。先 test 再 capture。
browser.parse() {
	json.run -R -s -c "$_BROWSER_PARSE_JQ"
}
