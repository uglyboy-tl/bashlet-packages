#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "v2ex.map_search: 北京时间字符串转成 UTC" {
	cat > "$BATS_TEST_TMPDIR/vx.json" << 'JSON'
{"hits":[{"_source":{"id":359136,"title":"为什么 zsh 数组下标从 1 开始","content":"c",
  "created":"2017-05-04T09:38:57","member":"tttty","replies":1}}]}
JSON
	run v2ex.map_search < "$BATS_TEST_TMPDIR/vx.json"
	assert_success
	assert_jq '[.id,.url,.author,.created_at,.engagement.replies]'
	assert_output '["359136","https://www.v2ex.com/t/359136","tttty","2017-05-04T01:38:57Z",1]'
}
