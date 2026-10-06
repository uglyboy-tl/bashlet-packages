#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "discourse.map: 用 topic_id 接起 posts 与 topics" {
	cat > "$BATS_TEST_TMPDIR/dc.json" << 'JSON'
{"topics":[{"id":7,"title":"T","slug":"t-slug","reply_count":2,"created_at":"2021-01-01T00:00:00.000Z","views":9}],
 "posts":[{"topic_id":7,"username":"u","blurb":"hello <b>world</b>","created_at":"2021-01-01T00:00:00.000Z","post_number":1}]}
JSON
	run discourse.map discuss.python.org < "$BATS_TEST_TMPDIR/dc.json"
	assert_success
	assert_jq '[.id,.url,.text,.author,.engagement.replies,.engagement.views]'
	assert_output '["discuss.python.org#7","https://discuss.python.org/t/t-slug/7","hello world","u",2,9]'
}
