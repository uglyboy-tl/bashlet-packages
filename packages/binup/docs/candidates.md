# binup 包目录候选池

验证日期 **2026-10-15**｜脚本 `scripts/binup-check.sh`（用法与全部踩坑见 [`maintaining.md`](maintaining.md)）｜来源 **HelloGitHub 第 82-126 期**（2023-01 ~ 2026-09）＋ **x-cmd 包索引**（`x-cmd/install` 的 curated 2392 条，取其中走 `x eget` 装预编译二进制的 1413 条）｜star 为当天快照

判据：Linux 侧 arm64 + amd64 双份归档或裸二进制 → 反推的 `file_pattern` 实际选中预期资产 → 解压后「可执行且文件名不含点」恰好 1 个（或能被 `binary_name` 筛成 1 个），且能独立跑起来。

`file_pattern` 是脚本按资产名反推的，**落地前人工核对一遍**，特别是带日期（N_m3u8DL-RE 的 `_20260629`）或平台后缀不规则的。

本表的 `file_pattern` 列写的是**含扩展名的完整资产模板**；写进 `registry.toml` 时要把结尾的扩展名去掉、只保留
`file_extension`（binup 拼匹配正则时会自己把后缀拼回去，两处都写会一个资产也匹配不到）。

## 可入仓（75 个，全部通过 `--deep`）
| 包名 | 仓库 | star | 用途 | file_pattern | ext | binary_name |
| --- | --- | ---: | --- | --- | --- | --- |
| mkcert | FiloSottile/mkcert | 59745 | 生成本地受信开发证书 | `mkcert-v*-{os}-{arch}` | - | mkcert |
| dive | wagoodman/dive | 54639 | 逐层查看并瘦身 Docker / OCI 镜像 | `dive_*_{os}_{arch}.tar.gz` | tar.gz | - |
| mise | jdx/mise | 35026 | 多语言工具链版本切换 + 环境变量 + 任务自动化 | `mise-v*-{os}-{arch}` | - | mise |
| k9s | derailed/k9s | 34814 | 终端里操作 Kubernetes 集群 | `k9s_Linux_{arch}.tar.gz` | tar.gz | - |
| nuclei | projectdiscovery/nuclei | 32044 | 模板驱动的漏洞扫描 | `nuclei_*_{os}_{arch}.zip` | zip | - |
| opentofu | opentofu/opentofu | 30503 | 基础设施即代码，用配置语法管理云与本地资源 | `tofu_*_{os}_{arch}.zip` | zip | - |
| d2 | d2lang/d2 | 25619 | 把文本描述编译成图表的 CLI | `d2-v*-{os}-{arch}.tar.gz` | tar.gz | - |
| vegeta | tsenart/vegeta | 25221 | 恒定速率的 HTTP 负载测试 | `vegeta_*_{os}_{arch}.tar.gz` | tar.gz | - |
| superfile | yorukot/superfile | 23829 | 终端文件管理器，双栏 + 预览 | `superfile-{os}-v*-{arch}.tar.gz` | tar.gz | - |
| chezmoi | twpayne/chezmoi | 21934 | 跨机器管理 dotfiles | `chezmoi_*_{os}_{arch}.tar.gz` | tar.gz | - |
| migrate | golang-migrate/migrate | 18973 | 生成并管理多数据库的 SQL 迁移文件与版本 | `migrate.{os}-{arch}.tar.gz` | tar.gz | - |
| magika | google/magika | 18723 | 深度学习识别文件真实类型 | `magika-cli-{arch}-unknown-{os}{libc}.tar.xz` | tar.xz | - |
| upx | upx/upx | 17952 | 压缩可执行文件并保持可直接运行 | `upx-*-{arch}_{os}.tar.xz` | tar.xz | - |
| ffuf | ffuf/ffuf | 16889 | Web 目录与参数模糊测试 | `ffuf_*_{os}_{arch}.tar.gz` | tar.gz | - |
| lsd | lsd-rs/lsd | 16258 | 带图标 / 颜色的新一代 ls | `lsd-v*-{arch}-unknown-{os}{libc}.tar.gz` | tar.gz | - |
| task | go-task/task | 16250 | YAML 写法的 Makefile 替代构建工具 | `task_{os}_{arch}.tar.gz` | tar.gz | task |
| goreleaser | goreleaser/goreleaser | 16100 | 一键打包、签名、发布 Go 应用 | `goreleaser_Linux_{arch}.tar.gz` | tar.gz | - |
| dirsearch | maurosoria/dirsearch | 14959 | Web 路径 / 目录扫描器 | `dirsearch-v*-{os}-{arch}-async` | - | dirsearch |
| edit | microsoft/edit | 14703 | 微软开源的终端文本编辑器 | `edit-*-{arch}-{os}{libc}.tar.gz` | tar.gz | - |
| fscan | shadow1ng/fscan | 14681 | 一键内网资产发现与漏洞 / 弱口令扫描 | `fscan_*_{os}_{arch}` | - | fscan |
| gron | tomnomnom/gron | 14528 | 把 JSON 拍平成可 grep 的赋值语句 | `gron-{os}-{arch}-*.tgz` | tgz | - |
| litestream | benbjohnson/litestream | 14492 | SQLite 实时增量复制 / 备份到本地或云端 | `litestream-*-{os}-{arch}.tar.gz` | tar.gz | - |
| go2rtc | AlexxIT/go2rtc | 14382 | 多协议流媒体转换 | `go2rtc_{os}_{arch}` | - | go2rtc |
| grpcurl | fullstorydev/grpcurl | 12858 | 像 curl 一样请求 gRPC 服务 | `grpcurl_*_{os}_{arch}.tar.gz` | tar.gz | - |
| ttyd | tsl0922/ttyd | 12502 | 把终端通过 Web 分享出去，远程运维用 | `ttyd.{arch}` | - | ttyd |
| hadolint | hadolint/hadolint | 12478 | Dockerfile 静态检查 | `hadolint-{os}-{arch}` | - | hadolint |
| devbox | jetify-com/devbox | 12405 | 不依赖 Docker / VM 为项目开隔离开发环境 | `devbox_*_{os}_{arch}.tar.gz` | tar.gz | - |
| slides | maaslalani/slides | 11685 | 在终端里用 Markdown 写并演示幻灯片 | `slides_*_{os}_{arch}.tar.gz` | tar.gz | - |
| goose | pressly/goose | 11578 | SQL / Go 数据库迁移工具 | `goose_{os}_{arch}` | - | goose |
| rr | rr-debugger/rr | 10706 | Linux 上录制 / 重放 / 反向执行 C/C++ 调试 | `rr-*-Linux-{arch}.tar.gz` | tar.gz | - |
| oha | hatoo/oha | 10597 | HTTP 压测工具，带实时 TUI 动画 | `oha-{os}-{arch}` | - | oha |
| hexyl | sharkdp/hexyl | 10292 | 彩色输出、带类型标注的十六进制查看器 | `hexyl-v*-{arch}-unknown-{os}{libc}.tar.gz` | tar.gz | - |
| check-if-email-exists | reacherhq/check-if-email-exists | 10169 | 不发邮件，靠 DNS / SMTP 校验邮箱有效性 | `check_if_email_exists-{arch}-unknown-{os}{libc}.tar.gz` | tar.gz | - |
| websocat | vi/websocat | 8718 | WebSocket 版 netcat | `websocat.{arch}-unknown-{os}{libc}` | - | websocat |
| grex | pemistahl/grex | 8221 | 根据示例字符串自动生成正则表达式 | `grex-v*-{arch}-unknown-{os}{libc}.tar.gz` | tar.gz | - |
| tailspin | bensadeh/tailspin | 7991 | 开箱即用地高亮日志里的数字 / 日期 / IP / URL | `tailspin-{arch}-unknown-{os}{libc}.tar.gz` | tar.gz | - |
| dbmate | amacneil/dbmate | 7458 | 纯 SQL 的数据库迁移 CLI | `dbmate-{os}-{arch}` | - | dbmate |
| himalaya | pimalaya/himalaya | 7449 | 终端里的多账户邮件客户端，支持 IMAP/SMTP 与 PGP | `himalaya.{arch}-{os}.tgz` | tgz | - |
| gopass | gopasspw/gopass | 7257 | 命令行密码管理器（GPG 加密 + Git 同步） | `gopass-*-{os}-{arch}.tar.gz` | tar.gz | - |
| pastel | sharkdp/pastel | 6518 | 颜色生成 / 转换 / 对比 | `pastel-v*-{arch}-unknown-{os}{libc}.tar.gz` | tar.gz | - |
| clipboard | Slackadays/Clipboard | 5928 | 命令行剪贴板，终端里复制 / 剪切 / 粘贴 | `clipboard-{os}-{arch}.zip` | zip | - |
| tuios | Gaurav-Gosain/tuios | 5381 | 终端里的桌面级多窗口管理 | `tuios_*_Linux_{arch}.tar.gz` | tar.gz | - |
| kyanos | hengyoush/kyanos | 5075 | 基于 eBPF 实时抓取分析 HTTP / Redis / MySQL 请求 | `kyanos_*_{os}_{arch}.tar.gz` | tar.gz | - |
| freeze | charmbracelet/freeze | 4885 | 把代码片段或终端输出渲染成 PNG / SVG / WebP | `freeze_*_Linux_{arch}.tar.gz` | tar.gz | - |
| cliamp | bjarneo/cliamp | 4481 | Winamp 风格的终端音乐播放器 | `cliamp-{os}-{arch}` | - | cliamp |
| oxipng | oxipng/oxipng | 4278 | 多线程 PNG 无损压缩 | `oxipng-*-{arch}-unknown-{os}{libc}.tar.gz` | tar.gz | - |
| vfox | version-fox/vfox | 4002 | 统一管理多编程语言版本，替代 nvm/fvm/gvm | `vfox_*_{os}_{arch}.tar.gz` | tar.gz | - |
| ouch | ouch-org/ouch | 3788 | 一个命令解压所有格式 | `ouch-{arch}-unknown-{os}{libc}.tar.gz` | tar.gz | - |
| doxx | bgreenwell/doxx | 3772 | 终端里渲染阅读 .docx，支持搜索与导出 | `doxx-{arch}-unknown-{os}{libc}.tar.xz` | tar.xz | - |
| surge | SurgeDM/Surge | 3597 | 多线程 / 多镜像的终端下载器 | `Surge_*_{os}_{arch}.tar.gz` | tar.gz | - |
| kage | tamnd/kage | 3477 | 把网站抓成可离线浏览的副本 / `.zim` | `kage_*_{os}_{arch}.tar.gz` | tar.gz | - |
| tuicr | agavra/tuicr | 3382 | 终端代码审查，评论直发 GitHub / GitLab | `tuicr-*-{arch}-unknown-{os}{libc}.tar.gz` | tar.gz | - |
| ghz | bojand/ghz | 3358 | gRPC 服务压测工具 | `ghz-{os}-{arch}.tar.gz` | tar.gz | ghz |
| hl | pamburus/hl | 3304 | 把 JSON / logfmt 结构化日志高亮成可读格式 | `hl-{os}-{arch}{libc}.tar.gz` | tar.gz | - |
| dblab | danvergara/dblab | 3241 | 交互式 TUI 数据库客户端（PostgreSQL / MySQL / SQLite / Oracle） | `dblab_*_{os}_{arch}.tar.gz` | tar.gz | - |
| URLFinder | pingc0y/URLFinder | 3192 | 从网页与 JS 文件里提取 URL、API 接口 | `URLFinder_Linux_{arch}.tar.gz` | tar.gz | - |
| tabiew | shshemi/tabiew | 3137 | 终端里交互式浏览、SQL 查询 CSV / Parquet / Excel | `tw-{arch}-unknown-{os}{libc}` | - | tw |
| pop | charmbracelet/pop | 2923 | 终端用命令行或 TUI 发邮件，可管道读入正文 | `pop_*_Linux_{arch}.tar.gz` | tar.gz | - |
| skillshare | runkids/skillshare | 2788 | 一条命令在多个 AI 工具间同步 skills / 提示词 | `skillshare_*_{os}_{arch}.tar.gz` | tar.gz | - |
| gonzo | control-theory/gonzo | 2783 | k9s 风格的终端实时日志分析与过滤 | `gonzo-*-{os}-{arch}.tar.gz` | tar.gz | - |
| numbat | sharkdp/numbat | 2763 | 带物理单位换算的命令行科学计算器 | `numbat-v*-{arch}-unknown-{os}{libc}.tar.gz` | tar.gz | - |
| bunster | yassinebenaid/bunster | 2679 | 把 shell 脚本转译为 Go 再编译成单文件二进制 | `bunster_{os}-{arch}.tar.gz` | tar.gz | - |
| muffet | raviqqe/muffet | 2616 | 递归爬取站点并检查所有页面死链 | `muffet_{os}_{arch}.tar.gz` | tar.gz | - |
| oryx | pythops/oryx | 2594 | eBPF 抓取并可视化 Linux 实时网络流量 | `oryx-{arch}-unknown-{os}{libc}` | - | oryx |
| f2 | ayoisaiah/f2 | 2454 | 正则批量重命名文件，带冲突处理与撤销 | `f2_*_{os}_{arch}.tar.gz` | tar.gz | - |
| kondo | tbillington/kondo | 2450 | 清理项目里的 node_modules / target | `kondo-{arch}-unknown-{os}{libc}.tar.gz` | tar.gz | - |
| ls-lint | loeffel-io/ls-lint | 2429 | 按 YAML 规则检查目录 / 文件命名风格 | `ls-lint-{os}-{arch}` | - | ls-lint |
| serie | lusingander/serie | 2144 | 可视化浏览 git 提交历史 | `serie-*-{arch}-unknown-{os}{libc}.tar.gz` | tar.gz | - |
| kibi | ilai-deutel/kibi | 1954 | 不到 1024 行 Rust 写的命令行文本编辑器 | `kibi-v*-{arch}-unknown-{os}{libc}.tar.gz` | tar.gz | - |
| sql-tap | mickamy/sql-tap | 1591 | 解析 wire 协议实时监控 SQL 流量 | `sql-tap_*_{os}_{arch}.tar.gz` | tar.gz | sql-tap |
| buildg | ktock/buildg | 1501 | 基于 BuildKit 交互式调试 Dockerfile，可断点单步 | `buildg-v*-{os}-{arch}.tar.gz` | tar.gz | - |
| sttr | abhimanyu003/sttr | 1354 | 字符串转换工具箱（编码 / 解码、哈希、格式化） | `sttr_Linux_{arch}.tar.gz` | tar.gz | - |
| gitmal | antonmedv/gitmal | 1343 | 把 Git 仓库一键生成静态浏览网站 | `gitmal_{os}_{arch}` | - | gitmal |
| quien | retlehs/quien | 1289 | 交互式终端域名分析（WHOIS/RDAP、DNS、TLS） | `quien_{os}_{arch}.tar.gz` | tar.gz | - |
| termshot | homeport/termshot | 975 | 把命令输出渲染成带语法高亮和窗口边框的终端截图 | `termshot_*_{os}_{arch}.tar.gz` | tar.gz | - |


