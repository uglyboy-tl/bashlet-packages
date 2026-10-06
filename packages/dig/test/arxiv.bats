#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "arxiv.map: Atom -> 条目，http 链接升级 https、作者逗号连接" {
	cat > "$BATS_TEST_TMPDIR/arxiv.xml" << 'XML'
<feed xmlns="http://www.w3.org/2005/Atom">
 <entry>
  <id>http://arxiv.org/abs/2103.00112v1</id>
  <published>2021-03-01T00:00:00Z</published>
  <title>Transformer in Transformer</title>
  <summary>We present a novel transformer.</summary>
  <author><name>Kai Han</name></author>
  <author><name>An Xiao</name></author>
 </entry>
</feed>
XML
	run arxiv.map < "$BATS_TEST_TMPDIR/arxiv.xml"
	assert_success
	assert_jq '{id,url,title,text,author,created_at}'
	assert_output '{"id":"http://arxiv.org/abs/2103.00112v1","url":"https://arxiv.org/abs/2103.00112v1","title":"Transformer in Transformer","text":"We present a novel transformer.","author":"Kai Han, An Xiao","created_at":"2021-03-01T00:00:00Z"}'
}

@test "arxiv.map: 多条 entry 各出一行" {
	cat > "$BATS_TEST_TMPDIR/two.xml" << 'XML'
<feed>
 <entry><id>http://arxiv.org/abs/1</id><published>2021-01-01T00:00:00Z</published>
  <title>A</title><summary>a</summary><author><name>X</name></author></entry>
 <entry><id>http://arxiv.org/abs/2</id><published>2021-01-02T00:00:00Z</published>
  <title>B</title><summary>b</summary><author><name>Y</name></author></entry>
</feed>
XML
	run arxiv.map < "$BATS_TEST_TMPDIR/two.xml"
	assert_success
	[ "${#lines[@]}" -eq 2 ]
	assert_line --index 0 --partial '"id":"http://arxiv.org/abs/1"'
	assert_line --index 1 --partial '"id":"http://arxiv.org/abs/2"'
}
