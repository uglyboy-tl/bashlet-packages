#!/usr/bin/env bash
# apthist 测试共用环境：各 bats 文件先 load 'test_helper/common-setup'，再 load 'setup.bash'

_apthist_setup() {
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
