#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "source.list: 列出全部已注册的源，且每源有说明" {
	run source.list
	assert_success
	local src
	local -a srcs=()
	mapfile -t srcs <<< "$output"
	[ "${#srcs[@]}" -ge 13 ]
	for src in "${srcs[@]}"; do
		run source.desc "$src"
		assert_success
		[ -n "$output" ]
	done
}

@test "source.cap: 读出 tier，未声明的键返回非 0" {
	run source.cap hn tier
	assert_output "core"
	run source.cap arxiv tier
	assert_output "topic"
	run source.cap bilibili tier
	assert_output "niche"

	run source.cap hn period
	assert_output "yes"
	run source.cap hn nosuchkey
	assert_failure
}

@test "source.cap: tier 只有 core|topic|niche 三种值" {
	run bash -c '
		source dig.sh
		mapfile -t srcs < <(source.list)
		for s in "${srcs[@]}"; do
			t="$(source.cap "$s" tier)"
			[[ $t == core || $t == topic || $t == niche ]] || echo "$s=$t"
		done
	'
	assert_success
	[ -z "$output" ]
}

@test "source.register: 缺源名时报错" {
	run source.register ""
	assert_failure
}
