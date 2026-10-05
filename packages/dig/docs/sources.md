# dig 源清单

接线前先看这里。优先级 = **增量信息价值 × 本机可得性**，两者缺一不接。

标 ✅ 的是本次实测通过（2026-10-05），标 ⚠ 的是来源为 last30days 源码常量但未在
本机验证，标 ❌ 的是已确认不可行。

## 1. 本机可达性实测（无代理）

**不可达** —— DNS 被污染，解析到 Facebook / Dropbox 的 IP，属于典型封锁特征：

| 站点 | 解析到的 IP | 归属 |
| --- | --- | --- |
| www.reddit.com | 157.240.7.20 | Facebook |
| gamma-api.polymarket.com | 103.252.115.49 | - |
| bsky.social | 108.160.166.9 | - |
| r.jina.ai | 162.125.32.5 | Dropbox |
| huggingface.co | 108.160.162.31 | Dropbox |
| www.v2ex.com | 185.60.216.50 | Facebook |
| html.duckduckgo.com | - | - |

连续 3 次请求全部超时，不是偶发。

**可达**（实测 HTTP 码）：`hn.algolia.com` 200、`api.stackexchange.com` 200、
`api.github.com` 200、`export.arxiv.org` 200、`arctic-shift.photon-reddit.com` 200、
`developer.zhihu.com` 200、`www.zhihu.com` 302、`www.xiaohongshu.com` 302、
`juejin.cn` 200、`sspai.com` 200、`lobste.rs` 200、`dev.to` 200、
`api.semanticscholar.org` 429（限流，说明可达）、`api.exa.ai` 403（未带 key）。

**结论**

- 不可达的源一律走代理。`curl` 原生认 `https_proxy` / `http_proxy`，`ext/requests`
  也继承同一套环境变量，所以 dig 只需支持一个 `DIG_PROXY` 显式覆盖（优先级高于环境变量）。
- 这些源的可用性取决于代理在不在，所以 **必须有一个 `dig doctor`**（或 `--diagnose`）
  逐个探活并直接说「reddit 需要代理，当前不通」，而不是让用户对着空结果猜。
- 本机没装 `yt-dlp`，YouTube 源要等装了这个才有意义。

## 2. 优先级

### P0：可达 + 免密钥 + 增量高

| 子命令 | 增量在哪 | 机制 |
| --- | --- | --- |
| `dig hn` | 技术讨论、评论、投票数 | HN Algolia ✅ |
| `dig github` | issue/PR 正文与评论，代码库一手状态 | `api.github.com` ✅（免密钥 10 req/min，`GITHUB_TOKEN` 或 `gh auth token` 提额）|
| `dig so` | 问答正文与得分 | StackExchange 2.3 ✅ |
| `dig arxiv` | 论文摘要（别处没有的正文级素材）| `export.arxiv.org` Atom ✅ |
| `dig zhihu` | 中文一手讨论与热榜 | 知乎官方开放平台 ✅（免费 key，纯 curl）|

`arxiv` 的默认时间窗口要比别的宽（论文不按天出），last30days 用的是 365 天。

### P1：可达但增量中等

| 子命令 | 机制 | 备注 |
| --- | --- | --- |
| `dig lobsters` | `lobste.rs/search.json?q=` ✅ | 免密钥，JSON，最省事的补充源 |
| `dig devto` | `dev.to/api/articles?tag=` ✅ | 免密钥；搜索端点未验证 |
| `dig juejin` / `dig sspai` | HTML，需解析 ✅ 可达 | 无公开 API，维护成本随改版上升 |
| `dig bilibili` | `api.bilibili.com/x/web-interface/search/all/v2` ✅ 可达 | ⚠ 搜索接口通常要 wbi 签名，返回 200 不代表能拿到数据，接线前必须实测 |

### P2：可达性有条件

| 子命令 | 阻塞点 |
| --- | --- |
| `dig reddit` | 需代理。可直接用 `www.reddit.com/search.json?q=&sort=relevance&t=month`（带浏览器 UA）⚠；`arctic-shift` 只是 **subreddit/用户归档查询**，`/api/posts/search` 必须给 `subreddit` 或 `author`，**没有关键词搜索**，只能当「抓某板块」用 |
| `dig xhs`（小红书）| 无纯 Bash 路径，见第 4 节 |
| `dig bluesky` | 需代理 + App Password ⚠ |
| `dig stocktwits` | 本机 403，需 UA / cookie；只有金融主题值得 |
| `dig polymarket` | 需代理；预测市场赔率是独特增量 ⚠ |

### 不做

- **X / Twitter**：last30days 为它写了 6 条后端链（bird / xai / xurl / xquik / grok / X API）
  外加约 1800 行浏览器 cookie 提取。纯 Bash 工具集不该介入，收益比极低。
