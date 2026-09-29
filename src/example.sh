#!/usr/bin/env bash
# 最小脚本骨架。tools/install 会把它安装为宿主项目的 src/example.sh。
set -euo pipefail
SCRIPT_NAME="Demo"
VERSION="1.0.0"
PROJECT_ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

.env # 可选：加载 .env（脚本目录优先，回退当前工作目录）

import core/args
import core/log
# import core/config          # 需要配置读写时打开
# import core/config.persist  # 需要写盘时打开
# import std/console.layout   # 需要 section/条目输出时打开

main() {
	args.init "示例脚本"
	args.add_options "version" "v" "显示版本信息"
	args.process "$@"

	args.has "-v" "--version" && usage.version && exit 0

	log.success "运行完成"
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then main "$@"; fi
