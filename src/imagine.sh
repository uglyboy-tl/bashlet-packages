#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

set -euo pipefail
SCRIPT_NAME="Imagine"
VERSION="0.2.0"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

.env "$(dirname "${BASH_SOURCE[0]}")"

import std/string
import std/array
import core/log
import core/args
import ext/requests

declare -ga VALID_PROVIDERS=("openai" "google" "dashscope" "zai" "minimax" "doubao")

declare -gA PROVIDER_DEFAULT_MODEL
PROVIDER_DEFAULT_MODEL["openai"]="gpt-image-1"
PROVIDER_DEFAULT_MODEL["google"]="imagen-4.0-fast-generate-001"
PROVIDER_DEFAULT_MODEL["dashscope"]="qwen-image-plus"
PROVIDER_DEFAULT_MODEL["zai"]="glm-image"
PROVIDER_DEFAULT_MODEL["minimax"]="image-01"
PROVIDER_DEFAULT_MODEL["doubao"]="doubao-seedream-5-0-260128"

# 使用 --ref 时的默认模型（部分模型不支持参考图）
declare -gA PROVIDER_DEFAULT_REF_MODEL
PROVIDER_DEFAULT_REF_MODEL["google"]="gemini-2.5-flash-image"
PROVIDER_DEFAULT_REF_MODEL["minimax"]="image-01"
PROVIDER_DEFAULT_REF_MODEL["dashscope"]="wan2.7-image-pro"
PROVIDER_DEFAULT_REF_MODEL["doubao"]="doubao-seedream-5-0-260128"

declare -gA PROVIDER_API_HOST
PROVIDER_API_HOST["openai"]="api.openai.com"
PROVIDER_API_HOST["google"]="generativelanguage.googleapis.com"
PROVIDER_API_HOST["dashscope"]="dashscope.aliyuncs.com"
PROVIDER_API_HOST["zai"]="api.z.ai"
PROVIDER_API_HOST["minimax"]="api.minimaxi.com"
PROVIDER_API_HOST["doubao"]="ark.cn-beijing.volces.com"

declare -gA PROVIDER_XGET_PREFIX
PROVIDER_XGET_PREFIX["openai"]="openai"
PROVIDER_XGET_PREFIX["google"]="gemini"
PROVIDER_XGET_PREFIX["dashscope"]=""
PROVIDER_XGET_PREFIX["zai"]=""
PROVIDER_XGET_PREFIX["minimax"]=""
PROVIDER_XGET_PREFIX["doubao"]=""

declare -gA PROVIDER_API_KEY_ENV
PROVIDER_API_KEY_ENV["openai"]="OPENAI_API_KEY"
PROVIDER_API_KEY_ENV["google"]="GOOGLE_API_KEY"
PROVIDER_API_KEY_ENV["dashscope"]="DASHSCOPE_API_KEY"
PROVIDER_API_KEY_ENV["zai"]="ZAI_API_KEY"
PROVIDER_API_KEY_ENV["minimax"]="MINIMAX_API_KEY"
PROVIDER_API_KEY_ENV["doubao"]="ARK_API_KEY"

declare -gA ASPECT_RATIO_SIZES=(
  ["1:1"]="1024*1024"
  ["16:9"]="1792*1024"
  ["9:16"]="1024*1792"
  ["4:3"]="1408*1056"
  ["3:4"]="1056*1408"
  ["2.35:1"]="2048*872"
)

# minimax 没有模型列表 API，使用静态列表
declare -gA PROVIDER_MODEL_LIST
PROVIDER_MODEL_LIST["minimax"]="image-01\nimage-01-plus\nimage-02\nvideo-01"

_resolve_output_path() {
  local output="$1" provider="$2"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)

  if [[ -z $output ]]; then
    echo "${provider}_${timestamp}.png"
    return
  fi

  if [[ $output == */ ]] || [[ -d $output ]]; then
    mkdir -p "$output"
    echo "${output%/}/${provider}_${timestamp}.png"
    return
  fi

  echo "$output"
}

