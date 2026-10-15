# binup

命令行程序的下载管理器（v2.3.0）：从 GitHub release 检查更新、下载二进制归档、备份旧版、解压安装。
安装目录优先 `/usr/local/bin`（可写时），否则 `~/.local/bin`。

## 用法

```bash
binup search lf                 # 搜索远端包目录（-r 忽略缓存强制刷新）
binup add uv lf                 # 从包目录添加包到本地配置（-f 覆盖已存在的配置）
binup list                      # 列出已配置的包
binup update                    # 检查所有已配置包的更新
binup upgrade uv                # 下载归档并按日期备份旧版
binup install uv                # 解压并安装
binup edit                      # 编辑配置文件（$EDITOR，默认 vi）
```

端到端：`binup search <关键词>` → `binup add <包名>` → `binup update && binup upgrade <包名> && binup install <包名>`。

包目录里有哪些包、按用途怎么分：见 [`catalog.md`](catalog.md)。

步骤分开是为了让你在 `update` 与 `upgrade` 之间看到版本变化，并在 `install` 前拿到归档（`download_dir`，默认为包内 `downloads/`）。

## 配置

包目录默认从远端拉取（`registry_url`，缓存 `registry_ttl` 小时），可用 `BINUP_REGISTRY_URL` 覆盖成自己的源。
本地落两份文件：`config.toml`（包声明）与 `versions.toml`（`current_version` / `latest_version` / `download_url`，由 `update` 写）。

包定义字段：`repo`（唯一必需，缺了不算已注册）、`version_type`（默认 `release`）、`file_pattern`（支持 `{os}` / `{arch}` / `{libc}` 与 `*` / `?`）、`file_extension`、`binary_name`。

`{libc}` 是 libc/ABI 风味占位符，自带前导 `-` 且整体可选，用于容忍上游按架构发不同风味（`-gnu` / `-gnueabihf` / `-musl` / `-musleabihf` / `-musleabi` / `-glibc` / `-softfloat`）或干脆不带风味。写成 `uv-{arch}-unknown-{os}{libc}` 而不是写死 `-gnu`——写死会在上游换风味时静默失效。

**收录门槛**：归档必须是单文件可执行，或几个各自独立可用的二进制（`uv`+`uvx`、`frpc`+`frps`、`yazi`+`ya`）；单文件压缩包（`.gz` / `.bz2` / `.xz`，如 restic）也算，但**必须配 `binary_name`**。
`install` 只把解压后「可执行且文件名不含点」的文件拷进安装目录，**依赖同级目录才能跑的包不能收**：
neovim 只拷 `bin/nvim` 会报 `E484: Can't open file /usr/local/share/nvim/syntax/syntax.vim`（runtime 在归档的 `share/nvim/`），
helix 只拷 `hx` 会报 `Runtime directory does not exist`（靠同级 `runtime/`）。
自检：解压后按上面那条 `find` 规则列出会被拷的文件，单独放进空目录里跑一次 `--version`。

下载与包目录的 GitHub 地址按宿主机 `git config --get-regexp 'url\..*\.insteadOf'` 改写（读 git 命令而非配置文件，`include` 也生效），
所以 git 里配过镜像就不必再为 binup 单独配一遍：

```ini
[url "https://gh-proxy.com/https://github.com/"]
	insteadOf = https://github.com/
```

映射范围由你的 git config 决定，想连 raw 域名也走镜像就再配一条 `https://raw.githubusercontent.com/` 的映射。API 请求（带 token 的那个）从不经过镜像。

## 环境变量

| 变量 | 用途 |
| --- | --- |
| `GITHUB_TOKEN` | GitHub API token；未设置时依次尝试 `gh auth token`、`pass "github"` |
| `BINUP_REGISTRY_URL` | 覆盖远端包目录 URL（优先于配置） |
| `EDITOR` | `binup edit` 用的编辑器，默认 `vi` |

## 开发

```bash
tools/test binup      # 39 条用例（test/ 下 10 个 .bats）
tools/build binup     # 产出 packages/binup/build/binup
```

注意：`add` 会就地修改真实配置文件，即使它是 dotbot 软链。
