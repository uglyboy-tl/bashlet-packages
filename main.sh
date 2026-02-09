#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$PROJECT_ROOT/lib/std/import.sh"

import std/init
import core/log
import core/args
import core/config
import github
import versions
import download


# Command: list - 列出已下载的包和更新状态
cmd_list() {
    args.init
    args.process "$@"

    console.stderr "已下载的包:"
    console.stderr "============"

    for package in $(config.array.items "packages"); do
        current_version=$(get_current_version "$package" 2>/dev/null || echo "")
        latest_version=$(get_latest_version "$package" 2>/dev/null || echo "")
        downloaded=$(is_package_downloaded "$package" 2>/dev/null && echo true || echo false)

        if [[ -n "$current_version" && "$downloaded" == "true" ]]; then
            console.stderr "  $package:"
            console.stderr "    当前版本: $current_version"

            file_extension=$(get_package_property "$package" "file_extension")
            if [[ -n "$file_extension" ]]; then
                file_pattern="$SETTINGS_DOWNLOAD_DIR/${package}-*.$file_extension"
                matching_files=($file_pattern)
            else
                # 无后缀文件，查找精确匹配
                matching_files=("$SETTINGS_DOWNLOAD_DIR/${package}-${current_version}")
            fi
            if [[ ${#matching_files[@]} -gt 0 && -f "${matching_files[0]}" ]]; then
                latest_file="${matching_files[0]}"
                download_time=$(stat -c "%y" "$latest_file" | cut -d'.' -f1 | sed 's/ /T/')
                console.stderr "    下载时间: $download_time"
                console.stderr "    文件: $(basename "$latest_file")"
            fi

            if [[ -n "$latest_version" ]]; then
                if [[ "$current_version" != "$latest_version" ]]; then
                    console.stderr "    状态: 🆕 有新版本 $latest_version"
                else
                    console.stderr "    状态: ✓ 已是最新"
                fi
            else
                console.stderr "    状态: ℹ️  运行 'update' 获取版本信息"
            fi
        elif [[ -n "$latest_version" ]]; then
            console.stderr "  $package:"
            console.stderr "    状态: 📦 未下载 (最新: $latest_version)"
            console.stderr "    运行 'upgrade $package' 下载"
        else
            console.stderr "  $package:"
            console.stderr "    状态: ℹ️  运行 'update' 获取版本信息"
        fi
    done
}

# Command: update - 检查更新并保存云端信息
cmd_update() {
    args.init
    args.process "$@"

    console.stderr "检查更新:"
    console.stderr "=========="

    local has_updates=false

    for package in $(config.array.items "packages"); do
        repo=$(get_package_property "$package" "repo")
        #version_type=$(get_package_property "$package" repo)
        version_type=""
        file_pattern=$(get_package_property "$package" "file_pattern")
        file_extension=$(get_package_property "$package" "file_extension")

        current_version=$(get_current_version "$package" 2>/dev/null)
        downloaded=$(is_package_downloaded "$package" 2>/dev/null && echo true || echo false)

        # 获取云端最新信息并保存
        latest_info=$(get_latest_version_and_url "$repo" "$version_type" "$file_pattern" "$file_extension") || {
            console.stderr "  $package: 获取版本失败"
            continue
        }

        latest_version="${latest_info%%|||*}"
        download_url="${latest_info#*|||}"

        if [[ -z "$latest_version" || -z "$download_url" ]]; then
            console.stderr "  $package: 获取版本信息失败"
            continue
        fi

        # 保存云端信息到本地
        save_latest_info "$package" "$latest_version" "$download_url"

        # 显示更新状态
        if [[ "$downloaded" != "true" ]]; then
            console.stderr "  $package: 未下载 (最新: $latest_version)"
            has_updates=true
        elif [[ -z "$current_version" ]]; then
            console.stderr "  $package: 最新版本 $latest_version"
        elif [[ "$current_version" != "$latest_version" ]]; then
            console.stderr "  $package: 有新版本 $current_version -> $latest_version"
            has_updates=true
        else
            console.stderr "  $package: 已是最新版本 $current_version"
        fi
    done

    if [[ "$has_updates" == "true" ]]; then
        console.stderr ""
        console.stderr "运行 './bin-updater.sh upgrade' 下载更新"
    fi
}

# Command: upgrade - 下载更新（使用本地保存的信息）
cmd_upgrade() {
    args.init
    args.add_options "arg" "待更新的二进制包" "可选：指定需要更新的二进制包名，支持多个包名"
    args.process "$@"

    local -n target_packages=$(args.args)
    local packages_to_upgrade=()

    if [[ ${#target_packages[@]} -eq 0 ]]; then
        packages_to_upgrade=($(config.array.items "packages"))
    else
        for package in "${target_packages[@]}"; do
            if ! printf '%s\n' $(config.array.items "packages") | grep -q "^${package}$"; then
                log.error "Unknown package: $package"
                log.error "Available packages: ${PACKAGES[*]}"
                exit 1
            fi
            packages_to_upgrade+=("$package")
        done
    fi

    local packages_skipped=0



    console.stderr "下载更新:"
    console.stderr "========="

    for package in "${packages_to_upgrade[@]}"; do
        file_extension=$(get_package_property "$package" "file_extension")

        local current_version=$(get_current_version "$package" 2>/dev/null)
        local latest_version=$(get_latest_version "$package" 2>/dev/null)
        local download_url=$(get_download_url "$package" 2>/dev/null)
        local downloaded=$(is_package_downloaded "$package" 2>/dev/null && echo true || echo false)

        if [[ -z "$latest_version" ]]; then
            console.stderr "  $package: 没有云端信息，请先运行 'update'"
            continue
        fi

        if [[ -z "$download_url" ]]; then
            console.stderr "  $package: 没有下载链接，请先运行 'update'"
            continue
        fi

        local needs_download=false
        local msg=""
        if [[ "$downloaded" != "true" ]]; then
            needs_download=true
            msg="未下载，将下载 $latest_version"
        elif [[ -z "$current_version" ]]; then
            needs_download=true
            msg="无版本记录，将下载 $latest_version"
        elif [[ "$current_version" != "$latest_version" ]]; then
            needs_download=true
            msg="有新版本 $current_version -> $latest_version"
        else
            console.stderr "  $package: 已是最新版本 $current_version"
            ((packages_skipped++)) || true
            continue
        fi

        console.stderr "  $package: $msg"

        if [[ "$needs_download" == "true" ]]; then
            if [[ "$downloaded" == "true" && -n "$current_version" ]]; then
                if [[ -n "$file_extension" ]]; then
                    old_file="${package}-${current_version}.${file_extension}"
                else
                    old_file="${package}-${current_version}"
                fi
                if [[ -f "$SETTINGS_DOWNLOAD_DIR/$old_file" ]]; then
                    backup_file "$package" "$current_version" "$old_file" > /dev/null
                fi
            fi

            if [[ -n "$file_extension" ]]; then
                filename="${package}-${latest_version}.${file_extension}"
            else
                filename="${package}-${latest_version}"
            fi
            output_file="$SETTINGS_DOWNLOAD_DIR/$filename"

            console.stderr "  [下载] $filename"
            if download_file "$download_url" "$output_file"; then
                console.stderr "  [完成] 下载成功"
                save_version_info "$package" "$latest_version" "true"
            else
                console.stderr "  $package: 下载失败"
                rm -f "$output_file"
            fi
        fi
    done

    console.stderr "========="
    local total=${#packages_to_upgrade[@]}
    local updated=$((total - packages_skipped))
    if [[ $total -gt 0 ]]; then
        console.stderr "共 $total 个包，$updated 个已更新，$packages_skipped 个跳过"
    fi
}

# 安装单个包的内部函数
_do_install_package() {
    local package="$1"
    local show_header="${2:-true}"

    current_version=$(get_current_version "$package" 2>/dev/null)
    if [[ -z "$current_version" ]]; then
        console.stderr "  $package: 未下载，请先运行 upgrade"
        return 1
    fi

    file_extension=$(get_package_property "$package" "file_extension")
    binary_name=$(get_package_property "$package" "binary_name")

    if [[ "$show_header" == "true" ]]; then
        console.stderr "  安装 $package (版本: $current_version)..."
    fi

    # 构建文件名（无后缀时直接用包名-版本）
    if [[ -n "$file_extension" ]]; then
        filename="${package}-${current_version}.${file_extension}"
    else
        filename="${package}-${current_version}"
    fi
    archive_file="$SETTINGS_DOWNLOAD_DIR/$filename"

    if [[ ! -f "$archive_file" ]]; then
        console.stderr "  $package: 文件不存在: $archive_file"
        return 1
    fi

    # 确定安装目录
    system_bin="/usr/local/bin"
    user_bin="$HOME/.local/bin"

    if [[ -w "$system_bin" ]]; then
        install_dir="$system_bin"
        console.stderr "  [检测] 有系统目录写入权限，使用系统目录"
    else
        install_dir="$user_bin"
        console.stderr "  [检测] 无系统目录写入权限，使用用户目录"
    fi
    mkdir -p "$install_dir"

    # 无后缀名二进制文件，直接安装
    if [[ -z "$file_extension" ]]; then
        local target_file="$install_dir/$binary_name"
        console.stderr "  [安装] $binary_name"
        cp "$archive_file" "$target_file"
        chmod +x "$target_file"
        console.stderr "  [完成] 安装成功"
        console.stderr "  [路径] $install_dir 已添加到 PATH"
        return 0
    fi

    extract_dir="$SETTINGS_DOWNLOAD_DIR/${package}-${current_version}"
    rm -rf "$extract_dir"
    console.stderr "  [解压] $filename"
    if ! extract_file "$filename" "$extract_dir"; then
        console.stderr "  $package: 解压失败"
        rm -rf "$extract_dir"
        return 1
    fi

    local binary_files=()
    while IFS= read -r -d '' binary_file; do
        binary_files+=("$binary_file")
    done < <(find "$extract_dir" -type f -executable -print0 2>/dev/null)

    if [[ ${#binary_files[@]} -eq 0 ]]; then
        while IFS= read -r -d '' binary_file; do
            binary_files+=("$binary_file")
        done < <(find "$extract_dir" -type f -perm /111 -print0 2>/dev/null)
    fi

    if [[ ${#binary_files[@]} -gt 0 ]]; then
        local installed_count=0
        for binary_file in "${binary_files[@]}"; do
            local target_file="$install_dir/$(basename "$binary_file")"
            console.stderr "  [安装] 到 $target_file"
            cp "$binary_file" "$target_file"
            chmod +x "$target_file"
            ((installed_count++)) || true
        done
        rm -rf "$extract_dir"
        console.stderr "  [完成] 安装成功 ($installed_count 个文件)"
        console.stderr "  [路径] $install_dir 已添加到 PATH"
        return 0
    else
        console.stderr "  $package: 未找到可执行文件"
        rm -rf "$extract_dir"
        return 1
    fi
}

# Command: install - 安装已下载的包
cmd_install() {
    args.init
    args.add_options "arg" "待安装的二进制包" "可选：指定需要安装的二进制包名，支持多个包名"
    args.process "$@"

    local -n target_packages=$(args.args)

    for package in "${target_packages[@]}"; do
        if ! printf '%s\n' $(config.array.items "packages") | grep -q "^${package}$"; then
            log.error "Unknown package: $package"
            log.error "Available packages: ${PACKAGES[*]}"
            exit 1
        fi
    done

    console.stderr "安装包:"
    console.stderr "========="

    local success_count=0
    local fail_count=0

    for package in "${target_packages[@]}"; do
        if _do_install_package "$package" "true"; then
            ((success_count++)) || true
        else
            ((fail_count++)) || true
        fi
        console.stderr ""
    done

    console.stderr "========="
    console.stderr "共 ${#target_packages[@]} 个包，$success_count 个成功，$fail_count 个失败"
}

# Command: edit - 使用系统编辑器编辑配置文件
cmd_edit() {
    args.init
    args.process "$@"

    local config_path=$(config.path)

    # Determine the editor to use (default: vim)
    local editor="${EDITOR:-${VISUAL:-vim}}"

    # Check if editor exists
    if ! command -v "$editor" >/dev/null 2>&1; then
        log.error "未找到编辑器: $editor，请设置 EDITOR 环境变量"
        exit 1
    fi

    # Create default config if it doesn't exist
    if [[ ! -f "$config_path" ]]; then
        create_default_config "$config_path"
    fi

    console.stderr "正在打开配置: $config_path"
    console.stderr "编辑器: $editor"

    # Open the editor
    if ! "$editor" "$config_path"; then
        log.error "编辑器打开失败: $editor"
        exit 1
    fi

    console.stderr "配置文件已保存: $config_path"

    # Optionally reload the config
    log.info "配置已更新，可能需要重启工具或执行 source 重新加载"
}

# Main entry point
main() {
    args.name "$SCRIPT_NAME"
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
    config.array.register "packages" "file_pattern"
    config.array.register "packages" "file_extension"
    config.array.register "packages" "binary_name"
    config.array.register "packages" "current_version"
    config.array.register "packages" "latest_version"
    config.array.register "packages" "download_url"
    config.array.register "packages" "downloaded"

    config.load
    SETTINGS_DOWNLOAD_DIR="$(config.get "download_dir")"
    SETTINGS_PROXY_PREFIX=$(config.get proxy_prefix)
    VERSIONS_FILE="$SETTINGS_DOWNLOAD_DIR/versions.toml"
    [[ -f "$VERSIONS_FILE" ]] || touch "$VERSIONS_FILE"
    config.load "$VERSIONS_FILE"
    log.setLevel $(config.get log_level)

    args.process "$@"
    args.has "-v" "--version" && usage.version && exit 0
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi