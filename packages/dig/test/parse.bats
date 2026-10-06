#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "parse.xml.records: 按记录标签切片出 TSV" {
	cat > "$BATS_TEST_TMPDIR/x.xml" << 'XML'
<feed>
  <entry><title>T1</title><id>i1</id><name>N1</name><name>N2</name></entry>
  <entry><title>T2</title><id>i2</id></entry>
</feed>
XML
	run parse.xml.records entry 'title,id,*name' < "$BATS_TEST_TMPDIR/x.xml"
	assert_success
	[ "${#lines[@]}" -eq 2 ]
	assert_line --index 0 $'T1\ti1\tN1, N2'
	assert_line --index 1 $'T2\ti2\t'
}

@test "parse.xml.records: @属性 与 #正文" {
	printf '%s' '<i><d p="1,2,3">hello</d><d p="4">bye</d></i>' > "$BATS_TEST_TMPDIR/d.xml"
	run parse.xml.records d '@p,#' < "$BATS_TEST_TMPDIR/d.xml"
	assert_success
	assert_line --index 0 $'1,2,3\thello'
	assert_line --index 1 $'4\tbye'
}

@test "parse.xml.records: 压平换行与解实体" {
	printf '%s' '<a><entry><title>line1
line2 &amp; more</title></entry></a>' > "$BATS_TEST_TMPDIR/m.xml"
	run parse.xml.records entry 'title' < "$BATS_TEST_TMPDIR/m.xml"
	assert_success
	assert_output 'line1 line2 & more'
}

@test "parse.xml.records: 记录里含子元素时不误切" {
	printf '%s' '<a><entry><author><name>N</name></author><title>T</title></entry></a>' > "$BATS_TEST_TMPDIR/n.xml"
	run parse.xml.records entry 'title,*name' < "$BATS_TEST_TMPDIR/n.xml"
	assert_success
	assert_output $'T\tN'
}

@test "parse.json.embedded: 花括号配对忽略字符串里的括号与转义" {
	printf '%s' 'x var ytInitialPlayerResponse = {"a":{"b":"}}{x\"y"}};var meta=1;</script>' > "$BATS_TEST_TMPDIR/pg.html"
	run parse.json.embedded ytInitialPlayerResponse < "$BATS_TEST_TMPDIR/pg.html"
	assert_success
	run bash -c 'jq -c .' <<< "$output"
	assert_output '{"a":{"b":"}}{x\"y"}}'
}

@test "parse.json.embedded: 跨行也能抠" {
	printf '%s\n' 'var X = {' '  "a": 1,' '  "b": [2, 3]' '};' > "$BATS_TEST_TMPDIR/multi.html"
	run parse.json.embedded X < "$BATS_TEST_TMPDIR/multi.html"
	assert_success
	run bash -c 'jq -c .' <<< "$output"
	assert_output '{"a":1,"b":[2,3]}'
}

@test "parse.json.embedded: 抠不到时返回非零且无输出" {
	printf '%s' 'nothing here' > "$BATS_TEST_TMPDIR/empty.html"
	run parse.json.embedded ytInitialPlayerResponse < "$BATS_TEST_TMPDIR/empty.html"
	assert_failure
	assert_output ""
}

@test "parse.json.patch: 空值不改动原行，非空值才覆盖" {
	run parse.json.patch '{"text":"原简介","created_at":"2025-01-01T00:00:00Z"}' "text=" "created_at=2025-02-02T00:00:00Z"
	assert_success
	assert_output '{"text":"原简介","created_at":"2025-02-02T00:00:00Z"}'
}

@test "parse.json.patch: 值里含 = 不被截断" {
	run parse.json.patch '{"text":""}' 'text=a=b&c=d'
	assert_success
	assert_output '{"text":"a=b&c=d"}'
}

@test "parse.json.patch: 全空值时原行原样输出" {
	run parse.json.patch '{"a":1}' "text="
	assert_success
	assert_output '{"a":1}'
}
