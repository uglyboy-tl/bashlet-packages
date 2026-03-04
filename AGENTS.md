# BashDev - 代理指南

本仓库是一个用于开发各种实用 Bash 脚本的通用开发环境，使用 bashlet 框架进行模块化开发。本指南为在本仓库中工作的代理编码代理提供必要信息。

## 项目结构

```
BashDev/
├── src/                # 各种脚本的入口文件目录
│   └── *.sh            # 不同功能脚本的主入口文件
├── lib/                # 脚本可引用的公共库文件
│   ├── core/           # 核心 bashlet 模块（符号链接）
│   ├── std/            # 标准 bashlet 模块（符号链接）
│   ├── ext/            # 扩展 bashlet 模块（符号链接）
│   └── *.sh            # 应用程序特定的公共库文件
├── test/               # 测试目录
│   ├── bats/           # Bats 测试框架（符号链接 -> bashlet/test/bats）
│   ├── test_helper/    # 测试辅助文件（含 common-setup.bash）
│   └── *.bats          # 各种具体测试文件
├── build/              # 构建输出目录
├── bashlet/tools/      # Bashlet 框架子模块提供的开发工具脚本
│   ├── build           # 构建脚本：将模块化脚本合并为单一文件
│   ├── test            # 测试脚本：运行 Bats 测试
│   └── install         # 初始化脚本：设置项目环境
├── .gitignore          # Git 忽略规则
└── .gitmodules         # Git 子模块配置
```

## 构建/检查/测试命令

### 初始化项目

```bash
# 初始化当前项目的 bashlet 子模块
git submodule update --init

# 初始化 bashlet 项目中的子模块
cd bashlet && git submodule update --init && cd ..

# 运行 bashlet 安装工具
bashlet/tools/install
```

### 测试

使用 **Bats** 进行测试。

```bash
# 运行所有测试
test/bats/bin/bats test/

# 运行单个测试
test/bats/bin/bats test/test.bats

# 常用参数：-p 漂亮输出，-t TAP格式，-j 并行执行，-r 递归，-f 过滤测试名
test/bats/bin/bats -p -j 4 -r -f "args" test/
```

### 检查（Linting）

```bash
# 检查 src 和 lib 目录下的文件（排除 bashlet 符号链接）
shellcheck src/*.sh lib/*.sh
```

### 格式化

```bash
# 格式化 src 和 lib 目录下的文件（排除 bashlet 符号链接）
shfmt -i 2 -ci -sr -w src/*.sh lib/*.sh

# 检查格式化
shfmt -i 2 -ci -sr -d src/*.sh lib/*.sh
```

### 构建

```bash
# 构建默认脚本（main.sh）
bashlet/tools/build

# 指定入口文件
bashlet/tools/build src/my-script.sh

# 指定输出文件
bashlet/tools/build -o my-tool src/my-script.sh
```

### 运行脚本

```bash
./src/script-name.sh
./build/script-name
```

## bashlet 使用指南

本项目使用 bashlet 框架进行模块化开发。bashlet 提供了完整的模块导入、命令行参数处理、配置管理等功能。

### 导入和依赖

在入口文件顶部导入 `import.sh`。由于 import.sh 依赖相对路径，需要根据脚本所在位置正确设置 `PROJECT_ROOT`：

```bash
#!/usr/bin/env bash
set -euo pipefail

# 脚本在 src/ 目录下时：
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 或者脚本直接在项目根目录下时：
# PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$PROJECT_ROOT/lib/std/import.sh"

# 导入 bashlet 核心模块
import core/log
import core/args
import core/config

# 导入 bashlet 标准库
import std/array
import std/map
import std/console

# 导入应用程序模块
import mymodule
```

### 命令行参数处理

使用 `core/args` 模块处理命令行参数：

```bash
main() {
    # 初始化，传入脚本描述
    args.init "我的脚本描述"

    # 添加选项：名称, 短选项, 描述
    args.add_options "verbose" "v" "显示详细信息"
    args.add_options "output" "o" "输出文件" "STRING"

    # 添加子命令：名称, 描述, 处理函数
    args.add_subcommand "list" "列出项目" "cmd_list"
    args.add_subcommand "install" "安装" "cmd_install"

    # 处理参数
    args.process "$@"

    # 检查选项
    if args.has "-v" "--verbose"; then
        echo "详细模式"
    fi

    # 获取选项值
    local output_file
    output_file=$(args.get "-o" "--output")
}

# 子命令处理函数
cmd_list() {
    args.init
    args.process "$@"
    # 处理 list 子命令
}
```

**args 模块常用函数：**
- `args.init [描述]` - 初始化参数解析
- `args.add_options 名称 短选项 描述` - 添加选项
- `args.add_subcommand 名称 描述 处理函数` - 添加子命令
- `args.process "$@"` - 处理命令行参数
- `args.has 选项...` - 检查选项是否存在
- `args.get 短选项 [长选项]` - 获取选项值

### 配置管理

使用 `core/config` 模块管理配置（TOML 格式）：

```bash
main() {
    # 注册配置项
    config.register "download_dir" "downloads" "string" "下载目录"
    config.register "max_workers" "4" "number" "最大并发数"

    # 注册数组配置
    config.array.register "packages" "repo"

    # 加载默认配置
    config.load

    # 加载自定义配置
    config.load "$HOME/.myapp/config.toml"

    # 获取配置值
    local dir
    dir=$(config.get "download_dir")

    # 获取数组项
    local items
    items=$(config.array.items "packages")

    # 获取数组项属性
    local version
    version=$(config.array.get "packages" "golang" "version")
}
```

**config 模块常用函数：**
- `config.register 名称 默认值 类型 描述` - 注册配置项
- `config.array.register 数组名 键名` - 注册数组配置
- `config.load [文件路径]` - 加载配置
- `config.get 名称` - 获取配置值
- `config.array.items 数组名` - 获取数组所有项
- `config.array.get 数组名 键 属性名` - 获取数组项属性

### 日志模块

使用 `core/log` 模块：

```bash
import core/log

log.info "信息日志"
log.success "成功"
log.warn "警告"
log.error "错误"
log.debug "调试信息"
```

### 控制台输出模块

使用 `std/console` 模块：

```bash
import std/console

console.info "信息"
console.success "成功"
console.warn "警告"
console.error "错误"

console.section "标题"
console.item.title 0 "项目标题"
console.item.mid "中间内容"
console.item.end "结束内容"
```

### 数组和映射操作

使用 `std/array` 和 `std/map` 模块：

```bash
import std/array
import std/map

# 数组操作
array.contains arr "value"
array.get arr 0
array.push arr "value"

# 映射操作
map.set mymap "key" "value"
map.get mymap "key"
map.has mymap "key"
map.keys mymap
```

## 仓库特定说明

- 这是一个 **通用 Bash 脚本开发环境**
- **Git 子模块** 用于 bashlet 框架
- 配置存储在 **TOML 格式** 文件中
- **Bats 测试框架** 通过符号链接集成在 `test/bats/` 目录中
- 构建输出保存在 `build/` 目录中
- 格式化时只处理 src 和 lib 目录下的非符号链接文件

## 开发工作流程

1. 编写脚本功能代码
2. 在 `test/` 目录下创建对应的测试文件
3. 运行测试确保功能正常
4. 提交前运行 shellcheck 检查代码
