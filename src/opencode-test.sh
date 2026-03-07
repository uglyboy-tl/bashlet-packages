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
		# Validate jobs immediately
		if [[ "$JOBS" == -* ]] || { [[ "$JOBS" =~ ^[0-9]+$ ]] && [[ "$JOBS" -le 0 ]]; }; then
			log.error "错误: 并发任务数必须为正整数"
			exit 1
		fi
	fi

	if args.has "-o" "--output"; then
		OUTPUT=$(args.get "-o" "--output")
	fi

	if args.has "--timeout"; then
		TIMEOUT=$(args.get "--timeout")
		# Validate timeout immediately
		if [[ "$TIMEOUT" == -* ]] || { [[ "$TIMEOUT" =~ ^[0-9]+$ ]] && [[ "$TIMEOUT" -le 0 ]]; }; then
			log.error "错误: 超时值必须为正整数"
			exit 1
		fi
	fi

	if args.has "--model"; then
		MODEL=$(args.get "--model")
	fi

	# Execute the main logic
	execute_test_suite
}

# Check dependencies
check_dependencies() {
	if ! command -v jq &>/dev/null; then
		log.error "错误: 需要 jq 工具来解析 JSON"
		exit 1
	fi
	if ! command -v opencode &>/dev/null; then
		log.error "错误: 需要 opencode CLI 工具"
		exit 1
	fi
}

# Read test configuration from JSON file
read_test_config() {
	if ! jq '.' "$TEST_FILE" >/dev/null 2>&1; then
		log.error "错误: 无效的 JSON 文件 '$TEST_FILE'"
		exit 1
	fi

	# Check if tests field exists
	if ! jq -e 'has("tests")' "$TEST_FILE" >/dev/null 2>&1; then
		log.warn "警告: 测试文件缺少 tests 字段，将执行 0 个测试用例"
	fi

	# Read config values, use defaults if not present
	local config_model
	config_model=$(jq -r '.config.model // empty' "$TEST_FILE" 2>/dev/null)
	if [[ -n $config_model ]]; then
		MODEL="$config_model"
	fi

	local config_timeout
	config_timeout=$(jq -r '.config.timeout // empty' "$TEST_FILE" 2>/dev/null)
	if [[ -n $config_timeout ]]; then
		TIMEOUT="$config_timeout"
	fi

	local config_parallel
	config_parallel=$(jq -r '.config.parallel // empty' "$TEST_FILE" 2>/dev/null)
	if [[ -n $config_parallel ]]; then
		JOBS="$config_parallel"
	fi

	# Validate numeric values only if they are set via command line args
	# Config values are validated separately in execute_test_suite
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
	if jq -e '.config | has("agents") and (.agents | type == "array" and length > 0)' "$TEST_FILE" >/dev/null 2>&1; then
		while IFS= read -r agent_path; do
			if [[ -n $agent_path && -f $agent_path ]]; then
				cp "$agent_path" "$TEST_ENV_DIR/.opencode/agents/"
				if [[ $VERBOSE == true ]]; then
					log.info "复制 agent: $agent_path"
				fi
			fi
		done < <(jq -r '.config.agents[] // empty' "$TEST_FILE")
	fi

	if jq -e '.config | has("commands") and (.commands | type == "array" and length > 0)' "$TEST_FILE" >/dev/null 2>&1; then
		while IFS= read -r command_path; do
			if [[ -n $command_path ]]; then
				if [[ -d $command_path ]]; then
					# Handle command directory
					cp -r "$command_path" "$TEST_ENV_DIR/.opencode/commands/"
				elif [[ -f $command_path ]]; then
					# Handle command file (.md)
					cp "$command_path" "$TEST_ENV_DIR/.opencode/commands/"
				fi
				if [[ $VERBOSE == true ]]; then
					log.info "复制 command: $command_path"
				fi
			fi
		done < <(jq -r '.config.commands[] // empty' "$TEST_FILE")
	fi

	if jq -e '.config | has("skills") and (.skills | type == "array" and length > 0)' "$TEST_FILE" >/dev/null 2>&1; then
		while IFS= read -r skill_path; do
			if [[ -n $skill_path && -d $skill_path ]]; then
				cp -r "$skill_path" "$TEST_ENV_DIR/.opencode/skills/"
				if [[ $VERBOSE == true ]]; then
					log.info "复制 skill: $skill_path"
				fi
			fi
		done < <(jq -r '.config.skills[] // empty' "$TEST_FILE")
	fi
}

# Execute individual test case
execute_test_case() {
	local test_name="$1"
	local agent="$2"
	local command="$3"
	local prompt="$4"
	local files_json="$5"

	if [[ $VERBOSE == true ]]; then
		log.info "执行测试: $test_name"
		log.info "  Agent: $agent"
		log.info "  Command: $command"
		log.info "  Prompt: $prompt"
		if [[ -n "$files_json" ]]; then
			log.info "  Files: $files_json"
		fi
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

	# Add file arguments from test case files array
	if [[ -n "$files_json" ]]; then
		# Get the directory of the test file to resolve relative paths
		local test_file_dir
		test_file_dir="$(dirname "$TEST_FILE")"

		# Count files first
		local file_count
		file_count=$(jq '. | length' <<<"$files_json")

		for ((i = 0; i < file_count; i++)); do
			local file_name
			file_name=$(jq -r ".[$i]" <<<"$files_json")
			if [[ -n "$file_name" ]]; then
				# Resolve relative path to absolute path
				local file_path
				if [[ "$file_name" == /* ]]; then
					# Absolute path
					file_path="$file_name"
				else
					# Relative path - resolve relative to test file directory
					file_path="$test_file_dir/$file_name"
				fi
				opencode_cmd+=" --file $(printf '%q' "$file_path")"
			fi
		done
	fi

	# Execute and save output
	local output_file="$TEST_ENV_DIR/output/${test_name}.jsonl"
	if [[ $VERBOSE == true ]]; then
		log.info "执行命令: $opencode_cmd"
		log.info "输出文件: $output_file"
		log.info "工作目录: $TEST_ENV_DIR"
	fi

	# Use timeout to enforce timeout limit and execute in the test environment directory
	if ! timeout "$TIMEOUT" bash -c "cd '$TEST_ENV_DIR' && $opencode_cmd" >"$output_file" 2>/dev/null; then
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
		local files_json
		files_json=$(jq -c ".tests[$i].files // []" "$TEST_FILE")

		execute_test_case "$test_name" "$agent" "$command" "$prompt" "$files_json"
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
