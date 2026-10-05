#!/usr/bin/env bash
# provider 适配器装载表：新增一家 = 在 lib/providers/ 加一个文件 + 这里加一行 import。
# 顺序即注册顺序，也决定 auto_select 在同等条件下（同为免费/付费）的优先级。

import provider

import providers/agnes
import providers/cloudflare
import providers/google
import providers/dashscope
import providers/doubao
import providers/minimax
import providers/openai
import providers/openrouter
import providers/zai
