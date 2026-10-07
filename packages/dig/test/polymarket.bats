#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "polymarket.map: 合成市场问题与成交量" {
	cat > "$BATS_TEST_TMPDIR/pm.json" << 'JSON'
{"events":[{"title":"E","slug":"e-slug","volume":100,"liquidity":50,
  "markets":[{"question":"Q1"},{"question":"Q2"}]}]}
JSON
	run polymarket.map < "$BATS_TEST_TMPDIR/pm.json"
	assert_success
	assert_jq '[.id,.url,.text,.engagement.volume]'
	assert_output '["e-slug","https://polymarket.com/event/e-slug","Q1 / Q2",100]'
}

# ========== -u：按 URL 直取单条 ==========

@test "polymarket.search_url: public-search 后按 slug 精确匹配 event" {
	dig.http.get() {
		[[ $1 == "https://gamma-api.polymarket.com/public-search" ]] || return 1
		printf '%s' '{"events":[
			{"title":"E","slug":"e-slug","volume":100,"liquidity":50,"markets":[{"question":"Q1"}]},
			{"title":"Z","slug":"z-slug","volume":9,"liquidity":1,"markets":[]}]}'
	}

	run polymarket.search_url "https://polymarket.com/event/e-slug"
	assert_success
	assert_jq '[.id,.title,.engagement.volume]'
	assert_output '["e-slug","E",100]'
}

@test "polymarket.search_url: URL 不成形时报错（路由由 test/fetch.bats 的表驱动用例覆盖）" {
	run polymarket.search_url "https://polymarket.com/"
	assert_failure
	assert_output --partial "不是合法的 Polymarket URL"
}
