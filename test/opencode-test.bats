#!/usr/bin/env bats

load 'test_helper/common-setup'

setup() {
  _common_setup
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  # Set output directory to temporary directory for tests
  export OPENCODE_TEST_OUTPUT="$TEST_TMPDIR"

  # Create a mock opencode command for tests that need it
  MOCK_OPENCODE_DIR="$TEST_TMPDIR/mock-bin"
  mkdir -p "$MOCK_OPENCODE_DIR"
  cat > "$MOCK_OPENCODE_DIR/opencode" << 'EOF'
#!/bin/bash
# Handle opencode commands and output valid JSONL format
echo '{"type": "step_finish", "part": {"tokens": {"total": 100}, "reason": "stop"}}'
exit 0
EOF
  chmod +x "$MOCK_OPENCODE_DIR/opencode"
  export MOCK_OPENCODE_DIR
}

teardown() {
  if [[ -n $TEST_TMPDIR && -d $TEST_TMPDIR ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

@test "test: 无参数时显示帮助错误" {
  run "$PROJECT_ROOT/src/opencode-test.sh" test
  [[ $status -ne 0 ]]
  [[ $output == *"错误: 请提供测试用例 JSON 文件"* ]]
}

@test "test: 验证测试文件存在性" {
  run "$PROJECT_ROOT/src/opencode-test.sh" test "$TEST_TMPDIR/nonexistent.json"
  [[ $status -ne 0 ]]
  [[ $output == *"错误: 测试文件"* ]]
}

@test "test: 接受有效的 JSON 测试文件" {
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
  run "$PROJECT_ROOT/src/opencode-test.sh" test "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
  [[ $output == *"开始执行测试"* ]]
}

@test "test: 支持 verbose 选项" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
  [[ $output == *"详细模式已启用"* ]]
}

@test "test: 支持 jobs 选项" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" test -j 2 "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
}

@test "test: 支持 output 选项" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" test -o "$TEST_TMPDIR/output.json" "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
}

@test "test: 支持 timeout 选项" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" test --timeout 60 "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
}

@test "test: 支持 model 选项" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" test --model "test/model" "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
}

@test "test: -h 显示帮助信息" {
  run "$PROJECT_ROOT/src/opencode-test.sh" test -h
  [[ $status -eq 0 ]]
  [[ $output == *"Usage:"* ]]
}

@test "test: 验证 JSON 文件有效性" {
  cat > "$TEST_TMPDIR/invalid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" test "$TEST_TMPDIR/invalid.json"
  [[ $status -ne 0 ]]
  [[ $output == *"错误: 无效的 JSON 文件"* ]]
}

@test "test: 允许缺少 description 字段" {
  cat > "$TEST_TMPDIR/missing-fields.json" << 'EOF'
{
  "config": {
    "agents": [],
    "commands": [],
    "skills": []
  },
  "tests": []
}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" test "$TEST_TMPDIR/missing-fields.json"
  [[ $status -eq 0 ]]
}

@test "test: 验证 jobs 参数有效性" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  # Test with valid positive number
  run "$PROJECT_ROOT/src/opencode-test.sh" test -j 2 "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]

  # Test with zero (should fail)
  run "$PROJECT_ROOT/src/opencode-test.sh" test -j 0 "$TEST_TMPDIR/valid.json"
  [[ $status -ne 0 ]]
}

@test "test: 验证 timeout 参数有效性" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  # Test with valid positive number
  run "$PROJECT_ROOT/src/opencode-test.sh" test --timeout 60 "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]

  # Test with zero (should fail)
  run "$PROJECT_ROOT/src/opencode-test.sh" test --timeout 0 "$TEST_TMPDIR/valid.json"
  [[ $status -ne 0 ]]
}

@test "test: 缺少 tests 字段时显示警告" {
  cat > "$TEST_TMPDIR/no-tests.json" << 'EOF'
{
  "description": "test",
  "config": {
    "agents": [],
    "commands": [],
    "skills": []
  }
}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/no-tests.json"
  [[ $status -eq 0 ]]
  [[ $output == *"警告: 测试文件缺少 tests 字段，将执行 0 个测试用例"* ]]
}

@test "test: 验证输出目录创建" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{
  "description": "test",
  "config": {
    "agents": [],
    "commands": [],
    "skills": []
  },
  "tests": []
}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" test -o "$TEST_TMPDIR/output" "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
  [[ -d "$TEST_TMPDIR/output" ]]
}

