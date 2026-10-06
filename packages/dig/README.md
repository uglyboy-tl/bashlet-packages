# dig

按站点取数的工具箱 —— 给一批有价值的站点各写一个适配器，把那个站点上「用关键词能捞到
的东西」（帖子、正文、评论、热度、时间）以统一结构吐出来。

**不是通用搜索引擎**。排序与解读留给调用者；dig 只负责取准、取全、说清哪里取不到。
不做跨源融合（实测重复率为 0，见 `docs/design.md`）。

## 用法

```bash
dig hn "bash 数组"       # Hacker News（-T comments 搜评论语料，-c N 抓评论树）
dig github "timefmt" -T repos   # GitHub（-T issues|repos|code|commits|discussions，走 gh）
dig so "bash array slice" -s unix -a 2   # Stack Exchange（-s 换站点，-a N 抓高赞回答）
dig discourse "typing"  # 官方论坛（Python/PyTorch/Rust/OpenAI/HF 等）
dig arxiv "retrieval eval"
dig openalex "RAG"      # 学术文献 + 被引数
dig hf "reranker"       # Hugging Face 模型（-T datasets 换数据集）
dig zhihu "..."          # 知乎官方开放平台；-H 热榜
dig weread "三体"        # 微信读书书目（需 WEREAD_API_KEY）
dig youtube "rust async" -t 3   # YouTube 搜索，-t 补精确发布日与简介（需代理）
dig bilibili "bash 教程" -d 2   # B 站视频 + 弹幕（弹幕免登录）
dig bilibili "bash 教程" -t 3   # B 站字幕全文稿（需 BILI_SESSDATA）
dig v2ex "Claude"       # V2EX（需代理）
dig polymarket "election"  # 预测市场赔率（需代理）
dig doctor               # 探活：哪个源缺密钥 / 缺代理 / 缺外部命令
dig sources              # 每个源的说明 / 凭证 / 依赖 / 能力
```

网络层带重试：传输层失败与 429/5xx 会退避重试（`DIG_RETRY`，默认 2 次），其余 4xx 直接报错。

公共参数：`-n/--limit`、`-p/--period`、`--json`（JSONL）、`-o/--output`。

代理：`DIG_PROXY` 环境变量 > `~/.config/dig/config.toml` 的 `proxy.url` > `https_proxy`。
youtube / v2ex / polymarket / discourse / hf 必须走代理。

登录态：目前只有 B 站字幕需要，用 `BILI_SESSDATA` 环境变量提供（dig 不抓浏览器 cookie）。
匿名实测 0/10 视频可得字幕，带 SESSDATA 则 10/10。

## 文档

| 文件 | 内容 |
| --- | --- |
| `SKILL.md` | agent 调研方法论（脚本 `scripts/dig`）：给定话题怎么选源、怎么下词、怎么判读证据 |
| `docs/design.md` | 定位、CLI 形态、条目 schema、源适配器契约、代理要求、为什么不做跨源融合 |
| `docs/sources.md` | **接线前必读**：源优先级、端点速查、本机可达性实测、中文站点结论、已知坑 |
| `docs/candidates.md` | 未接线候选的完整方案（X 的 queryId 刷新算法、Reddit OAuth、Bluesky、招聘板）与否决理由 |

## 开发

```bash
tools/test dig        # 只跑这个包
tools/build dig       # 产出 packages/dig/build/dig
```
