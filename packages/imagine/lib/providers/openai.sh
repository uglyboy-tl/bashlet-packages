#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016,SC2154
# OpenAI：OpenAI images/generations；不同模型的尺寸集合与 n 上限不同，故做模型级细化。

import core/log
import ext/requests
import size
import openai_compat

provider_openai_meta() {
	PROVIDER_LABEL="OpenAI"
	PROVIDER_CREDS=(OPENAI_API_KEY)
	PROVIDER_DEFAULT_MODEL="gpt-image-1"
	PROVIDER_CAPS="size:any ref:none seed:no negative:no quality:yes style:yes n:10"
	PROVIDER_HOST="api.openai.com"
	PROVIDER_XGET_PREFIX="openai"
}

provider_openai_auth() { openai_compat.auth "$OPENAI_API_KEY"; }

provider_openai_endpoint() { openai_compat.endpoint "/v1/images/generations"; }

provider_openai_body() {
	local sz="$SIZE" count="$COUNT" native_q="" extra='{}'
	case "${MODEL,,}" in
		*dall-e-3*)
			sz=$(size.nearest "$sz" "1024x1024 1792x1024 1024x1792")
			native_q="$([[ ${QUALITY:-normal} == 2k ]] && echo hd || echo standard)"
			;;
		*dall-e-2*) sz=$(size.nearest "$sz" "256x256 512x512 1024x1024") ;;
		gpt-image-1*)
			sz=$(size.nearest "$sz" "1024x1024 1536x1024 1024x1536")
			native_q="$([[ ${QUALITY:-normal} == 2k ]] && echo high || echo medium)"
			;;
	esac
	[[ $sz == "$SIZE" ]] || log.warn "openai $MODEL 已将 $SIZE 就近映射为 $sz"
	if [[ ${MODEL,,} == *dall-e-* && $count -gt 1 ]]; then
		log.warn "openai $MODEL 仅支持 n=1，已从 $count 收敛"
		count=1
	fi
	[[ -n $native_q ]] && extra=$(jq -c --arg q "$native_q" '.quality = $q' <<< "$extra")
	[[ -n ${STYLE:-} && ${MODEL,,} == *dall-e-3* ]] && extra=$(jq -c --arg s "$STYLE" '.style = $s' <<< "$extra")
	openai_compat.body "$extra" "$sz" "$count"
}

provider_openai_parse() { openai_compat.parse "$1"; }

provider_openai_models() {
	requests.json "$(requests.get "/v1/models")" '.data[].id | select(test("dall|image"))'
}

provider.register openai
