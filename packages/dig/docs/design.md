# dig 设计

## 定位

**dig 是按站点取数的工具箱，不是通用搜索引擎。**

要做的事：给一批有价值的站点各写一个适配器，把那个站点上「用关键词能捞到的东西」以
统一结构吐出来 —— 帖子、正文、评论、热度、时间。每个适配器只对**一个站点**负责。

不做的事：不做通用网页搜索（那是 pi 的 `web_search` / agent 自己的活），不做 LLM 摘要，
不做「给你一份研究报告」。排序与解读留给调用者（本机 agent）。

判断一个新源值不值得接，只有一条标准：**它能不能带来别处拿不到的增量信息**。
同一个 URL 被三个搜索引擎都索引过的内容不算增量；某站独有的评论区、投票数、
预测市场赔率、字幕文本才算。

## 与 last30days-skill 的关系

它是一个 Python 写的趋势研究 Skill（约 200 个源适配器 + LLM 重排 + 简报渲染）。
我们只要它的**取数部分**，并且明确不要它的编排层。

**抄这些**：

| 做法 | 为什么 |
| --- | --- |
| 一源一适配器，keyless 优先 | 直接映射到 dig 的「一个源一个子命令一个 lib 模块」 |
| 统一条目结构 | 对照它的 `SourceItem`，dig 用更简的 JSONL schema（见下） |
| 时间窗口双层过滤 | 源侧下推 + 客户端兜底（无日期条目保留而非丢弃） |
| **空结果要诚实**（nothing-solid）| 没找到就说没找到，不用低相关条目填充 |

**评估后放弃**：

| 放弃的 | 原因 |
| --- | --- |
| 加权 RRF 跨源融合 + 本地评分 | 实测跨源重复率为 0，融合无事可做；见下 |
| 窗口外降权而非删除 | 源侧下推 + 客户端过滤就够了，多一层分数没有必要 |

### 跨源融合为什么被砍掉

原设计抄了 last30days 的加权 RRF + 本地评分（约 150 行 jq、一整套权重配置）。实测把它否掉了：

- 同主题（`retrieval augmented generation`）拉 hn / so / github / arxiv / zhihu 共 90 条，
  按规范化 URL 两两求交集，**十个组合全为 0**；`dig merge` 进 90 条出 90 条，`sources`
  长度全是 1 —— 去重和融合都没有对象。
- 根因：我们的源在结构上互不重叠（论文 / 问答 / issue / 聚合帖 / 中文帖），
  它们不索引同一批 URL。跨源去重只在**同一批网页的链接聚合器**之间才有意义。
- 而且它实际做的只有一件事：用自编的 `rrf_k=60` / `overlap 0.5` / `engagement 0.3` /
  `time 0.2` / 源权重，把**源内原本的站点相关度**重排一遍。输入是站点自己算的相关度，
  输出是没有依据的分数，属于负收益。
- last30days 的融合是喂给它自己的 LLM 综合管线的；我们明确不要那条管线，
  融合的消费者也就没了。**没有消费者的融合只是重排。**

替代方案：统一 JSONL schema 已经够用 —— 每源一个文件，调用者按 `source` 字段分组或
自己 jq 即可。dig 不再提供跨源排序。

**不抄这些**（都已确认代价大于收益）：

| 不抄的 | 原因 |
| --- | --- |
| 源名当隐式主键，散在 5 张表里注册 | 加一个源要改 5 处；bashlet 有 `import`，该做显式注册 |
| 5700 行的 pipeline + 3900 行的 render | 巨型单文件，bash 没有类型系统帮你导航 |
| LLM 重排 / planning（rerank / planner / providers）| 要 Python 生态 + 付费推理 + prompt 注入防护，纯 bash 不引入 |
| 多后端 failover 链（X 一个源 6 个后端）| 收益比极低；真要做就只做「优先 + 兜底」两条 |
| 浏览器 cookie 提取（约 1800 行）| bash 工具集不该读别人的 cookie |
| Discovery 三段宿主持久化协议 | 需要「宿主模型」概念，与取数工具无关 |

**值得另外借鉴的工程习惯**（跟 dig 源码本身无关，但适合本项目）：
`docs/solutions/` 式的「症状 → 根因 → 修复」档案、区分「命令不在 PATH」与「在但执行不了」
的探活、`--preflight` 干跑报告、changelog 碎片。

## 代理

`sources.md` 第 1 节有实测：本机 DNS 污染导致 reddit / polymarket / bsky / jina 等不可达。
所以代理不是可选项，是红线功能：

- 默认继承 `https_proxy` / `http_proxy`（`curl` 与 `ext/requests` 都认）。
- `DIG_PROXY` 显式覆盖，优先级高于环境变量。
- **没有配置文件兜底**（2026-10-08 移除）：dig 是 skill 配套脚本，`tools/build` 产出单文件，
  包内 `config.toml` 不会跟着走 —— 原先那两个 `config.load` 在产物里只会静默失败（带
  `2>/dev/null || true`），比报错更糟：开发时以为配置生效了。现在所有默认值都读环境变量
  （`DIG_DEFAULT_LIMIT` / `DIG_DEFAULT_PERIOD` / `DIG_DISCOURSE_SITES` / `DIG_PROXY`），
  要持久化就写包内 `.env`。
- 所有源都要能报清楚「这是网络不通，不是没搜到」。

## CLI 形态

单源子命令为主，一个源一个子命令：

```bash
dig hn "bash 数组"          # Hacker News（Algolia）
dig github "timefmt"        # GitHub issues / 讨论（走 gh）
dig so "bash array slice"   # Stack Overflow
dig arxiv "retrieval eval"  # arXiv 预印本
dig openalex "transformer"  # OpenAlex 文献 + 被引数
dig discourse "rate limit"  # 官方论坛（Python/PyTorch/Rust…）
dig v2ex "zsh 数组"         # V2EX
dig zhihu "露营装备"         # 知乎（需要 ZHIHU_ACCESS_SECRET）
```

公共参数（所有源一致）：

| 参数 | 说明 |
| --- | --- |
| `-n, --limit N` | 返回条目上限 |
| `-p, --period <窗口>` | `last24h` / `pastweek` / `pastmonth` / `pastyear` / `all`；源侧不支持时退化为客户端过滤 |
| `--json` | 输出 JSONL（见下），默认输出人类可读文本 |
| `-o, --output FILE` | 落盘；多源结果各写一个文件，由调用者自行比较 |
| `--no-cache` | 跳过结果缓存，强制回源（默认同一个查询一天内直接回放缓存） |

统一输出：默认人类可读——每条先一行元数据，再一行 `text` 预览（压缩空白、截断到 200 字）；
`--json` 时输出 **JSONL**（一行一个条目，含完整 `text`）——
选择 JSONL 而不是单个 JSON 数组，是为了让 shell 管道能 `grep`/`head`/逐行 `jq`，
调用者也能逐条流式处理而不必读进内存。

> 预览是必须的：`-t`（B 站字幕）/ `-d`（弹幕）/ `-c`（HN 评论树）/ `-a`（SO 高赞答案）
> 把正文抓进 `text`，如果默认输出不显示它，这些选项看上去就像没生效（research 实测过两次）。

## 结果缓存

同一个查询（源 + 查询词 + 条数 + 窗口 + 该源的全部实参）在 TTL 内重复跑，直接回放上次的结果，不再打上游。
实参里也含 `--json` / `-o` 这类只影响输出的开关——宁可多算一份缓存，也不漏掉任何可能影响结果的输入。
上游多是免费/社区服务（Arctic Shift、sov2ex 等）且有容量背压，重复查询纯属浪费。

- 存储用 bashlet 的 `std/cache`，落在 `$XDG_CACHE_HOME/dig/result/<哈希>`；TTL 默认一天（`DIG_CACHE_TTL`）。
- **只缓存成功结果** —— 失败缓存下来会把一次网络抖动记一整天，那是「失败要响」的反面。
- 命中会打一行 INFO（stderr，不污染 JSONL）；要最新数据用 `--no-cache` 或 `DIG_NO_CACHE=1`。
- 探活（`dig doctor`）**不走缓存**，它必须实时。
- HTTP 层的条件缓存（`ext/requests.cache`）**没接**：dig 的重复是「同一个问题」而不是「同一个 URL」，
  每条 URL 都不同（discourse 多实例、bilibili 每条多个请求、`-r` 逐条），那层命中不了。

