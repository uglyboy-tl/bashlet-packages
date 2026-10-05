#!/usr/bin/env bash
# tools/common.sh - tools/* 共享的路径常量与框架链接保障
#
# 这里维护两类链接，都是指向 bashlet 的符号链接，靠 ensure_links 幂等补齐：
#   1. 包内 lib/{core,std,ext} 与 test/{bats,test_helper} —— 包自己 import 用
#   2. 根级 lib/{core,std,ext} —— 框架工具链的接口，见 _ensure_root 的注释
# 包内链接不入库（根 .gitignore 的 packages/*/…）；根级三个入库，保证直接调用
# bashlet/tools/build 也能工作。
#
# tools 下每个入口都应在动手前调用 ensure_links，克隆后第一次执行哪个工具都能自动接好。

TOOLS_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
ROOT="$(dirname "$TOOLS_DIR")"
BASHLET="$ROOT/bashlet"
PACKAGES="$ROOT/packages"

# _link <target> <path>：链接缺失、断链或指向别处时重建；已指向 target 则跳过
_link() {
	local target="$1" path="$2" resolved
	if [[ -L $path ]]; then
		resolved="$(readlink -f "$path" || true)"
		[[ $resolved == "$(readlink -f "$target")" ]] && return 0
		rm -f "$path"
	elif [[ -e $path ]]; then
		return 0 # 真实文件/目录，别覆盖别人的东西
	fi
	mkdir -p "$(dirname "$path")"
	ln -rs "$target" "$path"
	printf '  %s -> %s\n' "${path#"$ROOT"/}" "${target#"$ROOT"/}"
}

# 根级 lib/ 不是包内链接的中转（包内直连 bashlet），而是框架工具链的接口：
# bashlet/tools/build 把 PROJECT_ROOT 推导为「消费仓库根」，再 source
# "$PROJECT_ROOT/lib/std/import.sh"，而 import.sh 用 ${BASH_SOURCE[0]%/*}/.. 推出
# _LIB_DIR，于是所有 import 都在 <仓库根>/lib 下解析。删掉这根链接，
# tools/build 会直接报 “lib/std/import.sh: 没有那个文件或目录”。
_ensure_root() {
	_link "$BASHLET/lib/core" "$ROOT/lib/core"
	_link "$BASHLET/lib/std" "$ROOT/lib/std"
	_link "$BASHLET/lib/ext" "$ROOT/lib/ext"
}

_ensure_package() {
	local pkg="$1"
	[[ -d $pkg ]] || {
		echo "没有这个包: ${pkg#"$PACKAGES"/}" >&2
		return 1
	}
	# 逐项链接而非整目录，留出包私有模块（lib/<模块名>.sh、test/test_helper/<helper>）的空间
	_link "$BASHLET/lib/core" "$pkg/lib/core"
	_link "$BASHLET/lib/std" "$pkg/lib/std"
	_link "$BASHLET/lib/ext" "$pkg/lib/ext"
	_link "$BASHLET/test/test_helper" "$pkg/test/test_helper"
	_link "$BASHLET/test/bats" "$pkg/test/bats"
}

# ensure_links [包名...]：无参数 = 全部包；带参数 = 指定包
ensure_links() {
	[[ -d $BASHLET ]] || {
		echo "缺少 bashlet 子模块，先跑: git submodule update --init" >&2
		return 1
	}
	_ensure_root
	local arg
	if (($#)); then
		for arg in "$@"; do _ensure_package "$PACKAGES/$arg" || return 1; done
	else
		for arg in "$PACKAGES"/*/; do _ensure_package "${arg%/}" || return 1; done
	fi
}
