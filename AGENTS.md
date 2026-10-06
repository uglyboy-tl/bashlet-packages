# BashDev - 代理指南

本仓库是一个用于开发各种实用 Bash 脚本的通用开发环境，使用 bashlet 框架进行模块化开发。本指南为在本仓库中工作的编码代理提供必要信息。

## 项目结构

```
BashDev/
├── packages/           # 各脚本包（每包自包含：入口 + lib + test + 资源）
│   ├── <包名>/           # 包根下恰好一个 *.sh 即入口（名即包名）
│   │   ├── <包名>.sh     # 入口
│   │   ├── lib/          # core/std/ext 链接（不入库）+ 包私有模块（import <模块名>）
│   │   ├── test/         # *.bats + bats/test_helper 链接（不入库）
│   │   ├── build/        # 构建产物（根 .gitignore 忽略）
│   │   └── ...           # 包自己的资源（如 binup/registry.toml）
│   └── archive/        # 存档包，只保留历史代码，不计入全量测试
├── lib/                # → bashlet/lib：框架工具链的接口（见下）
├── tools/              # 工作区入口：install / test / build / new（共享函数：tools/common.sh）
└── bashlet/            # Bashlet 框架子模块（唯一共享依赖）
```

包之间不互相 import；共享的只有 `bashlet`。包内 `lib/core|std|ext` 与 `test/{bats,test_helper}`
都**直连 bashlet**，逐项链接而不是整目录，以留出包私有模块的空间（`lib/<模块名>.sh`）。
包内这些链接**不入库**（规则在根 `.gitignore` 的 `packages/*/…`），由 `tools/common.sh` 的
`ensure_links` 幂等补齐；tools 下每个入口动手前都会调用它，所以克隆后执行任何一个 tools 命令
都会自动接好，`tools/install` 只是显式全量补齐（带包名则只补指定包）。

根级 `test/` 没有存在的价值，已删（没有任何引用）。根级 `lib/` **保留**，但它不是包内链接的
中转，而是 `bashlet/tools/build` 的接口：它把 `PROJECT_ROOT` 推导为消费仓库根，再
`source "$PROJECT_ROOT/lib/std/import.sh"`，而 `import.sh` 又由 `${BASH_SOURCE[0]%/*}/..`
推出 `_LIB_DIR`——所以根下必须有 `lib/{core,std,ext}`，删了 `tools/build` 直接报错。
这三个链接入库（直接调用 `bashlet/tools/build` 也能工作），`ensure_links` 会修复断链。

## 包约定

结构定下来后，这几条是硬约定（`tools/install`、`tools/build`、`tools/test` 都按它工作）：

- **入口**：包根下恰好一个 `*.sh`，名字等于包名；多一个就构建失败（`tools/build` 会报数量不符）。存档包（`archive`）豁免此约定，也不参与全量测试。
- **包边界**：包之间不互相 `import`，共享的只有 `bashlet`。需要跳包复用的东西先沉淀到框架。
- **包私有模块**：放 `lib/<模块名>.sh`，用 `import <模块名>` 加载；别放进 `lib/core|std|ext`（那是 bashlet 的链接）。
- **命名**：`_` 前缀 = 仅本文件使用；无前缀 = 可供其他文件调用；子命令处理器统一 `cmd_<子命令>`。
- **资源与产物**：包自己的数据/模板放包根（如 `binup/registry.toml`）；构建产物落 `OUTPUT_DIR`（环境变量 > 包内本地环境文件 > 包内 `build/`）。
- **忽略规则**：共通项（`build/`、`.env`）写在根 `.gitignore`；包内链接用 `packages/*/…` 逐项通配。包内 `.gitignore` 只放该包特有的东西（如 binup 的 `/downloads`）。
- **测试**：与模块同名（`lib/registry.sh` → `test/registry.bats`）；存档包不计入全量测试。
- **每个包的 `test/` 下都有 `test/setup.bash`**：bats 文件只 `load 'test_helper/common-setup'`、
  `load 'setup.bash'`，再写用例；`setup()` 里调 `setup.bash` 暴露的 `_<包>_setup`。
  只有单个 .bats 的包（imagine、apthist）也建一个，保持所有包的 test/ 结构一致。
- **测试里加载代码必须走 `_fast_load`**（定义在 `bashlet/test/test_helper/common-setup.bash`）：
  bats 会装 DEBUG trap 并开着 functrace，直接 `source` / `import` 会让被加载文件里的
  **每一条命令**都过一遍 trap——单个模块使 `import` 从 ~0 变成 325ms，一个包加载十几个模块
  就是 3s/条。setup 里**凡是有循环/解析的初始化**（如 `config.load` 逐行读 TOML）也要包进去。
  实测 binup 3.6s/条 → 0.27s，dig 3.3s/条 → 0.26s。下限约 0.08s/条（`bats-assert` 自身的加载，包不掉）。
  上游查证过：bats 是**有意** `set -eET`（`libexec/bats-core/bats-exec-test:2`，为 run() 的栈追踪），
  它唯一的官方排除机制 `BATS_DEBUG_EXCLUDE_PATHS` 实测对本问题无效；`set +T` 是当前唯一有效手段。
  细节与量级见 `common-setup.bash` 里 `_fast_load` 的注释。
- **本地环境**：包内环境文件必须在 `source .../import.sh` 之后、`import` 之前加载（`core/log` 在顶层读 `_LOG_LEVEL`），且不入库。

## 编程指南

