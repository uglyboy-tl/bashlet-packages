#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

import core/args
import core/log
import core/config
import std/path
import common

cmd_edit() {
	args.init
	args.process "$@"

	local config_path
	config_path=$(config.path 2> /dev/null) || config_path="${_CONFIG_PATH:-$(path.config_dir)/config.toml}"
	[[ -f $config_path ]] || _create_default_config "$config_path"

	log.debug "配置文件: $config_path"

	"${EDITOR:-vi}" "$config_path" || {
		log.error "编辑器打开失败: ${EDITOR:-vi} $config_path"
		return 1
	}
}

_create_default_config() {
	local path="$1" dir="${1%/*}"
	[[ $dir != "$path" ]] && mkdir -p "$dir"
	cat > "$path" << 'EOF'
# BinUp 配置
# 注意: 本文件常常是 dotfiles 的软链（~/.config/binup/config.toml -> 仓库里的 xxx.toml），
#       `binup add` 会解析软链后就地改写真实文件，所以新增的包会直接出现在仓库里，记得提交。
#
# 每个包声明在 [packages.<名称>] 段中:
#   repo           = "owner/repo"           # GitHub 仓库
#   version_type   = "release"              # release(默认) | 其他(取 releases 列表首个)
#   file_pattern   = "<名称>-{os}-{arch}*"  # 占位符 {os}/{arch};支持 * 与 ?
#   file_extension = "tar.gz"               # 归档扩展名(可省略)
#   binary_name    = "<名称>"               # 归档内可执行文件名(单文件时可省略)
download_dir = "downloads"
log_level = "info"
# registry_url = "https://github.com/uglyboy-tl/bashlet-packages/raw/HEAD/packages/binup/registry.toml"  # 包目录 URL，search/add 使用
# registry_ttl = "24"                              # 包目录缓存有效期（小时）
EOF
}
