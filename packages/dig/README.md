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
dig weread "三体" -i 2     # 微信读书书目（`-i 2` 为前 2 本补简介；需 WEREAD_API_KEY）
dig youtube "rust async" -t 3   # YouTube 搜索，-t 补精确发布日与简介（需代理）
dig bilibili "bash 教程" -d 2   # B 站视频 + 弹幕（弹幕免登录）
dig bilibili "bash 教程" -t 3   # B 站字幕全文稿（需 BILI_SESSDATA）
dig v2ex "Claude"       # V2EX（需代理）
dig reddit -s linux "bash"   # Reddit 某个 sub 内搜索（-r N 抓嵌套评论树）
dig polymarket "election"  # 预测市场赔率（需代理）
dig fetch <url>          # 已有链接：自动判断属于哪个源并取这一条
dig fetch <公众号链接>     # 公众号正文（走云端浏览器，需 CLOUDFLARE_* 凭证）
dig v2ex -u <主题链接>     # 主题 + 回复（本机直连 v2ex 不通，走云端浏览器）
dig doctor               # 探活：哪个源缺密钥 / 缺代理 / 缺外部命令
```

网络层带重试：传输层失败与 429/5xx 会退避重试（`DIG_RETRY`，默认 2 次），其余 4xx 直接报错。

公共参数：`-n/--limit`、`-p/--period`、`--json`（JSONL，含完整正文）、`-o/--output`、`--no-cache`
（默认按天缓存结果，重复查询不再打上游）。
默认输出每条带一行正文预览（200 字，压缩空白）——`-t/-d/-c/-a` 抓进的正文不会你看不见。

已有链接不用再搜：`dig fetch <url>` 判断它属于哪个源并取这一条 —— 支持 `hn` / `github` / `so` / `arxiv` /
`openalex` / `reddit` / `bilibili` / `discourse` / `hf` / `polymarket` / `wechat` / `v2ex`。URL 必须是第一个实参，
它之后的选项原样转给那个源（如 `dig fetch <reddit 链接> -r 3`）；其余 URL 会明确报「认不出」。

代理：`DIG_PROXY` 环境变量 > `~/.config/dig/config.toml` 的 `proxy.url` > `https_proxy`。
云端浏览器：`CLOUDFLARE_ACCOUNT_ID` + `CLOUDFLARE_API_TOKEN`（权限 `Browser Rendering - Edit`），
给公众号正文与 v2ex 主题取数；`DIG_FETCH_FALLBACK=1` 时 `dig fetch` 对认不出的 URL 也用它兜底（默认关）。
youtube / v2ex / polymarket / discourse / hf 必须走代理。

登录态：目前只有 B 站字幕需要，用 `BILI_SESSDATA` 环境变量提供（dig 不抓浏览器 cookie）。
匿名实测 0/10 视频可得字幕，带 SESSDATA 则 10/10。

## 文档与分发

`docs/` 只是开发资料（**不随 `tools/build` 的产物分发**）；`SKILL.md` 与 `references/dig.md`
才是随 skill 一起装出去的两份。部署目标由包内 `.env` 的 `OUTPUT_DIR` 决定
（`tools/build dig` 会把产物直接写进 skill 的 `scripts/dig`）。

| 文件 | 内容 |
| --- | --- |
| `SKILL.md` | research skill 正文（自带 dig：委派 prompt 固定带上 dig 的脚本与参考文件路径，由 researcher 按需使用） |
| `references/dig.md` | dig 站内检索指南（**随 skill 分发**）：给执行者看的选源/查询词/时间窗口/判读/已知限制 |
| `docs/design.md` | 定位、CLI 形态、条目 schema、源适配器契约、代理要求、为什么不做跨源融合 |
| `docs/sources.md` | **接线前必读**：源优先级、端点速查、本机可达性实测、中文站点结论、已知坑 |
| `docs/candidates.md` | 未接线候选的完整方案（X 的 queryId 刷新算法、Reddit OAuth、Bluesky、招聘板）与否决理由 |

## 开发

```bash
tools/test dig        # 只跑这个包
tools/build dig       # 产出 packages/dig/build/dig
```
