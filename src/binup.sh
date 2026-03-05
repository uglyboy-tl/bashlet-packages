#!/usr/bin/env bash
# shellcheck disable=SC2034

set -euo pipefail
SCRIPT_NAME="BinUp"
VERSION="2.1.1"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

import core/log
import core/args
import core/config
import list
import update
import upgrade
import install
import edit

main() {
  args.init 命令行程序下载管理器

  args.add_options "version" "v" "显示版本信息"
  args.add_subcommand "list" "列出项目" "cmd_list"
  args.add_subcommand "update" "检查更新" "cmd_update"
  args.add_subcommand "upgrade" "下载二进制文件包" "cmd_upgrade"
  args.add_subcommand "install" "安装二进制文件" "cmd_install"
  args.add_subcommand "edit" "编辑配置文件" "cmd_edit"

  config.register "download_dir" "downloads" "string" "下载目录"
  config.register "proxy_prefix"
  config.register "log_level" "info"
  config.array.register "packages" "repo"
  config.array.register "packages" "version_type" ""
  config.array.register "packages" "file_pattern"
  config.array.register "packages" "file_extension"
  config.array.register "packages" "binary_name"
  config.array.register "packages" "current_version"
  config.array.register "packages" "latest_version"
  config.array.register "packages" "download_url"

  config.load
  SETTINGS_DOWNLOAD_DIR="$(config.get "download_dir")"
  SETTINGS_PROXY_PREFIX=$(config.get proxy_prefix)
  VERSIONS_FILE="$SETTINGS_DOWNLOAD_DIR/versions.toml"
  [[ -f $VERSIONS_FILE ]] || touch "$VERSIONS_FILE"
  config.load "$VERSIONS_FILE"
  log.setLevel "$(config.get log_level)"

  args.process "$@"
  args.has "-v" "--version" && usage.version && exit 0
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
fi
