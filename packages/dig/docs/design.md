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
| 窗口外降权而非删除 | 它的做法是排最后 + 分数乘 0.35，比直接过滤更诚实 |
| 加权 RRF 做跨源融合 | 比手调线性权重稳：`score = (子查询权重 × 源权重)/(60 + rank)` |
| **空结果要诚实**（nothing-solid）| 没找到就说没找到，不用低相关条目填充 |

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
- 所有源都要能报清楚「这是网络不通，不是没搜到」。

## CLI 形态

单源子命令为主，一个源一个子命令：

```bash
dig hn "bash 数组"          # Hacker News（Algolia）
dig reddit "bash arrays"    # Reddit 公开 JSON
dig so "bash array slice"   # Stack Overflow
dig github "timefmt"        # GitHub issues / 讨论（走 gh）
dig arxiv "retrieval eval"  # arXiv
dig xhs "露营装备"           # 小红书
dig zhihu "..."             # 知乎
```

公共参数（所有源一致）：

| 参数 | 说明 |
| --- | --- |
| `-n, --limit N` | 返回条目上限 |
| `-p, --period <窗口>` | `last24h` / `pastweek` / `pastmonth` / `all`；源侧不支持时退化为客户端过滤 |
| `--json` | 输出 JSONL（见下），默认输出人类可读文本 |
| `-o, --output FILE` | 落盘；配合聚合用 |

统一输出：默认人类可读，`--json` 时输出 **JSONL**（一行一个条目）——
选择 JSONL 而不是单个 JSON 数组，是为了让 shell 管道能 `grep`/`head`/逐行 `jq`，
聚合时也不必把整个结果读进内存。

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
不做归一化，原样放进去，聚合时按需要取。

时间一律 UTC RFC3339。这条是硬约定：跨源排序全靠它。

## 轻量聚合

聚合是**独立一步**，不藏在子命令里：

```bash
dig hn "rust async" --json > /tmp/a.jsonl
dig reddit "rust async" --json >> /tmp/a.jsonl
dig merge /tmp/a.jsonl
```

`dig merge` 做四件事，全部本地启发式，不调 LLM：

1. **去重** —— 按规范化 URL 合并（去 `utm_*` 等追踪参数、统一大小写、去尾斜杠）。
   同一 URL 多条时保留字段更全的那条。
2. **跨源融合** —— 每个源自己的列表是一个有序流，用**加权 RRF** 合并：
   `score += 源权重 / (60 + 该源内的名次)`。比手调线性权重稳，也不依赖各源分数可比。
3. **本地评分** —— RRF 之外再补三项：query 词与 `title`/`text` 的重合度、
   engagement 的对数映射（各源权重不同）、时间衰减。最后乘上源权重。
4. **每源保底** —— 每个源至少留 N 条（若过相关度底线），否则一个源刷屏会把别的源挤没。

权重与保底条数写在包内 `config.toml` 里，可调。这是**排序**，不是**判断**：
排序结果不等于结论，解读仍归调用者。

**空结果要诚实**：全部被过滤掉时输出「无结果」并说明是哪个源没数据，
不要用低相关条目填充。这条抄 last30days 的 "nothing-solid" 做法。

## 源适配器契约

包内 `lib/<源名>.sh`，用 `import <源名>` 加载（包私有模块，不进 `lib/core|std|ext`）。

每个源模块导出：

```bash
source.name           # 短名，等于子命令名
source.list           # 该源支持的能力：search / thread / comments / 其它
source.help           # 该源特有参数的说明文本
source.search         # 主入口，读公共变量，写 JSONL 到 stdout
```

公共变量由入口统一解析后传给源模块（`DIG_QUERY` / `DIG_LIMIT` / `DIG_PERIOD` / `DIG_JSON`），
源特有参数走透传。源模块**只管取数和转 schema**，不做排序美化。

网络请求一律走 `ext/requests`（超时、错误码、JSON 解析统一处理），GitHub 相关的走 `ext/github`。

约定：

- **keyless 优先**。需要密钥的源必须在 `source.help` 和 README 里写明，并在缺密钥时给出
  明确的「未配置 X，怎么配」提示，而不是静默返回空。
- **失败要响**。源挂了就报错退出，不要返回空数组假装「没搜到」，
  更不要把网络不通说成没有结果（本机很多源需要代理，见 `docs/sources.md`）。
- 聚合场景下单个源失败不拖倒全局，但要在输出里标注哪个源失败了。

## 目录

```
packages/dig/
├── dig.sh              # 入口：参数解析 + 子命令分发 + merge
├── lib/
│   ├── core|std|ext    # bashlet 链接
│   ├── schema.sh       # 条目 JSONL 构造与校验（本地时间、URL 规范化）
│   ├── merge.sh        # 去重 / 评分 / 合并
│   ├── hn.sh           # 各源适配器
│   └── ...
├── docs/
│   ├── design.md       # 本文件
│   └── sources.md      # 源清单：端点、密钥、限流、优先级（接线前先看这里）
├── config.toml         # 聚合权重、默认 limit / period
└── test/               # 与 lib 同名 *.bats
```

## 状态

只有文档与骨架，**尚未实现**。接线顺序：

1. `docs/sources.md` —— 源清单、端点、可达性、已知坑。接线前必读。
2. `schema.sh` + `merge.sh` —— 先把统一 JSONL 与聚合定下来，再加源。
3. P0 五个源：`hn` → `github` → `so` → `arxiv` → `zhihu`。
4. `dig doctor` —— 探活 + 说明该源缺什么（密钥 / 代理 / 外部命令）。
