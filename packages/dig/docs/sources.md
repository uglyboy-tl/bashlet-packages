# dig 源清单

接线前先看这里。优先级 = **增量信息价值 × 本机可得性**，两者缺一不接。

标 ✅ 的是实测通过，标 ⚠ 的是未在本机验证，标 ❌ 的是已确认不可行。
实测时间：原有结论 2026-10-05，新增源与代理结论 2026-10-06。

## 1. 本机可达性实测

### 代理 ✅ 可用（2026-10-06 实测）

本机跑着 v2raya，局域网有一个 HTTP 代理 `http://192.168.0.100:50172`（zsh 别名
`__ZSHPROXY_HTTP`）。经它访问：google 204、youtube 200、reddit 200、v2ex API 200、
bluesky 302、polymarket 200；出口 IP 稳定（`202.155.152.212` 连测 3 次一致，不是轮换代理）。

dig 的代理取值顺序：`DIG_PROXY` 环境变量 > `~/.config/dig/config.toml` 的 `proxy.url` >
curl 原生继承 `https_proxy` / `http_proxy`。本机已写好用户级配置，开箱即用；
构建出的单文件产物**会读同目录的 `.env`**（`dig.sh` 带 `# build:keep-env`，`tools/build` 会保留这段加载）；跨机器部署时用环境变量或随产物放一份 `.env`。

### 无代理时的不可达站点

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
- 这些源的可用性取决于代理在不在，所以 **必须有一个 `dig doctor`**
  逐个探活并直接说「需要代理，当前不通」，而不是让用户对着空结果猜。

## 2. 优先级

### 已接的源（`dig <名>`，2026-10-07）

| 子命令 | 增量在哪 | tier | 凭证 | 代理 |
| --- | --- | --- | --- | --- |
| `hn` | 技术讨论、投票、评论（`-T comments` 直接搜评论语料） | core | 免 | 否 |
| `github` | issue/PR、仓库、代码、commit 四种搜索（`-T`） | core | 免（走 `gh`） | 否 |
| `so` | 问答正文与多年沉淀的得分（`-s` 换 StackExchange 站点） | core | 免 | 否 |
| `arxiv` | 论文摘要 | topic | 免 | 否 |
| `openalex` | 学术文献 + 被引数 + 摘要 | topic | 建议免费 key | 否 |
| `discourse` | 官方论坛讨论（Python/PyTorch/Rust/OpenAI/HF 等 8 个实例） | topic | 免 | 是 |
| `hf` | 模型 / 数据集的下载量与点赞（`-T`） | topic | 免 | 是 |
| `zhihu` | 中文一手讨论与热榜 | topic | `ZHIHU_ACCESS_SECRET`（免费） | 否 |
| `v2ex` | 中文技术社区热帖与搜索 | topic | 免 | 是 |
| `reddit` | subreddit 内关键词搜索（`-s` 必给）+ `-r` 一次拿嵌套评论树；免 key 走 Arctic Shift，无需代理。拿不到跨全站关键词搜索 | topic | 免 | 否 |
| `bilibili` | 视频元数据、弹幕、字幕（`-t` 需 `BILI_SESSDATA`） | niche | 免 / 可选 SESSDATA | 否 |
| `youtube` | 视频搜索 + `-t` 补精确发布日与简介 | niche | 免 | 是 |
| `weread` | 书目评分 / 在读人数 | niche | `WEREAD_API_KEY` 或 `pass weread` | 否 |
| `wechat` | 公众号文章正文（**只能按 URL 取**；本地 curl 吃滑块，走云端浏览器） | topic | `CLOUDFLARE_ACCOUNT_ID` + `CLOUDFLARE_API_TOKEN` | 否 |
| `polymarket` | 预测市场赔率与成交量（真金白银） | niche | 免 | 是 |

> `reddit` 的定位是「某个社区怎么说 X」，不是「全网怎么说 X」：官方 `.json` 全 403，免 key 只能走
> Arctic Shift，而它的搜索接口要求 `subreddit` / `author` 圈定，**跨全站关键词搜索在免 key 层做不到**。
> 好消息是 `/api/comments/tree?link_id=t3_<id>` 能一次拿到嵌套评论树（没有 more stub 要展开），
> 数据也是当天的，`dig reddit -s linux -r 3 "bash"` 即可。代价见 §6。

### 探测过但不接的

