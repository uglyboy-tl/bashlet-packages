#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016,SC2154
# Agnes AI：OpenAI 兼容 images/generations；免费层，参考图走 extra_body。

import ext/requests
import common
import openai_compat

provider_agnes_meta() {
	PROVIDER_LABEL="Agnes AI"
	PROVIDER_CREDS=(AGNES_API_KEY)
	PROVIDER_DEFAULT_MODEL="agnes-image-2.5-flash"
	PROVIDER_CAPS="size:any ref:multi seed:yes negative:no quality:yes style:no n:1"
	PROVIDER_HOST="apihub.agnes-ai.com"
	PROVIDER_PROBE_PATH="/v1/models"
	PROVIDER_FREE=true
}

provider_agnes_auth() { openai_compat.auth "$AGNES_API_KEY"; }

provider_agnes_endpoint() { openai_compat.endpoint "/v1/images/generations"; }

provider_agnes_body() {
	local extra="" refs
	if [[ -n ${REF:-} ]]; then
		refs=$(common.ref_build_array "$REF" '. += [("data:\($mime);base64," + $b64)]') || return 1
		extra=$(json.run -c '{extra_body: {image: (if (. | length) == 1 then .[0] else . end), response_format: "b64_json"}}' <<< "$refs") || return 1
	fi
	openai_compat.body "$extra"
}

provider_agnes_parse() { openai_compat.parse "$1"; }

provider_agnes_models() {
	requests.json "$(requests.get "/v1/models")" '.data[].id | select(. | test("agnes-image")) | .'
}

provider.register agnes
