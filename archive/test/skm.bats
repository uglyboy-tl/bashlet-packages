#!/usr/bin/env bats

load 'test_helper/common-setup'

setup() {
	_common_setup
	export XDG_DATA_HOME="${BATS_TEST_TMPDIR}/skm-xdg"
	export XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/skm-xdg"
	SKM_HOME="$XDG_DATA_HOME/skm"
	SKM_CONFIG="$XDG_CONFIG_HOME/skm/config.toml"
	export GIT_AUTHOR_NAME="skm test"
	export GIT_AUTHOR_EMAIL="test@skm"
	export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
	export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
	export GIT_ALLOW_PROTOCOL=file

	mkdir -p "$SKM_HOME" "$(dirname "$SKM_CONFIG")"
}

# ── Help & Info ──

@test "help - 显示主帮助信息" {
	run bash "$PROJECT_ROOT/archive/skm.sh" --help
	[[ $status -eq 0 ]]
	echo "$output" | grep -q "add"
	echo "$output" | grep -q "remove"
	echo "$output" | grep -q "update"
	echo "$output" | grep -q "install"
	echo "$output" | grep -q "uninstall"
	echo "$output" | grep -q "list"
	echo "$output" | grep -q "search"
}

@test "help - 显示版本信息" {
	run bash "$PROJECT_ROOT/archive/skm.sh" --version
	[[ $status -eq 0 ]]
	echo "$output" | grep -qi "version"
}

@test "error - 未知子命令" {
	run bash "$PROJECT_ROOT/archive/skm.sh" nonexistent
	[[ $status -ne 0 ]]
}

# ── 源仓库管理 ──

@test "add 需要仓库参数" {
	run bash "$PROJECT_ROOT/archive/skm.sh" add
	[[ $status -ne 0 ]]
}

@test "add 无效的格式报错" {
	run bash "$PROJECT_ROOT/archive/skm.sh" add "badformat"
	[[ $status -ne 0 ]]
}

@test "add 添加源仓库（指定名称）" {
	local fake_repo="${BATS_TEST_TMPDIR}/fake-repo"
	git init "$fake_repo"
	git -C "$fake_repo" commit --allow-empty -m "init"

	run bash "$PROJECT_ROOT/archive/skm.sh" add -n my-test-repo "$fake_repo"
	[[ $status -eq 0 ]]
	[[ -d "$SKM_HOME/skills/my-test-repo" ]]
	grep -q "my-test-repo" "$SKM_CONFIG"
}

@test "add 自动检测源名称" {
	local fake_repo="${BATS_TEST_TMPDIR}/auto-repo"
	git init "$fake_repo"
	git -C "$fake_repo" commit --allow-empty -m "init"

	run bash "$PROJECT_ROOT/archive/skm.sh" add "$fake_repo"
	[[ $status -eq 0 ]]
	[[ -d "$SKM_HOME/skills/auto-repo" ]]
	grep -q "auto-repo" "$SKM_CONFIG"
}

@test "add 无效的本地路径报错" {
	run bash "$PROJECT_ROOT/archive/skm.sh" add -n bad-repo /tmp/nonexistent-path
	[[ $status -ne 0 ]]
}

@test "add 非 git 目录报错" {
	local empty_dir="${BATS_TEST_TMPDIR}/not-a-repo"
	mkdir -p "$empty_dir"
	run bash "$PROJECT_ROOT/archive/skm.sh" add -n bad-repo "$empty_dir"
	[[ $status -ne 0 ]]
}

@test "add 已存在的源跳过" {
	local fake_repo="${BATS_TEST_TMPDIR}/dup-repo"
	git init "$fake_repo"
	git -C "$fake_repo" commit --allow-empty -m "init"
	bash "$PROJECT_ROOT/archive/skm.sh" add -n dup-test "$fake_repo"

	run bash "$PROJECT_ROOT/archive/skm.sh" add -n dup-test "$fake_repo"
	[[ $status -eq 0 ]]
}

@test "remove 需要参数" {
	run bash "$PROJECT_ROOT/archive/skm.sh" remove
	[[ $status -ne 0 ]]
}

@test "remove 不存在的源报错" {
	run bash "$PROJECT_ROOT/archive/skm.sh" remove nonexistent
	[[ $status -ne 0 ]]
}

