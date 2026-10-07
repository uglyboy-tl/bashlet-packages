#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# Hugging Face。免密钥，但**必须走代理**：直连实测 http=000（SYN 被丢），DNS 解析到
# 31.13.94.7 / 2a03:2880:...:face:b00c（Facebook 段，典型污染）。增量是「这个方向上有什么
# 模型/数据集、下载量与点赞」——
# GitHub star 衡量代码仓库，HF 衡量模型权重与数据集，两者不重合。

import core/log

import common
import schema
import source

# 模型/数据集是长期资产，相关度靠下载量与点赞而不是新鲜度；默认不筛时间
# （用户仍可用 -p pastmonth 只看最近新增/改动的）。
hf.options() {
	args.add_options "type" "T" "models|datasets，默认 models" "STRING"
}

hf.probe() { dig.http.probe "https://huggingface.co/api/models?search=test&limit=1"; }

# 从仓库 URL 抠出 type 与 id：/<o>/<m>、/datasets/<o>/<n>、/spaces/<o>/<n>
hf.url.parse() {
	local url="$1" path type
	path="${url#*://}"
	path="${path#*/}"
	path="${path%%[?#]*}"
	[[ $path == */* ]] || return 1

	type="models"
	case $path in
		datasets/*)
			type="datasets"
			path="${path#datasets/}"
			;;
		spaces/*)
			type="spaces"
			path="${path#spaces/}"
			;;
		models/*)
			type="models"
			path="${path#models/}"
			;;
	esac
	# 只接受 <owner>/<name> 两段（再多是文件树之类的子路径）
	[[ $path =~ ^([^/]+)/([^/]+)$ ]] || return 1
	printf '%s %s' "$type" "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
}

hf.search() {
	[[ -n $DIG_QUERY ]] || {
		log.error '需要查询词：dig hf "模型或数据集关键词"'
		return 1
	}

	local type
	type="$(dig.opt -T --type)"
	type="${type:-models}"
	case $type in
		models | datasets) ;;
		*)
			log.error "未知类型: $type（可选 models / datasets）"
			return 1
			;;
	esac

	local out
	out="$(dig.http.get "https://huggingface.co/api/$type" \
		"search=$DIG_QUERY" \
		"limit=$DIG_LIMIT" \
		"sort=downloads" \
		"direction=-1")" || return 1

	printf '%s' "$out" | hf.map "$type" | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
}

# 单条：/api/{models,datasets,spaces}/<id> 返回单对象，包成数组后过 hf.map
hf.search_url() {
	local url="$1" type id out parsed
	parsed="$(hf.url.parse "$url")" || {
		log.error "不是合法的 Hugging Face 仓库 URL：$url"
		return 1
	}
	read -r type id <<< "$parsed"
	[[ -n $type && -n $id ]] || return 1
	out="$(dig.http.get "https://huggingface.co/api/$type/$id")" || return 1
	printf '%s' "$out" | "$(schema.jq.bin)" -c '[.]' | hf.map "$type" | schema.pipe 0 | schema.limit 1
}

hf.map() {
	local type="${1:-models}"
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" --arg type "$type" "$_SCHEMA_JQ_LIB"'
    .[]
    | {
        source: "hf",
        id: .id,
        url: ("https://huggingface.co/" + $type + "/" + .id),
        title: .id,
        text: ([ .pipeline_tag // empty ] | map(select(. != null and . != "")) | join(" ")),
        author: (.author // (.id | split("/")[0])),
        # 列表接口里 models 没有 lastModified，退回 createdAt；都是「活跃度」而非严格创建时间
        created_at: ((.lastModified // .createdAt // "") | to_utc),
        engagement: { downloads: (.downloads // 0), likes: (.likes // 0) },
        tags: ((.tags // []) | map(select(. != null and . != "")) | .[0:8]),
        query: $query
      }'
}

source.url.register hf huggingface.co
source.register hf "Hugging Face 模型 / 数据集（下载量与点赞）" "tier:topic period:all proxy:yes key:none"
