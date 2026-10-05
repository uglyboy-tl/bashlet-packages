#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016
# 模型目录（registry）：本地缓存优先，远端异步刷新。
#
#   读路径（前台，永不联网）：缓存不存在 → 用适配器兜底生成种子 → 读缓存
#   刷新路径（后台，失败无影响）：缓存过期 → 拉远端 → 校验 → 原子替换
#
# registry.toml 的字段：default_model / default_ref_model / models（空格分隔）。
# 能力声明（PROVIDER_CAPS）不在这里，那是适配器职责。

import core/log
import core/config
import ext/requests
import ext/requests.cache

: "${IMAGINE_REGISTRY_URL:=https://github.com/uglyboy-tl/bashlet-packages/raw/HEAD/packages/imagine/registry.toml}"
: "${IMAGINE_REGISTRY_TTL_HOURS:=24}"
: "${IMAGINE_REGISTRY_OFF:=}"

declare -gA _REGISTRY=()
declare -g _REGISTRY_LOADED=false

registry.cache() { requests.cache.path "$IMAGINE_REGISTRY_URL"; }
registry.meta() { printf '%s.meta' "$(registry.cache)"; }
registry.attempt_marker() { printf '%s.attempt' "$(registry.cache)"; }
registry.lock_dir() { printf '%s.lock' "$(registry.cache)"; }
registry.log() { printf '%s.log' "$(registry.cache)"; }
registry.ttl_seconds() {
	local hours="${IMAGINE_REGISTRY_TTL_HOURS:-24}"
	[[ $hours =~ ^[0-9]+$ ]] || hours=24
	printf '%s' "$((hours * 3600))"
}

# ---- 解析：子 shell 里用 core/config loose 读缓存，结果缓存进 _REGISTRY ----

