#!/usr/bin/env bats

# X 源：mapper 是纯函数（离线可测），取数路径靠 mock x.fetch / x.get.page / dig.http.status。
# queryId 没有内置值，所以凡是要走搜索的用例都必须先往缓存里放一个。

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
	# 隔离开发机包内 .env 里的真 cookie：凭证相关的用例各自显式 export/unset，
	# 否则同一个断言在「配过 cookie 的机器」和「没配的机器」上结果不同
	unset X_AUTH_TOKEN X_CT0
}

# 一份精简但同形的 SearchTimeline 响应：一条普通推 + 它的重复条目 + 一条游标。
_x_fixture() {
	cat << 'JSON'
{"data":{"search_by_raw_query":{"search_timeline":{"timeline":{"instructions":[
 {"type":"TimelineAddEntries","entries":[
  {"entryId":"tweet-111","content":{"entryType":"TimelineTimelineItem","itemContent":{"tweet_results":{"result":{
    "__typename":"Tweet","rest_id":"111",
    "core":{"user_results":{"result":{"core":{"screen_name":"alice"}}}},
    "legacy":{"full_text":"hello   world\nsecond line","created_at":"Wed Oct 07 23:06:08 +0000 2026",
              "favorite_count":3,"retweet_count":1,"reply_count":2,"quote_count":0},
    "views":{"count":"1200"}}}}}},
  {"entryId":"tweet-111-dup","content":{"entryType":"TimelineTimelineItem","itemContent":{"tweet_results":{"result":{
    "__typename":"Tweet","rest_id":"111",
    "core":{"user_results":{"result":{"core":{"screen_name":"alice"}}}},
    "legacy":{"full_text":"hello   world\nsecond line","created_at":"Wed Oct 07 23:06:08 +0000 2026","favorite_count":3}}}}}},
  {"entryId":"cursor-bottom-0","content":{"entryType":"TimelineTimelineCursor","cursorType":"Bottom","value":"abc"}}
 ]}
]}}}}}
JSON
}

# 往隔离的缓存里塞一个 queryId，让搜索用例不依赖网络
_x_seed_ids() {
	cache.put "$_X_OPS_NS" "$_X_OPS_KEY" '{"SearchTimeline":"TESTID"}'
}

# ========== x.map ==========

@test "x.map: Tweet 映射，RFC822 时间归一到 UTC，重复 rest_id 只出一条" {
	_x_fixture > "$BATS_TEST_TMPDIR/x.json"
	run x.map < "$BATS_TEST_TMPDIR/x.json"
	assert_success
	# 去重后只剩 1 行：重复的 111 与游标条目都不该出条目
	assert_equal "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" "1"
	assert_jq '[.id,.source,.author,.created_at,.engagement.likes,.engagement.views,.url]'
	assert_output '["111","x","alice","2026-10-07T23:06:08Z",3,1200,"https://x.com/alice/status/111"]'
}

@test "x.map: title 取正文压平后的首 120 字" {
	_x_fixture > "$BATS_TEST_TMPDIR/x.json"
	run x.map < "$BATS_TEST_TMPDIR/x.json"
	assert_success
	assert_jq '.title'
	assert_output '"hello world second line"'
}

@test "x.map: TweetWithVisibilityResults 取 .tweet，note_tweet 正文优先于 legacy.full_text" {
	cat > "$BATS_TEST_TMPDIR/x.json" << 'JSON'
{"data":{"search_by_raw_query":{"search_timeline":{"timeline":{"instructions":[
 {"type":"TimelineAddEntries","entries":[
  {"entryId":"tweet-222","content":{"entryType":"TimelineTimelineItem","itemContent":{"tweet_results":{"result":{
    "__typename":"TweetWithVisibilityResults",
    "tweet":{"rest_id":"222",
      "core":{"user_results":{"result":{"core":{"screen_name":"bob"}}}},
      "legacy":{"full_text":"short truncated","created_at":"Tue Oct 06 10:00:00 +0000 2026","favorite_count":0},
      "note_tweet":{"note_tweet_results":{"result":{"text":"LONG note tweet body"}}}}}}}}}
 ]}
]}}}}}
JSON
	run x.map < "$BATS_TEST_TMPDIR/x.json"
	assert_success
	assert_jq '[.id,.author,.text,.created_at]'
	assert_output '["222","bob","LONG note tweet body","2026-10-06T10:00:00Z"]'
}

