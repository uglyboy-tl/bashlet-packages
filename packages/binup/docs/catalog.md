# BinUp 包目录总览

`registry.toml` 里各包的人读版索引，按用途分类。**权威定义在 `registry.toml`**，本文件只做速查，两边不同步时以 `registry.toml` 为准。

追加/修改包的约定（`{libc}` 占位符、单文件可执行门槛）见 `README.md`。

## 运行时与工具链

| 包 | 描述 |
| --- | --- |
| bun | 一体化 JavaScript 运行时 / 打包器 / 测试器 / 包管理器 |
| uv | 极快的 Python 包与项目管理器（Rust） |
| ruff | 极快的 Python linter 与格式化器 |
| shfmt | Shell 脚本格式化工具 |
| just | 命令运行器（Makefile 替代） |
| hyperfine | 命令行基准测试工具 |
| opencode | 开源 AI 编码代理 |
| rtk | CLI 代理：把常见开发命令的 LLM token 消耗降低 60-90% |
| llmfit | 按本机硬件筛选能跑的模型 |
| shellcheck | shell 脚本静态分析工具 |
| direnv | 按目录自动加载 / 卸载环境变量 |
| dprint | 可插拔的多语言代码格式化平台 |
| claude | Anthropic 官方终端 AI 编码助手 |
| omp | 终端 AI 编码 agent（集成 LSP / 调试器） |
| bd | 给 AI 编码 agent 用的 Git 持久化记忆 / 任务 CLI |
| lightpanda | 启动极快、内存友好的无头浏览器 |
| abtop | 像 top 一样监控 AI agent 的 token / 上下文 / 限流 |

## 文件、搜索与文本

| 包 | 描述 |
| --- | --- |
| bat | 带语法高亮的 cat 替代 |
| eza | 现代 ls 替代 |
| fd | 更快的 find 替代 |
| fzf | 命令行模糊查找器 |
| lf | 终端文件管理器 |
| yazi | 极快的终端文件管理器（Rust） |
| ripgrep | 递归搜索工具（rg），grep 的更快替代 |
| sd | 更直观的 sed 替代 |
| dust | du 的可视化替代 |
| yq | YAML / JSON / XML / CSV / TOML / HCL 命令行处理器 |
| zoxide | 智能 cd 命令（z） |
| officecli | 面向 AI agent 的 Office 文档读写 CLI（.docx / .xlsx / .pptx） |
| wordcraft | Word 文档转换与检查 CLI（docx / pdf / odt / md / tex 互转；上游同包还带 GUI，只装 CLI） |
| gridcraft | Excel 电子表格（xlsx）的读表 / 算公式 / 转格式 CLI（上游同包还带 GUI，只装 CLI） |
| deckcraft | PowerPoint 演示文稿（pptx）的信息读取 / 幻灯片渲染成图 / 格式转换 CLI（上游同包还带 GUI，只装 CLI） |
| ast-grep | 基于语法树的搜索与重写（上游同包还带 sg 别名，只装 ast-grep） |
| lnav | 免配置的终端日志查看器，支持 SQL 与正则过滤 |
| czkawka | 查找并清理重复文件、空文件夹、相似图片（CLI 版） |

## Git、容器与代码托管

| 包 | 描述 |
| --- | --- |
| delta | git diff 的语法高亮分页器（Debian 同名 delta 包是另一个无关工具） |
| lazygit | git 的终端 UI |
| gitui | git 的终端 UI（Rust） |
| lazydocker | docker / compose 的终端 UI |
| gh | GitHub 官方命令行客户端 |
| ghq | 远程仓库按域与路径归置管理 |
| git-cliff | 按自定义模板从 Git 历史生成 Changelog |
| git-who | 按目录维度统计 git 各贡献者的提交与改动量 |
| lefthook | 快速的 Git hooks 管理器 |
| difftastic | 理解语法的结构化 diff 工具（difft） |

## 系统监控与信息

