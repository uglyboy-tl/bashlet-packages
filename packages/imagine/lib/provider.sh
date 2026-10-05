#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016
# provider 注册表：适配器在加载时调用 provider.register 声明自己；核心只读注册表，不认 provider 名。
#
# 适配器契约（lib/providers/<name>.sh 必须提供）：
#   provider_<name>_meta     设置 PROVIDER_* 全局后返回；register 会拷进注册表
#   provider_<name>_auth     追加认证头（requests.headers.append / requests.auth_bearer）
#   provider_<name>_endpoint $1=model → 输出请求路径
#   provider_<name>_body     读 PROMPT/MODEL/SIZE/ASPECT/COUNT/... → 输出请求 JSON
#   provider_<name>_parse    $1=响应 JSON → 设 IMAGINE_RESULT_TYPE（url|base64）与 IMAGINE_RESULTS
#   provider_<name>_models   可选；输出换行分隔的模型 ID
#
# meta 可声明：PROVIDER_LABEL / PROVIDER_CREDS(数组) / PROVIDER_DEFAULT_MODEL /
#   PROVIDER_DEFAULT_REF_MODEL / PROVIDER_CAPS / PROVIDER_SIZES(数组) /
#   PROVIDER_HOST / PROVIDER_XGET_PREFIX / PROVIDER_FREE / PROVIDER_MODEL_LIST
#
# PROVIDER_CAPS 是唯一的能力真相，形如 "size:star ref:multi seed:yes negative:no quality:no style:no n:9"。
# size 取 any/star/fixed/aspect/none；ref 取 none/one/multi；其余 yes/no。

import core/log
import registry

declare -gA PROV_LABEL=() PROV_CREDS=() PROV_DEFAULT_MODEL=() PROV_DEFAULT_REF_MODEL=()
declare -gA PROV_CAPS=() PROV_SIZES=() PROV_HOST=() PROV_XGET=() PROV_FREE=() PROV_MODEL_LIST=()
declare -ga PROV_ORDER=()

provider.register() {
	local name="$1"
	PROVIDER_LABEL="" PROVIDER_DEFAULT_MODEL="" PROVIDER_DEFAULT_REF_MODEL="" PROVIDER_CAPS=""
	PROVIDER_HOST="" PROVIDER_XGET_PREFIX="" PROVIDER_FREE=false PROVIDER_MODEL_LIST=""
	PROVIDER_CREDS=() PROVIDER_SIZES=()
	"provider_${name}_meta" || {
		log.error "provider 适配器 $name 的 meta 失败"
		return 1
	}
	PROV_LABEL[$name]="$PROVIDER_LABEL"
	PROV_CREDS[$name]="${PROVIDER_CREDS[*]:-}"
	PROV_DEFAULT_MODEL[$name]="$PROVIDER_DEFAULT_MODEL"
	PROV_DEFAULT_REF_MODEL[$name]="$PROVIDER_DEFAULT_REF_MODEL"
	PROV_CAPS[$name]="$PROVIDER_CAPS"
	PROV_SIZES[$name]="${PROVIDER_SIZES[*]:-}"
	PROV_HOST[$name]="$PROVIDER_HOST"
	PROV_XGET[$name]="$PROVIDER_XGET_PREFIX"
	PROV_FREE[$name]="$PROVIDER_FREE"
	PROV_MODEL_LIST[$name]="$PROVIDER_MODEL_LIST"
	PROV_ORDER+=("$name")
}

provider.exists() { [[ -v "PROV_LABEL[$1]" ]]; }

provider.list() { printf '%s\n' "${PROV_ORDER[@]}"; }

provider.label() { printf '%s' "${PROV_LABEL[$1]:-}"; }

# 默认模型：本地缓存 > 脚本兜底（--model 与 <PROVIDER>_IMAGE_MODEL 在入口处理）
provider.default_model() { registry.get "$1" default_model || printf '%s' "${PROV_DEFAULT_MODEL[$1]:-}"; }

provider.default_ref_model() { registry.get "$1" default_ref_model || printf '%s' "${PROV_DEFAULT_REF_MODEL[$1]:-${PROV_DEFAULT_MODEL[$1]:-}}"; }

# provider.cap <name> <key>  → 输出能力值，未声明则返回 1
provider.cap() {
	local caps=" ${PROV_CAPS[$1]:-} " key="$2"
	[[ $caps == *" $key:"* ]] || return 1
	caps="${caps#* "$key":}"
	printf '%s' "${caps%% *}"
}

# 凭证齐全返回 0；PROVIDER_CREDS 为空视为无需凭证
provider.creds_ok() {
	local env_names="${PROV_CREDS[$1]:-}" name
	[[ -z $env_names ]] && return 0
	for name in $env_names; do
		[[ -n ${!name:-} ]] || return 1
	done
	return 0
}

provider.creds_missing() {
	local env_names="${PROV_CREDS[$1]:-}" name out=""
	for name in $env_names; do
		[[ -n ${!name:-} ]] || out+="${out:+, }$name"
	done
	printf '%s' "$out"
}

# 走 XGET 代理时输出代理 URL，否则返回 1（供 base_url/via 共用）
provider._xget_url() {
	local prefix="${PROV_XGET[$1]:-}"
	[[ -n ${XGET_BASE_URL:-} && -n $prefix ]] || return 1
	printf '%s/ip/%s' "$XGET_BASE_URL" "$prefix"
}

provider.base_url() { provider._xget_url "$1" || printf 'https://%s' "${PROV_HOST[$1]}"; }

provider.via() { provider._xget_url "$1" || printf 'direct'; }

# provider.resolve_model <name> <是否参考图> <--model 值> → 输出最终模型 ID
# 优先级：--model > <PROVIDER>_IMAGE_MODEL > 目录/适配器默认
provider.resolve_model() {
	local name="$1" ref="$2" model="$3" env="${1^^}_IMAGE_MODEL"
	model="${model:-${!env:-}}"
	if [[ -n $ref ]]; then
		model="${model:-$(provider.default_ref_model "$name")}"
	else
		model="${model:-$(provider.default_model "$name")}"
	fi
	printf '%s' "$model"
}

provider.endpoint() { "provider_$1_endpoint" "$2"; }
provider.auth() { "provider_$1_auth"; }
provider.body() { "provider_$1_body"; }
provider.parse() { "provider_$1_parse" "$2"; }

# 模型清单：本地目录缓存（种子/远端刷新）> 适配器内置（代码兜底） > 活的 API（最后手段）
provider.models() {
	local name="$1" cached live
	if cached="$(registry.get "$name" models)"; then
		printf '%s\n' $cached
		return 0
	fi
	if [[ -n ${PROV_MODEL_LIST[$name]:-} ]]; then
		printf '%s\n' "${PROV_MODEL_LIST[$name]}"
		return 0
	fi
	if declare -F "provider_${name}_models" > /dev/null; then
		live="$("provider_${name}_models" 2> /dev/null)" || live=""
		[[ -n $live ]] && {
			printf '%s\n' "$live"
			return 0
		}
	fi
	return 1
}

# provider.models_live <name>：强制走活的模型列表 API（维护者/CI 刷新数据用）
provider.models_live() {
	local name="$1" live
	declare -F "provider_${name}_models" > /dev/null || return 1
	live="$("provider_${name}_models")" || return 1
	[[ -n $live ]] || return 1
	printf '%s\n' "$live"
}

# provider.auto_select [需要参考图]  → 免费优先、有凭证、能力匹配的第一个
provider.auto_select() {
	local need_ref="${1:-}" name cap_ref
	local -a free=() paid=()
	for name in "${PROV_ORDER[@]}"; do
		provider.creds_ok "$name" || continue
		if [[ -n $need_ref ]]; then
			cap_ref="$(provider.cap "$name" ref)" || cap_ref=none
			[[ $cap_ref == none ]] && continue
		fi
		if [[ ${PROV_FREE[$name]} == true ]]; then free+=("$name"); else paid+=("$name"); fi
	done
	if ((${#free[@]})); then
		printf '%s' "${free[0]}"
		return 0
	fi
	if ((${#paid[@]})); then
		printf '%s' "${paid[0]}"
		return 0
	fi
	return 1
}
