#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# Hacker News（Algolia）。免密钥；points 不能做 numericFilters，窗口只能用 created_at_i。
# -T/--type stories|comments：stories 找帖子，comments 直接在评论语料里搜
#   （「谁在哪条帖子下说过 X」是 HN 最值钱的用法）。
# -c N 在 stories 模式下把前 N 条的评论树抓进 text。

import core/log

import common
import parse
import schema
import source

# 单条故事最多取几条评论、单条评论最短多少字（过滤 "SABR" 这类噪音）
_HN_COMMENT_KEEP=12
_HN_COMMENT_MIN=24

hn.options() {
	args.add_options "type" "T" "搜索类型 stories|comments，默认 stories" "STRING"
	args.add_options "comments" "c" "为前 N 条故事抓评论树填进 text（仅 stories 模式）" "NUMBER"
}

hn.probe() { dig.http.probe "https://hn.algolia.com/api/v1/search?query=test&hitsPerPage=1"; }

# 从 item URL 抠出条目号：news.ycombinator.com/item?id=123
hn.url.id() {
	local u="$1"
	if [[ $u =~ [\?\&]id=([0-9]+) ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

hn.search() {
	[[ -n $DIG_QUERY ]] || {
		log.error '需要查询词：dig hn "关键词"（-T comments 可直接搜评论）'
		return 1
	}

	local type
	type="$(dig.opt -T --type)"
	case "${type:-stories}" in
		stories) hn.search_stories ;;
		comments) hn.search_comments ;;
		*)
			log.error "未知类型: $type（可选 stories / comments）"
			return 1
			;;
	esac
}

hn.search_stories() {
	local body
	body="$(dig.http.get "https://hn.algolia.com/api/v1/search" \
		"query=$DIG_QUERY" \
		"tags=story" \
		"hitsPerPage=$DIG_LIMIT" \
		"numericFilters=created_at_i>$DIG_AFTER")" || return 1

	local n
	n="$(dig.opt.natural 0 -c --comments)" || return 1

	printf '%s' "$body" | hn.map | schema.enrich "$n" hn.enrich_one | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
}

# 单条：items 端点返回一个 item，字段与 search 的 hit 不同；先对齐成 hit 再走 hn.map，
# 避免为直取另写一套字段映射。`text` 是 Ask HN 正文（链接帖通常为空）。
hn.search_url() {
	local url="$1" id body
	id="$(hn.url.id "$url")" || {
		log.error "不是合法的 HN item URL：$url"
		return 1
	}
	body="$(dig.http.get "https://hn.algolia.com/api/v1/items/$id")" || return 1
	printf '%s' "$body" | "$(schema.jq.bin)" -c '
        { hits: [ {
            objectID: (.id | tostring),
            title: (.title // ""),
            url: .url,
            story_text: (.text // ""),
            author: (.author // ""),
            created_at: (.created_at // ""),
            points: (.points // 0),
            num_comments: ((.children // []) | length),
            _tags: ([.type] | map(select(. != null and . != "")))
          } ] }' | hn.map | schema.pipe 0 | schema.limit 1
}

hn.search_comments() {
	local body
	body="$(dig.http.get "https://hn.algolia.com/api/v1/search" \
		"query=$DIG_QUERY" \
		"tags=comment" \
		"hitsPerPage=$DIG_LIMIT" \
		"numericFilters=created_at_i>$DIG_AFTER")" || return 1

	printf '%s' "$body" | hn.map_comments | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
}

hn.map() {
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" "$_SCHEMA_JQ_LIB"'
    (.hits // [])[]
    | {
        source: "hn",
        id: (.objectID | tostring),
        url: (.url // ("https://news.ycombinator.com/item?id=" + .objectID)),
        title: (.title // .story_title // ""),
        text: ((.story_text // "") | html_text),
        author: (.author // ""),
        created_at: (.created_at // ""),
        engagement: { points: (.points // 0), comments: (.num_comments // 0) },
        tags: ((._tags // []) | map(select(test("^(author|story)_") | not))),
        query: $query
      }'
}

hn.map_comments() {
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" "$_SCHEMA_JQ_LIB"'
    (.hits // [])[]
    | {
        source: "hn",
        id: (.objectID | tostring),
        url: ("https://news.ycombinator.com/item?id=" + .objectID),
        title: (.story_title // "(无标题)"),
        text: ((.comment_text // "") | html_text),
        author: (.author // ""),
        created_at: (.created_at // ""),
        engagement: { points: (.points // 0) },
        tags: ((._tags // []) | map(select(test("^(author|story)_") | not))),
        query: $query
      }'
}

hn.enrich_one() {
	local line="$1" id item text
	id="$(printf '%s' "$line" | "$(schema.jq.bin)" -r '.id // empty')"
	[[ -n $id ]] || {
		printf '%s' "$line"
		return 0
	}
	if item="$(dig.http.get "https://hn.algolia.com/api/v1/items/$id")"; then
		text="$(printf '%s' "$item" | hn.comments_text)"
	else
		text=""
	fi
	parse.json.patch "$line" "text=$text"
}

# 评论树是嵌套的；`..` 是前序遍历，等于按 HN 自己的排序取评论
hn.comments_text() {
	"$(schema.jq.bin)" -r --argjson keep "$_HN_COMMENT_KEEP" --argjson min "$_HN_COMMENT_MIN" "$_SCHEMA_JQ_LIB"'
    [ .. | objects | select(.text? != null) | (.text | html_text) ]
    | map(select(length >= $min))
    | .[0:$keep]
    | join("\n\n---\n\n")'
}

source.url.register hn news.ycombinator.com
source.register hn "Hacker News（-T stories|comments，-c N 抓评论树）" "tier:core period:yes proxy:no key:none"