@test "remove 移除源仓库" {
	local fake_repo="${BATS_TEST_TMPDIR}/remove-repo"
	git init "$fake_repo"
	git -C "$fake_repo" commit --allow-empty -m "init"
	bash "$PROJECT_ROOT/archive/skm.sh" add -n remove-test "$fake_repo"

	run bash "$PROJECT_ROOT/archive/skm.sh" remove remove-test
	[[ $status -eq 0 ]]
	[[ ! -d "$SKM_HOME/skills/remove-test" ]]
	! grep -q "remove-test" "$SKM_CONFIG"
}

@test "update 可被调用（无参数）" {
	run bash "$PROJECT_ROOT/archive/skm.sh" update
	[[ $status -eq 0 ]]
}

@test "update 未知名称报错" {
	run bash "$PROJECT_ROOT/archive/skm.sh" update nonexistent
	[[ $status -ne 0 ]]
}

@test "update 补充缺失的源" {
	local fake_repo="${BATS_TEST_TMPDIR}/missing-repo"
	git init "$fake_repo"
	git -C "$fake_repo" commit --allow-empty -m "init"

	bash "$PROJECT_ROOT/archive/skm.sh" add -n missing-test "$fake_repo"
	rm -rf "$SKM_HOME/skills/missing-test"

	run bash "$PROJECT_ROOT/archive/skm.sh" update
	[[ $status -eq 0 ]]
	[[ -d "$SKM_HOME/skills/missing-test" ]]
}

@test "update 清理冗余目录" {
	local fake_repo="${BATS_TEST_TMPDIR}/cleanup-repo"
	git init "$fake_repo"
	git -C "$fake_repo" commit --allow-empty -m "init"

	mkdir -p "$SKM_HOME/skills/not-in-config"

	run bash "$PROJECT_ROOT/archive/skm.sh" update
	[[ $status -eq 0 ]]
	[[ ! -d "$SKM_HOME/skills/not-in-config" ]]
}

@test "update 更新已克隆的源" {
	local fake_repo="${BATS_TEST_TMPDIR}/pull-test"
	git init "$fake_repo"
	git -C "$fake_repo" commit --allow-empty -m "init"

	bash "$PROJECT_ROOT/archive/skm.sh" add -n pull-test "$fake_repo"

	run bash "$PROJECT_ROOT/archive/skm.sh" update pull-test
	[[ $status -eq 0 ]]
}

@test "update 重新创建已安装技能的软链接" {
	local fake_repo="${BATS_TEST_TMPDIR}/relink-user"
	git init "$fake_repo"
	mkdir -p "${fake_repo}/relink-skill"
	cat > "${fake_repo}/relink-skill/SKILL.md" << 'EOF'
---
name: relink-skill
---
EOF
	git -C "$fake_repo" add -A && git -C "$fake_repo" commit -m "init"
	bash "$PROJECT_ROOT/archive/skm.sh" add -n relink-source "$fake_repo"

	local sandbox_home="${BATS_TEST_TMPDIR}/sandbox-relink"
	mkdir -p "$sandbox_home/.config/opencode/skills"
	env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" install relink-skill --user
	rm -f "$sandbox_home/.config/opencode/skills/relink-skill"

	run env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" update relink-source
	[[ $status -eq 0 ]]
	[[ -L "$sandbox_home/.config/opencode/skills/relink-skill" ]]
	local target
	target="$(readlink "$sandbox_home/.config/opencode/skills/relink-skill")"
	[[ $target == *"/relink-source/relink-skill" ]]
}

@test "update 重新创建项目级已安装技能的软链接" {
	local fake_repo="${BATS_TEST_TMPDIR}/relink-proj"
	git init "$fake_repo"
	mkdir -p "${fake_repo}/relink-proj-skill"
	cat > "${fake_repo}/relink-proj-skill/SKILL.md" << 'EOF'
---
name: relink-proj-skill
---
EOF
	git -C "$fake_repo" add -A && git -C "$fake_repo" commit -m "init"
	bash "$PROJECT_ROOT/archive/skm.sh" add -n relink-proj-source "$fake_repo"

	local sandbox_home="${BATS_TEST_TMPDIR}/sandbox-relink-proj"
	mkdir -p "$sandbox_home/.config/opencode/skills"
	local proj_dir="${BATS_TEST_TMPDIR}/proj"
	mkdir -p "$proj_dir"
	env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" install relink-proj-skill --project "$proj_dir"
	rm -f "$proj_dir/.agents/skills/relink-proj-skill"

	run env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" update relink-proj-source
	[[ $status -eq 0 ]]
	[[ -L "$proj_dir/.agents/skills/relink-proj-skill" ]]
}

@test "list 可被调用" {
	run bash "$PROJECT_ROOT/archive/skm.sh" list
	[[ $status -eq 0 ]]
}