@test "x.map: 时间解析不了时 created_at 给空串，条目仍保留" {
	cat > "$BATS_TEST_TMPDIR/x.json" << 'JSON'
{"data":{"search_by_raw_query":{"search_timeline":{"timeline":{"instructions":[
 {"type":"TimelineAddEntries","entries":[
  {"entryId":"tweet-333","content":{"entryType":"TimelineTimelineItem","itemContent":{"tweet_results":{"result":{
    "__typename":"Tweet","rest_id":"333",
    "core":{"user_results":{"result":{"core":{"screen_name":"carol"}}}},
    "legacy":{"full_text":"no date here","created_at":""}}}}}}
 ]}
]}}}}}
JSON
	run x.map < "$BATS_TEST_TMPDIR/x.json"
	assert_success
	assert_jq '[.id,.created_at]'
	assert_output '["333",""]'
}

# ========== 请求头 ==========

@test "x.fetch: ct0 进 x-csrf-token，两个 cookie 进 cookie 头，走 POST" {
	export X_AUTH_TOKEN="atok" X_CT0="ctok"
	local dump="$BATS_TEST_TMPDIR"
	dig.http.request() {
		printf '%s' "$1" > "$dump/method"
		return 1
	}
	x.fetch "https://x.com/i/api/graphql/q/SearchTimeline" '{}' > /dev/null || true
	assert_equal "$(cat "$dump/method")" "POST"
	assert_equal "${_REQUESTS_HEADERS[x-csrf-token]:-}" "ctok"
	assert_equal "${_REQUESTS_HEADERS[cookie]:-}" "auth_token=atok; ct0=ctok"
	assert_equal "${_REQUESTS_HEADERS[x-twitter-auth-type]:-}" "OAuth2Session"
}

@test "x.fetch: cookie 丢了时用匿名占位值顶上（缓存里有 queryId 就还能搜）" {
	unset X_AUTH_TOKEN X_CT0
	dig.http.request() { return 1; }
	x.fetch "https://x.com/i/api/graphql/q/SearchTimeline" '{}' > /dev/null || true
	assert_equal "${_REQUESTS_HEADERS[cookie]:-}" "auth_token=dig-anon; ct0=dig-anon"
	assert_equal "${_REQUESTS_HEADERS[x-csrf-token]:-}" "dig-anon"
}

@test "x.get.page: 页面请求不带 GraphQL 那套 API 头（带了 x.com/home 会 401）" {
	local dump="$BATS_TEST_TMPDIR"
	dig.http.request() {
		printf '%s|%s' "${_REQUESTS_HEADERS[x-twitter-auth-type]:-}" "${_REQUESTS_HEADERS[cookie]:-}" > "$dump/page"
		return 1
	}
	x.get.page "https://x.com/home" > /dev/null || true
	assert_equal "$(cat "$dump/page")" "|auth_token=dig-anon"
}

# ========== 搜索 ==========

@test "x.search: variables 带 rawQuery/count/product=Latest，body 带 38 个 features" {
	export X_AUTH_TOKEN=tok X_CT0=csrf DIG_QUERY="claude code" DIG_LIMIT=5 DIG_AFTER=0
	local dump="$BATS_TEST_TMPDIR"
	_x_fixture > "$dump/fixture.json"
	_x_seed_ids
	x.fetch() {
		printf '%s\n' "$1" > "$dump/url"
		printf '%s' "$2" > "$dump/body"
		cat "$dump/fixture.json"
	}

	x.search > "$dump/out"

	run jq -r '.queryId' "$dump/body"
	assert_output "TESTID"
	run jq -r '.features | length' "$dump/body"
	assert_output "38"
	run cat "$dump/url"
	assert_output --partial "/TESTID/SearchTimeline?variables="
	assert_output --partial "rawQuery%22%3A%22claude%20code"
	assert_output --partial "%22count%22%3A5"
	run cat "$dump/out"
	assert_output --partial '"id":"111"'
}

@test "x.search: 超过单页上限时 clamp 到 20 并告警" {
	export X_AUTH_TOKEN=tok X_CT0=csrf DIG_QUERY="q" DIG_LIMIT=100 DIG_AFTER=0
	local dump="$BATS_TEST_TMPDIR"
	_x_seed_ids
	x.fetch() {
		printf '%s\n' "$1" > "$dump/url"
		printf '{"data":{"search_by_raw_query":{"search_timeline":{"timeline":{"instructions":[]}}}}}'
	}
	run x.search
	assert_success
	assert_output --partial "单次最多 20 条"
	# count 在 variables（URL）里，不在请求体
	run cat "$dump/url"
	assert_output --partial "%22count%22%3A20"
}

