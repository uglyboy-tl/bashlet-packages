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

# ========== -u：按 URL 直取单条 ==========

@test "github.search_url: 仓库走 REST /repos/<o>/<r>，对齐后过 map_repos" {
	gh() {
		[[ $1 == api && $2 == "repos/a/b" ]] || return 1
		printf '%s' '{"full_name":"a/b","html_url":"https://github.com/a/b","description":"D",
			"stargazers_count":10,"forks_count":2,"created_at":"2018-01-01T00:00:00Z",
			"updated_at":"2026-10-01T00:00:00Z","language":"Rust"}'
	}

	run github.search_url "https://github.com/a/b"
	assert_success
	assert_jq '[.id,.source,.text,.author,.created_at,.engagement.stars,(.tags|join(","))]'
	assert_output '["a/b","github","D","a","2026-10-01T00:00:00Z",10,"Rust"]'
}

@test "github.search_url: pull 也走 issues 端点，pull_request 进 tags" {
	gh() {
		[[ $1 == api && $2 == "repos/a/b/issues/7" ]] || return 1
		printf '%s' '{"number":7,"html_url":"https://github.com/a/b/pull/7","title":"T","body":"B",
			"user":{"login":"u"},"created_at":"2026-01-01T00:00:00Z","comments":5,
			"state":"open","pull_request":{"url":"x"}}'
	}

	run github.search_url "https://github.com/a/b/pull/7"
	assert_success
	assert_jq '[.id,.url,(.tags|join(",")),.engagement.comments]'
	assert_output '["a/b#7","https://github.com/a/b/pull/7","open,pr",5]'
}

@test "github.search_url: URL 不成形时报错（路由由 test/fetch.bats 的表驱动用例覆盖）" {
	run github.search_url "https://github.com/a"
	assert_failure
	assert_output --partial "不是合法的 GitHub 仓库 / issue URL"
}

@test "github.search_url: gist 链接直接报不在源里，不拿它当仓库去问 gh" {
	gh() { echo "gh 不该被调用" >&2; return 1; }
	run github.search_url "https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f"
	assert_failure
	assert_output --partial "gist 不在 dig 的 github 源里"
	refute_output --partial "gh 不该被调用"
}