@test "list 列出已克隆源的 skills" {
	local fake_repo="${BATS_TEST_TMPDIR}/ls-skills"
	git init "$fake_repo"
	mkdir -p "${fake_repo}/my-skill"
	cat > "${fake_repo}/my-skill/SKILL.md" << 'EOF'
---
name: my-skill
description: A test skill
---
EOF
	git -C "$fake_repo" add -A && git -C "$fake_repo" commit -m "init"

	bash "$PROJECT_ROOT/archive/skm.sh" add -n ls-test "$fake_repo"
	run bash "$PROJECT_ROOT/archive/skm.sh" list
	[[ $status -eq 0 ]]
	echo "$output" | grep -q "ls-test"
	echo "$output" | grep -q "my-skill"
	echo "$output" | grep -q "A test skill"
}

@test "list 列出根级 SKILL.md 的源" {
	local fake_repo="${BATS_TEST_TMPDIR}/ls-root-repo"
	git init "$fake_repo"
	cat > "${fake_repo}/SKILL.md" << 'EOF'
---
name: root-skill
description: Root level skill
---
EOF
	git -C "$fake_repo" add -A && git -C "$fake_repo" commit -m "init"

	bash "$PROJECT_ROOT/archive/skm.sh" add -n ls-root-source "$fake_repo"
	run bash "$PROJECT_ROOT/archive/skm.sh" list
	[[ $status -eq 0 ]]
	echo "$output" | grep -q "ls-root-source"
	echo "$output" | grep -q "root-skill"
	echo "$output" | grep -q "Root level skill"
}

# ── search ──

@test "search - 需要关键词参数" {
	run bash "$PROJECT_ROOT/archive/skm.sh" search
	[[ $status -ne 0 ]]
}

@test "search - 可被调用" {
	[[ -n ${SKILLINK_TEST_NETWORK:-} ]] || skip "SKILLINK_TEST_NETWORK not set"
	run bash "$PROJECT_ROOT/archive/skm.sh" search typescript
	[[ $status -eq 0 ]]
}

# ── install ──

_setup_install_source() {
	local name="$1" skill_name="$2"
	local repo="${BATS_TEST_TMPDIR}/${name}-repo"
	git init "$repo"
	mkdir -p "${repo}/${skill_name}"
	cat > "${repo}/${skill_name}/SKILL.md" <<-EOF
		---
		name: ${skill_name}
		description: Skill from ${name}
		---
	EOF
	git -C "$repo" add -A && git -C "$repo" commit -m "init"
	bash "$PROJECT_ROOT/archive/skm.sh" add -n "$name" "$repo"
}

@test "install - 需要 skill 名称" {
	run bash "$PROJECT_ROOT/archive/skm.sh" install
	[[ $status -ne 0 ]]
}

@test "install - 不存在的 skill 报错" {
	run bash "$PROJECT_ROOT/archive/skm.sh" install nonexistent
	[[ $status -ne 0 ]]
}

@test "install - 用户级安装" {
	_setup_install_source "install-src" "my-skill"
	local sandbox_home="${BATS_TEST_TMPDIR}/sandbox-home"
	mkdir -p "$sandbox_home/.config/opencode/skills"

	run env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" install my-skill --user
	[[ $status -eq 0 ]]
	[[ -f "$sandbox_home/.config/opencode/skills/my-skill/SKILL.md" ]]
}

@test "install - 项目级安装" {
	_setup_install_source "proj-src" "proj-skill"
	local proj_dir="${BATS_TEST_TMPDIR}/my-project"
	mkdir -p "$proj_dir"

	run bash "$PROJECT_ROOT/archive/skm.sh" install proj-skill --project "$proj_dir"
	[[ $status -eq 0 ]]
	[[ -f "$proj_dir/.agents/skills/proj-skill/SKILL.md" ]]
}

@test "install - 指定 source" {
	_setup_install_source "first-src" "common-skill"
	# Override HOME to sandbox user-level install for the second step
	local sandbox_home="${BATS_TEST_TMPDIR}/sandbox-home3"
	mkdir -p "$sandbox_home/.config/opencode/skills"

	run env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" install common-skill --source first-src --user
	[[ $status -eq 0 ]]
	[[ -f "$sandbox_home/.config/opencode/skills/common-skill/SKILL.md" ]]
}

@test "install - 指定 source 不匹配报错" {
	_setup_install_source "match-src" "match-skill"
	run bash "$PROJECT_ROOT/archive/skm.sh" install match-skill --source wrong-src
	[[ $status -ne 0 ]]
}

