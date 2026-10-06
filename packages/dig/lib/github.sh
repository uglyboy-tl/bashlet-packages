#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# GitHub（走 gh，自动带认证）。
# -T/--type 切换搜什么：
#   issues  默认，issue / PR 正文与评论数（库的「现在的状态」）
#   repos   找项目（star 数、语言、最近更新）
#   code    找实现（哪个仓库的哪个文件里有这段代码）—— 注意 gh 对 code search 限流 10 次/分
#   commits 找最近改动

import core/log

import common
import schema
import source

github.options() {
	args.add_options "type" "T" "搜索类型 issues|repos|code|commits|discussions，默认 issues（repos 的时间轴是最后更新）" "STRING"
}

github.probe() {
	local user
	user="$(gh api user --jq .login 2> /dev/null || true)"
	[[ -n $user ]] && {
		printf 'gh 已认证（%s）' "$user"
		return 0
	}
	printf 'gh 已安装但未认证，先跑 gh auth login'
	return 1
}

github.search() {
	[[ -n $DIG_QUERY ]] || {
		log.error '需要查询词：dig github "关键词"（-T issues|repos|code|commits）'
		return 1
	}

	local type
	type="$(dig.opt -T --type)"
	case "${type:-issues}" in
		issues) github.search_issues ;;
		repos) github.search_repos ;;
		code) github.search_code ;;
		commits) github.search_commits ;;
		discussions) github.search_discussions ;;
		*)
			log.error "未知类型: $type（可选 issues / repos / code / commits / discussions）"
			return 1
			;;
	esac
}

github.search_issues() {
	local -a created=()
	((DIG_AFTER > 0)) && created=(--created ">=$(schema.epoch.date "$DIG_AFTER")")

	gh search issues "$DIG_QUERY" \
		--limit "$DIG_LIMIT" \
		--json number,title,url,state,body,author,createdAt,commentsCount,repository,isPullRequest \
		"${created[@]}" | github.map_issues | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
}

github.search_repos() {
	gh search repos "$DIG_QUERY" \
		--limit "$DIG_LIMIT" \
		--json fullName,url,description,stargazersCount,forksCount,createdAt,updatedAt,language |
		github.map_repos | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
}

github.search_code() {
	gh search code "$DIG_QUERY" \
		--limit "$DIG_LIMIT" \
		--json path,repository,url |
		github.map_code | schema.pipe 0 | schema.limit "$DIG_LIMIT"
}

github.search_commits() {
	gh search commits "$DIG_QUERY" \
		--limit "$DIG_LIMIT" \
		--json sha,commit,repository,url |
		github.map_commits | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
}

# Discussions 只能走 GraphQL；search(type:DISCUSSION) 支持跨仓库关键词搜索
github.search_discussions() {
	local q="$DIG_QUERY"
	((DIG_AFTER > 0)) && q+=" created:>=$(schema.epoch.date "$DIG_AFTER")"

	# GraphQL search 连接的 first 上限是 100，超过直接报 EXCESSIVE_PAGINATION（实测 101 即失败）
	local n="$DIG_LIMIT"
	if ((n > 100)); then
		n=100
		log.warn "GitHub 搜索的 GraphQL 上限是 100 条，-n $DIG_LIMIT 按 100 处理"
	fi

	gh api graphql \
		-f query='query($q:String!,$n:Int!){search(query:$q,type:DISCUSSION,first:$n){nodes{... on Discussion{number title url createdAt body upvoteCount category{name} answer{isAnswer} comments{totalCount} author{login} repository{nameWithOwner}}}}}' \
		-F q="$q" -F n="$n" |
		github.map_discussions | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
}

github.map_issues() {
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" '
    .[]
    | {
        source: "github",
        id: ((.repository.nameWithOwner // "?") + "#" + (.number | tostring)),
        url: .url,
        title: .title,
        text: (.body // ""),
        author: (.author.login // ""),
        created_at: (.createdAt // ""),
        engagement: { comments: (.commentsCount // 0) },
        tags: ([ .state, (if .isPullRequest then "pr" else "issue" end) ] | map(select(. != null and . != ""))),
        query: $query
      }'
}

github.map_repos() {
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" '
    .[]
    | {
        source: "github",
        id: .fullName,
        url: .url,
        title: .fullName,
        text: (.description // ""),
        author: (.fullName | split("/")[0]),
        # 项目是长期存在的：时间轴取「最后更新」而不是「创建」，这样 -p 筛的是还在维护的项目
        created_at: (.updatedAt // .createdAt // ""),
        engagement: { stars: (.stargazersCount // 0), forks: (.forksCount // 0) },
        tags: ((.language // "") | tostring | if . == "" then [] else [ . ] end),
        query: $query
      }'
}

github.map_code() {
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" '
    .[]
    | {
        source: "github",
        id: .url,
        url: .url,
        title: ((.repository.nameWithOwner // "?") + ": " + .path),
        text: "",
        author: ((.repository.nameWithOwner // "/") | split("/")[0]),
        created_at: "",
        engagement: {},
        tags: ["code"],
        query: $query
      }'
}

# 提交时间带时区偏移（如 +08:00），统一转 UTC
github.map_commits() {
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" "$_SCHEMA_JQ_LIB"'
    .[]
    | {
        source: "github",
        id: .sha,
        url: .url,
        title: ((.commit.message // "") | split("\n")[0]),
        text: (.commit.message // ""),
        author: (.commit.author.name // ""),
        created_at: ((.commit.author.date // "") | to_utc),
        engagement: { comments: (.commit.comment_count // 0) },
        tags: ["commit"],
        query: $query
      }'
}

github.map_discussions() {
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" '
    (.data.search.nodes // [])[]
    | select(.number != null)
    | {
        source: "github",
        id: ((.repository.nameWithOwner // "?") + "#" + (.number | tostring)),
        url: .url,
        title: .title,
        text: (.body // ""),
        author: (.author.login // ""),
        created_at: (.createdAt // ""),
        engagement: { comments: (.comments.totalCount // 0), upvotes: (.upvoteCount // 0) },
        tags: ([ "discussion", (.category.name // ""),
                 (if .answer.isAnswer == true then "answered" else "" end) ]
               | map(select(. != null and . != ""))),
        query: $query
      }'
}

source.register github "GitHub 搜索（-T issues|repos|code|commits|discussions，走 gh）" "tier:core period:yes proxy:no key:none" "gh" ""
