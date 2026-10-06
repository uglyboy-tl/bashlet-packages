#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "github.map_repos: 时间轴取最后更新、语言进 tags" {
	cat > "$BATS_TEST_TMPDIR/ghr.json" << 'JSON'
[{"fullName":"a/b","url":"https://github.com/a/b","description":"desc",
  "stargazersCount":10,"forksCount":2,"createdAt":"2018-01-01T00:00:00Z",
  "updatedAt":"2026-10-01T00:00:00Z","language":"Rust"}]
JSON
	run github.map_repos < "$BATS_TEST_TMPDIR/ghr.json"
	assert_success
	assert_jq '[.id,.created_at,.author,.engagement.stars,(.tags|join(","))]'
	assert_output '["a/b","2026-10-01T00:00:00Z","a",10,"Rust"]'
}

@test "github.map_commits: 带偏移的提交时间转 UTC" {
	cat > "$BATS_TEST_TMPDIR/ghc.json" << 'JSON'
[{"sha":"abc","url":"https://github.com/a/b/commit/abc",
  "commit":{"message":"fix: thing\n\nbody","comment_count":3,
    "author":{"name":"Me","date":"2026-10-01T18:18:52+08:00"}},
  "repository":{"fullName":"a/b"}}]
JSON
	run github.map_commits < "$BATS_TEST_TMPDIR/ghc.json"
	assert_success
	assert_jq '[.id,.title,.author,.created_at,.engagement.comments]'
	assert_output '["abc","fix: thing","Me","2026-10-01T10:18:52Z",3]'
}

@test "github.map_discussions: answered 进 tags，upvotes 进 engagement" {
	cat > "$BATS_TEST_TMPDIR/ghd.json" << 'JSON'
{"data":{"search":{"nodes":[
 {"number":7,"title":"T","url":"https://github.com/a/b/discussions/7",
  "createdAt":"2026-01-01T00:00:00Z","body":"B","upvoteCount":3,
  "category":{"name":"Q&A"},"answer":{"isAnswer":true},
  "comments":{"totalCount":5},"author":{"login":"u"},"repository":{"nameWithOwner":"a/b"}}
]}}}
JSON
	run github.map_discussions < "$BATS_TEST_TMPDIR/ghd.json"
	assert_success
	assert_jq '[.id,.title,.author,.engagement.comments,.engagement.upvotes,(.tags|join(","))]'
	assert_output '["a/b#7","T","u",5,3,"discussion,Q&A,answered"]'
}
