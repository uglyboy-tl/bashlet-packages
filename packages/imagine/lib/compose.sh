#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2154
# 生成编排：初始化请求、套用能力声明、调用适配器、落盘。
#
# 请求上下文（入口设置、适配器读取）：
#   PROMPT MODEL SIZE ASPECT SIZE_EXPLICIT COUNT SEED NEGATIVE QUALITY IMAGE_SIZE STYLE REF EXTRA_JSON
# 解析结果（适配器设置、本模块消费）：
#   IMAGINE_RESULT_TYPE=url|base64  IMAGINE_RESULTS=换行分隔

import core/log
import ext/requests
import std/string
import common
import provider
import size

# 请求超时（秒）与重试次数，可用 IMAGINE_TIMEOUT / IMAGINE_RETRY 覆盖
: "${IMAGINE_TIMEOUT:=120}"
: "${IMAGINE_RETRY:=2}"
: "${IMAGINE_JSON:=}"
: "${IMAGINE_ERROR:=}"

declare -ga IMAGINE_FILES=()
declare -gi IMAGINE_ATTEMPTS=0

compose.init() {
	local name="$1"
	requests.init
	requests.timeout "$IMAGINE_TIMEOUT"
	requests.base_url "$(provider.base_url "$name")"
	provider.auth "$name"
}

# compose.apply_caps <name>：把用户输入收敛到 provider 能力边界内
compose.apply_caps() {
	local name="$1" cap maxn
	# 尺寸：能力声明决定格式（star/fixed/none/aspect）
	cap="$(provider.cap "$name" size)" || cap=any
	if [[ $cap == none && ${SIZE_EXPLICIT:-false} == true ]]; then
		log.warn "$name 不支持自定义尺寸，已忽略 -s/--ar"
	fi
	local requested="${SIZE//\*/x}"
	SIZE="$(size.cap "$cap" "$SIZE" "$ASPECT" "${PROV_SIZES[$name]:-}")" || return 1
	if [[ $cap == fixed && $SIZE != "$requested" ]]; then
		log.warn "$name 只支持固定尺寸，$requested 已就近映射为 $SIZE"
	fi
	if [[ $cap == aspect && ${SIZE_EXPLICIT:-false} == true ]]; then
		log.warn "$name 只按宽高比出图，$requested 已按 $ASPECT 处理"
	fi

	# 数量上限
	if maxn="$(provider.cap "$name" n)" && [[ -n $maxn ]] && ((COUNT > maxn)); then
		log.warn "$name 单次最多 $maxn 张，已从 $COUNT 收敛到 $maxn"
		COUNT="$maxn"
	fi

	# 参考图：不支持则明确报错，不把参数丢给上游换 400
	if [[ -n ${REF:-} ]]; then
		cap="$(provider.cap "$name" ref)" || cap=none
		[[ $cap == none ]] && {
			common.fail "$name 不支持参考图（--ref），请换 provider 或去掉 --ref"
			return 1
		}
	fi

	# 其余可选参数：不支持则 warn 一次并忽略
	compose._drop_unsupported "$name" seed "$SEED" SEED "--seed"
	compose._drop_unsupported "$name" negative "$NEGATIVE" NEGATIVE "--negative-prompt"
	compose._drop_unsupported "$name" style "$STYLE" STYLE "--style"

	# 分辨率档位：size:fixed/none 的 provider 无法兑现 2k
	if [[ ${QUALITY_EXPLICIT:-false} == true && ${QUALITY:-normal} == 2k ]]; then
		cap="$(provider.cap "$name" quality)" || cap=no
		[[ $cap == yes ]] || log.warn "$name 不支持 --quality 2k，已按默认分辨率处理"
	fi
}

compose._drop_unsupported() {
	local name="$1" capname="$2" value="$3" varname="$4" label="$5" cap
	[[ -z $value ]] && return 0
	cap="$(provider.cap "$name" "$capname")" || cap=no
	[[ $cap == yes ]] && return 0
	log.warn "$label 在 $name 不受支持，已忽略"
	printf -v "$varname" '%s' ""
}

compose.build() {
	local name="$1" body
	body="$(provider.body "$name")" || return 1
	[[ -n $body ]] || {
		common.fail "构造的请求体为空（检查参数）"
		return 1
	}
	if [[ -n ${EXTRA_JSON:-} ]]; then
		body="$(jq -c --argjson e "$EXTRA_JSON" '. * $e' <<< "$body")" || return 1
	fi
	printf '%s' "$body"
}

