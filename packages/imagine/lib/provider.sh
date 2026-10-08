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
#   PROVIDER_HOST / PROVIDER_XGET_PREFIX / PROVIDER_FREE / PROVIDER_MODEL_LIST /
#   PROVIDER_PROBE_PATH
#
# PROVIDER_PROBE_PATH 是「只读探活」端点（相对 PROVIDER_HOST）：`providers` 用它验证 key 是否
# 真的能用，而不是只判断变量存不存在。没有这个声明的适配器在表里显示「没有只读端点」。
# 探活用适配器自己的 provider_<name>_auth 发头，所以探活与生成走同一套认证，不需要单独声明。
#
# PROVIDER_CAPS 是唯一的能力真相，形如 "size:star ref:multi seed:yes negative:no quality:no style:no n:9"。
# size 取 any/star/fixed/aspect/none；ref 取 none/one/multi；其余 yes/no。

import core/log
import ext/requests
import std/fs
import registry

declare -gA PROV_LABEL=() PROV_CREDS=() PROV_DEFAULT_MODEL=() PROV_DEFAULT_REF_MODEL=()
declare -gA PROV_CAPS=() PROV_SIZES=() PROV_HOST=() PROV_XGET=() PROV_FREE=() PROV_MODEL_LIST=()
declare -gA PROV_PROBE=()
declare -ga PROV_ORDER=()

provider.register() {
	local name="$1"
	PROVIDER_LABEL="" PROVIDER_DEFAULT_MODEL="" PROVIDER_DEFAULT_REF_MODEL="" PROVIDER_CAPS=""
	PROVIDER_HOST="" PROVIDER_XGET_PREFIX="" PROVIDER_FREE=false PROVIDER_MODEL_LIST=""
	PROVIDER_PROBE_PATH=""
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
	PROV_PROBE[$name]="$PROVIDER_PROBE_PATH"
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

# ── 只读探活：验证 key 真的能用（不碰生成接口）────────────────────────────────

# provider.probe <name> → 一行 "<状态>\t<说明>"；状态取值见 cmd_providers 的图例。
# 复用 provider.auth / provider.base_url，所以「走没走 XGET」与真实生成时完全一致：
# 探活通过不保证能生成，但探活不通过就一定生成不了。
provider.probe() {
	local name="$1"
	provider.creds_ok "$name" || {
		printf 'missing\t%s' "$(provider.creds_missing "$name")"
		return 0
	}
	local path="${PROV_PROBE[$name]:-}"
	[[ -n $path ]] || {
		printf 'noprobe\t-'
		return 0
	}

	requests.init 2> /dev/null || {
		printf 'noruntime\t缺 curl 或 jq'
		return 0
	}
	# 探活要快：默认 120s 超时下，一家被墙的能拖住整个表。IMAGINE_PROBE_TIMEOUT 可覆盖，
	# 探活是并发跑的所以它只影响最慢的那一家（网络差调大，想快点看到表就调小）。
	# 非法值回退默认：非数字喂给 requests.timeout 会让子 shell 崩，状态落回 unknown 就分不清原因了。
	local probe_timeout="${IMAGINE_PROBE_TIMEOUT:-8}"
	[[ $probe_timeout =~ ^[0-9]+$ ]] || probe_timeout=8
	requests.timeout "$probe_timeout"
	requests.base_url "$(provider.base_url "$name")"
	provider.auth "$name"

	local resp code
	resp="$(requests.get "$path")" || {
		printf 'unreachable\t%s' "$(provider.probe_hint "$name")"
		return 0
	}
	code="$(requests.status_code "$resp")"
	case "$code" in
		2*) printf 'ok\t-' ;;
		401 | 403) printf 'rejected\t-' ;;
		000 | 0) printf 'unreachable\t%s' "$(provider.probe_hint "$name")" ;;
		*) printf 'http\tHTTP %s' "$code" ;;
	esac
}

# 网络不通时的提示：声明了 XGET 前缀的正是墙外那三家（google / openai / openrouter），
# 它们直连本来就不通，所以先问「XGET 配了没」，而不是笼统地说一句网络问题。
provider.probe_hint() {
	if [[ -n ${PROV_XGET[$1]:-} ]]; then
		if [[ -n ${XGET_BASE_URL:-} ]]; then
			printf '不通（已走 XGET，检查 XGET_BASE_URL 本身）'
		else
			printf '不通（这家在墙外，配 XGET_BASE_URL 后重试）'
		fi
	else
		printf '不通'
	fi
}

# 不可用那一行的原因。措辞按「用户下一步做什么」写，而不是复述内部状态码。
provider.probe_reason() { # <状态> <说明>
	case "$1" in
		missing) printf '缺 %s' "$2" ;;
		rejected) printf 'key 被上游拒绝（换一个）' ;;
		unreachable) printf '%s' "$2" ;;
		noprobe) printf '没有只读端点，无法验证（只能试生成）' ;;
		noruntime) printf '%s' "$2" ;;
		unknown) printf '探活没拿到结果（临时目录不可用？）' ;;
		http) printf '%s' "$2" ;;
		*) printf '%s' "$1" ;;
	esac
}

# 并发探活所有凭证齐全的 provider → "<名>\t<状态>\t<说明>"。
# 串行最坏是 N×超时；并发后总耗时约等于最慢的那一家。
# 缺凭证的不探：原因就是 missing，没必要为它打一次网络。
provider.probe_all() {
	local dir name
	dir="$(fs.mktemp -d)" || return 1
	while IFS= read -r name; do
		provider.creds_ok "$name" || continue
		(
			printf '%s\t%s\n' "$name" "$(provider.probe "$name")" > "$dir/$name"
		) &
	done < <(provider.list)
	wait
	# 目录为空（一个凭证都没配）时 cat 会以 1 退出：set -e 下会跳过下面的清理，
	# 所以必须自己吞掉退出码，否则 probe_all 静默返回还泄漏临时目录。
	cat "$dir"/* 2> /dev/null || true
	rm -rf "$dir"
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
