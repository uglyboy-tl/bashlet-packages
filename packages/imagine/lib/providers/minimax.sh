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
	# 探活用 /v1/models（200 即 key 有效）—— 但它只列对话模型（MiniMax-M3 等），图像模型没有列表端点，
	# 所以下面的清单只能手工维护
	PROVIDER_PROBE_PATH="/v1/models"
	# 手工维护的依据（2026-10-08 实测）：
	#   - 官方文档的 enum 是唯一来源：文生图 image-01；图生图 image-01 + image-01-live
	#   - 候选列表端点都不存在：/v1/models 忽略 ?type=image（仍返回对话模型），
	#     /v1/image/models、/v1/images/models 等一律 404
	#   - 实际打生成接口：image-01 与 image-01-live 均 success；
	#     原先写在这里的 image-01-plus / image-02 报 "unsupported model"
	PROVIDER_MODEL_LIST="image-01
image-01-live"
}

provider_minimax_auth() { requests.auth_bearer "$MINIMAX_API_KEY"; }

provider_minimax_endpoint() { printf '/v1/image_generation'; }

provider_minimax_body() {
	local w="${SIZE%%x*}" h="${SIZE##*x}" refs body
	if [[ -n ${REF:-} ]]; then
		refs=$(common.ref_build_array "$REF" '. += [{type: "character", image_file: ("data:\($mime);base64," + $b64)}]') || return 1
		body=$(json.run --arg m "$MODEL" --arg p "$PROMPT" --argjson n "$COUNT" --argjson w "$w" --argjson h "$h" '{
			model: $m, prompt: $p, n: $n, width: $w, height: $h,
			response_format: "base64", subject_reference: .
		}' <<< "$refs") || return 1
	else
		body=$(json.run -n --arg m "$MODEL" --arg p "$PROMPT" --argjson n "$COUNT" --argjson w "$w" --argjson h "$h" '{
			model: $m, prompt: $p, n: $n, width: $w, height: $h
		}') || return 1
	fi
	[[ -n ${SEED:-} ]] && body=$(json.run --argjson seed "$SEED" '.seed = $seed' <<< "$body")
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
