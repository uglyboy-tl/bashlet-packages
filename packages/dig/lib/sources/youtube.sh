#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# YouTube：搜索走 InnerTube 的 WEB 客户端（纯 JSON）；-t 时用 watch 页的 ytInitialPlayerResponse
# 补精确发布日期与视频简介。不需要 yt-dlp / ffmpeg，本机 DNS 不通，必须走代理。
#
# 字幕拿不到（2026-10 实测）：watch 页里能看到 captionTracks，但取内容的两条路都被封——
#   /api/timedtext 恒返回 HTTP 200 + content-length: 0
#   /youtubei/v1/get_transcript 返回 400 Precondition check failed
# 两者都要 PO token，等于要跑 YouTube 自己的 JS（本项目排除的重方案）。代理出口 IP 稳定，
# 不是 IP 轮换导致的签名失配。

import core/log

import common
import parse
import schema
import source

_YT_API="https://www.youtube.com/youtubei/v1"
# YouTube Web 端公开的客户端 key（非账号凭证，所有前端都在用）。可用 DIG_YT_KEY 覆盖，
# 官方轮换时不必改代码。
_YT_KEY="${DIG_YT_KEY:-AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8}"
_YT_WEB_VERSION="2.20240726.00.00"
# 简介最长保留多少字符
_YT_TEXT_CAP=1500

youtube.options() {
	args.add_options "detail" "t" "为前 N 条抓精确发布日期与简介（每条 1 个页面请求，默认 0）" "NUMBER"
}

youtube.probe() { dig.http.probe "https://www.youtube.com/"; }

youtube.search() {
	[[ -n $DIG_QUERY ]] || {
		log.error '需要查询词：dig youtube "关键词"'
		return 1
	}

	local body out
	body="$(json.run -n --arg q "$DIG_QUERY" --arg v "$_YT_WEB_VERSION" \
		'{context:{client:{clientName:"WEB",clientVersion:$v,hl:"en",gl:"US"}},query:$q}')"
	out="$(dig.http.post_json "$_YT_API/search?key=$_YT_KEY&prettyPrint=false" "$body")" || return 1

	local n
	n="$(dig.opt.natural 0 -t --detail)" || return 1

	printf '%s' "$out" | youtube.map | schema.enrich "$n" youtube.enrich_one | schema.pipe 0 | schema.limit "$DIG_LIMIT"
}

youtube.map() {
	json.run -c --arg query "${DIG_QUERY:-}" '
    [ .. | objects | select(has("videoRenderer")) | .videoRenderer ][]
    | {
        source: "youtube",
        id: .videoId,
        url: ("https://www.youtube.com/watch?v=" + .videoId),
        title: (.title.runs[0].text // .title.simpleText // ""),
        text: "",
        author: (.ownerText.runs[0].text // ""),
        created_at: "",
        engagement: {
          views: (((.viewCountText.simpleText // "") | gsub("[^0-9]"; "")) as $v | if $v == "" then 0 else ($v | tonumber) end),
          duration: (.lengthText.simpleText // ""),
          age: (.publishedTimeText.simpleText // "")
        },
        tags: [],
        query: $query
      }'
}

youtube.enrich_one() {
	local line="$1" vid player date desc
	vid="$(printf '%s' "$line" | json.run -r '.id // empty')"
	[[ -n $vid ]] || {
		printf '%s' "$line"
		return 0
	}
	if ! player="$(youtube.player "$vid")"; then
		printf '%s' "$line"
		return 0
	fi
	date="$(printf '%s' "$player" | json.run -r "$_SCHEMA_JQ_LIB"'
    .microformat.playerMicroformatRenderer.publishDate // "" | to_utc')"
	desc="$(printf '%s' "$player" | json.run -r --argjson cap "$_YT_TEXT_CAP" '
    (.videoDetails.shortDescription // "") | if length > $cap then .[0:$cap] else . end')"
	parse.json.patch "$line" "created_at=$date" "text=$desc"
}

# watch 页里的 ytInitialPlayerResponse。抠 JSON 的活交给 lib/parse.sh：
# 页面是多行的，且那段 JSON 后面接什么（`;var meta = ...` 或 `;</script>`）不固定，
# 用花括号配对而不是正则找分隔符。
youtube.player() {
	local vid="$1" html
	html="$(dig.http.get "https://www.youtube.com/watch?v=$vid")" || return 1
	printf '%s' "$html" | parse.json.embedded ytInitialPlayerResponse
}

source.register youtube "YouTube 视频搜索（-t 补发布日期与简介，字幕不可得）" "tier:niche period:no proxy:yes key:none"
