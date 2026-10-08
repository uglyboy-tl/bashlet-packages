# BashDev

用 [bashlet](bashlet/README.md) 框架构建的命令行工具集合（monorepo）。每个包互相独立、可直接使用；
框架缺口在实现这些工具的过程中被发现，并按通用性判据沉淀回 bashlet。

## 包一览

| 包 | 做什么 |
| --- | --- |
| [`packages/apthist`](packages/apthist/README.md) | 分析 apt/dpkg 日志，列出最近 N 天安装或卸载的软件包 |
| [`packages/binup`](packages/binup/README.md) | 命令行程序的下载管理器：查 release、下载归档、备份旧版、解压安装 |
| [`packages/dig`](packages/dig/README.md) | 按站点取数的工具箱，配 research skill 使用 |
| [`packages/imagine`](packages/imagine/README.md) | 命令行文生图 / 图生图，一套参数调用所有 provider |
| `packages/archive` | 存档包，只保留历史代码，不计入全量测试 |

## 快速开始

```bash
git submodule update --init   # 拉 bashlet（唯一共享依赖）
tools/install                 # 补齐包内软链接

tools/test binup              # 跑指定包的测试
tools/test                    # 跑全部包，末尾附加文档校验
tools/build binup             # 产出 packages/binup/build/binup
tools/new my-script           # 新建包骨架
```

构建产物的落点由 `OUTPUT_DIR` 决定（环境变量 > 包内 `.env` > 包内 `build/`）。

## 文档

- [`AGENTS.md`](AGENTS.md)：工作指南（结构、包约定、命令），编码代理的入口；文档约定与权威顺序也在里面。
- [`CONTEXT.md`](CONTEXT.md)：领域词汇表。
- `docs/`：跨包规范（[`docs/env-example.md`](docs/env-example.md)）与仓库级决策（`docs/adr/`）。
- `packages/<包>/README.md`：单个包的用法；`SKILL.md` 与 `references/` 只在装了 skill 后随产物分发。
- [`bashlet/README.md`](bashlet/README.md)：框架 API 与模块分层。
