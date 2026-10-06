#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# V2EX。关键词搜索走第三方 sov2ex（官方没有搜索 API）；不带查询词时给热帖。
# v2ex.com 本机 DNS 不通，必须走代理。

import core/log

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

source.register v2ex "V2EX 热帖与关键词搜索（搜索走 sov2ex）" "tier:topic period:yes proxy:yes key:none" "" ""
