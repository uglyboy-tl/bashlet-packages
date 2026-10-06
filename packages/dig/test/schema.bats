#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "schema: URL 规范化去追踪参数、host 小写、去尾斜杠" {
	run schema.url.normalize "HTTPS://Example.COM/Path/?utm_source=x&a=1#frag"
	assert_success
	assert_output "https://example.com/Path?a=1"
}

@test "schema: URL 规范化不留尾斜杠" {
	run schema.url.normalize "https://a.example.com/b/"
	assert_output "https://a.example.com/b"
}

@test "schema: all 窗口起点为 0" {
	run schema.period.after all
	assert_output "0"
}

@test "schema: to_utc 把带偏移的 RFC3339 转成 UTC Z" {
	run schema.to_utc "2025-03-31T09:54:39-07:00"
	assert_success
	assert_output "2025-03-31T16:54:39Z"
}

@test "schema: to_utc 对解析不了的输入原样返回" {
	run schema.to_utc "不是日期"
	assert_success
	assert_output "不是日期"
}

@test "schema: 未知时间窗口报错" {
	run schema.period.after "nope"
	assert_failure
}

@test "schema.pipe: 缺必填字段时失败退出" {
	printf '%s\n' '{"source":"x","id":"1","url":"https://a/"}' > "$BATS_TEST_TMPDIR/in.jsonl"
	run schema.pipe 0 < "$BATS_TEST_TMPDIR/in.jsonl"
	assert_failure
}

@test "schema.pipe: 无日期条目保留、窗口外丢弃" {
	{
		printf '%s\n' '{"source":"x","id":"1","url":"https://a/","title":"t","created_at":""}'
		printf '%s\n' '{"source":"x","id":"2","url":"https://b/","title":"t","created_at":"2001-01-01T00:00:00Z"}'
		printf '%s\n' '{"source":"x","id":"3","url":"https://c/","title":"t","created_at":"2099-01-01T00:00:00Z"}'
	} > "$BATS_TEST_TMPDIR/in.jsonl"

	run schema.pipe 1700000000 < "$BATS_TEST_TMPDIR/in.jsonl"
	assert_success
	[ "${#lines[@]}" -eq 2 ]
	assert_line --index 0 --partial '"id":"1"'
	assert_line --index 1 --partial '"id":"3"'
}

@test "schema.pipe: 补上 fetched_at 并规范化 url" {
	printf '%s\n' '{"source":"x","id":"1","url":"https://A.com/b/?utm_medium=y","title":"t","created_at":""}' > "$BATS_TEST_TMPDIR/in.jsonl"
	run schema.pipe 0 < "$BATS_TEST_TMPDIR/in.jsonl"
	assert_success
	assert_output --partial '"url":"https://a.com/b"'
	assert_output --partial '"fetched_at":"'
}

@test "schema.pipe: 缺必填字段时失败（校验与 pipe 共用同一份必填定义）" {
	run schema.pipe 0 <<< '{"source":"x","id":"1"}'
	assert_failure
	assert_output --partial "条目缺少必填字段"
}

@test "schema.pipe: 必填字段齐全时通过" {
	run schema.pipe 0 <<< '{"source":"x","id":"1","url":"https://a/","title":"t","created_at":""}'
	assert_success
}

@test "schema.html_text: 去标签与实体" {
	run schema.html_text "<p>Hello &amp; <b>world</b>&#x27;s</p>"
	assert_success
	assert_output "Hello & world's"
}

@test "schema.limit: 只输出前 N 条且不提前关闭上游" {
	{
		printf '%s\n' '{"n":1}'
		printf '%s\n' '{"n":2}'
		printf '%s\n' '{"n":3}'
		printf '%s\n' '{"n":4}'
	} > "$BATS_TEST_TMPDIR/in.jsonl"

	run schema.limit 2 < "$BATS_TEST_TMPDIR/in.jsonl"
	assert_success
	[ "${#lines[@]}" -eq 2 ]
	assert_output --partial '{"n":1}'
	assert_output --partial '{"n":2}'
	refute_output --partial '{"n":3}'
}

@test "schema.enrich: 只富化前 N 行，其余原样透传" {
	probe_hit() { printf '{"n":%s,"tag":"hit"}' "$2"; }
	run schema.enrich 2 probe_hit <<< $'{"n":1}\n{"n":2}\n{"n":3}'
	assert_success
	assert_line --index 0 '{"n":1,"tag":"hit"}'
	assert_line --index 1 '{"n":2,"tag":"hit"}'
	assert_line --index 2 '{"n":3}'
}

@test "schema.enrich: 回调失败时保留原行，不中断流" {
	probe_fail() { return 1; }
	run schema.enrich 1 probe_fail <<< '{"n":1}'
	assert_success
	assert_output '{"n":1}'
}

@test "schema.enrich: 回调拿到行号与额外参数" {
	probe_args() { printf 'i=%s extra=%s\n' "$2" "$3"; }
	run schema.enrich 1 probe_args E <<< '{"a":1}'
	assert_success
	assert_output 'i=1 extra=E'
}

@test "schema.enrich: N=0 时原样透传" {
	probe_never() { printf '不应该被调用'; }
	run schema.enrich 0 probe_never <<< '{"a":1}'
	assert_success
	assert_output '{"a":1}'
}

@test "schema.render: 人类可读两行输出" {
	run schema.render <<< '{"source":"hn","title":"Hi","author":"pg","created_at":"2025-01-01T00:00:00Z","url":"https://x/","engagement":{"points":3}}'
	assert_success
	assert_line --index 0 "Hi"
	assert_output --partial "[hn]"
	assert_output --partial "3 points"
}
