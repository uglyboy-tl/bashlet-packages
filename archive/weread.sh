#!/usr/bin/env bash
# shellcheck disable=SC2034
# build:keep-env

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

.env

import core/log
import core/args
import std/string
import std/array
import std/path
import ext/requests

SCRIPT_NAME="weread"

SKILL_VERSION="1.0.3"
API_BASE="https://i.weread.qq.com/api/agent/gateway"

# ==================== 认证 ====================

weread.api.key() {
	[[ -n ${WEREAD_API_KEY:-} ]] && echo "$WEREAD_API_KEY" && return
	[[ -n ${_WEREAD_API_KEY_LOADED:-} ]] && echo "$_WEREAD_API_KEY_LOADED" && return
	if ! command -v pass &> /dev/null; then
		log.error "未找到 pass 命令，请安装 password-store 或设置 WEREAD_API_KEY 环境变量"
		return 1
	fi
	_WEREAD_API_KEY_LOADED="$(pass "weread" 2> /dev/null)" || {
		log.error "未设置 WEREAD_API_KEY，请执行: pass insert weread"
		return 1
	}
	echo "$_WEREAD_API_KEY_LOADED"
}

weread.api.check() { weread.api.key > /dev/null || exit 1; }

weread.api.assert_ok() {
	local upgrade_msg
	upgrade_msg=$(echo "$1" | jq -r '.upgrade_info.message // empty')
	[[ -n $upgrade_msg ]] && {
		log.error "$upgrade_msg"
		return 1
	}
	[[ $(echo "$1" | jq -r '.errcode // 0') == "0" ]] || {
		log.error "${2:-请求失败}"
		return 1
	}
}

# ==================== API 调用 ====================