@test "x.search: 403 时自动刷新 queryId 并重试一次，用新 id 命中" {
	export X_AUTH_TOKEN=realtoken X_CT0=realct0 DIG_QUERY="q" DIG_LIMIT=5 DIG_AFTER=0
	local dump="$BATS_TEST_TMPDIR"
	_x_fixture > "$dump/fixture.json"
	cache.put "$_X_OPS_NS" "$_X_OPS_KEY" '{"SearchTimeline":"OLDID"}'
	dig.http.status() { printf '403'; }
	x.get.page() {
		case "$1" in
			*"/home") printf '%s' '<script src="https://abs.twimg.com/x/web/main.nn.js"></script>' ;;
			*"main.nn.js") printf '%s' 'e.exports={queryId:"NEWID",operationName:"SearchTimeline"}' ;;
		esac
	}
	x.fetch() {
		local c
		c="$(cat "$dump/calls" 2> /dev/null || echo 0)"
		c=$((c + 1))
		printf '%s' "$c" > "$dump/calls"
		((c == 1)) && return 1
		cat "$dump/fixture.json"
	}

	run x.search
	assert_success
	assert_output --partial '"id":"111"'
	assert_equal "$(cat "$dump/calls")" "2"
	run x.ops.query_id
	assert_output "NEWID"
}

@test "x.search: 自愈能读到状态码（x.fetch 一旦包进命令替换，_DIG_HTTP_STATUS 就丢在子 shell 里）" {
	export X_AUTH_TOKEN=realtoken X_CT0=realct0 DIG_QUERY="q" DIG_LIMIT=5 DIG_AFTER=0
	local dump="$BATS_TEST_TMPDIR"
	_x_fixture > "$dump/fixture.json"
	cache.put "$_X_OPS_NS" "$_X_OPS_KEY" '{"SearchTimeline":"OLDID"}'

	# 刷新路径（x.get.page）用桩；GraphQL 路径走真实的 x.fetch → x.request → dig.http.request
	x.get.page() {
		case "$1" in
			*"/home") printf '%s' '<script src="https://abs.twimg.com/x/web/main.new.js"></script>' ;;
			*"main.new.js") printf '%s' 'e.exports={queryId:"NEWID",operationName:"SearchTimeline"}' ;;
		esac
	}
	dig.http.request() {
		if [[ $2 == *OLDID* ]]; then
			_DIG_HTTP_STATUS=403 # 真实的 dig.http.request 就是这样留下状态码的
			return 1
		fi
		cat "$dump/fixture.json"
	}

	run x.search
	assert_success
	assert_output --partial '"id":"111"'
	run x.ops.query_id
	assert_output "NEWID"
}

@test "x.search: 没有真 cookie 时 403 不重试，直接说明自动刷新需要 cookie" {
	unset X_AUTH_TOKEN X_CT0
	export DIG_QUERY="q" DIG_LIMIT=5 DIG_AFTER=0
	local dump="$BATS_TEST_TMPDIR"
	cache.put "$_X_OPS_NS" "$_X_OPS_KEY" '{"SearchTimeline":"OLDID"}'
	dig.http.status() { printf '403'; }
	x.fetch() {
		local c
		c="$(cat "$dump/calls" 2> /dev/null || echo 0)"
		c=$((c + 1))
		printf '%s' "$c" > "$dump/calls"
		return 1
	}
	run x.search
	assert_failure
	assert_equal "$(cat "$dump/calls")" "1"
	assert_output --partial "自动刷新需要真 cookie"
}

# ========== --tweet：单推（syndication） ==========

@test "x.tweet.id: 从 URL 或裸 id 抠出 id，认不出时失败" {
	run x.tweet.id "https://x.com/alice/status/2107975057934790905"
	assert_output "2107975057934790905"
	run x.tweet.id "https://twitter.com/a/status/123"
	assert_output "123"
	run x.tweet.id "2107975057934790905"
	assert_output "2107975057934790905"
	run x.tweet.id "not-an-id"
	assert_failure
}