- **Instagram / TikTok / LinkedIn / Threads / Pinterest / Telegram / YouTube 回退**：
  全部压在 ScrapeCreators 一个付费 key 上，单点依赖，不符合「keyless 优先」。
- **Amazon**（Bright Data 付费）、**Twitter-adjacent 的 Grok / Perplexity**：都属于搜索层。
- **通用 web 搜索**（brave / exa / serper / parallel / ddg）：那是 agent 自己的活，dig 不做。

## 3. 端点速查

### Hacker News（✅ 免密钥）

```bash
# 相关度搜索；窗口用 numericFilters（时间戳，秒）
curl -s "https://hn.algolia.com/api/v1/search?query=TOPIC&tags=story&hitsPerPage=30&numericFilters=created_at_i%3EFROM_TS,created_at_i%3CTO_TS"
# 按时间排序 / 首页 / 单条详情（含评论树）
curl -s "https://hn.algolia.com/api/v1/search_by_date?query=TOPIC"
curl -s "https://hn.algolia.com/api/v1/search?tags=front_page"
curl -s "https://hn.algolia.com/api/v1/items/ITEM_ID"
```

坑：`points` **不能**做 numericFilters（返回 400）。窗口必须 URL 编码 `>` 为 `%3E`。
`created_at_i` 是秒级时间戳，直接 `$(date +%s)` 减窗口。

### GitHub（✅ 免密钥，10 req/min）

```bash
curl -s -H 'Accept: application/vnd.github+json' "https://api.github.com/search/issues?q=QUERY&per_page=20"
curl -s "https://api.github.com/repos/OWNER/REPO/comments?per_page=50"
curl -s "https://api.github.com/repos/OWNER/REPO/readme"
curl -s "https://api.github.com/repos/OWNER/REPO/releases?per_page=10"
```

本机有 `gh` (2.46.0)，按仓库约定 **GitHub 相关一律走 `gh`**；`gh search issues` 免密钥、
自动带认证，还支持 Go template 直接排版：

```bash
gh search issues --repo cli/cli --limit 20 \
  --json title,url,state,number,author,createdAt \
  --template '{{range .}}{{.title}}|{{.url}}|{{.state}}|{{.number}}|{{.author.login}}|{{timefmt "2006-01-02" .createdAt}}{{"\n"}}{{end}}'
```

（✅ 实测可用，比 `--json` + `jq` 少一次进程，适合 bash 里 `IFS='|' read` 逐行吃。）

### Stack Overflow（✅ 免密钥）

```bash
curl -s "https://api.stackexchange.com/2.3/search?intitle=QUERY&site=stackoverflow&pagesize=20&sort=relevance&order=desc&tagged=bash"
```

坑：`pagesize` 上限 100。返回体是 gzip 的，`curl --compressed` 或让 `ext/requests` 处理。

### arXiv（✅ 免密钥，Atom XML）

```bash
curl -s 'https://export.arxiv.org/api/query?search_query=all:%22PHRASE%22&start=0&max_results=20&sortBy=relevance'
```

坑：**必须 https**（http 是 301）。返回 XML 不是 JSON，本机没有 `xmllint`，
要么用 `grep`/`sed` 硬解，要么让 `ext/requests` 之外单独处理（实现时再定）。

### 知乎官方开放平台（✅ 免密钥但需免费 Access Secret）

```bash
curl -s -H "Authorization: Bearer $ZHIHU_ACCESS_SECRET" \
     -H "X-Request-Timestamp: $(date +%s)" \
     "https://developer.zhihu.com/api/v1/quota"
```

- 凭证：`developer.zhihu.com/profile` 注册即生成，**无企业资质要求**，单账号最多 20 个，
  共享同一额度池。读取顺序参照社区实现：`ZHIHU_ACCESS_SECRET` → `~/.config/zhihu-search/credentials.json`。
- 端点：`/api/v1/content/zhihu_search`（单次 ≤10）、`/api/v1/content/global_search`（≤20）、
  热榜（≤30，上限 30）、`/api/v1/quota`，另有 OpenAI 兼容的直答 `POST /v1/chat/completions`。
- 错误码：`30001` 频率、`30002` 配额、`30003` 风控、`20001` token 无效。
- 参考实现（Python，可直接读它的调用细节）：`github.com/klarkxy/zhihu-search`。

### 其它（⚠ 未实测，来自 last30days 源码常量）

