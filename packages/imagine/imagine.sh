#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016
# build:keep-env

set -euo pipefail
SCRIPT_NAME="Imagine"
VERSION="0.3.0"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 错误信息文件：命令替换在子 shell 里跑，变量回传不了，用文件跨子 shell 传递
IMAGINE_ERROR_FILE="${TMPDIR:-/tmp}/.imagine-err.$$"
rm -f "$IMAGINE_ERROR_FILE"
source "$PROJECT_ROOT/lib/std/import.sh"

.env

import std/console.layout
import std/string
import core/log
import core/args

import common
import size
import provider
import registry
import compose
import providers/index

# ── generate（默认命令） ──

cmd_generate() {
	args.init "用同一套 CLI 调用所有文生图 / 图生图模型"
	args.add_options "prompt" "p" "提示词" "STRING"
	args.add_options "promptfile" "P" "从文件读取提示词（与 -p 合并）" "FILE"
	args.add_options "output" "o" "输出文件或目录" "PATH"
	args.add_options "provider" "" "服务提供商（缺省自动选择）" "NAME"
	args.add_options "model" "m" "模型 ID" "ID"
	args.add_options "ar" "" "宽高比，如 16:9" "RATIO"
	args.add_options "size" "s" "显式尺寸，如 1024x768" "WxH"
	args.add_options "quality" "q" "分辨率档位 normal|2k（默认 normal）" "PRESET"
	args.add_options "count" "n" "生成数量" "NUMBER"
	args.add_options "seed" "" "随机种子" "NUMBER"
	args.add_options "negative-prompt" "" "负面提示词" "STRING"
	args.add_options "ref" "" "参考图路径，多个用逗号分隔" "PATH"
	args.add_options "style" "" "风格预设（部分 provider）" "STRING"
	args.add_options "extra" "" "透传参数（支持 a.b 路径），如 parameters.prompt_extend=false" "K=V,..."
	args.add_options "json" "" "以 JSON 输出结果到 stdout（日志仍在 stderr）"
	args.add_options "EXAMPLE" '-p "a red apple"' "自动挑可用 provider"
	args.add_options "EXAMPLE" '-p "..." --ar 16:9 -o out.png' "按宽高比，脚本负责映射"
	args.add_options "EXAMPLE" '-p "..." --ref ref.png' "图生图"
	args.add_options "EXAMPLE" "--provider dashscope --extra parameters.prompt_extend=false" "透传 provider 特有参数"
	args.process "$@"

	IMAGINE_JSON=""
	IMAGINE_ERROR=""
	args.has "--json" && IMAGINE_JSON=true

	local prompt promptfile ar raw_size extra quality
	prompt="$(args.get "-p" "--prompt")" || prompt=""
	promptfile="$(args.get "-P" "--promptfile")" || promptfile=""
	OUTPUT="$(args.get "-o" "--output")" || OUTPUT=""
	PROVIDER="$(args.get "--provider")" || PROVIDER=""
	MODEL="$(args.get "-m" "--model")" || MODEL=""
	ar="$(args.get "--ar")" || ar=""
	raw_size="$(args.get "-s" "--size")" || raw_size=""
	quality="$(args.get "-q" "--quality")" || quality=""
	QUALITY_EXPLICIT=false
	if [[ -n $quality ]]; then
		[[ $quality == normal || $quality == 2k ]] || {
			common.fail "--quality 只支持 normal|2k，收到: $quality"
			return 1
		}
		QUALITY_EXPLICIT=true
	fi
	QUALITY="${quality:-normal}"
	[[ $QUALITY == 2k ]] && IMAGE_SIZE=2K || IMAGE_SIZE=1K
	COUNT="$(args.get "-n" "--count")" || COUNT="1"
	string.natural.check "$COUNT" || COUNT=1
	SEED="$(args.get "--seed")" || SEED=""
	NEGATIVE="$(args.get "--negative-prompt")" || NEGATIVE=""
	STYLE="$(args.get "--style")" || STYLE=""
	REF="$(args.get "--ref")" || REF=""
	extra="$(args.get "--extra")" || extra=""

	if [[ -n $promptfile ]]; then
		[[ -f $promptfile ]] || {
			common.fail "Prompt file not found: $promptfile"
			return 1
		}
		local file_content
		file_content=$(< "$promptfile")
		prompt="${prompt:+${prompt} }${file_content}"
	fi
	PROMPT="$prompt"
	[[ -n $PROMPT ]] || {
		common.fail "缺少提示词，用 -p/--prompt 或 -P/--promptfile 提供"
		return 1
	}
	if [[ -n $SEED ]]; then
		string.int.check "$SEED" || {
			common.fail "--seed 必须是整数: $SEED"
			return 1
		}
	fi

	EXTRA_JSON=""
	if [[ -n $extra ]]; then
		EXTRA_JSON="$(common.extra_json "$extra")" || return 1
	fi

	# provider 选择：显式指定则校验；否则按「免费优先 + 有凭证 + 能力匹配」自动挑
	if [[ -n $PROVIDER ]]; then
		provider.exists "$PROVIDER" || {
			common.fail "未知 provider: $PROVIDER"
			log.error "可用: $(provider.list | tr '\n' ' ')"
			return 1
		}
	else
		PROVIDER="$(provider.auto_select "$REF")" || {
			common.fail "没有可用的 provider（检查 API key，或用 --provider 指定）；imagine providers --offline 看每家缺什么"
			return 1
		}
	fi
	provider.creds_ok "$PROVIDER" || {
		common.fail "$PROVIDER 缺少凭证：$(provider.creds_missing "$PROVIDER")"
		return 1
	}
	registry.ensure || true

	# 模型解析：--model > <PROVIDER>_IMAGE_MODEL > 目录 > 适配器兜底
	MODEL="$(provider.resolve_model "$PROVIDER" "$REF" "$MODEL")"

	# 尺寸归一：用户只给宽高比或尺寸，脚本负责映射
	local resolved
	resolved="$(size.resolve "$raw_size" "$ar" "$QUALITY")" || return 1
	SIZE="${resolved%% *}"
	ASPECT="${resolved##* }"
	SIZE_EXPLICIT=false
	[[ -n $raw_size || -n $ar ]] && SIZE_EXPLICIT=true
	SIZE_REQUESTED="$SIZE"

	compose.apply_caps "$PROVIDER" || return 1

	OUTPUT="$(common.output_path "$OUTPUT" "$PROVIDER")"
	compose.generate "$PROVIDER" "$OUTPUT"
}

