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

get_current_version() { config.array.get "packages" "$1" "current_version";}
get_latest_version() { config.array.get "packages" "$1" "latest_version"; }
get_download_url() { config.array.get "packages" "$1" "download_url";}
is_package_downloaded() { [[ $(config.array.get "packages" "$1" "downloaded") == "true" ]];}
#has_new_version() { local cur=$(get_current_version "$1"); local latest=$(get_latest_version "$package"); [[ -z "$cur" || "$cur" != "$latest" ]]; }
get_package_property() { echo "$(config.array.get "packages" "$1" "$2")"; }
#_save_versions_to_file() { local -a _fk=(); local -A _fa=([packages]="current_version latest_version download_url downloaded"); config.save "$VERSIONS_FILE" _fk _fa; }