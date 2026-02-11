#!/usr/bin/env bash

import std/system
import core/config

# 保存当前版本信息（upgrade 命令使用）
save_version_info() {
    [[ -z "$1" ]] && return 1

    system.command.exist "yq" && {
        config.array.set "packages" "$1" "current_version" "$2"
        config.array.set "packages" "$1" "downloaded" "$3"
        yq -o toml -i ".packages.$1.current_version = \"$2\"" "$VERSIONS_FILE"
        yq -o toml -i ".packages.$1.downloaded = \"$3\"" "$VERSIONS_FILE"
    } ||
    {
        config.update "packages" "$1" "current_version" "$2" "$VERSIONS_FILE"
        config.update "packages" "$1" "downloaded" "$3" "$VERSIONS_FILE"
    }
}

# 保存云端最新信息（update 命令使用）
save_latest_info() {
    [[ -z "$1" ]] && return 1

    system.command.exist "yq" && {
        [[ -s "$VERSIONS_FILE" ]] || echo "[packages]" > "$VERSIONS_FILE"
        config.array.set "packages" "$1" "latest_version" "$2"
        config.array.set "packages" "$1" "download_url" "$3"
        yq -o toml -i ".packages.$1.latest_version = \"$2\"" "$VERSIONS_FILE"
        yq -o toml -i ".packages.$1.download_url = \"$3\"" "$VERSIONS_FILE"
    } ||
    {
        config.update "packages" "$1" "latest_version" "$2" "$VERSIONS_FILE"
        config.update "packages" "$1" "download_url" "$3" "$VERSIONS_FILE"
    }
}

get_package_property() { echo "$(config.array.get "packages" "$1" "$2")"; }