registry.dump() {
	local cache
	cache="$(registry.cache)"
	[[ -f $cache ]] || return 1
	(
		local k
		# 先清空：子 shell 会继承父进程已加载的配置
		if ((${#_CONFIG_VALUES[@]})); then
			for k in "${!_CONFIG_VALUES[@]}"; do unset "_CONFIG_VALUES[$k]"; done
		fi
		if ((${#_CONFIG_ARRAY_ITEMS[@]})); then
			for k in "${!_CONFIG_ARRAY_ITEMS[@]}"; do unset "_CONFIG_ARRAY_ITEMS[$k]"; done
		fi
		config.loose
		config.load "$cache" || exit 1
		for k in "${!_CONFIG_VALUES[@]}"; do
			[[ $k == providers.* ]] && printf '%s=%s\n' "$k" "${_CONFIG_VALUES[$k]}"
		done
	) | sort
}

registry._load() {
	[[ $_REGISTRY_LOADED == true ]] && return 0
	_REGISTRY=()
	local line key value
	while IFS='=' read -r key value; do
		[[ -n $key ]] && _REGISTRY["$key"]="$value"
	done < <(registry.dump)
	_REGISTRY_LOADED=true
	[[ ${#_REGISTRY[@]} -gt 0 ]]
}

registry.reload() {
	_REGISTRY_LOADED=false
	registry._load
}

# registry.get <provider> <field> → 输出值；未收录返回 1
registry.get() {
	registry._load || return 1
	[[ -v "_REGISTRY[providers.$1.$2]" ]] || return 1
	printf '%s' "${_REGISTRY["providers.$1.$2"]}"
}

# 把适配器里的默认模型/静态清单渲染成与远端同构的 TOML，作为第一份缓存
registry.seed() {
	[[ -v PROV_ORDER ]] || return 1 # provider 模块未加载时不可用
	local cache tmp name model ref models
	cache="$(registry.cache)"
	tmp="$cache.tmp"
	mkdir -p "${cache%/*}" || return 1
	{
		printf '# imagine 模型目录（内置种子，等待远端刷新覆盖）\n'
		for name in "${PROV_ORDER[@]}"; do
			printf '\n[providers.%s]\n' "$name"
			model="${PROV_DEFAULT_MODEL[$name]:-}"
			ref="${PROV_DEFAULT_REF_MODEL[$name]:-}"
			models="${PROV_MODEL_LIST[$name]:-}"
			[[ -n $model ]] && printf 'default_model = "%s"\n' "$model"
			[[ -n $ref ]] && printf 'default_ref_model = "%s"\n' "$ref"
			[[ -n $models ]] && printf 'models = "%s"\n' "${models//$'\n'/ }"
		done
	} > "$tmp" || return 1
	[[ -s $tmp ]] || {
		rm -f "$tmp"
		return 1
	}
	mv "$tmp" "$cache"
	printf 'source=seed\n' > "$(registry.meta)"
	_REGISTRY_LOADED=false
}

registry.seed_if_missing() {
	local cache
	cache="$(registry.cache)"
	[[ -s $cache ]] || registry.seed
}

# 以「上次尝试回源」的时间算 TTL：种子不写该标记，所以首次运行必拉一次远端
registry.is_fresh() { requests.cache.fresh "$(registry.attempt_marker)" "$(registry.ttl_seconds)"; }

# 前台调用：保证有数据，过期则起后台刷新（不等待）
registry.ensure() {
	registry.seed_if_missing || return 1
	registry.refresh_background
	return 0
}

registry.refresh_background() {
	[[ -n ${IMAGINE_REGISTRY_OFF:-} ]] && return 0
	registry.is_fresh && return 0
	local logf
	logf="$(registry.log)"
	# 日志不无限增长：超过 1MB 就截断
	if [[ -f $logf ]] && (($(wc -c < "$logf" 2> /dev/null || echo 0) > 1048576)); then
		: > "$logf"
	fi
	(registry._refresh) >> "$logf" 2>&1 &
	disown 2> /dev/null || true
	return 0
}

registry._refresh() {
	registry.lock || return 0
	trap 'rmdir "$(registry.lock_dir)" 2> /dev/null || true' EXIT
	registry.try_fetch || true
}

# 一次刷新尝试（不论成败都记录时间，避免离线时每次都重试）
registry.try_fetch() {
	local rc=0
	registry.fetch || rc=$?
	touch "$(registry.attempt_marker)"
	return "$rc"
}

# mkdir 原子锁；陈旧锁（>5 分钟）可抢
registry.lock() {
	local dir mtime now
	dir="$(registry.lock_dir)"
	mkdir "$dir" 2> /dev/null && return 0
	mtime=$(stat -c %Y "$dir" 2> /dev/null) || mtime=$(stat -f %m "$dir" 2> /dev/null) || return 1
	now=$(date +%s)
	((now - mtime > 300)) || return 1
	rmdir "$dir" 2> /dev/null
	mkdir "$dir" 2> /dev/null
}

registry.unlock() { rmdir "$(registry.lock_dir)" 2> /dev/null || true; }

# 拉远端：带验证器条件请求，校验形状后才原子替换；失败不触碰已有缓存
registry.fetch() {
	local cache tmp meta response code
	cache="$(registry.cache)"
	tmp="$cache.tmp"
	meta="$(registry.meta)"
	mkdir -p "${cache%/*}" || return 1

	requests.init "-L"
	if [[ -f $meta ]]; then
		local etag modified
		etag=$(sed -n 's/^etag=//p' "$meta")
		modified=$(sed -n 's/^last-modified=//p' "$meta")
		[[ -n $etag ]] && requests.headers.append "If-None-Match" "$etag"
		[[ -z $etag && -n $modified ]] && requests.headers.append "If-Modified-Since" "$modified"
	fi

	response=$(requests.get "$IMAGINE_REGISTRY_URL") || return 1
	code=$(requests.status_code "$response")

	if [[ $code == 304 ]]; then
		touch "$cache"
		log.info "模型目录远端未变更 (304)"
		return 0
	fi
	[[ $(requests.success "$response") == true ]] || return 1

	requests.text "$response" > "$tmp" || return 1
	if ! grep -q '^\[providers\.' "$tmp"; then
		log.error "模型目录内容无效（缺少 [providers.]）: $IMAGINE_REGISTRY_URL"
		rm -f "$tmp"
		return 1
	fi

	mv "$tmp" "$cache"
	{
		printf 'source=remote\n'
		printf 'etag=%s\n' "$(requests.headers "$response" "ETag")"
		printf 'last-modified=%s\n' "$(requests.headers "$response" "Last-Modified")"
	} > "$meta"
	_REGISTRY_LOADED=false
	log.info "模型目录已更新: $cache"
	return 0
}

# 打印两次 dump 的差异
registry.print_diff() {
	local old="$1" new="$2" name od nd om nm added removed
	if [[ $old == "$new" ]]; then
		log.success "模型目录无变化"
		return 0
	fi
	for name in "${PROV_ORDER[@]}"; do
		od="$(registry._field "$old" "$name" default_model)"
		nd="$(registry._field "$new" "$name" default_model)"
		[[ $od != "$nd" ]] && printf '  %-10s default: %s -> %s\n' "$name" "${od:-?}" "${nd:-?}"
		om="$(registry._field "$old" "$name" models)"
		nm="$(registry._field "$new" "$name" models)"
		if [[ $om != "$nm" ]]; then
			added="$(comm -13 <(printf '%s\n' $om | sort -u) <(printf '%s\n' $nm | sort -u) | tr '\n' ' ')"
			removed="$(comm -23 <(printf '%s\n' $om | sort -u) <(printf '%s\n' $nm | sort -u) | tr '\n' ' ')"
			[[ -n $added ]] && printf '  %-10s models: + %s\n' "$name" "$added"
			[[ -n $removed ]] && printf '  %-10s models: - %s\n' "$name" "$removed"
		fi
	done
	return 0
}

registry._field() {
	printf '%s\n' "$1" | awk -F= -v k="providers.$2.$3" '$1 == k { print substr($0, length(k) + 2); exit }'
}
