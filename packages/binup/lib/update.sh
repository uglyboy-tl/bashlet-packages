#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

import core/args
import core/log
import core/config.persist
import ext/github
import std/fs
import std/console
import std/console.layout
import common

# ===== GitHub 发布 =====

# 输出: VERSION|||URL
_get_latest_version_and_url() {
	local repo="$1" version_type="${2:-release}" pattern="$3" ext="${4:-}"
	local build_pattern mode="any"

	build_pattern=$(github.asset.pattern "$pattern" "$ext")
	log.debug "Matching regex: $build_pattern"

	[[ $version_type == "release" ]] && mode="stable"
	github.release.pick "$repo" "$build_pattern" "$mode"
}

# ===== 版本信息持久化 =====

_save_latest_info() {
	[[ $# -lt 3 ]] && return 1
	config.persist.update "packages" "$1" "latest_version" "$2" "$VERSIONS_FILE"
	config.persist.update "packages" "$1" "download_url" "$3" "$VERSIONS_FILE"
}

# ===== 并发检查 =====

# 单个包的更新检查，结果写入 $2：<status>\t<latest>\t<url>
# status: ok | fetch-fail | parse-fail
_check_package_latest() {
	local package="$1" result_file="$2"
	local repo version_type file_pattern file_extension latest_info latest_version download_url

	repo="$(get_package_property "$package" "repo")"
	version_type="$(get_package_property "$package" "version_type")"
	file_pattern="$(get_package_property "$package" "file_pattern")"
	file_extension="$(get_package_property "$package" "file_extension")"

	latest_info="$(_get_latest_version_and_url "$repo" "$version_type" "$file_pattern" "$file_extension")" || {
		printf 'fetch-fail\t\t\n' > "$result_file"
		return 0
	}
	latest_version="${latest_info%%|||*}"
	download_url="${latest_info#*|||}"
	[[ -n $latest_version && -n $download_url ]] || {
		printf 'parse-fail\t\t\n' > "$result_file"
		return 0
	}
	printf 'ok\t%s\t%s\n' "$latest_version" "$download_url" > "$result_file"
	return 0
}

cmd_update() {
	args.init
	args.add_options "all" "a" "连已禁用的包一起检查（默认跳过）"
	args.process "$@"

	ensure_download_dir
	github_token
	requests.available || {
		log.error "缺少依赖：curl 或 jq"
		exit 1
	}
	requests.init "-4" 2> /dev/null

	local -a registered_packages=() packages_to_check=() disabled_packages=()
	mapfile -t registered_packages < <(get_default_registered_packages)

	local check_all=false
	args.has "-a" "--all" && check_all=true

	local package
	for package in "${registered_packages[@]}"; do
		if [[ $check_all == true ]] || package_is_enabled "$package"; then
			packages_to_check+=("$package")
		else
			disabled_packages+=("$package")
		fi
	done

	console.layout.section "检查更新"

	if ((${#disabled_packages[@]} > 0)); then
		console.layout.item.title 0 "跳过 ${#disabled_packages[@]} 个已禁用的包: ${disabled_packages[*]}"
	fi

	if ((${#packages_to_check[@]} == 0)); then
		console.layout.footer "没有需要检查的包"
		return 0
	fi

	# 并发检查：GitHub API 的并发上限是 100（官方文档），6 个并发远低于阈值；
	# 总请求数与串行完全一致，primary/secondary rate limit 压力不变，收益只是掩盖单次 RTT。
	# 结果先落临时文件，回到主进程再按原顺序输出并串行写 versions.toml，避免子 shell 抢同一个文件。
	local concurrency="${BINUP_UPDATE_CONCURRENCY:-6}"
	[[ $concurrency =~ ^[1-9][0-9]*$ ]] || concurrency=6

	local tmp_dir
	tmp_dir=$(fs.mktemp "-d") || return 1

	local -a pids=()
	for package in "${packages_to_check[@]}"; do
		# 后台作业里不要写 stdout：输出会在并发下交错
		_check_package_latest "$package" "$tmp_dir/$package" &
		pids+=($!)
		if ((${#pids[@]} >= concurrency)); then
			wait "${pids[0]}" 2> /dev/null || true
			pids=("${pids[@]:1}")
		fi
	done
	if ((${#pids[@]} > 0)); then
		wait "${pids[@]}" 2> /dev/null || true
	fi

	local result status latest_version download_url current_version
	local pending_count=0 latest_count=0 failed_count=0
	for package in "${packages_to_check[@]}"; do
		result="$(cat "$tmp_dir/$package" 2> /dev/null)" || result=""
		status=""
		latest_version=""
		download_url=""
		IFS=$'\t' read -r status latest_version download_url <<< "$result" || true

		case "$status" in
			ok)
				_save_latest_info "$package" "$latest_version" "$download_url" || {
					console.layout.item.title 1 "$package: 版本信息写入失败"
					((failed_count++)) || true
					continue
				}
				current_version="$(get_package_property "$package" "current_version")"
				if [[ -z $current_version ]]; then
					console.layout.item.title 1 "$package: 未下载 (最新: $latest_version)"
					((pending_count++)) || true
				elif [[ $current_version != "$latest_version" ]]; then
					console.layout.item.title 1 "$package: 有新版本 $current_version $POWERLINE_POINTING_ARROW $latest_version"
					((pending_count++)) || true
				else
					# 「已是最新」不逐包展示：49 个包里绝大多数都是它，汇总到 footer 一行
					((latest_count++)) || true
				fi
				;;
			fetch-fail)
				console.layout.item.title 1 "$package: 获取版本失败"
				((failed_count++)) || true
				;;
			*)
				console.layout.item.title 1 "$package: 获取版本信息失败"
				((failed_count++)) || true
				;;
		esac
	done

	rm -rf "$tmp_dir"

	console.layout.footer "共 ${#packages_to_check[@]} 个包：$pending_count 个待下载，$failed_count 个失败，$latest_count 个已是最新"
	((pending_count > 0)) && console.stdout "运行 \`$_USAGE_SCRIPT_FILENAME upgrade\` 下载更新"
	((latest_count > 0)) && console.stdout "逐包详情: \`$_USAGE_SCRIPT_FILENAME list\`"
	return 0
}
