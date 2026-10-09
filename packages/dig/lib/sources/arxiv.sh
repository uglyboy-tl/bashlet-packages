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

read -r -d '' _ARXIV_MAP_JQ << 'JQ' || true
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
      }
JQ

# 该源的默认时间窗口（用户没显式给 -p 时生效）
arxiv.probe() { dig.http.probe "https://export.arxiv.org/api/query?search_query=all:test&max_results=1"; }

# 从论文 URL 抠出 id：/abs/2103.00112v1 或 /pdf/2103.00112.pdf
arxiv.url.id() {
	local u="$1" id
	if [[ $u =~ /(abs|pdf)/([^/?#]+) ]]; then
		id="${BASH_REMATCH[2]}"
		id="${id%.pdf}"
		printf '%s' "$id"
		return 0
	fi
	return 1
}

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

# 单条：id_list 查询返回同样的 Atom feed，直接复用 arxiv.map
arxiv.search_url() {
	local url="$1" id body
	id="$(arxiv.url.id "$url")" || {
		log.error "不是合法的 arXiv 论文 URL：$url"
		return 1
	}
	body="$(dig.http.get "https://export.arxiv.org/api/query" "id_list=$id" "max_results=1")" || return 1
	printf '%s' "$body" | arxiv.map | schema.pipe 0 | schema.limit 1
}

# Atom -> TSV：published / id / title / summary / 全部作者
arxiv.map() {
	parse.xml.records entry 'published,id,title,summary,*name' |
		schema.jq -R -s -c "$_ARXIV_MAP_JQ"
}

source.url.register arxiv arxiv.org
source.register arxiv "arXiv 论文摘要" "tier:topic period:pastyear proxy:no key:none"