| 候选 | 实测结论 |
| --- | --- |
| `reddit`（OAuth 路线） | `client_credentials` 流程本身没变（一条 curl 换 token，端点走 `oauth.reddit.com` + 固定格式 UA），但**门槛变成人工审批**：Responsible Builder Policy 要求先获批；新申请 **2026-10-31 截止**；RSS 2026-11-13 停；公共 Data API 2027-03 前关闭（公告口径存疑，见下）。**PullPush 已从「限流」变成付费墙**（实测 429 + 明说不为 agent 免费提供） |
| `lobsters` | `lobste.rs/search.json` 返回 Anubis 人机验证页（HTTP 200 + "Making sure you're not a bot!"），要跑 JS 解 PoW |
| `devto` | `/api/articles?tag=` 可用但只有标签浏览；`search/feed_content` 返回空，**没有关键词搜索** |
| `bluesky` | 需代理 + App Password（免费）；公共 XRPC 未验证通过 |
| `juejin` / `sspai` | 掘金搜索接口需参数调优；少数派有 RSS 但无关键词搜索 |
| `douban` | 见第 4 节：免密钥端点会静默限流，且增量是书目元数据而非讨论 |
| `pubmed` | **不加**：OpenAlex 已索引 PubMed 且多给被引数与摘要（已实测 esearch/esummary 可用，但属于重复造轮子） |
| Invidious / Piped | ❌ 测过 5 个 Invidious + 4 个 Piped 实例，全部 DNS 能解析但连不上（000）；且依赖第三方与 dig 原则不符 |
| `xhs`（小红书） | ❌ 无纯 Bash 路径（要 `x-s`/`x-t` JS 签名），见第 4 节 |

**X / Reddit / Bluesky / 招聘板的完整方案（含 queryId 刷新算法）单独放在
[`candidates.md`](candidates.md)** —— 都是「增量明确、路径已实测、只差凭证或维护机制」的候选。

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

**但 curl 直连 api.github.com 在本机不可用**：握手报 `SSL certificate problem: self-signed
certificate`（curl exit 60，疑似本地 SSL 拦截），`gh` 走自己的 CA 配置正常。所以 `dig github`
不接 `ext/github`（其 `github.api` 就是 curl 打 api.github.com），只走 `gh search issues`。

### Stack Overflow（✅ 免密钥）

```bash
curl -s "https://api.stackexchange.com/2.3/search?intitle=QUERY&site=stackoverflow&pagesize=20&sort=relevance&order=desc&tagged=bash"
```

坑：`pagesize` 上限 100。返回体是 gzip 的，`curl --compressed` 或让 `ext/requests` 处理。

### arXiv（✅ 免密钥，Atom XML）

```bash
curl -s 'https://export.arxiv.org/api/query?search_query=all:%22PHRASE%22&start=0&max_results=20&sortBy=relevance'
```

坑：**必须 https**（http 是 301）；返回的是 Atom XML 不是 JSON（本机没有 `xmllint`）。
解析统一走 `lib/parse.sh`：`parse.xml.records entry 'published,id,title,summary,*name'`
一次 jq 出 TSV，本源不再自带 awk 解析器。

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

### YouTube（✅ 免密钥，需代理）

搜索走 InnerTube，纯 JSON（不要用 yt-dlp，也不用解析搜索结果页）：

```bash
KEY='AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8'   # Web 端公开客户端 key，不是账号凭证
curl -s -X POST "https://www.youtube.com/youtubei/v1/search?key=$KEY&prettyPrint=false" \
  -H 'Content-Type: application/json' \
  -d '{"context":{"client":{"clientName":"WEB","clientVersion":"2.20240726.00.00","hl":"en","gl":"US"}},"query":"bash arrays"}'
```

- 结果在 `.. | objects | select(has("videoRenderer")) | .videoRenderer`，含 videoId / title /
ownerText / viewCountText / lengthText / publishedTimeText（相对时间）。
- **精确发布日期与简介**：watch 页里的 `ytInitialPlayerResponse`，用
  `parse.json.embedded ytInitialPlayerResponse` 抠出来（awk 花括号配对，不是正则找结尾 ——
  那段 JSON 后面接的是 `;var meta = ...` 或 `;</script>`，正则一定会抓多或抓少），
  再取 `.microformat.playerMicroformatRenderer.publishDate`（带 `-07:00` 偏移，已转 UTC）
  与 `.videoDetails.shortDescription`。