@test "install - 已安装的 skill 跳过" {
	_setup_install_source "dup-src" "dup-skill"
	local sandbox_home="${BATS_TEST_TMPDIR}/sandbox-home2"
	mkdir -p "$sandbox_home/.config/opencode/skills"

	env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" install dup-skill --user
	run env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" install dup-skill --user
	[[ $status -eq 0 ]]
	[[ -f "$sandbox_home/.config/opencode/skills/dup-skill/SKILL.md" ]]
}

@test "install --help 显示帮助" {
	run bash "$PROJECT_ROOT/archive/skm.sh" install --help
	[[ $status -eq 0 ]]
	echo "$output" | grep -q "source"
	echo "$output" | grep -q "project"
	echo "$output" | grep -q "agent"
}

@test "install - 根级 skill" {
	local fake_repo="${BATS_TEST_TMPDIR}/root-skill-repo"
	git init "$fake_repo"
	cat > "${fake_repo}/SKILL.md" << 'EOF'
---
name: root-skill
description: Root level skill
---
EOF
	git -C "$fake_repo" add -A && git -C "$fake_repo" commit -m "init"
	bash "$PROJECT_ROOT/archive/skm.sh" add -n root-skill-source "$fake_repo"

	local sandbox_home="${BATS_TEST_TMPDIR}/sandbox-root"
	mkdir -p "$sandbox_home/.config/opencode/skills"

	run env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" install root-skill --user
	[[ $status -eq 0 ]]
	[[ -f "$sandbox_home/.config/opencode/skills/root-skill/SKILL.md" ]]
}

@test "install - 按 frontmatter name 匹配" {
	local fake_repo="${BATS_TEST_TMPDIR}/fm-repo"
	git init "$fake_repo"
	mkdir -p "${fake_repo}/some-dir"
	cat > "${fake_repo}/some-dir/SKILL.md" << 'EOF'
---
name: fm-skill
description: Frontmatter match test
---
EOF
	git -C "$fake_repo" add -A && git -C "$fake_repo" commit -m "init"
	bash "$PROJECT_ROOT/archive/skm.sh" add -n fm-source "$fake_repo"

	local sandbox_home="${BATS_TEST_TMPDIR}/sandbox-fm"
	mkdir -p "$sandbox_home/.config/opencode/skills"

	run env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" install fm-skill --user
	[[ $status -eq 0 ]]
	[[ -f "$sandbox_home/.config/opencode/skills/fm-skill/SKILL.md" ]]
}

@test "install - 已有 symlink 时更新" {
	local fake_repo="${BATS_TEST_TMPDIR}/symlink-repo"
	git init "$fake_repo"
	mkdir -p "${fake_repo}/update-skill"
	cat > "${fake_repo}/update-skill/SKILL.md" << 'EOF'
---
name: update-skill
---
EOF
	git -C "$fake_repo" add -A && git -C "$fake_repo" commit -m "init"
	bash "$PROJECT_ROOT/archive/skm.sh" add -n symlink-source "$fake_repo"

	local sandbox_home="${BATS_TEST_TMPDIR}/sandbox-symlink"
	mkdir -p "$sandbox_home/.config/opencode/skills"
	ln -s /tmp/stale-target "$sandbox_home/.config/opencode/skills/update-skill"

	run env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" install update-skill --user
	[[ $status -eq 0 ]]
	local link_target
	link_target="$(readlink "$sandbox_home/.config/opencode/skills/update-skill")"
	echo "$link_target" | grep -q "symlink-source"
}

@test "install --source owner/repo 自动添加源失败" {
	local sandbox_home="${BATS_TEST_TMPDIR}/sandbox-auto"
	mkdir -p "$sandbox_home/.config/opencode/skills"
	run env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" install test-skill --source fake-owner/fake-repo
	[[ $status -ne 0 ]]
}

@test "install --source 已有源不触发自动添加" {
	_setup_install_source "auto-skip-source" "auto-skip-skill"
	local sandbox_home="${BATS_TEST_TMPDIR}/sandbox-auto2"
	mkdir -p "$sandbox_home/.config/opencode/skills"
	run env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" install auto-skip-skill --source auto-skip-source
	[[ $status -eq 0 ]]
	rm -rf ".agents/skills/auto-skip-skill"
}

@test "install - 默认当前目录项目级安装" {
	_setup_install_source "cwd-src" "cwd-skill"
	local sandbox_home="${BATS_TEST_TMPDIR}/sandbox-cwd"
	mkdir -p "$sandbox_home/.config/opencode/skills"
	local proj_dest="${BATS_TEST_TMPDIR}/.agents/skills/cwd-skill"

	run bash "$PROJECT_ROOT/archive/skm.sh" install cwd-skill --project "$BATS_TEST_TMPDIR"
	[[ $status -eq 0 ]]
	[[ -L $proj_dest ]]
}

