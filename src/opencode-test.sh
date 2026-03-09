#!/usr/bin/env bash

set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

import core/log
import core/args

# Global variables
VERBOSE=false
JOBS=4
OUTPUT="${OPENCODE_TEST_OUTPUT:-doc}"
INPUT="${OUTPUT}"
TIMEOUT=30
MODEL="opencode/gpt-5-nano"
AUTOGRADE=false
TEST_FILE=""
TEST_ENV_DIR=""
# Cache for test file parsing using associative array
declare -A TEST_FILE_CACHE=()

# Assets directory for resource files
ASSETS_DIR="$PROJECT_ROOT/assets/opencode-test"

main() {
	# Initialize argument parsing
	args.init "OpenCode 测试执行器"

	# Add global options
	args.add_options "version" "v" "显示版本信息"

	# Add subcommands
	args.add_subcommand "test" "执行测试" "cmd_test"
	args.add_subcommand "grade" "评分测试结果" "cmd_grade"

	# Process arguments
	args.process "$@"

	# Handle version flag
	if args.has "-v" "--version"; then
		echo "OpenCode Test Runner v1.0.0"
		exit 0
	fi

	# If no subcommand matched, show help
	args.show_help
	exit 1
}

# Handle common command line arguments for both test and grade subcommands
# Usage: handle_common_args <subcommand_name> "$@"
handle_common_args() {
	# Initialize args for the subcommand
	args.init "执行 ${_ARGS_CURRENT_SUBCOMMAND}"

	# Add common options
	args.add_options "verbose" "v" "显示详细执行信息"
	args.add_options "jobs" "j" "并行执行的数量" "NUMBER"
	args.add_options "output" "o" "指定输出目录" "STRING"
	args.add_options "timeout" "" "单个操作超时时间（秒）" "NUMBER"
	args.add_options "model" "" "指定模型" "STRING"
	args.add_options "arg" "测试文件" "测试用例 JSON 文件路径"

	# Add subcommand-specific options
	case "$_ARGS_CURRENT_SUBCOMMAND" in
	"test") args.add_options "autograde" "" "测试完成后自动评分" ;;
	"grade") args.add_options "input" "i" "指定测试结果输入目录" "STRING" ;;
	esac

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
	if [[ ! -f "$TEST_FILE" ]]; then
		log.error "错误: 测试文件 '$TEST_FILE' 不存在"
		exit 1
	fi

	# Set global variables from arguments
	if args.has "-v" "--verbose"; then
		VERBOSE=true
	fi

	if args.has "-j" "--jobs"; then
		JOBS=$(args.get "-j" "--jobs")
		# Validate jobs immediately - must be a positive integer
		if ! [[ $JOBS =~ ^[0-9]+$ ]] || [[ "$JOBS" -le 0 ]]; then
			log.error "错误: 并发任务数必须为正整数"
			exit 1
		fi
	fi

	if args.has "-o" "--output"; then
		OUTPUT=$(args.get "-o" "--output")
	fi

	if args.has "-i" "--input"; then
		INPUT=$(args.get "-i" "--input")
	fi

	if args.has "--timeout"; then
		TIMEOUT=$(args.get "--timeout")
		# Validate timeout immediately - must be a positive integer
		if ! [[ $TIMEOUT =~ ^[0-9]+$ ]] || [[ "$TIMEOUT" -le 0 ]]; then
			log.error "错误: 超时值必须为正整数"
			exit 1
		fi
	fi

	if args.has "--model"; then
		MODEL=$(args.get "--model")
	fi

	if args.has "--autograde"; then
		AUTOGRADE=true
	fi
}

# Test subcommand handler
cmd_test() {
	handle_common_args "$@"

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

	# If grade-after is enabled, run grading automatically
	if [[ $AUTOGRADE == true ]]; then
		if [[ $VERBOSE == true ]]; then
			log.info "测试完成，开始自动评分..."
		fi

		# Run grade subcommand with the same test file
		# Pass both input and output directories to grade command
		cmd_grade "--output" "$OUTPUT" "$TEST_FILE"
	fi
}