_resolve_image_size() {
  local size="$1" ar="$2"
  [[ -n $size ]] && echo "$size" | tr 'x' '*' && return
  [[ -n $ar ]] && [[ -v ASPECT_RATIO_SIZES[$ar] ]] && echo "${ASPECT_RATIO_SIZES[$ar]}" && return
  echo "2048*872"
}

_resolve_base_url() {
  local provider="$1"
  local xget_base="${XGET_BASE_URL:-}"
  local xget_prefix="${PROVIDER_XGET_PREFIX[$provider]:-}"
  if [[ -n $xget_base && -n $xget_prefix ]]; then
    echo "${xget_base}/ip/${xget_prefix}"
  else
    echo "https://${PROVIDER_API_HOST[$provider]}"
  fi
}

_init_provider_api() {
  local provider="$1"

  requests.init
  requests.timeout 120
  requests.base_url "$(_resolve_base_url "$provider")"

  local key_env="${PROVIDER_API_KEY_ENV[$provider]}"
  local key="${!key_env:-}"
  [[ -n $key ]] || { log.error "${key_env} not set - add to .env or export it"; return 1; }

  if [[ $provider == "google" ]]; then
    requests.headers.append "x-goog-api-key" "$key"
  else
    requests.auth_bearer "$key"
  fi
}

_download_images() {
  local urls="$1" output="$2"
  local i=0
  while IFS= read -r url; do
    [[ -z $url ]] && continue
    local outfile="$output"
    if [[ $i -gt 0 ]]; then
      local base="${output%.*}" ext="${output##*.}"
      outfile="${base}_${i}.${ext}"
    fi
    log.info "Downloading image $((i + 1))..."
    requests.download "$url" "$outfile"
    log.info "Saved: $outfile"
    ((i++))
  done <<< "$urls"
}

_get_mime_type() {
  local ext="${1##*.}"
  case "${ext,,}" in
    jpg|jpeg) echo "image/jpeg";;
    png) echo "image/png";;
    webp) echo "image/webp";;
    *) log.error "Unsupported image format for reference: $1 (jpg/jpeg/png/webp only)"; return 1;;
  esac
}

_ref_build_array() {
  local ref="$1" filter="$2"
  local result='[]' ref_path mime
  IFS=',' read -ra ref_paths <<< "$ref"
  for ref_path in "${ref_paths[@]}"; do
    [[ -f $ref_path ]] || { log.error "Reference image not found: $ref_path"; return 1; }
    mime=$(_get_mime_type "$ref_path") || return 1
    local tmpfile
    tmpfile=$(mktemp) || return 1
    string.base64.encode "$ref_path" | tr -d '\n' > "$tmpfile"
    result=$(echo "$result" | jq --rawfile b64 "$tmpfile" --arg mime "$mime" "$filter")
    rm -f "$tmpfile"
  done
  echo "$result"
}

