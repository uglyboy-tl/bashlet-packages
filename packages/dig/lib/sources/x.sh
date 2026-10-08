#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# X / Twitter。走网页端的 GraphQL SearchTimeline —— 与 last30days 的 bird 后端同一条路：
# 用浏览器里的两个 cookie 冒充已登录的网页端，公开 bearer 是固定的、不算凭证。
#
# 需要 X_AUTH_TOKEN / X_CT0。它们唯一的用途是**取回 queryId**：SearchTimeline 的 queryId 藏在
# x.com/home 的 main bundle 里，而那个页面未登录会 307 到登录页（实测）。
# 拿法：浏览器登录 x.com → F12 → Application → Cookies → https://x.com → 复制 auth_token
# 与 ct0 到包内 .env 的 X_AUTH_TOKEN / X_CT0（dig 不抓浏览器 cookie）。
#
# 而**搜索请求本身不校验 cookie 的真实性**（2026-10-07 实测：auth_token 填 0 / x / deadbeef 都返回
# 200 与真实结果，完全不带 cookie 头才 403；同一个假值打需要登录的 account/settings.json 会明确 401）。
# 所以缓存里已有 queryId 时，cookie 丢了也还能继续搜 —— 那时 dig 用匿名占位值顶上。
#
# 必须走代理：本机直连 x.com / abs.twimg.com 均超时（docs/candidates.md §1）。
#
# 三个子动作：
#   dig x "词"              SearchTimeline 搜索，单页最多 20 条
#   dig x --tweet <id|url>  单条推文，走 cdn.syndication.twimg.com（零凭证，不带 cookie 也行）
#   dig x --update-ids      手动刷新 queryId（一般用不着：失效会自动刷；需要真 cookie）
#
# 两处会漂移的东西：
#   1. queryId —— X 每次发版都可能换，所以**不留任何内置值**：写死的值一过期就是全挂，而且报
#      出来的是 403/404，看不出真正原因。queryId 只有两个来源 —— 本地缓存（30 天）与现刷。
#      搜索收到 403/404 时自动刷一次再重试，缓存过期后也会自动刷；两者都需要真 cookie。
#   2. features —— 请求体里必须带，缺字段直接 400。下面 _X_FEATURES 是同一批 38 个字段的快照。

import core/log
import ext/requests
import std/cache
import std/string

import common
import schema
import source

# 网页端公开的客户端 bearer，任何人都能在 x.com 的 JS 里读到，不是账号凭证。
# DIG_X_BEARER 可覆盖，官方轮换时不必改代码。
_X_BEARER="${DIG_X_BEARER:-AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA}"
# X 单页上限；要更多得翻页（见文件头）
_X_PAGE_MAX=20
# 没配 cookie 时的占位值：X 当前不校验它，足以让请求通过（见文件头）
_X_ANON_TOKEN='dig-anon'

# queryId 表缓存 30 天，只为防「缓存永不到期」。真正的刷新靠请求失败：queryId 一失效，旧值立刻
# 回 403/404，那时会重取一次再重试 —— 所以这里不设短 TTL 去做「定期刷新」。
# （last30days 同样走失败驱动：它的 24h TTL 因为所有 refresh 都带 force:true 而从不生效，
#   那个数字只是快照里的元数据。）
_X_OPS_NS='x-ops'
_X_OPS_KEY='query-ids'
_X_OPS_TTL=2592000

