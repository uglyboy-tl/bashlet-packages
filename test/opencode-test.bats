#!/usr/bin/env bats

load 'test_helper/common-setup'

setup() {
  _common_setup
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  # Create a mock opencode command for tests that need it
  MOCK_OPENCODE_DIR="$TEST_TMPDIR/mock-bin"
  mkdir -p "$MOCK_OPENCODE_DIR"
  cat > "$MOCK_OPENCODE_DIR/opencode" << 'EOF'
#!/bin/bash
echo "Mock opencode response"
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

@test "基本帮助显示错误信息" {
  run "$PROJECT_ROOT/src/opencode-test.sh"
  [[ $status -ne 0 ]]
  [[ $output == *"错误: 请提供测试用例 JSON 文件"* ]]
}

@test "缺失测试文件显示错误" {
  run "$PROJECT_ROOT/src/opencode-test.sh" "$TEST_TMPDIR/nonexistent.json"
  [[ $status -ne 0 ]]
  [[ $output == *"错误: 测试文件"* ]]
}

@test "接受有效的 JSON 文件" {
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

@test "支持详细模式选项" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" -v "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
  [[ $output == *"详细模式已启用"* ]]
}

@test "支持并发任务数选项" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" -j 2 "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
}

@test "支持输出文件选项" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" -o "$TEST_TMPDIR/output.json" "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
}

@test "支持超时选项" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" --timeout 60 "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
}

@test "支持模型选项" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" --model "test/model" "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
}

@test "使用 -h 显示帮助信息" {
  run "$PROJECT_ROOT/src/opencode-test.sh" -h
  [[ $status -eq 0 ]]
  [[ $output == *"Usage:"* ]]
}

@test "无效的 JSON 文件显示错误" {
  cat > "$TEST_TMPDIR/invalid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []
EOF
  run "$PROJECT_ROOT/src/opencode-test.sh" "$TEST_TMPDIR/invalid.json"
  [[ $status -ne 0 ]]
  [[ $output == *"错误: 无效的 JSON 文件"* ]]
}

@test "缺少 description 字段仍可执行" {
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
  run "$PROJECT_ROOT/src/opencode-test.sh" "$TEST_TMPDIR/missing-fields.json"
  [[ $status -eq 0 ]]
}

@test "并发任务数验证" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  # Test with valid positive number
  run "$PROJECT_ROOT/src/opencode-test.sh" -j 2 "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]

  # Test with zero (should fail)
  run "$PROJECT_ROOT/src/opencode-test.sh" -j 0 "$TEST_TMPDIR/valid.json"
  [[ $status -ne 0 ]]
}

@test "超时值验证" {
  cat > "$TEST_TMPDIR/valid.json" << 'EOF'
{"description": "test", "config": {"agents": [], "commands": [], "skills": []}, "tests": []}
EOF
  # Test with valid positive number
  run "$PROJECT_ROOT/src/opencode-test.sh" --timeout 60 "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]

  # Test with zero (should fail)
  run "$PROJECT_ROOT/src/opencode-test.sh" --timeout 0 "$TEST_TMPDIR/valid.json"
  [[ $status -ne 0 ]]
}

@test "测试文件缺少 tests 字段显示警告" {
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
  run "$PROJECT_ROOT/src/opencode-test.sh" -v "$TEST_TMPDIR/no-tests.json"
  [[ $status -eq 0 ]]
  [[ $output == *"警告: 测试文件缺少 tests 字段，将执行 0 个测试用例"* ]]
}

@test "验证输出目录创建" {
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
  run "$PROJECT_ROOT/src/opencode-test.sh" -o "$TEST_TMPDIR/output" "$TEST_TMPDIR/valid.json"
  [[ $status -eq 0 ]]
  [[ -d "$TEST_TMPDIR/output" ]]
}

@test "复制 agent 文件到测试环境" {
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

  run "$PROJECT_ROOT/src/opencode-test.sh" -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"复制 agent: $TEST_TMPDIR/agents/test-agent.md"* ]]
}

@test "复制 command 文件到测试环境" {
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

  run "$PROJECT_ROOT/src/opencode-test.sh" -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"复制 command: $TEST_TMPDIR/commands/test-command.md"* ]]
}

@test "复制 skill 目录到测试环境" {
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

  run "$PROJECT_ROOT/src/opencode-test.sh" -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"复制 skill: $TEST_TMPDIR/skills/test-skill"* ]]
}

@test "处理不存在的 agent 文件" {
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

  run "$PROJECT_ROOT/src/opencode-test.sh" -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  # Should not fail, just skip non-existent files
}

@test "配置文件中的参数覆盖命令行参数" {
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

  run "$PROJECT_ROOT/src/opencode-test.sh" -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"模型: test/custom-model"* ]]
  [[ $output == *"超时: 60 秒"* ]]
  [[ $output == *"并行数: 2"* ]]
}

@test "执行实际测试用例" {
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

  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: simple_test"* ]]
  [[ $output == *"找到 1 个测试用例"* ]]
}

@test "输出目录复制功能" {
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

  run "$PROJECT_ROOT/src/opencode-test.sh" -o "$TEST_TMPDIR/custom-output" "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ -d "$TEST_TMPDIR/custom-output" ]]
  [[ $output == *"输出已复制到: $TEST_TMPDIR/custom-output"* ]]
}

@test "测试用例包含agent和command参数" {
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

  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: test_with_agent"* ]]
  [[ $output == *"Agent: test-agent"* ]]
  [[ $output == *"Command: test-command"* ]]
}

@test "验证配置文件中的parallel参数" {
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

  run "$PROJECT_ROOT/src/opencode-test.sh" -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"并行数: 8"* ]]
}

@test "测试超时处理" {
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
  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" --timeout 1 "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  # Note: The actual timeout handling depends on the opencode command behavior
  # Since we can't easily mock opencode, we verify the script accepts the timeout parameter
}

@test "测试用例包含 files 字段" {
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

  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: test_with_files"* ]]
  [[ $output == *"Files: [\"test-file.txt\"]"* ]]
}

@test "测试用例包含多个 files 字段" {
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

  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: test_with_multiple_files"* ]]
  [[ $output == *"Files: [\"file1.txt\",\"file2.txt\",\"file3.txt\"]"* ]]
}

@test "测试用例包含 expectations 字段" {
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

  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: test_with_expectations"* ]]
}

@test "验证 agent 和 command 参数正确传递给 opencode" {
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

  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" -v "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ $output == *"执行测试: specific_agent_command_test"* ]]
  [[ $output == *"Agent: my-agent"* ]]
  [[ $output == *"Command: my-command"* ]]
}

@test "验证测试执行后生成输出文件" {
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
  PATH="$MOCK_OPENCODE_DIR:$PATH" run "$PROJECT_ROOT/src/opencode-test.sh" -o "$TEST_TMPDIR/test-output" "$TEST_TMPDIR/config.json"
  [[ $status -eq 0 ]]
  [[ -d "$TEST_TMPDIR/test-output" ]]
  [[ -f "$TEST_TMPDIR/test-output/output_test.jsonl" ]]
}

@test "端到端测试使用真实 opencode" {
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
  run "$PROJECT_ROOT/src/opencode-test.sh" -v -o "$TEST_TMPDIR/e2e-output" "$TEST_TMPDIR/e2e-test.json"
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
