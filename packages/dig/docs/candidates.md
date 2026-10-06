# 未接线候选的完整方案

这份文件回答一个问题：**「为什么没接 X / Reddit / Bluesky / 招聘板」以及如果将来要接，具体怎么做。**

每条都带实测证据（日期、HTTP 码、实测结论）与完整实现路径，避免下次重新踩一遍。
`sources.md` 只放已接源与一句话结论，完整配方放这里。

## 1. X / Twitter —— 可接，且 queryId 的维护有确定方法

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

**关键限制**：未授权的 GraphQL 请求一律返回 **404**。我用「正确的 queryId」与「故意写错的
queryId」各打一次，**都是 404** —— 也就是说「queryId 过期」与「没登录」在外部无法区分。
**所以不拿真 cookie 就无法验证任何 X 实现。** 这也是当初把它记下来而不是直接写代码的原因。

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

## 2. Reddit —— 免费 OAuth，不需要用户 cookie

**为什么必须走 OAuth**：匿名 `.json` 全路径 403（`www.reddit.com` / `old.reddit.com` /
`api.reddit.com`，带浏览器 UA 也一样，实测 2026-10-06）。社区共识是「Reddit 的 .json 端点
2026 年已死」。

**方案**：在 <https://www.reddit.com/prefs/apps> 建一个 **script** 类型的 app（免费，2 分钟），
拿 `client_id` / `client_secret`，然后：

```bash
# 1) 拿 token（client_credentials，无需用户登录）
curl -s -u "$REDDIT_CLIENT_ID:$REDDIT_CLIENT_SECRET" \
  -d 'grant_type=client_credentials' -A 'dig/0.1' \
  https://www.reddit.com/api/v1/access_token
# 2) 搜索 / 评论
curl -s -H "Authorization: Bearer $TOKEN" -A 'dig/0.1' \
  'https://oauth.reddit.com/search?q=TOPIC&sort=relevance&t=month&limit=20'
curl -s -H "Authorization: Bearer $TOKEN" -A 'dig/0.1' \
  'https://oauth.reddit.com/r/SUBREDDIT/comments/ID?limit=50'
```

- 限额 100 req/min（认证后），必须带非默认 `User-Agent`。
- `.json` 后缀在 `oauth.reddit.com` 上不加。

**实测过的替代（都不够用）**：

| 方案 | 结论 |
| --- | --- |
| `api.pullpush.io/reddit/search/{submission,comment}` | ✅ 免 cookie，**连评论都能关键词搜**；但连续性 429（间隔 6s 仍 429，实测 5/5 失败），只适合偶尔手动查 |
| `arctic-shift.photon-reddit.com/api/posts/search` | ✅ 可达，但**必须给 `subreddit` 或 `author`**，没有关键词搜索，只能当「抓某板块」 |

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
| **小红书 / 微博 / 抖音** | 卡在 `x-s` / `x-t` / `x-rap-param` 等 JS 签名，纯 Bash 无解（见 `sources.md` 第 4 节） |
| **豆瓣** | 见 `sources.md` 第 4 节：免密钥端点静默限流，且增量是书目元数据而非讨论 |

## 6. 判断标准（为什么反复否决）

一条，来自 dig 的定位：**它能不能带来别处拿不到的增量？**

- 被否掉的都是「网页检索或已有源已经覆盖」（PubMed、GitLab）、
  「拿不到就不要再试」（Invidious、Nitter）、或「需要 JS 签名而拒绝重方案」（小红书）。
- 被记下来的都是「增量明确、路径已有实测、只差凭证或维护机制」（X、Reddit、Bluesky、招聘板）。