_X_FEATURES='{"rweb_video_screen_enabled":true,"profile_label_improvements_pcf_label_in_post_enabled":true,"responsive_web_profile_redirect_enabled":true,"rweb_tipjar_consumption_enabled":true,"verified_phone_label_enabled":false,"creator_subscriptions_tweet_preview_api_enabled":true,"responsive_web_graphql_timeline_navigation_enabled":true,"responsive_web_graphql_exclude_directive_enabled":true,"responsive_web_graphql_skip_user_profile_image_extensions_enabled":false,"premium_content_api_read_enabled":false,"communities_web_enable_tweet_community_results_fetch":true,"c9s_tweet_anatomy_moderator_badge_enabled":true,"responsive_web_grok_analyze_button_fetch_trends_enabled":false,"responsive_web_grok_analyze_post_followups_enabled":false,"responsive_web_grok_annotations_enabled":false,"responsive_web_jetfuel_frame":true,"post_ctas_fetch_enabled":true,"responsive_web_grok_share_attachment_enabled":true,"responsive_web_edit_tweet_api_enabled":true,"graphql_is_translatable_rweb_tweet_is_translatable_enabled":true,"view_counts_everywhere_api_enabled":true,"longform_notetweets_consumption_enabled":true,"responsive_web_twitter_article_tweet_consumption_enabled":true,"tweet_awards_web_tipping_enabled":false,"responsive_web_grok_show_grok_translated_post":false,"responsive_web_grok_analysis_button_from_backend":true,"creator_subscriptions_quote_tweet_preview_enabled":false,"freedom_of_speech_not_reach_fetch_enabled":true,"standardized_nudges_misinfo":true,"tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled":true,"rweb_video_timestamps_enabled":true,"longform_notetweets_rich_text_read_enabled":true,"longform_notetweets_inline_media_enabled":true,"responsive_web_grok_image_annotation_enabled":true,"responsive_web_grok_imagine_annotation_enabled":true,"responsive_web_grok_community_note_auto_translation_is_enabled":false,"articles_preview_enabled":true,"responsive_web_enhance_cards_enabled":false}'

