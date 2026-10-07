#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# 源装载表：新增一个源 = 在 lib/sources/ 加一个文件（含 source.register 调用）+ 这里加一行 import。
# 顺序即 source.list() 的顺序。tools/build 靠静态 import 行做内联，所以本表不能改成 glob。

import sources/hn
import sources/github
import sources/so
import sources/arxiv
import sources/zhihu
import sources/weread
import sources/youtube
import sources/bilibili
import sources/v2ex
import sources/polymarket
import sources/openalex
import sources/discourse
import sources/hf
import sources/reddit
import sources/wechat
