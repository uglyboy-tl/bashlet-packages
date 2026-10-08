#!/usr/bin/env bash
# 维护者 / CI 工具：把各家活清单合并进 registry.toml 的 models 字段。
# default_model 与 default_ref_model 是人工决策，本脚本不改（但会检查它们还在不在活清单里）。
# models 默认**以活清单为准替换**：上游自己给的清单是权威，已下线的模型会被清掉，被清掉的
# 条目逐条打印出来让人看见。想保留旧条目（合并语义）就加 --merge。
# 缺凭证或该家没有模型列表 API 时，保留原有 models。
#
# 用法: scripts/update-registry.sh [-o registry.toml] [--merge]
#
# 依赖: bash、jq、curl（与 imagine 运行时一致）；凭证走环境变量或包目录 .env。

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$ROOT/registry.toml"
merge=false
while (($#)); do
	case "$1" in
		-o | --output)
			out="${2:?缺少输出路径}"
			shift
			;;
		--merge)
			merge=true
			;;
		-h | --help)
			echo "用法: update-registry.sh [-o registry.toml] [--merge]"
			exit 0
			;;
		*)
			echo "未知参数: $1" >&2
			exit 1
			;;
	esac
	shift
done

[[ -f $out ]] || {
	echo "找不到 $out" >&2
	exit 1
}
command -v jq > /dev/null || {
	echo "需要 jq" >&2
	exit 1
}

_toml_get() { # <file> <provider> <field>
	awk -v p="providers.$2" -v f="$3" '
		$0 == "[" p "]" { inb = 1; next }
		/^\[/ { inb = 0 }
		inb && $1 == f { sub(/^[^=]*=[ \t]*"?/, ""); sub(/"?[ \t]*$/, ""); print; exit }
	' "$1" 2> /dev/null
}

# 只保留合法模型 ID（防远端输出破坏 TOML）；非法行丢弃
_registry_sanitize() { printf '%s\n' "$1" | grep -E '^[A-Za-z0-9@/:.+_-]+$' || true; }

providers=$(grep -oE '^\[providers\.[^]]+\]' "$out" | sed -E 's/^\[providers\.(.*)\]$/\1/')
[[ -n $providers ]] || {
	echo "$out 里没有 [providers.*] 段" >&2
	exit 1
}

tmp=$(mktemp "${out}.XXXXXX")
trap 'rm -f "${tmp:-}"' EXIT
{
	printf '# imagine 模型目录\n'
	printf '#\n'
	printf '# 默认源（imagine 运行时按 TTL 后台刷新到本地缓存）：\n'
	printf '#   https://github.com/uglyboy-tl/bashlet-packages/raw/HEAD/packages/imagine/registry.toml\n'
	printf '# 换源优先级：IMAGINE_REGISTRY_URL 环境变量 > 上面这行的默认值。\n'
	printf '#\n'
	printf '# 字段（每个 [providers.<名字>] 下）：\n'
	printf '#   default_model      默认模型（--model 未指定时用）\n'
	printf '#   default_ref_model  带 --ref 时的默认模型（缺省回退 default_model）\n'
	printf '#   models             已知模型，空格分隔；缓存/离线时供 `imagine models` 用\n'
	printf '#\n'
	printf '# 手动编辑与 scripts/update-registry.sh（CI 定时）等价，均建议走 PR；\n'
	printf '# 能力声明（size/ref/seed/n 等接口机制）不在这里，它们在 lib/providers/*.sh。\n\n'
} > "$tmp"

for name in $providers; do
	def="$(_toml_get "$out" "$name" default_model)"
	ref="$(_toml_get "$out" "$name" default_ref_model)"
	old="$(_toml_get "$out" "$name" models)"

	live=""
	live=$(bash "$ROOT/imagine.sh" models "$name" --live 2> /dev/null) || live=""
	if [[ -n $live ]]; then
		raw=$(printf '%s\n' "$live" | grep -c . || true)
		live=$(_registry_sanitize "$live")
		kept=$(printf '%s\n' "$live" | grep -c . || true)
		((kept < raw)) && printf '  %-12s 丢弃 %d 个含非法字符的模型 ID\n' "$name" "$((raw - kept))" >&2
	fi
	# old 也过一遍，防手改引入非法值
	old_list=$(_registry_sanitize "${old// /$'\n'}")
	if [[ -n $live ]]; then
		# 默认模型是人工决策、脚本不改，但它若已不在活清单里就是「跑起来直接 404」级别的问题，
		# 而表里看不出来 —— 必须喊出来
		if [[ -n $def ]] && ! printf '%s\n' "$live" | grep -qxF "$def"; then
			printf '  %-12s 默认模型 %s 已不在活清单里！\n' "$name" "$def" >&2
		fi
		if [[ -n $ref ]] && ! printf '%s\n' "$live" | grep -qxF "$ref"; then
			printf '  %-12s 参考图默认模型 %s 已不在活清单里！\n' "$name" "$ref" >&2
		fi

		# 旧清单里活清单没有的条目：要么已下线，要么上游 API 不返回它 —— 两种都该让人看见
		removed=$(printf '%s\n' "$old_list" | awk 'NF && !seen[$0]++' | grep -vxF -f <(printf '%s\n' "$live") || true)
		if [[ -n $removed ]]; then
			printf '  %-12s 移除 %s 个已不在活清单里的模型：%s\n' \
				"$name" "$(printf '%s\n' "$removed" | grep -c .)" "$(printf '%s' "$removed" | tr '\n' ' ')" >&2
		fi

		if [[ $merge == true ]]; then
			models=$(printf '%s\n%s' "$live" "$removed" | awk 'NF && !seen[$0]++' | tr '\n' ' ')
		else
			models=$(printf '%s\n' "$live" | awk 'NF && !seen[$0]++' | tr '\n' ' ')
		fi
		models="${models% }"
		printf '  %-12s %s 个模型（%s）\n' "$name" "$(printf '%s' "$models" | wc -w)" \
			"$(if [[ $merge == true ]]; then echo 合并; else echo 替换; fi)" >&2
	else
		models="${old_list//$'\n'/ }"
		printf '  %-12s 跳过（无凭证或无列表 API）\n' "$name" >&2
	fi

	printf '[providers.%s]\n' "$name" >> "$tmp"
	[[ -n $def ]] && printf 'default_model = "%s"\n' "$def" >> "$tmp"
	[[ -n $ref ]] && printf 'default_ref_model = "%s"\n' "$ref" >> "$tmp"
	[[ -n $models ]] && printf 'models = "%s"\n' "${models//$'\n'/ }" >> "$tmp"
	printf '\n' >> "$tmp"
done

mv "$tmp" "$out"
trap - EXIT
echo "已更新 $out"