_provider_generate() {
  local provider="$1" prompt="$2" output="$3" model="$4" size="$5" count="$6" seed="$7" negative="$8"
  local quality="$9" style="${10}" ref="${11}"

  _init_provider_api "$provider" || return 1

  if [[ -n $ref ]]; then
    model="${model:-${PROVIDER_DEFAULT_REF_MODEL[$provider]:-${PROVIDER_DEFAULT_MODEL[$provider]}}}"
  else
    model="${model:-${PROVIDER_DEFAULT_MODEL[$provider]}}"
  fi
  count="${count:-1}"

  local body api_path
  local is_base64=false

  case $provider in
    openai)
      [[ $model == "dall-e-3" && $count -gt 1 ]] && { log.warn "DALL-E 3 only supports n=1, forcing count=1"; count=1; }
      local sz="${size//\*/x}"
      api_path="/v1/images/generations"
      body=$(jq -n --arg m "$model" --arg p "$prompt" --arg s "$sz" --argjson n "$count" '{model: $m, prompt: $p, n: $n, size: $s}')
      [[ -n $quality ]] && body=$(echo "$body" | jq --arg q "$quality" '.quality = $q')
      [[ -n $style ]] && body=$(echo "$body" | jq --arg s "$style" '.style = $s')
      [[ $model != "dall-e-3" && $model != "dall-e-2" ]] && is_base64=true
      ;;
    google)
      if [[ -n $ref ]]; then
        local parts
        parts=$(_ref_build_array "$ref" '. += [{inlineData: {mimeType: $mime, data: $b64}}]') || return 1
        parts=$(echo "$parts" | jq --arg p "$prompt" '. += [{text: $p}]')
        api_path="/v1beta/models/${model}:generateContent"
        body=$(echo "$parts" | jq --argjson n "$count" '{
          contents: [{role: "user", parts: .}],
          generationConfig: {responseModalities: ["IMAGE"], imageConfig: {imageSize: (if $n > 1 then "1K" else "2K" end)}}
        }')
      else
        api_path="/v1beta/models/${model}:predict"
        body=$(jq -n --arg p "$prompt" --argjson n "$count" '{
          instances: [{prompt: $p}],
          parameters: {sampleCount: $n}
        }')
      fi
      is_base64=true
      ;;
    dashscope)
      api_path="/api/v1/services/aigc/multimodal-generation/generation"
      if [[ -n $ref ]]; then
        local content
        content=$(_ref_build_array "$ref" '. += [{image: ("data:\($mime);base64," + $b64)}]') || return 1
        content=$(echo "$content" | jq --arg p "$prompt" '. += [{text: $p}]')
        body=$(echo "$content" | jq --arg m "$model" --arg s "$size" '{
          model: $m,
          input: { messages: [{ role: "user", content: . }] },
          parameters: { size: $s, n: 1, watermark: false }
        }')
        count=1
      else
        body=$(jq -n --arg m "$model" --arg p "$prompt" --arg s "$size" --argjson n "$count" '{
          model: $m,
          input: { messages: [{ role: "user", content: [{ text: $p }] }] },
          parameters: { size: $s, n: $n, prompt_extend: true, watermark: false }
        }')
        [[ -n $seed ]] && body=$(echo "$body" | jq --argjson seed "$seed" '.parameters.seed = $seed')
        [[ -n $negative ]] && body=$(echo "$body" | jq --arg neg "$negative" '.parameters.negative_prompt = $neg')
      fi
      ;;
    zai)
      local sz="${size//\*/x}"
      api_path="/api/paas/v4/images/generations"
      body=$(jq -n --arg m "$model" --arg p "$prompt" --arg s "$sz" --argjson n "$count" '{model: $m, prompt: $p, n: $n, size: $s}')
      ;;
    minimax)
      [[ $count -gt 9 ]] && { log.warn "MiniMax supports at most 9 images per request, capping count=9"; count=9; }
      api_path="/v1/image_generation"
      if [[ -n $ref ]]; then
        local sr
        sr=$(_ref_build_array "$ref" '. += [{type: "character", image_file: ("data:\($mime);base64," + $b64)}]') || return 1
        body=$(echo "$sr" | jq --arg m "$model" --arg p "$prompt" --argjson n "$count" '{
          model: $m, prompt: $p, n: $n, response_format: "base64", subject_reference: .
        }')
        is_base64=true
      else
        body=$(jq -n --arg m "$model" --arg p "$prompt" --argjson n "$count" '{model: $m, prompt: $p, n: $n}')
      fi
      ;;
    doubao)
      local sz
      if [[ -z $size || $size == "2048*872" ]]; then
        sz="2K"
      else
        sz="${size//\*/x}"
      fi
      api_path="/api/v3/images/generations"
      if [[ -n $ref ]]; then
        local image_data
        image_data=$(_ref_build_array "$ref" '. += [("data:\($mime);base64," + $b64)]') || return 1
        body=$(echo "$image_data" | jq --arg m "$model" --arg p "$prompt" --arg s "$sz" --argjson n "$count" '{
          model: $m, prompt: $p, size: $s, n: $n, response_format: "url", watermark: false, image: (if length == 1 then .[0] else . end)
        }')
      else
        body=$(jq -n --arg m "$model" --arg p "$prompt" --arg s "$sz" --argjson n "$count" '{
          model: $m, prompt: $p, size: $s, n: $n, response_format: "url", watermark: false
        }')
      fi
      [[ -n $seed ]] && body=$(echo "$body" | jq --argjson seed "$seed" '.seed = $seed')
      [[ -n $negative ]] && body=$(echo "$body" | jq --arg neg "$negative" '.negative_prompt = $neg')
      ;;
  esac

  log.info "[$provider] model: $model / size: ${size:-auto} / n: $count"

  local response bodyfile
  bodyfile=$(mktemp) || return 1
  printf '%s' "$body" > "$bodyfile"
  response=$(requests.post "$api_path" "@$bodyfile" "application/json")
  rm -f "$bodyfile"
  requests.raise_for_status "$response" || return 1

  if [[ $provider == "minimax" ]]; then
    local status
    status=$(requests.json "$response" '.base_resp.status_code // 1')
    if [[ $status != 0 ]]; then
      local msg
      msg=$(requests.json "$response" '.base_resp.status_msg // "Unknown error"')
      log.error "MiniMax error: $msg"
      return 1
    fi
  fi

  local images
  case $provider in
    openai)    images=$(requests.json "$response" '.data[].b64_json // .data[].url // empty') ;;
    google)    images=$(requests.json "$response" '(try .predictions[].bytesBase64Encoded) // (try .candidates[].content.parts[].inlineData.data) // empty') ;;
    dashscope) images=$(requests.json "$response" '.output.choices[].message.content[].image // empty') ;;
    zai)       images=$(requests.json "$response" '.data[].url // empty') ;;
    minimax) images=$(requests.json "$response" '.data.image_base64[] // .data.image_urls[] // empty') ;;
    doubao)    images=$(requests.json "$response" '.data[].url // empty') ;;
  esac

  [[ -z $images ]] && { log.error "No images in response"; return 1; }

  if $is_base64; then
    local i=0
    while IFS= read -r b64; do
      [[ -z $b64 ]] && continue
      local outfile="$output"
      if [[ $i -gt 0 ]]; then
        local base="${output%.*}" ext="${output##*.}"
        outfile="${base}_${i}.${ext}"
      fi
      log.info "Decoding image $((i + 1))..."
      echo "$b64" | string.base64.decode > "$outfile"
      log.info "Saved: $outfile"
      ((i++))
    done <<< "$images"
  else
    _download_images "$images" "$output"
  fi
}

