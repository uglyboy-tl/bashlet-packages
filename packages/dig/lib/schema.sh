#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# 统一条目 JSONL：构造与校验、URL 规范化、时间窗口、终端渲染。
# 源适配器只负责把站点响应映射成条目对象，其余都走这里。

import core/log
import std/string
import std/system

import parse

# jq 二进制定位归 parse（源适配器与 schema 都要用）
schema.jq.bin() { parse.jq.bin; }

# 公共 jq 函数 = parse 的文本原语（to_utc / html_text / XML 取值）+ 本模块的 norm_url。
# 源适配器统一用 "$_SCHEMA_JQ_LIB"'<program>' 拼程序，所以两边的函数都能用。
read -r -d '' _SCHEMA_JQ_NORM_URL << 'JQ' || true
def norm_url:
  if (. // "") == "" then ""
  else
    ((split("#")[0]) | split("?")) as $p
    | ($p[0]) as $base
    | ($p[1] // "") as $qs
    | ($base | capture("^(?<scheme>[A-Za-z][A-Za-z0-9+.-]*)://(?<host>[^/]*)(?<path>.*)$") // null) as $m
    | (if $m == null then $base
       else (($m.scheme | ascii_downcase) + "://" + ($m.host | ascii_downcase)
             + (if ($m.path | length) > 1 and ($m.path | endswith("/")) then $m.path[0:-1] else $m.path end))
       end) as $norm
    | ($qs | split("&")
           | map(select(length > 0
                        and (test("^(utm_[^=]*|fbclid|gclid|dclid|msclkid|mc_eid|mc_cid|ref|ref_src|spm|share_token|_hsenc|_hsmi|igshid|si)=") | not)))
           | join("&")) as $keep
    | $norm + (if $keep == "" then "" else "?" + $keep end)
  end;
JQ

_SCHEMA_JQ_LIB="$_PARSE_JQ_LIB$_SCHEMA_JQ_NORM_URL"

# 必填字段的唯一定义处。pipe 与校验共用这一个 def（以前两份 jq 程序各写一遍，会漂移）。
read -r -d '' _SCHEMA_JQ_REQUIRED << 'JQ' || true
def require_fields:
  (["source","id","url","title","created_at"]) as $req
  | . as $it
  | ($req | map(. as $k | select($it | has($k) | not))) as $missing
  | if ($missing | length) > 0 then
      error("\($it.source // "?")/\($it.id // "?"): 条目缺少必填字段 \($missing | join(","))")
    else $it end;
JQ

# 校验 + 补 fetched_at + 规范化 URL + 时间窗口过滤
# 无日期或日期无法解析的条目都保留（对应「无日期条目保留而非丢弃」）
read -r -d '' _SCHEMA_JQ_PIPE << 'JQ' || true
require_fields
| .fetched_at //= $now
| .url = (.url | norm_url)
| (.created_at // "") as $ca
| (try ($ca | fromdateiso8601) catch null) as $t
| select(($after == 0) or ($ca == "") or ($t == null) or ($t >= $after))
JQ

read -r -d '' _SCHEMA_JQ_RENDER << 'JQ' || true
# 正文预览：-t/-d/-c/-a 抓进 text 的正文必须在默认输出里看得见（完整正文用 --json）
def text_preview:
  (. // "") | gsub("\\s+"; " ") | sub("^ +"; "") | sub(" +$"; "")
  | if . == "" then "" else "  " + (if length > 200 then "\(.[0:200])…" else . end) + "\n" end;
"\(.title // "(无标题)")\n  "
+ (([ "[" + (.source // "?") + "]",
      (.author // ""),
      ((.engagement // {}) | to_entries
        | map(if (.value | type) == "number" then "\(.value) \(.key)" else "\(.key) \(.value)" end)
        | join(" ")),
      (.created_at // ""),
      (.url // "")
    ] | map(select(. != "")) | join("  ·  ")))
+ "\n"
+ (.text | text_preview)
JQ

schema.now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# epoch -> YYYY-MM-DD（给 gh 一类只认日期的接口）
schema.epoch.date() {
	if date -u -d "@$1" +%F 2> /dev/null; then return 0; fi
	date -u -r "$1" +%F
}

# 时间窗口名 -> 起始 epoch（计算窗口起点；all 返回 0）
schema.period.after() {
	local p="${1:-all}"
	local now
	now="$(date -u +%s)"
	case $p in
		last24h | pastday) echo $((now - 86400)) ;;
		pastweek | lastweek) echo $((now - 604800)) ;;
		pastmonth | lastmonth) echo $((now - 2592000)) ;;
		pastyear | lastyear) echo $((now - 31536000)) ;;
		all) echo 0 ;;
		*)
			log.error "未知时间窗口: $p（可选 last24h / pastweek / pastmonth / pastyear / all）"
			return 1
			;;
	esac
}

schema.url.normalize() {
	"$(schema.jq.bin)" -rn --arg u "${1:-}" "$_SCHEMA_JQ_LIB"'$u | norm_url'
}

# 带时区偏移的 RFC3339 -> UTC Z；解析不了时原样返回
schema.to_utc() {
	"$(schema.jq.bin)" -rn --arg d "${1:-}" "$_SCHEMA_JQ_LIB"'$d | to_utc'
}

# 粗粒度 HTML -> 纯文本（去标签、解常见实体、压空白）
schema.html_text() {
	"$(schema.jq.bin)" -rn --arg t "${1:-}" "$_SCHEMA_JQ_LIB"'$t | html_text'
}

# stdin: 条目对象流 -> stdout: 规范化后的 JSONL
schema.pipe() {
	local after="${1:-0}"
	"$(schema.jq.bin)" -c --arg now "$(schema.now)" --argjson after "$after" \
		"$_SCHEMA_JQ_LIB$_SCHEMA_JQ_REQUIRED$_SCHEMA_JQ_PIPE"
}

# stdin: JSONL -> 打印前 N 条（N<=0 全出；读完 stdin 以免上游 SIGPIPE）
schema.limit() {
	local n="${1:-0}" i=0 line
	while IFS= read -r line; do
		if ((n <= 0 || i < n)); then
			printf '%s\n' "$line"
		fi
		i=$((i + 1))
	done
}

# stdin: JSONL -> 前 N 行交给回调富化，其余原样透传。
# 回调签名 <回调> <行> <序号> [额外参数...]，应输出一行 JSONL。
# 回调失败或没输出时**保留原行**（不能用空串把上游的行吞掉），也不中断整条流。
schema.enrich() {
	local n="${1:-0}" fn="$2"
	shift 2
	local i=0 line out
	while IFS= read -r line; do
		i=$((i + 1))
		if ((i <= n)); then
			if out="$("$fn" "$line" "$i" "$@")" && [[ -n $out ]]; then
				line="$out"
			fi
		fi
		printf '%s\n' "$line"
	done
}

schema.render() { "$(schema.jq.bin)" -r "$_SCHEMA_JQ_RENDER"; }

schema.output() {
	if [[ ${DIG_JSON:-false} == true ]]; then
		cat
	else
		schema.render
	fi
}
