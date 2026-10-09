#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# 微信读书 agent gateway。单网关 POST，body 里用 api_name 选接口。
# 需要 WEREAD_API_KEY（环境变量或包内 .env）。
# 只产出书目元数据（评分 / 在读人数 / 作者），没有评论区。

import core/log

import common
import parse
import schema
import source

weread.probe() {
	if ! weread.key > /dev/null 2>&1; then
		printf '设置 WEREAD_API_KEY（写进包内 .env）'
		return 3
	fi
	if weread.api.call /store/search keyword test scope 10 count 1 > /dev/null 2>&1; then
		printf '凭证有效，网关可达'
		return 0
	fi
	printf '凭证或网关异常'
	return 1
}

_WEREAD_GATEWAY="https://i.weread.qq.com/api/agent/gateway"
# 网关校验这个字段。它只作为「告知」用：旧版本仍能取到数据，所以过期时只 warn，不 fail。
_WEREAD_SKILL_VERSION="1.0.4"
# 凭证只看 WEREAD_API_KEY（环境变量或包内 .env）。原来还有一条 `pass weread` 的回退，
# 已移除：key 只在一个地方配，缺了就直说。
weread.key() {
	if [[ -n ${WEREAD_API_KEY:-} ]]; then
		printf '%s' "$WEREAD_API_KEY"
		return 0
	fi
	log.error "缺少微信读书凭证：设置 WEREAD_API_KEY（写进包内 .env 即可）；取：https://weread.qq.com/r/weread-skills"
	return 1
}

# 组装请求体 {api_name, skill_version, ...}；纯数字参数走 argjson，其余走 arg
weread.body() {
	local api_name="$1"
	shift
	# 参数必须成对（key value）：落单的那个会被 while 静默丢掉，不如直接报出来
	(($# % 2 == 0)) || {
		log.error "参数必须成对给出：$*"
		return 1
	}
	local filter='{api_name:$api, skill_version:$ver}'
	local -a jqargs=(--arg api "$api_name")
	local i=0
	while [[ $# -ge 2 ]]; do
		filter+=" + {(\$k$i): \$v$i}"
		if [[ $2 =~ ^-?[0-9]+$ ]]; then
			jqargs+=(--arg "k$i" "$1" --argjson "v$i" "$2")
		else
			jqargs+=(--arg "k$i" "$1" --arg "v$i" "$2")
		fi
		shift 2
		i=$((i + 1))
	done
	json.run -n --arg ver "$_WEREAD_SKILL_VERSION" "$filter" "${jqargs[@]}"
}

weread.api.call() {
	local api_name="$1"
	shift
	local key body
	key="$(weread.key)" || return 1
	body="$(weread.body "$api_name" "$@")" || return 1

	dig.requests.init || return $?
	requests.headers.append "Authorization" "Bearer $key"

	# 与 zhihu 同理：只走重试层，偶发的传输层抖动不该被报成「源挂了」
	dig.http.request POST "$_WEREAD_GATEWAY" "$body" "application/json"
}

# 网关的 errcode 才是真错误；upgrade_info 只是「有新版本」的告知，不阻断取数
weread.check() {
	local body="$1" code up
	up="$(printf '%s' "$body" | json.run -r '.upgrade_info.message // empty')"
	[[ -n $up ]] && log.warn "$up"
	code="$(printf '%s' "$body" | json.run -r '.errcode // 0')"
	[[ $code == "0" ]] || {
		log.error "微信读书网关错误 errcode=$code"
		return 1
	}
	return 0
}

# /store/search 的 scope 取值，见 docs/sources.md
declare -ga _WEREAD_SCOPES=(10 16 14 6 12 13 2 4)

weread.options() {
	args.add_options "scope" "s" "搜索类型 10=电子书(默认) 16=网文 14=有声书 6=作者 12=全文 13=书单 2=公众号 4=文章" "NUMBER"
	args.add_options "info" "i" "为前 N 本抓简介填进 text（每本 1 个请求，默认 0）" "NUMBER"
}

weread.search() {
	[[ -n $DIG_QUERY ]] || {
		log.error '需要查询词：dig weread "书名或关键词"'
		return 1
	}

	# 非法值报错而不是静默回落（否则用户以为生效了）
	local scope
	scope="$(dig.opt.natural 10 -s --scope)" || return 1
	array.contains _WEREAD_SCOPES "$scope" || {
		log.error "无效的 -s/--scope：$scope（可选：${_WEREAD_SCOPES[*]}）"
		return 1
	}

	local body
	body="$(weread.api.call /store/search keyword "$DIG_QUERY" scope "$scope" count "$DIG_LIMIT")" || return 1
	weread.check "$body" || return 1

	# 书目没有时间维度，不套时间窗口（created_at 留空，schema.pipe 会保留）
	local n
	n="$(dig.opt.natural 0 -i --info)" || return 1

	printf '%s' "$body" | weread.map | schema.pipe 0 |
		schema.enrich "$n" weread.enrich_one | schema.limit "$DIG_LIMIT"
}

weread.map() {
	json.run -c --arg query "${DIG_QUERY:-}" '
    [ .results[]? as $r | $r.books[]? | { group: ($r.title // ""), book: . } ]
    | map(select(.book.bookInfo.bookId != null))
    | reduce .[] as $x (
        { seen: {}, out: [] };
        ($x.book.bookInfo.bookId) as $id
        | if .seen[$id] then . else .seen[$id] = true | .out += [$x] end
      )
    | .out[]
    | (.book.bookInfo) as $b
    | {
        source: "weread",
        id: $b.bookId,
        url: ($b.deepLink // ""),
        title: ($b.title // ""),
        text: "",
        author: ($b.author // ""),
        created_at: "",
        engagement: {
          rating: ($b.newRating // 0),
          ratings: ($b.newRatingCount // 0),
          reading: (.book.readingCount // 0)
        },
        tags: ([ $b.newRatingDetail.title, .group ] | map(select(. != null and . != ""))),
        query: $query
      }'
}

# -i N：为前 N 本抓 /book/info，把简介填进 text。
# 书目条目的用处就是「值不值得读」，而 /store/search 不返回简介（intro 只在详情里）。
# 失败时保留原行——这是 schema.enrich 的契约：不能用空串把上游的行吞掉。
weread.enrich_one() {
	local line="$1" id info text
	id="$(printf '%s' "$line" | json.run -r '.id // empty')"
	[[ -n $id ]] || {
		printf '%s' "$line"
		return 0
	}
	if info="$(weread.api.call /book/info bookId "$id")"; then
		text="$(printf '%s' "$info" | json.run -r '.intro // ""')"
	else
		text=""
	fi
	parse.json.patch "$line" "text=$text"
}

source.register weread "微信读书书目（无评论区）" "tier:niche period:no proxy:no key:required"