# 单次尝试：0=成功，1=不可重试（业务/参数错误），2=可重试（传输/瞬时故障）
compose._attempt() {
	local name="$1" output="$2" body response bodyfile status detail
	body="$(compose.build "$name")" || return 1

	log.info "[$name] model: $MODEL / size: ${SIZE:-auto} / n: $COUNT"
	bodyfile=$(mktemp) || return 1
	printf '%s' "$body" > "$bodyfile"
	response=$(requests.post "$(provider.endpoint "$name" "$MODEL")" "@$bodyfile" "application/json")
	rm -f "$bodyfile"

	if [[ $(requests.success "$response") != true ]]; then
		status="$(requests.status_code "$response")"
		detail="$(common.error_message "$response" '.errors[0].message // .error.message // .message // .msg // .base_resp.status_msg' '')"
		common.fail "HTTP $status${detail:+: $detail}"
		# 4xx（除 429）是参数/凭证问题，重试无意义
		[[ $status == 4* && $status != 429 ]] && return 1
		return 2
	fi
	if ! requests.text "$response" | jq . > /dev/null 2>&1; then
		common.fail "响应不是合法 JSON（可能被截断）"
		return 2
	fi

	provider.parse "$name" "$response" || return 1
	[[ -n ${IMAGINE_RESULTS:-} ]] || {
		common.fail "响应中没有图片"
		return 2
	}
	compose.save "$output"
}

# 重试编排：整体重跑 build→post→校验，次数由 IMAGINE_RETRY 控制（默认 2）
compose.generate() {
	local name="$1" output="$2" max="${IMAGINE_RETRY:-2}" attempt=0 rc=0
	[[ $max =~ ^[0-9]+$ ]] || max=2
	compose.init "$name" || return 1
	IMAGINE_ATTEMPTS=0
	IMAGINE_ERROR=""
	while :; do
		IMAGINE_FILES=()
		IMAGINE_ATTEMPTS=$((IMAGINE_ATTEMPTS + 1))
		rc=0
		compose._attempt "$name" "$output" || rc=$?
		((rc == 0)) && return 0
		((rc == 2 && attempt < max)) || return 1
		((++attempt))
		log.warn "可恢复失败，$((attempt * 2))s 后重试（$attempt/$max）"
		sleep "$((attempt * 2))"
	done
}

compose.save() {
	local output="$1" i=0 item outfile tmp
	local -a written=()
	while IFS= read -r item; do
		[[ -z $item ]] && continue
		outfile="$(compose._numbered "$output" "$i")"
		tmp=$(mktemp "${outfile}.tmp.XXXXXX") || {
			common.fail "无法创建临时文件: $outfile"
			return 1
		}
		if [[ ${IMAGINE_RESULT_TYPE:-url} == base64 ]]; then
			log.info "Decoding image $((i + 1))..."
			printf '%s' "$item" | string.base64.decode > "$tmp" || {
				compose._save_fail written "base64 解码失败" "$tmp"
				return 1
			}
		else
			log.info "Downloading image $((i + 1))..."
			requests.download "$item" "$tmp" || {
				compose._save_fail written "下载失败: $item" "$tmp"
				return 1
			}
		fi
		common.is_image_file "$tmp" || {
			compose._save_fail written "落盘内容不是图片（上游返回错误页或截断）: $outfile" "$tmp"
			return 1
		}
		mv -f "$tmp" "$outfile" || {
			compose._save_fail written "写入失败: $outfile" "$tmp"
			return 1
		}
		written+=("$outfile")
		log.info "Saved: $outfile"
		((++i))
	done <<< "$IMAGINE_RESULTS"
	IMAGINE_FILES=("${written[@]}")
}

# 落盘失败：删掉本次已写文件与当前文件，并记录错误
compose._save_fail() {
	local -n files="$1"
	common.fail "$2"
	rm -f "$3" ${files[@]+"${files[@]}"}
}

compose._numbered() {
	local output="$1" i="$2"
	if ((i == 0)); then
		printf '%s' "$output"
	elif [[ ${output##*/} == *.* ]]; then
		printf '%s_%s.%s' "${output%.*}" "$i" "${output##*.}"
	else
		printf '%s_%s' "$output" "$i"
	fi
}

# compose.emit_json <退出码>：--json 模式下把结果写到 stdout（日志仍在 stderr）
compose.emit_json() {
	local rc="$1" ok=false files_json base err="${IMAGINE_ERROR:-}" count="${COUNT:-1}"
	((rc == 0)) && ok=true
	[[ $count =~ ^[0-9]+$ ]] || count=1
	if [[ -n ${IMAGINE_ERROR_FILE:-} && -s $IMAGINE_ERROR_FILE ]]; then
		err="$(< "$IMAGINE_ERROR_FILE")"
		rm -f "$IMAGINE_ERROR_FILE"
	fi
	if ((${#IMAGINE_FILES[@]})); then
		files_json=$(printf '%s\n' "${IMAGINE_FILES[@]}" | jq -R . | jq -s -c .)
	else
		files_json='[]'
	fi
	base=$(jq -n -c --argjson ok "$ok" --argjson files "$files_json" \
		--arg provider "${PROVIDER:-}" --arg model "${MODEL:-}" \
		--arg requested "${SIZE_REQUESTED:-}" --arg size "${SIZE:-}" --arg aspect "${ASPECT:-}" \
		--argjson count "$count" --argjson attempts "${IMAGINE_ATTEMPTS:-0}" \
		'{ok: $ok, provider: $provider, model: $model, requested_size: $requested, size: $size, aspect: $aspect, count: $count, attempts: $attempts, files: $files}') || return 1
	if ((rc == 0)); then
		printf '%s\n' "$base"
	else
		jq -c --arg e "$err" '. + {error: $e}' <<< "$base" || printf '%s\n' "$base"
	fi
}