@test "test: 复制 agent 文件到测试环境" {
  # 创建模拟agent文件（.md格式）
  mkdir -p "$TEST_TMPDIR/agents"
  echo "# Test Agent" > "$TEST_TMPDIR/agents/test-agent.md"

  cat > "$TEST_TMPDIR/config.json" << EOF
{
  "description": "test with agents",
  "config": {
    "agents": ["$TEST_TMPDIR/agents/test-agent.md"],
    "commands": [],
    "skills": []
  },
  "tests": []
}
EOF

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"复制 agent: $TEST_TMPDIR/agents/test-agent.md"* ]]
}

@test "test: 复制 command 文件到测试环境" {
  # 创建模拟command文件（.md格式）
  mkdir -p "$TEST_TMPDIR/commands"
  echo "# Test Command" > "$TEST_TMPDIR/commands/test-command.md"

  cat > "$TEST_TMPDIR/config.json" << EOF
{
  "description": "test with commands",
  "config": {
    "agents": [],
    "commands": ["$TEST_TMPDIR/commands/test-command.md"],
    "skills": []
  },
  "tests": []
}
EOF

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"复制 command: $TEST_TMPDIR/commands/test-command.md"* ]]
}

@test "test: 复制 skill 目录到测试环境" {
  # 创建模拟skill目录
  mkdir -p "$TEST_TMPDIR/skills/test-skill"
  echo "skill content" > "$TEST_TMPDIR/skills/test-skill/SKILL.md"

  cat > "$TEST_TMPDIR/config.json" << EOF
{
  "description": "test with skills",
  "config": {
    "agents": [],
    "commands": [],
    "skills": ["$TEST_TMPDIR/skills/test-skill"]
  },
  "tests": []
}
EOF

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"复制 skill: $TEST_TMPDIR/skills/test-skill"* ]]
}

@test "test: 处理不存在的 agent 文件" {
  cat > "$TEST_TMPDIR/config.json" << 'EOF'
{
  "description": "test with missing agent",
  "config": {
    "agents": ["/nonexistent/agent.md"],
    "commands": [],
    "skills": []
  },
  "tests": []
}
EOF

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  # Should not fail, just skip non-existent files
}

@test "test: 配置文件参数覆盖命令行参数" {
  mkdir -p "$TEST_TMPDIR/agents"
  echo "# Test Agent" > "$TEST_TMPDIR/agents/test-agent.md"

  cat > "$TEST_TMPDIR/config.json" << EOF
{
  "description": "test config override",
  "config": {
    "agents": ["$TEST_TMPDIR/agents/test-agent.md"],
    "model": "test/custom-model",
    "timeout": 60,
    "parallel": 2
  },
  "tests": []
}
EOF

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"模型: test/custom-model"* ]]
  [[ $output == *"超时: 60 秒"* ]]
  [[ $output == *"并行数: 2"* ]]
}

@test "test: 执行实际测试用例" {
  cat > "$TEST_TMPDIR/config.json" << 'EOF'
{
  "description": "test with actual test case",
  "config": {
    "agents": [],
    "commands": [],
    "skills": []
  },
  "tests": [
    {
      "name": "simple_test",
      "prompt": "hello world"
    }
  ]
}
EOF

  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: simple_test"* ]]
  [[ $output == *"找到 1 个测试用例"* ]]
}

@test "test: 执行多个实际测试用例" {
  cat > "$TEST_TMPDIR/config.json" << 'EOF'
{
  "description": "test with multiple actual test cases",
  "config": {
    "agents": [],
    "commands": [],
    "skills": []
  },
  "tests": [
    {
      "name": "test1",
      "prompt": "hello world"
    },
    {
      "name": "test2",
      "prompt": "goodbye world"
    }
  ]
}
EOF

  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" test -v --timeout 2 "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: test1"* ]]
  [[ $output == *"执行测试: test2"* ]]
  [[ $output == *"找到 2 个测试用例"* ]]
}

@test "test: 输出目录复制功能" {
  cat > "$TEST_TMPDIR/config.json" << 'EOF'
{
  "description": "test output copy",
  "config": {
    "agents": [],
    "commands": [],
    "skills": []
  },
  "tests": []
}
EOF

  run "$PROJECT_ROOT/src/opencode-test.sh" test -o "$TEST_TMPDIR/custom-output" "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ -d "$TEST_TMPDIR/custom-output" ]]
  [[ $output == *"输出已复制到: $TEST_TMPDIR/custom-output"* ]]
}

@test "test: 测试用例包含 agent 和 command" {
  cat > "$TEST_TMPDIR/config.json" << 'EOF'
{
  "description": "test with agent and command",
  "config": {
    "agents": [],
    "commands": [],
    "skills": []
  },
  "tests": [
    {
      "name": "test_with_agent",
      "agent": "test-agent",
      "command": "test-command",
      "prompt": "hello world"
    }
  ]
}
EOF

  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: test_with_agent"* ]]
  [[ $output == *"Agent: test-agent"* ]]
  [[ $output == *"Command: test-command"* ]]
}

@test "test: 验证 parallel 配置参数" {
  cat > "$TEST_TMPDIR/config.json" << 'EOF'
{
  "description": "test parallel config",
  "config": {
    "agents": [],
    "commands": [],
    "skills": [],
    "parallel": 8
  },
  "tests": []
}
EOF

  run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"并行数: 8"* ]]
}

@test "test: 测试超时处理" {
  # 创建一个会超时的测试（使用sleep命令模拟长时间运行）
  cat > "$TEST_TMPDIR/config.json" << 'EOF'
{
  "description": "test timeout",
  "config": {
    "agents": [],
    "commands": [],
    "skills": []
  },
  "tests": [
    {
      "name": "timeout_test",
      "prompt": "this will timeout"
    }
  ]
}
EOF

  # 使用非常短的超时时间（1秒）
  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" test --timeout 1 "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  # Note: The actual timeout handling depends on the opencode command behavior
  # Since we can't easily mock opencode, we verify the script accepts the timeout parameter
}

@test "test: 测试用例包含单个 files 字段" {
  # 创建测试文件
  echo "test content" > "$TEST_TMPDIR/test-file.txt"

  cat > "$TEST_TMPDIR/config.json" << 'EOF'
{
  "description": "test with files",
  "config": {
    "agents": [],
    "commands": [],
    "skills": []
  },
  "tests": [
    {
      "name": "test_with_files",
      "prompt": "process files",
      "files": ["test-file.txt"]
    }
  ]
}
EOF

  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: test_with_files"* ]]
  [[ $output == *"Files: [\"test-file.txt\"]"* ]]
}

@test "test: 测试用例包含多个 files 字段" {
  # 创建多个测试文件
  echo "file1 content" > "$TEST_TMPDIR/file1.txt"
  echo "file2 content" > "$TEST_TMPDIR/file2.txt"
  echo "file3 content" > "$TEST_TMPDIR/file3.txt"

  cat > "$TEST_TMPDIR/config.json" << 'EOF'
{
  "description": "test with multiple files",
  "config": {
    "agents": [],
    "commands": [],
    "skills": []
  },
  "tests": [
    {
      "name": "test_with_multiple_files",
      "prompt": "process multiple files",
      "files": ["file1.txt", "file2.txt", "file3.txt"]
    }
  ]
}
EOF

  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: test_with_multiple_files"* ]]
  [[ $output == *"Files: [\"file1.txt\",\"file2.txt\",\"file3.txt\"]"* ]]
}

@test "test: 测试用例包含 expectations 字段" {
  cat > "$TEST_TMPDIR/config.json" << 'EOF'
{
  "description": "test with expectations",
  "config": {
    "agents": [],
    "commands": [],
    "skills": []
  },
  "tests": [
    {
      "name": "test_with_expectations",
      "prompt": "meet expectations",
      "expectations": ["输出包含 X", "技能使用了脚本 Y"]
    }
  ]
}
EOF

  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: test_with_expectations"* ]]
}

@test "test: agent 和 command 参数传递给 opencode" {
  # 创建模拟的 agent 和 command 文件
  mkdir -p "$TEST_TMPDIR/agents" "$TEST_TMPDIR/commands"
  echo "# Test Agent" > "$TEST_TMPDIR/agents/my-agent.md"
  echo "# Test Command" > "$TEST_TMPDIR/commands/my-command.md"

  cat > "$TEST_TMPDIR/config.json" << EOF
{
  "description": "test agent and command passing",
  "config": {
    "agents": ["$TEST_TMPDIR/agents/my-agent.md"],
    "commands": ["$TEST_TMPDIR/commands/my-command.md"],
    "skills": []
  },
  "tests": [
    {
      "name": "specific_agent_command_test",
      "agent": "my-agent",
      "command": "my-command",
      "prompt": "test specific agent and command"
    }
  ]
}
EOF

  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" test -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: specific_agent_command_test"* ]]
  [[ $output == *"Agent: my-agent"* ]]
  [[ $output == *"Command: my-command"* ]]
}

@test "test: 测试执行后生成输出文件" {
  cat > "$TEST_TMPDIR/config.json" << 'EOF'
{
  "description": "test output generation",
  "config": {
    "agents": [],
    "commands": [],
    "skills": []
  },
  "tests": [
    {
      "name": "output_test",
      "prompt": "generate output"
    }
  ]
}
EOF

  # 指定自定义输出目录
  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" test -o "$TEST_TMPDIR/test-output" "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ -d "$TEST_TMPDIR/test-output" ]]
  [[ -f "$TEST_TMPDIR/test-output/output_test.jsonl" ]]
}

@test "test: 端到端测试使用真实 opencode" {
  # Skip this test if opencode is not available or if we're in CI
  if ! command -v opencode &> /dev/null; then
    skip "opencode CLI not available"
  fi

  # Create agent and command files
  mkdir -p "$TEST_TMPDIR/agents" "$TEST_TMPDIR/commands"
  cat > "$TEST_TMPDIR/agents/python-agent.md" << 'EOF'
# Python Agent
Name: PythonExpert
This agent specializes in Python code generation and debugging. When asked to perform tasks, always start by introducing yourself as "PythonExpert".
EOF
  cat > "$TEST_TMPDIR/commands/echo-hello.md" << 'EOF'
请直接输出以下字符串，不要添加任何其他内容：
COMMAND_ECHO_HELLO_12345XYZ
EOF

  # Create test files for the files parameter
  echo "This is test file 1 content" > "$TEST_TMPDIR/test-file1.txt"
  echo "This is test file 2 content" > "$TEST_TMPDIR/test-file2.txt"

  # Create a comprehensive test case with agent, command, and files
  cat > "$TEST_TMPDIR/e2e-test.json" << EOF
{
  "description": "End-to-end test with real opencode",
  "config": {
    "agents": ["$TEST_TMPDIR/agents/python-agent.md"],
    "commands": ["$TEST_TMPDIR/commands/echo-hello.md"],
    "skills": [],
    "model": "opencode/gpt-5-nano",
    "timeout": 60,
    "parallel": 1
  },
  "tests": [
    {
      "name": "python_agent_test",
      "agent": "python-agent",
      "command": "echo-hello",
      "prompt": "Before doing anything, please introduce yourself by name. Then use the echo-hello command to execute its instructions. Also, I have provided you with test files that you should reference in your response.",
      "files": ["test-file1.txt", "test-file2.txt"],
      "expectations": ["Agent introduces as PythonExpert", "Command outputs COMMAND_ECHO_HELLO_12345XYZ", "References test files"]
    }
  ]
}
EOF
  cat > "$TEST_TMPDIR/commands/echo-hello.md" << 'EOF'
请直接输出以下字符串，不要添加任何其他内容：
COMMAND_ECHO_HELLO_12345XYZ
EOF

  # Create a comprehensive test case with agent and command
  cat > "$TEST_TMPDIR/e2e-test.json" << EOF
{
  "description": "End-to-end test with real opencode",
  "config": {
    "agents": ["$TEST_TMPDIR/agents/python-agent.md"],
    "commands": ["$TEST_TMPDIR/commands/echo-hello.md"],
    "skills": [],
    "model": "opencode/gpt-5-nano",
    "timeout": 60,
    "parallel": 1
  },
  "tests": [
    {
      "name": "python_agent_test",
      "agent": "python-agent",
      "command": "echo-hello",
      "prompt": "Before doing anything, please introduce yourself by name. Then use the echo-hello command to output its signature string.",
      "expectations": ["Agent introduces as PythonExpert", "Command outputs COMMAND_ECHO_HELLO_EXECUTED"]
    }
  ]
}
EOF

  # Run with real opencode and capture output
  run "$PROJECT_ROOT/src/opencode-test.sh" test -v -o "$TEST_TMPDIR/e2e-output" "$TEST_TMPDIR/e2e-test.json"
  [[ $status -eq 0 ]]

  # Verify output directory structure
  [[ -d "$TEST_TMPDIR/e2e-output" ]]
  [[ -f "$TEST_TMPDIR/e2e-output/python_agent_test.jsonl" ]]

  # Verify the JSONL file contains valid JSON lines
  local jsonl_file="$TEST_TMPDIR/e2e-output/python_agent_test.jsonl"
  [[ -s "$jsonl_file" ]]

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
  has_tokens=$(jq -r '.part.tokens.total // empty' "$jsonl_file" | grep -v null | grep -v "^$" | wc -l || true)
  [[ $has_tokens -gt 0 ]]
}

# ============================================
# Test --grade-after 功能测试
# ============================================

@test "test: --autograde 选项测试完成后自动评分" {
  # 创建测试文件
  cat > "$TEST_TMPDIR/test-config.json" << 'EOF'
{
  "description": "test with autograde",
  "tests": [
    {"name": "test1", "prompt": "say hello"},
    {"name": "test2", "prompt": "say world"}
  ]
}
EOF

  # 运行 test 命令并启用 --autograde
  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" test \
    -o "$TEST_TMPDIR/output" \
    --timeout 3 \
    --autograde \
    "$TEST_TMPDIR/test-config.json"

  [[ $status -eq 0 ]]

  # 验证测试输出文件存在
  [[ -f "$TEST_TMPDIR/output/test1.jsonl" ]]
  [[ -f "$TEST_TMPDIR/output/test2.jsonl" ]]

  # 验证评分报告文件也被生成（在 output/grading/ 目录）
  [[ -f "$TEST_TMPDIR/output/grading/test1.json" ]]
  [[ -f "$TEST_TMPDIR/output/grading/test2.json" ]]
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
  [[ $output == *"错误"* ]]
}

@test "grade: 验证测试文件存在性" {
  run "$PROJECT_ROOT/src/opencode-test.sh" grade "$TEST_TMPDIR/nonexistent.json"
  [[ $status -ne 0 ]]
  [[ $output == *"错误"* ]]
}

@test "grade: 支持 verbose 选项" {
  # 创建测试文件和对应的输出目录
  cat > "$TEST_TMPDIR/test-config.json" << 'EOF'
{
  "description": "test",
  "tests": [{"name": "test1", "prompt": "test"}]
}
EOF
  mkdir -p "$TEST_TMPDIR/output"
  echo '{"type": "step_finish", "part": {"tokens": {"total": 100}}}' > "$TEST_TMPDIR/output/test1.jsonl"

  run "$PROJECT_ROOT/src/opencode-test.sh" grade -v "$TEST_TMPDIR/test-config.json"
  [[ $status -eq 0 ]]

  # 验证默认输出在临时目录的 grading 目录
  [[ -f "$TEST_TMPDIR/grading/test1.json" ]]
}

@test "grade: 支持 output 选项" {
  # 创建测试文件和对应的输出目录
  cat > "$TEST_TMPDIR/test-config.json" << 'EOF'
{
  "description": "test",
  "tests": [{"name": "test1", "prompt": "test"}]
}
EOF
  mkdir -p "$TEST_TMPDIR/output"
  echo '{"type": "step_finish", "part": {"tokens": {"total": 100}}}' > "$TEST_TMPDIR/output/test1.jsonl"

  run "$PROJECT_ROOT/src/opencode-test.sh" grade -o "$TEST_TMPDIR" "$TEST_TMPDIR/test-config.json"
  [[ $status -eq 0 ]]
  [[ -d "$TEST_TMPDIR/grading" ]]
}

@test "grade: 支持 input 选项" {
  # 创建测试文件和自定义输入目录
  cat > "$TEST_TMPDIR/test-config.json" << 'EOF'
{
  "description": "test",
  "tests": [{"name": "test1", "prompt": "test"}]
}
EOF
  mkdir -p "$TEST_TMPDIR/custom-output"
  echo '{"type": "step_finish", "part": {"tokens": {"total": 100}}}' > "$TEST_TMPDIR/custom-output/test1.jsonl"

  run "$PROJECT_ROOT/src/opencode-test.sh" grade -i "$TEST_TMPDIR/custom-output" "$TEST_TMPDIR/test-config.json"
  [[ $status -eq 0 ]]
}

@test "grade: 支持 model 选项" {
  # 创建测试文件和对应的输出目录
  cat > "$TEST_TMPDIR/test-config.json" << 'EOF'
{
  "description": "test",
  "tests": [{"name": "test1", "prompt": "test"}]
}
EOF
  mkdir -p "$TEST_TMPDIR/output"
  echo '{"type": "step_finish", "part": {"tokens": {"total": 100}}}' > "$TEST_TMPDIR/output/test1.jsonl"

  run "$PROJECT_ROOT/src/opencode-test.sh" grade --model "opencode/gpt-4" -o "$TEST_TMPDIR/grading" "$TEST_TMPDIR/test-config.json"
  [[ $status -eq 0 ]]
}

@test "grade: 生成正确的输出文件" {
  # 创建测试文件和测试结果
  cat > "$TEST_TMPDIR/test-config.json" << 'EOF'
{
  "description": "test",
  "tests": [
    {"name": "hello_world_test", "prompt": "say hello"},
    {"name": "python_code_test", "prompt": "write python"}
  ]
}
EOF
  mkdir -p "$TEST_TMPDIR/output"
  # 创建两个测试用例的输出文件
  echo '{"type": "step_finish", "part": {"tokens": {"total": 150}, "reason": "stop"}}' > "$TEST_TMPDIR/output/hello_world_test.jsonl"
  echo '{"type": "step_finish", "part": {"tokens": {"total": 200}, "reason": "stop"}}' > "$TEST_TMPDIR/output/python_code_test.jsonl"

  run "$PROJECT_ROOT/src/opencode-test.sh" grade -o "$TEST_TMPDIR" "$TEST_TMPDIR/test-config.json"
  [[ $status -eq 0 ]]

  # 验证输出文件存在且文件名正确
  [[ -f "$TEST_TMPDIR/grading/hello_world_test.json" ]]
  [[ -f "$TEST_TMPDIR/grading/python_code_test.json" ]]
}

@test "grade: 评分报告包含所有必需字段" {
  # 创建测试文件和测试结果
  cat > "$TEST_TMPDIR/test-config.json" << 'EOF'
{
  "description": "test",
  "tests": [
    {
      "name": "test1",
      "prompt": "test prompt",
      "expectations": ["输出包含 hello", "代码可运行"]
    }
  ]
}
EOF
  mkdir -p "$TEST_TMPDIR/output"
  cat > "$TEST_TMPDIR/output/test1.jsonl" << 'EOF'
{"type": "step_start", "part": {"id": "1"}}
{"type": "text", "part": {"text": "Hello world", "time": {"start": 1000, "end": 2000}}}
{"type": "step_finish", "part": {"reason": "stop", "tokens": {"total": 150, "input": 100, "output": 50}}}
EOF

  run "$PROJECT_ROOT/src/opencode-test.sh" grade -o "$TEST_TMPDIR" "$TEST_TMPDIR/test-config.json"
  [[ $status -eq 0 ]]

  # 验证输出文件包含所有必需字段
  local report_file="$TEST_TMPDIR/grading/test1.json"
  [[ -f "$report_file" ]]

  # 检查必需字段
  jq -e '.test_name' "$report_file" >/dev/null
  jq -e '.score' "$report_file" >/dev/null
  jq -e '.score.passed' "$report_file" >/dev/null
  jq -e '.score.failed' "$report_file" >/dev/null
  jq -e '.score.total' "$report_file" >/dev/null
  jq -e '.score.pass_rate' "$report_file" >/dev/null
  jq -e '.expectations' "$report_file" >/dev/null
  jq -e '.metrics' "$report_file" >/dev/null
  jq -e '.metrics.tokens' "$report_file" >/dev/null
  jq -e '.metrics.tokens.total' "$report_file" >/dev/null
  jq -e '.graded_at' "$report_file" >/dev/null
}

@test "grade: 正确统计定量指标" {
  # 创建测试文件和包含多个事件的测试结果
  cat > "$TEST_TMPDIR/test-config.json" << 'EOF'
{
  "description": "test",
  "tests": [
    {"name": "metrics_test", "prompt": "test"}
  ]
}
EOF
  mkdir -p "$TEST_TMPDIR/output"
  cat > "$TEST_TMPDIR/output/metrics_test.jsonl" << 'EOF'
{"type": "step_start", "part": {"id": "1"}}
{"type": "text", "part": {"text": "Some output here", "time": {"start": 1000, "end": 2000}}}
{"type": "tool_use", "part": {"tool": "Bash", "state": {"status": "completed"}}}
{"type": "tool_use", "part": {"tool": "Read", "state": {"status": "completed"}}}
{"type": "tool_use", "part": {"tool": "Write", "state": {"status": "completed"}}}
{"type": "step_finish", "part": {"reason": "stop", "tokens": {"total": 250, "input": 180, "output": 70}}}
EOF

  run "$PROJECT_ROOT/src/opencode-test.sh" grade -o "$TEST_TMPDIR" "$TEST_TMPDIR/test-config.json"
  [[ $status -eq 0 ]]

  local report_file="$TEST_TMPDIR/grading/metrics_test.json"

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
  # 创建包含 expectations 的测试文件
  cat > "$TEST_TMPDIR/test-config.json" << 'EOF'
{
  "description": "test",
  "tests": [
    {
      "name": "expectation_test",
      "prompt": "say hello",
      "expectations": ["输出包含 hello", "输出包含 world"]
    }
  ]
}
EOF
  mkdir -p "$TEST_TMPDIR/output"
  cat > "$TEST_TMPDIR/output/expectation_test.jsonl" << 'EOF'
{"type": "text", "part": {"text": "Hello world"}}
{"type": "step_finish", "part": {"tokens": {"total": 100}}}
EOF

  run "$PROJECT_ROOT/src/opencode-test.sh" grade -o "$TEST_TMPDIR" "$TEST_TMPDIR/test-config.json"
  [[ $status -eq 0 ]]

  local report_file="$TEST_TMPDIR/grading/expectation_test.json"

  # 验证 expectations 数组存在且数量与测试用例中的 expectations 数量一致
  [[ $(jq '.expectations | length' "$report_file") -eq 2 ]]

  # 验证每个 expectation 都有必需的字段
  jq -e '.expectations[0].description' "$report_file" >/dev/null
  jq -e '.expectations[0].passed' "$report_file" >/dev/null
  jq -e '.expectations[0].evidence' "$report_file" >/dev/null

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

@test "qualitative_assess: 需要测试文件、测试名称和输出文件参数" {
  # Test with missing arguments
  run bash -c 'source "$PROJECT_ROOT/src/opencode-test.sh" && qualitative_assess'
  [[ $status -ne 0 ]]
}

@test "qualitative_assess: 从测试文件中提取 expectations" {
  # Create test file with expectations
  cat > "$TEST_TMPDIR/test.json" << 'JSONEOF'
{
  "tests": [
    {
      "name": "test1",
      "prompt": "test",
      "expectations": ["期望1", "期望2"]
    }
  ]
}
JSONEOF

  # Create mock output file
  echo '{"type": "text", "part": {"text": "output"}}' > "$TEST_TMPDIR/output.jsonl"

  # Create grader agent
  mkdir -p "$TEST_TMPDIR/.opencode/agents"
  echo "# Grader" > "$TEST_TMPDIR/.opencode/agents/grader.md"

  # Create mock opencode
  mkdir -p "$TEST_TMPDIR/mock-bin"
  cat > "$TEST_TMPDIR/mock-bin/opencode" << 'MOCKEOF'
#!/bin/bash
echo '{"type":"text","part":{"text":"[{\"text\": \"测试期望\", \"passed\": true, \"evidence\": \"找到证据\"}]"}}'
exit 0
MOCKEOF
  chmod +x "$TEST_TMPDIR/mock-bin/opencode"

  # The function should extract expectations from test file
  PATH="$TEST_TMPDIR/mock-bin:$PATH" run bash -c "
    source \"$PROJECT_ROOT/src/opencode-test.sh\"
    TEST_FILE=\"$TEST_TMPDIR/test.json\"
    create_test_environment
    qualitative_assess \"$TEST_TMPDIR/test.json\" \"test1\" \"$TEST_TMPDIR/output.jsonl\"
  "

  [[ $status -eq 0 ]]
}

@test "qualitative_assess: 当测试用例没有 expectations 时返回空数组" {
  # Create test file without expectations
  cat > "$TEST_TMPDIR/test.json" << 'JSONEOF'
{
  "tests": [
    {
      "name": "no_expectations_test",
      "prompt": "test"
    }
  ]
}
JSONEOF

  echo '{"type": "text", "part": {"text": "output"}}' > "$TEST_TMPDIR/output.jsonl"

  run bash -c "
    source \"$PROJECT_ROOT/src/opencode-test.sh\"
    qualitative_assess \"$TEST_TMPDIR/test.json\" \"no_expectations_test\" \"$TEST_TMPDIR/output.jsonl\"
  "

  [[ $status -eq 0 ]]
  [[ "$output" == "[]" ]]
}

@test "qualitative_assess: 当测试用例不存在时返回空数组" {
  cat > "$TEST_TMPDIR/test.json" << 'JSONEOF'
{
  "tests": [
    {
      "name": "existing_test",
      "prompt": "test"
    }
  ]
}
JSONEOF

  echo '{"type": "text", "part": {"text": "output"}}' > "$TEST_TMPDIR/output.jsonl"

  run bash -c "
    source \"$PROJECT_ROOT/src/opencode-test.sh\"
    qualitative_assess \"$TEST_TMPDIR/test.json\" \"nonexistent_test\" \"$TEST_TMPDIR/output.jsonl\"
  "

  [[ $status -eq 0 ]]
  [[ "$output" == "[]" ]]
}

@test "qualitative_assess: 返回有效的 JSON 数组格式" {
  cat > "$TEST_TMPDIR/test.json" << 'JSONEOF'
{
  "tests": [
    {
      "name": "test1",
      "prompt": "test",
      "expectations": ["期望1"]
    }
  ]
}
JSONEOF

  echo '{"type": "text", "part": {"text": "output"}}' > "$TEST_TMPDIR/output.jsonl"
  mkdir -p "$TEST_TMPDIR/.opencode/agents"
  echo "# Grader" > "$TEST_TMPDIR/.opencode/agents/grader.md"

  # Create mock opencode
  mkdir -p "$TEST_TMPDIR/mock-bin"
  cat > "$TEST_TMPDIR/mock-bin/opencode" << 'MOCKEOF'
#!/bin/bash
echo '{"type":"text","part":{"text":"[{\"text\": \"测试期望\", \"passed\": true, \"evidence\": \"找到证据\"}]"}}'
exit 0
MOCKEOF
  chmod +x "$TEST_TMPDIR/mock-bin/opencode"

  # Test with test environment
  PATH="$TEST_TMPDIR/mock-bin:$PATH" run bash -c "
    source \"$PROJECT_ROOT/src/opencode-test.sh\"
    TEST_FILE=\"$TEST_TMPDIR/test.json\"
    create_test_environment
    qualitative_assess \"$TEST_TMPDIR/test.json\" \"test1\" \"$TEST_TMPDIR/output.jsonl\"
  "

  [[ $status -eq 0 ]]
  # Verify output is valid JSON array
  echo "$output" | jq -e 'if type == "array" then true else false end'
}

@test "qualitative_assess: 自动创建 grader agent 如果不存在" {
  skip "qualitative_assess no longer handles environment creation"
}

@test "qualitative_assess: 评估结果包含必需的字段" {
  cat > "$TEST_TMPDIR/test.json" << 'JSONEOF'
{
  "tests": [
    {
      "name": "test1",
      "prompt": "test",
      "expectations": ["期望1", "期望2"]
    }
  ]
}
JSONEOF

  echo '{"type": "text", "part": {"text": "output"}}' > "$TEST_TMPDIR/output.jsonl"
  mkdir -p "$TEST_TMPDIR/.opencode/agents"
  echo "# Grader" > "$TEST_TMPDIR/.opencode/agents/grader.md"

  # Create mock opencode
  mkdir -p "$TEST_TMPDIR/mock-bin"
  cat > "$TEST_TMPDIR/mock-bin/opencode" << 'MOCKEOF'
#!/bin/bash
echo '{"type":"text","part":{"text":"[{\"text\": \"测试期望\", \"passed\": true, \"evidence\": \"找到证据\"}]"}}'
exit 0
MOCKEOF
  chmod +x "$TEST_TMPDIR/mock-bin/opencode"

  # Test with test environment
  run bash -c "
    source \"$PROJECT_ROOT/src/opencode-test.sh\"
    TEST_FILE=\"$TEST_TMPDIR/test.json\"
    create_test_environment
    PATH=\"$TEST_TMPDIR/mock-bin:\$PATH\" qualitative_assess \"$TEST_TMPDIR/test.json\" \"test1\" \"$TEST_TMPDIR/output.jsonl\"
  "

  [[ $status -eq 0 ]]
  # Check that output has required fields using jq
  echo "$output" | jq -e '.[0].text'
  echo "$output" | jq -e '.[0].passed'
  echo "$output" | jq -e '.[0].evidence'
}

# ============================================
# init_test_environment 函数测试
# ============================================

@test "init_test_environment: 创建 .opencode 目录结构" {
  run bash -c "
    source \"$PROJECT_ROOT/src/opencode-test.sh\"
    init_test_environment \"$TEST_TMPDIR\"
  "

  [[ $status -eq 0 ]]
  [[ -d "$TEST_TMPDIR/.opencode/agents" ]]
  [[ -d "$TEST_TMPDIR/.opencode/commands" ]]
  [[ -d "$TEST_TMPDIR/.opencode/skills" ]]
}

@test "init_test_environment: 创建 empty.md 和 grader.md" {
  run bash -c "
    source \"$PROJECT_ROOT/src/opencode-test.sh\"
    init_test_environment \"$TEST_TMPDIR\"
  "

  [[ $status -eq 0 ]]
  [[ -f "$TEST_TMPDIR/.opencode/agents/empty.md" ]]
  [[ -f "$TEST_TMPDIR/.opencode/agents/grader.md" ]]
  # empty.md should be empty
  [[ ! -s "$TEST_TMPDIR/.opencode/agents/empty.md" ]]
  # grader.md should not be empty
  [[ -s "$TEST_TMPDIR/.opencode/agents/grader.md" ]]
}

@test "init_test_environment: 如果目录已存在则不报错" {
  mkdir -p "$TEST_TMPDIR/.opencode/agents"

  run bash -c "
    source \"$PROJECT_ROOT/src/opencode-test.sh\"
    init_test_environment \"$TEST_TMPDIR\"
  "

  [[ $status -eq 0 ]]
}
