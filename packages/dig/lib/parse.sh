#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# 从「非 JSON 文本」里取出结构的唯一入口：内嵌 JSON、XML/HTML 标签取值、纯文本清理。
# 纯文本处理，不触网。
#
# 为什么要单独一个模块：源适配器里有三处得从 HTML/XML 里抠数据（arXiv 的 Atom、
# YouTube watch 页里的 ytInitialPlayerResponse、B 站弹幕 XML）。散在三个文件里时，
# 每处都要自己处理换行、实体、属性与分隔符，同一个坑要踩三遍。收到这里之后，
# 「换语言」的成本也只需要重写这一个文件。
#
# 依赖方向：parse 只依赖 std/system 与 core/log；schema 反过来 import parse
# （schema 的数据模型要用这里的 html_text / to_utc），不会成环。
#
# 【将来提升到 bashlet 的目标层】：**ext/parse，不是 std/parse**。
# 因为 parse.xml.records 与 _PARSE_JQ_LIB 都依赖 jq，而 bashlet 按依赖重量分层：
# std/ 只放 coreutils 类（tar/sed/base64…），jq 与 curl/fzf 同属 ext/（README：
# 「ext/ 可选重能力」+「HTTP / SSE — 基于 curl + jq 的请求封装」）。
# 只有 parse.json.embedded 是 jq-free（tr + awk），但它与 XML 部分是一个整体，
# 一个消费者不值得再拆。
# jq 定位归 bashlet 的 ext/json（import 时探活并缓存路径，重复定位只有那一份），
# 这里只留给 jq 程序用的文本原语。

import core/log
import ext/json

read -r -d '' _PARSE_XML_RECORDS_JQ << 'JQ' || true
    ($spec | split(",")) as $fields
    | [ match("(?s)<" + $tag + "(?<attrs>[^>]*)>(?<body>.*?)</" + $tag + ">"; "g") ]
    | .[]
    | { attrs: .captures[0].string, body: .captures[1].string } as $rec
    | [ $fields[] as $f
        | if ($f | startswith("#")) then ($rec.body | xml_flat)
          elif ($f | startswith("@")) then xml_attr($rec.attrs; $f[1:])
          elif ($f | startswith("*")) then xml_many($rec.body; $f[1:])
          else xml_one($rec.body; $f)
          end ]
    | @tsv
JQ

# 给 jq 程序用的文本原语。schema.sh 会把它接在自己的 norm_url 前面，组成 _SCHEMA_JQ_LIB。
read -r -d '' _PARSE_JQ_LIB << 'JQ' || true
# 带时区偏移的 RFC3339 -> UTC Z（YouTube 的 publishDate 是 -07:00 这种）
# 解析不了的日期原样返回，让 schema.pipe 把它当「无日期」保留而不是丢弃。
def to_utc:
  if type != "string" then . else
    sub("\\.[0-9]+"; "") as $s   # 先去掉毫秒（可能在 Z 前或偏移前）
    | if ($s | test("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}[+-]\\d{2}:\\d{2}$")) then
        ($s | capture("^(?<d>.{19})(?<sign>[+-])(?<h>\\d{2}):(?<m>\\d{2})$")) as $c
        | ((($c.d + "Z") | fromdateiso8601)
           - (if $c.sign == "+" then 1 else -1 end)
             * ((($c.h | tonumber) * 3600) + (($c.m | tonumber) * 60))
           | todateiso8601)
      else $s end
  end;

# 粗粒度 HTML -> 纯文本：去标签、解常见实体、压空白。
# HN 评论、SO 正文、B 站简介都是 HTML，agent 读纯文本更省 token 也更不容易误读。
def html_text:
  gsub("<[^>]*>"; " ")
  | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&quot;"; "\"")
  | gsub("&#x27;"; "'") | gsub("&#39;"; "'") | gsub("&amp;"; "&")
  | gsub("&nbsp;"; " ") | gsub("&#x2F;"; "/") | gsub("&#x3D;"; "=")
  | gsub("[ \t\r]+"; " ") | gsub("\n{2,}"; "\n")
  | gsub(" +(?<p>[,.!?;:'])"; "\(.p)")
  | sub("^ +"; "") | sub(" +$"; "");

# XML 值：压平空白 + 解实体（不剥标签 —— 记录本身可能还含子元素）
def xml_flat:
  gsub("[ \t\r\n]+"; " ")
  | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&quot;"; "\"")
  | gsub("&#39;"; "'") | gsub("&amp;"; "&")
  | sub("^ +"; "") | sub(" +$"; "");

