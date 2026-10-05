#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016,SC2154
# 阿里云 DashScope（通义万相）：多模态生成接口；size 必须用星号分隔。

import core/log
import ext/requests
import common

provider_dashscope_meta() {
	PROVIDER_LABEL="阿里云 DashScope"
	PROVIDER_CREDS=(DASHSCOPE_API_KEY)
	PROVIDER_DEFAULT_MODEL="qwen-image-plus"
	PROVIDER_DEFAULT_REF_MODEL="wan2.7-image-pro"
	PROVIDER_CAPS="size:star ref:multi seed:yes negative:yes quality:yes style:no n:4"
	PROVIDER_HOST="dashscope.aliyuncs.com"
}

provider_dashscope_auth() { requests.auth_bearer "$DASHSCOPE_API_KEY"; }

provider_dashscope_endpoint() { printf '/api/v1/services/aigc/multimodal-generation/generation'; }

provider_dashscope_body() {
	local body content
	if [[ -n ${REF:-} ]]; then
		# 参考图模式下上游只接受 n=1，这里固定为单张；seed/negative 不适用
		[[ -n ${SEED:-} ]] && log.warn "dashscope 参考图模式忽略 --seed"
		[[ -n ${NEGATIVE:-} ]] && log.warn "dashscope 参考图模式忽略 --negative-prompt"
		content=$(common.ref_build_array "$REF" '. += [{image: ("data:\($mime);base64," + $b64)}]') || return 1
		content=$(jq --arg p "$PROMPT" '. += [{text: $p}]' <<< "$content") || return 1
		body=$(jq --arg m "$MODEL" --arg s "$SIZE" '{
			model: $m,
			input: {messages: [{role: "user", content: .}]},
			parameters: {size: $s, n: 1, watermark: false}
		}' <<< "$content") || return 1
	else
		body=$(jq -n --arg m "$MODEL" --arg p "$PROMPT" --arg s "$SIZE" --argjson n "$COUNT" '{
			model: $m,
			input: {messages: [{role: "user", content: [{text: $p}]}]},
			parameters: {size: $s, n: $n, prompt_extend: true, watermark: false}
		}') || return 1
		[[ -n ${SEED:-} ]] && body=$(jq --argjson seed "$SEED" '.parameters.seed = $seed' <<< "$body")
		[[ -n ${NEGATIVE:-} ]] && body=$(jq --arg neg "$NEGATIVE" '.parameters.negative_prompt = $neg' <<< "$body")
	fi
	printf '%s' "$body"
}

provider_dashscope_parse() {
	IMAGINE_RESULT_TYPE=url
	IMAGINE_RESULTS=$(requests.json "$1" '.output.choices[].message.content[].image // empty')
}

provider_dashscope_models() {
	requests.json "$(requests.get "/api/v1/models?page_no=1&page_size=200")" '.output.models[] | select(.model | test("qwen-image|wan.*image|wan.*t2i|wanx.*t2i")) | .model'
}

provider.register dashscope
