#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "hn.comments_text: 从评论树里取正文并过滤短评论" {
	cat > "$BATS_TEST_TMPDIR/hnc.json" << 'JSON'
{"title":"S","children":[
  {"author":"a","text":"SABR"},
  {"author":"b","text":"<p>A sufficiently long comment about the subject matter.</p>","children":[
     {"author":"c","text":"<p>Another long enough reply to the above comment.</p>"}]}
]}
JSON
	run hn.comments_text < "$BATS_TEST_TMPDIR/hnc.json"
	assert_success
	refute_output --partial "SABR"
	assert_output --partial "sufficiently long comment"
	assert_output --partial "Another long enough reply"
}

@test "hn.map_comments: 评论条目带故事标题与纯文本" {
	cat > "$BATS_TEST_TMPDIR/hnc2.json" << 'JSON'
{"hits":[{"objectID":"99","story_title":"S","author":"a",
  "created_at":"2026-01-01T00:00:00Z","comment_text":"<p>hello &amp; bye</p>","_tags":["comment"]}]}
JSON
	run hn.map_comments < "$BATS_TEST_TMPDIR/hnc2.json"
	assert_success
	assert_jq '[.id,.title,.text,.author,(.tags|join(","))]'
	assert_output '["99","S","hello & bye","a","comment"]'
}

# ========== -u：按 URL 直取单条 ==========

@test "hn.search_url: 打 items 端点并把 item 对齐成 map 的 hit" {
	dig.http.get() {
		[[ $1 == "https://hn.algolia.com/api/v1/items/12345" ]] || return 1
		printf '%s' '{"id":12345,"created_at":"2026-01-01T00:00:00Z","type":"story",
			"author":"pg","title":"Ask HN: X","url":"https://example.com/x",
			"text":"<p>Body &amp; more</p>","points":10,"children":[{"id":1},{"id":2}]}'
	}

	run hn.search_url "https://news.ycombinator.com/item?id=12345"
	assert_success
	assert_jq '[.id,.source,.title,.text,.author,.engagement.points,.engagement.comments,.tags[0]]'
	assert_output '["12345","hn","Ask HN: X","Body & more","pg",10,2,"story"]'
}

@test "hn.search_url: 链接帖的 url 为空时回退到 item 页，text 为空" {
	dig.http.get() {
		printf '%s' '{"id":7,"created_at":"2026-01-01T00:00:00Z","type":"story",
			"author":"a","title":"Link","url":null,"text":"","points":1,"children":[]}'
	}

	run hn.search_url "https://news.ycombinator.com/item?id=7"
	assert_success
	assert_jq '[.url,.text]'
	assert_output '["https://news.ycombinator.com/item?id=7",""]'
}

@test "hn.search_url: URL 不成形时报错（路由由 test/fetch.bats 的表驱动用例覆盖）" {
	run hn.search_url "https://news.ycombinator.com/"
	assert_failure
	assert_output --partial "不是合法的 HN item URL"
}