# 注意：jq 的 match / capture 在**不匹配时返回 empty，而不是报错**，try/catch 兜不住——
# `(try capture(..) catch null) as $m` 会让整段变成 empty（调用方的那个字段甚至整行消失）。
# 所以统一「先 test 再 capture」，缺字段时明确给空串。
def xml_one($body; $tag):
  if ($body | test("(?s)<" + $tag + "[^>]*>")) then
    ($body | capture("(?s)<" + $tag + "[^>]*>(?<v>.*?)</" + $tag + ">") | .v | xml_flat)
  else "" end;

def xml_many($body; $tag):
  [ ($body | [match("(?s)<" + $tag + "[^>]*>(?<v>.*?)</" + $tag + ">"; "g")] | .[].captures[0].string | xml_flat) ]
  | join(", ");

def xml_attr($attrs; $name):
  if ($attrs | test("(?:^|\\s)" + $name + "=[\"']")) then
    ($attrs | capture("(?:^|\\s)" + $name + "=[\"'](?<v>[^\"']*)") | .v)
  else "" end;
JQ

# 从 HTML/JS 文本里抠出 `var NAME = {...}` 那个对象。
# stdin: 文本（多行也行）→ stdout: JSON 对象；抠不到时不输出并返回 1。
#
# 用 awk 做花括号配对，而不是正则找「结尾分隔符」—— 页面里那段 JSON 后面接什么
# 千奇百怪（YouTube 是 `;var meta = ...`，有些是 `;</script>`），正则一定会抓多或抓少。
# 配对时正确跳过字符串与转义，所以值里出现花括号也不会算错。
parse.json.embedded() {
	local name="${1:-}"
	[[ -n $name ]] || {
		log.error "parse.json.embedded 需要变量名"
		return 1
	}

	tr -d '\n' | awk -v name="$name" '
	{
		needle = name " = {"
		p = index($0, needle)
		if (p == 0) { exit 1 }

		start = p + length(needle) - 1
		n = length($0)
		depth = 0; instr = 0; esc = 0
		for (i = start; i <= n; i++) {
			c = substr($0, i, 1)
			if (instr) {
				if (esc) { esc = 0 }
				else if (c == "\\") { esc = 1 }
				else if (c == "\"") { instr = 0 }
				continue
			}
			if (c == "\"") { instr = 1; continue }
			if (c == "{") { depth++ }
			else if (c == "}") {
				depth--
				if (depth == 0) { print substr($0, start, i - start + 1); exit 0 }
			}
		}
		exit 1
	}'
}

# 只覆盖非空字段：抓不到内容时用空串赋值会把上游填好的值清掉，所以「值为空 = 不动这一项」。
# 用法：parse.json.patch <JSONL 行> [键=值 ...]；值里可以含 =（按第一个 = 切分）。
parse.json.patch() {
	local line="$1"
	shift
	local -a jq_args=()
	local filter="." kv k v
	for kv in "$@"; do
		[[ $kv == *=* ]] || continue
		k="${kv%%=*}"
		v="${kv#*=}"
		[[ -n $v ]] || continue
		jq_args+=(--arg "$k" "$v")
		filter+=" | .$k = \$$k"
	done
	printf '%s' "$line" | json.run -c "${jq_args[@]}" "$filter"
}

# XML -> TSV：按记录标签切开，一条记录一行，字段用 \t 分隔。
#   parse.xml.records <记录标签> <字段spec> < xml
#
# 字段 spec（逗号分隔）：
#   tag    该标签的内容（首条）
#   *tag   该标签的全部内容，用 ", " 连接
#   @attr  记录标签自身的属性
#   #      记录自身的文本内容
#
# 例：parse.xml.records entry 'published,id,title,summary,*name'   # arXiv Atom
# 例：parse.xml.records d '#'                                       # B 站弹幕
parse.xml.records() {
	local tag="${1:-}" fields="${2:-}"
	[[ -n $tag && -n $fields ]] || {
		log.error "parse.xml.records 需要 <记录标签> <字段spec>"
		return 1
	}

	json.run -R -s -r --arg tag "$tag" --arg spec "$fields" "$_PARSE_JQ_LIB$_PARSE_XML_RECORDS_JQ"
}