- ❌ **字幕拿不到**：watch 页里有 `captionTracks`，但 `/api/timedtext` 恒返回
  `HTTP 200 + content-length: 0`，`/youtubei/v1/get_transcript` 返回
  `400 Precondition check failed`。两者都要 PO token（等于要跑 YouTube 自己的 JS）。
  InnerTube 的 `/player` 也不给 captions：WEB/TVHTML5 返回 `UNPLAYABLE`，
  ANDROID_VR 返回 `LOGIN_REQUIRED`。代理出口 IP 稳定，排除签名 IP 失配。

### B 站（✅ 免密钥、免签名）

```bash
curl -s 'https://api.bilibili.com/x/web-interface/search/all/v2?keyword=TOPIC'
curl -s 'https://api.bilibili.com/x/web-interface/view?bvid=BV...'          # 拿 cid/aid
curl -s 'https://api.bilibili.com/x/v1/dm/list.so?oid=CID'                  # 弹幕（deflate）
curl -s 'https://api.bilibili.com/x/v2/reply?type=1&oid=AID&pn=1&ps=20&sort=2'
```

- 搜索**不需要 wbi 签名、不需要 cookie**（带不带 cookie 实测都是 `code 0`，3/3 稳定）。
- 视频字段：bvid / title（带 `<em class="keyword">` 高亮，要清）/ author / play / danmaku /
  review / duration / pubdate(epoch) / tag / typename。
- 弹幕响应是 `content-encoding: deflate`，curl `--compressed` 会自动解；XML 是**单行**的，
  用 `grep -o '<d p="[^"]*">[^<]*</d>'` 抽，不要用按行数数的写法。
- ❌ **匿名拿不到字幕内容**：`view.subtitle.list` 只能看到「有几条字幕轨」（如 `ai-zh`），
  但 `subtitle_url` 是空串；`player/v2` 与**补了正确 wbi 签名**的 `player/wbi/v2`
  对有 CC 轨的视频都返回 `subtitles: []`。
- ✅ **带 `SESSDATA` 就能拿到**（已接）：`public-clis/bilibili-cli#33` 有一组对照测量——
  B 站热门 10 个视频，**匿名 0/10 有字幕，登录后 10/10**（全部 `ai-zh`）；拿到
  `subtitle_url` 后拉下来就是完整文稿（该 issue 实测 456 段 / 5948 字）。
  dig 用法：`export BILI_SESSDATA=...` 后 `dig bilibili "词" -t 3`。
- ⚠️ 匿名评论也只有首页 3 条（`ps` 给多少都只回 3，`pn=2` 空，楼中楼 `code 12006`）；
  所以没带登录态时，本源用**弹幕**（匿名可拿，几千条）当观众反应。
- 历史弹幕（未接线，本机未实测）：`bilibili-API-collect` 记录 `/x/v2/dm/history/index`（日期索引）+
  `/x/v2/dm/web/history/seg.so`（protobuf，老的 xml 接口已失效），两者都要 `SESSDATA`。
  接上就能把弹幕从「一次性快照」变成时间序列。

### V2EX（✅ 免密钥，需代理）

```bash
curl -s 'https://www.v2ex.com/api/topics/hot.json'                    # 热帖（v1，免 token）
curl -s 'https://www.sov2ex.com/api/search?q=TOPIC&size=20&sort=created'  # 搜索（第三方）
curl -s -H "Authorization: Bearer $V2EX_TOKEN" \
  'https://www.v2ex.com/api/v2/topics/1/replies'                      # 回复楼层（v2，需 PAT）
```

- 官方没有搜索 API，关键词搜索走 sov2ex。
- **API 2.0 需 PAT**（`Authorization: Bearer`，600 请求/小时/IP）：2026-10 实测 `/api/v2/topics/1`、
  `/api/v2/topics/1/replies`、`/api/v2/nodes/api/topics` **免 token 一律 401 `Token not found`**。
  回复楼层是「大家怎么解决的」真正的所在：API 2.0 要 PAT，**但按 URL 取主题走云端浏览器就能拿到**
  （`dig fetch https://www.v2ex.com/t/<id>`，见 §4 微信公众号那节）。
- sov2ex 默认按相关度排，结果跨年份，会把时间窗口过滤变成空；**必须带 `sort=created`**。
- sov2ex 的 `created` 是「北京时间、无时区」的字符串（`2017-05-04T09:38:57`），
  按 UTC 解析后减 8 小时才是真实 UTC 时刻。
