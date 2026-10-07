#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "reddit.map: epoch 转 UTC、URL 用 subreddit+id 拼、tags 放 subreddit" {
	cat > "$BATS_TEST_TMPDIR/rd.json" << 'JSON'
{"data":[{"id":"abc123","title":"Bash arrays","selftext":"body text","author":"u1",
  "created_utc":1791338863,"score":5,"num_comments":3,"subreddit":"linux"}]}
JSON
	run reddit.map < "$BATS_TEST_TMPDIR/rd.json"
	assert_success
	assert_jq '[.source,.id,.url,.title,.author,.created_at,.engagement.score,.engagement.comments,(.tags|join(","))]'
	assert_output '["reddit","abc123","https://www.reddit.com/r/linux/comments/abc123/","Bash arrays","u1","2026-10-07T02:07:43Z",5,3,"linux"]'
}

@test "reddit.map: data 为 null（空结果）时输出为空而不是报错" {
	echo '{"data":null}' > "$BATS_TEST_TMPDIR/rd_empty.json"
	run reddit.map < "$BATS_TEST_TMPDIR/rd_empty.json"
	assert_success
	assert_output ""
}

@test "reddit.comments_text: 从嵌套评论树取正文、排掉 AutoModerator 与短评论" {
	cat > "$BATS_TEST_TMPDIR/rdtree.json" << 'JSON'
{"data":[{"kind":"t1","data":{"author":"AutoModerator","body":"A long automated moderator notice that should be dropped.",
  "replies":{"data":{"children":[{"kind":"t1","data":{"author":"b","body":"A sufficiently long comment about the subject matter.",
    "replies":{"data":{"children":[{"kind":"t1","data":{"author":"c","body":"Another long enough reply to the above.","replies":""}}]}}}}]}}}},
  {"kind":"t1","data":{"author":"d","body":"short","replies":""}}]}
JSON
	run reddit.comments_text < "$BATS_TEST_TMPDIR/rdtree.json"
	assert_success
	refute_output --partial "AutoModerator"
	refute_output --partial "short"
	assert_output --partial "sufficiently long comment"
	assert_output --partial "Another long enough reply"
}

# ========== -u：按 URL 直取单条 ==========

@test "reddit.search_url: 打 posts/ids 端点并过 reddit.map" {
	args.init
	reddit.options
	args.process
	reddit.fetch() {
		[[ $1 == "https://arctic-shift.photon-reddit.com/api/posts/ids" ]] || return 1
		printf '%s' '{"data":[{"id":"abc123","title":"T","selftext":"body","author":"u1",
			"created_utc":1791338863,"score":5,"num_comments":3,"subreddit":"linux"}]}'
	}

	run reddit.search_url "https://www.reddit.com/r/linux/comments/abc123/x/"
	assert_success
	assert_jq '[.id,.source,.title,.author,.engagement.score,(.tags|join(","))]'
	assert_output '["abc123","reddit","T","u1",5,"linux"]'
}

@test "reddit.search_url: URL 不成形时报错（路由由 test/fetch.bats 的表驱动用例覆盖）" {
	run reddit.search_url "https://www.reddit.com/r/linux/"
	assert_failure
	assert_output --partial "不是合法的 Reddit 帖子 URL"
}

@test "reddit.probe: 上游背压时说成背压，不误导成「网络不通/设代理」" {
	dig.http.probe() { printf 'arctic-shift.photon-reddit.com 返回 HTTP 422'; return 1; }
	sleep() { :; } # 探活的重试间隔在测试里不用真等
	run reddit.probe
	assert_failure
	assert_output --partial "背压"
	assert_output --partial "与代理无关"
	refute_output --partial "网络不通"
}

@test "reddit.probe: 第一次就通时只探一次" {
	# 计数要落文件：探活在 $() 子 shell 里跑，改不了本 shell 的变量
	dig.http.probe() {
		printf 'x' >> "$BATS_TEST_TMPDIR/calls"
		printf 'arctic-shift.photon-reddit.com 可达'
		return 0
	}
	run reddit.probe
	assert_success
	assert_output --partial "可达"
	[ "$(wc -c < "$BATS_TEST_TMPDIR/calls")" -eq 1 ] || {
		echo "应只探一次，实探 $(wc -c < "$BATS_TEST_TMPDIR/calls") 次"
		return 1
	}
}
