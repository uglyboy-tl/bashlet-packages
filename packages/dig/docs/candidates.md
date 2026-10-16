# 未接线候选的完整方案

这份文件回答一个问题：**「为什么没接 X / Reddit / Bluesky / 招聘板」以及如果将来要接，具体怎么做。**

每条都带实测证据（日期、HTTP 码、实测结论）与完整实现路径，避免下次重新踩一遍。
`sources.md` 只放已接源与一句话结论，完整配方放这里。

## 1. X / Twitter —— 可接，且 queryId 的维护有确定方法

> **2026-10-07 已接线**：`dig x "词"`（搜索）、`dig x --tweet <id|url>` 与 `dig fetch <推文链接>`
> （单推，零凭证走 syndication）、`dig x --update-ids`（手动刷新，一般已自动完成）。仍需代理。
> 与本节方案的差异：
> - §1.2 的更正：搜索请求**不校验 cookie 真实性**，但 **queryId 只能靠登录态取**（main bundle 只在
>   `x.com/home`，未登录 307 到登录页），所以 `X_AUTH_TOKEN` / `X_CT0` 仍是必需的；
> - §1.3 设想的「BFS 展开 168 个 chunk」被实测简化：`main.*.js` 里直接有成对的
>   `queryId:"…",operationName:"…"`（104 条），不必展开整张图；
> - **不留内置 queryId**：写死的值过期后只报 403/404，看不出原因。缓存 30 天，403/404 时自动重取；
> - 单页上限 20 条，**翻页仍未实现**。
> 接线细节见 `sources.md` §3 与 `lib/sources/x.sh`。

**结论：技术上完全可行，代价是「用户提供 cookie」+「一个刷新 queryId 的子命令」。** 价值高
（技术/AI 话题的第一落点常常在 X，HN 与 GitHub 都滞后），所以一旦要做，这是最值得的一个。

### 1.1 三条读推路径（实测 2026-10-06）

| 路径 | 能拿到 | 凭证 | 实测 |
| --- | --- | --- | --- |
| `cdn.syndication.twimg.com/tweet-result?id=<id>&token=<t>` | 单条推的全文、`favorite_count`、`created_at`、`user` | **零** | ✅ 200，JSON |
| `api.fxtwitter.com/<user>/status/<id>` | 同上，字段更全（`likes` / `replies` / `quotes` / `retweets` / `views`） | **零** | ✅ 200，JSON |
| `api.x.com/graphql/<queryId>/SearchTimeline` | **关键词搜索**、线程、用户时间线 | 用户 cookie | ⚠️ 见 1.3 |

零凭证的两条**只能读「已知推文 ID」**，没有搜索能力；而且都依赖第三方（前者是 Twitter 自己的
CDN，尚可；后者是第三方服务，与 dig「直接对站点负责」的原则冲突）。

### 1.2 公开 bearer 与 guest token（实测有效）

```bash
# Web 端公开的客户端 bearer，不是账号凭证
BEARER='AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA'
curl -s -X POST -H "Authorization: Bearer $BEARER" https://api.x.com/1.1/guest/activate.json
# → 200 {"guest_token":"2107302643823767876"}
```

**关键限制（2026-10-07 接线时更正）**：原记录是「未授权一律返回 404，与 queryId 过期无法区分」。
重测得到的是 **403**（完全不带 cookie 头），而**只要带一个非空的 `auth_token`（值随便填，`0`/`x`/`deadbeef` 都行）
就返回 200 与真实结果** —— SearchTimeline 只检查 cookie 是否存在、不验值。
所以结论要改两条：**真 cookie 不是必需的**；但「queryId 过期」与「X 收紧 cookie 校验」仍然同形（403/404）。
完整实测（含排除代理缓存与 cookie 注入的对照）见 `sources.md` §3。

### 1.3 queryId 会轮换，但可以自动提取（这是「好办法」）

x.com 现在是 Vite 应用：入口 bundle 是
`https://abs.twimg.com/x-web/x-web/entry-client-logged-out-*.js`，它动态加载 **168 个 chunk**，
而 chunk 名全是 UI 组件名（`authorize` / `trending` / `view` / `page`…），**不带 operation 名** ——
所以无法按名字定向取，只能把 chunk 图展开后整体 grep。

