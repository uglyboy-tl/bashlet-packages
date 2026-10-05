# dig

按站点取数的工具箱 —— 给一批有价值的站点各写一个适配器，把那个站点上「用关键词能捞到
的东西」（帖子、正文、评论、热度、时间）以统一结构吐出来，再用本地启发式做轻量聚合。

**不是通用搜索引擎**。排序与解读留给调用者；dig 只负责取准、取全、说清哪里取不到。

## 用法（规划中）

```bash
dig hn "bash 数组"       # Hacker News
dig github "timefmt"     # GitHub issue / 讨论（走 gh）
dig so "bash array slice"
dig arxiv "retrieval eval"
dig zhihu "..."          # 知乎官方开放平台
dig merge 结果.jsonl      # 多源去重 + 加权融合
dig doctor               # 探活：哪个源缺密钥 / 缺代理 / 缺外部命令
```

公共参数：`-n/--limit`、`-p/--period`、`--json`（JSONL）、`-o/--output`、`DIG_PROXY`。

## 文档

| 文件 | 内容 |
| --- | --- |
| `docs/design.md` | 定位、CLI 形态、条目 schema、源适配器契约、聚合规则、代理要求 |
| `docs/sources.md` | **接线前必读**：源优先级、端点速查、本机可达性实测、中文站点结论、已知坑 |

## 开发

```bash
tools/test dig        # 只跑这个包
tools/build dig       # 产出 packages/dig/build/dig
```

当前状态：**只有文档与骨架，尚未实现**。
