#!/usr/bin/env bash
# shellcheck disable=SC2016

# dig fetch：给一个 URL，判断它属于哪个源，再交给那个源取这一条。
#
# 和检索互补：`dig <源> "<词>"` 是手上没有 URL、去源里找；`dig fetch <url>` 是已经有 URL、
# 把这一条取全（正文 / 评论树 / 结构化字段）。所以这里**只做「host → 源」的路由**，不含任何站点知识：
# URL 长什么样、该打哪个接口，都由各源自己回答，与它的 map / 取数函数放在同一个文件。
#
# 路由表是数据，不是代码：源用 source.url.register <源> <host...> 声明自己认领哪些 host
# （多实例的源改写 <源>.url.hosts 函数动态给，如 discourse 的配置实例列表）。
# URL 形式的校验不在这里做——交给该源的 search_url，它本来就要抠 id，报错也更具体。
#
# 参数回传用「源名 + 该源自己的参数」而不是「源名 + id」：URL → id 的抠取与用法同属一个文件。

import core/log
import std/cache

import browser
import common
import schema
import source

# URL → 小写 host：去掉 scheme / userinfo / 端口。没有 scheme 的裸域名也接受（粘贴常见）
fetch.host() {
	local h="${1#*://}"
	# 第一个 / ? # 之前都是 host（URL 可以没有路径，直接跟 query 或 fragment）
	h="${h%%[/?#]*}"
	h="${h##*@}"
	h="${h%%:*}"
	printf '%s' "${h,,}"
}

# fetch.host.any <url> <host...>：host 等于候选之一、或是候选的子域（www. / old. / m.）→ 0
fetch.host.any() {
	local url="$1" host h
	shift
	host="$(fetch.host "$url")"
	for h in "$@"; do
		if [[ $host == "$h" || $host == *".$h" ]]; then
			return 0
		fi
	done
	return 1
}

# fetch.route <url> → stdout 打印 "<源> -u <url>"；认不出返回 1
fetch.route() {
	local url="$1" src host
	while IFS= read -r src; do
		if declare -F "${src}.url.hosts" > /dev/null 2>&1; then
			# 动态清单（discourse 的多实例）：一行一个 host
			while IFS= read -r host; do
				if [[ -n $host ]] && fetch.host.any "$url" "$host"; then
					# tab 分隔：URL 可能含空格或 *，空格分隔会被切错、* 还会被当 glob
					printf '%s\t-u\t%s' "$src" "$url"
					return 0
				fi
			done < <("${src}.url.hosts")
			continue
		fi
		for host in $(source.url.hosts "$src"); do
			if fetch.host.any "$url" "$host"; then
				printf '%s\t-u\t%s' "$src" "$url"
				return 0
			fi
		done
	done < <(source.list)
	return 1
}

# ── 兜底：认不出 host 时用云端浏览器取一页 ─────────────────────────────────────
# 默认关：dig 的定位是「按站点取数」，不是通用抓取器——「取不到就取不到」。
# 开了（DIG_FETCH_FALLBACK=1）才有这个能力，且只走云端浏览器，不做别的猜测。
fetch.fallback.enabled() {
	case "${DIG_FETCH_FALLBACK:-}" in
		"" | 0 | false | no | off) return 1 ;;
		*) return 0 ;;
	esac
}

fetch.fallback.item() {
	local url="$1"
	browser.page "$url" | "$(schema.jq.bin)" -c --arg url "$url" '
    {
        source: "browser",
        id: $url,
        url: $url,
        title: (.title // ""),
        text: (.text // ""),
        author: (.author // ""),
        created_at: "",
        engagement: {},
        tags: [],
        query: ""
      }'
}

# 与源一样过结果缓存：同一个 URL 重复取不打第二次云端浏览器（免费档 6 次/分钟）
fetch.fallback() {
	local url="$1"
	dig.cached "$(cache.key webfallback "$url")" -- fetch.fallback.item "$url"
}
