#!/usr/bin/env bash

import core/log
import core/args
import core/config

cmd_edit() {
	args.init
	args.process "$@"

	local -r config_path=$(config.path)

	# Create default config if it doesn't exist
	if [[ ! -f "$config_path" ]]; then
		create_default_config "$config_path"
	fi

	log.debug "配置文件: $config_path"

	# Open the editor
	"${EDITOR:-vi}" "$config_path" || ( log.error "编辑器打开失败: ${EDITOR:-vi} $config_path" && exit 1 )
}