cmd_generate() {
  args.init "生成图像"
  args.add_options "prompt" "p" "提示词" "STRING"
  args.add_options "promptfile" "P" "从文件读取提示词" "STRING"
  args.add_options "output" "o" "输出路径" "STRING"
  args.add_options "provider" "" "服务提供商" "STRING"
  args.add_options "model" "m" "模型 ID" "STRING"
  args.add_options "ar" "" "宽高比" "STRING"
  args.add_options "size" "s" "显式尺寸" "STRING"
  args.add_options "quality" "q" "画质预设" "STRING"
  args.add_options "count" "n" "生成数量" "NUMBER"
  args.add_options "seed" "" "随机种子" "NUMBER"
  args.add_options "negative-prompt" "" "负面提示词" "STRING"
  args.add_options "ref" "" "参考图路径" "STRING"
  args.add_options "style" "" "风格预设" "STRING"
  args.process "$@"

  local provider model output size ar count seed negative style quality
  local prompt promptfile ref

  prompt="$(args.get "-p" "--prompt")" || prompt=""
  promptfile="$(args.get "-P" "--promptfile")" || promptfile=""
  output="$(args.get "-o" "--output")" || output=""
  provider="$(args.get "--provider")" || provider=""
  model="$(args.get "-m" "--model")" || model=""
  ar="$(args.get "--ar")" || ar=""
  size="$(args.get "-s" "--size")" || size=""
  quality="$(args.get "-q" "--quality")" || quality=""
  count="$(args.get "-n" "--count")" || count="1"
  seed="$(args.get "--seed")" || seed=""
  negative="$(args.get "--negative-prompt")" || negative=""
  style="$(args.get "--style")" || style=""
  ref="$(args.get "--ref")" || ref=""

  if [[ -n $promptfile ]]; then
    [[ -f $promptfile ]] || { log.error "Prompt file not found: $promptfile"; return 1; }
    local file_content
    file_content=$(< "$promptfile")
    prompt="${prompt:+${prompt} }${file_content}"
  fi

  [[ -z $prompt ]] && { log.error "No prompt. Use -p/--prompt or -P/--promptfile"; return 1; }
  string.natural.check "$count" || count=1

  [[ -n $ref && -z $provider ]] && provider="google"
  [[ -z $provider ]] && provider="minimax"

  if ! array.contains VALID_PROVIDERS "$provider"; then
    log.error "Unknown provider: $provider"
    log.error "Valid: ${VALID_PROVIDERS[*]}"
    return 1
  fi

  output=$(_resolve_output_path "$output" "$provider")
  size=$(_resolve_image_size "$size" "$ar")

  _provider_generate "$provider" "$prompt" "$output" "$model" "$size" "$count" "$seed" "$negative" "$quality" "$style" "$ref"
}

_provider_has_key() {
  local key_env="${PROVIDER_API_KEY_ENV[$1]}"
  [[ -n ${!key_env:-} ]]
}

_list_models_from_api() {
  local provider="$1"
  _init_provider_api "$provider" || return 1

  case $provider in
    openai)
      requests.json "$(requests.get "/v1/models")" '.data[] | select(.id | test("dall|image")) | .id'
      ;;
    google)
      requests.json "$(requests.get "/v1beta/models")" '.models[].name | select(. | test("imagen|gemini.*image")) | sub("^models/"; "")'
      ;;
    dashscope)
      requests.json "$(requests.get "/api/v1/models?page_no=1&page_size=200")" '.output.models[] | select(.model | test("qwen-image|wan[0-9]|wanx")) | .model'
      ;;
    doubao)
      requests.json "$(requests.get "/api/v3/models")" '.data[].id | select(. | test("seedream|seedance")) | .'
      ;;
  esac
}

_fmt_provider_via() {
  local p="$1"
  local xget="${PROVIDER_XGET_PREFIX[$p]:-}"
  if [[ -n $XGET_BASE_URL && -n $xget ]]; then
    echo "${XGET_BASE_URL}/ip/${xget}"
  else
    echo "direct"
  fi
}

cmd_models() {
  if [[ $# -eq 0 ]]; then
    printf "  %-12s %-28s %s\n" "PROVIDER" "DEFAULT MODEL" "VIA"
    printf "  %s\n" "──────────────────────────────────────────────────────────────"
    for p in "${VALID_PROVIDERS[@]}"; do
      _provider_has_key "$p" || continue
      printf "  %-12s %-28s %s\n" "$p" "${PROVIDER_DEFAULT_MODEL[$p]}" "$(_fmt_provider_via "$p")"
    done
    echo ""
    echo "  Use 'models <provider>' to see all available models."
  else
    local provider="$1"
    array.contains VALID_PROVIDERS "$provider" || { log.error "Invalid provider: $provider"; return 1; }
    _provider_has_key "$provider" || { log.error "${PROVIDER_API_KEY_ENV[$provider]} not set"; return 1; }
    printf "  %s (default: %s)\n" "$provider" "${PROVIDER_DEFAULT_MODEL[$provider]}"
    printf "  %s\n" "──────────────────────────────────────────"
    local models=""
    case $provider in
      openai|google|dashscope|doubao)
        models=$(_list_models_from_api "$provider") || models=""
        ;;
      minimax)
        models="${PROVIDER_MODEL_LIST[$provider]:-}"
        ;;
    esac
    echo -e "$models"
  fi
}

main() {
  args.init "命令行文生图工具 — 支持 OpenAI, Google, DashScope, Z.AI, MiniMax, Doubao"
  args.add_options "version" "v" "显示版本信息"
  args.add_subcommand "models" "查看提供商和模型信息" "cmd_models"

  local cmd="${1:-}"
  if [[ -v _ARGS_SUBCOMMANDS[$cmd] ]]; then
    local handler="${_ARGS_SUBCOMMANDS[$cmd]}"
    shift
    "$handler" "$@"
    exit $?
  fi

  for arg in "$@"; do
    [[ $arg == "-h" || $arg == "--help" ]] && { args.show_help; exit 0; }
    [[ $arg == "-v" || $arg == "--version" ]] && { usage.version; exit 0; }
  done

  cmd_generate "$@"
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
fi
