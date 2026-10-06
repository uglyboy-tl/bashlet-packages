#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "weread.map: 跨分组去重且保留搜索顺序" {
	run weread.map < "$BATS_TEST_DIRNAME/fixtures/weread-search.json"
	assert_success
	[ "${#lines[@]}" -eq 2 ]
	assert_line --index 0 --partial '"id":"1"'
	assert_line --index 1 --partial '"id":"2"'
}

@test "weread.map: 映射评分、在读人数与标签" {
	run weread.map < "$BATS_TEST_DIRNAME/fixtures/weread-search.json"
	assert_success
	run bash -c "jq -c '[.id, .source, .author, .engagement.rating, .engagement.ratings, .engagement.reading, (.tags | join(\",\"))]' <<< \"\$1\"" _ "${lines[0]}"
	assert_output '["1","weread","作者甲",930,100,7,"神作,电子书"]'
}

@test "weread.api.call: 传输层失败报「网络不通」，不是 HTTP 0" {
	weread.key() { printf 'k'; }
	requests.post() { printf '%s' '{"status_code":0,"curl_exit":7,"body":"","headers":{}}'; }
	run weread.api.call /store/search keyword x
	assert_failure
	assert_output --partial "网络不通"
	refute_output --partial "HTTP 0"
}

@test "weread.body: 数字参数编码成 JSON number，字符串成 string" {
	run weread.body /store/search keyword "三体" scope 10 count 3
	assert_success
	run bash -c "jq -e '{api_name: .api_name, keyword: .keyword, scope: (.scope|type), count: (.count|type), ver: (.skill_version != null)}' <<< \"\$1\"" _ "$output"
	assert_output --partial '"scope": "number"'
	assert_output --partial '"count": "number"'
	assert_output --partial '"ver": true'
}

@test "weread.check: upgrade_info 只警告不失败" {
	run weread.check '{"errcode":0,"upgrade_info":{"message":"有新版本"}}'
	assert_success
	assert_output --partial "有新版本"
}

@test "weread.check: 业务 errcode 非 0 报错" {
	run weread.check '{"errcode":-2010,"errmsg":"用户不存在"}'
	assert_failure
	assert_output --partial "errcode=-2010"
}