@test "x.tweet.map: syndication 响应映射，ISO 时间去掉毫秒，hashtag 进 tags" {
	cat > "$BATS_TEST_TMPDIR/t.json" << 'JSON'
{"id_str":"111","text":"hello   world","created_at":"2026-10-07T23:23:12.000Z",
 "favorite_count":7,"conversation_count":3,"user":{"screen_name":"alice"},
 "entities":{"hashtag":[{"text":"ai"},{"text":"bash"}]}}
JSON
	run x.tweet.map < "$BATS_TEST_TMPDIR/t.json"
	assert_success
	assert_jq '[.id,.source,.author,.created_at,.engagement.likes,.engagement.replies,(.tags|join(",")),.url]'
	assert_output '["111","x","alice","2026-10-07T23:23:12Z",7,3,"ai,bash","https://x.com/alice/status/111"]'
}

@test "x.tweet: 打 syndication 端点且不需要 cookie 与 queryId" {
	unset X_AUTH_TOKEN X_CT0
	local dump="$BATS_TEST_TMPDIR"
	x.get() {
		printf '%s' "$1" > "$dump/url"
		printf '%s' '{"id_str":"111","text":"hi","created_at":"2026-10-07T00:00:00.000Z","user":{"screen_name":"a"}}'
	}
	run x.tweet "https://x.com/a/status/111"
	assert_success
	run cat "$dump/url"
	assert_output --partial "syndication.twimg.com/tweet-result?id=111"
}

@test "x.tweet: syndication 对取不到的推只回 {}，要说清楚而不是给空条目" {
	x.get() { printf '%s' '{}'; }
	run x.tweet "111"
	assert_failure
	assert_output --partial "取不到这条推文"
}

# ========== queryId 的缓存与刷新 ==========

@test "x.ops.query_id: 没有缓存又没有真 cookie 时明确失败（刻意不留内置值）" {
	unset X_AUTH_TOKEN X_CT0
	run x.ops.query_id
	assert_failure
	assert_output --partial "拿不到 SearchTimeline 的 queryId"
}

@test "x.ops.query_id: 没有缓存但有真 cookie 时自动现刷一次" {
	export X_AUTH_TOKEN=realtoken X_CT0=realct0
	x.get.page() {
		case "$1" in
			*"/home") printf '%s' '<script src="https://abs.twimg.com/x/web/main.zz.js"></script>' ;;
			*"main.zz.js") printf '%s' 'e.exports={queryId:"AUTOID",operationName:"SearchTimeline"}' ;;
		esac
	}
	# 现刷路径会打 INFO 日志（stderr），所以不用 run —— 只捕 stdout
	local out
	out="$(x.ops.query_id 2> /dev/null)"
	assert_equal "$out" "AUTOID"
}

@test "x.cache.bypass: 只有 --update-ids 时不进结果缓存（否则第二次跑等于没跑）" {
	args.has() { [[ $1 == "--update-ids" ]]; }
	run x.cache.bypass
	assert_success

	args.has() { return 1; }
	run x.cache.bypass
	assert_failure
}

@test "x.ops.update: 未配真 cookie 时拒绝并说明为什么（main bundle 只在 /home）" {
	unset X_AUTH_TOKEN X_CT0
	run x.ops.update
	assert_failure
	assert_output --partial "刷新 queryId 需要真 cookie"
}

@test "x.ops.update: 从 main bundle 里提取成对的 operation 并写入缓存" {
	export X_AUTH_TOKEN=realtoken X_CT0=realct0
	x.get.page() {
		case "$1" in
			*"/home")
				printf '%s' '<script src="https://abs.twimg.com/x-web/x-web/main.abc123.js"></script>'
				;;
			*"main.abc123.js")
				cat << 'JS'
e.exports={queryId:"M1jEez78PEfVfbQLvlWMvQ",operationName:"SearchTimeline",operationType:"query"}
e.exports={queryId:"D1nwFlsu_qHsX92YzoRaaA",operationName:"AddContentDisclosure"}
JS
				;;
			*) return 1 ;;
		esac
	}
	run x.ops.update
	assert_success
	assert_output --partial "已缓存 2 个 operation"
	run x.ops.query_id
	assert_output "M1jEez78PEfVfbQLvlWMvQ"
}

# ========== 探活 ==========

@test "x.probe: 没 cookie 报缺前置；有 cookie 才探可达性" {
	unset X_AUTH_TOKEN X_CT0
	run x.probe
	assert_equal "$status" "3"
	assert_output --partial "缺少 X_AUTH_TOKEN / X_CT0"

	export X_AUTH_TOKEN=realtoken X_CT0=realct0
	dig.http.probe() {
		printf 'x.com 可达'
		return 0
	}
	run x.probe
	assert_equal "$status" "0"
	assert_output --partial "x.com 可达"
	assert_output --partial "搜索可用"
}

