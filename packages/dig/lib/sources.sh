#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# 源装载表：新增一个源 = 在 lib/ 加一个文件（含 source.register 调用）+ 这里加一行 import。
# 顺序即 source.list() 的顺序。tools/build 靠静态 import 行做内联，所以本表不能改成 glob。

import hn
import github
import so
import arxiv
import zhihu
import weread
import youtube
import bilibili
import v2ex
import polymarket
import openalex
import discourse
import hf
