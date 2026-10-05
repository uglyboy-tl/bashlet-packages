#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016,SC2154
# MiniMax：宽高分开传；HTTP 200 也可能是业务错误（base_resp.status_code）。

import core/log
import ext/requests
import common
provider_minimax_meta() {
	PROVIDER_LABEL="MiniMax"
	PROVIDER_CREDS=(MINIMAX_API_KEY)
	PROVIDER_DEFAULT_MODEL="image-01"
	PROVIDER_CAPS="size:any ref:multi seed:yes negative:no quality:yes style:no n:9"
	PROVIDER_HOST="api.minimaxi.com"
	PROVIDER_MODEL_LIST="image-01
image-01-plus
image-02"
}

provider_minimax_auth() { requests.auth_bearer "$MINIMAX_API_KEY"; }

provider_minimax_endpoint() { printf '/v1/image_generation'; }

provider_minimax_body() {
	local w="${SIZE%%x*}" h="${SIZE##*x}" refs body
	if [[ -n ${REF:-} ]]; then
		refs=$(common.ref_build_array "$REF" '. += [{type: "character", image_file: ("data:\($mime);base64," + $b64)}]') || return 1
		body=$(jq --arg m "$MODEL" --arg p "$PROMPT" --argjson n "$COUNT" --argjson w "$w" --argjson h "$h" '{
			model: $m, prompt: $p, n: $n, width: $w, height: $h,
			response_format: "base64", subject_reference: .
		}' <<< "$refs") || return 1
	else
		body=$(jq -n --arg m "$MODEL" --arg p "$PROMPT" --argjson n "$COUNT" --argjson w "$w" --argjson h "$h" '{
			model: $m, prompt: $p, n: $n, width: $w, height: $h
		}') || return 1
	fi
	[[ -n ${SEED:-} ]] && body=$(jq --argjson seed "$SEED" '.seed = $seed' <<< "$body")
	printf '%s' "$body"
}

provider_minimax_parse() {
	local resp="$1" status b64
	status=$(requests.json "$resp" '.base_resp.status_code // 1')
	[[ $status == 0 ]] || {
		common.fail "MiniMax: $(common.error_message "$resp" '.base_resp.status_msg')"
		return 1
	}
	b64=$(requests.json "$resp" '(try .data.image_base64[] catch empty) // empty')
	if [[ -n $b64 ]]; then
		IMAGINE_RESULT_TYPE=base64
		IMAGINE_RESULTS="$b64"
	else
		IMAGINE_RESULT_TYPE=url
		IMAGINE_RESULTS=$(requests.json "$resp" '(try .data.image_urls[] catch empty) // empty')
	fi
}

provider.register minimax
