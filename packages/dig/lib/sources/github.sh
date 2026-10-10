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

read -r -d '' _GITHUB_DISCUSSIONS_JQ << 'JQ' || true
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
      }
JQ

read -r -d '' _GITHUB_CODE_JQ << 'JQ' || true
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
      }
JQ

read -r -d '' _GITHUB_MAP_REPOS_JQ << 'JQ' || true
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
      }
JQ

read -r -d '' _GITHUB_MAP_ISSUES_JQ << 'JQ' || true
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
      }
JQ

read -r -d '' _GITHUB_URL_REPO_JQ << 'JQ' || true
            [ {
              fullName: .full_name,
              url: .html_url,
              description: (.description // ""),
              stargazersCount: (.stargazers_count // 0),
              forksCount: (.forks_count // 0),
              createdAt: (.created_at // ""),
              updatedAt: (.updated_at // ""),
              language: (.language // "")
            } ]
JQ

read -r -d '' _GITHUB_URL_ISSUE_JQ << 'JQ' || true
            [ {
              repository: { nameWithOwner: $repo },
              number: .number,
              url: .html_url,
              title: .title,
              body: (.body // ""),
              author: { login: (.user.login // "") },
              createdAt: (.created_at // ""),
              commentsCount: (.comments // 0),
              state: (.state // ""),
              isPullRequest: (.pull_request != null)
            } ]
JQ

read -r -d '' _GITHUB_COMMITS_JQ << 'JQ' || true
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
      }
JQ

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

# URL 的路径部分（去 scheme/host/query/fragment）：github.com/o/r/issues/1 → o/r/issues/1
github.url.path() {
	local u="$1"
	u="${u#*://}"
	u="${u#*/}"
	printf '%s' "${u%%[?#]*}"
}

# 输出 "repo <o> <r>" 或 "issue <o> <r> <n>"；pull 也归到 issue（issues 端点响应里有 pull_request）
github.url.parse() {
	local url="$1" path
	path="$(github.url.path "$url")"
	if [[ $path =~ ^([^/]+)/([^/]+)/(issues|pull)/([0-9]+)(/.*)?$ ]]; then
		printf 'issue %s %s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}"
		return 0
	fi
	if [[ $path =~ ^([^/]+)/([^/]+)$ ]]; then
		printf 'repo %s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
		return 0
	fi
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

# 单条：REST 端点返回 snake_case 单对象，先对齐成 gh search 的 camelCase 形状再走
github.search_url() {
	local url="$1" kind o r n body parsed
	# gist.github.com 是 github.com 的子域，fetch 的子域匹配会把它路由到这里，但 gist 不是仓库：
	# 拿它去问 gh 只会得到一句 "Not Found"。点明替代做法，不让调用者猜。
	if [[ ${url,,} == *gist.github.com* ]]; then
		log.error "gist 不在 dig 的 github 源里"
		return 1
	fi
	parsed="$(github.url.parse "$url")" || {
		log.error "不是合法的 GitHub 仓库 / issue URL：$url"
		return 1
	}
	read -r kind o r n <<< "$parsed"

	if [[ $kind == issue ]]; then
		body="$(gh api "repos/$o/$r/issues/$n")" || return 1
		printf '%s' "$body" | json.run -c --arg repo "$o/$r" "$_GITHUB_URL_ISSUE_JQ" | github.map_issues | schema.pipe 0 | schema.limit 1
	else
		body="$(gh api "repos/$o/$r")" || return 1
		printf '%s' "$body" | json.run -c "$_GITHUB_URL_REPO_JQ" | github.map_repos | schema.pipe 0 | schema.limit 1
	fi
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
	schema.jq -c "$_GITHUB_MAP_ISSUES_JQ"
}

github.map_repos() {
	schema.jq -c "$_GITHUB_MAP_REPOS_JQ"
}

github.map_code() {
	schema.jq -c "$_GITHUB_CODE_JQ"
}

# 提交时间带时区偏移（如 +08:00），统一转 UTC
github.map_commits() {
	schema.jq -c "$_GITHUB_COMMITS_JQ"
}

github.map_discussions() {
	schema.jq -c "$_GITHUB_DISCUSSIONS_JQ"
}

source.url.register github github.com
source.register github "GitHub 搜索（-T issues|repos|code|commits|discussions，走 gh）" "tier:core period:yes proxy:no key:none" "gh"