- 热帖接口的 `created` 本身就是 epoch，不用换算。

### Polymarket（✅ 免密钥，需代理）

```bash
curl -s 'https://gamma-api.polymarket.com/public-search?q=TOPIC&page=1&events_status=active&keep_closed_markets=0'
```

增量是 `.events[].markets[].outcomePrices`（赔率）与 `volume`（成交量）——
真金白银的概率，任何论坛都拿不到。注意结果里混有已结束事件，用 `events_status=active` 过滤。

### OpenAlex（✅ 免密钥但会限流）

```bash
curl -s 'https://api.openalex.org/works?search=TOPIC&per-page=20&sort=relevance_score:desc'
```

- 匿名访问**频繁收到 429/503**（`"Anonymous search is paused while the search cluster
  recovers from heavy load"`）；官方建议申请免费 API key。dig 支持
  `OPENALEX_API_KEY` 与 `OPENALEX_MAILTO`（polite pool）。
- 摘要是**倒排索引** `abstract_inverted_index`，要按位置号重排才能还原成正文。
- 相关度排在前面的往往是老论文，套时间窗口会把结果清空；所以本源默认不筛时间。

### GitHub 四种搜索（`-T`）

全部走 `gh`（自带认证）：

```bash
gh search issues  "Q" --json number,title,url,state,body,author,createdAt,commentsCount,repository,isPullRequest
gh search repos   "Q" --json fullName,url,description,stargazersCount,forksCount,createdAt,updatedAt,language
gh search code    "Q" --json path,repository,url          # 限流 10 次/分
gh search commits "Q" --json sha,commit,repository,url
gh api graphql -f query='query($q:String!,$n:Int!){search(query:$q,type:DISCUSSION,first:$n){nodes{... on Discussion{number title url createdAt body upvoteCount category{name} answer{isAnswer} comments{totalCount} author{login} repository{nameWithOwner}}}}}' -F q=QUERY -F n=20
```

- `repos` 模式的时间轴取 **updatedAt**（仓库是长期存在的，创建时间无意义）；
- `commits` 的 `commit.author.date` 带偏移（如 `+08:00`），要走 `to_utc`；
- `code` 搜索的 `repository` 字段是 `nameWithOwner`，`commits` 的却是 `fullName`，两者不一致。
- **Discussion 只能走 GraphQL**（`gh search` 没有 discussions），但 `search(type:DISCUSSION)` 支持
  跨仓库关键词搜索，`created:>=YYYY-MM-DD` 限定符也能用；`answer.isAnswer` 告诉你这个问题
  是否已被解答。

### Discourse（✅ 免密钥、开放 JSON、需代理）

```bash
curl -s 'https://discuss.python.org/search.json?q=TOPIC'
```

- 响应同时给 `topics[]`（标题 / slug / reply_count / created_at）与
  `posts[]`（username / blurb 摘要 / created_at），用 `topic_id` 接起来就是完整条目。
- 主题 URL 要自己拼：`https://<host>/t/<slug>/<id>`。
- **`order` 参数无效**（试过 `order=latest`、`order=latest_topic`，首位结果不变），
  所以源侧无法按时间排；dig 的处理是默认窗口放宽到 `pastyear`。
- 实测可用的实例（2026-10-06）：discuss.python.org、community.openai.com、
  discuss.huggingface.co、discuss.pytorch.org、users.rust-lang.org、meta.discourse.org、
  community.fly.io、discuss.elastic.co。`discuss.jetbrains.com` 不通、`community.render.com` 301。

### Hugging Face（✅ 免密钥，**需代理**）

```bash
curl -s 'https://huggingface.co/api/models?search=Q&limit=20&sort=downloads&direction=-1'
curl -s 'https://huggingface.co/api/datasets?search=Q&limit=20&sort=downloads&direction=-1'
```

- 增量是**模型/数据集的下载量与点赞**：GitHub star 衡量代码仓库，HF 衡量权重与数据，两者不重合。
- ⚠️ **必须走代理**：直连实测 `http=000`，`getent hosts huggingface.co` 解析到
  `2a03:2880:f10f:83:face:b00c:0:25de`（Facebook 段，典型污染特征）。
- 列表接口里 `models` 的 `lastModified` 是 `null`（详情接口才有），要退回 `createdAt`；
  `datasets` 的 `lastModified` 有值。