## 条目 schema

```json
{
  "source": "hn",
  "id": "42990001",
  "url": "https://news.ycombinator.com/item?id=42990001",
  "title": "……",
  "text": "正文或摘要，可为空",
  "author": "pg",
  "created_at": "2025-01-01T12:00:00Z",
  "engagement": { "points": 123, "comments": 45 },
  "tags": ["story"],
  "query": "原始查询词",
  "fetched_at": "2026-10-05T11:00:00Z"
}
```

必填：`source` `id` `url` `title` `created_at`。其余可缺省。
`engagement` 各源字段不同（HN 是 points，Reddit 是 score/num_comments），
不做归一化，原样放进去，跨源比较时按需要取。

时间一律 UTC RFC3339。这条是硬约定：跨源比较全靠它。

**空结果要诚实**：没搜到就输出「无结果」并说明是哪个源没数据，不要用低相关条目填充。
这条抄 last30days 的 "nothing-solid" 做法。

## 源适配器契约

包内 `lib/sources/<源名>.sh`，用 `import sources/<源名>` 加载（包私有模块，不进 `lib/core|std|ext`）。

每个源模块导出：

```bash
<源>.search           # 主入口，读公共变量，写 JSONL 到 stdout
<源>.map              # 站点响应 -> 条目对象流（纯函数，不触网，可离线测）
<源>.options          # 可选，声明该源特有参数
<源>.probe            # 可选，探活：0=可达 1=被拒 2=网络不通 3=缺依赖
source.register <名> <说明> <caps> <依赖>   # 末尾声明，doctor / 子命令注册 / 默认窗口都读它
```

公共变量由入口统一解析后传给源模块（`DIG_QUERY` / `DIG_LIMIT` / `DIG_PERIOD` / `DIG_AFTER` /
`DIG_JSON`），源特有参数走透传。源模块**只管取数和转 schema**，不做排序美化。
完整的契约说明写在 `lib/source.sh` 顶部。

网络请求一律走 `ext/requests`（超时、错误码、JSON 解析统一处理）。GitHub 走 `gh`：
`ext/github` 只包了 release / 资产 / contents / raw，没有 search，而且本机 curl 直连
`api.github.com` 报自签名证书错（curl exit 60），`gh` 自带 CA 配置正常。

**非 JSON 解析一律走 `lib/parse.sh`。** 从 HTML/XML 里抠数据只有两个入口：

```bash
parse.json.embedded <变量名>          # 抠 `var NAME = {...}`，用花括号配对而不是正则找结尾（页面里
                                     # 那段 JSON 后面接什么不固定：`;var meta = ...` 或 `;</script>`）
parse.xml.records <记录标签> <字段spec>  # XML → TSV；spec: tag / *tag（全部）/ @attr / #（记录正文）
```

约束的理由：arXiv 的 Atom、YouTube 的 ytInitialPlayerResponse、B 站弹幕 XML 原来各自内联
了 awk / grep / sed / jq 正则，每处都要自己处理换行、实体、属性与结尾分隔符 —— **同一个坑踩三遍**，
也是本项目修过 bug 最多的地方。收到一个文件后，① 解析逻辑只有一份、可单测；
② 将来若真换语言（Python/TS），要重写的也只有这一个文件。

约定：

- **keyless 优先**。需要密钥的源必须在 `<源>.options` 的说明、`env.example` 与 README 里写明，
  并在缺密钥时给出明确的「未配置 X，怎么配」提示，而不是静默返回空。
- **失败要响**。源挂了就报错退出，不要返回空数组假装「没搜到」，
  更不要把网络不通说成没有结果（本机很多源需要代理，见 `docs/sources.md`）。

### dig fetch：URL → 源 的路由

`dig fetch <url>` 是检索的互补：`dig <源> "<词>"` 是手上没有 URL、去源里找；已经有链接时不必再搜一遍，
交给「认领它的源」把这一条取全。框架（`lib/fetch.sh`）只有通用机制——host 归一化、子域匹配、
按 `source.list` 顺序询问、认不出时报错——**零站点知识**：URL 长什么样、该打哪个端点，都由各源自己回答。

