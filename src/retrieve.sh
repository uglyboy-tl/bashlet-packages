#!/usr/bin/env bash

set -euo pipefail
SCRIPT_NAME="Retrieve"
VERSION="0.1.0"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

.env
import std/string
import std/array
import core/log
import core/args
import core/usage
import ext/requests

DEFUDDLE_BASE_URL="https://defuddle.md"
declare -ga EXA_VALID_TYPES=("neural" "keyword" "hybrid" "fast" "deep" "deep-reasoning" "deep-max" "magic" "instant")
declare -ga EXA_VALID_CATEGORIES=("company" "research paper" "news" "tweet" "personal site" "financial report" "people")
declare -ga HN_VALID_TAGS=("story" "comment" "poll" "pollopt" "show_hn" "ask_hn" "front_page")

main() {
	args.name "retrieve"
	args.init "信息检索工具 - 支持多种检索源"
	args.add_options "version" "v" "显示版本信息"
	args.add_options "help" "h" "显示帮助信息"
	args.add_subcommand "fetch" "查看普通网页" "cmd_fetch"
	args.add_subcommand "github" "GitHub调试信息检索" "cmd_github"
	args.add_subcommand "hackernews" "Hacker News 技术新闻检索" "cmd_hackernews"
	args.add_subcommand "exa" "Exa AI 网络搜索" "cmd_exa_search"
	args.process "$@"
	args.has "-v" "--version" && usage.version && exit 0
}

