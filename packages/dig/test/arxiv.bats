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

# ========== -u：按 URL 直取单条 ==========

@test "arxiv.search_url: 打 id_list 查询并过 Atom 解析" {
	dig.http.get() {
		[[ $1 == "https://export.arxiv.org/api/query" && ${2:-} == "id_list=2103.00112v1" ]] || return 1
		printf '%s' '<feed><entry><id>http://arxiv.org/abs/2103.00112v1</id>
			<published>2021-03-01T00:00:00Z</published><title>TiT</title>
			<summary>abs</summary><author><name>Kai Han</name></author></entry></feed>'
	}

	run arxiv.search_url "https://arxiv.org/abs/2103.00112v1"
	assert_success
	assert_jq '[.id,.url,.title,.author]'
	assert_output '["http://arxiv.org/abs/2103.00112v1","https://arxiv.org/abs/2103.00112v1","TiT","Kai Han"]'
}

@test "fetch.route: arxiv 的 abs/pdf 都归到 arxiv，别的站不认" {
	run fetch.route "https://arxiv.org/abs/2103.00112"
	assert_success
	[[ $output == "arxiv"$'\t'* ]]

	run fetch.route "https://arxiv.org/pdf/2103.00112.pdf"
	assert_success
	[[ $output == "arxiv"$'\t'* ]]

	run fetch.route "https://example.com/abs/1"
	assert_failure
}

@test "arxiv.search_url: URL 里没有论文号时报「不是合法的 arXiv 论文 URL」" {
	run arxiv.search_url "https://arxiv.org/abs/"
	assert_failure
	assert_output --partial "不是合法的 arXiv 论文 URL"
}
