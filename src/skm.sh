#!/usr/bin/env bash
# shellcheck disable=SC2034

set -euo pipefail
SCRIPT_NAME="skm"
VERSION="0.1.0"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

import core/log
import core/args
import core/config
import std/string
import std/array
import std/path
import std/fs
import std/console
import std/ansi
import ext/requests

# ── Initialization ──

_ensure_skm_home() {
	local home
	home="$(path.data_dir)"
	if [[ ! -d $home ]]; then
		mkdir -p "$home"
	fi
	if ! git -C "$home" rev-parse --git-dir > /dev/null 2>&1; then
		log.info "Initializing skm home at ${home}..."
		git init "$home"
		log.info "skm home initialized"
	fi
}

_ensure_config() {
	local cfg="$(path.config_dir)/config.toml"
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

	# Auto-set default agent: if exactly one agent → use it; otherwise "opencode"
	local default_agent
	default_agent="opencode"
	config.has "default_agent" && default_agent="$(config.get "default_agent")"
	if [[ -z $default_agent ]]; then
		local agents agent_count=0
		agents="$(_get_agent_names)"
		agents="$(string.trim "$agents")"
		for a in $agents; do ((++agent_count)); done
		if ((agent_count == 1)); then
			config.set "default_agent" "$agents"
		else
			config.set "default_agent" "opencode"
		fi
	fi
}

# ── 配置访问辅助 ──

_get_source_names() { config.array.items "sources"; }

_get_source_repo() { config.array.get "sources" "$1" "repo"; }

_expand_repo_url() {
	local input="$1"
	if [[ $input == *"://"* || $input == *"@"* || $input == "/"* || $input == "."* ]]; then
		echo "$input"
	else
		echo "https://github.com/${input}.git"
	fi
}

