#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# arXiv。免密钥；必须 https，返回是 Atom XML —— 解析交给 lib/parse.sh
# （`parse.xml.records entry ...` 一次 jq 出 TSV），本源不再自带 awk 解析器。
# 论文不按天出，默认窗口比其他源宽。

import core/log

import common
import parse
import schema
import source

# 该源的默认时间窗口（用户没显式给 -p 时生效）
arxiv.probe() { dig.http.probe "https://export.arxiv.org/api/query?search_query=all:test&max_results=1"; }

arxiv.search() {
	[[ -n $DIG_QUERY ]] || {
		log.error '需要查询词：dig arxiv "主题"'
		return 1
	}

	# arXiv 侧不支持时间过滤，靠 schema.pipe 客户端兜底；多取一些再筛
	local fetch=$((DIG_LIMIT * 5))
	((fetch > 100)) && fetch=100

	local body
	body="$(dig.http.get "https://export.arxiv.org/api/query" \
		"search_query=all:\"$DIG_QUERY\"" \
		"start=0" \
		"max_results=$fetch" \
		"sortBy=relevance" \
		"sortOrder=descending")" || return 1

	printf '%s' "$body" | arxiv.map | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
}

# Atom -> TSV：published / id / title / summary / 全部作者
arxiv.map() {
	parse.xml.records entry 'published,id,title,summary,*name' |
		"$(schema.jq.bin)" -R -s -c --arg query "${DIG_QUERY:-}" '
    [ split("\n")[] | select(length > 0) | split("\t") ][]
    | {
        source: "arxiv",
        id: .[1],
        url: (.[1] | sub("^http://"; "https://")),
        title: .[2],
        text: .[3],
        author: .[4],
        created_at: .[0],
        engagement: {},
        tags: [],
        query: $query
      }'
}

source.register arxiv "arXiv 论文摘要" "tier:topic period:pastyear proxy:no key:none" "" ""
