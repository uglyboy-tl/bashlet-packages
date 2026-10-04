#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

import core/log
import core/config
import ext/requests.cache
import ext/github

# ===== 包目录 (registry) =====
# 远端 TOML 与本地配置同构，仅多一个 description 字段供 search 展示。
# 远端内容不进入运行时配置: search 只在子 shell 中解析, add 经白名单校验后写入本地配置。

declare -ga REGISTRY_FIELDS=(repo version_type file_pattern file_extension binary_name description)

# 包目录地址: 环境变量 > 本地配置；随后按代理前缀改写（GitHub 域名才改写）
registry_source() {
	local url="${BINUP_REGISTRY_URL:-$(config.get registry_url)}"
	github.url.proxied "$url" "${SETTINGS_PROXY_PREFIX:-}"
}

# 保证包目录缓存可用且内容合法；缺 [packages.*] 段视为无效并丢弃缓存
registry_ensure() {
	local url="$1" cache
	cache=$(requests.cache.path "$url")
	requests.cache.ensure "$url" "$2" || return 1
	if ! grep -q '^\[packages\.' "$cache" 2> /dev/null; then
		log.error "包目录内容无效（缺少 [packages.*] 段）: $url"
		rm -f "$cache" "$cache.meta"
		return 1
	fi
	return 0
}

# 在子 shell 中解析缓存, 输出 packages.<名称>.<字段>=<值>, 不污染运行时配置
_registry_dump() {
	local cache="$1" k
	(
		# 必须清空：子 shell 只保证修改不外传，但会继承父进程已加载的本地配置，
		# 不清空则 config.load 是叠加而非替换，本地包会混进目录列表。
		for k in "${!_CONFIG_VALUES[@]}"; do unset "_CONFIG_VALUES[$k]"; done
		for k in "${!_CONFIG_ARRAY_ITEMS[@]}"; do unset "_CONFIG_ARRAY_ITEMS[$k]"; done
		config.load "$cache" || exit 1
		for k in "${!_CONFIG_VALUES[@]}"; do
			[[ $k == packages.* ]] && printf '%s=%s\n' "$k" "${_CONFIG_VALUES[$k]}"
		done
	) | sort
}

# 列出包目录中的全部包名（收包目录 URL，与其他 registry 函数一致）
registry_names() {
	_registry_dump "$(requests.cache.path "$1")" | sed -E 's/^packages\.([^.]+)\..*/\1/' | sort -u
}

# 读取单个字段, 不存在时输出空
registry_get() {
	_registry_dump "$(requests.cache.path "$1")" | awk -F= -v k="packages.$2.$3" '$1 == k { print substr($0, length(k) + 2); exit }'
}

# 拒绝可破坏 TOML 或注入 shell 的字符（含换行/回车，否则会被原样写进 TOML 破坏配置文件）
registry_safe_value() {
	local v="$1" bad=$'"\'`$\\\n\r'
	[[ $v == *["$bad"]* ]] && return 1
	return 0
}