@test "x.ops.update: bundle 里 operationName 与 queryId 顺序颠倒也能提取" {
	export X_AUTH_TOKEN=realtoken X_CT0=realct0
	x.get.page() {
		case "$1" in
			*"/home") printf '%s' '<script src="https://abs.twimg.com/x/web/main.rev.js"></script>' ;;
			*"main.rev.js") printf '%s' 'e.exports={operationName:"SearchTimeline",queryId:"REVID"}' ;;
		esac
	}

	run x.ops.update
	assert_success
	run x.ops.cached
	assert_output --partial '"SearchTimeline": "REVID"'
}

@test "x.search: HTTP 200 但 GraphQL 报 errors 时明确失败，不当成空结果" {
	export X_AUTH_TOKEN=realtoken X_CT0=realct0 DIG_QUERY="q" DIG_LIMIT=5 DIG_AFTER=0
	cache.put "$_X_OPS_NS" "$_X_OPS_KEY" '{"SearchTimeline":"ID"}'
	x.fetch() { printf '%s' '{"errors":[{"message":"Rate limit exceeded"}]}'; }

	run x.search
	assert_failure
	assert_output --partial "GraphQL 错误"
	assert_output --partial "Rate limit exceeded"
}

@test "x.ops.can_update: 只配 X_AUTH_TOKEN 不算可用（x.headers 两个都要）" {
	export X_AUTH_TOKEN=realtoken
	unset X_CT0
	run x.ops.can_update
	assert_failure

	export X_CT0=realct0
	run x.ops.can_update
	assert_success
}

@test "x.probe: 只配 X_AUTH_TOKEN 时点名缺 X_CT0，而不是笼统的缺前置" {
	export X_AUTH_TOKEN=realtoken
	unset X_CT0
	run x.probe
	assert_equal "$status" "3"
	assert_output --partial "缺少 X_CT0"
	refute_output --partial "X_AUTH_TOKEN /"
}

@test "x.tweet.map: syndication 用复数 hashtags 也能进 tags" {
	cat > "$BATS_TEST_TMPDIR/t2.json" << 'JSON'
{"id_str":"222","text":"hello","created_at":"2026-10-07T23:23:12.000Z",
 "favorite_count":1,"conversation_count":0,"user":{"screen_name":"bob"},
 "entities":{"hashtags":[{"text":"ai"},{"text":"bash"}]}}
JSON
	run x.tweet.map < "$BATS_TEST_TMPDIR/t2.json"
	assert_success
	assert_jq '[.tags]'
	assert_output '[["ai","bash"]]'
}

@test "x.tweet: syndication 请求不带 cookie 与 csrf（公开端点不需要登录态）" {
	export X_AUTH_TOKEN=realtoken X_CT0=realct0
	local dump="$BATS_TEST_TMPDIR"
	dig.http.request() {
		printf '%s|%s' "${_REQUESTS_HEADERS[cookie]:-}" "${_REQUESTS_HEADERS[x-csrf-token]:-}" > "$dump/hdr"
		printf '%s' '{"id_str":"111","text":"hi","created_at":"2026-10-07T00:00:00.000Z","user":{"screen_name":"a"}}'
	}

	run x.tweet 111
	assert_success
	assert_equal "$(cat "$dump/hdr")" "|"
}

@test "x.map: 从 legacy.entities.hashtags 取 tags（不再写死空数组）" {
	_x_fixture | jq -c '(.data.search_by_raw_query.search_timeline.timeline.instructions[0].entries[0]
		.content.itemContent.tweet_results.result.legacy.entities) = {hashtags: [{text: "ai"}, {text: "bash"}]}' \
		> "$BATS_TEST_TMPDIR/f.json"

	run x.map < "$BATS_TEST_TMPDIR/f.json"
	assert_success
	assert_jq '[.tags]'
	assert_output '[["ai","bash"]]'
}

@test "x.search: 401 给出「登录态被拒」的话术，而不是静默失败" {
	export X_AUTH_TOKEN=realtoken X_CT0=realct0 DIG_QUERY="q" DIG_LIMIT=5 DIG_AFTER=0
	cache.put "$_X_OPS_NS" "$_X_OPS_KEY" '{"SearchTimeline":"ID"}'
	dig.http.status() { printf '401'; }
	x.fetch() { return 1; }

	run x.search
	assert_failure
	assert_output --partial "401"
	assert_output --partial "登录态被拒"
}
