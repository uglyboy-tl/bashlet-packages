#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "youtube.map: 提取 videoId/标题/频道/播放量" {
	cat > "$BATS_TEST_TMPDIR/yt.json" << 'JSON'
{"contents":{"a":{"videoRenderer":{
  "videoId":"abc123",
  "title":{"runs":[{"text":"Arrays in Bash"}]},
  "ownerText":{"runs":[{"text":"Chan"}]},
  "viewCountText":{"simpleText":"1,234 views"},
  "lengthText":{"simpleText":"7:10"},
  "publishedTimeText":{"simpleText":"1 year ago"}
}}}}
JSON
	run youtube.map < "$BATS_TEST_TMPDIR/yt.json"
	assert_success
	assert_jq '[.id,.title,.author,.engagement.views,.engagement.duration]'
	assert_output '["abc123","Arrays in Bash","Chan",1234,"7:10"]'
}
