# BashDev - 代理指南

本仓库是一个用于开发各种实用 Bash 脚本的通用开发环境，使用 bashlet 框架进行模块化开发。本指南为在本仓库中工作的代理编码代理提供必要信息。

## 项目结构

```
BashDev/
├── src/                # 各种脚本的入口文件目录
│   └── *.sh            # 不同功能脚本的主入口文件
├── lib/                # 脚本可引用的公共库文件（符号链接到 bashlet）
│   ├── core/           # 核心模块（args, log, config, usage）
│   ├── std/            # 标准库（array, map, string, console）
│   └── ext/            # 扩展库（requests, llm, select）
├── test/               # 测试目录
│   └── bats/           # Bats 测试框架
├── bashlet/            # Bashlet 框架子模块
└── build/              # 构建输出目录
```

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
# 初始化项目
git submodule update --init
bashlet/tools/install

# 测试
test/bats/bin/bats test/

# 检查和格式化
shellcheck src/*.sh lib/*.sh
shfmt -sr -s -ci -w src/*.sh lib/*.sh

# 构建
bashlet/tools/build src/my-script.sh -o my-tool
```

## 环境变量配置

可以在 import 之前添加 `.env` 语句，导入项目级全局变量：

```bash
#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

.env  # 导入 .env 文件，定义项目级全局变量

import core/log
import core/args
import ext/requests
```

**.env 文件示例**：

```bash
# API Keys
EXA_API_KEY="your-api-key"
GITHUB_TOKEN="ghp_xxx"

# 日志配置
_LOG_LEVEL="DEBUG"      # 显示 debug 信息
_LOG_USE_EXTRA=true     # 显示具体行号
```

## 核心模块使用规范

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

**不要直接使用 curl**，必须使用 `ext/requests` 模块（代码：`bashlet/lib/ext/requests.sh`）：

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

**常用函数**：
- `array.contains ARRAY VALUE` - 检查数组是否包含值
- `array.len ARRAY` - 获取数组长度
- `array.get ARRAY INDEX` - 获取指定索引元素
- `array.append ARRAY VALUES...` - 追加元素

### 日志输出（core/log）

```bash
import core/log

log.info "信息"
log.warn "警告"
log.error "错误"
log.debug "调试"
```