# Grade subcommand handler
cmd_grade() {
	handle_common_args "$@"

	check_dependencies
	read_test_config

	# Create test environment for grading
	create_test_environment

	# Execute grading
	if [[ $VERBOSE == true ]]; then
		log.info "开始评分..."
		log.info "测试文件: $TEST_FILE"
		log.info "测试环境: $TEST_ENV_DIR"
		log.info "评分输出: $OUTPUT"
		log.info "评分模型: $MODEL"
	fi

	grade_all_tests

	log.success "评分完成，结果保存到: $OUTPUT"
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

# Unified cache function that handles all test file data access
get_cached_value() {
	local key="$1"

	# Early return if cache is already set
	if [[ -n "${TEST_FILE_CACHE[$key]+isset}" ]]; then
		echo "${TEST_FILE_CACHE[$key]}"
		return
	fi

	# Ensure content is loaded first
	if [[ -z "${TEST_FILE_CACHE[content]+isset}" ]]; then
		if ! jq '.' "$TEST_FILE" >/dev/null 2>&1; then
			log.error "错误: 无效的 JSON 文件 '$TEST_FILE'"
			exit 1
		fi
		TEST_FILE_CACHE[content]=$(cat "$TEST_FILE")
	fi

	case "$key" in
	"content") ;;
	"has_tests")
		TEST_FILE_CACHE[has_tests]=$(jq -e 'has("tests")' <<<"${TEST_FILE_CACHE[content]}" >/dev/null 2>&1 && echo "true" || echo "false")
		;;
	"test_count")
		TEST_FILE_CACHE[test_count]=$(jq -e 'has("tests")' <<<"${TEST_FILE_CACHE[content]}" >/dev/null 2>&1 && jq '.tests | length' <<<"${TEST_FILE_CACHE[content]}" || echo "0")
		;;
	"model" | "timeout" | "parallel")
		TEST_FILE_CACHE[$key]=$(jq -r ".config.${key} // empty" <<<"${TEST_FILE_CACHE[content]}" 2>/dev/null)
		;;
	"agents" | "commands" | "skills")
		TEST_FILE_CACHE[$key]=$(jq -e ".config | has(\"$key\") and (.$key | type == \"array\")" <<<"${TEST_FILE_CACHE[content]}" >/dev/null 2>&1 && jq -r ".config.${key}[]" <<<"${TEST_FILE_CACHE[content]}" || echo "")
		;;
	test_case_*_*)
		# Parse key: test_case_<index>_<field>
		local index="${key#test_case_}"
		local field="${index#*_}"
		index="${index%_*}"
		if [[ "$field" == "files" ]]; then
			TEST_FILE_CACHE[$key]=$(jq -c ".tests[$index].files // []" <<<"${TEST_FILE_CACHE[content]}")
		else
			TEST_FILE_CACHE[$key]=$(jq -r ".tests[$index].$field // empty" <<<"${TEST_FILE_CACHE[content]}")
		fi
		;;
	expectations_*)
		local test_name="${key#expectations_}"
		TEST_FILE_CACHE[$key]=$(jq -r --arg name "$test_name" '
				.tests[] | select(.name == $name) | .expectations // []
			' <<<"${TEST_FILE_CACHE[content]}" 2>/dev/null || echo "[]")
		;;
	*)
		log.error "错误: 未知的缓存键 '$key'"
		exit 1
		;;
	esac

	# Output the cached value
	echo "${TEST_FILE_CACHE[$key]}"
}

# Simplified wrapper functions using specific keys
get_test_case_field() { get_cached_value "test_case_$1_$2"; }
get_test_case_files() { get_cached_value "test_case_$1_files"; }
get_test_expectations() { get_cached_value "expectations_$1"; }

read_test_config() {
	# Ensure test file is valid by triggering content cache
	get_cached_value "content" >/dev/null

	# Show warning for missing tests field
	has_tests_result=$(get_cached_value "has_tests")
	if [[ "$has_tests_result" != "true" ]]; then
		log.warn "警告: 测试文件缺少 tests 字段，将执行 0 个测试用例"
	fi

	# Read config values, use defaults if not present
	local config_model
	config_model=$(get_cached_value "model")
	if [[ -n $config_model ]]; then
		MODEL="$config_model"
	fi

	# Only read timeout and parallel config for test command
	if [[ "${_ARGS_CURRENT_SUBCOMMAND:-}" == "test" ]]; then
		local config_timeout
		config_timeout=$(get_cached_value "timeout")
		if [[ -n $config_timeout ]]; then
			TIMEOUT="$config_timeout"
		fi

		local config_parallel
		config_parallel=$(get_cached_value "parallel")
		if [[ -n $config_parallel ]]; then
			JOBS="$config_parallel"
		fi
	fi
}

