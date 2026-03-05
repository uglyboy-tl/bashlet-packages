#!/usr/bin/env bash
# shellcheck disable=SC2034

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

import core/log
import core/args

# Global variables
VERBOSE=false
JOBS=4
OUTPUT="doc"
TIMEOUT=30
MODEL="opencode/gpt-5-nano"
TEST_FILE=""
TEST_ENV_DIR=""

main() {
  # Initialize argument parsing
  args.init "OpenCode 测试执行器"

  # Add options with empty short options for long-only options
  args.add_options "verbose" "v" "显示详细执行信息"
  args.add_options "jobs" "j" "并行执行的测试数量" "NUMBER"
  args.add_options "output" "o" "指定输出报告文件" "STRING"
  args.add_options "timeout" "" "单个测试超时时间（秒）" "NUMBER"
  args.add_options "model" "" "指定测试模型" "STRING"
  args.add_options "arg" "测试用例文件" "测试用例 JSON 文件路径"

  # Process arguments
  args.process "$@"

  # Get positional argument (test file)
  declare -n args_array=$(args.args)
  if [[ ${#args_array[@]} -eq 0 ]]; then
    log.error "错误: 请提供测试用例 JSON 文件"
    args.show_help
    exit 1
  fi
  TEST_FILE="${args_array[0]}"

  # Validate test file exists
  if [[ ! -f $TEST_FILE ]]; then
    log.error "错误: 测试文件 '$TEST_FILE' 不存在"
    exit 1
  fi

  # Set global variables from arguments
  if args.has "-v" "--verbose"; then
    VERBOSE=true
  fi

  if args.has "-j" "--jobs"; then
    JOBS=$(args.get "-j" "--jobs")
  fi

  if args.has "-o" "--output"; then
    OUTPUT=$(args.get "-o" "--output")
  fi

  if args.has "--timeout"; then
    TIMEOUT=$(args.get "--timeout")
  fi

  if args.has "--model"; then
    MODEL=$(args.get "--model")
  fi

  # Execute the main logic
  execute_test_suite
}

# Check dependencies
check_dependencies() {
  if ! command -v jq &> /dev/null; then
    log.error "错误: 需要 jq 工具来解析 JSON"
    exit 1
  fi
  if ! command -v opencode &> /dev/null; then
    log.error "错误: 需要 opencode CLI 工具"
    exit 1
  fi
}

# Read test configuration from JSON file
read_test_config() {
  if ! jq '.' "$TEST_FILE" > /dev/null 2>&1; then
    log.error "错误: 无效的 JSON 文件 '$TEST_FILE'"
    exit 1
  fi

  # Read config values, use defaults if not present
  local config_model
  config_model=$(jq -r '.config.model // empty' "$TEST_FILE" 2> /dev/null)
  if [[ -n $config_model ]]; then
    MODEL="$config_model"
  fi

  local config_timeout
  config_timeout=$(jq -r '.config.timeout // empty' "$TEST_FILE" 2> /dev/null)
  if [[ -n $config_timeout ]]; then
    TIMEOUT="$config_timeout"
  fi

  local config_parallel
  config_parallel=$(jq -r '.config.parallel // empty' "$TEST_FILE" 2> /dev/null)
  if [[ -n $config_parallel ]]; then
    JOBS="$config_parallel"
  fi
}

# Create test environment directory structure
create_test_environment() {
  TEST_ENV_DIR="$(mktemp -d -t opencode-test-XXXXXX)"
  if [[ $VERBOSE == true ]]; then
    log.info "创建测试环境: $TEST_ENV_DIR"
  fi

  # Create .opencode directory structure
  mkdir -p "$TEST_ENV_DIR/.opencode/agents"
  mkdir -p "$TEST_ENV_DIR/.opencode/commands"
  mkdir -p "$TEST_ENV_DIR/.opencode/skills"

  # Create output directory
  mkdir -p "$TEST_ENV_DIR/output"

  # Copy agents, commands, skills from config
  local i=0
  while IFS= read -r agent_path; do
    if [[ -n $agent_path && -f $agent_path ]]; then
      cp "$agent_path" "$TEST_ENV_DIR/.opencode/agents/"
      if [[ $VERBOSE == true ]]; then
        log.info "复制 agent: $agent_path"
      fi
    fi
  done < <(jq -r '.config.agents[] // empty' "$TEST_FILE")

  i=0
  while IFS= read -r command_path; do
    if [[ -n $command_path && -d $command_path ]]; then
      cp -r "$command_path" "$TEST_ENV_DIR/.opencode/commands/"
      if [[ $VERBOSE == true ]]; then
        log.info "复制 command: $command_path"
      fi
    fi
  done < <(jq -r '.config.commands[] // empty' "$TEST_FILE")

  i=0
  while IFS= read -r skill_path; do
    if [[ -n $skill_path && -d $skill_path ]]; then
      cp -r "$skill_path" "$TEST_ENV_DIR/.opencode/skills/"
      if [[ $VERBOSE == true ]]; then
        log.info "复制 skill: $skill_path"
      fi
    fi
  done < <(jq -r '.config.skills[] // empty' "$TEST_FILE")
}

# Execute individual test case
execute_test_case() {
  local test_name="$1"
  local agent="$2"
  local command="$3"
  local prompt="$4"

  if [[ $VERBOSE == true ]]; then
    log.info "执行测试: $test_name"
    log.info "  Agent: $agent"
    log.info "  Command: $command"
    log.info "  Prompt: $prompt"
  fi

  # Build opencode command
  local opencode_cmd="opencode run"
  opencode_cmd+=" \"$(printf '%q' "$prompt")\""
  opencode_cmd+=" --model $(printf '%q' "$MODEL")"
  opencode_cmd+=" --format json"

  if [[ -n $agent ]]; then
    opencode_cmd+=" --agent $(printf '%q' "$agent")"
  fi
  if [[ -n $command ]]; then
    opencode_cmd+=" --command $(printf '%q' "$command")"
  fi

  # Execute and save output
  local output_file="$TEST_ENV_DIR/output/${test_name}.jsonl"
  if [[ $VERBOSE == true ]]; then
    log.info "执行命令: $opencode_cmd"
    log.info "输出文件: $output_file"
  fi

  # Use timeout to enforce timeout limit
  if ! timeout "$TIMEOUT" bash -c "$opencode_cmd" > "$output_file" 2> /dev/null; then
    if [[ $? -eq 124 ]]; then
      log.error "测试超时: $test_name"
    else
      log.error "测试执行失败: $test_name"
    fi
  fi
}

# Execute all test cases
execute_all_tests() {
  local test_count
  test_count=$(jq '.tests | length' "$TEST_FILE")

  if [[ $VERBOSE == true ]]; then
    log.info "找到 $test_count 个测试用例"
  fi

  # For now, execute sequentially (parallel execution requires more complex setup)
  for ((i = 0; i < test_count; i++)); do
    local test_name
    test_name=$(jq -r ".tests[$i].name" "$TEST_FILE")
    local agent
    agent=$(jq -r ".tests[$i].agent // empty" "$TEST_FILE")
    local command
    command=$(jq -r ".tests[$i].command // empty" "$TEST_FILE")
    local prompt
    prompt=$(jq -r ".tests[$i].prompt" "$TEST_FILE")

    execute_test_case "$test_name" "$agent" "$command" "$prompt"
  done
}

# Cleanup test environment
cleanup() {
  if [[ -n ${TEST_ENV_DIR:-} && -d $TEST_ENV_DIR ]]; then
    if [[ $VERBOSE == true ]]; then
      log.info "清理测试环境: $TEST_ENV_DIR"
    fi
    rm -rf "$TEST_ENV_DIR"
  fi
}

# Set up cleanup trap
trap cleanup EXIT

execute_test_suite() {
  check_dependencies
  read_test_config

  if [[ $VERBOSE == true ]]; then
    log.info "详细模式已启用"
    log.info "并行数: $JOBS"
    log.info "超时: $TIMEOUT 秒"
    log.info "模型: $MODEL"
    log.info "输出文件: ${OUTPUT:-未指定}"
  fi

  create_test_environment
  log.info "开始执行测试: $TEST_FILE"
  execute_all_tests
  log.success "测试执行完成，输出保存在: $TEST_ENV_DIR/output/"

  # If output file is specified, copy the output directory there
  if [[ -n $OUTPUT ]]; then
    cp -r "$TEST_ENV_DIR/output" "$OUTPUT"
    log.info "输出已复制到: $OUTPUT"
  fi
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
fi
