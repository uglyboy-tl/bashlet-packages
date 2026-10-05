#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016,SC2154
# Cloudflare Workers AI：两个凭证（token + account id）；无 size 参数；
# HTTP 200 也可能是业务错误（success=false + errors[]）。

import core/log
import ext/requests
import common

provider_cloudflare_meta() {
	PROVIDER_LABEL="Cloudflare Workers AI"
	PROVIDER_CREDS=(CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID)
	PROVIDER_DEFAULT_MODEL="@cf/black-forest-labs/flux-1-schnell"
	# 实测 flux-1-schnell 不接受 seed（报 Additional properties '/seed' not allowed）；
	# flux-2-dev 的多参考图走 multipart，暂未接入，故声明 ref:none
	PROVIDER_CAPS="size:none ref:none seed:no negative:no quality:no style:no n:1"
	PROVIDER_HOST="api.cloudflare.com"
	PROVIDER_FREE=true
	PROVIDER_MODEL_LIST="@cf/black-forest-labs/flux-1-schnell
@cf/black-forest-labs/flux-2-dev"
}

provider_cloudflare_auth() { requests.auth_bearer "$CLOUDFLARE_API_TOKEN"; }

provider_cloudflare_endpoint() { printf '/client/v4/accounts/%s/ai/run/%s' "$CLOUDFLARE_ACCOUNT_ID" "$1"; }

provider_cloudflare_body() {
	jq -n --arg p "$PROMPT" '{prompt: $p}'
}

provider_cloudflare_parse() {
	local resp="$1"
	[[ $(requests.json "$resp" '.success') == true ]] || {
		common.fail "Cloudflare: $(common.error_message "$resp" '.errors[0].message')"
		return 1
	}
	IMAGINE_RESULT_TYPE=base64
	IMAGINE_RESULTS=$(requests.json "$resp" '.result.image')
}

provider.register cloudflare