- `<源>.url.route <url>`：认领本源的 URL → stdout 打印该源的参数（`-u <url>`）；不是本源的 host → 返回 1
  （静默地问下一个源）；是本源的 host 但形式不对 → 返回 2 并把原因写 stderr，框架直接失败、不再问别的源
  （否则用户会看到「认不出这个 URL」这种误导性报错）。
- 源侧用 `-u/--url` 接住，抠出 id 走详情端点，产物过该源**现有的 map**，再 `schema.pipe 0`——
  映射规则只写一遍。
- `cmd_fetch` 特意不走 `args.process`：源特有的选项（`-r 3`、`-T issues`）只有源的解析器认得，
  在外层先解析会把它们当未知选项拒掉。所以约定 **URL 必须是第一个实参**，其余原样转给源。
- 缓存键含 `-u <url>`，同一链接重复取会命中缓存，`--no-cache` 照常生效。

### 能力模块：`lib/browser.sh`（云端无头浏览器）

它不是源，是可被复用的能力：Cloudflare Browser Run 的 `/markdown`
（`browser.available` / `creds.check` / `probe` / `markdown` / `page`）。

消费者有三个：`wechat`（公众号正文）、`v2ex`（按 URL 取主题，顺带补上回复楼层那个老缺口）、
以及 `DIG_FETCH_FALLBACK=1` 时 `dig fetch` 的兜底。独立成一层的理由：**「本地拿不到正文」是一类问题**，
将来换后端（自建 crawl4ai 之类）只改这一个文件；反过来，源里只留「我要这个 URL 的正文」这一句。

`doctor` 会给它单列一行（不是源，但决定上面三个用途能不能用）。

## 目录

```
packages/dig/
├── dig.sh              # 入口：参数解析 + 子命令分发
├── SKILL.md            # dig skill 正文（随 skill 分发，执行手册已并入）
├── lib/
│   ├── core|std|ext    # bashlet 链接
│   ├── common.sh       # 网络入口、重试、公共选项解析
│   ├── parse.sh        # 从非 JSON 文本里取结构的**唯一**入口（内嵌 JSON、XML→TSV）
│   ├── schema.sh       # 条目 JSONL 构造与校验（本地时间、URL 规范化）
│   ├── source.sh       # 源注册表（source.register / source.list / source.cap）
│   ├── doctor.sh       # 探活
│   └── sources/        # 源适配器，一个站点一个文件
│       ├── index.sh    # 装载表：新增源在这里加一行 import
│       └── hn.sh       # 各源适配器
├── docs/               # 开发资料，不随 skill 分发
│   ├── design.md       # 本文件
│   ├── sources.md      # 源清单：端点、密钥、限流、优先级（接线前先看这里）
│   └── candidates.md   # 未接线候选的完整方案与否决理由
└── test/               # 与 lib 的模块同名 *.bats（保持平铺，嵌套路径会让 bats 的 load 变脆）
```

## 状态

**已实现**：十五个源——`hn` / `github` / `so` / `arxiv` / `openalex` / `discourse` / `hf` /
`zhihu` / `v2ex` / `reddit` / `bilibili` / `youtube` / `weread` / `polymarket` / `x`，加 `dig doctor`。
跨源聚合已评估并砍掉（见「跨源融合为什么被砍掉」）。

网络层统一带重试：传输层失败与 429/5xx 退避重试（`DIG_RETRY`，默认 2 次），其余 4xx 直接报错。

**源分三层权重**（`caps` 里的 `tier:`，机器可读）：`core`（几乎每次调研都该跑）、
`topic`（只在匹配的话题类型上用）、`niche`（极少用但不可替代）。这个分层写在 `SKILL.md`。
这是为了抵抗「源一多就想全跑」的惯性 —— dig 是要给一次具体调研做补充，不是聚合器。

加一个源 = 在 `lib/sources/` 加一个文件（末尾调 `source.register`）+ 在 `lib/sources/index.sh` 加一行 import。
`doctor` 与子命令注册都从注册表读，不需要改入口。

未接线的候选源见 `docs/sources.md`。
