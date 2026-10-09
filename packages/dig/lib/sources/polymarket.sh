#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# Polymarket 预测市场。独特增量：真金白银的赔率与成交量，任何论坛都拿不到。
# 本机 DNS 不通，必须走代理。

import core/log

import common
import schema
import source

read -r -d '' _POLYMARKET_MAP_JQ << 'JQ' || true
    def num: if type == "number" then . elif type == "string" then (tonumber? // 0) else 0 end;
    .events[]?
    | {
        source: "polymarket",
        id: (.slug // (.id | tostring)),
        url: ("https://polymarket.com/event/" + (.slug // "")),
        title: (.title // ""),
        text: ([.markets[]? | .question] | map(select(. != null and . != "")) | join(" / ")),
        author: "",
        created_at: "",
        engagement: { volume: (.volume | num), liquidity: (.liquidity | num) },
        tags: ["prediction-market"],
        query: $query
      }
JQ

polymarket.probe() { dig.http.probe "https://gamma-api.polymarket.com/public-search?q=test&page=1"; }

# 从 event/market URL 抠出 slug
polymarket.url.slug() {
	local u="$1"
	if [[ $u =~ /(event|market)/([^/?#]+) ]]; then
		printf '%s' "${BASH_REMATCH[2]}"
		return 0
	fi
	return 1
}

polymarket.search() {
	[[ -n $DIG_QUERY ]] || {
		log.error '需要查询词：dig polymarket "事件关键词"'
		return 1
	}

	local out
	out="$(dig.http.get "https://gamma-api.polymarket.com/public-search" \
		"q=$DIG_QUERY" "page=1" "events_status=active" "keep_closed_markets=0")" || return 1
	printf '%s' "$out" | polymarket.map | schema.pipe 0 | schema.limit "$DIG_LIMIT"
}

# 单条：仍走已验证的 public-search，再按 slug 精确匹配 event（或它下面的 market）
polymarket.search_url() {
	local url="$1" slug out
	slug="$(polymarket.url.slug "$url")" || {
		log.error "不是合法的 Polymarket URL：$url"
		return 1
	}
	out="$(dig.http.get "https://gamma-api.polymarket.com/public-search" \
		"q=$slug" "page=1" "events_status=active" "keep_closed_markets=0")" || return 1
	printf '%s' "$out" | json.run -c --arg slug "$slug" '
        { events: [ (.events // [])[] | select(.slug == $slug or ([.markets[]?.slug] | index($slug))) ] }' |
		polymarket.map | schema.pipe 0 | schema.limit 1
}

polymarket.map() {
	schema.jq -c "$_POLYMARKET_MAP_JQ"
}

source.url.register polymarket polymarket.com
source.register polymarket "Polymarket 预测市场赔率与成交量" "tier:niche period:no proxy:yes key:none"