# Generate grading report for a single test case
generate_grading_report() {
	local test_name="$1"
	local test_output_file="$2"
	local test_index="$3"

	# Create grading directory
	mkdir -p "$OUTPUT/grading"
	local report_file="$OUTPUT/grading/${test_name}.json"

	# Extract expectations from test file using cache
	local expectations_json
	expectations_json=$(get_test_expectations "$test_name")
	local expectations_count
	expectations_count=$(jq '. | length' <<<"$expectations_json")

	# Calculate quantitative metrics directly using variables
	local total_tokens=0
	local input_tokens=0
	local output_tokens=0
	local tool_calls_total=0
	local output_chars=0
	local tool_calls_by_type="{}"

	if [[ -f $test_output_file ]]; then
		total_tokens=$(jq -s '[.[] | select(.type == "step_finish") | .part.tokens.total // 0] | add // 0' "$test_output_file")
		input_tokens=$(jq -s '[.[] | select(.type == "step_finish") | .part.tokens.input // 0] | add // 0' "$test_output_file")
		output_tokens=$(jq -s '[.[] | select(.type == "step_finish") | .part.tokens.output // 0] | add // 0' "$test_output_file")
		tool_calls_total=$(jq -s '[.[] | select(.type == "tool_use")] | length' "$test_output_file")
		output_chars=$(jq -s '[.[] | select(.type == "text") | .part.text // ""] | join("") | length' "$test_output_file")
		tool_calls_by_type=$(jq -s '[.[] | select(.type == "tool_use") | .part.tool] | group_by(.) | map({(.[0]): length}) | add // {}' "$test_output_file")
	fi

	# Perform qualitative assessment and get results directly
	local expectations_array="[]"
	local passed_count=0
	local failed_count=0

	if [[ $expectations_count -gt 0 ]]; then
		local qualitative_result
		qualitative_result=$(qualitative_assess "$expectations_json" "$test_output_file")

		if [[ -n $qualitative_result && "$qualitative_result" != "[]" ]]; then
			# Use the result directly as it matches the expected format with 'text' field
			expectations_array="$qualitative_result"
			passed_count=$(echo "$expectations_array" | jq '[.[] | select(.passed == true)] | length')
			failed_count=$(echo "$expectations_array" | jq '[.[] | select(.passed == false)] | length')
		fi
		# If qualitative assessment failed or returned empty, keep defaults (empty array, 0 counts)
	else
		# No expectations defined, create a default one
		expectations_array='[{"description": "测试执行完成", "passed": true, "evidence": "测试成功执行并生成输出"}]'
		passed_count=1
	fi

	# Calculate final report metrics
	local total_evaluations=$((passed_count + failed_count))
	local pass_rate="0.00"
	if [[ $total_evaluations -gt 0 ]]; then
		pass_rate=$(awk "BEGIN {printf \"%.2f\", $passed_count / $total_evaluations}")
	fi

	local graded_at
	graded_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# Build the final report JSON directly
	jq -n \
		--arg test_name "$test_name" \
		--arg expectations "$expectations_array" \
		--argjson passed "$passed_count" \
		--argjson failed "$failed_count" \
		--argjson total "$total_evaluations" \
		--argjson pass_rate "$pass_rate" \
		--argjson total_tokens "$total_tokens" \
		--argjson input_tokens "$input_tokens" \
		--argjson output_tokens "$output_tokens" \
		--argjson tool_calls_total "$tool_calls_total" \
		--argjson tool_calls_by_type "$tool_calls_by_type" \
		--argjson output_chars "$output_chars" \
		--arg graded_at "$graded_at" \
		'{
      test_name: $test_name,
      expectations: $expectations | fromjson,
      score: {
        passed: $passed,
        failed: $failed,
        total: $total,
        pass_rate: $pass_rate
      },
      metrics: {
        tokens: {
          total: $total_tokens,
          input: $input_tokens,
          output: $output_tokens
        },
        tool_calls: {
          total: $tool_calls_total,
          by_type: $tool_calls_by_type
        },
        duration_seconds: 0.0,
        output_chars: $output_chars
      },
      graded_at: $graded_at
    }' >"$report_file"
}

