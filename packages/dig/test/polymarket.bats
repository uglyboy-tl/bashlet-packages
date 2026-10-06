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
