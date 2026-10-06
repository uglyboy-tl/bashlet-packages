#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "so.map: html 去标签、tags 去重并补上站点名" {
	cat > "$BATS_TEST_TMPDIR/so.json" << 'JSON'
{"items":[{"question_id":123,"link":"https://stackoverflow.com/q/123",
  "title":"How to slice an array?","body":"<p>Use <code>arr</code> here</p>",
  "owner":{"display_name":"pg"},"creation_date":1500000000,
  "score":7,"answer_count":2,"view_count":100,"tags":["bash","arrays"]}]}
JSON
	run so.map stackoverflow < "$BATS_TEST_TMPDIR/so.json"
	assert_success
	assert_jq '{id,url,title,text,author,created_at,engagement,tags}'
	assert_output '{"id":"123","url":"https://stackoverflow.com/q/123","title":"How to slice an array?","text":"Use arr here","author":"pg","created_at":"2017-07-14T02:40:00Z","engagement":{"score":7,"answers":2,"views":100},"tags":["arrays","bash","stackoverflow"]}'
}

@test "so.map: 换站点时 tags 里带的是新站点" {
	run so.map unix <<< '{"items":[{"question_id":9,"link":"https://unix.stackexchange.com/q/9","title":"T","body":"b","tags":["shell"]}]}'
	assert_success
	assert_jq '.tags'
	assert_output '["shell","unix"]'
}

@test "so.map: 没有 items 时无输出" {
	run so.map <<< '{}'
	assert_success
	assert_output ""
}