# ── providers：可用状态 ──
#
# 分两段：能用的给详情（默认模型 / 免费），不能用的只给一行原因 ——
# 一视同仁地铺开会让「这家为什么用不了」淹没在九行表格里。
#
# 探活复用 provider.auth / provider.base_url，与真实生成走同一条路（含 XGET）：
# 探活通过不保证生成成功，但探活不通过就一定用不了。只想看配置不发请求就加 --offline。
#
# XGET 只在**不通**时才被提起（墙外三家直连本来就不通，提示去配 XGET_BASE_URL）；
# 通了就不必关心走的是代理还是直连。

# 按显示宽度补空格。不能用 %-12s：那数的是字符数，而中文占 2 列，中英混排必然错位。
_providers_pad() {
	local w="$1" s="$2" pad
	pad=$((w - $(console.display_width "$s")))
	((pad < 0)) && pad=0
	printf '%s%*s' "$s" "$pad" ""
}

_providers_caps() {
	printf '  %s%s%s%s\n' "$(_providers_pad 14 "PROVIDER")" "$(_providers_pad 10 "SIZE")" \
		"$(_providers_pad 8 "REF")" "N"
	printf '  %s\n' "$(console.repeat "-" 33)"
	local name cap_size cap_ref maxn
	while IFS= read -r name; do
		[[ -z $name ]] && continue
		cap_size="$(provider.cap "$name" size)" || cap_size="-"
		cap_ref="$(provider.cap "$name" ref)" || cap_ref="-"
		maxn="$(provider.cap "$name" n)" || maxn="-"
		printf '  %s%s%s%s\n' \
			"$(_providers_pad 14 "$name")" "$(_providers_pad 10 "$cap_size")" \
			"$(_providers_pad 8 "$cap_ref")" "n=$maxn"
	done < <(provider.list)
	printf '  %s\n' "SIZE: any=原样直传 / star=星号分隔 / fixed=就近映射 / aspect=宽高比 / none=忽略"
	printf '  %s\n' "REF:  none=不支持 / one=单张 / multi=多张；N=单次最大张数"
}