weread.api.call() {
	local api_name="$1"
	shift
	weread.api.check
	requests.init
	requests.base_url ""
	requests.headers.append "Authorization" "Bearer $(weread.api.key)"

	# shellcheck disable=SC2016
	local jq_filter='{api_name: $api, skill_version: $ver}'
	local -a jq_args=()
	local i=0
	while [[ $# -ge 2 ]]; do
		jq_filter+=" + {(\$k$i): \$v$i}"
		if [[ $2 =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
			jq_args+=(--arg "k$i" "$1" --argjson "v$i" "$2")
		else
			jq_args+=(--arg "k$i" "$1" --arg "v$i" "$2")
		fi
		shift 2
		((i++))
	done

	local body response
	body=$(jq -n --arg api "$api_name" --arg ver "$SKILL_VERSION" "$jq_filter" "${jq_args[@]}")
	response=$(requests.post "$API_BASE" "$body" "application/json")
	requests.raise_for_status "$response"
	requests.text "$response"
}

# ==================== 工具函数 ====================

weread.util.ts2date() {
	local ts="$1"
	[[ $ts == "0" || $ts == "null" || -z $ts ]] && echo "-" && return
	date -d "@$ts" '+%Y-%m-%d' 2> /dev/null || echo "-"
}

weread.util.sec2time() {
	local sec="$1"
	[[ -z $sec || $sec == "null" || $sec == "0" ]] && echo "0分钟" && return
	local h=$((sec / 3600)) m=$(((sec % 3600) / 60))
	((h > 0)) && echo "${h}小时${m}分钟" || echo "${m}分钟"
}

weread.util.fmt_rating() {
	local r="${1:-0}" cnt="${2:-}"
	[[ $r == "0" || $r == "null" ]] && echo "-" && return
	local label
	((r >= 90)) && label="神作"
	((r >= 80)) && label="力荐"
	((r >= 70)) && label="推荐"
	((r >= 60)) && label="还行"
	((r >= 50)) && label="一般"
	[[ -n ${label:-} ]] || label="较差"
	local s="${label}($r)"
	[[ -n $cnt && $cnt != "null" ]] && s+=" (${cnt}人)"
	echo "$s"
}

weread.util.resolve_bookid() {
	local input="$1"

	if [[ $input =~ ^[0-9]+$ ]]; then
		((input < 1)) && {
			echo "$input"
			return
		}
		local cache_file
		cache_file="$(path.cache_dir)/shelf.json"
		local cache_fresh=0
		if [[ -f $cache_file ]]; then
			local created_time
			created_time=$(stat -c %Y "$cache_file" 2> /dev/null || echo 0)
			(($(date +%s) - created_time < 300)) && cache_fresh=1
		fi
		if [[ $cache_fresh -eq 0 ]]; then
			local shelf_result
			if shelf_result=$(weread.api.call "/shelf/sync") && weread.api.assert_ok "$shelf_result" "" 2> /dev/null; then
				mkdir -p "$(path.cache_dir)"
				echo "$shelf_result" > "$cache_file"
			fi
		fi
		if [[ $cache_fresh -eq 0 ]]; then
			local shelf_result
			if shelf_result=$(weread.api.call "/shelf/sync") && weread.api.assert_ok "$shelf_result" "" 2> /dev/null; then
				mkdir -p "$(path.cache_dir)"
				echo "$shelf_result" > "$cache_file"
			fi
		fi
		if [[ -f $cache_file ]]; then
			local shelf_id
			shelf_id=$(jq -r ".books[$((input - 1))].bookId // empty" "$cache_file")
			[[ -n $shelf_id ]] && {
				echo "$shelf_id"
				return
			}
		fi
		echo "$input"
		return
	fi

	local result
	result=$(weread.api.call "/store/search" "keyword" "$input" "count" 5)
	weread.api.assert_ok "$result" "搜索失败" || return 1
	local book_id
	book_id=$(echo "$result" | jq -r '.results[0].books[0].bookInfo.bookId // empty')
	[[ -n $book_id ]] && echo "$book_id" || {
		log.error "未找到书籍: $input"
		return 1
	}
}

weread.util.url.book() { echo "weread://reading?bId=$1"; }
weread.util.url.chapter() { echo "weread://reading?bId=$1&chapterUid=$2"; }

# ==================== search ====================

cmd_search() {
	args.init "搜索书籍"
	args.add_options "ARG" "keyword" "搜索关键词" "STRING"
	args.add_options "scope" "s" "搜索类型: 0=全部 10=电子书 16=网文 14=有声书 6=作者 12=全文 13=书单 2=公众号 4=文章" "NUMBER"
	args.add_options "count" "c" "每页数量" "NUMBER"
	args.process "$@"
	declare -n position_args="$(args.args)"
	[[ ${#position_args[@]} -eq 0 ]] && {
		log.error "请提供搜索关键词"
		return 1
	}
	local keyword="${position_args[0]}"

	local scope count
	scope="$(args.get "-s" "--scope")" && string.int.check "$scope" || scope="10"
	count="$(args.get "-c" "--count")" && string.natural.check "$count" || count=""

	local result
	if [[ -n $count ]]; then
		result=$(weread.api.call "/store/search" "keyword" "$keyword" "scope" "$scope" "count" "$count")
	else
		result=$(weread.api.call "/store/search" "keyword" "$keyword" "scope" "$scope")
	fi

	weread.api.assert_ok "$result" "搜索失败" || return 1

	local num_results
	num_results=$(echo "$result" | jq '.results | length')
	((num_results == 0)) && {
		log.info "未找到相关结果"
		return 0
	}

	local merged
	merged=$(echo "$result" | jq '[.results[] | select(.books != null and .books != []) | .books[] as $book | {scope, title, book: $book}] | group_by(.scope) | map({scope: .[0].scope, title: .[0].title, books: [.[].book]})')

	local group_count
	group_count=$(echo "$merged" | jq 'length')

	for ((g = 0; g < group_count; g++)); do
		local group_title
		group_title=$(echo "$merged" | jq -r ".[$g].title")
		echo ""
		echo "━━━ $group_title ━━━"

		local book_count
		book_count=$(echo "$merged" | jq ".[$g].books | length")
		for ((b = 0; b < book_count; b++)); do
			local title author rating rating_count reading_count category soldout book_id
			title=$(echo "$merged" | jq -r ".[$g].books[$b].bookInfo.title")
			author=$(echo "$merged" | jq -r ".[$g].books[$b].bookInfo.author")
			rating=$(echo "$merged" | jq -r ".[$g].books[$b].newRating // 0")
			rating_count=$(echo "$merged" | jq -r ".[$g].books[$b].newRatingCount // 0")
			reading_count=$(echo "$merged" | jq -r ".[$g].books[$b].readingCount // 0")
			category=$(echo "$merged" | jq -r ".[$g].books[$b].bookInfo.category // \"-\"")
			soldout=$(echo "$merged" | jq -r ".[$g].books[$b].bookInfo.soldout // 0")
			book_id=$(echo "$merged" | jq -r ".[$g].books[$b].bookInfo.bookId")

			local soldout_tag=""
			[[ $soldout == "1" ]] && soldout_tag=" [已下架]"

			echo "  $((b + 1)). $title$soldout_tag"
			echo "     作者: $author | 评分: $(weread.util.fmt_rating "$rating" "$rating_count") | 在读: $reading_count | 分类: $category"
			echo "     $(weread.util.url.book "$book_id")"
		done
	done
}

# ==================== book ====================

cmd_book_info() {
	args.init "查看书籍信息"
	args.add_options "ARG" "book" "书籍ID或书名" "STRING"
	args.process "$@"
	declare -n position_args="$(args.args)"
	[[ ${#position_args[@]} -eq 0 ]] && {
		log.error "请提供书籍ID或书名"
		return 1
	}

	local book_id
	book_id=$(weread.util.resolve_bookid "${position_args[0]}") || return 1

	local result
	result=$(weread.api.call "/book/info" "bookId" "$book_id")
	weread.api.assert_ok "$result" "获取书籍信息失败" || return 1

	local title author translator category publisher publish_time isbn word_count rating intro cover
	title=$(echo "$result" | jq -r '.title')
	author=$(echo "$result" | jq -r '.author')
	translator=$(echo "$result" | jq -r '.translator // ""')
	category=$(echo "$result" | jq -r '.category // "-"')
	publisher=$(echo "$result" | jq -r '.publisher // "-"')
	publish_time=$(echo "$result" | jq -r '.publishTime // "-"')
	isbn=$(echo "$result" | jq -r '.isbn // "-"')
	word_count=$(echo "$result" | jq -r '.wordCount // 0')
	rating=$(echo "$result" | jq -r '.newRating // 0')
	intro=$(echo "$result" | jq -r '.intro // ""')
	cover=$(echo "$result" | jq -r '.cover // ""')

	local rating_count
	rating_count=$(echo "$result" | jq -r '.newRatingCount // 0')

	echo "📖 $title"
	echo "   作者: $author"
	[[ -n $translator && $translator != "null" ]] && echo "   译者: $translator"
	echo "   分类: $category | 出版社: $publisher"
	echo "   出版时间: $publish_time | ISBN: $isbn"
	echo "   字数: $word_count | 评分: $(weread.util.fmt_rating "$rating" "$rating_count")"
	[[ -n $cover && $cover != "null" ]] && echo "   封面: $cover"
	echo "   $(weread.util.url.book "$book_id")"
	[[ -n $intro && $intro != "null" ]] && echo "" && echo "   简介: $intro"
}

cmd_book_chapters() {
	args.init "查看章节目录"
	args.add_options "ARG" "book" "书籍ID或书名" "STRING"
	args.add_options "limit" "l" "显示章节数" "NUMBER"
	args.process "$@"
	declare -n position_args="$(args.args)"
	[[ ${#position_args[@]} -eq 0 ]] && {
		log.error "请提供书籍ID或书名"
		return 1
	}

	local book_id
	book_id=$(weread.util.resolve_bookid "${position_args[0]}") || return 1

	local result
	result=$(weread.api.call "/book/chapterinfo" "bookId" "$book_id")
	weread.api.assert_ok "$result" "获取章节目录失败" || return 1

	local chapter_count limit_val
	chapter_count=$(echo "$result" | jq '.chapters | length')
	echo "📑 章节目录 (共 $chapter_count 章)"
	limit_val="$(args.get "-l" "--limit")" && string.natural.check "$limit_val" || limit_val="$chapter_count"
	((limit_val < chapter_count)) && echo "   (显示前 $limit_val 章，共 $chapter_count 章)"
	echo ""

	for ((i = 0; i < limit_val; i++)); do
		local ch_uid ch_idx ch_title ch_wc ch_level ch_paid
		ch_uid=$(echo "$result" | jq -r ".chapters[$i].chapterUid")
		ch_idx=$(echo "$result" | jq -r ".chapters[$i].chapterIdx")
		ch_title=$(echo "$result" | jq -r ".chapters[$i].title")
		ch_wc=$(echo "$result" | jq -r ".chapters[$i].wordCount // 0")
		ch_level=$(echo "$result" | jq -r ".chapters[$i].level // 1")
		ch_paid=$(echo "$result" | jq -r ".chapters[$i].paid // 0")

		local indent=""
		case "$ch_level" in
			1) indent="  " ;;
			2) indent="    " ;;
			3) indent="      " ;;
			*) indent="        " ;;
		esac

		local paid_tag=""
		[[ $ch_paid == "0" ]] && paid_tag=" [免费]"

		echo "${indent}${ch_idx}. ${ch_title} (${ch_wc}字)${paid_tag}"
		echo "     $(weread.util.url.chapter "$book_id" "$ch_uid")"
	done
}

cmd_book_progress() {
	args.init "查看阅读进度"
	args.add_options "ARG" "book" "书籍ID或书名" "STRING"
	args.process "$@"
	declare -n position_args="$(args.args)"
	[[ ${#position_args[@]} -eq 0 ]] && {
		log.error "请提供书籍ID或书名"
		return 1
	}

	local book_id
	book_id=$(weread.util.resolve_bookid "${position_args[0]}") || return 1

	local result
	result=$(weread.api.call "/book/getprogress" "bookId" "$book_id")
	weread.api.assert_ok "$result" "获取阅读进度失败" || return 1

	local progress read_time update_time finish_time is_start
	progress=$(echo "$result" | jq -r '.book.progress // 0')
	read_time=$(echo "$result" | jq -r '.book.recordReadingTime // 0')
	update_time=$(echo "$result" | jq -r '.book.updateTime // 0')
	finish_time=$(echo "$result" | jq -r '.book.finishTime // "null"')
	is_start=$(echo "$result" | jq -r '.book.isStartReading // 0')

	echo "📊 阅读进度"
	echo "   进度: ${progress}%"
	echo "   累计阅读: $(weread.util.sec2time "$read_time")"
	echo "   最后阅读: $(weread.util.ts2date "$update_time")"
	[[ $progress == "100" && $finish_time != "null" ]] && echo "   读完时间: $(weread.util.ts2date "$finish_time")"
	[[ $is_start == "0" ]] && echo "   状态: 未开始阅读"
	echo "   $(weread.util.url.book "$book_id")"
}

cmd_book() {
	local subcmd="${1:-}"
	shift || true

	case "$subcmd" in
		info) cmd_book_info "$@" ;;
		chapters) cmd_book_chapters "$@" ;;
		progress) cmd_book_progress "$@" ;;
		-h | --help)
			echo "weread book - 书籍相关操作"
			echo ""
			echo "Usage: weread book <subcommand> [OPTIONS]"
			echo ""
			echo "Subcommands:"
			echo "  info        查看书籍详情"
			echo "  chapters    查看章节目录"
			echo "  progress    查看阅读进度"
			;;
		"") log.error "请指定子命令: info | chapters | progress" ;;
		*) log.error "未知子命令: $subcmd" ;;
	esac
}

# ==================== shelf ====================

cmd_shelf() {
	args.init "查看我的书架"
	args.process "$@"

	local result
	result=$(weread.api.call "/shelf/sync")
	weread.api.assert_ok "$result" "获取书架失败" || return 1

	local books_len albums_len has_mp
	books_len=$(echo "$result" | jq '.books | length')
	albums_len=$(echo "$result" | jq '.albums | length')
	has_mp=$(echo "$result" | jq 'if .mp == null or .mp == {} then 0 else 1 end')

	local mp_tag=""
	((has_mp > 0)) && mp_tag=" + 1 个文章收藏"

	echo "📚 我的书架 (共 $((books_len + albums_len + has_mp)) 个条目: $books_len 本电子书 + $albums_len 个专辑/有声书${mp_tag})"
	echo ""

	local idx=0

	for ((i = 0; i < books_len; i++)); do
		idx=$((idx + 1))
		local title author category read_time is_top secret finish book_id
		title=$(echo "$result" | jq -r ".books[$i].title")
		author=$(echo "$result" | jq -r ".books[$i].author")
		category=$(echo "$result" | jq -r ".books[$i].category // \"-\"")
		read_time=$(echo "$result" | jq -r ".books[$i].readUpdateTime // 0")
		is_top=$(echo "$result" | jq -r ".books[$i].isTop // 0")
		secret=$(echo "$result" | jq -r ".books[$i].secret // 0")
		finish=$(echo "$result" | jq -r ".books[$i].finishReading // 0")
		book_id=$(echo "$result" | jq -r ".books[$i].bookId // \"-\"")

		local tags=""
		[[ $is_top == "1" ]] && tags="${tags}[置顶] "
		[[ $secret == "1" ]] && tags="${tags}[私密] "
		[[ $finish == "1" ]] && tags="${tags}[已读完] "

		echo "  $idx. $title ${tags}"
		echo "     作者: $author | 分类: $category | 最近阅读: $(weread.util.ts2date "$read_time") | ID: $book_id"
	done

	((albums_len > 0)) || return 0

	echo ""
	echo "━━━ 专辑/有声书 ━━━"
	for ((i = 0; i < albums_len; i++)); do
		idx=$((idx + 1))
		local name author_name track_count finish_status is_top secret
		name=$(echo "$result" | jq -r ".albums[$i].albumInfo.name")
		author_name=$(echo "$result" | jq -r ".albums[$i].albumInfo.authorName")
		track_count=$(echo "$result" | jq -r ".albums[$i].albumInfo.trackCount // 0")
		finish_status=$(echo "$result" | jq -r ".albums[$i].albumInfo.finishStatus // \"-\"")
		is_top=$(echo "$result" | jq -r ".albums[$i].albumInfoExtra.isTop // 0")
		secret=$(echo "$result" | jq -r ".albums[$i].albumInfoExtra.secret // 0")

		local tags=""
		[[ $is_top == "1" ]] && tags="${tags}[置顶] "
		[[ $secret == "1" ]] && tags="${tags}[私密] "

		echo "  $idx. $name ${tags}"
		echo "     演播: $author_name | 共 $track_count 集 | $finish_status"
	done
}

# ==================== stats ====================

cmd_stats() {
	args.init "查看阅读统计"
	args.add_options "mode" "m" "统计维度: weekly|monthly|annually|overall" "STRING"
	args.add_options "year" "y" "指定年份" "NUMBER"
	args.process "$@"

	local mode year
	mode="$(args.get "-m" "--mode")" || mode="monthly"
	case "$mode" in
		weekly | monthly | annually | overall) ;;
		*)
			log.error "无效的统计维度: $mode，可选: weekly|monthly|annually|overall"
			return 1
			;;
	esac
	year="$(args.get "-y" "--year")"

	local base_time="0"
	if [[ -n $year ]]; then
		base_time=$(date -d "$year-01-01" '+%s' 2> /dev/null || echo "0")
		[[ $mode == "monthly" ]] && mode="annually"
	fi

	local result
	if [[ $base_time != "0" ]]; then
		result=$(weread.api.call "/readdata/detail" "mode" "$mode" "baseTime" "$base_time")
	else
		result=$(weread.api.call "/readdata/detail" "mode" "$mode")
	fi

	weread.api.assert_ok "$result" "获取阅读统计失败" || return 1

	local total_time read_days day_avg compare
	total_time=$(echo "$result" | jq -r '.totalReadTime // 0')
	read_days=$(echo "$result" | jq -r '.readDays // 0')
	day_avg=$(echo "$result" | jq -r '.dayAverageReadTime // 0')
	compare=$(echo "$result" | jq -r '.compare // "null"')

	local mode_label="本月"
	case "$mode" in
		weekly) mode_label="本周" ;;
		annually) mode_label="本年" ;;
		overall) mode_label="总计" ;;
	esac

	echo "📊 阅读统计 ($mode_label)"
	echo ""
	echo "━━━ 总览 ━━━"
	echo "  阅读天数: $read_days 天"
	echo "  总阅读时长: $(weread.util.sec2time "$total_time")"
	echo "  自然日均时长: $(weread.util.sec2time "$day_avg")"
	[[ $compare != "null" ]] && {
		local pct dir="下降"
		pct=$(echo "$compare" | awk '{v=$1*100; printf "%.0f", (v>0?v:-v)}')
		awk -v c="$compare" 'BEGIN{exit !(c>0)}' && dir="增长"
		[[ $pct != "0" ]] && echo "  与上期对比: ${dir} ${pct}%"
	}

	local longest_count
	longest_count=$(echo "$result" | jq '.readLongest | length')
	if ((longest_count > 0)); then
		echo ""
		echo "━━━ 读书排行 ━━━"
		for ((i = 0; i < longest_count; i++)); do
			local title author read_time tags
			title=$(echo "$result" | jq -r ".readLongest[$i].book.title // .readLongest[$i].albumInfo.name // \"未知\"")
			author=$(echo "$result" | jq -r ".readLongest[$i].book.author // .readLongest[$i].albumInfo.authorName // \"-\"")
			read_time=$(echo "$result" | jq -r ".readLongest[$i].readTime // 0")
			tags=$(echo "$result" | jq -r ".readLongest[$i].tags | join(\", \") // \"\"")

			echo "  $((i + 1)). $title ($author) - $(weread.util.sec2time "$read_time")"
			[[ -n $tags && $tags != "null" ]] && echo "     标签: $tags"
		done
	fi

	local stat_count
	stat_count=$(echo "$result" | jq '.readStat | length')
	if ((stat_count > 0)); then
		echo ""
		echo "━━━ 阅读统计 ━━━"
		for ((i = 0; i < stat_count; i++)); do
			local stat_name stat_val
			stat_name=$(echo "$result" | jq -r ".readStat[$i].stat")
			stat_val=$(echo "$result" | jq -r ".readStat[$i].counts")
			echo "  $stat_name: $stat_val"
		done
	fi

	local cat_count
	cat_count=$(echo "$result" | jq '.preferCategory | length')
	if ((cat_count > 0)); then
		echo ""
		echo "━━━ 偏好分类 ━━━"
		local cat_word
		cat_word=$(echo "$result" | jq -r '.preferCategoryWord // ""')
		[[ -n $cat_word && $cat_word != "null" ]] && echo "  $cat_word"
		for ((i = 0; i < cat_count; i++)); do
			local cat_title parent_title reading_time reading_count
			cat_title=$(echo "$result" | jq -r ".preferCategory[$i].categoryTitle")
			parent_title=$(echo "$result" | jq -r ".preferCategory[$i].parentCategoryTitle // \"\"")
			reading_time=$(echo "$result" | jq -r ".preferCategory[$i].readingTime // 0")
			reading_count=$(echo "$result" | jq -r ".preferCategory[$i].readingCount // 0")
			((reading_count == 0)) && continue

			local parent_tag=""
			[[ -n $parent_title && $parent_title != "null" ]] && parent_tag=" ($parent_title)"
			echo "  $cat_title${parent_tag}: $reading_count 本, $(weread.util.sec2time "$reading_time")"
		done
	fi

	local time_word
	time_word=$(echo "$result" | jq -r '.preferTimeWord // ""')
	[[ -n $time_word && $time_word != "null" ]] && echo "" && echo "━━━ 偏好时段 ━━━" && echo "  $time_word"

	local author_count
	author_count=$(echo "$result" | jq '.preferAuthor | length')
	if ((author_count > 0)); then
		echo ""
		echo "━━━ 偏好作者 ━━━"
		for ((i = 0; i < author_count; i++)); do
			local name count read_time
			name=$(echo "$result" | jq -r ".preferAuthor[$i].name")
			count=$(echo "$result" | jq -r ".preferAuthor[$i].count // 0")
			read_time=$(echo "$result" | jq -r ".preferAuthor[$i].readTime // \"\"")
			echo "  $name: $count 本 ($read_time)"
		done
	fi

	local read_rate wr_read wr_listen
	read_rate=$(echo "$result" | jq -r '.readRate // "null"')
	[[ $read_rate == "null" ]] && return 0
	wr_read=$(echo "$result" | jq -r '.wrReadTime // 0')
	wr_listen=$(echo "$result" | jq -r '.wrListenTime // 0')
	echo ""
	echo "━━━ 阅读方式 ━━━"
	echo "  文字阅读: $(weread.util.sec2time "$wr_read")"
	echo "  听书/TTS: $(weread.util.sec2time "$wr_listen")"
	echo "  文字占比: ${read_rate}%"
}

