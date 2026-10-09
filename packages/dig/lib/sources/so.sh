#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# Stack Exchange 2.3。免密钥；响应是 gzip，由 requests 的 --compressed 处理。
#
# -s/--site 换网络内的站点（superuser / unix / askubuntu / security / mathoverflow …）。
# -a N 取前 N 条问题的**高赞回答**填进 text —— 问答站真正有价值的是答案，不是问题。
#      回答接口支持 `;` 拼多个 question_id，所以 N 条问题只要 1 次请求。

import core/log

import common
import schema
import source

_SO_TEXT_CAP=4000

so.options() {
	args.add_options "site" "s" "StackExchange 站点，默认 stackoverflow" "STRING"
	args.add_options "answers" "a" "为前 N 条抓高赞回答填进 text（1 次请求，默认 0）" "NUMBER"
}

so.probe() { dig.http.probe "https://api.stackexchange.com/2.3/info?site=stackoverflow"; }

# 从问题 URL 抠出问题号：/questions/123 或 /q/123
so.url.id() {
	local u="$1"
	if [[ $u =~ /(questions|q)/([0-9]+) ]]; then
		printf '%s' "${BASH_REMATCH[2]}"
		return 0
	fi
	return 1
}

# 只认 stackoverflow.com：其它 StackExchange 站点要猜 -s 的 site 名，映射容易错
so.search() {
	[[ -n $DIG_QUERY ]] || {
		log.error '需要查询词：dig so "关键词"（-s 可换 StackExchange 站点）'
		return 1
	}

	local site
	site="$(dig.opt -s --site)"
	[[ -n $site ]] || site="stackoverflow"

	local -a params=(
		"order=desc"
		"sort=relevance"
		"q=$DIG_QUERY"
		"site=$site"
		"pagesize=$(dig.clamp "$DIG_LIMIT" 100 "Stack Exchange")"
		"filter=withbody"
	)
	((DIG_AFTER > 0)) && params+=("fromdate=$DIG_AFTER")

	local body
	body="$(dig.http.get "https://api.stackexchange.com/2.3/search/advanced" "${params[@]}")" || return 1

	local n
	n="$(dig.opt.natural 0 -a --answers)" || return 1

	if ((n > 0)); then
		printf '%s' "$body" | so.map "$site" | so.answers "$n" "$site" | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
	else
		printf '%s' "$body" | so.map "$site" | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
	fi
}

# 单条：questions/<id> 的响应用于 {items:[…]}，与搜索同形，所以直接过 so.map
so.search_url() {
	local url="$1" id body
	id="$(so.url.id "$url")" || {
		log.error "不是合法的 Stack Overflow 问题 URL：$url"
		return 1
	}
	body="$(dig.http.get "https://api.stackexchange.com/2.3/questions/$id" "site=stackoverflow" "filter=withbody")" || return 1
	printf '%s' "$body" | so.map stackoverflow | schema.pipe 0 | schema.limit 1
}

so.map() {
	local site="${1:-stackoverflow}"
	json.run -c --arg query "${DIG_QUERY:-}" --arg site "$site" "$_SCHEMA_JQ_LIB"'
    (.items // [])[]
    | {
        source: "so",
        id: (.question_id | tostring),
        url: .link,
        title: .title,
        text: ((.body // "") | html_text),
        author: (.owner.display_name // ""),
        created_at: ((.creation_date // 0) | if . > 0 then todateiso8601 else "" end),
        engagement: { score: (.score // 0), answers: (.answer_count // 0), views: (.view_count // 0) },
        tags: ((.tags // []) + [ $site ] | unique),
        query: $query
      }'
}

# 先读完 JSONL 拿到前 N 个 id，再一次请求把它们的回答取回来
so.answers() {
	local n="${1:-0}" site="${2:-stackoverflow}"
	local -a lines=() ids=()
	local i=0 line

	while IFS= read -r line; do
		lines+=("$line")
		i=$((i + 1))
		if ((i <= n)); then
			ids+=("$(printf '%s' "$line" | json.run -r '.id // empty')")
		fi
	done

	if ((${#ids[@]} == 0)); then
		((${#lines[@]})) && printf '%s\n' "${lines[@]}"
		return 0
	fi

	local joined answers answers_json="[]"
	joined="$(IFS=';' && echo "${ids[*]}")"
	if answers="$(
		dig.http.get "https://api.stackexchange.com/2.3/questions/$joined/answers" \
			"order=desc" "sort=votes" "site=$site" "filter=withbody" "pagesize=$(dig.clamp "$((n * 3))" 100 "Stack Exchange")"
	)"; then
		answers_json="$(printf '%s' "$answers" | json.run -c '.items // []')"
	fi

	printf '%s\n' "${lines[@]}" | json.run -c \
		--argjson ans "$answers_json" --argjson cap "$_SO_TEXT_CAP" "$_SCHEMA_JQ_LIB"'
    . as $item
    | ([ $ans[] | select(.question_id == ($item.id | tonumber)) ]
       | sort_by([(if .is_accepted then 0 else 1 end), -.score])
       | .[0:2]
       | map("--- 回答（\(.score) 分\(if .is_accepted then "，已采纳" else "" end)）---\n"
             + (.body | html_text))) as $parts
    | if ($parts | length) == 0 then $item
      else $item | .text = (((.text // "") + "\n\n" + ($parts | join("\n\n"))) | .[0:$cap])
      end'
}

source.url.register so stackoverflow.com
source.register so "Stack Exchange 问答（-s 换站点，-a N 抓高赞回答）" "tier:core period:yes proxy:no key:none"
