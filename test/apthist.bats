#!/usr/bin/env bats

load 'test_helper/common-setup'

setup() {
	_common_setup
	cd "$PROJECT_ROOT"
	LOG="$BATS_TEST_TMPDIR/apt.log"
	local d1 d2 d3 d4
	d1=$(date -d "-20 days" +%F)
	d2=$(date -d "-10 days" +%F)
	d3=$(date -d "-5 days" +%F)
	d4=$(date -d "-3 days" +%F)
	cat > "$LOG" << EOF
Start-Date: $d1  10:00:00
Commandline: apt install foo bar
Install: foo:amd64 (1.0), bar (2.0, automatic)
End-Date: $d1  10:00:05

Start-Date: $d2  11:00:00
Commandline: apt remove bar
Remove: bar:amd64 (2.0)
End-Date: $d2  11:00:02

Start-Date: $d3  12:00:00
Commandline: apt install baz
Install: baz (3.0)
End-Date: $d3  12:00:03

Start-Date: $d4  13:00:00
Commandline: apt install qux
Install: qux (1.0, automatic)
End-Date: $d4  13:00:01
EOF
}

_apt() { run bash src/apthist.sh -l "$LOG" "$@"; }

@test "apthist: 默认只列出手动安装且仍在装的包" {
	_apt -d 3650
	assert_success
	assert_output --partial "foo"
	assert_output --partial "baz"
	refute_output --partial "bar"
	refute_output --partial "qux"
}

@test "apthist: -a 显示自动安装的包" {
	_apt -d 3650 -a
	assert_output --partial "qux"
}

@test "apthist: -r 列出手动卸载的包" {
	_apt -d 3650 -r
	assert_output --partial "bar"
	refute_output --partial "baz"
}

@test "apthist: 输出按日期升序" {
	_apt -d 3650
	local a b
	a=$(printf '%s\n' "$output" | grep -n 'foo' | cut -d: -f1)
	b=$(printf '%s\n' "$output" | grep -n 'baz' | cut -d: -f1)
	[ "$a" -lt "$b" ]
}

@test "apthist: 时间范围外无结果" {
	_apt -d 1
	assert_success
	assert_output --partial "无结果"
}

@test "apthist: 非法天数回退默认而非报错" {
	_apt -d abc
	assert_success
	assert_output --partial "baz"
	refute_output --partial "foo"
}
