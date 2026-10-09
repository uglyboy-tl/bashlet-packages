#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# Reddit，走 Arctic Shift（免 key，本机直连可达，不用代理）。
#
# 官方 .json 全 403，免 key 只剩 Arctic Shift 这条路，它有两个硬约束：
#   1. 关键词搜索必须用 subreddit 或 author 圈定 —— **跨全站关键词搜索做不到**（只给 query 会直接报错）。
#      所以 `-s/--subreddit` 是必需项，用来回答「某个社区怎么说 X」，不是「全网怎么说 X」。
#   2. 失败会塞在响应体里（HTTP 200 或 422 都可能带 {"error":"Timeout. Maybe slow down a bit"}），
#      dig.http.request 只按 HTTP 状态判成功，所以这里补一层 reddit.fetch 做体级检查与重试。
#
# -r N 为前 N 条抓嵌套评论树填进 text（一次到位，没有 more stub 要展开）。

import core/log

import common
import parse
import schema
import source

read -r -d '' _REDDIT_COMMENTS_JQ << 'JQ' || true
    [ .. | objects | select(.body? != null and .author? != "AutoModerator") | .body ]
    | map(gsub("\\s+"; " ") | sub("^ +"; "") | sub(" +$"; ""))
    | map(select(length >= $min))
    | .[0:$keep]
    | join("\n\n---\n\n")
JQ