_validate_repo() {
	local input="$1"
	if [[ $input == "/"* || $input == "."* ]]; then
		git -C "$input" rev-parse --git-dir > /dev/null 2>&1 || {
			log.error "Not a valid git repository: $input"
			return 1
		}
		return 0
	fi
	if [[ $input == *"://"* || $input == *"@"* ]]; then
		log.error "Use owner/repo format instead of full URL: $input"
		return 1
	fi
	[[ $input =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || {
		log.error "Invalid format: '${input}'. Expected owner/repo"
		return 1
	}
	if command -v gh &> /dev/null; then
		gh repo view "$input" --json name > /dev/null 2>&1 || {
			log.error "GitHub repository not found: $input"
			return 1
		}
		return 0
	fi
	local url
	url="$(_expand_repo_url "$input")"
	git ls-remote "$url" > /dev/null 2>&1 || {
		log.error "Repository not reachable: $input"
		return 1
	}
}

_get_agent_names() { config.array.items "agents"; }

_get_default_agent() { config.get "default_agent" || echo "opencode"; }

_get_agent_user_dir() { config.array.get "agents" "$1" "user_dir"; }

_get_agent_project_dir() { config.array.get "agents" "$1" "project_dir"; }

_remove_source_git() {
	local name="$1"
	local home="$(path.data_dir)"
	local path="$home/skills/$name"
	if [[ -d $path ]]; then
		git -C "$home" submodule deinit -f "skills/$name" 2> /dev/null || true
		git -C "$home" rm -f "skills/$name" 2> /dev/null || true
		rm -rf "$path"
	fi
	rm -rf "$home/.git/modules/skills/$name"
}

_remove_source_from_config() {
	local name="$1"
	local config_file
	config_file="$(config.path)"
	[[ ! -f $config_file ]] && return 0
	local escaped
	escaped="$(string.escape.regex "$name")"
	sed -i "/^\[sources\.${escaped}\]$/,/^\[/{ /^\[sources\.${escaped}\]$/d; /^\[/!d; }" "$config_file"
	# Clean up leftover blank lines
	sed -i "/^\[sources\.${escaped}\]$/d" "$config_file"
}

_get_installed_names() { config.array.items "installed"; }

_get_installed_field() { config.array.get "installed" "$1" "$2"; }

_get_installed_by_source() {
	local source="$1"
	local names n src
	names="$(_get_installed_names)"
	names="$(string.trim "$names")"
	for n in $names; do
		src="$(_get_installed_field "$n" "source")" || src=""
		[[ $src == "$source" ]] && echo "$n"
	done
}

_relink_skills() {
	local source="$1"
	local names n
	names="$(_get_installed_by_source "$source")"
	names="$(string.trim "$names")"
	for n in $names; do
		local skill_dir agent mode project_path dest
		skill_dir="$(_find_skill_dir "$n" "$source")" || {
			log.warn "Skill '${n}' not found in '${source}', skipping"
			continue
		}
		agent="$(_get_installed_field "$n" "agent")" || agent=""
		mode="$(_get_installed_field "$n" "mode")" || mode=""
		project_path="$(_get_installed_field "$n" "project_path")" || project_path=""
		dest="$(_get_install_dest "$n" "$agent" "$mode" "$project_path")" || continue
		mkdir -p "$(dirname "$dest")"
		ln -srnf "$skill_dir" "$dest"
		log.info "Relinked '${n}' (${source}) → ${dest}"
	done
}

_remove_installed_entry() {
	local name="$1"
	local config_file
	config_file="$(config.path)"
	[[ ! -f $config_file ]] && return 0
	local escaped
	escaped="$(string.escape.regex "$name")"
	sed -i "/^\[installed\.${escaped}\]$/,/^\[/{ /^\[installed\.${escaped}\]$/d; /^\[/!d; }" "$config_file"
	sed -i "/^\[installed\.${escaped}\]$/d" "$config_file"
}

_get_install_dest() {
	local name="$1" agent="$2" mode="$3" project_path="$4"
	if [[ $mode == "project" && -n $project_path ]]; then
		local subdir
		subdir="$(_get_agent_project_dir "$agent")" || return 1
		echo "${project_path}/${subdir}/${name}"
	else
		local user_dir
		user_dir="$(_get_agent_user_dir "$agent")" || return 1
		echo "${user_dir/#\~/$HOME}/${name}"
	fi
}

_uninstall_skill() {
	local name="$1"
	local agent mode project_path dest
	agent="$(_get_installed_field "$name" "agent")" || agent=""
	mode="$(_get_installed_field "$name" "mode")" || mode=""
	project_path="$(_get_installed_field "$name" "project_path")" || project_path=""

	dest="$(_get_install_dest "$name" "$agent" "$mode" "$project_path")" || dest=""
	[[ -n $dest && -L $dest ]] && rm -f "$dest"
	_remove_installed_entry "$name"
	log.info "Uninstalled '${name}'"
}

# ── 源仓库管理 ──

_add_source() {
	local name="$1" repo="$2"
	_validate_repo "$repo" || return 1
	local full_url
	full_url="$(_expand_repo_url "$repo")"
	(cd "$(path.data_dir)" && git submodule add "$full_url" "skills/${name}") || return 1
	config.array.set sources "$name" repo "$repo"
	local config_file="$(config.path)"
	if command -v yq &> /dev/null; then
		grep -q '^\[sources' "$config_file" 2> /dev/null || printf "\n[sources]\n" >> "$config_file"
		yq -o toml -i ".sources.\"${name}\".repo = \"${repo}\"" "$config_file"
	else
		config.save "$config_file"
	fi
}

cmd_add() {
	args.init "add - 添加 Skills 源仓库"
	args.add_options "name" "n" "源仓库名称（可选，默认使用仓库名）" "STRING"
	args.add_options "arg" "<owner/repo>" "STRING"
	args.process "$@"

	local -n args_arr=$(args.args)
	local repo="${args_arr[0]:-}"
	[[ -z $repo ]] && {
		args.show_help; exit 1
	}

	local name
	name="$(args.get "-n" "--name")" || name=""
	if [[ -z $name ]]; then
		if [[ $repo == "/"* || $repo == "."* ]]; then
			name="$(basename "$repo")"
		else
			name="${repo##*/}"
		fi
	fi
	[[ -z $name ]] && { log.error "Could not determine source name from '${repo}'"; exit 1; }

	if config.array.has "sources" "$name" || [[ -d "$(path.data_dir)/skills/${name}" ]]; then
		log.warn "Source '${name}' already exists, skipping"
		exit 0
	fi

	_add_source "$name" "$repo" || {
		log.error "Failed to add source '${name}' from ${repo}"
		exit 1
	}
	log.info "Source '${name}' added (${repo})"
}

cmd_remove() {
	args.init "remove - 移除 Skills 源仓库"
	args.add_options "arg" "源仓库名称" "STRING"
	args.process "$@"

	local -n args_arr=$(args.args)
	local name="${args_arr[0]:-}"
	[[ -z $name ]] && {
		args.show_help; exit 1
	}

	config.array.has "sources" "$name" || {
		log.error "Source '${name}' not found in config"
		exit 1
	}

	local installed_skills
	installed_skills="$(_get_installed_by_source "$name")"
	for skill in $installed_skills; do
		_uninstall_skill "$skill"
	done

	_remove_source_git "$name"
	_remove_source_from_config "$name"
	log.info "Source '${name}' removed"
}

_sync_source() {
	local name="$1" repo="$2"
	local full_url
	full_url="$(_expand_repo_url "$repo")"
	if [[ -d "$(path.data_dir)/skills/${name}" ]]; then
		log.info "Pulling ${name}..."
		git -C "$(path.data_dir)/skills/${name}" pull --ff-only || log.warn "Failed to pull ${name}"
	else
		log.info "Cloning ${name}..."
		(cd "$(path.data_dir)" && git submodule add "$full_url" "skills/${name}" 2> /dev/null) ||
			git -C "$(path.data_dir)" submodule update --init "skills/${name}" ||
			log.warn "Failed to clone ${name}"
	fi
}

cmd_update() {
	args.init "update - 更新 Skills 源仓库"
	args.add_options "arg" "源仓库名称（可选，省略则更新全部）" "STRING"
	args.process "$@"

	local -n args_arr=$(args.args)
	local name="${args_arr[0]:-}"

	if [[ -n $name ]]; then
		local repo
		repo="$(_get_source_repo "$name")" || {
			log.error "Source '${name}' not found in config"
			exit 1
		}
		_sync_source "$name" "$repo" && _relink_skills "$name"
	else
		local all_names
		all_names="$(_get_source_names)"
		all_names="$(string.trim "$all_names")"

		for n in $all_names; do
			_sync_source "$n" "$(_get_source_repo "$n")" && _relink_skills "$n"
		done

		local skills_dir="$(path.data_dir)/skills"
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

# ── ls ──

_parse_skill_frontmatter() {
	local file="$1" key="$2"
	awk -v k="$key" '
		BEGIN { in_fm=0; found=0 }
		/^---$/ { if (!in_fm) { in_fm=1; next } else { exit } }
		in_fm && !found && $0 ~ "^"k":" {
			sub("^"k":[[:space:]]*", "")
			if ($0 ~ /^["\047]/) {
				match($0, /^["\047]([^"\047]*)["\047]/); print substr($0, RSTART+1, RLENGTH-2)
			} else { print }
			found=1
			exit
		}
	' "$file" 2> /dev/null
}

_scan_source_skills() {
	local source_dir="$1"
	find "$source_dir" -mindepth 2 -name "SKILL.md" -maxdepth 4 -print0 2> /dev/null
}

cmd_ls() {
	args.init "列出所有可用的 Skills"
	args.process "$@"

	local total=0
	local all_names
	all_names="$(_get_source_names)"
	all_names="$(string.trim "$all_names")"
	[[ -z $all_names ]] && {
		log.info "No sources configured"
		return
	}

	local name
	for name in $all_names; do
		local source_dir="$(path.data_dir)/skills/${name}"
		[[ -d $source_dir ]] || continue

		console.stdout "  ${CYAN}${Bold}${name}${NC}"

		# collect all skills (root + sub)
		local skills=()
		if [[ -f $source_dir/SKILL.md ]]; then
			local root_name root_desc
			root_name="$(_parse_skill_frontmatter "$source_dir/SKILL.md" "name")"
			[[ -z $root_name ]] && root_name="$name"
			root_desc="$(_parse_skill_frontmatter "$source_dir/SKILL.md" "description")"
			skills+=("$root_name|$root_desc")
		fi
		while IFS= read -r -d '' skill_file; do
			local skill_dir skill_name skill_desc
			skill_dir="$(dirname "$skill_file")"
			skill_name="$(_parse_skill_frontmatter "$skill_file" "name")"
			[[ -z $skill_name ]] && skill_name="$(basename "$skill_dir")"
			skill_desc="$(_parse_skill_frontmatter "$skill_file" "description")"
			skills+=("$skill_name|$skill_desc")
		done < <(_scan_source_skills "$source_dir")

		local last_idx=$((${#skills[@]} - 1))
		local idx=0 entry skill_name skill_desc
		for entry in "${skills[@]}"; do
			skill_name="${entry%%|*}"
			skill_desc="${entry#*|}"
			local prefix="├─"
			((idx == last_idx)) && prefix="└─"
			if [[ -n $skill_desc ]]; then
				console.stdout "$(printf "    %s %-30s ${Dim}%s${NC}" "$prefix" "$skill_name" "${skill_desc:0:70}")"
			else
				console.stdout "    ${prefix} ${skill_name}"
			fi
			((total++))
			((idx++))
		done
	done

	if ((total == 0)); then
		log.info "No skills found in any source"
	fi
}

# ── search ──

cmd_search() {
	args.init "search - 搜索 Skills (从 skills.sh)"
	args.add_options "arg" "搜索关键词" "STRING"
	args.process "$@"

	local -n args_arr=$(args.args)
	local keyword="${args_arr[0]:-}"
	[[ -z $keyword ]] && {
		args.show_help; exit 1
	}

	local response
	requests.init
	response="$(requests.get "https://skills.sh/api/search" "q=${keyword}")"
	requests.raise_for_status "$response" || {
		log.error "Failed to search skills.sh"
		exit 1
	}

	local body
	body="$(requests.text "$response")"

	local count
	count="$(yq eval '.skills | length' - <<< "$body")" || count=0
	[[ $count -eq 0 ]] && {
		log.info "No skills found for '${keyword}'"
		return
	}

	local name source installs
	local -a left=() right=()
	while IFS=$'\t' read -r name source installs; do
		left+=("  ${CYAN}${Bold}${name}${NC} ${Dim}(${source})${NC}")
		right+=("${installs}")
	done < <(yq eval '.skills[] | [.name, .source, (.installs | tostring)] | @tsv' - <<< "$body")

	local max_width=0 w
	for s in "${left[@]}"; do
		w=$(console.display_width "$s")
		((w > max_width)) && max_width=$w
	done
	((max_width += 4))
	local i
	for ((i = 0; i < ${#left[@]}; i++)); do
		console.align "$max_width" "${left[$i]}" "${right[$i]}"
	done
}

# ── install ──

_find_skill_dir() {
	local skill="$1" source_filter="${2:-}"
	local sources_dir="$(path.data_dir)/skills"

	local search_sources
	if [[ -n $source_filter ]]; then
		search_sources="$source_filter"
	else
		search_sources="$(_get_source_names)"
		search_sources="$(string.trim "$search_sources")"
	fi

	local name dir
	for name in $search_sources; do
		dir="$sources_dir/$name/$skill"
		[[ -d $dir && -f $dir/SKILL.md ]] && { echo "$dir" && return 0; }
		[[ $name == "$skill" && -f $sources_dir/$name/SKILL.md ]] && { echo "$sources_dir/$name" && return 0; }
	done

	# Fallback: search by frontmatter name or find SKILL.md anywhere in source
	local skill_file fm_name
	for name in $search_sources; do
		local source_dir="$sources_dir/$name"
		[[ -d $source_dir ]] || continue
		if [[ -f $source_dir/SKILL.md ]]; then
			fm_name="$(_parse_skill_frontmatter "$source_dir/SKILL.md" "name")"
			[[ $fm_name == "$skill" ]] && { echo "$source_dir" && return 0; }
		fi
		while IFS= read -r -d '' skill_file; do
			fm_name="$(_parse_skill_frontmatter "$skill_file" "name")"
			if [[ $fm_name == "$skill" ]]; then
				echo "$(dirname "$skill_file")"
				return 0
			fi
		done < <(_scan_source_skills "$source_dir")
	done
	return 1
}

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
	[[ -z $skill ]] && {
		args.show_help; exit 1
	}

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
	skill_dir="$(_find_skill_dir "$skill" "$source_filter")" || {
		log.error "Skill '${skill}' not found in any source"
		exit 1
	}

	local source_name dest
	local sources_dir="$(path.data_dir)/skills"
	local relative="${skill_dir#"$sources_dir"/}"
	source_name="${relative%%/*}"

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
	dest="$(_get_install_dest "$skill" "$agent" "$mode" "$project_path")" || {
		log.error "Agent '${agent}' has no ${mode}_dir configured"
		exit 1
	}

	if [[ -L $dest ]]; then
		ln -srnf "$skill_dir" "$dest"
		log.info "Updated symlink '${skill}' (${source_name}) → ${dest}"
	elif [[ -d $dest ]]; then
		log.warn "Skill '${skill}' already installed at ${dest} (real directory)"
		exit 0
	else
		mkdir -p "$(dirname "$dest")"
		ln -srnf "$skill_dir" "$dest"
		log.info "Installed '${skill}' (${source_name}) → ${dest}"
	fi

	config.array.set installed "$skill" source "$source_name"
	config.array.set installed "$skill" agent "$agent"
	config.array.set installed "$skill" mode "$mode"
	[[ -n $project_path ]] && config.array.set installed "$skill" project_path "$project_path"
	config.save
}

# ── uninstall ──

cmd_uninstall() {
	args.init "uninstall - 卸载 Skill"
	args.add_options "agent" "a" "指定 Agent" "STRING"
	args.add_options "arg" "Skill 名称" "STRING"
	args.process "$@"

	local -n args_arr=$(args.args)
	local skill="${args_arr[0]:-}"
	[[ -z $skill ]] && {
		args.show_help; exit 1
	}

	local agent
	agent="$(args.get "-a" "--agent")" || agent=""

	config.array.has "installed" "$skill" || {
		log.error "Skill '${skill}' is not installed"
		exit 1
	}

	if [[ -n $agent ]]; then
		local inst_agent
		inst_agent="$(_get_installed_field "$skill" "agent")" || inst_agent=""
		[[ $inst_agent == "$agent" ]] || {
			log.error "Skill '${skill}' is installed for agent '${inst_agent}', not '${agent}'"
			exit 1
		}
	fi

	_uninstall_skill "$skill"
}

# ── status ──

cmd_status() {
	args.init "status - 查看安装状态"
	args.add_options "arg" "源仓库名称（可选，仅显示该源的已安装技能）" "STRING"
	args.process "$@"

	local -n args_arr=$(args.args)
	local filter="${args_arr[0]:-}"
	local home="$(path.data_dir)"

	# ── Source-filtered mode ──
	if [[ -n $filter ]]; then
		config.array.has "sources" "$filter" || {
			log.error "Source '${filter}' not found"
			exit 1
		}
		local n agent mode path target
		local -a left=() right=()
		for n in $(_get_installed_by_source "$filter"); do
			agent="$(_get_installed_field "$n" "agent")" || agent=""
			mode="$(_get_installed_field "$n" "mode")" || mode=""
			path="$(_get_installed_field "$n" "project_path")" || path=""
			if [[ $mode == "project" && -n $path ]]; then
				target="${Dim}${path} (${agent})${NC}"
			else
				local user_dir
				user_dir="$(_get_agent_user_dir "$agent")" || user_dir=""
				target="${Dim}${user_dir} (${agent})${NC}"
			fi
			left+=("  ${GREEN}✓${NC} ${n}")
			right+=("${target}")
		done
		if [[ ${#left[@]} -eq 0 ]]; then
			log.info "No installed skills from '${filter}'"
			return
		fi
		local max_width=0 w i
		for s in "${left[@]}"; do
			w=$(console.display_width "$s")
			((w > max_width)) && max_width=$w
		done
		((max_width += 4))
		for ((i = 0; i < ${#left[@]}; i++)); do
			console.align "$max_width" "${left[$i]}" "${right[$i]}"
		done
		return
	fi

	# ── Full status ──
	local cfg="$(config.path)"
	console.stdout "${Bold}Home:${NC} ${home}"
	git -C "$home" rev-parse --git-dir &> /dev/null && console.stdout "${Bold}Git:${NC} initialized" || console.stdout "${Bold}Git:${NC} ---"
	console.stdout "${Bold}Config:${NC} ${cfg}"
	console.stdout ""

	local names name source_count=0 cloned_count=0 skills_count=0
	names="$(_get_source_names)"
	names="$(string.trim "$names")"
	for name in $names; do
		((++source_count))
		[[ -d "${home}/skills/${name}" ]] && ((++cloned_count))
	done
	console.stdout "${Bold}Sources:${NC} ${source_count} configured, ${cloned_count} cloned"
	for name in $names; do
		if [[ -d "${home}/skills/${name}" ]]; then
			console.stdout "  ${GREEN}✓${NC} ${name}"
		else
			console.stdout "  ${RED}✗${NC} ${name} (not cloned)"
		fi
	done
	console.stdout ""

	for name in $names; do
		if [[ -d "${home}/skills/${name}" ]]; then
			while IFS= read -r -d '' skill_file; do
				((skills_count++))
			done < <(_scan_source_skills "${home}/skills/${name}" 2> /dev/null)
		fi
	done

	local installed_names installed_count=0
	installed_names="$(_get_installed_names)"
	installed_names="$(string.trim "$installed_names")"
	for n in $installed_names; do
		((installed_count++))
	done
	console.stdout "${Bold}Skills:${NC} ${skills_count} available, ${installed_count} installed"

	local -a left=() right=()
	for n in $installed_names; do
		local src agent mode path target
		src="$(_get_installed_field "$n" "source")" || src=""
		agent="$(_get_installed_field "$n" "agent")" || agent=""
		mode="$(_get_installed_field "$n" "mode")" || mode=""
		path="$(_get_installed_field "$n" "project_path")" || path=""
		if [[ $mode == "project" && -n $path ]]; then
			target="${Dim}${path} (${agent})${NC}"
		else
			local user_dir
			user_dir="$(_get_agent_user_dir "$agent")" || user_dir=""
			target="${Dim}${user_dir} (${agent})${NC}"
		fi
		left+=("  ${GREEN}✓${NC} ${n} (${src})")
		right+=("${target}")
	done

	local max_width=0 w i
	for s in "${left[@]}"; do
		w=$(console.display_width "$s")
		((w > max_width)) && max_width=$w
	done
	((max_width += 4))
	for ((i = 0; i < ${#left[@]}; i++)); do
		console.align "$max_width" "${left[$i]}" "${right[$i]}"
	done
	console.stdout ""

	local agent_count=0
	local agent_names="$(_get_agent_names)"
	agent_names="$(string.trim "$agent_names")"
	for a in $agent_names; do
		((agent_count++))
	done
	console.stdout "${Bold}Agents:${NC} ${agent_count} configured"
	_show_agents
}

# ── agent 命令组 ──

_show_agents() {
	local names name user_dir project_dir
	names="$(_get_agent_names)"
	names="$(string.trim "$names")"
	for name in $names; do
		user_dir="$(_get_agent_user_dir "$name")"
		project_dir="$(_get_agent_project_dir "$name")"
		console.stdout "  ${CYAN}${Bold}${name}${NC}"
		console.stdout "$(printf "    ├─ %-12s ${Dim}%s${NC}" "user" "${user_dir}")"
		console.stdout "$(printf "    └─ %-12s ${Dim}%s${NC}" "project" "${project_dir}")"
	done
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

	# 无子命令时默认显示 status
	local -n _args=$(args.args)
	[[ -z $_ARGS_CURRENT_SUBCOMMAND ]] && cmd_status "${_args[@]}" && exit 0
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	main "$@"
fi