cmd_providers() {
	args.init "列出各 provider 的可用状态（探活验证 key 真的能用）"
	args.add_options "offline" "" "只读配置，不发探活请求"
	args.add_options "caps" "" "只看能力明细（尺寸 / 参考图 / 张数），不跑探活"
	args.process "$@"

	local offline=false caps=false
	args.has "--offline" && offline=true
	args.has "--caps" && caps=true

	# --caps 是另一个视图，不是附加在可用性表后面：能力来自适配器声明，与凭证/探活/目录都无关，
	# 所以直接给表、不再叠一遍 providers，也省掉一次目录刷新
	if [[ $caps == true ]]; then
		console.layout.section "能力明细"
		_providers_caps
		console.layout.footer "可用状态与凭证：imagine providers（--offline 跳过探活）"
		return 0
	fi

	[[ $offline == true ]] || registry.ensure || true

	# 先按凭证填一遍，再让探活结果覆盖：这样两种模式下「缺凭证」走同一条路，
	# 不会在探活模式下因为「没被探到」而原因成空。
	local -A status=() detail=() name st text
	while IFS= read -r name; do
		if provider.creds_ok "$name"; then
			status[$name]=unknown
			detail[$name]=-
		else
			status[$name]=missing
			detail[$name]="$(provider.creds_missing "$name")"
		fi
	done < <(provider.list)

	if [[ $offline == true ]]; then
		# 离线：凭证齐全的就算「可用」，但底部会说明没发过请求，不假装验证过
		for name in "${!status[@]}"; do
			[[ ${status[$name]} == unknown ]] && status[$name]=ok
		done
	else
		while IFS=$'\t' read -r name st text; do
			[[ -n $name ]] || continue
			status[$name]="$st"
			detail[$name]="$text"
		done < <(provider.probe_all)
	fi

	local -a usable=() blocked=()
	while IFS= read -r name; do
		if [[ ${status[$name]:-} == ok ]]; then usable+=("$name"); else blocked+=("$name"); fi
	done < <(provider.list)

	console.layout.section "Providers"

	printf '\n可用\n'
	if ((${#usable[@]} == 0)); then
		printf '  （没有可用的 provider）\n'
	else
		printf '  %s%s%s%s\n' "$(_providers_pad 14 "PROVIDER")" "$(_providers_pad 24 "LABEL")" \
			"$(_providers_pad 6 "FREE")" "DEFAULT MODEL"
		printf '  %s\n' "$(console.repeat "-" 57)"
		local free
		for name in "${usable[@]}"; do
			free="付费"
			[[ ${PROV_FREE[$name]} == true ]] && free="免费"
			printf '  %s%s%s%s\n' \
				"$(_providers_pad 14 "$name")" \
				"$(_providers_pad 24 "$(provider.label "$name")")" \
				"$(_providers_pad 6 "$free")" \
				"$(provider.default_model "$name")"
		done
	fi

	printf '\n不可用\n'
	if ((${#blocked[@]} == 0)); then
		printf '  （无）\n'
	else
		for name in "${blocked[@]}"; do
			printf '  %s%s\n' "$(_providers_pad 14 "$name")" \
				"$(provider.probe_reason "${status[$name]}" "${detail[$name]}")"
		done
	fi

	local auto
	if [[ $offline == true ]]; then
		console.layout.footer "离线模式：没有发探活请求；--caps 看能力明细"
	elif auto="$(provider.auto_select)"; then
		console.layout.footer "未指定 --provider 时会选 $auto（按凭证与能力挑，不预探活）；--caps 看能力明细"
	else
		console.layout.footer "没有可用的 provider：照 env.example 配一家，再跑一次看缺什么"
	fi

	return 0
}

# ── update：从远端刷新模型目录 ──

cmd_update() {
	args.init "从远端刷新模型目录到本地缓存"
	args.process "$@"
	[[ -n ${IMAGINE_REGISTRY_OFF:-} ]] && {
		log.warn "IMAGINE_REGISTRY_OFF 已设置，跳过刷新"
		return 1
	}
	registry.seed_if_missing || return 1
	local old new
	old="$(registry.dump || true)"
	registry.lock || {
		log.error "已有刷新正在进行，请稍后再试"
		return 1
	}
	if ! registry.try_fetch; then
		registry.unlock
		log.error "刷新失败（保留本地数据）: $IMAGINE_REGISTRY_URL"
		return 1
	fi
	registry.unlock
	registry.reload
	new="$(registry.dump || true)"
	printf '  %s\n' "本地缓存: $(registry.cache)"
	registry.print_diff "$old" "$new"
}

# ── models：默认模型 / 全部模型 ──

cmd_models() {
	args.init "查看提供商与可用模型"
	args.add_options "arg" "provider" "指定 provider 时列出其全部模型"
	args.add_options "live" "" "强制走活的模型列表 API（维护者/CI 用，仅输出模型行）"
	args.process "$@"

	local -n pos="$(args.args)"
	local name live=false
	args.has "--live" && live=true
	[[ $live == true ]] || registry.ensure || true
	if ((${#pos[@]} == 0)); then
		printf '  %-12s %-38s %s\n' "PROVIDER" "DEFAULT MODEL" "VIA"
		printf '  %s\n' "------------------------------------------------------------------------------"
		while IFS= read -r name; do
			[[ -z $name ]] && continue
			provider.creds_ok "$name" || continue
			printf '  %-12s %-38s %s\n' "$name" "$(provider.default_model "$name")" "$(provider.via "$name")"
		done < <(provider.list)
		echo ""
		echo "  Use 'models <provider>' to see all available models."
		return 0
	fi

	name="${pos[0]}"
	((${#pos[@]} > 1)) && {
		log.error "models 只接受一个 provider 参数"
		return 1
	}
	provider.exists "$name" || {
		log.error "未知 provider: $name"
		return 1
	}
	# 凭证只在 --live 时才必要：不带它时清单来自 registry / 适配器的内置兜底，没 key 也看得见
	if [[ $live == true ]]; then
		provider.creds_ok "$name" || {
			log.error "$name 缺少凭证：$(provider.creds_missing "$name")（--live 要打它的列表 API）"
			return 1
		}
		compose.init "$name" || return 1
		provider.models_live "$name"
		return
	fi
	printf '  %s (default: %s)\n' "$name" "$(provider.default_model "$name")"
	printf '  %s\n' "------------------------------------------"
	# 清单来自 registry / 适配器内置兜底，不需要认证；只有落到活 API 兜底那一步才用到凭证，
	# 所以有凭证才初始化请求层，没凭证也允许看清单。
	if provider.creds_ok "$name"; then
		compose.init "$name" || return 1
	fi
	local missing
	missing="$(provider.creds_missing "$name")"
	provider.models "$name" || {
		log.error "$name 拿不到模型清单${missing:+（缺 $missing）}"
		return 1
	}
}

main() {
	args.init "命令行文生图 / 图生图工具 — 一套参数调用多家 provider"
	args.add_options "version" "v" "显示版本信息"
	args.add_subcommand "models" "查看提供商与可用模型" "cmd_models"
	args.add_subcommand "providers" "列出各 provider 的能力与凭证状态" "cmd_providers"
	args.add_subcommand "update" "从远端刷新模型目录" "cmd_update"

	local cmd="${1:-}" arg
	if [[ -v _ARGS_SUBCOMMANDS[$cmd] ]]; then
		local handler="${_ARGS_SUBCOMMANDS[$cmd]}"
		shift
		"$handler" "$@" || exit $?
		exit 0
	fi

	for arg in "$@"; do
		[[ $arg == "-v" || $arg == "--version" ]] && {
			usage.version
			exit 0
		}
	done

	local rc=0
	cmd_generate "$@" || rc=$?
	if [[ -n ${IMAGINE_JSON:-} ]]; then
		compose.emit_json "$rc" || true
	fi
	rm -f "$IMAGINE_ERROR_FILE"
	return "$rc"
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	main "$@"
fi