# ── uninstall ──

@test "uninstall - 需要 skill 名称" {
	run bash "$PROJECT_ROOT/archive/skm.sh" uninstall
	[[ $status -ne 0 ]]
}

@test "uninstall - 不存在的 skill 报错" {
	run bash "$PROJECT_ROOT/archive/skm.sh" uninstall nonexistent
	[[ $status -ne 0 ]]
}

@test "uninstall - 卸载已安装技能" {
	_setup_install_source "uninst-src" "uninst-skill"
	local sandbox_home="${BATS_TEST_TMPDIR}/sandbox-uninst"
	mkdir -p "$sandbox_home/.config/opencode/skills"

	env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" install uninst-skill --user
	run env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" uninstall uninst-skill
	[[ $status -eq 0 ]]
	[[ ! -L "$sandbox_home/.config/opencode/skills/uninst-skill" ]]
}

@test "uninstall - 支持 --agent 选项" {
	_setup_install_source "agt-src" "agt-skill"
	local sandbox_home="${BATS_TEST_TMPDIR}/sandbox-agt"
	mkdir -p "$sandbox_home/.config/opencode/skills"

	env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" install agt-skill --user
	run env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" uninstall agt-skill --agent opencode
	[[ $status -eq 0 ]]
	[[ ! -L "$sandbox_home/.config/opencode/skills/agt-skill" ]]
}

@test "uninstall - 指定错误的 agent 报错" {
	_setup_install_source "wrong-agt-src" "wrong-agt"
	local sandbox_home="${BATS_TEST_TMPDIR}/sandbox-wrong-agt"
	mkdir -p "$sandbox_home/.config/opencode/skills"

	env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" install wrong-agt --user
	run env HOME="$sandbox_home" bash "$PROJECT_ROOT/archive/skm.sh" uninstall wrong-agt --agent NONSENSE
	[[ $status -ne 0 ]]
}

# ── 默认 status ──

@test "默认显示 status 信息" {
	run bash "$PROJECT_ROOT/archive/skm.sh"
	[[ $status -eq 0 ]]
	[[ $output =~ "Home:" ]]
	[[ $output =~ "Git:" ]]
	[[ $output =~ "Config:" ]]
	[[ $output =~ "Sources:" ]]
	[[ $output =~ "Skills:" ]]
	[[ $output =~ "Agents:" ]]
	[[ $output =~ "opencode" ]]
	[[ $output =~ "user" ]]
	[[ $output =~ "project" ]]
}

@test "status 指定源无已安装技能" {
	local fake_repo="${BATS_TEST_TMPDIR}/status-source"
	git init "$fake_repo"
	git -C "$fake_repo" commit --allow-empty -m "init"
	bash "$PROJECT_ROOT/archive/skm.sh" add -n status-test "$fake_repo"

	run bash "$PROJECT_ROOT/archive/skm.sh" status-test
	[[ $status -eq 0 ]]
	echo "$output" | grep -q "No installed skills"
}

# ── 配置初始化 ──

@test "init - 自动创建配置文件" {
	run bash "$PROJECT_ROOT/archive/skm.sh" list
	[[ -f "$SKM_CONFIG" ]]
}

@test "init - 配置包含默认 agents" {
	run bash "$PROJECT_ROOT/archive/skm.sh" list
	[[ -f "$SKM_CONFIG" ]]
	grep -q "opencode" "$SKM_CONFIG"
}

@test "init - 自动创建 skm home" {
	[[ -d "$SKM_HOME" ]]
}

@test "init - 从已有配置加载 sources" {
	mkdir -p "${BATS_TEST_TMPDIR}/skm-config"
	cat > "$SKM_CONFIG" <<-TOML
	[sources.test-source]
	repo = "https://github.com/test/test-skills"

	[agents.opencode]
	user_dir = "~/.config/opencode/skills"
	project_dir = ".opencode/skills"
	TOML

	run bash "$PROJECT_ROOT/archive/skm.sh" list
	[[ $status -eq 0 ]]
}

@test "init - 配置不覆盖已有文件" {
	mkdir -p "${BATS_TEST_TMPDIR}/skm-config"
	echo "custom content" > "$SKM_CONFIG"
	run bash "$PROJECT_ROOT/archive/skm.sh" list
	[[ $(< "$SKM_CONFIG") == "custom content" ]]
}
