#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# B 站。搜索免登录、免 wbi 签名（实测带不带 cookie 都是 code 0）。
#
# 字幕需要登录态：匿名实测 0/10 视频能拿到字幕轨，带 SESSDATA 则 10/10（多为 ai-zh）。
# 所以设置 BILI_SESSDATA 环境变量即可解锁字幕全文稿（dig 不抓浏览器 cookie，由用户提供）。
# 弹幕匿名可拿，是另一条「观众反应」通道。

import core/log

import common
import parse
import schema
import source

read -r -d '' _BILI_SUBTITLE_JQ << 'JQ' || true
    (.data.subtitle.subtitles // []) as $t
    | ( ($t | map(select(.lan == "ai-zh"))[0])
      // ($t | map(select((.lan // "") | startswith("zh")))[0])
      // ($t | map(select((.lan // "") | startswith("ai-")))[0])
      // $t[0] ) | .subtitle_url // empty
JQ

read -r -d '' _BILI_MAP_JQ << 'JQ' || true
    def num: if type == "number" then . elif type == "string" then (tonumber? // 0) else 0 end;
    [ .data.result[]? | select(.result_type == "video") | .data[]? ][]
    | {
        source: "bilibili",
        id: .bvid,
        url: ("https://www.bilibili.com/video/" + .bvid),
        title: ((.title // "") | gsub("<[^>]*>"; "")),
        text: ((.description // "") | gsub("<[^>]*>"; "")),
        author: (.author // ""),
        created_at: ((.pubdate // 0) | if . > 0 then todateiso8601 else "" end),
        engagement: { play: (.play | num), danmaku: (.danmaku | num), comments: (.review | num) },
        tags: ((((.tag // "") | split(",")) + [ (.typename // "") ]) | map(select(. != ""))),
        query: $query
      }
JQ

read -r -d '' _BILI_MAP_VIEW_JQ << 'JQ' || true
    { data: { result: [ { result_type: "video", data: [ {
        bvid: .data.bvid,
        title: (.data.title // ""),
        author: (.data.owner.name // ""),
        pubdate: (.data.pubdate // 0),
        play: (.data.stat.view // 0),
        danmaku: (.data.stat.danmaku // 0),
        review: (.data.stat.reply // 0),
        tag: "",
        typename: (.data.tname // ""),
        description: (.data.desc // "")
      } ] } ] } }
JQ

_BILI_API="https://api.bilibili.com"
# 字幕最长保留多少字符
_BILI_TEXT_CAP=8000
# 弹幕抽样步长与条数
_BILI_DM_STEP=41
_BILI_DM_KEEP=30

bilibili.options() {
	args.add_options "transcript" "t" "为前 N 条抓字幕全文稿（需 BILI_SESSDATA，每条 3 个请求）" "NUMBER"
	args.add_options "danmaku" "d" "为前 N 条抓弹幕填进 text（每条 2 个请求，默认 0）" "NUMBER"
}

bilibili.probe() { dig.http.probe "$_BILI_API/x/web-interface/search/all/v2?keyword=test"; }

# 从视频 URL 抠出 view 端点的参数：/video/BV… 或 /video/av123
bilibili.url.param() {
	local u="$1"
	if [[ $u =~ /video/(BV[A-Za-z0-9]+) ]]; then
		printf 'bvid=%s' "${BASH_REMATCH[1]}"
		return 0
	fi
	if [[ $u =~ /video/av([0-9]+) ]]; then
		printf 'aid=%s' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

# b23.tv 短链要读 302，先不接（返回 1 让别的源看）
bilibili.search() {
	[[ -n $DIG_QUERY ]] || {
		log.error '需要查询词：dig bilibili "关键词"'
		return 1
	}

	# SESSDATA 是唯一的登录态入口；不设就只拿得到弹幕与元数据
	if [[ -n ${BILI_SESSDATA:-} ]]; then
		dig.cookie.set "SESSDATA=$BILI_SESSDATA"
	fi

	local dn tn
	dn="$(dig.opt.natural 0 -d --danmaku)" || return 1
	tn="$(dig.opt.natural 0 -t --transcript)" || return 1

	if ((tn > 0)) && [[ -z ${BILI_SESSDATA:-} ]]; then
		log.error "B 站字幕需要登录态：设置 BILI_SESSDATA 环境变量（匿名实测 0/10 视频可得字幕）"
		return 1
	fi

	local out
	out="$(dig.http.get "$_BILI_API/x/web-interface/search/all/v2" "keyword=$DIG_QUERY")" || return 1
	[[ "$(printf '%s' "$out" | json.run -r '.code // 0')" == "0" ]] || {
		log.error "B 站接口返回 code=$(printf '%s' "$out" | json.run -r '.code // "?"')：$(printf '%s' "$out" | json.run -r '.message // ""')"
		return 1
	}

	printf '%s' "$out" | bilibili.map | schema.pipe "$DIG_AFTER" |
		schema.enrich "$((dn > tn ? dn : tn))" bilibili.enrich_one "$dn" "$tn" | schema.limit "$DIG_LIMIT"
}

# view 端点的 .data 与搜索结果 item 形状不同；转成 item 后再交给 bilibili.map，
# 避免为直取另写一套字段映射。
bilibili.map_view() {
	json.run -c "$_BILI_MAP_VIEW_JQ"
}

# 用户给视频链接就是想要里面的内容，所以 -u 隐式等于 -t 1 -d 1。
# 没有 BILI_SESSDATA 时字幕拿不到：只 warn 不失败，text 退回弹幕/简介。
bilibili.search_url() {
	local url="$1" param view bvid cid line text="" sub="" dm=""
	param="$(bilibili.url.param "$url")" || {
		log.error "不是合法的 B 站视频 URL：$url"
		return 1
	}

	if [[ -n ${BILI_SESSDATA:-} ]]; then
		dig.cookie.set "SESSDATA=$BILI_SESSDATA"
	else
		log.warn "B 站字幕需要登录态（BILI_SESSDATA），本次只抓弹幕与视频元数据"
	fi

	view="$(dig.http.get "$_BILI_API/x/web-interface/view" "$param")" || return 1
	[[ "$(printf '%s' "$view" | json.run -r '.code // 0')" == "0" ]] || {
		log.error "B 站接口返回 code=$(printf '%s' "$view" | json.run -r '.code // "?"')：$(printf '%s' "$view" | json.run -r '.message // ""')"
		return 1
	}

	bvid="$(printf '%s' "$view" | json.run -r '.data.bvid // empty')"
	cid="$(printf '%s' "$view" | json.run -r '.data.cid // empty')"
	line="$(printf '%s' "$view" | bilibili.map_view | bilibili.map | head -1)"
	[[ -n $line ]] || return 1

	if [[ -n ${BILI_SESSDATA:-} && -n $cid ]]; then
		sub="$(bilibili.subtitle "$bvid" "$cid")" || sub=""
	fi
	if [[ -n $cid ]]; then
		dm="$(bilibili.danmaku_text "$cid")" || dm=""
	fi
	text="$sub"
	if [[ -n $dm ]]; then
		text="${text:+$text

--- 弹幕 ---
}$dm"
	fi

	# parse.json.patch 只覆盖非空值：抓不到字幕/弹幕时保留 map 填好的简介
	parse.json.patch "$line" "text=$text" | schema.pipe 0 | schema.limit 1
}

bilibili.map() {
	schema.jq -c "$_BILI_MAP_JQ"
}

# 搜索响应里没有 cid，字幕和弹幕都要先用 view 换 cid；两个标志同时给时只查一次 view
bilibili.enrich_one() {
	local line="$1" i="$2" dn="$3" tn="$4"
	local bvid cid view text=""

	bvid="$(printf '%s' "$line" | json.run -r '.id // empty')"
	[[ -n $bvid ]] || {
		printf '%s' "$line"
		return 0
	}

	if view="$(dig.http.get "$_BILI_API/x/web-interface/view" "bvid=$bvid")"; then
		cid="$(printf '%s' "$view" | json.run -r '.data.cid // empty')"
	else
		cid=""
	fi
	[[ -n $cid ]] || {
		printf '%s' "$line"
		return 0
	}

	if ((i <= tn)); then
		text="$(bilibili.subtitle "$bvid" "$cid")"
	fi
	if ((i <= dn)); then
		local dm
		dm="$(bilibili.danmaku_text "$cid")"
		if [[ -n $dm ]]; then
			text="${text:+$text

--- 弹幕 ---
}$dm"
		fi
	fi

	# parse.json.patch 只覆盖非空值：抓不到字幕/弹幕时不会把 map 填好的简介清空
	parse.json.patch "$line" "text=$text"
}

# 字幕轨优先 ai-zh，其次任意中文，再退到第一条
bilibili.subtitle() {
	local bvid="$1" cid="$2" player url raw
	player="$(dig.http.get "$_BILI_API/x/player/v2" "bvid=$bvid" "cid=$cid")" || return 0
	url="$(printf '%s' "$player" | json.run -r "$_BILI_SUBTITLE_JQ")"
	[[ -n $url ]] || return 0
	[[ $url == //* ]] && url="https:$url"

	raw="$(dig.http.get "$url")" || return 0
	printf '%s' "$raw" | json.run -r --argjson cap "$_BILI_TEXT_CAP" '
    ([.body[]?.content] | join(" ")) | if length > $cap then .[0:$cap] else . end'
}

bilibili.danmaku_text() {
	local cid="$1" raw
	raw="$(dig.http.get "$_BILI_API/x/v1/dm/list.so" "oid=$cid")" || return 0
	bilibili.danmaku_sample "$raw"
}

# 弹幕是单行大 XML；按步长抽样，避免把几千条灌进 text
bilibili.danmaku_sample() {
	local out
	out="$(printf '%s' "$1" |
		parse.xml.records d '#' |
		awk -v step="$_BILI_DM_STEP" 'NR % step == 1' |
		head -"$_BILI_DM_KEEP" || true)"
	printf '%s' "$out" | awk '{ s = (NR == 1 ? $0 : s " / " $0) } END { print s }'
}

source.url.register bilibili bilibili.com
source.register bilibili "B 站视频搜索（字幕需 BILI_SESSDATA，弹幕免登录）" "tier:niche period:yes proxy:no key:optional"
