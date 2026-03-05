#!/usr/bin/env bats

load 'test_helper/common-setup'

setup() {
  _common_setup
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
}

teardown() {
  if [[ -n $TEST_TMPDIR && -d $TEST_TMPDIR ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

@test "basic help shows error message" {
  run "$PROJECT_ROOT/src/opencode-test.sh"
  [[ $status -ne 0 ]]
  [[ $output == *"错误: 请提供测试用例 JSON 文件"* ]]
}

@test "missing test file shows error" {
  run "$PROJECT_ROOT/src/opencode-test.sh" "$TEST_TMPDIR/nonexistent.json"
  [[ $status -ne 0 ]]
  [[ $output == *"错误: 测试文件"* ]]
}

@test "accepts valid json file" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{
  "description": "test",
  "config": {
    "agents": [],
    "commands": [],
    "skills": [],
    "model": "opencode/gpt-5-nano",
    "timeout": 30,
    "parallel": 4
  },
  "tests": []
}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
  [[ $output == *"开始执行测试"* ]]
}

@test "supports verbose option" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" -v "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
  [[ $output == *"详细模式已启用"* ]]
}

@test "supports jobs option" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" -j 2 "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
}

@test "supports output option" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" -o "$TEST_TMPDIR/output.json" "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
}

@test "supports timeout option" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" --timeout 60 "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
}

@test "supports model option" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" --model "test/model" "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
}

@test "shows help with -h" {
  run "$PROJECT_ROOT/src/opencode-test.sh" -h
  [[ $status -eq 0 ]]
  [[ $output == *"Usage:"* ]]
}
