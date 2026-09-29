#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

set -euo pipefail
SCRIPT_NAME="skm"
VERSION="0.1.0"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

import core/log
import core/args
import core/config
import core/config.persist
import std/string
import std/path
import std/console
import std/ansi
import ext/requests

# ── Init ──

_ensure_skm_home() {
	local home
	home="$(path.data_dir)"
	mkdir -p "$home"
	if ! git -C "$home" rev-parse --git-dir > /dev/null 2>&1; then
		log.info "Initializing skm home at ${home}..."
		git init "$home"
		log.info "skm home initialized"
	fi
}

_ensure_config() {
	local cfg
	cfg="$(path.config_dir)/config.toml"
	[[ -f $cfg ]] && return 0
	log.info "Creating default config at ${cfg}"
	mkdir -p "$(dirname "$cfg")"
	cat > "$cfg" <<- TOML
		default_agent = "opencode"

		[agents.opencode]
		user_dir = "~/.config/opencode/skills"
		project_dir = ".agents/skills"
	TOML
	log.info "Default config created"
}

_load_config() {
	config.register "default_agent"
	config.array.register "sources" "repo"
	config.array.register "agents" "user_dir"
	config.array.register "agents" "project_dir"
	config.array.register "installed" "source"
	config.array.register "installed" "agent"
	config.array.register "installed" "mode"
	config.array.register "installed" "project_path"
	config.load

	config.has "default_agent" && return 0

	local agents agent_count=0
	agents="$(config.array.items "agents")"
	for _ in $agents; do ((++agent_count)); done
	if ((agent_count == 1)); then
		agents="$(string.trim "$agents")"
		config.set "default_agent" "$agents"
	else
		config.set "default_agent" "opencode"
	fi
}

# ── Config access helpers ──

_get_source_names() { config.array.items "sources"; }
_get_source_repo() { config.array.get "sources" "$1" "repo"; }
_get_agent_names() { config.array.items "agents"; }
_get_default_agent() { config.get "default_agent" || echo "opencode"; }
_get_agent_user_dir() { config.array.get "agents" "$1" "user_dir"; }
_get_agent_project_dir() { config.array.get "agents" "$1" "project_dir"; }
_get_installed_names() { config.array.items "installed"; }
_get_installed_field() { config.array.get "installed" "$1" "$2"; }

_get_installed_by_source() {
	local n src
	for n in $(_get_installed_names); do
		src="$(_get_installed_field "$n" "source")" || src=""
		[[ $src == "$1" ]] && echo "$n"
	done
}

# ── Display helpers ──

