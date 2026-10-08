#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# Discourse 社区。技术产品/语言/工具的官方论坛几乎都跑 Discourse，它的 /search.json 是
# 开放的、免密钥的 —— 这是 HN / SO 覆盖不到的一整类社区（Python、PyTorch、Rust、OpenAI、
# Hugging Face 等）。默认搜一组精选实例，-s 可换成自己的清单。

import core/log

import common
import fetch
import schema
import source

# 论坛有很长的尾巴，且 Discourse 的 /search.json 无法按时间排序（order 参数无效），
# 所以默认窗口放成一年，否则默认的 pastmonth 会把结果清空。
discourse.options() {
	args.add_options "site" "s" "逗号分隔的实例清单，默认用配置里的一组" "STRING"
}

# 探测默认实例清单里的第一个
discourse.probe() { dig.http.probe "https://${_DIG_DISCOURSE_SITES%%,*}/search.json?q=test"; }

# 从主题 URL 抠出主题号：/t/<slug>/<id> 或 /t/<id>
discourse.url.id() {
	local u="$1"
	if [[ $u =~ /t/[^/]+/([0-9]+) ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi
	if [[ $u =~ /t/([0-9]+) ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

# host 必须命中 _DIG_DISCOURSE_SITES（逐个 fetch.host.any 比对）：全面开放域名会把别人的站当 Discourse
discourse.search() {
	[[ -n $DIG_QUERY ]] || {
		log.error '需要查询词：dig discourse "关键词"'
		return 1
	}

	local sites
	sites="$(dig.opt -s --site)"
	[[ -n $sites ]] || sites="$_DIG_DISCOURSE_SITES"
	[[ -n $sites ]] || {
		log.error "没有可搜的 Discourse 实例：设置 -s 或配置 discourse.sites"
		return 1
	}

	# 用 IFS 切分并加引号：未加引号的 ${sites//,/ } 会把 host 里的 * ? 当 glob 做路径展开
	local -a hosts
	IFS=, read -ra hosts <<< "$sites"
	local host ok=0 out combined=""
	for host in "${hosts[@]}"; do
		host="${host// /}"
		# host 会拼进 URL：手误（如 evil.com/x?）会构造出别的地址，先卡字符集
		[[ $host =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || {
			log.error "-s/--site 需要形如 discuss.python.org 的 host，得到：$host"
			return 1
		}
		if out="$(dig.http.get "https://$host/search.json" "q=$DIG_QUERY")"; then
			combined+="$(printf '%s' "$out" | discourse.map "$host")"$'\n'
			ok=$((ok + 1))
		else
			log.warn "$host 搜索失败，跳过"
		fi
	done

	((ok > 0)) || {
		log.error "所有 Discourse 实例都失败了（网络不通？见 dig doctor）"
		return 1
	}
	printf '%s' "$combined" | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
}

# 单条：<实例>/t/<id>.json 的形状与 search.json 不同，用小 mapper 取标题 / 首帖正文 /
# 创建时间 / 浏览量 / 楼层数；cooked 是 HTML，去标签后进 text。
discourse.map_topic() {
	local host="${1:-}"
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" --arg host "$host" "$_SCHEMA_JQ_LIB"'
    {
      source: "discourse",
      id: ($host + "#" + (.id | tostring)),
      url: ("https://" + $host + "/t/" + (.slug // "topic") + "/" + (.id | tostring)),
      title: (.title // ""),
      text: ((.post_stream.posts[0].cooked // "") | html_text),
      author: (.post_stream.posts[0].username // ""),
      created_at: ((.details.created_at // .created_at // "") | to_utc),
      engagement: ({ replies: ((.posts_count // 0) | if . > 0 then . - 1 else 0 end) }
        + (if (.views // null) != null then { views: .views } else {} end)),
      tags: ([ $host ]
        + [(.tags // [])[]? | if type == "object" then (.name // "") else (. | tostring) end]
        | map(select(. != null and . != ""))),
      query: $query
    }'
}

discourse.search_url() {
	local url="$1" host id body
	host="$(fetch.host "$url")"
	id="$(discourse.url.id "$url")" || {
		log.error "不是合法的 Discourse 主题 URL：$url"
		return 1
	}
	body="$(dig.http.get "https://$host/t/$id.json")" || return 1
	printf '%s' "$body" | discourse.map_topic "$host" | schema.pipe 0 | schema.limit 1
}

# search.json 分成 topics[] 与 posts[]：topics 有标题与 slug，posts 有作者与摘要。
# 用 topic_id 把两者接起来，取该主题第一条帖子的摘要。
discourse.map() {
	local host="${1:-}"
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" --arg host "$host" "$_SCHEMA_JQ_LIB"'
    (.posts // []) as $posts
    | (.topics // [])[]
    | . as $t
    | ($posts | map(select(.topic_id == $t.id)) | first) as $p
    | {
        source: "discourse",
        id: ($host + "#" + ($t.id | tostring)),
        url: ("https://" + $host + "/t/" + ($t.slug // "topic") + "/" + ($t.id | tostring)),
        title: ($t.title // ""),
        text: ($p.blurb // "" | html_text),
        author: ($p.username // ""),
        created_at: (($p.created_at // $t.created_at // "") | to_utc),
        engagement: ({ replies: ($t.reply_count // 0) }
          + (if ($t.views // null) != null then { views: $t.views } else {} end)
          + (if ($t.like_count // null) != null then { likes: $t.like_count } else {} end)),
        tags: ([ $host ] + ($t.tags // []) | map(select(. != null and . != ""))),
        query: $query
      }'
}

# 认领哪些实例由 DIG_DISCOURSE_SITES 决定，所以用函数动态给清单
discourse.url.hosts() {
	local -a sites=()
	[[ -n ${_DIG_DISCOURSE_SITES:-} ]] || return 0
	IFS=, read -ra sites <<< "$_DIG_DISCOURSE_SITES"
	printf '%s\n' "${sites[@]}"
}

source.register discourse "Discourse 社区（Python/PyTorch/Rust/OpenAI/HF 等官方论坛）" "tier:topic period:pastyear proxy:yes key:none"
