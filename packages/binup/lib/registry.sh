#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

import core/log
import core/config
import ext/requests.cache
import ext/github

# ===== 包目录 (registry) =====
# 远端 TOML 与本地配置同构，字段全集见 REGISTRY_FIELDS（description 只存在于远端，仅供 search 展示，不写进本地配置）。
# 远端内容不进入运行时配置：search 只读解析结果，add 经白名单校验后才写入本地配置。

declare -ga REGISTRY_FIELDS=(repo version_type file_pattern file_extension binary_name)

# 解析后的包目录：键 packages.<包>.<字段>，值同 dump 输出。
# 缓存原因：_registry_dump 每次都要在子 shell 里跑一轮 config.load（全表逐行解析，30 包约 25ms），
# 而 search/add 会反复取字段（add 每包 5 个字段、search 按包读 repo/description），不缓存即放大成秒级。
declare -gA _REGISTRY_ENTRIES=()
declare -g _REGISTRY_DUMP_URL=""

# 包目录地址: 环境变量 > 本地配置；随后按代理前缀改写（GitHub 域名才改写）
registry_source() {
	local url="${BINUP_REGISTRY_URL:-$(config.get registry_url)}"
	github.url.proxied "$url" "${SETTINGS_PROXY_PREFIX:-}"
}

# 保证包目录缓存可用且内容合法；缺 [packages.*] 段视为无效并丢弃缓存
registry_ensure() {
	local url="$1" cache
	cache=$(requests.cache.path "$url")
	# 回源可能重写缓存文件，先作废已解析的包目录
	_REGISTRY_DUMP_URL=""
	requests.cache.ensure "$url" "$2" || return 1
	if ! grep -q '^\[packages\.' "$cache" 2> /dev/null; then
		log.error "包目录内容无效（缺少 [packages.*] 段）: $url"
		rm -f "$cache" "$cache.meta"
		return 1
	fi
	# 预解析到当前 shell：registry_get/registry_names 的调用点都在 $( )/< <( ) 里，
	# 子 shell 里的首次解析回传不了父进程，不预解析就是每个字段重新解析一遍。
	registry_load "$url" || {
		log.error "包目录解析失败: $url"
		return 1
	}
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

# 解析包目录缓存到 _REGISTRY_ENTRIES，同一 URL 只解析一次
registry_load() {
	local url="$1" line
	[[ $_REGISTRY_DUMP_URL == "$url" ]] && return 0
	_REGISTRY_ENTRIES=()
	while IFS= read -r line; do
		_REGISTRY_ENTRIES["${line%%=*}"]="${line#*=}"
	done < <(_registry_dump "$(requests.cache.path "$url")")
	# 解析出 0 个包视为失败：registry_ensure 已确认缓存里有 [packages.*]，所以这里为空只能是解析挂了。
	# 不记标记也不返回成功，否则一次失败会被永久当成「没有包」缓存住。
	((${#_REGISTRY_ENTRIES[@]})) || return 1
	_REGISTRY_DUMP_URL="$url"
}

# 包名白名单：远端表名会进本地 TOML 的 section 头，含引号/括号等字符会把配置写坏；
# 点号也不行——[packages.foo.bar] 在 TOML 里是嵌套表，拆不出包名
registry.name.valid() { [[ $1 =~ ^[A-Za-z0-9_-]+$ ]]; }

# 列出包目录中的全部包名（收包目录 URL，与其他 registry 函数一致）
# 只认 packages.<名>.<字段> 三段键：名字不合白名单的整条丢弃，
# 不做到第一个点截断，免得 `add foo` 拿到一个没有任何字段的幽灵包
registry_names() {
	registry_load "$1" || return 1
	((${#_REGISTRY_ENTRIES[@]})) || return 0
	local k name
	for k in "${!_REGISTRY_ENTRIES[@]}"; do
		[[ $k =~ ^packages\.(.+)\.[^.]+$ ]] || continue
		name="${BASH_REMATCH[1]}"
		registry.name.valid "$name" || continue
		printf '%s\n' "$name"
	done | sort -u
}

# 读取单个字段, 不存在时输出空
registry_get() {
	registry_load "$1"
	[[ -v "_REGISTRY_ENTRIES[packages.$2.$3]" ]] && printf '%s\n' "${_REGISTRY_ENTRIES[packages.$2.$3]}"
	return 0
}

# 拒绝可破坏 TOML 或注入 shell 的字符（含换行/回车，否则会被原样写进 TOML 破坏配置文件）
registry_safe_value() {
	local v="$1" bad=$'"\'`$\\\n\r'
	[[ $v == *["$bad"]* ]] && return 1
	return 0
}
