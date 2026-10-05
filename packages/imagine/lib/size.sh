#!/usr/bin/env bash
# shellcheck disable=SC2016
# 尺寸决策：用户只表达 --ar 宽高比或 -s 尺寸，本模块把它归一为「规范尺寸 + 宽高比」，
# 再按 provider 能力声明（size:any|star|fixed|aspect|none）产出适配器可用的 SIZE。
#
# 规范尺寸统一用 `WxH`（小写 x）；星号、宽高比、固定集合等差异只在这里和适配器之间转换。

import core/log

# 记录错误（与 common.fail 同语义，但 size 不依赖 common，避免拉入 ext/requests）
size._fail() {
	IMAGINE_ERROR="$1"
	[[ -n ${IMAGINE_ERROR_FILE:-} ]] && printf '%s' "$1" > "$IMAGINE_ERROR_FILE"
	log.error "$1"
}

# 规范宽高比 → 尺寸（x 分隔）；normal 用短边约 1024，2k 用长边 2048
declare -gA SIZE_ASPECT_TABLE=(
	["1:1"]="1024x1024"
	["16:9"]="1792x1024"
	["9:16"]="1024x1792"
	["4:3"]="1408x1056"
	["3:4"]="1056x1408"
	["2.35:1"]="2048x872"
)

declare -gA SIZE_ASPECT_TABLE_2K=(
	["1:1"]="2048x2048"
	["16:9"]="2048x1152"
	["9:16"]="1152x2048"
	["4:3"]="2048x1536"
	["3:4"]="1536x2048"
	["2.35:1"]="2048x872"
)

# 常见宽高比（含 Google 的合法集合），用于无法精确匹配时取最近值
size._known_aspects() { printf '%s\n' 1:1 16:9 9:16 4:3 3:4 3:2 2:3 4:5 5:4 21:9 2.35:1; }

# size.resolve <原始尺寸> <宽高比> [质量档位 normal|2k]  → 输出 "<WxH> <宽高比>"
size.resolve() {
	local raw_size="$1" ar="$2" quality="${3:-normal}" w h aspect
	if [[ -n $raw_size ]]; then
		raw_size="${raw_size//\*/x}"
		[[ $raw_size =~ ^([0-9]+)x([0-9]+)$ ]] || {
			size._fail "无效尺寸: $1（应为 WxH，如 1024x768）"
			return 1
		}
		w="${BASH_REMATCH[1]}"
		h="${BASH_REMATCH[2]}"
		((w > 0 && h > 0)) || {
			size._fail "无效尺寸: $1（宽高必须大于 0）"
			return 1
		}
		if [[ -n $ar ]]; then
			size.valid_aspect "$ar" || {
				size._fail "无效宽高比: $ar（应为 A:B 且非 0，如 16:9）"
				return 1
			}
			aspect="$ar"
		else
			aspect="$(size.aspect_of "$w" "$h")"
		fi
		printf '%s %s\n' "${w}x${h}" "$aspect"
		return 0
	fi
	if [[ -n $ar ]]; then
		local sz
		if [[ $quality == 2k ]]; then
			sz="${SIZE_ASPECT_TABLE_2K[$ar]:-}"
			[[ -n $sz ]] || sz=$(size.from_aspect "$ar" 2048) || return 1
		else
			sz="${SIZE_ASPECT_TABLE[$ar]:-}"
			[[ -n $sz ]] || sz=$(size.from_aspect "$ar" 1024) || return 1
		fi
		printf '%s %s\n' "$sz" "$ar"
		return 0
	fi
	local key="1:1"
	if [[ $quality == 2k ]]; then
		printf '%s 1:1\n' "${SIZE_ASPECT_TABLE_2K[$key]}"
	else
		printf '%s 1:1\n' "${SIZE_ASPECT_TABLE[$key]}"
	fi
}

# 由精确尺寸反推宽高比：先查表（两档），查不到取最接近的常见比例
size.aspect_of() {
	local w="$1" h="$2" key
	for key in "${!SIZE_ASPECT_TABLE[@]}"; do
		[[ ${SIZE_ASPECT_TABLE[$key]} == "${w}x${h}" ]] && {
			printf '%s' "$key"
			return 0
		}
	done
	for key in "${!SIZE_ASPECT_TABLE_2K[@]}"; do
		[[ ${SIZE_ASPECT_TABLE_2K[$key]} == "${w}x${h}" ]] && {
			printf '%s' "$key"
			return 0
		}
	done
	size.nearest_aspect "$w" "$h"
}

# size.nearest_aspect <W> <H>  → 常见宽高比里最接近的一个
size.nearest_aspect() {
	awk -v w="$1" -v h="$2" -v list="$(size._known_aspects | tr '\n' ' ')" 'BEGIN{
		target = w / h; best = ""; bd = 0;
		n = split(list, arr, " ");
		for (i = 1; i <= n; i++) {
			split(arr[i], p, ":");
			r = p[1] / p[2];
			d = (r > target) ? r - target : target - r;
			if (best == "" || d < bd) { best = arr[i]; bd = d }
		}
		print best
	}'
}

# A:B 形式（含小数）且两项非 0
size.valid_aspect() { [[ $1 =~ ^([0-9]+(\.[0-9]+)?):([0-9]+(\.[0-9]+)?)$ && ${BASH_REMATCH[1]} != 0 && ${BASH_REMATCH[3]} != 0 ]]; }

# size.from_aspect <A:B> [基准短边=1024]  → 生成尺寸（支持小数比，如 2.35:1）
size.from_aspect() {
	local ar="$1" base="${2:-1024}" a b
	size.valid_aspect "$ar" || {
		size._fail "无效宽高比: $ar（应为 A:B 且非 0，如 16:9）"
		return 1
	}
	a="${ar%%:*}"
	b="${ar##*:}"
	awk -v a="$a" -v b="$b" -v base="$base" 'BEGIN{
		if (a >= b) { h = base; w = int(base * a / b + 0.5) }
		else { w = base; h = int(base * b / a + 0.5) }
		printf "%dx%d\n", w, h
	}'
}

# size.nearest <WxH> <候选尺寸空格分隔>  → 宽高比最接近的候选
size.nearest() {
	local candidates="$2"
	awk -v s="$1" -v list="$candidates" 'BEGIN{
		split(s, a, "x"); target = a[1] / a[2];
		n = split(list, c, " "); best = ""; bd = 0;
		for (i = 1; i <= n; i++) {
			split(c[i], p, "x");
			r = p[1] / p[2];
			d = (r > target) ? r - target : target - r;
			if (best == "" || d < bd) { best = c[i]; bd = d }
		}
		print best
	}'
}

# size.cap <能力> <规范尺寸> <宽高比> <固定集合>  → 适配器直接可用的尺寸（none 时输出空串）
size.cap() {
	local cap="$1" size="$2" aspect="$3" fixed_sizes="$4"
	case "$cap" in
		none) printf '' ;;
		star) printf '%s' "${size//x/*}" ;;
		fixed)
			[[ -n $fixed_sizes ]] || {
				size._fail "provider 声明 size:fixed 但 PROVIDER_SIZES 为空"
				return 1
			}
			size.nearest "$size" "$fixed_sizes"
			;;
		*) printf '%s' "$size" ;;
	esac
}

# 把尺寸放大到至少 min 像素（保持宽高比，整数倍缩放）
size.min_pixels() {
	local w="${1%%x*}" h="${1##*x}" min="$2" s=1
	while ((w * s * h * s < min)); do ((s++)); done
	printf '%sx%s' "$((w * s))" "$((h * s))"
}
