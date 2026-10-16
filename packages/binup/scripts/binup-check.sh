#!/usr/bin/env bash
# 校验 GitHub repo 是否符合 binup 公共包目录的入仓标准
# 用法: binup-check.sh [--deep] owner/repo [...]
#   --deep 额外下载两侧归档、解压、列出会被拷的文件并在空目录试跑 --version
set -euo pipefail
# 资产名都是 ASCII；固定 locale 后 `[[ < ]]` 的 tie-break 和 binup 那边的码点序一致，
# [A-Za-z0-9] 这类范围也不会受 UTF-8 房间影响
export LC_ALL=C

DEEP=false
REPOS=()
for a in "$@"; do
	case $a in
		--deep) DEEP=true ;;
		*) REPOS+=("$a") ;;
	esac
done
((${#REPOS[@]})) || {
	echo "用法: ${0##*/} [--deep] owner/repo ..." >&2
	exit 1
}

ARCH_ARM='(aarch64|arm64)'
ARCH_X86='(x86_64|amd64|x64)'
# 挑「预期资产」用带边界的版本：ARCH_* 是拼进 pattern 的片段（binup 那边也不加边界），
# 直接拿来搜资产名时，`x64` 会命中 `jq-linux64` 这种把架构写进复合词的名字，选出一个拼不出模板的资产
SEL_ARM='(^|[^A-Za-z0-9])(aarch64|arm64)([^A-Za-z0-9]|$)'
SEL_X86='(^|[^A-Za-z0-9])(x86_64|amd64|x64)([^A-Za-z0-9]|$)'
LIBRE='(-gnueabihf|-musleabihf|-musleabi|-softfloat|-glibc|-gnu|-musl)?'
# binup 装不了的东西：包管理器格式、校验/签名文件、脚本
SKIP_RE='\.(deb|rpm|apk|snap|flatpak|whl|nupkg|jar|msi|exe|ps1|bat|sh|zsh|py|rb|pl|json|yml|yaml|txt|pem|dmg|appimage|sha[0-9]*(sum)?|sig|asc|minisig|zst)$'

norm() { # 资产名 -> 模板（arch/os/libc 占位 + 版本段换 *）
	# 占位替换按词边界做：无锚点的子串替换会把 `jq-linux64` 里的 `x64` 当架构、`linux64` 里的
	# `linux` 当系统，拼出 `jq-linu{arch}` 这种模板（binup 真跑时用的 pattern 是对的，是脚本自己认错）
	local n="$1"
	n=$(sed -E \
		-e 's/(^|[^A-Za-z0-9])aarch64([^A-Za-z0-9]|$)/\1{arch}\2/g' \
		-e 's/(^|[^A-Za-z0-9])arm64([^A-Za-z0-9]|$)/\1{arch}\2/g' \
		-e 's/(^|[^A-Za-z0-9])x86_64([^A-Za-z0-9]|$)/\1{arch}\2/g' \
		-e 's/(^|[^A-Za-z0-9])amd64([^A-Za-z0-9]|$)/\1{arch}\2/g' \
		-e 's/(^|[^A-Za-z0-9])x64([^A-Za-z0-9]|$)/\1{arch}\2/g' \
		-e 's/(^|[^A-Za-z0-9])[Ll]inux([^A-Za-z0-9]|$)/\1{os}\2/g' <<< "$n")
	n=$(sed -E 's/-(gnueabihf|musleabihf|musleabi|softfloat|glibc|gnu|musl)/{libc}/g' <<< "$n")
	n=$(sed -E 's/[0-9]+\.[0-9]+(\.[0-9]+)*/*/g' <<< "$n")
	printf '%s' "$n"
}

to_re() { # 模板 + arch 正则 -> ERE；不含扩展名后缀，binup 会另行追加「[.][^.]*<ext>$」
	# {os} 展成 [Ll]inux：上游常把 Linux 写进名字（glow_*_Linux_{arch}），binup 侧匹配不区分大小写
	local p="$1" arch="$2"
	p="${p//./\\.}"
	p="${p//\*/.*}"
	p="${p//\{arch\}/$arch}"
	p="${p//\{os\}/[Ll]inux}"
	p="${p//\{libc\}/$LIBRE}"
	printf '%s' "$p"
}

ext_of() {
	case $1 in
		*.tar.gz) printf 'tar.gz' ;;
		*.tgz) printf 'tgz' ;;
		*.tar.xz) printf 'tar.xz' ;;
		*.tar.bz2) printf 'tar.bz2' ;;
		*.tar) printf 'tar' ;;
		*.zip) printf 'zip' ;;
		*.gz) printf 'gz' ;;
		*.bz2) printf 'bz2' ;;
		*.xz) printf 'xz' ;;
		*) printf '' ;;
	esac
}

# binup 的选型规则：命中 pattern 的资产里，按 (名字长度, 名字) 排序取第一个。
# 可选的 $2（包名关键词）只用于「预期」选型：同仓库常发别的程序（czkawka 里还有 krokiet），
# 短名字会把它选中；名字里含包名的候选优先，一个都没有则退回纯长度规则。
# 复刻 binup 真实行为时（got_*）不传 $2，否则就不再是 binup 的选型了。
plan_pick() {
	local re="$1" want="${2:-}" best="" n
	local -a matches=() preferred=()
	for n in "${cand[@]}"; do
		[[ $n =~ $re ]] || continue
		matches+=("$n")
	done
	((${#matches[@]})) || return 0
	if [[ -n $want ]]; then
		for n in "${matches[@]}"; do
			[[ ${n,,} == *"$want"* ]] && preferred+=("$n")
		done
		((${#preferred[@]})) && matches=("${preferred[@]}")
	fi
	for n in "${matches[@]}"; do
		if [[ -z $best ]] || ((${#n} < ${#best})) || { ((${#n} == ${#best})) && [[ $n < $best ]]; }; then
			best="$n"
		fi
	done
	printf '%s' "$best"
}

deep_check() { # $1=repo $2=资产名 $3=架构标签 $4=推测包名 $5=binup 会用的下载名
	local repo="$1" name="$2" label="$3" pkgbin="${4:-}" fname="$5" d ex bins b t out rc
	d=$(mktemp -d)
	if ! gh release download --repo "$repo" --pattern "$name" --dir "$d" --clobber > /dev/null 2>&1; then
		deep_bad="下载失败，没能验成"
		echo "    [$label] deep: 下载失败"
		rm -rf "$d"
		return
	fi
	# binup 把资产存成「包名-版本[.ext]」，之后的重命名与挑选都基于这个名字，不是上游资产名
	[[ $name == "$fname" ]] || mv "$d/$name" "$d/$fname"
	ex="$d/x"
	mkdir -p "$ex"
	case $name in
		*.zip) unzip -q "$d/$fname" -d "$ex" ;;
		*.tar.gz | *.tgz) tar -zxf "$d/$fname" -C "$ex" ;;
		*.tar.xz) tar -xJf "$d/$fname" -C "$ex" ;;
		*.tar.bz2) tar -xjf "$d/$fname" -C "$ex" ;;
		*.gz) gzip -dc "$d/$fname" > "$ex/${fname%.gz}" ;;
		*.bz2) bzip2 -dc "$d/$fname" > "$ex/${fname%.bz2}" ;;
		*.xz) xz -dc "$d/$fname" > "$ex/${fname%.xz}" ;;
		*) cp "$d/$fname" "$ex/${fname%%.*}"; chmod +x "$ex/${fname%%.*}" ;;
	esac
	# 复刻 binup _install_archive 的挑选规则：可执行且文件名不含点
	# 顶层只有一个无扩展名文件时补执行位（binup lib/install.sh 同样先 chmod）
	mapfile -t top < <(find "$ex" -maxdepth 1 -type f ! -name "*.*" 2> /dev/null)
	[[ ${#top[@]} -eq 1 ]] && chmod +x "${top[0]}"
	mapfile -t bins < <(find "$ex" -type f -executable ! -name "*.*" 2> /dev/null)
	if ((${#bins[@]} == 0)) && [[ $fname == *.gz || $fname == *.bz2 || $fname == *.xz ]]; then
		[[ -f "$ex/${fname%.*}" ]] && bins=("$ex/${fname%.*}")
	fi
	if ((${#bins[@]} == 0)); then
		echo "    [$label] deep: 解压后没有可执行文件 ⚠️"
		deep_bad="解压后没有可执行文件"
	else
		echo "    [$label] deep: 会被拷的文件 ${#bins[@]} 个"
	fi
	# 多文件不是问题：binup 在多文件时各按原名装，只有同名 basename 才会互相覆盖。
	# 没命中推测包名时只提示一句，让人自己决定要不要配 binary_name（如 ast-grep 的 app-*.zip 里是
	# ast-grep + sg，推测包名是 app，看着像没命中，实际配 binary_name = "ast-grep" 就合法）。
	if ((${#bins[@]} > 1)); then
		local has_expect=0 dup bnames=()
		for b in "${bins[@]}"; do bnames+=("$(basename "$b")"); done
		for b in "${bnames[@]}"; do [[ $b == "$pkgbin" ]] && has_expect=1; done
		((has_expect)) || printf '           提示：%s\n' "${bnames[*]}（没命中推测包名 ${pkgbin:-（空）}，只想装一个就配 binary_name）"
		dup=$(printf '%s\n' "${bnames[@]}" | sort | uniq -d)
		[[ -n $dup ]] && deep_bad="多个二进制同名，装到同一目录会互相覆盖：$dup"
	fi
	local host_ok=1
	case $label in
		arm64) [[ $(uname -m) == aarch64 || $(uname -m) == arm64 ]] || host_ok=0 ;;
		amd64) [[ $(uname -m) == x86_64 || $(uname -m) == amd64 ]] || host_ok=0 ;;
	esac
	for b in "${bins[@]}"; do
		if ((!host_ok)); then
			printf '           %s：本机 %s 跑不了 %s 版，跳过试跑（只看文件数）\n' "$(basename "$b")" "$(uname -m)" "$label"
			continue
		fi
		if ((${#bins[@]} > 1)); then
			if [[ -n $pkgbin && $(basename "$b") == "$pkgbin" ]]; then
				printf '           %s ✓ 与推测包名同名（注意：上游把 GUI 与 CLI 分开发时，CLI 常在名字里带 -cli）\n' "$(basename "$b")"
			else
				printf '           %s -> 按原名装（不到同名就不会覆盖）\n' "$(basename "$b")"
			fi
			continue
		fi
		t=$(mktemp -d)
		cp "$b" "$t/"
		chmod +x "$t/$(basename "$b")"
		out=$(cd "$t" && timeout 10 "./$(basename "$b")" --version 2>&1) && rc=0 || rc=$?
		printf '           %s --version -> rc=%s  %s\n' "$(basename "$b")" "$rc" "$(head -1 <<< "$out")"
		# rc≥126 不是「没有 --version 子命令」而是启动就崩（127 缺命令、134 进程 abort）
		((rc < 126)) || deep_bad="--version 以 rc=$rc 退出，疑似缺系统依赖"
		rm -rf "$t"
	done
	rm -rf "$d"
}

for repo in "${REPOS[@]}"; do
	want="${repo##*/}"
	want="${want,,}" # 用于「预期」选型，把同仓库里的其他程序排除在外（见 plan_pick）
	if ! out=$(gh release view --repo "$repo" --json tagName,assets --jq '.tagName, (.assets[].name)' 2>&1); then
		printf '%s\n  结论: ❌ 拿不到 release（%s）\n\n' "$repo" "$(head -1 <<< "$out")"
		continue
	fi
	tag=$(head -1 <<< "$out")
	mapfile -t names < <(tail -n +2 <<< "$out" | sed '/^$/d')
	if ((${#names[@]} == 0)); then
		printf '%s  tag=%s\n  结论: ❌ release 无资产（多半只发源码）\n\n' "$repo" "$tag"
		continue
	fi

	cand=()      # 名字带 Linux 平台标记的归档 / 裸二进制
	unmarked=()  # 名字不带平台标记的归档（如多平台合一的 zip）
	for n in "${names[@]}"; do
		l="${n,,}"
		# 一律按小写匹配，免得 AppImage / .DMG 这类大写后缀漏网
		[[ $l =~ $SKIP_RE ]] && continue
		case $l in
			*darwin* | *macos* | *osx* | *mac-* | *mac_* | *mac.* | *apple* | *ios* | *android* | *windows* | *bsd* | *win-* | *win_* | *win.* | *win32* | *win64*) continue ;;
		esac
		if [[ $l == *linux* || $l == *musl* || $l == *gnu* || $l == *arm64* || $l == *aarch64* || $l == *x86_64* || $l == *amd64* ]]; then
			cand+=("$n")
		else
			unmarked+=("$n")
		fi
	done
	printf '%s  tag=%s  资产=%s 带标记候选=%s\n' "$repo" "$tag" "${#names[@]}" "${#cand[@]}"

	if ((${#cand[@]} == 0)); then
		if ((${#unmarked[@]})); then
			printf '  候选归档无平台标记: %s\n  结论: ⚠️ 需 --deep 解压确认（多平台合一的包会把同名二进制互相覆盖）\n' "${unmarked[*]}"
			if $DEEP; then deep_check "$repo" "${unmarked[0]}" unmarked "" "${unmarked[0]}"; fi
		else
			printf '  结论: ❌ Linux 侧没有可用的归档或裸二进制\n'
		fi
		echo ""
		continue
	fi

	a64=$(plan_pick "$SEL_ARM" "$want")
	x64=$(plan_pick "$SEL_X86" "$want")
	printf '  预期 arm64: %s\n  预期 amd64: %s\n' "${a64:-（无）}" "${x64:-（无）}"
	if [[ -z $a64 || -z $x64 ]]; then
		printf '  结论: ❌ 缺 %s\n\n' "$([[ -z $a64 ]] && echo arm64 || echo amd64)"
		continue
	fi

	pa=$(norm "$a64")
	px=$(norm "$x64")
	if [[ $pa != "$px" ]]; then
		printf '  arm64 模板: %s\n  amd64 模板: %s\n  结论: ⚠️ 两侧模板不一致，pattern 需人工写\n\n' "$pa" "$px"
		continue
	fi

	ext=$(ext_of "$pa")
	# registry 里的 file_pattern 不带扩展名——binup 的 github.asset.pattern 会把 ext 追加成
	# 「[.][^.]*<ext>$」（见 lib/update.sh）。这里按同一规则做正则，输出的 pattern 也要先剥掉扩展名，
	# 否则 pattern 与 file_extension 叠加后永远匹配不到资产。
	pat="$pa"
	suffix='$'
	if [[ -n $ext ]]; then
		pat="${pa%."$ext"}"
		suffix="[.][^.]*${ext}\$"
	fi
	re_a="$(to_re "$pat" "$ARCH_ARM")$suffix"
	re_x="$(to_re "$pat" "$ARCH_X86")$suffix"
	hit_a=$(printf '%s\n' "${cand[@]}" | grep -cE "$re_a" || true)
	hit_x=$(printf '%s\n' "${cand[@]}" | grep -cE "$re_x" || true)
	got_a=$(plan_pick "$re_a")
	got_x=$(plan_pick "$re_x")
	pkg=$(sed -E 's|.*/||; s|[^A-Za-z0-9_-]||g' <<< "$repo" | tr '[:upper:]' '[:lower:]')
	ver=$(grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' <<< "$tag" | head -1) || ver=""
	[[ -n $ver ]] || ver="${tag#v}"
	ver="${ver//[^A-Za-z0-9._-]/}" # 异常 tag 会把 $fname 带到临时目录外，清掉白名单之外的字符
	fname="$pkg-$ver${ext:+.$ext}"
	base="${pa%%[{\*]*}"
	base="${base%[-_]}"
	base="${base%[-_]v}"
	base="${base%[-_]}"
	base="${base%.}"
	# pattern 以占位符开头（如 {arch}-unknown-...-foo）时推不出名字，退回包名
	[[ ${#base} -ge 2 ]] || base="$pkg"
	if [[ -z $ext ]]; then
		bin_hint="binary_name = \"$base\"   # 裸二进制，不配会把架构后缀带进文件名"
	elif [[ $ext == gz || $ext == bz2 || $ext == xz ]]; then
		bin_hint="binary_name = \"$base\"   # 单文件压缩包必须配；名字以下面 --deep 的 --version 输出为准，不是资产名推出来的前缀"
	else
		bin_hint=""
	fi
	printf '  pattern: %s\n  ext: %s  命中: arm64=%s amd64=%s\n' "$pat" "${ext:-（无）}" "$hit_a" "$hit_x"
	if ((hit_a > 1 || hit_x > 1)); then
		printf '  arm64 命中清单: %s\n' "$(printf '%s\n' "${cand[@]}" | grep -E "$re_a" | paste -sd ' ' -)"
		printf '  amd64 命中清单: %s\n' "$(printf '%s\n' "${cand[@]}" | grep -E "$re_x" | paste -sd ' ' -)"
	fi
	printf '  [packages.%s]\n    repo = "%s"\n    file_pattern = "%s"\n' "$pkg" "$repo" "$pat"
	[[ -n $ext ]] && printf '    file_extension = "%s"\n' "$ext"
	[[ -n $bin_hint ]] && printf '    %s\n' "$bin_hint"
	if [[ $got_a == "$a64" && $got_x == "$x64" ]]; then
		$DEEP && printf '  候选层: ✅ pattern 实际会选中预期资产\n' || printf '  结论: ✅ 可收（pattern 实际会选中预期资产）\n'
	else
		printf '  ⚠️ pattern 实际会选中 arm64=%s amd64=%s（与预期不同，需收窄）\n' "$got_a" "$got_x"
		printf '  结论: ⚠️ 需人工\n'
	fi
	if $DEEP; then
		deep_bad=""
		# 归档结构两侧一致，只深挖本机架构侧，省一半下载；
		# 宿主不是 arm64/amd64 时 deep_check 压根没跑，不能报通过
		case $(uname -m) in
			aarch64 | arm64) deep_check "$repo" "$got_a" arm64 "$base" "$fname" ;;
			x86_64 | amd64) deep_check "$repo" "$got_x" amd64 "$base" "$fname" ;;
			*)
				printf '  结论: ⏭️ 本机架构 %s 不在 arm64/amd64 里，--deep 没跑\n\n' "$(uname -m)"
				continue
				;;
		esac
		if [[ -n $deep_bad ]]; then
			printf '  结论: ❌ --deep 不通过（%s）\n' "$deep_bad"
		else
			printf '  结论: ✅ --deep 通过\n'
		fi
	fi
	echo ""
done
