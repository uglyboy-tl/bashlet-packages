#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016,SC2154
# 火山方舟（Doubao Seedream）：OpenAI 兼容；尺寸最低像素有要求，不传尺寸时用 "2K"。

import ext/requests
import common
import size
import openai_compat

provider_doubao_meta() {
	PROVIDER_LABEL="火山方舟 Doubao"
	PROVIDER_CREDS=(ARK_API_KEY)
	PROVIDER_DEFAULT_MODEL="doubao-seedream-5-0-260128"
	PROVIDER_CAPS="size:any ref:multi seed:yes negative:yes quality:yes style:no n:10"
	PROVIDER_HOST="ark.cn-beijing.volces.com"
}

provider_doubao_auth() { openai_compat.auth "$ARK_API_KEY"; }

provider_doubao_endpoint() { openai_compat.endpoint "/api/v3/images/generations"; }

provider_doubao_body() {
	local sz extra refs
	if [[ ${SIZE_EXPLICIT:-false} == true ]]; then
		sz=$(size.min_pixels "$SIZE" 3686400)
	else
		sz="2K"
	fi
	if [[ -n ${REF:-} ]]; then
		refs=$(common.ref_build_array "$REF" '. += [("data:\($mime);base64," + $b64)]') || return 1
		extra=$(jq -c '{response_format: "url", watermark: false, image: (if (. | length) == 1 then .[0] else . end)}' <<< "$refs") || return 1
	else
		extra='{"response_format":"url","watermark":false}'
	fi
	[[ -n ${NEGATIVE:-} ]] && extra=$(jq -c --arg neg "$NEGATIVE" '.negative_prompt = $neg' <<< "$extra")
	openai_compat.body "$extra" "$sz"
}

provider_doubao_parse() { openai_compat.parse "$1"; }

provider_doubao_models() {
	requests.json "$(requests.get "/api/v3/models")" '.data[].id | select(. | test("seedream")) | .'
}

provider.register doubao