### Hacker News 评论搜索（`-T comments`）

```bash
curl -s 'https://hn.algolia.com/api/v1/search?query=TOPIC&tags=comment&hitsPerPage=20'
```

返回 `comment_text`（HTML）、`story_title`、`story_id`、`author`、`created_at`；
`points` 恒为 null（HN 不给单条评论打分）。条目 URL 是
`https://news.ycombinator.com/item?id=<objectID>`。
另有一条路是按故事抓整棵评论树：`/api/v1/items/<story_id>`。

### 其它候选（截至 2026-10-06 的实测状态）

```bash
https://lobste.rs/search.json?q=TOPIC                       # ❌ Anubis 人机验证（页内无可用 JSON）
https://api.stocktwits.com/api/2/streams/symbol/AAPL.json   # 403，需 UA / cookie
https://arctic-shift.photon-reddit.com/api/posts/search?subreddit=linux&limit=50          # 列表（subreddit/author 必给）
https://arctic-shift.photon-reddit.com/api/posts/search?subreddit=linux&query=bash       # ✅ sub 内关键词搜索（跨全站不行）
https://arctic-shift.photon-reddit.com/api/comments/tree?link_id=t3_<id>&limit=9999      # ✅ 一次拿到嵌套评论树，免 key
https://api.pullpush.io/reddit/search/comment?q=TOPIC                                    # ❌ 付费墙（429 + 明说不为 agent 免费提供）
https://api.semanticscholar.org/graph/v1/paper/search?query=TOPIC&limit=20        # 429，需重试
https://api.npmjs.org/downloads/point/last-month/PKG        # ✅ 包下载量
https://pypistats.org/api/packages/PKG/recent               # ✅ 包下载量
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

### 微信读书 ✅ 纯 curl 可行（需 key）

单网关 POST，认证用 Bearer token：

```bash
curl -s -X POST "https://i.weread.qq.com/api/agent/gateway" \
  -H "Authorization: Bearer $WEREAD_API_KEY" -H 'Content-Type: application/json' \
  -d '{"api_name":"/store/search","skill_version":"1.0.4","keyword":"三体","scope":10,"count":3}'