> 另有 **42 个**已于 2026-10-15 收录进 bashlet-packages 的 `packages/binup/registry.toml`（当时按用途分节，现已统一为字母序），已从下表移除；2026-10-16 又直接收录了同上游作者的 `gridcraft` / `deckcraft`（未进过本表）。

两点要留意：

- **裸二进制必须配 `binary_name`**。binup 先把资产存成 `<包名>-<版本>[.ext]`，解压阶段再截到第一个点之前（`dirsearch-0`、`dbmate-2`、`icloud_photos_downloader-1`），不配就会装出这种名字。表里 `binary_name` 是脚本按 pattern 反推的，**复杂命名（icloudpd、tabiew→tw、sttr）要人工确认一遍**。
- arm64 侧全部实跑过。少数没有 `--version` 子命令（`sttr`、`snitch`、`lazyssh`、`gitmal`、`make-look-scanned`、`NBping`、`freeze`），`lightpanda` 用 `version` 子命令；`ffmpeg-over-ip-client` 需要配置文件；`task` / `sql-tap` / `doxx` / `hurl` / `czkawka`（带 `_heif_raw_avif_` / `_musl` 变体）的归档里除二进制外还有别的东西，靠 `binary_name` 筛。

## 入库判据

先看现有 registry 的 49 个包有什么共性，再看真正热门的 CLI 有什么共性，提炼成四条：

