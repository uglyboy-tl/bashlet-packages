#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# V2EX。关键词搜索走第三方 sov2ex（官方没有搜索 API）；不带查询词时给热帖。
# v2ex.com 本机直连不通（搜索走 sov2ex 所以不受影响），按 URL 取主题则走云端浏览器——
# 顺带把「回复楼层」这个老缺口补上：渲染出来的 markdown 里带回复（表格形态，见 v2ex.map_topic）。

import core/log

import browser
import common
import schema
import source

v2ex.probe() { dig.http.probe "https://www.v2ex.com/api/topics/hot.json"; }

v2ex.search() {
	local out
	if [[ -z $DIG_QUERY ]]; then
		out="$(dig.http.get "https://www.v2ex.com/api/topics/hot.json")" || return 1
		printf '%s' "$out" | v2ex.map_hot | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
		return 0
	fi

	# sov2ex 默认按相关度排，会跨年份；按时间排才能让时间窗口过滤有意义
	out="$(dig.http.get "https://www.sov2ex.com/api/search" "q=$DIG_QUERY" "size=$DIG_LIMIT" "sort=created")" || return 1
	printf '%s' "$out" | v2ex.map_search | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
}

v2ex.map_hot() {
	"$(schema.jq.bin)" -c --arg query "" '
    .[]
    | {
        source: "v2ex",
        id: (.id | tostring),
        url: .url,
        title: (.title // ""),
        text: (.content // ""),
        author: "",
        created_at: ((.created // 0) | if . > 0 then todateiso8601 else "" end),
        engagement: { replies: (.replies // 0) },
        tags: ([.node.name] | map(select(. != null and . != ""))),
        query: $query
      }'
}

# sov2ex 的 created 是「北京时间、无时区」的字符串（如 2017-05-04T09:38:57），
# 按 UTC 解析后减 8 小时才是真正的 UTC 时刻。
v2ex.map_search() {
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" '
    .hits[]?
    | ._source
    | {
        source: "v2ex",
        id: (.id | tostring),
        url: ("https://www.v2ex.com/t/" + (.id | tostring)),
        title: (.title // ""),
        text: (.content // ""),
        author: (.member // ""),
        created_at: ((.created // "")
          | (try (strptime("%Y-%m-%dT%H:%M:%S") | mktime - 28800 | todateiso8601) catch "")),
        engagement: { replies: (.replies // 0) },
        tags: [],
        query: $query
      }'
}

# 主题 URL：/t/<id>（可选 ?p=<页>、#replyN）
v2ex.url.id() {
	local u="$1"
	if [[ $u =~ /t/([0-9]+) ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

# 按 URL 取主题：交给云端浏览器渲染整页（本机到不了 www.v2ex.com）
v2ex.search_url() {
	local url="$1" id
	id="$(v2ex.url.id "$url")" || {
		log.error "不是合法的 V2EX 主题 URL：$url（形如 www.v2ex.com/t/123456）"
		return 1
	}
	browser.creds.check || {
		log.error '本机直连 www.v2ex.com 不通，取主题需要 Cloudflare Browser Run 凭证（见 env.example）'
		return 1
	}
	browser.page "https://www.v2ex.com/t/$id" | v2ex.map_topic "$id" | schema.pipe 0 | schema.limit 1
}

# 云端浏览器给的是渲染后的整页 markdown：裁掉导航/广告/页脚，保留主题正文 + 回复表格
v2ex.map_topic() {
	local id="$1"
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" --arg id "$id" --arg url "https://www.v2ex.com/t/$id" '
    def opt($s; $re): if ($s | test($re)) then ($s | capture($re) | .v) else "" end;
    def trim_text:
      sub("(?ms)^.*?(?=^# )"; "")            # 标题之前的导航与广告
      | sub("(?s)\nVERSION:.*$"; "")        # 页脚
      | sub("^\\s+"; "") | sub("\\s+$"; "");
    (.text | trim_text) as $t
    | {
        source: "v2ex",
        id: $id,
        url: $url,
        title: (.title // ""),
        text: $t,
        author: (if (.author // "") != "" then .author else opt($t; "/member/(?<v>[^)]*)\\)") end),
        created_at: "",
        engagement: { replies: (opt($t; "(?<v>[0-9]+) replies?") | tonumber? // 0) },
        tags: [],
        query: $query
      }'
}

source.url.register v2ex v2ex.com
source.register v2ex "V2EX 热帖与关键词搜索（搜索走 sov2ex）" "tier:topic period:yes proxy:yes key:none"
