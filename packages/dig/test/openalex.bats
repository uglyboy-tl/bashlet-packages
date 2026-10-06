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
