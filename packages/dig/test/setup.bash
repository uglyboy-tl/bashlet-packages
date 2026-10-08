#!/usr/bin/env bash
# dig 测试共用环境：各 bats 先 load 'test_helper/common-setup'，再 load 'setup.bash'

# 入口必须走 _fast_load（见 test_helper/common-setup.bash 里的说明）：
# bats 开着 functrace，DEBUG trap 会传播进被 source 的每个文件，加载 ~20 个模块时
# 每条命令都要过一遍 trap —— 实测 2.9s vs 6ms。
_dig_setup() {
	_common_setup
	cd "$PROJECT_ROOT"
	# 隔离结果缓存：否则用例会读到开发机 ~/.cache/dig 里的旧结果，或写脏它
	export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
	_fast_load source "$PROJECT_ROOT/dig.sh"
	# settings.load 里那几个变量校验同样吃 trap 开销
	_fast_load dig.settings.load
	# 必须在加载之后清：dig.sh 顶部会 source 包内 .env，开发机上那里写着 DIG_PROXY；
	# 不清掉的话「连不上」会被代理拦成 HTTP 503，探活的「网络不通」分支就测不到了
	unset DIG_PROXY
}

# 对上一次 run 的 $output 跑一段 jq 过滤，结果写回 $output。
# 断言字段而不是整行文本时用（避免每处都在单引号里嵌一层 jq 双引号）：
#   run youtube.map < f.json
#   assert_jq '[.id,.title]'
#   assert_output '["abc","T"]'
assert_jq() {
	run bash -c 'jq -c "$1"' _ "$1" <<< "$output"
}