# Qualitative assessment function
# Evaluates expectations against test output using grader agent
# Usage: qualitative_assess <expectations_json> <output_file>
# Returns: JSON array with evaluation results
qualitative_assess() {
	local expectations_json="$1"
	local output_file="$2"

	# Ensure absolute paths
	output_file="$(realpath "$output_file")"

	# If no expectations, return empty array
	if [[ -z $expectations_json || $expectations_json == "null" || $expectations_json == "[]" ]]; then
		echo "[]"
		return 0
	fi

	# Build prompt
	local prompt
	prompt="请评估以下期望:\n${expectations_json}\n\n测试输出文件: ${output_file}"

	# Execute opencode for qualitative assessment
	local result
	result=$(cd "$TEST_ENV_DIR" && opencode run "$prompt" \
		--agent grader \
		-f "$output_file" \
		--format json 2>&1 | jq -s '[.[] | select(.type == "text")] | last | .part.text' -r)

	# If opencode failed or output is empty, return empty array
	if [[ -z $result || $result == "null" ]]; then
		echo "[]"
		return 1
	fi

	# Validate output is valid JSON array
	if ! echo "$result" | jq -e 'if type == "array" then true else false end' >/dev/null 2>&1; then
		echo "[]"
		return 1
	fi

	echo "$result"
	return 0
}

# Initialize test environment in a directory
# Creates .opencode directory structure and required agent files
# Usage: init_test_environment <target_dir>
init_test_environment() {
	local target_dir="$1"

	# Create .opencode directory structure
	mkdir -p "$target_dir/.opencode/agents"
	mkdir -p "$target_dir/.opencode/commands"
	mkdir -p "$target_dir/.opencode/skills"

	# Create empty.md (empty agent for tests without specific agent)
	if [[ ! -f "$target_dir/.opencode/agents/empty.md" ]]; then
		touch "$target_dir/.opencode/agents/empty.md"
	fi

	# Create grader.md if it doesn't exist
	if [[ ! -f "$target_dir/.opencode/agents/grader.md" ]]; then
		if [[ -f "$ASSETS_DIR/grader.md" ]]; then
			cp "$ASSETS_DIR/grader.md" "$target_dir/.opencode/agents/grader.md"
		else
			# Fallback: create a default grader.md if assets file not found
			log.warn "警告: 未找到 grader.md 资源文件，使用默认配置"
			cat >"$target_dir/.opencode/agents/grader.md" <<'GRADER_EOF'
# 评分代理

根据测试输出评估期望（expectations）。

## 角色

你是评分者，审查测试输出文件，然后确定每个期望是通过还是失败。

## 输出格式

只输出纯 JSON 数组：
[
  {"text": "期望描述", "passed": true, "evidence": "证据描述"}
]
GRADER_EOF
		fi
	fi
}

