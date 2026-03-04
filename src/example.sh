#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$PROJECT_ROOT/lib/std/import.sh"

import core/log
import core/args
import core/config

main() {
	args.name "${SCRIPT_NAME:-Demo}"
	args.init

	args.add_options "version" "v" "显示版本信息"
	args.add_options "config" "c" "加载配置文件" "FILE"

	args.process "$@"

	args.has "-v" "--version" && usage.version && exit 0
	local config_file="$(args.get "-c" "--config")"
	[[ -n "$config_file" ]] && config.load "$config_file" || config.load || log.warn "无法加载配置文件"

	log.success "运行完成"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi