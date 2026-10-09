#!/usr/bin/env bash
# shellcheck disable=SC2016
# 包内共享小工具：参考图拼装、输出路径、--extra 透传解析。

import core/log
import ext/requests
import std/string

# 记录错误信息（供 --json 输出）并写日志；写文件以便子 shell 里的错误也能传出
common.fail() {
	IMAGINE_ERROR="$1"
	[[ -n ${IMAGINE_ERROR_FILE:-} ]] && printf '%s' "$1" > "$IMAGINE_ERROR_FILE"
	log.error "$1"
}

# 参考图扩展名 → MIME
common.mime_type() {
	local ext="${1##*.}"
	case "${ext,,}" in
		jpg | jpeg) printf 'image/jpeg' ;;
		png) printf 'image/png' ;;
		webp) printf 'image/webp' ;;
		*)
			common.fail "不支持的参考图格式: $1（仅 jpg/jpeg/png/webp）"
			return 1
			;;
	esac
}

# common.ref_build_array <逗号分隔路径> <jq 过滤器>
# 过滤器对累积数组 `.` 追加一个元素，元素里可用 $mime / $b64。
common.ref_build_array() {
	local ref="$1" filter="$2"
	local -a paths
	local result='[]' path mime tmp
	IFS=',' read -ra paths <<< "$ref"
	for path in "${paths[@]}"; do
		[[ -f $path ]] || {
			common.fail "参考图不存在: $path"
			return 1
		}
		mime=$(common.mime_type "$path") || return 1
		tmp=$(mktemp) || return 1
		string.base64.encode "$path" | tr -d '\n' > "$tmp"
		result=$(json.run --rawfile b64 "$tmp" --arg mime "$mime" "$filter" <<< "$result") || {
			rm -f "$tmp"
			return 1
		}
		rm -f "$tmp"
	done
	printf '%s' "$result"
}

# 落盘内容看起来是图片：PNG / JPEG / WebP（避免把错误页/空文件当图保存）
common.is_image_file() {
	local f="$1" magic
	[[ -s $f ]] || return 1
	magic=$(od -An -tx1 -N12 "$f" 2> /dev/null | tr -d ' \n')
	case "$magic" in
		89504e47*) return 0 ;;                                    # PNG
		52494646*) [[ ${magic:16:8} == 57454250 ]] && return 0 ;; # RIFF + WEBP
	esac
	[[ $magic == ffd8ff* ]] # JPEG
}

# common.error_message <响应> <jq 路径> [默认文案]  → 取错误信息并截断
# requests.json 在 jq 路径解析失败时会回退成整个响应体，这里做长度护栏，避免
# 把含 base64 图片的响应打进日志。
common.error_message() {
	local resp="$1" path="$2" default="${3-Unknown error}" msg
	msg=$(requests.json "$resp" "$path" 2> /dev/null) || msg=""
	if [[ -z $msg || $msg == null || ${#msg} -gt 300 ]]; then
		printf '%s' "$default"
	else
		printf '%s' "$msg"
	fi
}

# OpenAI 风格响应：优先非空 b64_json，否则取 url
# （agnes 在 URL 模式下 b64_json 是空串而非 null，不能只靠 jq 的 // 回退）
common.data_b64_or_url() {
	local b64
	b64=$(requests.json "$1" '.data[] | select(.b64_json != null and .b64_json != "") | .b64_json')
	if [[ -n $b64 ]]; then
		IMAGINE_RESULT_TYPE=base64
		IMAGINE_RESULTS="$b64"
	else
		IMAGINE_RESULT_TYPE=url
		IMAGINE_RESULTS=$(requests.json "$1" '.data[] | select(.url != null and .url != "") | .url')
	fi
}

# common.output_path <用户输出> <provider>  → 具体文件路径（目录或空值时自动命名）
common.output_path() {
	local output="$1" provider="$2" timestamp
	timestamp=$(date +%Y%m%d_%H%M%S)
	if [[ -z $output ]]; then
		printf '%s_%s.png' "$provider" "$timestamp"
		return 0
	fi
	if [[ $output == */ || -d $output ]]; then
		mkdir -p "$output"
		printf '%s/%s_%s.png' "${output%/}" "$provider" "$timestamp"
		return 0
	fi
	printf '%s' "$output"
}

# common.extra_json <k=v[,k=v...]>  → JSON 对象；值按 true/false/null/数字/字符串推断。
# key 支持点号路径，嵌套参数写 parameters.prompt_extend=false。
common.extra_json() {
	local extra="$1" json='{}' pair key value next
	local -a pairs
	IFS=',' read -ra pairs <<< "$extra"
	for pair in "${pairs[@]}"; do
		key="${pair%%=*}"
		value="${pair#*=}"
		[[ $pair == *=* && -n $key ]] || {
			common.fail "无效的 --extra: $pair（应为 key=value）"
			return 1
		}
		case "$value" in
			true | false | null) next=$(json.run -c --arg k "$key" --argjson v "$value" 'setpath($k | split("."); $v)' <<< "$json") ;;
			'') next=$(json.run -c --arg k "$key" 'setpath($k | split("."); "")' <<< "$json") ;;
			*)
				if [[ $value =~ ^-?[0-9]+$ || $value =~ ^-?[0-9]*\.[0-9]+$ ]]; then
					next=$(json.run -c --arg k "$key" --argjson v "$value" 'setpath($k | split("."); $v)' <<< "$json")
				else
					next=$(json.run -c --arg k "$key" --arg v "$value" 'setpath($k | split("."); $v)' <<< "$json")
				fi
				;;
		esac
		[[ -n $next ]] || {
			common.fail "无效的 --extra 取值: $pair"
			return 1
		}
		json="$next"
	done
	printf '%s' "$json"
}
