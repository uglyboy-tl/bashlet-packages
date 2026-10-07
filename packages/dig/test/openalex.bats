#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "openalex.map: 还原倒排摘要并补全日期" {
	cat > "$BATS_TEST_TMPDIR/oa.json" << 'JSON'
{"results":[{"id":"https://openalex.org/W1","display_name":"Paper","doi":"https://doi.org/1",
  "publication_date":"2023-01-01","cited_by_count":5,
  "primary_location":{"landing_page_url":"https://example.com/p","source":{"display_name":"EMNLP"}},
  "authorships":[{"author":{"display_name":"Alice"}},{"author":{"display_name":"Bob"}}],
  "abstract_inverted_index":{"Hello":[0],"world":[1]}}]}
JSON
	run openalex.map < "$BATS_TEST_TMPDIR/oa.json"
	assert_success
	assert_jq '[.title,.text,.author,.created_at,.engagement.cited,(.tags|join("/"))]'
	assert_output '["Paper","Hello world","Alice, Bob","2023-01-01T00:00:00Z",5,"EMNLP"]'
}

# ========== -u：按 URL 直取单条 ==========

@test "openalex.search_url: W-id 走 /works/<id>，单对象包一层后过 map" {
	dig.http.get() {
		[[ $1 == "https://api.openalex.org/works/W123" ]] || return 1
		printf '%s' '{"id":"https://openalex.org/W123","display_name":"Paper",
			"publication_date":"2023-01-01","cited_by_count":5,
			"authorships":[{"author":{"display_name":"Alice"}}],
			"abstract_inverted_index":{"Hello":[0],"world":[1]}}'
	}

	run openalex.search_url "https://openalex.org/W123"
	assert_success
	assert_jq '[.title,.text,.author,.engagement.cited]'
	assert_output '["Paper","Hello world","Alice",5]'
}

@test "openalex.search_url: doi.org 走 filter 查询" {
	dig.http.get() {
		[[ $1 == "https://api.openalex.org/works" && ${2:-} == "filter=doi:10.1234/foo" ]] || return 1
		printf '%s' '{"results":[{"id":"https://openalex.org/W9","display_name":"D",
			"publication_date":"2020-01-01","cited_by_count":1,"authorships":[]}]}'
	}

	run openalex.search_url "https://doi.org/10.1234/foo"
	assert_success
	assert_jq '[.title,.source]'
	assert_output '["D","openalex"]'
}

@test "openalex.search_url: URL 不成形时报错（路由由 test/fetch.bats 的表驱动用例覆盖）" {
	run openalex.search_url "https://openalex.org/"
	assert_failure
	assert_output --partial "不是合法的 OpenAlex 作品 URL"
}
