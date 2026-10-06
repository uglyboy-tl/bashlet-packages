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
