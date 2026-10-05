#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2154
# OpenAI 兼容 images 接口的公共实现，供多家适配器复用：
#   - bearer 认证
#   - 请求体 {model, prompt, n, size[, seed]}，可用额外字段 JSON 顶层合并
#   - 响应 data[].b64_json（非空优先）否则 data[].url
#
# 适配器只声明端点路径，并把差异（额外字段/参考图/尺寸覆盖/数量覆盖）作为参数传入。

import ext/requests
import common

openai_compat.auth() { requests.auth_bearer "$1"; }

openai_compat.endpoint() { printf '%s' "$1"; }

# openai_compat.body [额外字段 JSON] [尺寸覆盖] [数量覆盖]
openai_compat.body() {
	local extra="${1:-}" size="${2:-${SIZE:-}}" count="${3:-${COUNT:-1}}" body
	body=$(jq -n --arg m "$MODEL" --arg p "$PROMPT" --arg s "$size" --argjson n "$count" \
		'{model: $m, prompt: $p, n: $n, size: $s}') || return 1
	if [[ -n ${SEED:-} ]]; then
		body=$(jq --argjson seed "$SEED" '.seed = $seed' <<< "$body") || return 1
	fi
	if [[ -n $extra ]]; then
		# extra 可能很大（参考图 base64），必须走 stdin 而不是 --argjson 参数
		body=$(jq -c --argjson b "$body" '. + $b' <<< "$extra") || return 1
	fi
	printf '%s' "$body"
}

openai_compat.parse() { common.data_b64_or_url "$1"; }
