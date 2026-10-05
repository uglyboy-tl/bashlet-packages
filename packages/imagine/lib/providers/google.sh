#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016,SC2154
# Google Gemini：generateContent；尺寸用 aspectRatio，参考图走 inlineData。

import core/log
import ext/requests
import common

provider_google_meta() {
	PROVIDER_LABEL="Google Gemini"
	PROVIDER_CREDS=(GOOGLE_API_KEY)
	PROVIDER_DEFAULT_MODEL="gemini-2.5-flash-image"
	PROVIDER_CAPS="size:aspect ref:multi seed:no negative:no quality:yes style:no n:4"
	PROVIDER_HOST="generativelanguage.googleapis.com"
	PROVIDER_XGET_PREFIX="gemini"
}

provider_google_auth() { requests.headers.append "x-goog-api-key" "$GOOGLE_API_KEY"; }

provider_google_endpoint() { printf '/v1beta/models/%s:generateContent' "$1"; }

provider_google_body() {
	local parts body
	if [[ -n ${REF:-} ]]; then
		parts=$(common.ref_build_array "$REF" '. += [{inlineData: {mimeType: $mime, data: $b64}}]') || return 1
		parts=$(jq --arg p "$PROMPT" '. += [{text: $p}]' <<< "$parts") || return 1
		body=$(jq --arg ar "$ASPECT" --arg is "$IMAGE_SIZE" '{
			contents: [{role: "user", parts: .}],
			generationConfig: {responseModalities: ["IMAGE"], imageConfig: {aspectRatio: $ar, imageSize: $is}}
		}' <<< "$parts") || return 1
	else
		body=$(jq -n --arg p "$PROMPT" --arg ar "$ASPECT" --arg is "$IMAGE_SIZE" '{
			contents: [{role: "user", parts: [{text: $p}]}],
			generationConfig: {responseModalities: ["IMAGE"], imageConfig: {aspectRatio: $ar, imageSize: $is}}
		}') || return 1
	fi
	printf '%s' "$body"
}

provider_google_parse() {
	IMAGINE_RESULT_TYPE=base64
	IMAGINE_RESULTS=$(requests.json "$1" '(try .candidates[].content.parts[].inlineData.data) // empty')
}

provider_google_models() {
	requests.json "$(requests.get "/v1beta/models")" '.models[].name | select(. | test("gemini.*image")) | sub("^models/"; "")'
}

provider.register google