read -r -d '' _REDDIT_MAP_JQ << 'JQ' || true
    (.data // [])[]
    | {
        source: "reddit",
        id: (.id | tostring),
        url: ("https://www.reddit.com/r/" + (.subreddit // "") + "/comments/" + (.id | tostring) + "/"),
        title: (.title // ""),
        text: (.selftext // ""),
        author: (.author // ""),
        created_at: ((.created_utc // 0) | if . > 0 then todateiso8601 else "" end),
        engagement: { score: (.score // 0), comments: (.num_comments // 0) },
        tags: ([.subreddit] | map(select(. != null and . != ""))),
        query: $query
      }
JQ

# 只取要用的字段，避免整条 reddit 帖子（含 preview 图片）把响应撑大。
# 注意：`permalink` 不在 Arctic Shift 的可选字段里（实测报 "'permalink' is not a valid field"），
# 帖子 URL 由 subreddit + id 自己拼。
_REDDIT_FIELDS="id,title,selftext,author,created_utc,score,num_comments,subreddit"
_REDDIT_COMMENT_KEEP=12
_REDDIT_COMMENT_MIN=24

reddit.options() {
	args.add_options "subreddit" "s" "要搜的 subreddit（必填）" "NAME"
	args.add_options "comments" "r" "为前 N 条抓嵌套评论树填进 text" "NUMBER"
}

# Arctic Shift 是单人维护的免费服务，容量背压（422 "Timeout. Maybe slow down a bit"）与连接超时
# 都属偶发。探活连试几次；仍失败时把话说成「上游背压」——报成「网络不通、需设代理」会把人带偏
# （这个域名不需要代理）。
reddit.probe() {
	local out="" rc=1 i
	for i in 1 2 3; do
		if out="$(dig.http.probe "https://arctic-shift.photon-reddit.com/api/posts/search?subreddit=linux&limit=1&fields=id")"; then
			printf '%s' "$out"
			return 0
		else
			# 必须在 else 里取：if 语句在条件失败时整体退出码是 0
			rc=$?
		fi
		if ((i < 3)); then
			sleep "${DIG_PROBE_RETRY_SLEEP:-2}"
		fi
	done
	printf 'Arctic Shift 背压或超时（上游偶发，与代理无关）：%s' "$out"
	return "$rc"
}

# 从帖子 URL 抠出 id：…/comments/<id>、redd.it/<id>（含 old./np. 子域）
reddit.url.id() {
	local u="$1"
	if [[ $u =~ /comments/([A-Za-z0-9]+) ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi
	if [[ $u =~ redd\.it/([A-Za-z0-9]+) ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

# Arctic Shift 的失败有两种形态，都不能静默：
#   - HTTP 422（容量背压，体里常写 "Timeout. Maybe slow down a bit"）：交给 dig.http.request
#     统一重试 —— 站点把背压信号放在非 429/5xx 的状态码上，只能靠 DIG_HTTP_RETRY_CODES 追加。
#   - HTTP 200 但体里带 {"error": ...}：状态码看着是成功，统一层判不出来，所以这里自己退避重试。
reddit.fetch() {
	local url="$1"
	shift
	# 仅本次调用生效：local 是动态作用域，reddit 内部调的 dig.http.request 看得到，
	# 不会留着影响同一进程里后面的请求
	local DIG_HTTP_RETRY_CODES="${DIG_HTTP_RETRY_CODES:+$DIG_HTTP_RETRY_CODES }422"

	local tries=$((${DIG_RETRY:-2} + 1)) i=0 body err
	while :; do
		i=$((i + 1))
		# 状态类失败（422 也在内）dig.http.request 已重试并报过错，这里不再叠加一层
		body="$(dig.http.get "$url" "$@")" || return 1

		err="$(printf '%s' "$body" | json.run -r 'if type == "object" then (.error // "") else "" end' 2> /dev/null || true)"
		if [[ -z $err ]]; then
			printf '%s' "$body"
			return 0
		fi

		if ((i < tries)); then
			log.warn "Arctic Shift 返回错误：$err；$((i * 2))s 后重试（$i/$((tries - 1))）)"
			sleep $((i * 2))
			continue
		fi
		log.error "Arctic Shift 返回错误：$err（已重试 $((i - 1)) 次）"
		return 1
	done
}

reddit.search() {
	local sub
	sub="$(dig.opt -s --subreddit)"
	[[ -n $sub ]] || {
		log.error '需要 -s/--subreddit 圈定社区：Arctic Shift 的免 key 层做不到跨全站关键词搜索（只给 query 不给 subreddit/author 会直接报错）'
		return 1
	}

	local -a params=(
		"subreddit=$sub"
		"limit=$(dig.clamp "$DIG_LIMIT" 100 "Arctic Shift")"
		"sort=desc"
		"fields=$_REDDIT_FIELDS"
	)
	[[ -n $DIG_QUERY ]] && params+=("query=$DIG_QUERY")

	local body
	body="$(reddit.fetch "https://arctic-shift.photon-reddit.com/api/posts/search" "${params[@]}")" || return 1

	local n
	n="$(dig.opt.natural 0 -r --comments)" || return 1

	printf '%s' "$body" | reddit.map | schema.enrich "$n" reddit.enrich_one | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
}

# 单条：posts/ids 响应与 search 同形（{data:[…]}），直接过 reddit.map；-r 仍走现有评论树
reddit.search_url() {
	local url="$1" id body
	id="$(reddit.url.id "$url")" || {
		log.error "不是合法的 Reddit 帖子 URL：$url"
		return 1
	}
	body="$(reddit.fetch "https://arctic-shift.photon-reddit.com/api/posts/ids" "ids=$id" "fields=$_REDDIT_FIELDS")" || return 1

	local n
	n="$(dig.opt.natural 0 -r --comments)" || return 1
	printf '%s' "$body" | reddit.map | schema.enrich "$n" reddit.enrich_one | schema.pipe 0 | schema.limit 1
}

reddit.map() {
	schema.jq -c "$_REDDIT_MAP_JQ"
}

reddit.enrich_one() {
	local line="$1" id item text
	id="$(printf '%s' "$line" | json.run -r '.id // empty')"
	[[ -n $id ]] || {
		printf '%s' "$line"
		return 0
	}
	if item="$(reddit.fetch "https://arctic-shift.photon-reddit.com/api/comments/tree" "link_id=t3_$id" "limit=9999")"; then
		text="$(printf '%s' "$item" | reddit.comments_text)"
	else
		text=""
	fi
	parse.json.patch "$line" "text=$text"
}

# 评论树是嵌套的；`..` 是前序遍历，等于按 Reddit 自己的排序取评论。
# AutoModerator 的自动回复又长又没信息量，按作者名排掉。
reddit.comments_text() {
	json.run -r --argjson keep "$_REDDIT_COMMENT_KEEP" --argjson min "$_REDDIT_COMMENT_MIN" "$_REDDIT_COMMENTS_JQ"
}

source.url.register reddit reddit.com redd.it
source.register reddit "Reddit（-s 必给 subreddit，-r N 抓嵌套评论树；走 Arctic Shift，跨全站搜索做不到）" "tier:topic period:yes proxy:no key:none"
