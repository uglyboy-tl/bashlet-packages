#!/usr/bin/env bash

import std/system
import core/config

# 保存当前版本信息（upgrade 命令使用）
save_version_info() {
    local package="$1" version="$2" downloaded="${3:-false}"
    [[ -z "$package" ]] && return 1

    system.command.exist "yq" && {
        config.array.set "packages" "$package" "current_version" "$version"
        config.array.set "packages" "$package" "downloaded" "$downloaded"
        yq -o toml -i ".packages.$package.current_version = \"$version\"" "$VERSIONS_FILE"
        yq -o toml -i ".packages.$package.downloaded = \"$downloaded\"" "$VERSIONS_FILE"
    } ||
    {
        config.update "packages" "$package" "current_version" "$version" "$VERSIONS_FILE"
        config.update "packages" "$package" "downloaded" "$downloaded" "$VERSIONS_FILE"
    }
}

# 保存云端最新信息（update 命令使用）
save_latest_info() {
    local package="$1" version="$2" url="$3"
    [[ -z "$package" ]] && return 1

    system.command.exist "yq" && {
        [[ -s "$VERSIONS_FILE" ]] || echo "[packages]" > "$VERSIONS_FILE"
        config.array.set "packages" "$package" "latest_version" "$version"
        config.array.set "packages" "$package" "download_url" "$url"
        yq -o toml -i ".packages.$package.latest_version = \"$version\"" "$VERSIONS_FILE"
        yq -o toml -i ".packages.$package.download_url = \"$url\"" "$VERSIONS_FILE"
    } ||
    {
        config.update "packages" "$package" "latest_version" "$version" "$VERSIONS_FILE"
        config.update "packages" "$package" "download_url" "$url" "$VERSIONS_FILE"
    }
}

get_current_version() { local package="$1"; config.array.get "packages" "$package" "current_version";}
get_latest_version() { local package="$1"; config.array.get "packages" "$package" "latest_version"; }
get_download_url() { local package="$1"; config.array.get "packages" "$package" "download_url";}
is_package_downloaded() { local package="$1"; [[ $(config.array.get "packages" "$package" "downloaded") == "true" ]];}
has_new_version() { local package="$1"; local cur=$(get_current_version "$package"); local latest=$(get_latest_version "$package"); [[ -z "$cur" || "$cur" != "$latest" ]]; }
#_save_versions_to_file() { local -a _fk=(); local -A _fa=([packages]="current_version latest_version download_url downloaded"); config.save "$VERSIONS_FILE" _fk _fa; }