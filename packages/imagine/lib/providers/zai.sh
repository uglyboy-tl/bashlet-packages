#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016,SC2154
# Z.AI：OpenAI 兼容 images/generations；尺寸原样直传，无参考图接口。

import openai_compat

provider_zai_meta() {
	PROVIDER_LABEL="Z.AI"
	PROVIDER_CREDS=(ZAI_API_KEY)
	PROVIDER_DEFAULT_MODEL="glm-image"
	PROVIDER_CAPS="size:any ref:none seed:no negative:no quality:yes style:no n:4"
	PROVIDER_HOST="api.z.ai"
	PROVIDER_PROBE_PATH="/api/paas/v4/models"
	PROVIDER_MODEL_LIST="glm-image"
}

provider_zai_auth() { openai_compat.auth "$ZAI_API_KEY"; }

provider_zai_endpoint() { openai_compat.endpoint "/api/paas/v4/images/generations"; }

provider_zai_body() { openai_compat.body; }

provider_zai_parse() { openai_compat.parse "$1"; }

provider.register zai