`vladkens/twscrape`（⭐2833，2026-10-06 当天仍有推送）的 `scripts/update-gql-ops.py`（约 8KB）
就是这个刷新器，算法已确认，可移植到 bash：

1. 取 `https://x.com/home` 与 `https://x.com/xdevelopers` 的 HTML，抽出 script URL；
2. **递归展开**：在这些脚本里用 `(?:from|import)\s*\(?\s*[`"](\.{1,2}/[^`"]+?\.js)[`"]` 找相对引用，
   BFS 把整张 chunk 图抓下来（这是能触达懒加载 chunk 的关键）；
3. 过滤掉 `/i18n/`、`/icons/`、`react-syntax-highlighter`；
4. 用两条正则提取 operation：
   - `queryId:[`"](.+?)[`"].+?operationName:[`"](.+?)[`"]`
   - `params:\{id:[`"]([^`"]+)[`"].+?name:[`"]([^`"]+)[`"].+?operationKind:[`"]`
5. 同一 operation 有多个来源时，**优先 `/responsive-web/client-web/`，其次 `/x-web/`**；
6. 结果落缓存目录（twscrape 用 `/tmp/twscrape-ops`），命中缓存就不重下。

**拉取量**：首轮上百个请求（有缓存后为零），所以应该做成显式的 `dig x --update-ids`，
而不是每次运行都去取。

### 1.4 要接的话，最小可用形态

```bash
# 用户提供（环境变量，与 BILI_SESSDATA 同一套做法；dig 不抓浏览器 cookie）
export X_AUTH_TOKEN='...'   # 浏览器 cookie auth_token
export X_CT0='...'          # 浏览器 cookie ct0

dig x "claude code"         # SearchTimeline：搜推文
dig x --update-ids          # 刷新 queryId（缓存到 ~/.cache/dig/x-ops/）
dig x --tweet <url|id>      # 单推/线程，走 syndication（零凭证也能跑）
```

请求头（除 bearer 外都必须）：`x-csrf-token: $X_CT0`、`x-twitter-auth-type: OAuth2Session`、
`x-twitter-active-user: yes`、`x-twitter-client-language: en`，以及
`Cookie: auth_token=$X_AUTH_TOKEN; ct0=$X_CT0`。
`variables` / `features` 都要带；**features 缺字段会 400**。

### 1.5 已知不可行

| 路径 | 实测 |
| --- | --- |
| `api.vxtwitter.com` | ❌ 403 Cloudflare 挑战页 |
| `publish.twitter.com/oembed` | ❌ 301（已下线） |
| 官方 API | ❌ 免费档只能发推，读搜索要付费 |
| Nitter / twstalker / socialgrep | ❌ 连不上 / 403 |
| RSSHub 公共实例 | ❌ 302 Cloudflare |

## 2. Reddit —— 免 key 走 Arctic Shift（OAuth 已变成审批制）

> **2026-10-07 已接线**：`dig reddit -s <sub> "词"`（`-r N` 抓嵌套评论树），免 key、无需代理。
> 本节保留为端点速查与「将来补 OAuth」的方案，接线细节见 `sources.md` 与 `lib/sources/reddit.sh`。

**先记住三个日期**（2026-10-06~07 实测 + 官方/二手混查；自助创建已关，这几个日期现在只对**已获批**的
应用有意义）：新 app 申请 **2026-10-31** 截止；官方 RSS **2026-11-13** 停止；公共 Data API 公告称
**2027-03** 前关闭（口径存疑，官方帖题为「Moving Data API apps to the Developer Platform」）。

**免 key 路径（推荐主体）：Arctic Shift**

```bash
# 列表（subreddit/author 必给一个）
curl -s 'https://arctic-shift.photon-reddit.com/api/posts/search?subreddit=linux&limit=100&sort=desc'
# sub 内关键词搜索（跨全站不行：?query= 不带 subreddit/author 会直接报错）
curl -s 'https://arctic-shift.photon-reddit.com/api/posts/search?subreddit=linux&query=bash&limit=50'
# 嵌套评论树，一次到位（不用展开 more stub）
curl -s 'https://arctic-shift.photon-reddit.com/api/comments/tree?link_id=t3_<id>&limit=9999'
```

- 实测数据是**当天**的（`created_utc` 对得上），不是归档快照；单次 `limit` ≤100（`auto` 可到 1000），
  `fields=` 可裁字段，`format=json|rss|jsonfeed`。
- 失败是**容量型背压**：连发 5 次 1 次超时，或 `422 {"error":"Timeout. Maybe slow down a bit"}`，
  无 `X-RateLimit` 头可读。要分三类处理：`HTTP != 200` / JSON 体里的 `error`（200 与 422 都可能带）/ 连接超时。
- 单人维护、无 SLA。全局关键词搜索只能靠「遍历 subreddit 列表」近似。

### 为什么不做 OAuth（2026-10-07 实测 + 一手/二手混查）

1. **自助创建已关闭**：在 `reddit.com/prefs/apps` 点创建后，页面只回一句
   「In order to create an application or use our API you can read our full policies here:
   <Responsible Builder Policy>」——拿不到 `client_id`。Reddit 2025-11 发布 Responsible Builder
   Policy 的同时终止了自助 API key（「打开 prefs/apps、点 create app、秒拿凭证」那条路没了）。
2. **`developers.reddit.com/app-registration` 不是这条路**：它要的是 **Automated account**——一个专门
   给应用用的 Reddit 账号（字段要用户名，填邮箱会一直禁用 Continue），产出的是 **Devvit 应用**：跑在
   Reddit 自己的服务器上、只对**你自己当 mod 的 sub** 有效，**给不了本地 CLI 用的 OAuth 凭证**。
3. **唯一的官方路径是人工审批**：走 Developer Support 表单
   <https://support.reddithelp.com/hc/en-us/requests/new?ticket_form_id=14868593862164>，
   写清用途 / 数据范围 / 涉及哪些 subreddit / 预期请求量。Reddit 自称多数申请 7 天响应。
   社区汇总的通过率现实（二手，但方向一致）：个人脚本**几乎不批**；学术需机构伦理证明（中等）；
   版主工具成功率最高（10 万+ 订阅的 sub 尤甚）；商用基本无望（除非企业档，$10k/月起）。
4. **2025-11 前的旧凭证仍然有效**——所以这不是「大家一起被断」，而是「新人没有门」。

**结论：OAuth 不值得做**。它能换来的只有「跨全站关键词搜索」，代价是一个需要人工审批、通过率低、
且 2027-03 之后是否存续都不确定的凭证；跨全站搜索改用「curated subreddit 列表」近似即可。

（若将来真拿到凭证，流程本身没变，照下面这段即可：）

```bash
TOKEN=$(curl -s -X POST -u "$CLIENT_ID:$CLIENT_SECRET" \
  -A "linux:dig:v0.1 (by /u/<你的用户名>)" \
  -d grant_type=client_credentials \
  https://www.reddit.com/api/v1/access_token | jq -r .access_token)
curl -s -A "linux:dig:v0.1 (by /u/<你的用户名>)" -H "Authorization: bearer $TOKEN" \
  'https://oauth.reddit.com/r/linux/new?limit=100'
```

- UA 格式是硬要求：`<platform>:<app ID>:<version> (by /u/<username>)`，官方明说**不得撒谎**。
- 端点只走 `oauth.reddit.com`（不加 `.json`），认证后 100 QPM / client_id（滚动 10 分钟均值）。

**已死 / 将死（不要当依赖）**：

| 方案 | 结论 |
| --- | --- |
| `api.pullpush.io/reddit/search/*` | ❌ **不是限流，是付费墙**：实测 429 且正文明说「不为 agent 提供免费抓取资源」；摄取停在 2025-05 |
| 官方 RSS（`/r/<sub>/new/.rss`、`/search.rss?q=`） | ⚠️ 公告 2026-11-13 停，只剩几周，只能当过渡 |
| 匿名 `.json` | ❌ 本机全 403（**换浏览器 UA 无效**，UA 不是解药）；第三方博客称「公开 `.json` 仍可用、约 10 req/min」，与实测冲突——差异很可能来自出口 IP（我们走代理，IP 被标记），**不按可用处理** |

## 3. Bluesky —— 需要免费 app password

**为什么必须认证**：`public.api.bsky.app/xrpc/app.bsky.feed.searchPosts` 返回 **403**，
响应头 `server: BunnyCDN-HK1-*` —— CDN 层按出口 IP 拒绝；`bsky.social/xrpc/...` 返回 401
`AuthMissing`。

**方案**（app password 免费，1 分钟，<https://bsky.app/settings/app-passwords>）：

```bash
curl -s -X POST https://bsky.social/xrpc/com.atproto.server.createSession \
  -H 'Content-Type: application/json' \
  -d '{"identifier":"'"$BSKY_HANDLE"'","password":"'"$BSKY_APP_PASSWORD"'"}'   # → accessJwt
curl -s -H "Authorization: Bearer $JWT" -G \
  --data-urlencode 'q=TOPIC' --data 'limit=25' \
  https://bsky.social/xrpc/app.bsky.feed.searchPosts
```

条目字段：`record.text` / `record.createdAt` / `author.handle` / `likeCount` / `replyCount` /
`repostCount`。价值定位：**dev/AI 圈从 X 迁出去的那部分人有在这里**。

## 4. 招聘板 —— 零凭证，公司在招什么是方向的先行信号

五个板子都有免密钥公开 JSON，形态统一（给公司 slug 就返回职位列表）：

```bash
https://boards-api.greenhouse.io/v1/boards/TOKEN/jobs
https://api.ashbyhq.com/posting-api/job-board/SLUG
https://api.lever.co/v0/postings/SLUG
https://apply.workable.com/api/v3/accounts/SLUG/jobs
https://api.smartrecruiters.com/v1/companies/SLUG/postings
```

适合回答「这家公司现在在押什么方向」——招聘 JD 往往早于发布会。限制是**需要公司 slug**，
不是关键词搜索，所以形态上更像 `dig jobs <slug>` 而不是 `dig jobs "<词>"`。

## 5. 调研后明确不加的

| 候选 | 结论与原因 |
| --- | --- |
| **PubMed** | esearch/esummary 实测可用，但 **OpenAlex 已索引 PubMed 且多给被引数与摘要** —— 纯重复，不加 |
| **Invidious / Piped** | 测了 5 个 Invidious + 4 个 Piped 实例，**全部 DNS 可解析但连接失败（000）**；且依赖第三方，与 dig 原则不符 |
| **GitLab** | `gitlab.com/api/v4/projects?search=` 免密钥可用，但绝大多数开源在 GitHub，边际价值低 |
| **npm / PyPI 下载量** | 实测可用（`api.npmjs.org/downloads/point/last-month/react`、`pypistats.org/api/packages/x/recent`），是「这个库真的被用吗」的信号，但不是讨论型载体，暂不单独立源 |
| **小红书 / 微博 / 抖音** | 卡在 `x-s` / `x-t` / `x-rap-param` 等 JS 签名，纯 Bash 无解（见 `sources.md` 第 4 节）；**小红书另有展开的方案与风险评估，见第 8 节** |
| **豆瓣** | 见 `sources.md` 第 4 节：免密钥端点静默限流，且增量是书目元数据而非讨论 |
| **微信公众号** | 本机 curl 拿不到（302 滑块验证）；**已接**：走云端浏览器只按 URL 取正文 —— 见第 7 节 |

## 6. 判断标准（为什么反复否决）

一条，来自 dig 的定位：**它能不能带来别处拿不到的增量？**

- 被否掉的都是「网页检索或已有源已经覆盖」（PubMed、GitLab）、
  「拿不到就不要再试」（Invidious、Nitter）、或「需要 JS 签名而拒绝重方案」（小红书）。
- 被记下来的都是「增量明确、路径已有实测、只差凭证或维护机制」（X、Reddit、Bluesky、招聘板）。

## 7. 微信公众号 —— 本地 curl 拿不到，云端浏览器能拿（2026-10-07 实测）

**结论：已接（`wechat` 源，只按 URL 取，走 Cloudflare Browser Run）。** 下面 7.1-7.3 是「为什么本地路线都不行」的
实测存档；7.4 是最后的解法与边界。

### 7.1 为什么拿不回：302 到滑块验证

拿 58 条 GitHub 上抓来的真实文章长链，逐个单次请求（不并发、不循环轰炸，排除频率因素）：

| UA | 结果 |
| --- | --- |
| curl 默认 / 桌面 Chrome / Googlebot | **HTTP 302** → `mp.weixin.qq.com/mp/wappoc_appmsgcaptcha?poc_token=…` |
| **MicroMessenger 8.0.49**（微信内置浏览器） | 同上，**没有区别** |

- 302 响应带 `set-cookie: poc_sid=…`，body 是「未知错误」页（`<title>未知错误</title>`）。
- 出口 IP 是 `221.220.132.131`（中国联通北京 AS4808）—— **不是境外 IP 或 DNS 污染问题**。
- 流传很广的「UA 里带 `MicroMessenger` 就能过」**已经过时**；要过只能浏览器解滑块，
  或复用已经验证过的会话 cookie（dig 明确不抓浏览器 cookie）。
- `weixin.sogou.com/weixin?type=2&query=` 返回 200 但结果里 0 条 `mp.weixin.qq.com` 链接
  （反爬/JS 渲染）；而且它只能做发现，不解决正文。

### 7.2 微信读书官方 skill 也没有文章正文接口

官方 skill 自报家门：`{"api_name":"/_list"}` 列出全部 17 个接口 ——
`/book/{info,chapterinfo,bestbookmarks,bookmarklist,getprogress,readreviews,recommend,similar,underlines}`、
`/discover/interact/type3`、`/readdata/detail`、`/review/{list,list/mine,single}`、`/shelf/sync`、
`/store/search`、`/user/notebooks`。**没有一个返回文章正文。**

`/store/search` 知道「文章」这一组存在（`type=6`，`scopeCount=350`），但 `scope=4` 只回组头，
`books` 为空 —— 文章条目没随请求返回，也没有后续接口能取正文。

（`/book/chapterinfo` 的 `chapters[].isMPChapter` 说明公众号内容会以「章节」形式收进某些书，
但那个接口只给目录，不给章节正文。）

### 7.3 第三方路线（都不接）

| 方案 | 为什么不接 |
| --- | --- |
| wechat2rss（xlab.app） | 免费额度有限、要账号；是别人的常驻服务 |
| wewe-rss（自部署，原理基于微信读书） | 要自己跑服务 + 登录态，dig 从「纯 curl 零依赖」变成「要维护一个后端」 |
| feeddd 等聚合源 | 覆盖有限（按公众号订阅，不能按关键词） |
| 新榜 / 极致了等商业 API | 要付费凭证 |

### 7.4 解法：Cloudflare Browser Run（能读公众号与 v2ex，读不了知乎）

| 目标 | 云端浏览器 `/markdown` | 说明 |
| --- | --- | --- |
| 微信公众号正文 | ✅ 能 | 短链 `/s/<id>` 与带 `poc_token` 的长链都拿到 title / author / 正文（30KB 量级），**不需要 poc_token** |
| V2EX 主题页 | ✅ 能 | 本机直连 `www.v2ex.com` 超时，云端出口能到；顺带拿到渲染后的回复（补上 API 2.0 要 PAT 的缺口） |
| 知乎（含专栏） | ❌ 不能 | 同一出口回 `40362 您当前请求存在异常` —— 它挡的是 IP/指纹，不是渲染 |
| 任意 JS 页 | ✅ 能 | 但默认不放开（见下） |

- 接线形态：能力抽成 `lib/browser.sh`，`wechat` 与 `v2ex` 只声明「取这个 URL 的正文」；
  `dig fetch <公众号/v2ex 链接>` 走同一套路由表。
- 免费档限流 **REST 6 次/分钟**（1 次/10 秒）：只做单条，不做批量。
- 默认**不**给「认不出的 URL」兜底：`DIG_FETCH_FALLBACK=1` 才开——否则 dig 就从「按站点取数」
  漂成「通用抓取器」，「取不到就取不到」那条边界就没了。
- 早期的评估探针（`packages/dig/experiments/cloudflare-probe.sh`）已删，逻辑落在上面两个文件里。

## 8. 小红书 —— 免登录已无路，只剩「花钱」或「借你的浏览器」

`sources.md` 第 4 节给了「纯 Bash 无解」的结论与三条出路，本节是它的展开：实测拦截层次、
签名攻防的时间线、风险评估（**封 IP 与封号要分开看**）、以及每条路的维护成本。

**结论先行**：想在不冒封号风险的前提下把小红书当日常信息源，只有两条路——
付 `$0.01/次` 买第三方 API（风险在服务商侧，不在你的账号），
或用**你自己浏览器的登录态**做只读抓取（零成本，但要长期跟维护）。纯 HTTP 自建签名是风险最高的一条。

### 8.1 拦截层次（实测 2026-10-11）

这五条请求说明了「门槛到底在哪」，可直接复现：

| 请求 | 结果 | 含义 |
| --- | --- | --- |
| `GET www.xiaohongshu.com/explore` | `302 → /login?redirectPath=…` | Web 端**整站登录墙** |
| `POST edith.xiaohongshu.com/api/sns/web/v1/search/notes`（无签名无 cookie） | `200 {"code":-101,"msg":"无登录信息，或登录信息为空"}` | **登录检查在签名检查之前** |
| `POST …/api/sns/web/v1/homefeed`（无签名） | `406 {"code":-1}` | 签名层直接拒 |
| `GET /explore/<id>?xsec_token=<已过期>` | `302 → /404/…?error_code=300031&error_msg=当前笔记暂时无法浏览` | 分享链接的 `xsec_token` 有时效，过期即风控页 |
| `GET www.rednote.com/explore` | `302 → /login` | 国际版同样登录墙 |

复现命令：

```bash
curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' https://www.xiaohongshu.com/explore
curl -s -X POST 'https://edith.xiaohongshu.com/api/sns/web/v1/search/notes' \
  -H 'content-type: application/json' --data '{"keyword":"咖啡","page":1}'
```

### 8.2 官方开放平台：与「内容检索」无关

`openaccount.xiaohongshu.com` 现在是纯 OAuth 登录平台，API 参考（官方，2026-08-19 更新）的
11 个接口全是授权链路（`auth_info` / `authorize` / `access_token` / `refresh_token` / `token_status` /
`batch_get_min_user_info` / `auth_app/*` / `device/*` / `revoke`），返回数据最多到「昵称、头像、性别、地区」。

**没有任何笔记 / 搜索 / 评论类接口。** 中文社区里写「申请开放平台就能调笔记详情 API」的文章
把「OAuth 登录能力」和「商业侧接口（蒲公英 / 千帆 / 小程序）」混为一谈，无官方文档支撑，不要采信。
（企业资质门槛另见 `sources.md` 第 4 节。）

### 8.3 签名能算，但风控已从「认签名」转向「认账号」

纯 Python 生成签名是成熟的：`Cloxl/xhshow`（push 2026-06-11，1088★）提供
`sign_headers_get/post`、`x_rap_param`、`get_search_id`、`generate_a1`、`generate_web_id`；
MediaCrawler 2026-07-24 的提交就是「升级 xhshow 至 0.2.0」——它至今是社区主力实现。

**但「有签名」不等于「能用」**，时间线（全部一手 issue）：

| 时间 | 事件 |
| --- | --- |
| 2025-10-26 | 签名算法整体失效，「能在 API 层面直接识别旧算法生成的 `x-s` / `x-t`」 |
| 2025-10-28 | 签名修好后仍 `406`，紧接着 `461 {'code': 300011, 'msg': '检测到账号异常'}` |
| 2026-03-31 | `user_posted` 端点签名自 2025-11 起一直有问题，「暂无可靠修复方案」 |
| 2026-06-12 | **只读场景**（看帖、下视频）也被提示「检查到 AI 操作」 |
| 2026-09-24 / 10-06 | `creator`（用户主页）模式仍失败 |

**签名可以追，账号信用追不回来。** 这是「纯 HTTP 路线」与「浏览器路线」风险差异的根源。

### 8.4 三条路对比

| 路径 | 现在能用吗 | 稳定性 | 封号风险 | 门槛与成本 | 需登录 |
| --- | --- | --- | --- | --- | --- |
| **第三方 API**（rnote.dev / TikHub / Apify） | ✅ 注册即用 | 高（服务商替你跟算法） | **零**（风险在服务商侧） | `$0.01/次`，每天约 100 次 ≈ `$1` | 否（对使用者） |
| **复用自己浏览器**（CDP / 插件 / MediaCrawler CDP 模式） | ✅ search + detail 大致可用；`creator` 脆弱 | 中：DOM 变了要自己修，但坏了看得见 | 中：**只读 + 独立小号 + 不互动**可压住 | 约 1 小时搭建 | 是（小号） |
| **纯 HTTP 签名自建**（Spider_XHS 式） | ⚠️ 追着算法跑 | 低：坏起来是静默空数据或封号 | **高**：实测 45s 间隔、每天几十条，两三天封号 | 维护成本最高 | 是 |

第三方 API 的价格口径在 `rnote.dev`（`$0.01/次`，「仅成功请求扣费」，22+ 端点含搜索 / 评论 / 二级评论）
与 `tikhub.io`（`$0.01/请求`，明确「无需中国开发者资质」）两家独立服务商上一致，可作价格锚点。

**工程上的关键差别**：走第三方 API 时签名复杂度被服务商吃掉，dig 只需把它当**普通 JSON API 源**接
（`ext/requests` + `json.run` 就够，**不需要 Python sidecar**）；走自建才必须 sidecar（见 8.9）。

### 8.5 开源项目现状（2026-10-11 读）

| 项目 | 最后 push | ★ | 关键词搜索 | 形态 | 近期失效 / 封号证据 |
| --- | --- | --- | --- | --- | --- |
| `NanmiCoder/MediaCrawler` | 2026-10-10 | 66.6k | ✅ | Playwright / CDP + `xhshow` 签名 | 签名失效与账号异常的多条 issue；`creator` 模式 2026-09 仍坏 |
| `xpzouying/xiaohongshu-mcp` | 2026-10-09 | 16.2k | ✅ | Go + 真实浏览器（必扫码登录） | 「仅取消收藏 + 搜索一次」次日被警告；搜索页 DOM 变动导致 60s 超时 |
| `JoeanAmier/XHS-Downloader` | 2026-10-09 | 13.0k | ❌ 只能按链接 | 混合（API + MCP + 油猴） | 只读下载，风险最低；「从浏览器读取 Cookie」功能已失效 |
| `cv-cat/Spider_XHS` | 2026-10-08 | 8.1k | ✅ | 纯 HTTP 逆向（Web + 创作者 + 蒲公英全套签名） | 45s 间隔仍两三天封号；机房 IP 上 cookie 直接报无效 |
| `iFurySt/RedNote-MCP` | 2025-05-11 | 1.1k | ✅ | Go | **近一年半未维护，不要用** |

GitHub 上 2026 年新出现的小红书 MCP 仓大多是 `xiaohongshu-mcp` 的复刻，无独立价值。

判断「现在还能不能用」最可信的证据是 **MediaCrawler 的 commit 时间线**：2026-09-18 仍在 `fix(xhs)`，
说明维护者还跟得上；但 issue #985（2026-09-24）与 #990（2026-10-06）显示 `creator` 模式当天仍是坏的。

### 8.6 RSS 与间接路径：覆盖不了「按关键词搜笔记」

- **RSSHub** 的 xiaohongshu namespace 只有 `/user/:user_id/notes|collect` 与 `/board/:board_id`，
  `antiCrawler + requirePuppeteer`，可选 `XIAOHONGSHU_COOKIE`。**没有关键词搜索路由**——
  只能「盯某个博主 / 某个专辑」，做不了「按词搜笔记」。
- **搜索引擎收录差**：百度自 2024 下半年起「几乎很难找到」小红书笔记（二手来源，营销机构自测）；
  本次 `site:xiaohongshu.com` 检索也没有返回任何笔记详情页。
- **分享链接**：`xsec_token` 一次性且有时效，过期落到 `300031`（实测）；社区称拿 token 本身也需要登录。
- **搬运到公众号 / 知乎**：能拿（`dig wechat` 已接），但那是别人选过的内容，不构成「按你的关键词检索小红书」。

### 8.7 风险：封 IP 与封号是两件事

| 风险类型 | 触发条件 | 后果 |
| --- | --- | --- |
| **只封 IP / 只触发验证码** | 未登录 + 高频 + 机房 / 海外 IP 直连私有 API | 换 IP 或过验证码即恢复，**账号无损** |
| **封号 / 限制账号（不可逆）** | 用主号跑爬虫；**互动动作**（发布 / 评论 / 点赞 / 收藏）；新号或未实名；环境异常；高频 | 官方提示话术是「设备环境异常 / 可能存在多个异常账号 / 网络及手机号存在异常」 |

一手证据里所有封号报告的共同点是**用主号 + 做了互动动作**；而只读 + 小号的对照组（维护者自测）能持续运行。
注意维护者说「一年多没封号」与社区说「两三天就封」是**冲突**的，没有对照实验——但封号样本来自多人多次独立报告，
更可信；环境差异（住宅 IP vs 机房、实名 vs 未实名、只读 vs 发布）是合理解释。

### 8.8 降低风险的具体做法

来自各项目 README 与维护者的实际建议，按重要性排：

1. **只用独立小号**，与主号零关联（不同手机号、不同浏览器 profile、绝不互关）。
2. **复用自己真实浏览器的登录态**（CDP / 插件 / userscript），不要 headless 全新实例——
   MediaCrawler 默认 CDP 模式连你已有的 Chrome，并「通过 JS 表达式获取签名参数」，即不必自己实现签名。
3. **只读**：只做搜索 + 详情 + 评论，永不点赞 / 收藏 / 评论 / 发布。
4. **并发恒为 1**（MediaCrawler 默认 `MAX_CONCURRENCY_NUM = 1`），单次 ≤ 15-20 条
   （`CRAWLER_MAX_NOTES_COUNT = 15`），会话间加随机秒级停顿。
   注意「只加间隔」不够——`Spider_XHS` 用户 45s 间隔、每天几十条仍被封，**降总量与降行为相似度才是关键**。
5. **出口 IP 固定在账号常用地**：住宅 IP，不要机房；海外场景用 `rednote.com`，别拿大陆账号在境外 IP 登录。
6. **cookie 里的 `a1`（设备指纹，52 位）固定**，不要每次重新生成。其余字段：`web_session`（登录态）、
   `webId` / `gid` / `websectiga` / `sec_poison_id` / `b1`；每篇笔记还需 `xsec_token`，搜索还需 `search_id`。

### 8.9 若将来要接进 dig

- **走第三方 API**（推荐形态）：dig 新增一个普通 JSON API 源，纯 Bash，无新语言依赖，
  凭证沿用现有 `.env` 的 cookie 模式（形如 `XHS_API_KEY`）。签名升级与风控对抗全在服务商侧，dig 不需要跟。
- **走自建**：只能按 `sources.md` 第 4 节第 1 条做 sidecar——本地跑一个薄 Python 服务（`xhshow` 签名），
  dig 只 `curl http://127.0.0.1:PORT/search?q=`。签名的复杂度隔离在一个可独立升级的进程里。
  代价：多一个常驻进程，且**要与小红书的风控持续对抗**（见 8.3 的时间线）。

### 8.10 待验证项（动手前要先补的）

1. **`xhshow`（2026-06-11）是否覆盖 2026-09/10 的算法升级**——没有直接证据，只能靠 MediaCrawler
   的 commit 间接推断。这是纯 HTTP / sidecar 路线的固有维护点。
2. **带「当日新鲜」`xsec_token` 的分享链接能否免登录读正文**——只测到过期 token → `300031`，未拿到有效 token，无法判定。
3. **第三方 API 的实际稳定性与字段完整度**——只有服务商自述，没有独立评测。建议小额充值实测一周再决定。
4. **MediaCrawler 的 xhs search 模式在 2026-10 是否真可用**——正面证据是 2026-09-18 还在修，
   反面是 `creator` 模式的失败 issue；未自测（需要登录态）。

