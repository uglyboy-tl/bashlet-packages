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

# ========== -u：按 URL 直取单条 ==========

@test "discourse.search_url: 打 <实例>/t/<id>.json 并过 map_topic" {
	dig.http.get() {
		[[ $1 == "https://discuss.python.org/t/12345.json" ]] || return 1
		printf '%s' '{"id":12345,"title":"T","slug":"some-slug","posts_count":4,"views":9,
			"details":{"created_at":"2021-01-01T00:00:00.000Z"},
			"post_stream":{"posts":[{"username":"u","cooked":"hello <b>world</b>"}]}}'
	}

	run discourse.search_url "https://discuss.python.org/t/some-slug/12345"
	assert_success
	assert_jq '[.id,.url,.text,.author,.engagement.replies,.engagement.views]'
	assert_output '["discuss.python.org#12345","https://discuss.python.org/t/some-slug/12345","hello world","u",3,9]'
}

@test "fetch.route: discourse 命中配置实例，别处 host 不认" {
	run fetch.route "https://discuss.python.org/t/some-slug/1"
	assert_success
	[[ $output == "discourse"$'\t'* ]]

	run fetch.route "https://example.com/t/1"
	assert_failure
}

@test "discourse.search_url: URL 里没有主题号时报「不是合法的 Discourse 主题 URL」" {
	run discourse.search_url "https://discuss.python.org/"
	assert_failure
	assert_output --partial "不是合法的 Discourse 主题 URL"
}

@test "discourse.search: -s 不是 host 形态时报错，不把它拼进 URL" {
	run main discourse -s "evil.com/x?" typo
	assert_failure
	assert_output --partial "需要形如"
}
