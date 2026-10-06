#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# OpenAlex：学术文献，免密钥、免代理，覆盖率比 arXiv 大（含期刊、会议）。
# 增量：被引数（论文热度）与摘要；arXiv 只有预印本。

import core/log

import common
import schema
import source

# 学术文献看被引数而非新鲜度：相关度排在前面的往往是老论文，套时间窗口会把结果清空，
# 所以默认不筛时间（用户可以用 -p 自己收紧）。
openalex.probe() { dig.http.probe "https://api.openalex.org/works?search=test&per-page=1"; }

openalex.search() {
	[[ -n $DIG_QUERY ]] || {
		log.error '需要查询词：dig openalex "主题"'
		return 1
	}

	# 匿名搜索会被下游限流（503 "Anonymous search is paused"）；
	# 带上 mailto 进 polite pool，或用免费 API key 换稳定额度。
	# key 走 Authorization 头（官方文档说与 query 参数等价）：放进 URL 会被重试/失败日志原样打出来
	[[ -n ${OPENALEX_API_KEY:-} ]] && dig.auth.set "Bearer $OPENALEX_API_KEY"

	local -a params=("search=$DIG_QUERY" "per-page=$(dig.clamp "$DIG_LIMIT" 100 "OpenAlex")" "sort=relevance_score:desc")
	[[ -n ${OPENALEX_MAILTO:-} ]] && params+=("mailto=$OPENALEX_MAILTO")

	local out
	if ! out="$(dig.http.get "https://api.openalex.org/works" "${params[@]}")"; then
		# 只有真是限流才补这条提示；网络不通/其它 4xx 的具体原因底层已经报过了
		case "$(dig.http.status)" in
			429 | 503)
				log.error "OpenAlex 匿名访问被限流（HTTP $(dig.http.status)）：去 openalex.org 免费申请 API key 后设 OPENALEX_API_KEY；退一步设 OPENALEX_MAILTO 进 polite pool"
				;;
		esac
		return 1
	fi
	printf '%s' "$out" | openalex.map | schema.pipe "$DIG_AFTER" | schema.limit "$DIG_LIMIT"
}

openalex.map() {
	"$(schema.jq.bin)" -c --arg query "${DIG_QUERY:-}" '
    # 摘要在 OpenAlex 里是倒排索引，按位置还原成正文
    def abstract:
      .abstract_inverted_index as $ix
      | if $ix == null then ""
        else [ $ix | to_entries[] as $w | $w.value[] | { p: ., w: $w.key } ]
             | sort_by(.p) | map(.w) | join(" ")
        end;
    .results[]?
    | {
        source: "openalex",
        id: (.id // .doi // ""),
        url: (.primary_location.landing_page_url // .doi // ""),
        title: (.display_name // ""),
        text: (abstract | .[0:1200]),
        author: ([.authorships[0:3][].author.display_name] | join(", ")),
        created_at: ((.publication_date // "")
          | if length == 10 then . + "T00:00:00Z" else . end),
        engagement: { cited: (.cited_by_count // 0) },
        tags: ([.primary_location.source.display_name // empty]
               + [.type_crossref // empty] | map(select(. != null and . != ""))),
        query: $query
      }'
}

source.register openalex "OpenAlex 学术文献（含被引数与摘要）" "tier:topic period:all proxy:no key:optional" "" "OPENALEX_API_KEY"