1. **先测试后实现** - 实现功能前，先在命令行中测试命令，确认符合预期再添加到脚本中
2. **Debug 不猜测** - 遇到问题时，先在命令行中实测确认错误原因，再针对性修改
3. **清理旧代码** - 每次修改后，重新检查代码，删除不再需要的函数和测试用例
4. **提前退出（Guard Clauses）** - 函数开头处理边界情况，尽早退出
5. **解析但不验证（Parse, Don't Validate）** - 在边界解析数据，内部数据可信；使用 `||` 处理默认值
6. **快速失败（Fail Fast, Fail Loud）** - 无效状态立即报错，不尝试修补；使用 `requests.raise_for_status` 检查错误
7. **有意义命名（Intentional Naming）** - 名称即文档

## 构建/检查/测试命令

```bash
# 克隆后先拉子模块；包内软链接不入库，tools 下任何命令都会自动补齐
# （tools/install 只是显式全量补齐一次）
git submodule update --init
tools/install

# 测试（不带参数跑全部包；archive 存档包需显式指定）
tools/test
tools/test binup
# 末尾会打印总耗时：若 setup 里误在 functrace 下 source，单条会回到 3s 级，一眼能看出来

# 改动不涉及 bashlet 时，不必回归 bashlet 测试集；涉及框架模块或 tools/build 才需要
cd bashlet && tools/test -x requests

# 检查和格式化（archive/agent.sh 是历史 POSIX sh，一直有告警；imagine/lib 有几个 SC2086 info）
shellcheck packages/*/*.sh packages/*/lib/*.sh tools/*.sh tools/install tools/test tools/build tools/new
shfmt -sr -s -ci -w packages/*/*.sh packages/*/lib/*.sh tools/*.sh tools/install tools/test tools/build tools/new

# 构建（默认落在 packages/<包名>/build/<包名>；设了 OUTPUT_DIR 则落到那里）
tools/build binup

# 新建包骨架
tools/new my-script
```

## 包内环境与部署配置

每个包可以在自己的目录下放一个本地环境文件，在 import 之前加载（`core/log` 在顶层就读 `_LOG_LEVEL`，所以顺序不能反）：

```bash
#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 包根
source "$PROJECT_ROOT/lib/std/import.sh"

.env  # 加载包目录的本地环境（脚本目录优先，回退当前工作目录）

import core/log
import core/args
import ext/requests
```

该文件已被根 `.gitignore` 排除（常含密钥），内容示例：

```bash
# 构建产物落地位置；tools/build 优先读环境变量，其次这里，最后回落到包内 build/
OUTPUT_DIR="${HOME}/.local/share/dotfiles/scripts"

# bashlet core/log 的两个变量
_LOG_LEVEL="DEBUG"
_LOG_USE_EXTRA=true

# 密钥（不应进配置文件）
GITHUB_TOKEN="ghp_xxx"
```

非密钥的运行时配置仍用包自己的配置文件（如 binup 的 `config.toml`）。

## 核心模块使用规范

完整 API 见 `bashlet/README.md` 的函数速查；以下只列 BashDev 的常用用法与约定。

### 参数处理（core/args）

```bash
import std/string
import std/array
import core/args

# 定义枚举值
declare -ga VALID_TYPES=("neural" "keyword" "fast")

cmd_example() {
    args.init "示例命令"
    args.add_options "name" "n" "名称" "STRING"
    args.add_options "force" "f" "强制执行"
    args.add_options "limit" "l" "限制数量" "NUMBER"
    args.add_options "type" "t" "类型" "TYPE"
    args.process "$@"

    # 基本参数获取
    local name force_flag=""
    name="$(args.get "-n" "--name")" || name=""
    args.has "-f" "--force" && force_flag="--force"

    # 合并参数获取和自然数验证
    local limit="$(args.get "-l" "--limit")" && string.natural.check "$limit" || limit="10"

    # 合并参数获取和枚举验证
    local type="$(args.get "-t" "--type")" && array.contains VALID_TYPES "$type" || type=""
}
```

### 网络请求（ext/requests）

请求一律走 `ext/requests`（代码：`bashlet/lib/ext/requests.sh`）——它统一处理超时、请求头、错误码与 JSON 解析，直接 curl 会绕过这些：

需要缓存远端文件时用 `ext/requests.cache`（TTL + ETag/Last-Modified 条件请求），
需要跟 GitHub API 打交道时用 `ext/github`（release 查询、资产名匹配、contents 列表）。

```bash
import ext/requests

cmd_api() {
    requests.init
    requests.base_url "https://api.example.com"
    requests.headers.append "Authorization" "Bearer $TOKEN"

    # GET 请求
    local response=$(requests.get "/endpoint" "param=value")
    requests.raise_for_status "$response"
    response=$(requests.text "$response")

    # POST 请求
    response=$(requests.post "/endpoint" '{"key":"value"}' "application/json")
    requests.raise_for_status "$response"
}
```

### 字符串处理（std/string）

清理空格和类型检查（代码：`bashlet/lib/std/string.sh`）：

```bash
import std/string

# 清理空格
local query="${position_args[*]} $exact_query"
query="$(string.trim "$query")"

# 类型检查
string.int.check "$var" && echo "是整数"
string.natural.check "$var" && echo "是自然数"
```

### 数组操作（std/array）

数组包含检查（代码：`bashlet/lib/std/array.sh`）：

```bash
import std/array

array.contains my_array "value" && echo "存在"
```

### 日志输出（core/log）

```bash
import core/log

log.info "信息"
log.warn "警告"
log.error "错误"
log.debug "调试"
```