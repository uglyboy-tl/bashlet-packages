#!/usr/bin/env bats

# lib/sources/index.sh（源装载表）与注册表的一致性，以及「文档与注册表不漂移」。
# 各源自己的 mapper 测试在 test/<源>.bats。

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "sources: 每个已注册的源都有 lib/sources/<源>.sh，且装载表里有对应的一行 import" {
	local s
	for s in $(source.list); do
		[ -f "$PROJECT_ROOT/lib/sources/$s.sh" ] || {
			echo "缺 lib/sources/$s.sh"
			return 1
		}
		grep -q "^import sources/$s$" "$PROJECT_ROOT/lib/sources/index.sh" || {
			echo "lib/sources/index.sh 缺 import sources/$s"
			return 1
		}
	done
}

@test "sources: 装载表没有重复项，且每源都有说明与 tier" {
	local -a srcs=()
	mapfile -t srcs < <(source.list)
	[ "${#srcs[@]}" -ge 13 ]
	[ "$(printf '%s\n' "${srcs[@]}" | sort -u | wc -l)" -eq "${#srcs[@]}" ]

	local s
	for s in "${srcs[@]}"; do
		local desc tier
		desc="$(source.desc "$s")"
		[ -n "$desc" ] || {
			echo "$s 缺说明"
			return 1
		}
		tier="$(source.cap "$s" tier || true)"
		case $tier in
			core | topic | niche) ;;
			*)
				echo "$s 的 tier 非法：$tier"
				return 1
				;;
		esac
	done
}

@test "sources: docs/sources.md 的表格列出了每一个源" {
	local s
	for s in $(source.list); do
		grep -q "^| \`$s\` " "$PROJECT_ROOT/docs/sources.md" || {
			echo "docs/sources.md 表格缺 $s"
			return 1
		}
	done
}

# 这条是为了防止「注册表说 proxy:yes、文档说不用代理」这类漂移（hf 就出过一次）
@test "sources: README 与 docs/sources.md 的代理标记和 proxy: 一致" {
	local -a want=() got=()
	local s
	for s in $(source.list); do
		[[ "$(source.cap "$s" proxy || true)" == yes ]] && want+=("$s")
	done
	[ "${#want[@]}" -gt 0 ] || {
		echo "没有任何源标记 proxy:yes，断言失效"
		return 1
	}

	local line list
	line="$(grep -m1 '必须走代理' "$PROJECT_ROOT/README.md")"
	[ -n "$line" ] || {
		echo "README 里找不到代理清单那一句"
		return 1
	}
	list="${line%%必须走代理*}"
	local tok
	for tok in ${list//\// }; do
		tok="${tok// /}"
		[[ -n $tok ]] && got+=("$tok")
	done
	[ "$(printf '%s\n' "${got[@]}" | sort | tr '\n' ' ')" = "$(printf '%s\n' "${want[@]}" | sort | tr '\n' ' ')" ] || {
		echo "README 代理清单=[${got[*]}] 与 proxy:yes=[${want[*]}] 不一致"
		return 1
	}

	local row
	for s in $(source.list); do
		row="$(grep -m1 "^| \`$s\` " "$PROJECT_ROOT/docs/sources.md")"
		if [[ "$(source.cap "$s" proxy || true)" == yes ]]; then
			[[ $row == *"| 是 |"* ]] || {
				echo "docs/sources.md 表格里 $s 的「需代理」列应为「是」"
				return 1
			}
		else
			[[ $row == *"| 否 |"* ]] || {
				echo "docs/sources.md 表格里 $s 的「需代理」列应为「否」"
				return 1
			}
		fi
	done
}