1. **是管道里的零件** - `fd` / `rg` / `jq` / `yq` / `sd` / `xh` / `bat` / `delta` 都能 `|` 起来，输入输出干净
2. **无法被系统内置或几行 shell 廉价替代** - `fzf` 的交互、`just` 的依赖图、`restic` 的去重加密、`freeze` 的图形渲染，都不是拼几行命令能顶掉的
3. **受众是「所有命令行用户」**，而不是某个语言或某个云服务的用户
4. **没有娱乐工具** - 现有 49 个里一个都没有

按这四条砍掉的 20 个：

| 类别 | 被砍 | 理由 |
| --- | --- | --- |
| 娱乐 / 观赏性 | genact、weathr、gitlogue | 不解决任何实际问题 |
| 可被内置或 shell 替代 | simple-http-server（`python3 -m http.server`）、tldx（`for` + `dig`）、cheat（`rg` + 本地 md，它就是「文本 + 搜索」）、lazyssh（`ssh` + config + `fzf`）、eget（与 binup 本体重复）、landrun（`bwrap` / `firejail` 更成熟） | 有廉价等价物 |
| 单一语言 | go-size-analyzer、gosec、sqlc、go-blueprint（Go 专用）、austin（CPython 专用） | 受众半径窄 |
| 单一服务 | icloudpd、DepotDownloader、feishu2md、N_m3u8DL-RE、make-look-scanned、ffmpeg-over-ip | 只服务某一个平台或场景 |