_print_aligned() {
	local -n _left="$1" _right="$2"
	local max_width=0 w i
	for s in "${_left[@]}"; do
		w=$(console.display_width "$s")
		((w > max_width)) && max_width=$w
	done
	((max_width += 4))
	for ((i = 0; i < ${#_left[@]}; i++)); do
		console.align "$max_width" "${_left[$i]}" "${_right[$i]}"
	done
}

_parse_skill_frontmatter() {
	awk -v k="$2" '
		BEGIN { in_fm=0; found=0 }
		/^---$/ { if (!in_fm) { in_fm=1; next } else { exit } }
		in_fm && !found && $0 ~ "^"k":" {
			sub("^"k":[[:space:]]*", "")
			if ($0 ~ /^["\047]/) {
				match($0, /^["\047]([^"\047]*)["\047]/); print substr($0, RSTART+1, RLENGTH-2)
			} else { print }
			found=1; exit
		}
	' "$1" 2> /dev/null
}

_scan_source_skills() { find "$1" -mindepth 2 -name "SKILL.md" -maxdepth 4 -print0 2> /dev/null; }

_show_agents() {
	for name in $(_get_agent_names); do
		local user_dir project_dir
		user_dir="$(_get_agent_user_dir "$name")"
		project_dir="$(_get_agent_project_dir "$name")"
		console.stdout "  ${CYAN}${Bold}${name}${NC}"
		console.stdout "$(printf "    ├─ %-12s ${Dim}%s${NC}" "user" "${user_dir}")"
		console.stdout "$(printf "    └─ %-12s ${Dim}%s${NC}" "project" "${project_dir}")"
	done
}

# ── Git helpers ──

_expand_repo_url() {
	if [[ $1 == *"://"* || $1 == *"@"* || $1 == "/"* || $1 == "."* ]]; then
		echo "$1"
	else
		echo "https://github.com/${1}.git"
	fi
}

_validate_repo() {
	if [[ $1 == "/"* || $1 == "."* ]]; then
		git -C "$1" rev-parse --git-dir > /dev/null 2>&1 || { log.error "Not a valid git repository: $1"; return 1; }
		return 0
	fi
	if [[ $1 == *"://"* || $1 == *"@"* ]]; then
		log.error "Use owner/repo format instead of full URL: $1"; return 1
	fi
	[[ $1 =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || { log.error "Invalid format: '${1}'. Expected owner/repo"; return 1; }
	if command -v gh &> /dev/null; then
		gh repo view "$1" --json name > /dev/null 2>&1 || { log.error "GitHub repository not found: $1"; return 1; }
		return 0
	fi
	git ls-remote "$(_expand_repo_url "$1")" > /dev/null 2>&1 || { log.error "Repository not reachable: $1"; return 1; }
}

_remove_source_git() {
	local home path
	home="$(path.data_dir)"
	path="$home/skills/$1"
	if [[ -d $path ]]; then
		git -C "$home" submodule deinit -f "skills/$1" 2> /dev/null || true
		git -C "$home" rm -f "skills/$1" 2> /dev/null || true
		rm -rf "$path"
	fi
	rm -rf "$home/.git/modules/skills/$1"
}

_remove_toml_section() {
	local config_file
	config_file="$(config.path)" || return 0
	[[ ! -f $config_file ]] && return 0
	local escaped
	escaped="$(string.escape.regex "$2")"
	sed -i "/^\[$1\.${escaped}\]$/,/^\[/{ /^\[$1\.${escaped}\]$/d; /^\[/!d; }" "$config_file"
	sed -i "/^\[$1\.${escaped}\]$/d" "$config_file"
}

_sync_source() {
	local name="$1" repo="$2"
	if [[ -d "$(path.data_dir)/skills/${name}" ]]; then
		log.info "Pulling ${name}..."
		git -C "$(path.data_dir)/skills/${name}" pull --ff-only || log.warn "Failed to pull ${name}"
	else
		log.info "Cloning ${name}..."
		(cd "$(path.data_dir)" && git submodule add "$(_expand_repo_url "$repo")" "skills/${name}" 2> /dev/null) ||
			git -C "$(path.data_dir)" submodule update --init "skills/${name}" ||
			log.warn "Failed to clone ${name}"
	fi
}

# ── Install helpers ──

_get_install_dest() {
	local name="$1" agent="$2" mode="$3" project_path="$4"
	if [[ $mode == "project" && -n $project_path ]]; then
		echo "${project_path}/$(_get_agent_project_dir "$agent")/${name}"
	else
		local user_dir
		user_dir="$(_get_agent_user_dir "$agent")" || return 1
		echo "${user_dir/#\~/$HOME}/${name}"
	fi
}

_find_skill_dir() {
	local skill="$1" source_filter="${2:-}"
	local sources_dir search_sources name dir skill_file fm_name
	sources_dir="$(path.data_dir)/skills"
	search_sources="${source_filter:-$(_get_source_names)}"

	for name in $search_sources; do
		dir="$sources_dir/$name/$skill"
		[[ -d $dir && -f $dir/SKILL.md ]] && { echo "$dir"; return 0; }
		[[ $name == "$skill" && -f $sources_dir/$name/SKILL.md ]] && { echo "$sources_dir/$name"; return 0; }
	done

	for name in $search_sources; do
		local source_dir="$sources_dir/$name"
		[[ -d $source_dir ]] || continue
		if [[ -f $source_dir/SKILL.md ]]; then
			fm_name="$(_parse_skill_frontmatter "$source_dir/SKILL.md" "name")"
			[[ $fm_name == "$skill" ]] && { echo "$source_dir"; return 0; }
		fi
		while IFS= read -r -d '' skill_file; do
			fm_name="$(_parse_skill_frontmatter "$skill_file" "name")"
			[[ $fm_name == "$skill" ]] && { dirname "$skill_file"; return 0; }
		done < <(_scan_source_skills "$source_dir")
	done
	return 1
}

_add_source() {
	local name="$1" repo="$2"
	_validate_repo "$repo" || return 1
	(cd "$(path.data_dir)" && git submodule add "$(_expand_repo_url "$repo")" "skills/${name}") || return 1
	config.persist.update "sources" "$name" "repo" "$repo"
}

_relink_skills() {
	for n in $(_get_installed_by_source "$1"); do
		local skill_dir agent mode project_path dest
		skill_dir="$(_find_skill_dir "$n" "$1")" || { log.warn "Skill '${n}' not found in '${1}', skipping"; continue; }
		agent="$(_get_installed_field "$n" "agent")" || agent=""
		mode="$(_get_installed_field "$n" "mode")" || mode=""
		project_path="$(_get_installed_field "$n" "project_path")" || project_path=""
		dest="$(_get_install_dest "$n" "$agent" "$mode" "$project_path")" || continue
		mkdir -p "$(dirname "$dest")"
		ln -srnf "$skill_dir" "$dest"
		log.info "Relinked '${n}' (${1}) → ${dest}"
	done
}

_uninstall_skill() {
	local name="$1" agent mode project_path dest
	agent="$(_get_installed_field "$name" "agent")" || agent=""
	mode="$(_get_installed_field "$name" "mode")" || mode=""
	project_path="$(_get_installed_field "$name" "project_path")" || project_path=""
	dest="$(_get_install_dest "$name" "$agent" "$mode" "$project_path")" || dest=""
	[[ -n $dest && -L $dest ]] && rm -f "$dest"
	_remove_toml_section "installed" "$name"
	log.info "Uninstalled '${name}'"
}

# ── add subcommand ──

cmd_add() {
	args.init "add - 添加 Skills 源仓库"
	args.add_options "name" "n" "源仓库名称（可选，默认使用仓库名）" "STRING"
	args.add_options "arg" "<owner/repo>" "STRING"
	args.process "$@"

	local -n args_arr=$(args.args)
	local repo="${args_arr[0]:-}"
	[[ -z $repo ]] && { args.show_help; exit 1; }

	local name
	name="$(args.get "-n" "--name")" || name=""
	if [[ -z $name ]]; then
		[[ $repo == "/"* || $repo == "."* ]] && name="$(basename "$repo")" || name="${repo##*/}"
	fi
	[[ -z $name ]] && { log.error "Could not determine source name from '${repo}'"; exit 1; }

	if config.array.has "sources" "$name" || [[ -d "$(path.data_dir)/skills/${name}" ]]; then
		log.warn "Source '${name}' already exists, skipping"; exit 0
	fi

	_add_source "$name" "$repo" || { log.error "Failed to add source '${name}' from ${repo}"; exit 1; }
	log.info "Source '${name}' added (${repo})"
}

# ── install subcommand ──

cmd_install() {
	args.init "install - 安装 Skill"
	args.add_options "source" "s" "源仓库 <owner/repo>" "STRING"
	args.add_options "project" "p" "指定项目目录（项目级安装）" "STRING"
	args.add_options "user" "u" "安装到用户级目录"
	args.add_options "agent" "a" "指定 Agent" "STRING"
	args.add_options "arg" "Skill 名称" "STRING"
	args.process "$@"

	local -n args_arr=$(args.args)
	local skill="${args_arr[0]:-}"
	[[ -z $skill ]] && { args.show_help; exit 1; }

	local source_filter project_path agent
	source_filter="$(args.get "-s" "--source")" || source_filter=""
	project_path="$(args.get "-p" "--project")" || project_path=""
	agent="$(args.get "-a" "--agent")" || agent="$(_get_default_agent)"

	if [[ -n $source_filter && $source_filter != *"://"* && $source_filter != *"@"* && $source_filter != "/"* && $source_filter != "."* ]]; then
		local auto_name="${source_filter##*/}"
		auto_name="${auto_name%.git}"
		if ! config.array.has "sources" "$auto_name" && [[ ! -d "$(path.data_dir)/skills/${auto_name}" ]]; then
			log.info "Auto-adding source '${source_filter}'..."
			_add_source "$auto_name" "$source_filter" || exit 1
		fi
		source_filter="$auto_name"
	fi

	local skill_dir
	skill_dir="$(_find_skill_dir "$skill" "$source_filter")" || { log.error "Skill '${skill}' not found in any source"; exit 1; }

	local sources_dir source_name
	sources_dir="$(path.data_dir)/skills"
	source_name="${skill_dir#"$sources_dir"/}"
	source_name="${source_name%%/*}"

	local mode
	if args.has "-u" "--user"; then
		mode="user"
	elif [[ -n $project_path ]]; then
		mode="project"
		project_path="$(cd "$project_path" && pwd)"
	else
		mode="project"
		project_path="$PWD"
	fi

	local dest
	dest="$(_get_install_dest "$skill" "$agent" "$mode" "$project_path")" || { log.error "Agent '${agent}' has no ${mode}_dir configured"; exit 1; }

	if [[ -L $dest ]]; then
		ln -srnf "$skill_dir" "$dest"
		log.info "Updated symlink '${skill}' (${source_name}) → ${dest}"
	elif [[ -d $dest ]]; then
		log.warn "Skill '${skill}' already installed at ${dest} (real directory)"; exit 0
	else
		mkdir -p "$(dirname "$dest")"
		ln -srnf "$skill_dir" "$dest"
		log.info "Installed '${skill}' (${source_name}) → ${dest}"
	fi

	config.array.set installed "$skill" source "$source_name"
	config.array.set installed "$skill" agent "$agent"
	config.array.set installed "$skill" mode "$mode"
	[[ -n $project_path ]] && config.array.set installed "$skill" project_path "$project_path"
	config.persist.save
}

# ── list subcommand ──

cmd_ls() {
	args.init "列出所有可用的 Skills"
	args.process "$@"

	local all_names
	all_names="$(_get_source_names)"
	[[ -z $all_names ]] && { log.info "No sources configured"; return; }

	local total=0
	for name in $all_names; do
		local source_dir="$(path.data_dir)/skills/${name}"
		[[ -d $source_dir ]] || continue

		console.stdout "  ${CYAN}${Bold}${name}${NC}"

		local skills=()
		if [[ -f $source_dir/SKILL.md ]]; then
			local root_name root_desc
			root_name="$(_parse_skill_frontmatter "$source_dir/SKILL.md" "name")"
			[[ -z $root_name ]] && root_name="$name"
			root_desc="$(_parse_skill_frontmatter "$source_dir/SKILL.md" "description")"
			skills+=("$root_name|$root_desc")
		fi
		while IFS= read -r -d '' skill_file; do
			local skill_name skill_desc
			skill_name="$(_parse_skill_frontmatter "$skill_file" "name")"
			[[ -z $skill_name ]] && skill_name="$(basename "$(dirname "$skill_file")")"
			skill_desc="$(_parse_skill_frontmatter "$skill_file" "description")"
			skills+=("$skill_name|$skill_desc")
		done < <(_scan_source_skills "$source_dir")

		local last_idx=$((${#skills[@]} - 1)) idx=0
		for entry in "${skills[@]}"; do
			local entry_name="${entry%%|*}" entry_desc="${entry#*|}"
			local prefix="├─"
			((idx == last_idx)) && prefix="└─"
			if [[ -n $entry_desc ]]; then
				console.stdout "$(printf "    %s %-30s ${Dim}%s${NC}" "$prefix" "$entry_name" "${entry_desc:0:70}")"
			else
				console.stdout "    ${prefix} ${entry_name}"
			fi
			((total++)); ((idx++))
		done
	done
	if ((total == 0)); then log.info "No skills found in any source"; fi
}

# ── remove subcommand ──

cmd_remove() {
	args.init "remove - 移除 Skills 源仓库"
	args.add_options "arg" "源仓库名称" "STRING"
	args.process "$@"

	local -n args_arr=$(args.args)
	local name="${args_arr[0]:-}"
	[[ -z $name ]] && { args.show_help; exit 1; }

	config.array.has "sources" "$name" || { log.error "Source '${name}' not found in config"; exit 1; }

	for skill in $(_get_installed_by_source "$name"); do
		_uninstall_skill "$skill"
	done

	_remove_source_git "$name"
	_remove_toml_section "sources" "$name"
	log.info "Source '${name}' removed"
}

# ── search subcommand ──

cmd_search() {
	args.init "search - 搜索 Skills (从 skills.sh)"
	args.add_options "arg" "搜索关键词" "STRING"
	args.process "$@"

	local -n args_arr=$(args.args)
	local keyword="${args_arr[0]:-}"
	[[ -z $keyword ]] && { args.show_help; exit 1; }

	requests.init
	local response
	response="$(requests.get "https://skills.sh/api/search" "q=${keyword}")"
	requests.raise_for_status "$response" || { log.error "Failed to search skills.sh"; exit 1; }

	local body
	body="$(requests.text "$response")"

	local count
	count="$(yq eval '.skills | length' - <<< "$body")" || count=0
	[[ $count -eq 0 ]] && { log.info "No skills found for '${keyword}'"; return; }

	local -a left=() right=()
	local name source installs
	while IFS=$'\t' read -r name source installs; do
		left+=("  ${CYAN}${Bold}${name}${NC} ${Dim}(${source})${NC}")
		right+=("${installs}")
	done < <(yq eval '.skills[] | [.name, .source, (.installs | tostring)] | @tsv' - <<< "$body")

	_print_aligned left right
}

# ── status subcommand ──

cmd_status() {
	args.init "status - 查看安装状态"
	args.add_options "arg" "源仓库名称（可选，仅显示该源的已安装技能）" "STRING"
	args.process "$@"

	local -n args_arr=$(args.args)
	local filter="${args_arr[0]:-}"
	local home
	home="$(path.data_dir)"

	if [[ -n $filter ]]; then
		config.array.has "sources" "$filter" || { log.error "Source '${filter}' not found"; exit 1; }
		local -a left=() right=()
		for n in $(_get_installed_by_source "$filter"); do
			local agent mode path
			agent="$(_get_installed_field "$n" "agent")" || agent=""
			mode="$(_get_installed_field "$n" "mode")" || mode=""
			path="$(_get_installed_field "$n" "project_path")" || path=""
			if [[ $mode == "project" && -n $path ]]; then
				left+=("  ${GREEN}✓${NC} ${n}")
				right+=("${Dim}${path} (${agent})${NC}")
			else
				left+=("  ${GREEN}✓${NC} ${n}")
				right+=("${Dim}$(_get_agent_user_dir "$agent") (${agent})${NC}")
			fi
		done
		[[ ${#left[@]} -eq 0 ]] && { log.info "No installed skills from '${filter}'"; return; }
		_print_aligned left right
		return
	fi

	local cfg
	cfg="$(config.path)"
	console.stdout "${Bold}Home:${NC} ${home}"
	git -C "$home" rev-parse --git-dir &> /dev/null && console.stdout "${Bold}Git:${NC} initialized" || console.stdout "${Bold}Git:${NC} ---"
	console.stdout "${Bold}Config:${NC} ${cfg}"
	console.stdout ""

	local source_count=0 cloned_count=0 skills_count=0
	for name in $(_get_source_names); do
		((++source_count))
		[[ -d "${home}/skills/${name}" ]] && ((++cloned_count))
	done
	console.stdout "${Bold}Sources:${NC} ${source_count} configured, ${cloned_count} cloned"

	for name in $(_get_source_names); do
		if [[ -d "${home}/skills/${name}" ]]; then
			console.stdout "  ${GREEN}✓${NC} ${name}"
		else
			console.stdout "  ${RED}✗${NC} ${name} (not cloned)"
		fi
	done
	console.stdout ""

	for name in $(_get_source_names); do
		[[ -d "${home}/skills/${name}" ]] || continue
		while IFS= read -r -d '' _; do ((skills_count++)); done < <(_scan_source_skills "${home}/skills/${name}" 2> /dev/null)
	done

	local installed_count=0
	for _ in $(_get_installed_names); do ((++installed_count)); done
	console.stdout "${Bold}Skills:${NC} ${skills_count} available, ${installed_count} installed"

	local -a left=() right=()
	for n in $(_get_installed_names); do
		local src agent mode path
		src="$(_get_installed_field "$n" "source")" || src=""
		agent="$(_get_installed_field "$n" "agent")" || agent=""
		mode="$(_get_installed_field "$n" "mode")" || mode=""
		path="$(_get_installed_field "$n" "project_path")" || path=""
		if [[ $mode == "project" && -n $path ]]; then
			left+=("  ${GREEN}✓${NC} ${n} (${src})")
			right+=("${Dim}${path} (${agent})${NC}")
		else
			left+=("  ${GREEN}✓${NC} ${n} (${src})")
			right+=("${Dim}$(_get_agent_user_dir "$agent") (${agent})${NC}")
		fi
	done
	_print_aligned left right
	console.stdout ""

	local agent_count=0
	for _ in $(_get_agent_names); do ((++agent_count)); done
	console.stdout "${Bold}Agents:${NC} ${agent_count} configured"
	_show_agents
}

# ── uninstall subcommand ──

cmd_uninstall() {
	args.init "uninstall - 卸载 Skill"
	args.add_options "agent" "a" "指定 Agent" "STRING"
	args.add_options "arg" "Skill 名称" "STRING"
	args.process "$@"

	local -n args_arr=$(args.args)
	local skill="${args_arr[0]:-}"
	[[ -z $skill ]] && { args.show_help; exit 1; }

	config.array.has "installed" "$skill" || { log.error "Skill '${skill}' is not installed"; exit 1; }

	local agent
	agent="$(args.get "-a" "--agent")" || agent=""
	if [[ -n $agent ]]; then
		local inst_agent
		inst_agent="$(_get_installed_field "$skill" "agent")" || inst_agent=""
		[[ $inst_agent == "$agent" ]] || { log.error "Skill '${skill}' is installed for agent '${inst_agent}', not '${agent}'"; exit 1; }
	fi
	_uninstall_skill "$skill"
}

# ── update subcommand ──

cmd_update() {
	args.init "update - 更新 Skills 源仓库"
	args.add_options "arg" "源仓库名称（可选，省略则更新全部）" "STRING"
	args.process "$@"

	local -n args_arr=$(args.args)
	local name="${args_arr[0]:-}"

	if [[ -n $name ]]; then
		local repo
		repo="$(_get_source_repo "$name")" || { log.error "Source '${name}' not found in config"; exit 1; }
		_sync_source "$name" "$repo" && _relink_skills "$name"
	else
		for n in $(_get_source_names); do
			_sync_source "$n" "$(_get_source_repo "$n")" && _relink_skills "$n"
		done

		local skills_dir
		skills_dir="$(path.data_dir)/skills"
		[[ -d $skills_dir ]] || return 0
		for entry in "$skills_dir"/*/; do
			[[ -d $entry ]] || continue
			local dir_name
			dir_name="$(basename "$entry")"
			if ! config.array.has "sources" "$dir_name"; then
				log.info "Removing redundant '${dir_name}'..."
				(cd "$(path.data_dir)" && git submodule deinit -f "skills/${dir_name}" 2> /dev/null && git rm -f "skills/${dir_name}" 2> /dev/null) || true
				rm -rf "$entry"
				log.info "Removed redundant '${dir_name}'"
			fi
		done
	fi
}

# ── Main ──

main() {
	args.init "Skills 管理器 — 管理 AI 编程代理的 Skills"
	args.add_options "version" "v" "显示版本信息"
	args.add_options "arg" "源仓库名称（可选，仅显示该源的已安装技能）" "STRING"
	args.add_subcommand "add" "添加 Skills 源仓库" "cmd_add"
	args.add_subcommand "remove" "移除 Skills 源仓库" "cmd_remove"
	args.add_subcommand "update" "更新 Skills 源仓库" "cmd_update"
	args.add_subcommand "list" "列出所有可用 Skills" "cmd_ls"
	args.add_subcommand "search" "搜索 Skills" "cmd_search"
	args.add_subcommand "install" "安装 Skill" "cmd_install"
	args.add_subcommand "uninstall" "卸载 Skill" "cmd_uninstall"

	config.register "log_level" "info"

	ansi.enable || true

	_ensure_skm_home
	_ensure_config
	_load_config

	log.setLevel "$(config.get log_level)"

	args.process "$@"
	args.has "-v" "--version" && usage.version && exit 0

	local -n _args=$(args.args)
	[[ -z $_ARGS_CURRENT_SUBCOMMAND ]] && cmd_status "${_args[@]}" && exit 0
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	main "$@"
fi
