#!/usr/bin/env bats

load 'test_helper/common-setup'

# 生成测试配置文件的辅助函数
# 参数说明:
#   $1: agents 数组 (默认: [])
#   $2: commands 数组 (默认: [])
#   $3: skills 数组 (默认: [])
#   $4: tests 数组 (默认: [])
#   $5: 额外的配置项 (默认: 空)
#   $6: 输出文件路径 (默认: $TEST_TMPDIR/config.json)
generate_test_config() {
  local agents="${1:-[]}"
  local commands="${2:-[]}"
  local skills="${3:-[]}"
  local tests="${4:-[]}"
  local extra_config="${5:-}"
  local output_file="${6:-$TEST_TMPDIR/config.json}"

  # 构建 JSON 配置内容
  local config_content="{\"description\": \"test\", \"config\": {\"agents\": $agents, \"commands\": $commands, \"skills\": $skills"

  # 添加额外配置项（如果存在）
  if [[ -n $extra_config ]]; then
    config_content="$config_content, $extra_config"
  fi

  config_content="$config_content}, \"tests\": $tests}"

  echo "$config_content" > "$output_file"
}

# 测试环境初始化
setup() {
  # 调用通用设置
  _common_setup

  # 定义测试资产路径
  TEST_ASSETS_DIR="$PROJECT_ROOT/test/assets/opencode-test"

  # 创建临时目录用于测试
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  # 设置测试输出目录
  export OPENCODE_TEST_OUTPUT="$TEST_TMPDIR"

  # 创建 mock opencode 命令
  MOCK_OPENCODE_DIR="$TEST_TMPDIR/mock-bin"
  mkdir -p "$MOCK_OPENCODE_DIR"
  cp "$TEST_ASSETS_DIR/mock-opencode.sh" "$MOCK_OPENCODE_DIR/opencode"
  chmod +x "$MOCK_OPENCODE_DIR/opencode"

  # 将 mock opencode 加入 PATH，所有测试默认使用
  export PATH="$MOCK_OPENCODE_DIR:$PATH"k

  # 复制常用测试资产到临时目录
  cp "$TEST_ASSETS_DIR/full.json" "$TEST_TMPDIR/full.json"
  mkdir -p "$TEST_TMPDIR/output" "$TEST_TMPDIR/agents" "$TEST_TMPDIR/.opencode/agents"
  cp "$TEST_ASSETS_DIR/opencode-output-basic.jsonl" "$TEST_TMPDIR/output/test1.jsonl"
  cp "$TEST_ASSETS_DIR/empty.md" "$TEST_TMPDIR/.opencode/agents/grader.md"
  cp "$TEST_ASSETS_DIR/empty.md" "$TEST_TMPDIR/agents/test-agent.md"

  # Source the main script for all tests
  source "$PROJECT_ROOT/src/opencode-test.sh"
}

teardown() {
  if [[ -n $TEST_TMPDIR && -d $TEST_TMPDIR ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

@test "test: 无参数时显示帮助错误" {
  run "$PROJECT_ROOT/src/opencode-test.sh" test
  [[ $status -ne 0 ]]
  [[ $output == *"[ERROR] 请提供测试用例 JSON 文件"* ]]
}

@test "test: 验证测试文件存在性" {
  run "$PROJECT_ROOT/src/opencode-test.sh" test "$TEST_TMPDIR/nonexistent.json"
  [[ $status -ne 0 ]]
  [[ $output == *"[ERROR] 测试文件"* ]]
}

@test "test: 接受有效的 JSON 测试文件" {
  run "$PROJECT_ROOT/src/opencode-test.sh" test "$TEST_TMPDIR/full.json"
  [[ $status -eq 0 ]]
  [[ $output == *"开始执行测试"* ]]
}

@test "test: 支持 verbose 选项" {
  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/full.json"
  [[ $status -eq 0 ]]
  [[ $output == *"详细模式已启用"* ]]
}

@test "test: 支持 jobs 选项" {
  run "$PROJECT_ROOT/src/opencode-test.sh" test -j 2 "$TEST_TMPDIR/full.json"
  [[ $status -eq 0 ]]
}

@test "test: 支持 output 选项" {
  run "$PROJECT_ROOT/src/opencode-test.sh" test -o "$TEST_TMPDIR/output.json" "$TEST_TMPDIR/full.json"
  [[ $status -eq 0 ]]
}

@test "test: 支持 timeout 选项" {
  run "$PROJECT_ROOT/src/opencode-test.sh" test --timeout 60 "$TEST_TMPDIR/full.json"
  [[ $status -eq 0 ]]
}

@test "test: 支持 model 选项" {
  run "$PROJECT_ROOT/src/opencode-test.sh" test --model "test/model" "$TEST_TMPDIR/full.json"
  [[ $status -eq 0 ]]
}

@test "test: -h 显示帮助信息" {
  run "$PROJECT_ROOT/src/opencode-test.sh" test -h
  [[ $status -eq 0 ]]
  [[ $output == *"Usage:"* ]]
}

@test "test: 验证 JSON 文件有效性" {
  cp "$TEST_ASSETS_DIR/invalid.json" "$TEST_TMPDIR/invalid.json"
  run "$PROJECT_ROOT/src/opencode-test.sh" test "$TEST_TMPDIR/invalid.json"
  [[ $status -ne 0 ]]
  [[ $output == *"[ERROR] 无效的 JSON 文件"* ]]
}

@test "test: 允许缺少 description 字段" {
  cp "$TEST_ASSETS_DIR/missing-fields.json" "$TEST_TMPDIR/missing-fields.json"
  run "$PROJECT_ROOT/src/opencode-test.sh" test "$TEST_TMPDIR/missing-fields.json"
  [[ $status -eq 0 ]]
}

@test "test: 验证 jobs 参数有效性" {
  # Test with valid positive number
  run "$PROJECT_ROOT/src/opencode-test.sh" test -j 2 "$TEST_TMPDIR/full.json"
  [[ $status -eq 0 ]]

  # Test with zero (should fail)
  run "$PROJECT_ROOT/src/opencode-test.sh" test -j 0 "$TEST_TMPDIR/full.json"
  [[ $status -ne 0 ]]
}

@test "test: 验证 timeout 参数有效性" {
  # Test with valid positive number
  run "$PROJECT_ROOT/src/opencode-test.sh" test --timeout 60 "$TEST_TMPDIR/full.json"
  [[ $status -eq 0 ]]

  # Test with zero (should fail)
  run "$PROJECT_ROOT/src/opencode-test.sh" test --timeout 0 "$TEST_TMPDIR/full.json"
  [[ $status -ne 0 ]]
}

@test "test: 缺少 tests 字段时显示警告" {
  cp "$TEST_ASSETS_DIR/no-tests.json" "$TEST_TMPDIR/no-tests.json"
  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/no-tests.json"
  [[ $status -eq 0 ]]
  [[ $output == *"[WARN] 测试文件缺少 tests 字段，将执行 0 个测试用例"* ]]
}

@test "test: 验证输出目录创建" {
  generate_test_config "[]" "[]" "[]" "[]" "" "$TEST_TMPDIR/full.json"
  run "$PROJECT_ROOT/src/opencode-test.sh" test -o "$TEST_TMPDIR/output" "$TEST_TMPDIR/full.json"
  [[ $status -eq 0 ]]
  [[ -d "$TEST_TMPDIR/output" ]]
}

@test "test: 复制 agent 文件到测试环境" {
  generate_test_config "[\"$TEST_TMPDIR/agents/test-agent.md\"]"

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"复制 agent: $TEST_TMPDIR/agents/test-agent.md"* ]]
}

@test "test: 复制 command 文件到测试环境" {
  # 创建模拟command文件（.md格式）
  mkdir -p "$TEST_TMPDIR/commands"
  cp "$TEST_ASSETS_DIR/empty.md" "$TEST_TMPDIR/commands/test-command.md"

  generate_test_config "[]" "[\"$TEST_TMPDIR/commands/test-command.md\"]"

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"复制 command: $TEST_TMPDIR/commands/test-command.md"* ]]
}

@test "test: 复制 skill 目录到测试环境" {
  # 创建模拟skill目录
  mkdir -p "$TEST_TMPDIR/skills/test-skill"
  cp "$TEST_ASSETS_DIR/empty.md" "$TEST_TMPDIR/skills/test-skill/SKILL.md"

  generate_test_config "[]" "[]" "[\"$TEST_TMPDIR/skills/test-skill\"]"

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"复制 skill: $TEST_TMPDIR/skills/test-skill"* ]]
}

@test "test: 处理不存在的 agent 文件" {
  generate_test_config '["/nonexistent/agent.md"]'

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  # Should not fail, just skip non-existent files
}

@test "test: 配置文件参数覆盖命令行参数" {
  mkdir -p "$TEST_TMPDIR/agents"
  echo "# Test Agent" > "$TEST_TMPDIR/agents/test-agent.md"

  local extra_config='"agents": ["'$TEST_TMPDIR/agents/test-agent.md'"], "model": "test/custom-model", "timeout": 60, "parallel": 2'
  generate_test_config "[]" "[]" "[]" "[]" "$extra_config"

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"模型: test/custom-model"* ]]
  [[ $output == *"超时: 60 秒"* ]]
  [[ $output == *"并行数: 2"* ]]
}

@test "test: 执行实际测试用例" {
  local tests_json='[{"name": "simple_test", "prompt": "hello world"}]'
  generate_test_config "[]" "[]" "[]" "$tests_json"

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: simple_test"* ]]
  [[ $output == *"找到 1 个测试用例"* ]]
}

@test "test: 执行多个实际测试用例" {
  local tests_json='[{"name": "test1", "prompt": "hello world"}, {"name": "test2", "prompt": "goodbye world"}]'
  generate_test_config "[]" "[]" "[]" "$tests_json"

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v --timeout 2 "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: test1"* ]]
  [[ $output == *"执行测试: test2"* ]]
  [[ $output == *"找到 2 个测试用例"* ]]
}

@test "test: 输出目录复制功能" {
  generate_test_config "[]" "[]" "[]" "[]" "" "$TEST_TMPDIR/config.json"

  run "$PROJECT_ROOT/src/opencode-test.sh" test -o "$TEST_TMPDIR/custom-output" "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ -d "$TEST_TMPDIR/custom-output" ]]
  [[ $output == *"输出已复制到: $TEST_TMPDIR/custom-output"* ]]
}

@test "test: 测试用例包含 agent 和 command" {
  local tests_json='[{"name": "test_with_agent", "agent": "test-agent", "command": "test-command", "prompt": "hello world"}]'
  generate_test_config "[]" "[]" "[]" "$tests_json"

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: test_with_agent"* ]]
  [[ $output == *"Agent: test-agent"* ]]
  [[ $output == *"Command: test-command"* ]]
}

@test "test: 验证 parallel 配置参数" {
  generate_test_config "[]" "[]" "[]" "[]" '"parallel": 8'

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"并行数: 8"* ]]
}

@test "test: 测试超时处理" {
  # 创建一个会超时的测试（使用sleep命令模拟长时间运行）
  local tests_json='[{"name": "timeout_test", "prompt": "this will timeout"}]'
  generate_test_config "[]" "[]" "[]" "$tests_json"

  # 使用非常短的超时时间（1秒）
  run "$PROJECT_ROOT/src/opencode-test.sh" test --timeout 1 "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  # Note: The actual timeout handling depends on the opencode command behavior
  # Since we can't easily mock opencode, we verify the script accepts the timeout parameter
}

@test "test: 测试用例包含单个 files 字段" {
  # 创建测试文件
  echo "test content" > "$TEST_TMPDIR/test-file.txt"

  local tests_json='[{"name": "test_with_files", "prompt": "process files", "files": ["test-file.txt"]}]'
  generate_test_config "[]" "[]" "[]" "$tests_json"

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: test_with_files"* ]]
  [[ $output == *"Files: [\"test-file.txt\"]"* ]]
}

@test "test: 测试用例包含多个 files 字段" {
  # 创建多个测试文件
  echo "file1 content" > "$TEST_TMPDIR/file1.txt"
  echo "file2 content" > "$TEST_TMPDIR/file2.txt"
  echo "file3 content" > "$TEST_TMPDIR/file3.txt"

  local tests_json='[{"name": "test_with_multiple_files", "prompt": "process multiple files", "files": ["file1.txt", "file2.txt", "file3.txt"]}]'
  generate_test_config "[]" "[]" "[]" "$tests_json"

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: test_with_multiple_files"* ]]
  [[ $output == *"Files: [\"file1.txt\",\"file2.txt\",\"file3.txt\"]"* ]]
}

@test "test: 测试用例包含 expectations 字段" {
  local tests_json='[{"name": "test_with_expectations", "prompt": "meet expectations", "expectations": ["输出包含 X", "技能使用了脚本 Y"]}]'
  generate_test_config "[]" "[]" "[]" "$tests_json"

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: test_with_expectations"* ]]
}

@test "test: agent 和 command 参数传递给 opencode" {
  # 创建模拟的 agent 和 command 文件
  mkdir -p "$TEST_TMPDIR/agents" "$TEST_TMPDIR/commands"
  cp "$TEST_ASSETS_DIR/empty.md" "$TEST_TMPDIR/commands/my-command.md"

  local agents_json='["'$TEST_TMPDIR/agents/grader.md'"]'
  local commands_json='["'$TEST_TMPDIR/commands/my-command.md'"]'
  local tests_json='[{"name": "specific_agent_command_test", "agent": "grader", "command": "my-command", "prompt": "test specific agent and command"}]'
  generate_test_config "$agents_json" "$commands_json" "[]" "$tests_json"

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: specific_agent_command_test"* ]]
  [[ $output == *"Agent: grader"* ]]
  [[ $output == *"Command: my-command"* ]]
}

@test "test: 测试执行后生成输出文件" {
  local tests_json='[{"name": "output_test", "prompt": "generate output"}]'
  generate_test_config "[]" "[]" "[]" "$tests_json"

  # 指定自定义输出目录
  run "$PROJECT_ROOT/src/opencode-test.sh" test -o "$TEST_TMPDIR/test-output" "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ -d "$TEST_TMPDIR/test-output" ]]
  [[ -f "$TEST_TMPDIR/test-output/output_test.jsonl" ]]
}

@test "e2e: 端到端测试使用真实 opencode" {
  # Skip this test if opencode is not available or if we're in CI
  if ! command -v opencode &> /dev/null; then
    skip "opencode CLI not available"
  fi

  # 临时移除 mock opencode 目录，使用真实的 opencode 命令
  PATH="${PATH//:$MOCK_OPENCODE_DIR/}"
  PATH="${PATH//$MOCK_OPENCODE_DIR:/}"
  PATH="${PATH//$MOCK_OPENCODE_DIR/}"

  # Create agent and command files from assets
  mkdir -p "$TEST_TMPDIR/agents" "$TEST_TMPDIR/commands"
  cp "$TEST_ASSETS_DIR/e2e-python-agent.md" "$TEST_TMPDIR/agents/python-agent.md"
  cp "$TEST_ASSETS_DIR/e2e-echo-hello.md" "$TEST_TMPDIR/commands/echo-hello.md"

  # Create test files from assets
  cp "$TEST_ASSETS_DIR/e2e-test-file1.txt" "$TEST_TMPDIR/test-file1.txt"
  cp "$TEST_ASSETS_DIR/e2e-test-file2.txt" "$TEST_TMPDIR/test-file2.txt"

  # Create test configuration from assets
  sed -e "s|TEST_AGENTS_PATH|$TEST_TMPDIR/agents/python-agent.md|" \
    -e "s|TEST_COMMANDS_PATH|$TEST_TMPDIR/commands/echo-hello.md|" \
    "$TEST_ASSETS_DIR/e2e-test.json" > "$TEST_TMPDIR/e2e-test.json"

  # Run with real opencode and capture output
  run "$PROJECT_ROOT/src/opencode-test.sh" test -v -o "$TEST_TMPDIR/e2e-output" "$TEST_TMPDIR/e2e-test.json"
  [[ $status -eq 0 ]]

  # Verify output directory structure
  [[ -d "$TEST_TMPDIR/e2e-output" ]]
  [[ -f "$TEST_TMPDIR/e2e-output/python_agent_test.jsonl" ]]

  # Verify the JSONL file contains valid JSON lines
  local jsonl_file="$TEST_TMPDIR/e2e-output/python_agent_test.jsonl"
  [[ -s $jsonl_file ]]

  # Verify it contains text response
  local has_text_response
  has_text_response=$(jq -r '.type' "$jsonl_file" | grep -c "text" || true)
  [[ $has_text_response -gt 0 ]]

  # Verify agent introduces itself by name (PythonExpert)
  local has_agent_name
  has_agent_name=$(jq -r 'select(.part.text) | .part.text' "$jsonl_file" | grep -c "PythonExpert" || true)
  [[ $has_agent_name -gt 0 ]]

  # Verify command outputs the specific string
  local has_command_output
  has_command_output=$(jq -r 'select(.part.text) | .part.text' "$jsonl_file" | grep -c "COMMAND_ECHO_HELLO_12345XYZ" || true)
  [[ $has_command_output -gt 0 ]]

  # Verify it has step finish events
  local has_step_finish
  has_step_finish=$(jq -r '.type' "$jsonl_file" | grep -c "step_finish" || true)
  [[ $has_step_finish -gt 0 ]]

  # Verify token usage is reported in at least one step_finish
  local has_tokens
  has_tokens=$(jq -r '.part.tokens.total // empty' "$jsonl_file" | grep -v null | grep -cv "^$")
  [[ $has_tokens -gt 0 ]]
}

# ============================================
# Test --autograde 功能测试
# ============================================

@test "test: --autograde 选项测试完成后自动评分" {
  # 创建测试文件
  local tests_json='[{"name": "test3", "prompt": "say hello"}, {"name": "test4", "prompt": "say world"}]'
  generate_test_config "[]" "[]" "[]" "$tests_json" "" "$TEST_TMPDIR/test-config.json"

  # 运行 test 命令并启用 --autograde
  run "$PROJECT_ROOT/src/opencode-test.sh" test \
    -o "$TEST_TMPDIR" \
    --timeout 3 \
    --autograde \
    "$TEST_TMPDIR/test-config.json"

  [[ $status -eq 0 ]]

  # 验证测试输出文件存在
  [[ -f "$TEST_TMPDIR/output/test3.jsonl" ]]
  [[ -f "$TEST_TMPDIR/output/test4.jsonl" ]]

  # 验证评分报告文件也被生成（在 output/grading/ 目录）
  [[ -f "$TEST_TMPDIR/grading/test3.json" ]]
  [[ -f "$TEST_TMPDIR/grading/test4.json" ]]
}

# ============================================
# Grade 子命令测试
# ============================================

@test "grade: 显示帮助信息" {
  run "$PROJECT_ROOT/src/opencode-test.sh" grade -h
  [[ $status -eq 0 ]]
  [[ $output == *"Usage:"* ]]
}

@test "grade: 需要指定测试文件" {
  run "$PROJECT_ROOT/src/opencode-test.sh" grade
  [[ $status -ne 0 ]]
  [[ $output == *"[ERROR]"* ]]
}

@test "grade: 验证测试文件存在性" {
  run "$PROJECT_ROOT/src/opencode-test.sh" grade "$TEST_TMPDIR/nonexistent.json"
  [[ $status -ne 0 ]]
  [[ $output == *"[ERROR]"* ]]
}

@test "grade: 支持 verbose 选项" {

  run "$PROJECT_ROOT/src/opencode-test.sh" grade -v "$TEST_TMPDIR/full.json"
  [[ $status -eq 0 ]]

  # 验证默认输出在临时目录的 grading 目录
  [[ -f "$TEST_TMPDIR/grading/test1.json" ]]
}

@test "grade: 支持 output 选项" {

  run "$PROJECT_ROOT/src/opencode-test.sh" grade -o "$TEST_TMPDIR" "$TEST_TMPDIR/full.json"
  [[ $status -eq 0 ]]
  [[ -d "$TEST_TMPDIR/grading" ]]
}

@test "grade: 支持 input 选项" {
  # 创建测试文件和自定义输入目录
  mkdir -p "$TEST_TMPDIR/custom-output"
  cp "$TEST_ASSETS_DIR/opencode-output-basic.jsonl" "$TEST_TMPDIR/custom-output/test1.jsonl"

  run "$PROJECT_ROOT/src/opencode-test.sh" grade -i "$TEST_TMPDIR/custom-output" "$TEST_TMPDIR/full.json"
  [[ $status -eq 0 ]]
}

@test "grade: 支持 model 选项" {

  run "$PROJECT_ROOT/src/opencode-test.sh" grade --model "opencode/gpt-4" -o "$TEST_TMPDIR/grading" "$TEST_TMPDIR/full.json"
  [[ $status -eq 0 ]]
}

@test "grade: 生成正确的输出文件" {
  # 创建测试文件和测试结果
  local tests_json='[{"name": "hello_world_test", "prompt": "say hello"}, {"name": "python_code_test", "prompt": "write python"}]'
  generate_test_config "[]" "[]" "[]" "$tests_json" "" "$TEST_TMPDIR/test-config.json"
  # 创建两个测试用例的输出文件（使用相同的base文件）
  cp "$TEST_ASSETS_DIR/opencode-output-basic.jsonl" "$TEST_TMPDIR/output/hello_world_test.jsonl"
  cp "$TEST_ASSETS_DIR/opencode-output-basic.jsonl" "$TEST_TMPDIR/output/python_code_test.jsonl"

  run "$PROJECT_ROOT/src/opencode-test.sh" grade -o "$TEST_TMPDIR" "$TEST_TMPDIR/test-config.json"
  [[ $status -eq 0 ]]

  # 验证输出文件存在且文件名正确
  [[ -f "$TEST_TMPDIR/grading/hello_world_test.json" ]]
  [[ -f "$TEST_TMPDIR/grading/python_code_test.json" ]]
}

@test "grade: 评分报告包含所有必需字段" {

  run "$PROJECT_ROOT/src/opencode-test.sh" grade -o "$TEST_TMPDIR" "$TEST_TMPDIR/full.json"
  [[ $status -eq 0 ]]

  # 验证输出文件包含所有必需字段
  local report_file="$TEST_TMPDIR/grading/test1.json"
  [[ -f $report_file ]]

  # 检查必需字段
  jq -e '.test_name' "$report_file" > /dev/null
  jq -e '.score' "$report_file" > /dev/null
  jq -e '.score.passed' "$report_file" > /dev/null
  jq -e '.score.failed' "$report_file" > /dev/null
  jq -e '.score.total' "$report_file" > /dev/null
  jq -e '.score.pass_rate' "$report_file" > /dev/null
  jq -e '.expectations' "$report_file" > /dev/null
  jq -e '.metrics' "$report_file" > /dev/null
  jq -e '.metrics.tokens' "$report_file" > /dev/null
  jq -e '.metrics.tokens.total' "$report_file" > /dev/null
  jq -e '.graded_at' "$report_file" > /dev/null
}

@test "grade: 正确统计定量指标" {

  run "$PROJECT_ROOT/src/opencode-test.sh" grade -o "$TEST_TMPDIR" "$TEST_TMPDIR/full.json"
  [[ $status -eq 0 ]]

  local report_file="$TEST_TMPDIR/grading/test1.json"

  # 验证 token 统计正确
  [[ $(jq '.metrics.tokens.total' "$report_file") -eq 250 ]]
  [[ $(jq '.metrics.tokens.input' "$report_file") -eq 180 ]]
  [[ $(jq '.metrics.tokens.output' "$report_file") -eq 70 ]]

  # 验证工具调用统计正确
  [[ $(jq '.metrics.tool_calls.total' "$report_file") -eq 3 ]]
  [[ $(jq '.metrics.tool_calls.by_type.Bash' "$report_file") -eq 1 ]]
  [[ $(jq '.metrics.tool_calls.by_type.Read' "$report_file") -eq 1 ]]
  [[ $(jq '.metrics.tool_calls.by_type.Write' "$report_file") -eq 1 ]]
}

@test "grade: 正确评估 expectations" {

  run "$PROJECT_ROOT/src/opencode-test.sh" grade -o "$TEST_TMPDIR" "$TEST_TMPDIR/full.json"
  [[ $status -eq 0 ]]

  local report_file="$TEST_TMPDIR/grading/test1.json"

  # 验证 expectations 数组存在且数量与测试用例中的 expectations 数量一致
  [[ $(jq '.expectations | length' "$report_file") -eq 2 ]]

  # 验证每个 expectation 都有必需的字段
  jq -e '.expectations[0].text' "$report_file" > /dev/null
  jq -e '.expectations[0].passed' "$report_file" > /dev/null
  jq -e '.expectations[0].evidence' "$report_file" > /dev/null

  # 验证评分汇总正确
  [[ $(jq '.score.total' "$report_file") -eq 2 ]]
  # passed + failed 应该等于 total
  [[ $(jq '.score.passed + .score.failed' "$report_file") -eq $(jq '.score.total' "$report_file") ]]
  # pass_rate 应该在 0 到 1 之间
  [[ $(jq '.score.pass_rate >= 0 and .score.pass_rate <= 1' "$report_file") == "true" ]]
}

