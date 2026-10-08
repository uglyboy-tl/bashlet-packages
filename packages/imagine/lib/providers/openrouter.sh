#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016,SC2154
# OpenRouter：OpenAI 风格 images 接口，只接受固定尺寸集合（按宽高比就近映射）。

import ext/requests
import common
import openai_compat

provider_openrouter_meta() {
	PROVIDER_LABEL="OpenRouter"
	PROVIDER_CREDS=(OPENROUTER_API_KEY)
	PROVIDER_DEFAULT_MODEL="qwen/qwen-image-3"
	PROVIDER_DEFAULT_REF_MODEL="google/gemini-3.1-flash-image"
	PROVIDER_CAPS="size:fixed ref:multi seed:yes negative:no quality:no style:no n:10"
	PROVIDER_SIZES=(1024x1024 1536x1024 1024x1536)
	PROVIDER_HOST="openrouter.ai"
	PROVIDER_XGET_PREFIX="openrouter"
	PROVIDER_PROBE_PATH="/api/v1/key"
}

provider_openrouter_auth() { openai_compat.auth "$OPENROUTER_API_KEY"; }

provider_openrouter_endpoint() { openai_compat.endpoint "/api/v1/images"; }

provider_openrouter_body() {
	local extra refs
	if [[ -n ${REF:-} ]]; then
		refs=$(common.ref_build_array "$REF" '. += [{type: "image_url", image_url: {url: ("data:\($mime);base64," + $b64)}}]') || return 1
		extra=$(jq -c '{output_format: "png", input_references: .}' <<< "$refs") || return 1
	else
		extra='{"output_format":"png"}'
	fi
	openai_compat.body "$extra"
}

provider_openrouter_parse() { openai_compat.parse "$1"; }

provider_openrouter_models() {
	requests.json "$(requests.get "/api/v1/images/models")" '.data[].id'
}

provider.register openrouter