「功能重复」本身不算问题（重复说明需求大），但**同一抽象层的实现**算：`lsd` vs 已在库的 `eza`、`gdu` vs `dust`、`superfile` vs `yazi` + `lf`、`kibi` vs `edit`、`hl` vs `tailspin`、`NBping` vs `gping` —— 这些最后决定保留，但心里有数。

## 剔除与未入库

- **不是独立二进制**：broot、bacon、dysk（单 zip 含多平台，解压出多个同名二进制互相覆盖）、DiscordChatExporter（.NET 依赖同级 `.dll`）、smolvm（154 个文件）、git-filter-repo、iotop、sshfs、rsync、trurl、mosh（源码包）、cloc（Perl 脚本）、helix（runtime 目录必须同级）、micro（arm64 是 `linux-arm64`、amd64 是 `linux64`，命名对不上）、ImageMagick（7z / AppImage 命名不规则）、pdm / zensical / cronboard / harlequin / manga-image-translator（Python 包）、allure2（Java，需 JRE）、ipatool（二进制在 `bin/` 下且名字含点）
- **release 无资产**：black、hey、watermarks-remover、ccstatusline、whichllm、docmd、ASCILINE、visidata、sqlit、OnnxSlim、qmd、docling、term.everything、gemini-cli、vulture、cmus、buku、toolong、khal、pyupgrade、sshx、nvitop、watchgha、dperf、skopeo、xdotool、bandit、YouPlot
- **只有单侧架构**：clifm、GeminiWatermarkTool、objcurses、rendercv、checkov、k3sup、verus、Diagon、code2prompt、kanata、minisign、aria2、dockerc、video2x、pspy、Ciphey、gorss、onefetch
- **需要系统依赖，装了也跑不起来**：git-credential-manager（缺 libicu，rc=134）、isd（AppImage 缺 fusermount3，rc=127）、carbonyl（rc=127）
- **上游版本 / 资产异常**：vector（latest 指向 dev tag）、borg（两侧 glibc 版本号与后缀都不同）、ollama（release 里没有 Linux 归档）、OpenBB（只有 macOS dmg 与 Windows exe）
- **技术合格但不收**：App-Store-Connect-CLI（只服务 iOS 生态）

