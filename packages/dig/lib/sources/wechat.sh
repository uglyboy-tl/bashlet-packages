#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# 微信公众号文章。微信没有公开检索接口——**发现只能靠 web 检索**，这个源只负责按 URL 取正文，
# 取正文这件事交给 lib/browser.sh（云端无头浏览器；本地 curl 会 302 到滑块验证）。
#
# 所以它是「只能按 URL 取」的源：`dig wechat -u <url>` 或 `dig fetch <url>`，没有检索分支。

import core/log
import std/string

import browser
import common
import schema
import source

wechat.probe() { browser.probe; }

wechat.search() {
	log.error '微信公众号没有公开检索接口：发现用 web 检索，正文用 dig fetch "<文章链接>"'
	return 1
}

wechat.search_url() {
	local url="$1"
	browser.creds.check || return 1
	browser.page "$url" | wechat.map "$(wechat.url.clean "$url")" | schema.pipe 0 | schema.limit 1
}

# 文章 URL：短链 /s/<id>，或长链 /s?__biz=…&mid=…&idx=…&sn=…
wechat.url.id() {
	local u="$1" mid idx=""
	if [[ $u =~ /s/([A-Za-z0-9_-]+) ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi
	if [[ $u =~ [?\&]mid=([0-9]+) ]]; then
		mid="${BASH_REMATCH[1]}"
		[[ $u =~ [?\&]idx=([0-9]+) ]] && idx="${BASH_REMATCH[1]}"
		printf '%s_%s' "$mid" "${idx:-1}"
		return 0
	fi
	return 1
}

# 只去掉会话噪声 poc_token：长链的其它参数是文章定位用的，删了就打不开
wechat.url.clean() {
	local u="$1" base="${1%%\?*}" joined="" p
	[[ $u == *\?* ]] || {
		printf '%s' "$u"
		return 0
	}
	local -a parts=() keep=()
	IFS='&' read -ra parts <<< "${u#*\?}"
	for p in "${parts[@]}"; do
		[[ ${p%%=*} == "poc_token" ]] && continue
		keep+=("$p")
	done
	((${#keep[@]})) || {
		printf '%s' "$base"
		return 0
	}
	joined="$(printf '%s&' "${keep[@]}")"
	printf '%s?%s' "$base" "${joined%&}"
}

# browser.page 的 {title, author, description, text} → dig 的条目形状
wechat.map() {
	local url="$1" id
	id="$(wechat.url.id "$url" || printf '%s' "$url")"
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" --arg url "$url" --arg id "$id" '
    {
        source: "wechat",
        id: $id,
        url: $url,
        title: (.title // ""),
        text: (.text // ""),
        author: (.author // ""),
        created_at: "",
        engagement: {},
        tags: [],
        query: $query
      }'
}

source.url.register wechat mp.weixin.qq.com
source.register wechat "微信公众号文章正文（只按 URL 取，需 Cloudflare Browser Run 凭证）" "tier:topic period:no proxy:no key:required"