# ============================================
# qualitative_assess 函数测试
# ============================================

@test "qualitative_assess: 需要 expectations 和输出文件参数" {
  # Test with missing arguments
  run qualitative_assess
  [[ $status -ne 0 ]]
}

@test "qualitative_assess: 从测试文件中提取 expectations" {
  # The function should receive expectations directly
  TEST_FILE="$TEST_TMPDIR/full.json"
  create_test_environment
  run qualitative_assess '["期望1", "期望2"]' "$TEST_TMPDIR/test1.jsonl"

  [[ $status -eq 0 ]]
}

@test "qualitative_assess: 当测试用例没有 expectations 时返回空数组" {
  # Create test file without expectations
  local tests_json='[{"name": "hello_world_test", "prompt": "say hello"}, {"name": "python_code_test", "prompt": "write python"}]'
  generate_test_config "[]" "[]" "[]" "$tests_json" "" "$TEST_TMPDIR/test.json"

  run qualitative_assess '[]' "$TEST_TMPDIR/test1.jsonl"

  [[ $status -eq 0 ]]
  [[ $output == "[]" ]]
}

@test "qualitative_assess: 当测试用例不存在时返回空数组" {
  run qualitative_assess '[]' "$TEST_TMPDIR/test1.jsonl"

  [[ $status -eq 0 ]]
  [[ $output == "[]" ]]
}

@test "qualitative_assess: 返回有效的 JSON 数组格式" {
  # Test with test environment
  TEST_FILE="$TEST_TMPDIR/full.json"
  create_test_environment
  run qualitative_assess '["期望1"]' "$TEST_TMPDIR/test1.jsonl"

  [[ $status -eq 0 ]]
  # Verify output is valid JSON array
  echo "$output" | jq -e 'if type == "array" then true else false end'
}

@test "qualitative_assess: 评估结果包含必需的字段" {
  # Test with test environment
  TEST_FILE="$TEST_TMPDIR/full.json"
  create_test_environment
  run qualitative_assess '["期望1", "期望2"]' "$TEST_TMPDIR/test1.jsonl"

  [[ $status -eq 0 ]]
  # Check that output has required fields using jq
  echo "$output" | jq -e '.[0].text'
  echo "$output" | jq -e '.[0].passed'
  echo "$output" | jq -e '.[0].evidence'
}

# ============================================
# create_test_environment 函数测试
# ============================================

@test "create_test_environment: 创建 .opencode 目录结构" {
  run init_opencode_structure "$TEST_TMPDIR"

  [[ $status -eq 0 ]]
  [[ -d "$TEST_TMPDIR/.opencode/agents" ]]
  [[ -d "$TEST_TMPDIR/.opencode/commands" ]]
  [[ -d "$TEST_TMPDIR/.opencode/skills" ]]
}

@test "create_test_environment: 创建 empty.md 和 grader.md" {
  rm "$TEST_TMPDIR/.opencode/agents/grader.md"
  _ARGS_CURRENT_SUBCOMMAND="grade"
  run init_opencode_structure "$TEST_TMPDIR" && copy_config_resources "$TEST_TMPDIR"

  [[ $status -eq 0 ]]
  [[ -f "$TEST_TMPDIR/.opencode/agents/empty.md" ]]
  [[ -f "$TEST_TMPDIR/.opencode/agents/grader.md" ]]
  # empty.md should be empty
  [[ ! -s "$TEST_TMPDIR/.opencode/agents/empty.md" ]]
  # grader.md should not be empty
  [[ -s "$TEST_TMPDIR/.opencode/agents/grader.md" ]]
}

@test "create_test_environment: 如果目录已存在则不报错" {
  mkdir -p "$TEST_TMPDIR/.opencode/agents"
  run create_test_environment "$TEST_TMPDIR"
  [[ $status -eq 0 ]]
}