cmd_fetch() {
	args.init "查看普通网页"
	args.add_options "ARG" "url" "网页网址"
	args.process "$@"
	declare -n position_args=$(args.args)
	[[ ${#position_args[@]} -eq 0 ]] && log.error "请提供要访问的URL" && exit 1

	requests.init
	local target="${position_args[0]}"
	local response=$(requests.get "$DEFUDDLE_BASE_URL/$target")
	requests.raise_for_status "$response"
	requests.text "$response"
}

cmd_github() {
	args.init "GitHub调试信息检索"
	args.add_options "exact" "" "精确错误消息搜索" "ERROR_MSG"
	args.add_options "closed" "" "在已关闭问题中搜索"
	args.add_options "version" "" "版本特定问题搜索" "VERSION"
	args.add_options "repo" "" "仓库名称" "OWNER/REPO"
	args.add_options "limit" "n" "限制返回结果数量（默认 30）" "NUMBER"
	args.add_options "ARG" "query" "搜索关键词（多个关键词用空格分隔）"
	args.process "$@"
	local exact_query="$(args.get "--exact")" || exact_query=""
	local version_query="$(args.get "--version")" || version_query=""
	local repo="$(args.get "--repo")" || repo=""
	local limit="$(args.get "-n" "--limit")" && string.natural.check "$limit" || limit="30"
	local closed_flag=""
	args.has "--closed" && closed_flag="--state closed"
	declare -n position_args=$(args.args)
	local final_query="${position_args[*]} $exact_query $version_query"
	final_query="$(string.trim "$final_query")"
	local -a gh_args=("--json" "title,url,state,number,author,createdAt" "--limit" "$limit")
	[[ -n $closed_flag ]] && gh_args+=("--state" "closed")
	[[ -n $repo ]] && gh_args+=("--repo" "$repo")
	gh_args+=("$final_query")
	local template='{{range .}}{{.title}}|{{.url}}|{{.state}}|{{.number}}|{{.author.login}}|{{timefmt "2006-01-02" .createdAt}}{{"\n"}}{{end}}'
	gh_args+=("--template" "$template")
	log.info "执行查询: $final_query"
	local result exit_code=0
	result=$(gh search issues "${gh_args[@]}" 2> /dev/null) || exit_code=$?
	if [[ $exit_code -ne 0 ]] || [[ $result == "[]" ]] || [[ -z $result ]]; then
		echo "没有找到包含 '$final_query' 的相关结果"
		return 0
	fi

	echo "GitHub 搜索结果 (关键词: '$final_query'):"
	echo "=================================================="
	local count=0
	while IFS='|' read -r title url state number author date; do
		((count++))
		echo "$count. $title"
		echo "   Issue #$number | 状态: $state | 作者: $author | 时间: $date"
		echo "   链接: $url"
		echo ""
	done <<< "$result"
	[[ $count -eq 0 ]] && echo "没有找到相关结果"
}

cmd_hackernews() {
	args.init "Hacker News 技术新闻检索"
	args.add_options "limit" "n" "返回结果数量（默认 20，最大 30）" "NUMBER"
	args.add_options "tags" "t" "过滤标签（story, comment, poll, show, ask, job）" "TAGS"
	args.add_options "period" "p" "时间范围（last24h, pastweek, pastmonth, all）" "PERIOD"
	args.add_options "ARG" "query" "搜索关键词（必需）"

	args.process "$@"

	local limit="$(args.get "-n" "--limit")" && string.natural.check "$limit" || limit="20"
	local tags="$(args.get "-t" "--tags")" && array.contains HN_VALID_TAGS "$tags" || tags=""
	local period="$(args.get "-p" "--period")" || period="all"
	declare -n position_args=$(args.args)
	local search_query="${position_args[*]}"
	[[ $limit -gt 30 ]] && limit=30

	requests.init
	requests.base_url "https://hn.algolia.com/api/v1"
	log.info "搜索: $search_query"
	local -a query_params=("query=$search_query" "hitsPerPage=$limit")
	[[ -n $tags ]] && query_params+=("tags=$tags")
	case "$period" in
	"last24h")
		local timestamp=$(($(date +%s) - 86400))
		query_params+=("numericFilters=created_at_i>$timestamp")
		;;
	"pastweek")
		local timestamp=$(($(date +%s) - 604800))
		query_params+=("numericFilters=created_at_i>$timestamp")
		;;
	"pastmonth")
		local timestamp=$(($(date +%s) - 2629743))
		query_params+=("numericFilters=created_at_i>$timestamp")
		;;
	esac
	local response
	response=$(requests.get "/search" "${query_params[@]}")
	requests.raise_for_status "$response"

	response=$(requests.text "$response")
	local total_hits
	total_hits=$(echo "$response" | jq -r '.nbHits // 0')
	[[ $total_hits -eq 0 ]] && echo "没有找到包含 '$search_query' 的相关结果" && return 0
	echo "Hacker News 搜索结果 (关键词: '$search_query'):"
	echo "=================================================="
	local displayed_count=0
	while IFS=$'\t' read -r title url points author created_at object_id tag; do
		((displayed_count++))
		title=$(echo "$title" | sed 's/<[^>]*>//g' | tr '\n' ' ')
		echo "$displayed_count. $title"
		echo "   类型: $tag | 分数: $points | 作者: $author | 时间: $created_at"
		[[ -n $url && $url != "null" ]] && echo "   链接: $url"
		echo "   HN链接: https://news.ycombinator.com/item?id=$object_id"
		echo ""
		[[ $displayed_count -ge $limit ]] && break
	done < <(echo "$response" | jq -r '.hits[] |
    (.title // .story_title // .comment_text // "") + "\t" +
    (.url // .story_url // "") + "\t" +
    (.points // 0 | tostring) + "\t" +
    (.author // "unknown") + "\t" +
    (.created_at // "") + "\t" +
    (.objectID // "") + "\t" +
    (._tags[0] // "story")')
	[[ $displayed_count -eq 0 ]] && echo "没有找到相关结果"
}

cmd_exa_search() {
	args.init "Exa AI 网络搜索"
	args.add_options "type" "t" "搜索类型（neural, keyword, hybrid, fast, deep, instant）" "TYPE"
	args.add_options "category" "c" "数据类别（company, research paper, news, tweet, personal site, financial report, people）" "CATEGORY"
	args.add_options "limit" "n" "返回结果数量（默认 10，最大 100）" "NUMBER"
	args.add_options "ARG" "query" "搜索目标（支持语义搜索）"

	args.process "$@"

	[[ -z ${EXA_API_KEY:-} ]] && log.error "未设置 EXA_API_KEY 环境变量" && exit 1
	local type="$(args.get "-t" "--type")" && array.contains EXA_VALID_TYPES "$type" || type=""
	local category="$(args.get "-c" "--category")" && array.contains EXA_VALID_CATEGORIES "$category" || category=""
	local limit="$(args.get "-n" "--limit")" && string.natural.check "$limit" || limit="10"
	declare -n position_args=$(args.args)
	local query="${position_args[*]}"

	requests.init
	requests.base_url "https://api.exa.ai"
	requests.headers.append "x-api-key" "$EXA_API_KEY"

	# 解析不验证：替换异常字符为安全表示
	local safe_query="$query"
	safe_query="${safe_query//\\/\\\\}"   # 反斜杠优先处理
	safe_query="${safe_query//\"/\\\"}"   # 双引号
	safe_query="${safe_query//$'\n'/\\n}" # 换行符
	safe_query="${safe_query//$'\r'/\\r}" # 回车符
	safe_query="${safe_query//$'\t'/\\t}" # 制表符

	local json_data="{\"query\":\"$safe_query\",\"numResults\":$limit"
	[[ -n $type ]] && json_data="$json_data,\"type\":\"$type\""
	[[ -n $category ]] && json_data="$json_data,\"category\":\"$category\""
	json_data="$json_data}"
	log.info "搜索: $query"
	local response
	response=$(requests.post "/search" "$json_data" "application/json")
	requests.raise_for_status "$response"

	response=$(requests.text "$response")
	if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
		local error_msg=$(echo "$response" | jq -r '.error')
		log.error "API 错误: $error_msg"
		exit 1
	fi
	local results_count
	results_count=$(echo "$response" | jq -r '.results | length')
	[[ $results_count -eq 0 ]] && echo "没有找到包含 '$query' 的相关结果" && return 0
	echo "Exa 搜索结果 (关键词: '$query'):"
	echo "=================================================="
	local count=0
	while IFS=$'\t' read -r title url author published; do
		((count++))
		echo "$count. $title"
		echo "   作者: $author | 发布时间: $published"
		echo "   链接: $url"
		echo ""
	done < <(echo "$response" | jq -r '.results[] |
    (.title // "无标题") + "\t" +
    (.url // "") + "\t" +
    (.author // "unknown") + "\t" +
    (.publishedDate // "")')
	[[ $count -eq 0 ]] && echo "没有找到相关结果"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