# ==================== discover ====================

cmd_discover() {
	args.init "发现推荐好书"
	args.add_options "similar" "s" "相似书推荐（需提供书名）" "STRING"
	args.add_options "count" "c" "每页数量" "NUMBER"
	args.process "$@"

	local count_val similar_input
	count_val="$(args.get "-c" "--count")" && string.natural.check "$count_val" || count_val="12"
	similar_input="$(args.get "-s" "--similar")"

	if [[ -n $similar_input ]]; then

		local book_id
		book_id=$(weread.util.resolve_bookid "$similar_input") || return 1

		local source_title
		source_title=$(weread.api.call "/book/info" "bookId" "$book_id" | jq -r '.title // "未知"')

		local result
		result=$(weread.api.call "/book/similar" "bookId" "$book_id" "count" "$count_val" "maxIdx" 0)
		weread.api.assert_ok "$result" "获取相似推荐失败" || return 1

		local book_count
		book_count=$(echo "$result" | jq '.booksimilar.books | length')
		((book_count == 0)) && {
			log.info "暂无相似推荐"
			return 0
		}

		echo "📚 与 \"$source_title\" 相似的书"
		echo ""

		for ((i = 0; i < book_count; i++)); do
			local title author bid
			title=$(echo "$result" | jq -r ".booksimilar.books[$i].book.bookInfo.title")
			author=$(echo "$result" | jq -r ".booksimilar.books[$i].book.bookInfo.author")
			bid=$(echo "$result" | jq -r ".booksimilar.books[$i].book.bookInfo.bookId")

			echo "  $((i + 1)). $title"
			echo "     作者: $author"
			echo "     $(weread.util.url.book "$bid")"
			echo ""
		done
	else

		local result
		result=$(weread.api.call "/book/recommend" "count" "$count_val")
		weread.api.assert_ok "$result" "获取推荐失败" || return 1

		local book_count
		book_count=$(echo "$result" | jq '.books | length')
		((book_count == 0)) && {
			log.info "暂无推荐"
			return 0
		}

		echo "🌟 为你推荐"
		echo ""

		for ((i = 0; i < book_count; i++)); do
			local title author rating rating_count reason reading_count bid
			title=$(echo "$result" | jq -r ".books[$i].title")
			author=$(echo "$result" | jq -r ".books[$i].author")
			rating=$(echo "$result" | jq -r ".books[$i].newRating // 0")
			rating_count=$(echo "$result" | jq -r ".books[$i].newRatingCount // 0")
			reason=$(echo "$result" | jq -r ".books[$i].reason // \"\"")
			reading_count=$(echo "$result" | jq -r ".books[$i].readingCount // 0")
			bid=$(echo "$result" | jq -r ".books[$i].bookId")

			echo "  $((i + 1)). $title"
			echo "     作者: $author | 评分: $(weread.util.fmt_rating "$rating" "$rating_count") | 在读: $reading_count"
			[[ -n $reason && $reason != "null" ]] && echo "     推荐: $reason"
			echo "     $(weread.util.url.book "$bid")"
			echo ""
		done
	fi
}

# ==================== main ====================

main() {
	args.name "weread"
	args.init "微信读书 CLI 工具"

	args.add_subcommand "search" "搜索书籍" "cmd_search"
	args.add_subcommand "book" "书籍信息/章节/进度" "cmd_book"
	args.add_subcommand "shelf" "查看我的书架" "cmd_shelf"
	args.add_subcommand "stats" "阅读统计" "cmd_stats"
	args.add_subcommand "discover" "发现推荐好书" "cmd_discover"

	args.process "$@"
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	main "$@"
fi