```bash
https://lobste.rs/search.json?q=TOPIC                       # ✅ 实测可达
https://api.stocktwits.com/api/2/streams/symbol/AAPL.json   # 本机 403
https://gamma-api.polymarket.com/public-search?q=TOPIC&page=1&events_status=active&keep_closed_markets=0
https://arctic-shift.photon-reddit.com/api/posts/search?subreddit=linux&limit=50   # 仅 subreddit/author
https://api.semanticscholar.org/graph/v1/paper/search?query=TOPIC&limit=20        # 本机 429，需重试
```

招聘板（免密钥，公司信号，需要时再说）：

```bash
https://boards-api.greenhouse.io/v1/boards/TOKEN/jobs
https://api.ashbyhq.com/posting-api/job-board/SLUG
https://api.lever.co/v0/postings/SLUG
https://apply.workable.com/api/v3/accounts/SLUG/jobs
https://api.smartrecruiters.com/v1/companies/SLUG/postings
```

## 4. 中文站点

### 知乎 ✅ 纯 curl 可行

官方开放平台就是用户猜到的那条路：REST + Bearer token，纯 Bash 成立，见第 3 节。

**能力边界要说清**：`user/*` 系列端点是「本人」语义 —— 能拿自己创作的内容，
**拿不到任意用户主页、任意问题的全部回答、通用评论**。要这些只能逆向网页接口
（`www.zhihu.com/api/v4/...`），而那条路必带 `x-zse-96`，是 JSVMP 保护的 JS 算法，
纯 Bash 不可行。所以 `dig zhihu` 只承诺「搜索 + 热榜 + 问题的回答摘要」。

### 小红书 ❌ 没有纯 Bash 路径

官方开放平台对企业主体（中国大陆注册、存续、成立满 1 年、营业执照、逐接口审核），
个人开发者不在范围内。网页端接口在 `edith.xiaohongshu.com/api/sns/web/v1/*`，
必带 `x-s` / `x-s-common` / `x-t`，feed 与搜索还要 `x-rap-param` 风控头；
签名算法持续迭代且会整体失效（2023-05-30 那版已作废）。现成签名实现清一色 Python/JS
（`Cloxl/xhshow`、`ReaJason/xhs`、`MediaCrawler`、`XHS-Downloader`），**没有任何 Bash 实现**。

三条路，按代价排序：

1. **sidecar 常驻服务（推荐）** —— 本地跑一个薄 Python 服务（内部用 `xhshow` 签名），
   dig 只 `curl http://127.0.0.1:PORT/search?q=`。dig 本体保持纯 Bash，签名复杂度隔离在
   一个可独立升级的进程里。代价：多一个常驻进程，签名库改版时要单独升它。
2. **`xpzouying/xiaohongshu-mcp`（Go 单二进制 + 真实浏览器，16k stars）** ——
   无需 Python，但常驻浏览器、必须保持登录态、讲 MCP 协议而非 REST。资源占用高。
3. **砍掉** —— 如果 sidecar 也不想要，小红书就不该出现在 dig 里。

**已否定的**：在小红书官方开放平台申请（要企业资质）；在 Bash 里实现 `x-s` 签名
（无先例，算法被 JSVMP 保护）；「无需登录」的路径只存在于付费云端采集（Apify 之类）。

## 5. 从 archive/retrieve.sh 抢救下来的内容

已归档到这里，原文件已删（`git log` 里仍有全文）：

| 内容 | 结论 |
| --- | --- |
| `gh search issues ... --template` + `IFS='\|' read` 排版法 | ✅ 保留，见第 3 节 |
| HN Algolia 的时间窗口参数化（`numericFilters=created_at_i>TS`）| ✅ 保留 |
| StackExchange 2.3 的 `intitle` 搜索 | ✅ 保留 |
| `: "${EXA_API_KEY:=$(pass "exa")}"` 密钥回退 | ⚠ 模式可用，但 exa 属搜索层，dig 不接 |
| Exa 的手写 JSON 转义（逐字符替换 `\` `"` `\n`）| ❌ 反面教材，用 `jq -n --arg` 生成 body |
| `defuddle.md` 网页转 markdown | ❌ 服务已下线（连接超时）|

## 6. 已知坑

- **HN**：`points` 不能做 numericFilters；`>` 要编码成 `%3E`。
- **Reddit**：必须带浏览器 UA，否则被拒；`.json` 搜索通道本身也不稳（403/429 是常态）。
- **SO**：`pagesize` ≤ 100；响应是 gzip。
- **arXiv**：http 会 301；XML 不是 JSON；本机无 `xmllint`。
- **GitHub**：免密钥 10 req/min，跑批量时先 `gh auth token` 提额。
- **本机缺 `yt-dlp`**，YouTube 相关全部不可用。
- **知乎**：每日免费额度数字**未确认**（二手来源称 1000 次/天），接线前先用
  `GET /api/v1/quota` 实测；官方文档页 JS 渲染，本机抓不到正文。