# Create test environment directory structure
# If TEST_ENV_DIR already exists and is valid, reuse it
create_test_environment() {
	# If test environment already exists and is valid, reuse it
	if [[ -n ${TEST_ENV_DIR:-} && -d $TEST_ENV_DIR && -d "$TEST_ENV_DIR/.opencode" ]]; then
		if [[ $VERBOSE == true ]]; then
			log.info "复用现有测试环境: $TEST_ENV_DIR"
		fi
		return 0
	fi

	# Validate that TEST_FILE exists (fast fail principle)
	if [[ ! -f "$TEST_FILE" ]]; then
		log.error "错误: 测试文件 '$TEST_FILE' 不存在"
		exit 1
	fi

	# Create new test environment
	TEST_ENV_DIR="$(mktemp -d -t opencode-test-XXXXXX)"
	if [[ $VERBOSE == true ]]; then
		log.info "创建测试环境: $TEST_ENV_DIR"
	fi

	# Initialize base environment structure
	init_test_environment "$TEST_ENV_DIR"

	# Create output directory
	mkdir -p "$TEST_ENV_DIR/output"

	# Copy input files if INPUT is specified (independent of TEST_FILE existence)
	if [[ -n $INPUT && -d "$INPUT/output" ]]; then
		cp -r "$INPUT/output"/. "$TEST_ENV_DIR/output/"
		if [[ $VERBOSE == true ]]; then
			log.info "复制输入文件到测试环境: $INPUT/output -> $TEST_ENV_DIR/output/"
		fi
	fi

	# Copy agents, commands, skills from config only for test command
	if [[ "${_ARGS_CURRENT_SUBCOMMAND:-}" == "test" ]]; then
		# Get cached config arrays
		local agents_config
		agents_config=$(get_cached_value "agents")
		if [[ -n "$agents_config" ]]; then
			while IFS= read -r agent_path; do
				if [[ -n $agent_path && -f $agent_path ]]; then
					cp "$agent_path" "$TEST_ENV_DIR/.opencode/agents/"
					if [[ $VERBOSE == true ]]; then
						log.info "复制 agent: $agent_path"
					fi
				fi
			done <<<"$agents_config"
		fi

		local commands_config
		commands_config=$(get_cached_value "commands")
		if [[ -n "$commands_config" ]]; then
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
			done <<<"$commands_config"
		fi

		local skills_config
		skills_config=$(get_cached_value "skills")
		if [[ -n "$skills_config" ]]; then
			while IFS= read -r skill_path; do
				if [[ -n $skill_path && -d $skill_path ]]; then
					cp -r "$skill_path" "$TEST_ENV_DIR/.opencode/skills/"
					if [[ $VERBOSE == true ]]; then
						log.info "复制 skill: $skill_path"
					fi
				fi
			done <<<"$skills_config"
		fi
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
	if [[ -n $files_json ]]; then
		# Get the directory of the test file to resolve relative paths
		local test_file_dir
		test_file_dir="$(dirname "$TEST_FILE")"

		# Count files first
		local file_count
		file_count=$(jq '. | length' <<<"$files_json")

		for ((file_idx = 0; file_idx < file_count; file_idx++)); do
			local file_name
			file_name=$(jq -r ".[$file_idx]" <<<"$files_json")
			if [[ -n $file_name ]]; then
				# Resolve relative path to absolute path
				local file_path
				if [[ $file_name == /* ]]; then
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
	local timeout_result
	timeout "$TIMEOUT" bash -c "cd '$TEST_ENV_DIR' && $opencode_cmd" >"$output_file" 2>/dev/null
	timeout_result=$?
	if [[ $timeout_result -ne 0 ]]; then
		if [[ $timeout_result -eq 124 ]]; then
			log.error "测试超时: $test_name"
		else
			log.error "测试执行失败: $test_name"
		fi
	fi
}

# Execute all test cases
execute_all_tests() {
	local test_count
	test_count=$(get_cached_value "test_count")

	if [[ $VERBOSE == true ]]; then
		log.info "找到 $test_count 个测试用例"
	fi

	# For now, execute sequentially (parallel execution requires more complex setup)
	for ((i = 0; i < test_count; i++)); do
		local test_name
		test_name=$(get_test_case_field "$i" "name")
		local agent
		agent=$(get_test_case_field "$i" "agent")
		local command
		command=$(get_test_case_field "$i" "command")
		local prompt
		prompt=$(get_test_case_field "$i" "prompt")
		local files_json
		files_json=$(get_test_case_files "$i")

		execute_test_case "$test_name" "$agent" "$command" "$prompt" "$files_json"
	done
}

# Grade all test cases
grade_all_tests() {
	local test_count
	test_count=$(get_cached_value "test_count")

	for ((i = 0; i < test_count; i++)); do
		local test_name
		test_name=$(get_test_case_field "$i" "name")
		local test_output_file="$TEST_ENV_DIR/output/${test_name}.jsonl"

		if [[ ! -f $test_output_file ]]; then
			log.warn "警告: 测试输出文件不存在: $test_output_file"
			continue
		fi

		if [[ $VERBOSE == true ]]; then
			log.info "评分测试: $test_name"
		fi

		# Generate grading report for this test case
		generate_grading_report "$test_name" "$test_output_file" "$i"
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

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	main "$@"
fi
