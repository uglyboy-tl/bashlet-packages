#!/usr/bin/env bash
set -euo pipefail
SCRIPT_NAME="Dig"
VERSION="0.1.0"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

import core/args
import core/log

cmd_hello() {
	args.init
	args.process "$@"

	log.info "dig: hello"
}

main() {
	args.init "Dig - 简述这个包做什么"

	args.add_options "version" "v" "显示版本信息"
	args.add_subcommand "hello" "示例子命令" "cmd_hello"

	args.process "$@"
	args.has "-v" "--version" && usage.version && exit 0
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then main "$@"; fi
