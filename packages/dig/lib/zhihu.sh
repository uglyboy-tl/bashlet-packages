#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# 知乎官方开放平台。需要免费 Access Secret（developer.zhihu.com/personal）。
# 能力边界：搜索 / 热榜 / 问题回答摘要；拿不到任意用户主页或通用评论（那需要 x-zse-96 签名）。

import core/log

import common
import schema
import source

zhihu.probe() {
	if ! zhihu.credential > /dev/null 2>&1; then
		printf '设置 ZHIHU_ACCESS_SECRET，或写 ~/.config/zhihu-search/credentials.json'
		return 3
	fi
	if zhihu.fetch /api/v1/quota > /dev/null 2>&1; then
		printf '凭证有效，开发者接口可达'
		return 0
	fi
	printf '凭证或接口异常'
	return 1
}

zhihu.options() {
	args.add_options "hot" "H" "取知乎热榜（忽略查询词）"
}

# 凭证读取顺序：ZHIHU_ACCESS_SECRET > $ZHIHU_SEARCH_HOME|~/.config/zhihu-search/credentials.json
zhihu.credential() {
	if [[ -n ${ZHIHU_ACCESS_SECRET:-} ]]; then
		printf '%s' "$ZHIHU_ACCESS_SECRET"
		return 0
	fi

	local dir="${ZHIHU_SEARCH_HOME:-$HOME/.config/zhihu-search}"
	local file="$dir/credentials.json"
	if [[ -f $file ]]; then
		local s
		s="$("$(schema.jq.bin)" -r '.access_secret // empty' "$file" 2> /dev/null || true)"
		if [[ -n $s ]]; then
			printf '%s' "$s"
			return 0
		fi
		log.error "凭证文件 $file 缺少 access_secret 字段"
		return 1
	fi

	log.error "缺少知乎凭证：设置 ZHIHU_ACCESS_SECRET，或写入 $file 的 {\"access_secret\":\"...\"}；免费申请 https://developer.zhihu.com/personal"
	return 1
}

zhihu.fetch() {
	local path="$1"
	shift
	local secret
	secret="$(zhihu.credential)" || return 1

	dig.requests.init || return 1
	requests.headers.append "Authorization" "Bearer $secret"
	requests.headers.append "X-Request-Timestamp" "$(date -u +%s)"

	local resp code rc
	resp="$(requests.get "https://developer.zhihu.com$path" "$@")" || return 1
	code="$(requests.status_code "$resp")"
	rc="$(requests.exit_code "$resp")"
	# 传输层失败时 status_code 是 0 而不是 000（见 dig.http.probe 的注释）
	if [[ -n $rc && $rc != 0 ]] || [[ $code == 0 || $code == 000 ]]; then
		log.error "无法连接 developer.zhihu.com：网络不通（curl exit ${rc:-未知}）"
		return 1
	fi
	[[ $(requests.success "$resp") == "true" ]] || {
		log.error "知乎接口返回 HTTP $code"
		return 1
	}
	requests.text "$resp"
}

zhihu.check() {
	"$(schema.jq.bin)" -c '
    def hint($c):
      if $c == 10001 then "（参数错误）"
      elif $c == 20001 then "（token 无效或过期，去 developer.zhihu.com/personal 重新生成）"
      elif $c == 30001 then "（触发频率限制，稍后重试）"
      elif $c == 30002 then "（当日配额用尽）"
      elif $c == 30003 then "（风控拦截）"
      else "" end;
    if (.Code // 0) != 0 then
      error("知乎错误 \(.Code)\(hint(.Code))：\(.Message // "未知错误")")
    else . end'
}

zhihu.search() {
	zhihu.credential > /dev/null || return 1

	local count="$DIG_LIMIT"

	if args.has "-H" "--hot"; then
		((count > 30)) && count=30
		local hot_body
		hot_body="$(zhihu.fetch /api/v1/content/hot_list "Limit=$count")" || return 1
		printf '%s' "$hot_body" | zhihu.check | zhihu.hot.map | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
		return $?
	fi

	[[ -n $DIG_QUERY ]] || {
		log.error '需要查询词：dig zhihu "关键词"（或加 -H 取热榜）'
		return 1
	}
	((count > 10)) && count=10

	local body
	body="$(zhihu.fetch /api/v1/content/zhihu_search "Query=$DIG_QUERY" "Count=$count")" || return 1
	printf '%s' "$body" | zhihu.check | zhihu.map | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
}

zhihu.map() {
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" '
    (.Data.Items // [])[]
    | {
        source: "zhihu",
        id: ((.Url // "") | if . == "" then (.Title // "?") else . end),
        url: (.Url // ""),
        title: (.Title // ""),
        text: (.ContentText // ""),
        author: (.AuthorName // ""),
        created_at: ((.EditTime // 0) | if . > 0 then todateiso8601 else "" end),
        engagement: { votes: (.VoteUpCount // 0), comments: (.CommentCount // 0) },
        tags: ([.ContentType] | map(select(. != null and . != ""))),
        query: $query
      }'
}

zhihu.hot.map() {
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" '
    (.Data.Items // [])[]
    | {
        source: "zhihu",
        id: ((.Url // "") | if . == "" then (.Title // "?") else . end),
        url: (.Url // ""),
        title: (.Title // ""),
        text: (.Summary // ""),
        author: "",
        created_at: "",
        engagement: {},
        tags: ["hot"],
        query: $query
      }'
}

source.register zhihu "知乎搜索 / 热榜" "tier:topic period:yes proxy:no key:required" "" "ZHIHU_ACCESS_SECRET"