read -r -d '' _X_JQ_LIB << 'JQ' || true
# X 的 legacy.created_at 是 RFC822（"Wed Oct 07 23:06:08 +0000 2026"），jq 没有 strptime，
# 所以手转成 RFC3339 再交给 to_utc 归一成 UTC Z。解析不了时给空串 —— schema.pipe 会把
# 无日期的条目保留而不是丢弃（与其它源一致）。
def x_rfc822:
  if type != "string" then "" else
    (capture("^[A-Za-z]{3} (?<mon>[A-Za-z]{3}) +(?<day>[0-9]{1,2}) (?<time>[0-9]{2}:[0-9]{2}:[0-9]{2}) (?<off>[+-][0-9]{4}) (?<year>[0-9]{4})$") // null) as $c
    | if $c == null then "" else
        (["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
         | index($c.mon) // 99 | . + 1 | tostring
         | if length < 2 then "0" + . else . end) as $m
        | "\($c.year)-\($m)-\($c.day | if length < 2 then "0" + . else . end)T\($c.time)\($c.off[0:3]):\($c.off[3:5])"
      end
  end;
JQ

x.options() {
	args.add_options "tweet" "" "取单条推文：数字 id 或 x.com/<user>/status/<id> 链接（零凭证）" "URL|ID"
	args.add_options "update-ids" "" "手动刷新 queryId 缓存（失效时会自动刷，一般不用跑；需要真 cookie）"
}

# --update-ids 是带副作用的动作（写 queryId 缓存），必须绕开结果缓存：否则第二次跑会被
# 上一次缓存的空结果挡住，看起来执行了其实什么都没做。
x.cache.bypass() { args.has "--update-ids"; }

# 两件会让 dig x 用不了的事都要探：没 cookie 就取不到 queryId（缓存过期后彻底没得搜），
# 没代理就连不上 x.com。没 cookie 时不探网络 —— 那是用户立刻能自己解决的一环，
# 而探活本身要等一次超时。
x.probe() {
	# doctor 要能分开「源不可用」与「源可达但不能搜」：缺哪个 cookie 逐个点名，可达时再报 queryId 状态，
	# 否则只有一句笼统的「缺前置」，看不出到底能不能搜。
	local -a missing=()
	[[ -n ${X_AUTH_TOKEN:-} && ${X_AUTH_TOKEN:-} != "$_X_ANON_TOKEN" ]] || missing+=("X_AUTH_TOKEN")
	[[ -n ${X_CT0:-} && ${X_CT0:-} != "$_X_ANON_TOKEN" ]] || missing+=("X_CT0")
	if ((${#missing[@]})); then
		local joined
		printf -v joined '%s / ' "${missing[@]}"
		printf '缺少 %s：SearchTimeline 的 queryId 要从 x.com/home 的 main bundle 取，那一步需要登录态' "${joined% / }"
		return 3
	fi

	local probe qid
	probe="$(dig.http.probe "https://x.com/")" || return $?
	qid="$("$(schema.jq.bin)" -r '.SearchTimeline // ""' <<< "$(x.ops.cached)" 2> /dev/null)" || qid=""
	if [[ -n $qid ]]; then
		printf '%s；搜索可用（queryId 已缓存）' "$probe"
	else
		printf '%s；搜索可用（queryId 未缓存，首次搜索会现取一次）' "$probe"
	fi
}

x.search() {
	# 刷新 queryId 是独立动作，不需要查询词，所以放在最前面
	if args.has "--update-ids"; then
		x.ops.update
		return $?
	fi

	local tweet
	tweet="$(dig.opt --tweet)"
	if [[ -n $tweet ]]; then
		local single
		single="$(x.tweet "$tweet")" || return 1
		printf '%s' "$single" | x.tweet.map | schema.pipe 0 | schema.limit 1
		return 0
	fi

	[[ -n $DIG_QUERY ]] || {
		log.error '需要查询词：dig x "关键词"（单条用 --tweet <id|url>，刷新 queryId 用 --update-ids）'
		return 1
	}

	local query_id count vars url body resp status attempt out refresh_failed=false
	count="$(dig.clamp "$DIG_LIMIT" "$_X_PAGE_MAX" "X")"
	resp=""
	status=""
	# 响应体落文件，而不是写 `resp="$(x.fetch …)"`：状态码 `_DIG_HTTP_STATUS` 是靠全局变量传出来的，
	# 套一层命令替换就等于把「失败在哪一步」丢在子 shell 里 —— 403/404 的自愈会因此永远判不出来。
	out="$(mktemp)" || {
		log.error "无法创建临时文件，发不出请求"
		return 1
	}
	vars="$("$(schema.jq.bin)" -nc --arg q "$DIG_QUERY" --argjson n "$count" \
		'{rawQuery: $q, count: $n, querySource: "typed_query", product: "Latest"}')" || {
		rm -f "$out"
		return 1
	}

	# 失败自愈：403/404 说明 queryId 失效（或 X 开始校验 cookie）。有真 cookie 就刷一次再试。
	# 只重试一次 —— 刚刷完的 queryId 还是 403/404，那就是 cookie 的问题，再刷也没有意义。
	for ((attempt = 1; attempt <= 2; attempt++)); do
		# 拿不到 queryId 就没得搜：直接退出，别拿个来路不明的值去撞 403
		if ! query_id="$(x.ops.query_id)"; then
			rm -f "$out"
			return 1
		fi
		body="$("$(schema.jq.bin)" -nc --argjson f "$_X_FEATURES" --arg id "$query_id" \
			'{features: $f, queryId: $id}')" || {
			rm -f "$out"
			return 1
		}
		url="https://x.com/i/api/graphql/${query_id}/SearchTimeline?variables=$("$(schema.jq.bin)" -nr --arg v "$vars" '$v | @uri')" || {
			rm -f "$out"
			return 1
		}

		if x.fetch "$url" "$body" > "$out"; then
			resp="$(cat "$out")"
			status=""
			break
		fi
		status="$(dig.http.status)"

		if ((attempt == 1)) && [[ $status == 404 || $status == 403 ]] && x.ops.can_update; then
			log.info "X 返回 $status（queryId ${query_id} 可能已失效），自动刷新后重试一次"
			# 「刷新本身失败」与「刷新后仍 403」是两回事，下面的话术要分开
			if ! x.ops.update; then
				refresh_failed=true
				break
			fi
			continue
		fi
		break
	done
	rm -f "$out"

	if [[ -z $resp ]]; then
		# 403/404 有两种成因，外部无法区分：按「能不能自救」分两种话术，别把用户往错的方向推
		if [[ $status == 404 || $status == 403 ]]; then
			if [[ $refresh_failed == true ]]; then
				log.error "X 返回 $status，而自动刷新 queryId 也失败了（原因见上面的报错）：先解决刷新失败再试"
			elif x.ops.can_update; then
				log.error "X 返回 $status，自动刷新 queryId 之后仍然如此：更可能是 cookie 的问题（更新 X_AUTH_TOKEN / X_CT0）"
			else
				log.error "X 返回 $status：queryId 已失效，而自动刷新需要真 cookie（X_AUTH_TOKEN / X_CT0）—— main bundle 只在 x.com/home，那个页面未登录会 307 到登录页"
			fi
		elif [[ $status == 401 ]]; then
			log.error "X 返回 401：登录态被拒（X_AUTH_TOKEN / X_CT0 失效或权限不足），重新从 x.com 复制两个 cookie 再试"
		elif [[ $status == 429 ]]; then
			# 统一层对 429 也会退避重试（全局策略），但 X 的额度窗口是分钟级的，重试基本白等
			log.error "X 限流（429）：网页端 SearchTimeline 的额度窗口按分钟计，等一下再试；连着跑大批查询时容易撞上"
		fi
		return 1
	fi

	# HTTP 200 也可能是业务错误：GraphQL 把失败放在 .errors[]，data 为空。静默返回空结果会让调用方
	# 以为「搜到 0 条」，所以这里必须出声。
	local gql_err
	gql_err="$(printf '%s' "$resp" | "$(schema.jq.bin)" -r '.errors[0].message // ""' 2> /dev/null)" || gql_err=""
	[[ -n $gql_err ]] && {
		log.error "X 返回 GraphQL 错误：$gql_err"
		return 1
	}

	printf '%s' "$resp" | x.map | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
}

# ── 请求 ────────────────────────────────────────────────────────────────────
# 请求头是 X 的实际接口契约，抽成一层：x.fetch / x.get 只负责方法与体。
x.headers() { # <auth_token> <ct0>
	requests.headers.append \
		"authorization" "Bearer $_X_BEARER" \
		"cookie" "auth_token=$1; ct0=$2" \
		"x-csrf-token" "$2" \
		"x-twitter-auth-type" "OAuth2Session" \
		"x-twitter-active-user" "yes" \
		"x-twitter-client-language" "en" \
		"origin" "https://x.com" \
		"referer" "https://x.com/"
}

x.request() { # <method> <url> [body] [content-type]
	dig.requests.init || return $?
	x.headers "${X_AUTH_TOKEN:-$_X_ANON_TOKEN}" "${X_CT0:-$_X_ANON_TOKEN}"
	dig.http.request "$1" "$2" "${3:-}" "${4:-}"
}

x.fetch() { x.request POST "$1" "$2" "application/json"; }
# 零凭证的公开端点（syndication）：不带 cookie 与 csrf —— 那些是给需要登录态的接口准备的，
# 发到不需要它的域名上只是把登录凭证多送一份出去。
x.get() {
	dig.requests.init || return $?
	requests.headers.append "accept" "application/json"
	dig.http.request GET "$1" "" ""
}

# 取网页资源（不是 API）：只带 cookie。带上 GraphQL 那套 API 头反而会被拒 ——
# 实测 x.com/home 带 x-twitter-auth-type 时返回 401，只带 cookie 与 UA 才 200。
x.get.page() {
	dig.requests.init || return $?
	requests.headers.append "cookie" "auth_token=${X_AUTH_TOKEN:-$_X_ANON_TOKEN}"
	dig.http.request GET "$1" "" ""
}

# ── queryId 的缓存与刷新 ─────────────────────────────────────────────────────
# 缓存的 operation 表（JSON: {operationName: queryId}）；缺失或过期时给空串。
x.ops.cached() { cache.get "$_X_OPS_NS" "$_X_OPS_KEY" "$_X_OPS_TTL" 2> /dev/null || true; }

# 刷新要用真 cookie（见 x.ops.update）：匿名占位值换不来 main bundle
x.ops.can_update() {
	# 两个都要：x.headers 把它们一起发出去，只配一个必然 403（cookie 与 csrf 必须来自同一次登录会话）
	local token="${X_AUTH_TOKEN:-}" ct0="${X_CT0:-}"
	[[ -n $token && $token != "$_X_ANON_TOKEN" && -n $ct0 && $ct0 != "$_X_ANON_TOKEN" ]]
}

# 当前 SearchTimeline 的 queryId：新鲜缓存优先，缺失或过期就现刷。
#
# 刻意**不留内置值**：写死的 queryId 一过期就是全挂，报出来还是 403/404，看不出真正原因。
# 拿不到就明确失败、让用户去配 cookie，而不是拿一个不知道还能活多久的值硬撑。
x.ops.query_id() {
	local id=""
	id="$(x.ops.cached | "$(schema.jq.bin)" -r '.SearchTimeline // ""' 2> /dev/null)" || id=""
	if [[ -n $id ]]; then
		printf '%s' "$id"
		return 0
	fi

	if ! x.ops.can_update; then
		log.error "拿不到 SearchTimeline 的 queryId：本地没有缓存，而取它需要 X_AUTH_TOKEN / X_CT0（main bundle 只在 x.com/home，未登录会 307 到登录页）"
		return 1
	fi

	log.info "本地没有 queryId 缓存（或已过期），从 x.com 的 main bundle 现取一次"
	x.ops.update || return 1
	id="$(x.ops.cached | "$(schema.jq.bin)" -r '.SearchTimeline // ""' 2> /dev/null)" || id=""
	[[ -n $id ]] || {
		log.error "刷新完成了，但缓存里没有 SearchTimeline 这一项"
		return 1
	}
	printf '%s' "$id"
}

# 刷新：x.com/home 的 HTML → main bundle → 成对的 queryId/operationName。
#
# 为什么必须有真 cookie：main bundle 只出现在 x.com/home，而它对未登录会 307 到
# /i/jf/onboarding/web（实测）。公开页面（xdevelopers / explore / login）里都只有 9 个
# 登录前 chunk，没有 main。所以刷新是「配了 cookie 才有的能力」——但注意**搜索本身不需要**，
# 它靠内置值或已有缓存就能跑。
#
# bundle 是压缩成单行的 JS，operation 表以 queryId:"…",operationName:"…" 成对出现
# （2026-10-07 实测 main.*.js 里有 104 条），所以不需要展开整个 chunk 图。
x.ops.update() {
	if ! x.ops.can_update; then
		log.error "刷新 queryId 需要真 cookie（X_AUTH_TOKEN / X_CT0）：main bundle 只在 x.com/home 里，而那个页面未登录会 307 到登录页"
		return 1
	fi

	log.info "抓 x.com/home，找 main bundle"
	local html main_url js table n sid
	html="$(x.get.page "https://x.com/home")" || return 1

	# 页面里的 URL 是 JSON 转义形式（https:\/\/…），先去反斜杠；HTML 里还混着 NUL
	main_url="$(printf '%s' "$html" | tr -d '\0' | sed 's|\\||g' |
		grep -oE 'https://abs\.twimg\.com[A-Za-z0-9._/-]+/main\.[A-Za-z0-9_-]+\.js' | head -1)"
	if [[ -z $main_url ]]; then
		log.error "x.com/home 的 HTML 里没有 main bundle：cookie 可能已失效（该页会 307 到登录页），或 X 改了页面结构"
		return 1
	fi
	log.info "main bundle：$main_url"

	js="$(x.get.page "$main_url")" || return 1
	table="$(printf '%s' "$js" | tr -d '\0' |
		# 字段顺序与空白由打包器决定，两种顺序都接（X 换打包格式时就会换顺序）
		grep -oE '(queryId:"[A-Za-z0-9_-]+"[[:space:]]*,[[:space:]]*operationName:"[A-Za-z0-9_]+"|operationName:"[A-Za-z0-9_]+"[[:space:]]*,[[:space:]]*queryId:"[A-Za-z0-9_-]+")' |
		sed -E -e 's/queryId:"([^"]+)"[[:space:]]*,[[:space:]]*operationName:"([^"]+)"/\2\t\1/' \
			-e 's/operationName:"([^"]+)"[[:space:]]*,[[:space:]]*queryId:"([^"]+)"/\1\t\2/' |
		"$(schema.jq.bin)" -R -s 'split("\n") | map(select(length > 0)) | map(split("\t") | {(.[0]): .[1]}) | add // {}')" || true

	n="$(printf '%s' "$table" | "$(schema.jq.bin)" -r 'length' 2> /dev/null)" || n=0
	if [[ ${n:-0} -eq 0 ]]; then
		log.error "没能从 main bundle 里提取出 operation 表（$main_url）：X 可能改了打包格式"
		return 1
	fi
	sid="$(printf '%s' "$table" | "$(schema.jq.bin)" -r '.SearchTimeline // ""')"
	if [[ -z $sid ]]; then
		log.error "提取到 $n 个 operation，但里面没有 SearchTimeline"
		return 1
	fi

	if cache.put "$_X_OPS_NS" "$_X_OPS_KEY" "$table"; then
		log.info "已缓存 $n 个 operation（SearchTimeline: $sid）"
	else
		log.warn "operation 表写入缓存失败（不影响本次结果），SearchTimeline: $sid"
	fi
}

# ── 单条推文（syndication，零凭证）────────────────────────────────────────────
x.tweet.id() {
	local s="$1"
	if [[ $s =~ /status(es)?/([0-9]+) ]]; then
		printf '%s' "${BASH_REMATCH[2]}"
		return 0
	fi
	if string.natural.check "$s"; then
		printf '%s' "$s"
		return 0
	fi
	return 1
}

# syndication 对长文（note tweet）只回截断版：响应里有 note_tweet 对象，但 text 停在约 280 字。
# api.fxtwitter.com 是零凭证的公开镜像，给全文（.tweet.text）；只在确实截断时多打一次请求。
# 走 get_public：X 的 DIG_COOKIE 不能发给这个第三方域名。
x.tweet.full_text() {
	local user="$1" id="$2" body
	# user 来自远端 JSON，拼进 URL 前限回 X 允许的用户名字符集
	[[ $user =~ ^[A-Za-z0-9_]+$ ]] || return 1
	body="$(dig.http.get_public "https://api.fxtwitter.com/${user}/status/${id}")" || return 1
	printf '%s' "$body" | "$(schema.jq.bin)" -r '.tweet.text // empty' 2> /dev/null
}

# cdn.syndication.twimg.com 的 token 参数必须存在、但值不校验（实测 x / wrongtoken 都返回
# 完整数据），所以这里不实现那套 base36 算法，给个固定值。哪天 X 开始校验，再补算法。
x.tweet() {
	local id
	id="$(x.tweet.id "$1")" || {
		log.error "认不出推文 id：$1（给 x.com/<user>/status/<id> 这样的链接，或直接给数字 id）"
		return 1
	}

	local body
	body="$(x.get "https://cdn.syndication.twimg.com/tweet-result?id=${id}&token=dig")" || return 1
	if [[ "$(printf '%s' "$body" | "$(schema.jq.bin)" -r 'has("id_str")' 2> /dev/null)" != "true" ]]; then
		log.error "取不到这条推文（id=$id）：可能不存在、已删除，或作者设了保护 —— syndication 端点对这类情况只回 {}"
		return 1
	fi

	# note_tweet 出现 = syndication 只给了截断正文，补全文；补不到时告警，不静默给半句
	if [[ "$(printf '%s' "$body" | "$(schema.jq.bin)" -r 'has("note_tweet")' 2> /dev/null)" == "true" ]]; then
		local user full
		user="$(printf '%s' "$body" | "$(schema.jq.bin)" -r '.user.screen_name // "i"' 2> /dev/null)"
		if full="$(x.tweet.full_text "$user" "$id")" && [[ -n $full ]]; then
			body="$(printf '%s' "$body" | "$(schema.jq.bin)" -c --arg t "$full" '.text = $t')"
		else
			# 标记进 JSON：只打 stderr 的话，只读 stdout 的下游会把截断文本当全文
			body="$(printf '%s' "$body" | "$(schema.jq.bin)" -c '.truncated = true')"
			log.warn "这是长推文（note tweet），syndication 只回约 280 字的截断版，取全文失败：text 不完整（条目带 truncated:true）"
		fi
	fi
	printf '%s' "$body"
}

x.tweet.map() {
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" "$_SCHEMA_JQ_LIB"'
	{
      source: "x",
      id: .id_str,
      url: ("https://x.com/" + (.user.screen_name // "i") + "/status/" + .id_str),
      title: (.text // "" | gsub("\\s+"; " ") | .[0:120]),
      text: (.text // ""),
      author: (.user.screen_name // ""),
      # syndication 给的 created_at 已经是 ISO（带毫秒），过 to_utc 去掉毫秒
      created_at: (.created_at // "" | to_utc),
      # 只有点赞与回复数；点赞数可能是慢更新的（实测新推文是 0）
      engagement: { likes: (.favorite_count // 0), replies: (.conversation_count // 0) },
      # syndication 端点的键是复数 hashtags；单数写法也接（老响应与部分变体）
      tags: [(.entities.hashtags // .entities.hashtag // [])[] | .text // empty],
      query: $query
    }
    + (if .truncated == true then { truncated: true } else {} end)'
}

# dig fetch <推文链接>：与 --tweet 同一条路，只是入口从链接进来（零凭证）
x.search_url() {
	local out
	out="$(x.tweet "$1")" || return 1
	printf '%s' "$out" | x.tweet.map | schema.pipe 0 | schema.limit 1
}

# SearchTimeline 响应 -> 条目流。纯函数，不触网。
#
# 两处结构上的坑：
#   - 有敏感内容的推会包一层 TweetWithVisibilityResults，真身在 .tweet 里；
#   - 同一推常在 entries 里重复出现，所以按 rest_id 保序去重（不能事后 unique_by —— 那会
#     按 id 排序，把 X 自己的时间序打乱）。
x.map() {
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" "$_SCHEMA_JQ_LIB$_X_JQ_LIB"'
    reduce (
      .data.search_by_raw_query.search_timeline.timeline.instructions[]?
      | select(.type == "TimelineAddEntries")
      | .entries[]?
      | select(.content.entryType == "TimelineTimelineItem")
      | (.content.itemContent.tweet_results.result? // empty)
      | if .__typename == "TweetWithVisibilityResults" then .tweet else . end
      | select(.legacy.full_text? != null)
    ) as $t ({ seen: [], out: [] };
      ($t.rest_id // "") as $id
      | if $id == "" or (.seen | index($id)) then . else { seen: (.seen + [$id]), out: (.out + [$t]) } end
    )
    | .out[]
    | . as $t
    | ($t.note_tweet.note_tweet_results.result.text // $t.legacy.full_text // "") as $text
    | {
        source: "x",
        id: $t.rest_id,
        url: ("https://x.com/" + ($t.core.user_results.result.core.screen_name // "i")
              + "/status/" + $t.rest_id),
        # X 没有标题这一栏；取正文首 120 字，让默认渲染与 agent 读 JSONL 时都有个抓手
        title: ($text | gsub("\\s+"; " ") | .[0:120]),
        text: $text,
        # 作者的 screen_name 在 core.user_results.result.core（新版路径），不是 legacy.screen_name
        author: ($t.core.user_results.result.core.screen_name // ""),
        created_at: ($t.legacy.created_at | x_rfc822 | to_utc),
        engagement: {
          likes: ($t.legacy.favorite_count // 0),
          reposts: ($t.legacy.retweet_count // 0),
          replies: ($t.legacy.reply_count // 0),
          quotes: ($t.legacy.quote_count // 0),
          views: (($t.views.count // 0) | if type == "string" then (tonumber? // 0) else . end)
        },
        tags: [($t.legacy.entities.hashtags // [])[] | .text // empty],
        query: $query
      }'
}

source.url.register x x.com twitter.com
source.register x "X 搜索 / 单推（--tweet；单页最多 20 条；queryId 失效时 --update-ids）" "tier:topic period:yes proxy:yes key:required"