| 包 | 描述 |
| --- | --- |
| bottom | 跨平台终端系统监控（btm） |
| btop | 资源监控器（CPU / 内存 / 磁盘 / 网络） |
| procs | 现代 ps 替代（Rust） |
| sonar | 查看和管理本机监听端口的 CLI 工具 |
| fastfetch | 系统信息展示工具（neofetch 替代） |
| witr | 追踪进程 / 端口 / 容器 / 文件由谁启动（CLI + TUI） |
| duf | df 的现代化替代，磁盘空间与文件系统速查 |
| gdu | 磁盘占用分析器（TUI / 非交互 / 导出三模式） |

## 终端体验与复用

| 包 | 描述 |
| --- | --- |
| starship | 跨 shell 的极快提示符 |
| oh-my-posh | 可定制的 shell 提示符引擎 |
| atuin | 跨 shell 的命令历史管理，可选同步与加密 |
| glow | 终端 Markdown 渲染与阅读器 |
| gum | Shell 脚本的 UI 组件工具集 |
| zellij | 终端工作区与复用器 |
| herdr | 编码 agent 的终端运行时（工作区 / 窗格 / agent 编排） |

## 网络、代理与备份

| 包 | 描述 |
| --- | --- |
| frp | 内网穿透（frpc / frps） |
| sing-box | 通用代理平台 |
| rclone | 云存储同步与挂载（40+ 后端） |
| restic | 加密去重的备份工具（本地 / S3 / B2 / SFTP 等后端） |
| mc | MinIO / S3 兼容对象存储的客户端（上游仓库已归档，不会再更新） |
| chsrc | 全平台通用换源工具与框架 |
| xh | 友好的 HTTP 客户端（httpie 替代） |
| trippy | traceroute + ping 结合的网络诊断（TUI） |
| doggo | 彩色高亮的命令行 DNS 查询客户端（DoH / DoT） |
| q | 小型 DNS 客户端，支持 UDP / TCP / DoT / DoH / DoQ / ODoH |
| gping | 折线图实时展示 ping 延迟 |
| nbping | 多目标并发 ping，表格 / 折线可视化延迟与丢包 |
| ntr | 路由跟踪，显示途经 IP、归属地与耗时 |
| bandwhich | 按进程 / 连接实时查看网络带宽占用 |
| snitch | ss / netstat 替代的 TCP / UDP 连接查看器（TUI） |
| hurl | 用纯文本描述并校验 HTTP 请求 |
| kopia | 增量加密去重备份（本地 / S3 / B2 / SFTP 等后端） |

## 数据处理

| 包 | 描述 |
| --- | --- |
| jq | 命令行 JSON 处理器（事实标准） |
| fq | 二进制格式的 jq，用于二进制与文本格式的解析 |
| jc | 把常见命令的输出转成 JSON / YAML |
| dasel | 用同一套语法选择 / 修改 JSON / YAML / TOML / XML / CSV |
| miller | CSV / TSV / JSON 的 awk-sed-cut-join |
| xan | 处理 GB 级 CSV 的终端数据工具 |
| duckdb | 嵌入式分析型数据库的 SQL 命令行，可直接查 CSV / Parquet |
| sq | 用 SQL 查数据库与文档（jq 风格的数据源查询） |
| usql | 通用 SQL 数据库命令行（PostgreSQL / MySQL / SQLite / Oracle 等） |

## 安全与加密

| 包 | 描述 |
| --- | --- |
| age | 现代简洁的文件加密工具（X25519 + ChaCha20-Poly1305） |
| gitleaks | 检出并防止仓库中硬编码的密钥 |
| cosign | 签名与验证容器镜像 / 构建产物 |

## 文档处理

| 包 | 描述 |
| --- | --- |
| pandoc | 通用标记语言 / 文档格式互转 |
| typst | 类 LaTeX 的标记语言排版编译器，产出 PDF |

## 静态站点生成

| 包 | 描述 |
| --- | --- |
| hugo | 静态网站生成器（基础版） |
| hugo-extended | 静态网站生成器（扩展版，支持 SCSS / WebP，多数主题需要） |
