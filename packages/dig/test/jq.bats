#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

# 提炼出的 jq program（顶层 heredoc 常量）至少要能编译。
# jq 退出码：0=正常、3=编译错（语法错 / 未定义函数 / 未定义 $var）、5=运行期类型错。
# 只拦 3 —— 以 null 为输入必然有运行期错，那是正常的。
# 这条替代不了真实查询（只测编译，字段路径打错之类运行期问题测不出来），
# 但改完 program 后 1 秒内就能发现语法写坏。
@test "jq: 所有提炼的 program 都能编译（只测编译）" {
	# _SCHEMA_JQ_LIB 也会被下面的 compgen 收进来，初值只补它之外的那份
	local libs="$_SCHEMA_JQ_REQUIRED" lv
	while IFS= read -r lv; do
		libs+="${!lv}"
	done < <(compgen -A variable | grep -E '^_[A-Z0-9_]+_JQ_LIB$')

	# 先取清单再循环：直接 `while read` 消费进程替换时，grep 失败或路径写错会让循环一次都不跑，
	# failures 保持 0 就成了静默通过 —— 测试最坏的失败模式。
	local -a names
	mapfile -t names < <(grep -rhoP "read -r -d \x27\x27 \K_[A-Z0-9_]+(?= << \x27JQ\x27)" "$PROJECT_ROOT/lib")
	((${#names[@]})) || {
		echo "没扫到任何 JQ 常量（grep -P 不可用？lib 路径错了？）"
		return 1
	}

	local name prog out rc failures=0 v
	local -a args
	for name in "${names[@]}"; do
		# ${!name} 对不存在的变量返回空串（不是报错），常量名打错或模块没被加载时会静默编译通过
		declare -p "$name" > /dev/null 2>&1 || {
			echo "  未加载的常量: $name"
			failures=$((failures + 1))
			continue
		}
		prog="${!name}"
		# 纯 def 的库常量没有 top-level program，补一个 "." 才能编译。
		# program 不能补：常量末尾直接接 "." 会让 jq 报 "unexpected end of file, expecting FORMAT"。
		case $name in
			*_JQ_LIB | _SCHEMA_JQ_NORM_URL | _SCHEMA_JQ_REQUIRED) prog="$prog"$'\n.' ;;
		esac
		# jq 编译期要求 $var 已定义；名字从 program 里抓（含数字，如 $ct0），值给什么都行（类型错是 rc=5，放行）
		args=()
		for v in $(printf '%s' "$prog" | grep -oP '\$[a-z_][a-z0-9_]*' | sort -u); do
			args+=(--arg "${v#\$}" "x")
		done
		if out="$(jq -n ${args[@]+"${args[@]}"} "$libs$prog" 2>&1)"; then
			rc=0
		else
			rc=$?
		fi
		if ((rc != 0 && rc != 5)); then
			echo "  $name (rc=$rc): ${out%%$'\n'*}"
			failures=$((failures + 1))
		fi
	done
	[ "$failures" -eq 0 ]
}
