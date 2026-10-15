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

## Git、容器与代码托管

| 包 | 描述 |
| --- | --- |
| delta | git diff 的语法高亮分页器（Debian 同名 delta 包是另一个无关工具） |
| lazygit | git 的终端 UI |
| gitui | git 的终端 UI（Rust） |
| lazydocker | docker / compose 的终端 UI |
| gh | GitHub 官方命令行客户端 |

## 系统监控与信息

| 包 | 描述 |
| --- | --- |
| bottom | 跨平台终端系统监控（btm） |
| btop | 资源监控器（CPU / 内存 / 磁盘 / 网络） |
| procs | 现代 ps 替代（Rust） |
| sonar | 查看和管理本机监听端口的 CLI 工具 |
| fastfetch | 系统信息展示工具（neofetch 替代） |
| witr | 追踪进程 / 端口 / 容器 / 文件由谁启动（CLI + TUI） |

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

## 静态站点生成

| 包 | 描述 |
| --- | --- |
| hugo | 静态网站生成器（基础版） |
| hugo-extended | 静态网站生成器（扩展版，支持 SCSS / WebP，多数主题需要） |