## 规律

- HelloGitHub 的约 200 个候选筛出 83 个（约四成）；x-cmd 索引再补 34 个，合计 117 个。主要死在：不是单文件可执行、release 里没有 Linux 二进制、只有单侧架构，以及上面那套入库判据。
- **x-cmd 的索引是广度优先、几乎不过滤**：2392 条里有成片的 neofetch 变体（stormy、mufetch、steamfetch）、聊天客户端（Discord / Signal / Matrix / Twitch）、刚发布的新 TUI，以及某一朵云专用的 CLI（cloud-public / cloud-tool 就有 22 个）。它的价值在于供给面广（尤其是数据管道类：jq / fq / gron / jc / dasel / miller / sq），但“同一条管道里能不能替掉某个经典命令”这一层过滤得我们自己做 —— 这轮 34 个就是这层过滤的产物。
- 固定八个坑（都已进脚本）：多平台合一的单个 zip；源码或 Python 包伪装成 release 归档；资产名自带 `.sha256` / `.pem` / `.yml` 旁车文件（名字比正式归档短，会抢占「名字长度优先」）；`mac-` / `ios` / `android` 简写没排除干净；裸二进制被截断成 `foo-0`；`--version` 以 rc≥126 退出说明缺系统库；编辑器类把 runtime 放在归档同级目录；`.gz` 单文件包必须配 `binary_name`。
- Go / Rust 是绝对主力，裸二进制基本都能直接跑；Python / JS 项目几乎不出预编译二进制。
- 月刊里 CLI/TUI 约占 10-12%，主体是 GUI、Web 平台、AI agent 与技能包。
- 品类随时间漂移：2026 年（124 期往后）AI agent 周边密集（omp、claude、abtop、skillshare、bd）；2025 下半年偏终端可视化与 Git 工具（tuios、gitlogue、gitmal、serie）；2025 上半年多网络与运维（hurl、oha、doggo、kyanos、oryx、go2rtc、litestream）；2023-2024 则集中在经典命令行替代品（lsd、gdu、cheat、gping、lazyssh、superfile）。

## 待办

- [x] 第一批 42 个已写进 `registry.toml` 与 `docs/catalog.md`（2026-10-15），本表剩 75 个待定
- [ ] 已覆盖第 82-126 期（2023-01 ~ 2026-09），如需继续往 81 期之前推
