#!/usr/bin/env bash

import std/system
import std/console
import core/args
import core/config
import ext/requests
import utils

# 初始化
requests.init "-4" 2> /dev/null || { log.error "Failed to initialize requests module" && exit 1; }

[[ -n ${GITHUB_TOKEN:-} ]] && requests.headers.append "Authorization" "token $GITHUB_TOKEN"

# 架构正则映射
_get_arch_regex() {
  case "$(system.arch)" in
  amd64) echo "(x86_64|x64|amd64)" ;;
  arm64) echo "(aarch64|arm64)" ;;
  armhf) echo "(armv7l|armhf|armv7hl|armv7l-unknown)" ;;
  i386) echo "(i686|i386|i586)" ;;
  *) echo "$(system.arch)" ;;
  esac
}

# 构建匹配模式
_build_pattern() {
  local pattern="$1"
  pattern="${pattern//\{os\}/$(system.os)}"
  pattern="${pattern//\{arch\}/$(_get_arch_regex)}"
  pattern="${pattern//\*/.*}"
  pattern="${pattern//\?/.}"
  [[ -n ${2:-} ]] && echo "${pattern}[.][^.]*${2}$" || echo "${pattern}$"
}

# 获取 GitHub Release
_github_fetch_release() {
  local response=$(requests.get "https://api.github.com/repos/$1/releases")
  requests.raise_for_status "$response" || return 1
  [[ ${2:-release} == "release" ]] && requests.json "$response" '[.[] | select(.prerelease == false)][0]' || requests.json "$response" '.[0]'
}

# 获取最新版本和下载 URL (输出: VERSION|||URL)
get_latest_version_and_url() {
  local latest=$(_github_fetch_release "$1" "${2:-release}") || return 1
  local version=$(echo "$latest" | jq -r '.tag_name // .name')
  [[ $version =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]] && version="${BASH_REMATCH[1]}"
  [[ -z $version || $version == "null" ]] && return 1

  local pattern=$(_build_pattern "$3" "${4:-}")
  local url=$(echo "$latest" | jq -r ".assets[] | select(.name | test(\"$pattern\"; \"i\")) | .browser_download_url" | head -1)
  log.debug "Matching regex: $pattern"

  [[ -z $url || $url == "null" ]] && return 1

  echo "${version}|||${url}"
}

# 保存最新版本信息
save_latest_info() {
  [[ $# -lt 3 ]] && return 1
  if system.command.exist "yq"; then
    [[ -s $VERSIONS_FILE ]] || echo "[packages]" > "$VERSIONS_FILE"
    yq -o toml -i ".packages.$1.latest_version = \"$2\" | .packages.$1.download_url = \"$3\"" "$VERSIONS_FILE"
  else
    config.update "packages" "$1" "latest_version" "$2" "$VERSIONS_FILE"
    config.update "packages" "$1" "download_url" "$3" "$VERSIONS_FILE"
  fi
}

cmd_update() {
  args.init
  args.process "$@"

  console.section "检查更新"

  local has_updates=false

  for package in $(config.array.items "packages"); do
    # 批量获取包属性
    local -a props=()
    for prop in repo version_type file_pattern file_extension current_version; do
      props+=("$(get_package_property "$package" "$prop")")
    done
    local repo="${props[0]}" version_type="${props[1]}" file_pattern="${props[2]}" \
      file_extension="${props[3]}" current_version="${props[4]}"

    # 获取云端最新信息
    local latest_info=$(get_latest_version_and_url "$repo" "$version_type" "$file_pattern" "$file_extension") || {
      console.item.title 1 "$package: 获取版本失败"
      continue
    }

    local latest_version="${latest_info%%|||*}" download_url="${latest_info#*|||}"
    [[ -z $latest_version || -z $download_url ]] && {
      console.item.title 1 "$package: 获取版本信息失败"
      continue
    }

    # 保存并显示状态
    save_latest_info "$package" "$latest_version" "$download_url"
    has_updates=true

    if [[ -z $current_version ]]; then
      console.item.title 1 "$package: 未下载 (最新: $latest_version)"
    elif [[ $current_version != "$latest_version" ]]; then
      console.item.title 1 "$package: 有新版本 $current_version $POWERLINE_POINTING_ARROW  $latest_version"
    else
      console.item.title 1 "$package: 已是最新版本 $current_version"
      has_updates=false
    fi
  done

  [[ $has_updates == "true" ]] && {
    console.footer '运行 `./bin-updater.sh upgrade` 下载更新'
  }
}
