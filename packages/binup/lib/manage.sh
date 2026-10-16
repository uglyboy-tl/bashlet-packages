#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

import core/args
import core/log
import core/config
import core/config.persist
import std/console
import std/console.layout
import common

# ===== 本地包配置管理：enable / disable / remove =====

# 批量切换 enabled：$1=目标值(false/true) $2=标题 $3=动词，其余为包名
_toggle_packages() {
	local value="$1" title="$2" verb="$3"
	shift 3
	local -a packages=("$@")

	((${#packages[@]})) || {
		log.error "请指定包名: $_USAGE_SCRIPT_FILENAME $verb <包名>"
		return 1
	}

	local config_file
	config_file="$(resolve_config_file)" || return 1

	console.layout.section "$title"

	local package count=0 failures=0 currently_enabled
	for package in "${packages[@]}"; do
		if ! is_package_in_default_config_with_repo "$package"; then
			log.error "Unknown package: $package"
			((failures++)) || true
			continue
		fi

		currently_enabled="true"
		package_is_enabled "$package" || currently_enabled="false"
		if [[ $currently_enabled == "$value" ]]; then
			console.layout.item.title 0 "$package 已处于目标状态，无需改动"
			((count++)) || true
			continue
		fi

		if ! config.persist.update "packages" "$package" "enabled" "$value" "$config_file"; then
			log.error "$package: 写入配置失败"
			((failures++)) || true
			continue
		fi
		console.layout.item.title 0 "$POWERLINE_OK $package 已$verb"
		((count++)) || true
	done

	package_reset_cache

	if ((failures > 0)); then
		log.error "$failures 个包处理失败"
		return 1
	fi
	console.layout.footer "共 ${#packages[@]} 个包，$count 个已$verb"
	return 0
}

cmd_enable() {
	args.init
	args.add_options "arg" "待启用的包名" "必填：启用后重新参与 update 检查"
	args.process "$@"

	local -n targets="$(args.args)"
	_toggle_packages "true" "启用包" "启用" "${targets[@]}"
}

cmd_disable() {
	args.init
	args.add_options "arg" "待禁用的包名" "必填：禁用后 update 不再检查其更新"
	args.process "$@"

	local -n targets="$(args.args)"
	_toggle_packages "false" "禁用包" "禁用" "${targets[@]}"
}

cmd_remove() {
	args.init
	args.add_options "arg" "待移除的包名" "必填：只删本地配置，不删已安装的二进制"
	args.add_options "purge" "p" "同时删除已下载的归档与备份"
	args.process "$@"

	local -n targets="$(args.args)"
	((${#targets[@]})) || {
		log.error "请指定包名: $_USAGE_SCRIPT_FILENAME remove <包名>"
		return 1
	}

	local config_file
	config_file="$(resolve_config_file)" || return 1

	local purge=false
	args.has "-p" "--purge" && purge=true

	# download_dir 为空时 glob 会退化成 /<包名>-*，在根目录扫同名文件；宁可不删也不误删
	if [[ $purge == true && -z $SETTINGS_DOWNLOAD_DIR ]]; then
		log.error "download_dir 为空，拒绝执行 --purge（避免在根目录误删同名文件）"
		return 1
	fi

	console.layout.section "移除包"

	local package count=0 failures=0
	for package in "${targets[@]}"; do
		# 这里走文件判断而非内存缓存（同进程删掉一个包后缓存会过期），所以白名单必须在这条路径上单独挡一次：
		# 否则 [packages.../evil] 这种键会让 --purge 的 glob 扫到 download_dir 之外
		package_name_is_valid "$package" || {
			log.error "包名非法（只允许字母/数字/下划线/连字符）: $package"
			((failures++)) || true
			continue
		}
		if ! grep -qF "[packages.$package]" "$config_file" 2> /dev/null; then
			log.error "Unknown package: $package"
			((failures++)) || true
			continue
		fi

		if ! config.persist.remove_section "packages.$package" "$config_file"; then
			log.error "$package: 删除配置失败"
			((failures++)) || true
			continue
		fi
		# versions.toml 清理失败不该中断整批 remove：主配置已经删了，这里降级为告警继续处理后面的包
		config.persist.remove_section "packages.$package" "$VERSIONS_FILE" ||
			log.warn "$package: 版本记录清理失败（$VERSIONS_FILE）"

		if [[ $purge == true ]]; then
			# 归档按 <包名>-<版本>.<扩展名> 命名，连字符保证不误伤同前缀的包（uv 不会命中 uvx-*）
			rm -f "$SETTINGS_DOWNLOAD_DIR/${package}-"* "$SETTINGS_DOWNLOAD_DIR/backups/${package}-"* 2> /dev/null &&
				console.layout.item.title 0 "$POWERLINE_OK $package 已从配置移除（归档与备份已删除）" ||
				{
					log.warn "$package: 配置已移除，但归档删除失败（权限不足或只读挂载）"
					((failures++)) || true
				}
		else
			console.layout.item.title 0 "$POWERLINE_OK $package 已从配置移除"
		fi
		((count++)) || true
	done

	package_reset_cache

	if ((failures > 0)); then
		log.error "$failures 个包处理失败"
		return 1
	fi
	# 不在这里重复「归档删没删」：上面每个包的 item 已经逐条说明了
	console.layout.footer "共 ${#targets[@]} 个包，$count 个已移除"
	return 0
}