```

- 这套接口是**微信读书官方 skill** 提供的，权威说明看那边：
  <https://weread.qq.com/r/weread-skills>（扫码拿 API Key）与 <https://github.com/Tencent/WeChatReading>
  的 `skills/*.md`。本文件只记 dig 用到的那部分。
- 凭证：`WEREAD_API_KEY`（官方页面扫码获取），或本地 `pass weread`。
- 官方 skill 提供多个 `api_name`（`/store/search`、`/book/info`、`/shelf/sync`、`/book/getprogress`、
  `/readdata/detail` 等）；**dig 只用两个**：`/store/search` 与 `-i N` 时的 `/book/info`。
  剩下的（书架 / 进度 / 阅读统计）是账号私有数据，属「个人阅读助手」语义，
  与 dig「按站点取公开数据」的定位不符，不接。
- `skill_version` 是网关校验字段。过期时响应会带 `upgrade_info`（含 `latest_version` /
  `upgrade_url`），**但数据仍然返回** —— 所以 dig 只 warn 不 fail（把它当致命错，
  会让每次上游发版都断）。
- 返回是「HTTP 200 + 业务 `errcode`」信封，必须单独判错，否则会静默返回空。
- **能力边界**：只有书目元数据（评分 / 在读人数 / 作者 / 分类），**没有评论区、没有读者讨论**。
- `newRating` 是 0-1000 的原始分（`930` = 93.0），dig 不做换算，原样进 `engagement`。
- `dig weread` 用 `/store/search`（`-s/--scope` 可选类型，10=电子书 默认）；
  `-i N` 为前 N 本抓 `/book/info`，取 `intro`（简介，实测 215 字）填进 `text`——
  `/store/search` 不返回简介，而「值不值得读」的判断材料就在它里面。
  `/book/info` 另给 `publisher` / `publishTime` / `category` / `isbn`，dig 暂不收（会污染 tags，
  也不是 `created_at` 该用的时间轴）。

### 豆瓣 ⚠️ 免密钥端点不稳定，暂不接

实测（2026-10-05）：

| 端点 | 结果 |
| --- | --- |
| `{movie,book}.douban.com/j/subject_suggest?q=` | ✅ 免密钥 JSON（title/author/year/id） |
| 同上连续调用 | ⚠️ 第 5-6 次起静默返回 `[]`，HTTP 仍为 200 |
| `m.douban.com/rexxar/api/v2/{movie,book}/{id}` | ✅ 免登录，含 rating / intro / 演职员 |
| `m.douban.com/rexxar/api/v2/search` | ❌ 先返回过 19KB，随后变 `code 103 need_login` |
| `api.douban.com/v2/*` | ❌ `apikey_required` / `invalid_credencial2`（旧版已废） |
| `www.douban.com/j/search` | ❌ 403 |
| 豆瓣小组讨论 | ❌ 匿名端点拿不到 |

不接的原因：增量是**书目/影视元数据**而不是讨论区；而且「被限流」与「无结果」都是
HTTP 200 + `[]`，无法区分，直接违反 dig 的「失败要响」。将来若要接，只能靠
`subject_suggest` + rexxar 详情，且必须加退避与「连续空结果疑似限流」的判定。

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

### 微信公众号 ✅ 走云端浏览器（需 Cloudflare 凭证）

本地怎么试都不行、云端浏览器能过——2026-10-07 实测：

| 路径 | 结果 |
| --- | --- |
| 本机 curl（桌面 UA / MicroMessenger UA / Googlebot 都试了） | HTTP 302 → `mp.weixin.qq.com/mp/wappoc_appmsgcaptcha`（滑块验证页） |
| 普通网页读取 | 判成「JS 渲染、无内容」 |
| Cloudflare Browser Run `/markdown` | ✅ 拿到 title / author / 正文（短链 `/s/<id>` 与带 `poc_token` 的长链都行，30KB 量级） |

- 所以 `dig wechat` **只能按 URL 取**（`dig fetch "<文章链接>"`）：微信没有公开检索接口，发现仍靠 web 检索。
- 端点：`POST https://api.cloudflare.com/client/v4/accounts/<account>/browser-run/markdown`，
  body `{"url":…,"gotoOptions":{"waitUntil":"networkidle0"}}`，token 要 `Account · Browser Rendering · Edit`。
  注意「凭证有效」与「有权限」是两回事：只授别的权限时 `/user/tokens/verify` 是绿的，这个接口回 `10000`。
- 返回是 markdown，头部带 YAML front-matter（`title` / `meta.author` / `meta.description`）。
  字段与正文的拆分在 `lib/browser.sh`，`wechat` 与 `v2ex` 共用这一份能力。
- **限流**：免费档 REST 6 次/分钟（1 次/10 秒）——只适合单条取，不做批量。dig 会让调用在本地按这个
  间隔排队（`DIG_BROWSER_MIN_INTERVAL`，默认 12 秒——10 秒卡在 6 次/分钟的边界上）；真被 429 时还会
  按这个间隔多试一次（通用退避的 2s/4s 对分钟级限流太短）。
- **反面**：知乎在同一出口回 `40362 您当前请求存在异常`。云端浏览器解决的是「挡在本机 / 要 JS 渲染」，
  不是「站点要求登录」，别当通用抓取器用。

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
- **Reddit**：`.json` 全 403（换 UA 无效）；**免 key 只能走 Arctic Shift**，且关键词搜索必须用 `subreddit`/`author` 圈定；
  失败要分三类处理——`HTTP != 200` / JSON 体里的 `error` 字段（Arctic Shift 在 200、422 里都会塞）/ 连接超时，分别退避重试与报错退出。
- **SO**：`pagesize` ≤ 100；响应是 gzip。
- **arXiv**：http 会 301；Atom XML 不是 JSON，本机无 `xmllint`，解析走 `parse.xml.records`。
- **GitHub**：免密钥 10 req/min，跑批量时先 `gh auth token` 提额。
- **YouTube 只缺字幕**：watch 页能拿到字幕轨（实测 31 条），但轨道 URL 带 `exp=xpe`（需 PO token），
  取回是 HTTP 200 + **0 字节**；2026-10 实测七个 InnerTube 客户端（WEB / MWEB / WEB_EMBEDDED_PLAYER /
  TVHTML5_SIMPLY_EMBEDDED_PLAYER / ANDROID_VR / IOS / TVHTML5）**全部拿不到 `captionTracks`**，
  ANDROID_VR 与 TVHTML5 直接回 `Sign in to confirm you're not a bot`（出口 IP 被标记）。
  要拿只能引 BotGuard / PO token 生成，属于本工具拒绝的重依赖；搜索与 `-t` 补发布日期/简介不受影响，**不要用 yt-dlp**。
- **知乎**：每日免费额度数字**未确认**（二手来源称 1000 次/天），接线前先用
  `GET /api/v1/quota` 实测；官方文档页 JS 渲染，本机抓不到正文。

## 7. 按 URL 直取（`dig fetch`）

给一个链接，判断它属于哪个源，再用该源的接口取这一条（2026-10-07 接线，产物与检索同形：同一条 JSONL、
同样的正文预览、同样过缓存）。路由框架（`lib/fetch.sh`）只有通用机制，站点知识全在各源自己的
`<源>.url.route` 里，新增一个源不动框架。

| 源 | URL 形态 | 端点 | 单条结果的 `text` |
| --- | --- | --- | --- |
| `hn` | `news.ycombinator.com/item?id=<n>` | `hn.algolia.com/api/v1/items/<n>` | Ask HN 正文；链接帖为空 |
| `github` | `github.com/<o>/<r>`、`/<o>/<r>/issues/<n>`、`/pull/<n>` | `gh api repos/<o>/<r>`、`repos/<o>/<r>/issues/<n>` | 仓库 description / issue 正文 |
| `so` | `stackoverflow.com/questions/<n>[/slug]`、`/q/<n>` | `api.stackexchange.com/2.3/questions/<n>?site=stackoverflow&filter=withbody` | 问题正文 |
| `arxiv` | `arxiv.org/abs/<id>`、`/pdf/<id>[vN][.pdf]` | `export.arxiv.org/api/query?id_list=<id>` | 摘要 |
| `openalex` | `openalex.org/W<id>`、`api.openalex.org/works/W<id>`、`doi.org/<doi>` | `/works/<id>` 或 `/works?filter=doi:<doi>` | 倒排索引还原的摘要（截 1200 字符） |
| `reddit` | `reddit.com/r/<sub>/comments/<id>`、`/comments/<id>`、`redd.it/<id>`、old./np. | `arctic-shift…/api/posts/ids?ids=<id>` | `selftext`；给了 `-r N` 时是评论树 |
| `bilibili` | `bilibili.com/video/BV…`、`/video/av<N>` | `x/web-interface/view` + `player/v2` 字幕 + `dm/list.so` 弹幕 | 字幕稿 + 弹幕；都拿不到时退回简介 |
| `discourse` | `https://<实例>/t/<slug>/<id>`、`/t/<id>` | `https://<实例>/t/<id>.json` | 首帖正文 |
| `hf` | `huggingface.co/<o>/<m>`、`/datasets/<o>/<n>`、`/spaces/<o>/<n>` | `huggingface.co/api/{models,datasets,spaces}/<id>` | `pipeline_tag`（与检索同形） |
| `wechat` | `mp.weixin.qq.com/s/<id>` 或 `/s?__biz=…&mid=…&idx=…&sn=…` | 云端浏览器 `/markdown`（见 §4） | 正文全文；`title` / `author` 来自 front-matter |
| `v2ex` | `www.v2ex.com/t/<id>` | 同上（本机直连不通，只能走它） | 主题正文 + 回复（markdown 表格），导航/广告/页脚已裁掉 |
| `polymarket` | `polymarket.com/event/<slug>`、`/market/<slug>` | `gamma-api.polymarket.com/public-search?q=<slug>` 再按 slug 精确匹配 | 该事件下各 market 的 `question` |

不接线的三个，以及为什么：

- **zhihu**：正文要登录态（云端浏览器也过不去，见 §4）。
- **youtube**：字幕轨要 PO token（见第 6 节）。
- **weread**：deepLink 里的 `v=` 不是 `bookId`，映射不过去。

约定：**URL 必须是第一个实参**，它之后的参数原样转给认领它的源（`-r 3`、`--no-cache` 都能用）——
`fetch` 自己不解析选项，否则源特有的选项会在外层被当未知选项拒掉。认不出的 URL 报错，不会静默地
当成「没搜到」。

另：`DIG_FETCH_FALLBACK=1`（默认关）时，认不出的 URL 会交给云端浏览器兜底取一页，产出 `source=browser`
的一条——默认关是为了保住「按站点取数、取不到就取不到」的定位。
