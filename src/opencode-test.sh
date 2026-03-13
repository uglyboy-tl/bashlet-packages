#!/usr/bin/env bash

set -euo pipefail

# Script metadata
SCRIPT_NAME="OpenCode-Test"
VERSION="1.0.0"

# Project setup
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/lib/std/import.sh"

import core/log
import core/args

# Global variables

# Configuration variables (with defaults)
VERBOSE=false
JOBS=4
OUTPUT="${OPENCODE_TEST_OUTPUT:-doc}"
INPUT="${OUTPUT}"
TIMEOUT=30
MODEL="opencode/gpt-5-nano"
AUTOGRADE=false

# Runtime variables
TEST_FILE=""
TEST_ENV_DIR=""

# Parsed config arrays (boundary parsing)
AGENTS_CONFIG=""
COMMANDS_CONFIG=""
SKILLS_CONFIG=""

# Assets directory for resource files
ASSETS_DIR="$PROJECT_ROOT/assets/opencode-test"

# Parsed test data (boundary validation results)
_PARSED_CONTENT=""
declare -A _PARSED_DATA=()

# Load and parse test file at boundary (once only)
load_parsed_test_data() {
	if [[ -n $_PARSED_CONTENT ]]; then
		return
	fi

	# Boundary validation: ensure file exists and is valid JSON
	if [[ ! -f $TEST_FILE ]]; then
		log.error "测试文件 '$TEST_FILE' 不存在"
		exit 1
	fi

	# Read and validate JSON in one step
	if ! _PARSED_CONTENT=$(cat "$TEST_FILE") || ! jq '.' <<< "$_PARSED_CONTENT" > /dev/null 2>&1; then
		log.error "无效的 JSON 文件 '$TEST_FILE'"
		exit 1
	fi

	# Extract all needed data in a single jq call using associative array format
	local parsed_json
	parsed_json=$(jq -r '
		# Basic config and test info
		(has("tests") | tostring) as $has_tests |
		(if has("tests") then (.tests | length | tostring) else "0" end) as $test_count |
		(.config.model // "") as $model |
		(.config.timeout // "") as $timeout |
		(.config.parallel // "") as $parallel |
		(.config.agents // [] | join("\n")) as $agents |
		(.config.commands // [] | join("\n")) as $commands |
		(.config.skills // [] | join("\n")) as $skills |

		# Output basic entries
		"has_tests|\($has_tests)",
		"test_count|\($test_count)",
		"model|\($model)",
		"timeout|\($timeout)",
		"parallel|\($parallel)",
		"agents|\($agents)",
		"commands|\($commands)",
		"skills|\($skills)",

		# Test case data
		(.tests // [] | to_entries[] |
			"test_\(.key)_name|\(.value.name // "")",
			"test_\(.key)_agent|\(.value.agent // "")",
			"test_\(.key)_command|\(.value.command // "")",
			"test_\(.key)_prompt|\(.value.prompt // "")",
			"test_\(.key)_files|\(.value.files // [] | @json)"
		),

		# Expectations data
		(.tests // [] | .[] | select(has("expectations")) |
			"expectations_\(.name)|\(.expectations | @json)"
		)
	' <<< "$_PARSED_CONTENT")

	# Parse the output into associative array
	while IFS='|' read -r key value; do
		_PARSED_DATA["$key"]="$value"
	done <<< "$parsed_json"
}

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

	args.has "-v" "--version" && usage.version && exit 0
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
		log.error "请提供测试用例 JSON 文件"
		args.show_help
		exit 1
	fi

	TEST_FILE="${args_array[0]}"

	# Validate test file exists
	if [[ ! -f $TEST_FILE ]]; then
		log.error "测试文件 '$TEST_FILE' 不存在"
		exit 1
	fi

	# Set global variables from arguments
	if args.has "-v" "--verbose"; then
		VERBOSE=true
	fi

	if args.has "-j" "--jobs"; then
		JOBS=$(args.get "-j" "--jobs")
		# Validate jobs immediately - must be a positive integer
		if ! [[ $JOBS =~ ^[0-9]+$ ]] || [[ $JOBS -le 0 ]]; then
			log.error "并发任务数必须为正整数"
			exit 1
		fi
	fi

	args.has "-o" "--output" && OUTPUT=$(args.get "-o" "--output")

	args.has "-i" "--input" && INPUT=$(args.get "-i" "--input")

	args.has "--timeout" && TIMEOUT=$(args.get "--timeout") && {
		# Validate timeout immediately - must be a positive integer
		[[ $TIMEOUT =~ ^[0-9]+$ ]] && [[ $TIMEOUT -gt 0 ]] || {
			log.error "超时值必须为正整数"
			exit 1
		}
	}

	args.has "--model" && MODEL=$(args.get "--model")

	args.has "--autograde" && AUTOGRADE=true
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
	[[ $AUTOGRADE != true ]] && return 0
	[[ $VERBOSE == true ]] && log.info "测试完成，开始自动评分..."
	cmd_grade "--output" "$OUTPUT" "$TEST_FILE"
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
	if ! command -v jq &> /dev/null; then
		log.error "需要 jq 工具来解析 JSON"
		exit 1
	fi
	if ! command -v opencode &> /dev/null; then
		log.error "需要 opencode CLI 工具"
		exit 1
	fi
}

# Simplified cache function for backward compatibility
get_cached_value() {
	local key="$1"
	load_parsed_test_data

	# Return from parsed data with fallback
	case "$key" in
	"content") echo "$_PARSED_CONTENT" ;;
	"has_tests") echo "${_PARSED_DATA[$key]:-false}" ;;
	"test_count") echo "${_PARSED_DATA[$key]:-0}" ;;
	"model") echo "${_PARSED_DATA[$key]:-$MODEL}" ;;
	"timeout") echo "${_PARSED_DATA[$key]:-$TIMEOUT}" ;;
	"parallel") echo "${_PARSED_DATA[$key]:-$JOBS}" ;;
	"agents" | "commands" | "skills" | test_*_*) echo "${_PARSED_DATA[$key]:-}" ;;
	expectations_*) echo "${_PARSED_DATA[$key]:-[]}" ;;
	*) log.error "错误: 未知的缓存键 '$key'" && exit 1 ;;
	esac
}

# Simplified wrapper functions using specific keys
get_test_field() {
	get_cached_value "test_$1_$2"
}

read_test_config() {
	# Parse test file at boundary (validation happens here)
	load_parsed_test_data

	# Show warning for missing tests field
	if [[ $(get_cached_value "has_tests") != "true" ]]; then
		log.warn "测试文件缺少 tests 字段，将执行 0 个测试用例"
	fi

	# Read config values, use defaults if not present
	MODEL=$(get_cached_value "model")

	# Early return if not in test command (guard clause)
	if [[ ${_ARGS_CURRENT_SUBCOMMAND:-} != "test" ]]; then
		return 0
	fi

	# Read timeout, parallel and config arrays for test command
	TIMEOUT=$(get_cached_value "timeout")
	JOBS=$(get_cached_value "parallel")

	# Parse config arrays at boundary (parse, don't validate)
	AGENTS_CONFIG=$(get_cached_value "agents")
	COMMANDS_CONFIG=$(get_cached_value "commands")
	SKILLS_CONFIG=$(get_cached_value "skills")
}

# Generate grading report for a single test case
generate_grading_report() {
	local test_name="$1"
	local test_output_file="$2"
	local test_index="$3"

	mkdir -p "$OUTPUT/grading"
	local report_file="$OUTPUT/grading/${test_name}.json"

	local expectations_json
	expectations_json=$(get_cached_value "expectations_$test_name")
	local expectations_count
	expectations_count=$(jq '. | length' <<< "$expectations_json")

	local metrics
	metrics=$(extract_metrics "$test_output_file")
	local total_tokens input_tokens output_tokens tool_calls_total output_chars tool_calls_by_type
	read -r total_tokens input_tokens output_tokens tool_calls_total output_chars tool_calls_by_type <<< "$metrics"

	local expectations_array="[]"
	local passed_count=0
	local failed_count=0

	if [[ $expectations_count -gt 0 ]]; then
		local qualitative_result
		qualitative_result=$(qualitative_assess "$expectations_json" "$test_output_file")

		if [[ -n $qualitative_result && $qualitative_result != "[]" ]]; then
			local parsed
			parsed=$(parse_qualitative_result "$qualitative_result")
			IFS='|' read -r expectations_array passed_count failed_count <<< "$parsed"
		fi
	else
		expectations_array='[{"description": "测试执行完成", "passed": true, "evidence": "测试成功执行并生成输出"}]'
		passed_count=1
	fi

	local total_evaluations=$((passed_count + failed_count))
	local pass_rate="0.00"
	if [[ $total_evaluations -gt 0 ]]; then
		pass_rate=$(awk "BEGIN {printf \"%.2f\", $passed_count / $total_evaluations}")
	fi

	build_report_json "$test_name" "$expectations_array" "$passed_count" "$failed_count" "$total_evaluations" "$pass_rate" "$total_tokens" "$input_tokens" "$output_tokens" "$tool_calls_total" "$tool_calls_by_type" "$output_chars" > "$report_file"
}

# Extract quantitative metrics from test output file (pure function, single jq call)
# Usage: extract_metrics <test_output_file>
# Prints: total_tokens input_tokens output_tokens tool_calls_total output_chars tool_calls_by_type_json
extract_metrics() {
	local test_output_file="$1"

	if [[ ! -f $test_output_file ]]; then
		echo "0 0 0 0 0 {}"
		return
	fi

	# Use single jq call to extract all metrics with proper escaping
	jq -s -r '
		# Calculate all metrics in one pass
		([.[] | select(.type == "step_finish") | .part.tokens.total // 0] | add // 0) as $total_tokens |
		([.[] | select(.type == "step_finish") | .part.tokens.input // 0] | add // 0) as $input_tokens |
		([.[] | select(.type == "step_finish") | .part.tokens.output // 0] | add // 0) as $output_tokens |
		([.[] | select(.type == "tool_use")] | length) as $tool_calls_total |
		([.[] | select(.type == "text") | .part.text // ""] | join("") | length) as $output_chars |
		([.[] | select(.type == "tool_use") | .part.tool] | group_by(.) | map({(.[0]): length}) | add // {}) as $tool_calls_by_type |

		# Output with proper shell escaping for the JSON part
		"\($total_tokens) \($input_tokens) \($output_tokens) \($tool_calls_total) \($output_chars) \($tool_calls_by_type|@json)"
	' "$test_output_file"
}

parse_qualitative_result() {
	local qualitative_json="$1"

	if [[ -z $qualitative_json || $qualitative_json == "[]" ]]; then
		echo "[]|0|0"
		return
	fi

	local passed failed
	passed=$(jq -r '[.[] | select(.passed == true)] | length' <<< "$qualitative_json")
	failed=$(jq -r '[.[] | select(.passed == false)] | length' <<< "$qualitative_json")

	echo "$qualitative_json|$passed|$failed"
}

# Build grading report JSON (pure function)
# Usage: build_report_json <test_name> <expectations_json> <passed> <failed> <total> <pass_rate> <total_tokens> <input_tokens> <output_tokens> <tool_calls_total> <tool_calls_by_type> <output_chars>
build_report_json() {
	jq -n \
		--arg test_name "$1" \
		--arg expectations "$2" \
		--argjson passed "$3" \
		--argjson failed "$4" \
		--argjson total "$5" \
		--argjson pass_rate "$6" \
		--argjson total_tokens "$7" \
		--argjson input_tokens "$8" \
		--argjson output_tokens "$9" \
		--argjson tool_calls_total "${10}" \
		--argjson tool_calls_by_type "${11}" \
		--argjson output_chars "${12}" \
		--arg graded_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
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
		}'
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
	if ! echo "$result" | jq -e 'if type == "array" then true else false end' > /dev/null 2>&1; then
		echo "[]"
		return 1
	fi

	echo "$result"
	return 0
}

# Validate required resources exist for current operation
# Fast fail if resources are missing
validate_required_resources() {
	# Check if we need grader.md for current operation
	if [[ ${_ARGS_CURRENT_SUBCOMMAND:-} == "grade" ]] || [[ $AUTOGRADE == true ]]; then
		if [[ ! -f "$ASSETS_DIR/grader.md" ]]; then
			log.error "未找到 grader.md 资源文件，无法进行评分"
			exit 1
		fi
	fi
}

# Initialize .opencode directory structure in target directory
# Usage: init_opencode_structure <target_dir>
init_opencode_structure() {
	local target_dir="$1"

	# Create .opencode directory structure
	mkdir -p "$target_dir/.opencode/agents"
	mkdir -p "$target_dir/.opencode/commands"
	mkdir -p "$target_dir/.opencode/skills"

	# Create empty.md if not exists (guard clause)
	[[ -f "$target_dir/.opencode/agents/empty.md" ]] || touch "$target_dir/.opencode/agents/empty.md"
}

# Copy configuration resources to test environment
# Usage: copy_config_resources <target_dir>
copy_config_resources() {
	local target_dir="$1"

	# Copy parsed config resources with validation
	while IFS= read -r agent_path; do
		[[ -z $agent_path ]] && continue
		[[ -f $agent_path ]] && cp "$agent_path" "$target_dir/.opencode/agents/"
		[[ $VERBOSE == true && -n $agent_path && -f $agent_path ]] && log.info "复制 agent: $agent_path"
	done <<< "$AGENTS_CONFIG"

	while IFS= read -r command_path; do
		[[ -z $command_path ]] && continue
		[[ -d $command_path ]] && cp -r "$command_path" "$target_dir/.opencode/commands/"
		[[ -f $command_path ]] && cp "$command_path" "$target_dir/.opencode/commands/"
		[[ $VERBOSE == true ]] && log.info "复制 command: $command_path"
	done <<< "$COMMANDS_CONFIG"

	while IFS= read -r skill_path; do
		[[ -z $skill_path ]] && continue
		[[ -d $skill_path ]] && cp -r "$skill_path" "$target_dir/.opencode/skills/"
		[[ $VERBOSE == true && -n $skill_path && -d $skill_path ]] && log.info "复制 skill: $skill_path"
	done <<< "$SKILLS_CONFIG"

	# Copy grader.md if needed (already validated by validate_required_resources)
	[[ ${_ARGS_CURRENT_SUBCOMMAND:-} == "test" ]] && [[ $AUTOGRADE == false ]] && return
	cp "$ASSETS_DIR/grader.md" "$target_dir/.opencode/agents/grader.md"
}

# Create test environment directory structure
# If TEST_ENV_DIR already exists and is valid, reuse it
create_test_environment() {
	# Early return if already exists (fast fail - no work needed)
	if [[ -n ${TEST_ENV_DIR:-} && -d $TEST_ENV_DIR && -d "$TEST_ENV_DIR/.opencode" ]]; then
		[[ $VERBOSE == true ]] && log.info "复用现有测试环境: $TEST_ENV_DIR"
		return 0
	fi

	# Validate required resources before creating environment
	validate_required_resources

	# Create new test environment
	TEST_ENV_DIR="$(mktemp -d -t opencode-test-XXXXXX)"
	[[ $VERBOSE == true ]] && log.info "创建测试环境: $TEST_ENV_DIR"

	# Initialize base .opencode structure
	init_opencode_structure "$TEST_ENV_DIR"

	# Create output directory
	mkdir -p "$TEST_ENV_DIR/output"

	# Copy input files if INPUT is specified
	if [[ -n $INPUT && -d "$INPUT/output" ]]; then
		cp -r "$INPUT/output"/. "$TEST_ENV_DIR/output/"
		[[ $VERBOSE == true ]] && log.info "复制输入文件到测试环境: $INPUT/output -> $TEST_ENV_DIR/output/"
	fi

	# Copy configuration resources
	copy_config_resources "$TEST_ENV_DIR"
}

# Execute individual test
execute_test() {
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
		if [[ -n $files_json ]]; then
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
	if [[ -n $files_json && $files_json != "[]" ]]; then
		# Parse JSON array to bash array once (boundary)
		local -a files_array
		readarray -t files_array < <(jq -r '.[]' <<< "$files_json")

		# Get the directory of the test file to resolve relative paths
		local test_file_dir
		test_file_dir="$(dirname "$TEST_FILE")"

		# Use parsed bash array directly
		for file_name in "${files_array[@]}"; do
			[[ -z $file_name ]] && continue
			# Resolve relative path to absolute path
			local file_path
			[[ $file_name == /* ]] && file_path="$file_name" || file_path="$test_file_dir/$file_name"
			opencode_cmd+=" --file $(printf '%q' "$file_path")"
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
	timeout "$TIMEOUT" bash -c "cd '$TEST_ENV_DIR' && $opencode_cmd" > "$output_file" 2> /dev/null
	timeout_result=$?
	[[ $timeout_result -eq 0 ]] && return
	[[ $timeout_result -eq 124 ]] && log.error "测试超时 - $test_name" || log.error "测试执行失败 - $test_name"
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
		test_name=$(get_test_field "$i" "name")
		agent=$(get_test_field "$i" "agent")
		local command
		command=$(get_test_field "$i" "command")
		local prompt
		prompt=$(get_test_field "$i" "prompt")
		local files_json
		files_json=$(get_test_field "$i" "files")

		execute_test "$test_name" "$agent" "$command" "$prompt" "$files_json"
	done
}

# Grade all test cases
grade_all_tests() {
	local test_count
	test_count=$(get_cached_value "test_count")

	for ((i = 0; i < test_count; i++)); do
		local test_name
		test_name=$(get_test_field "$i" "name")
		local test_output_file="$TEST_ENV_DIR/output/${test_name}.jsonl"

		if [[ ! -f $test_output_file ]]; then
			log.warn "测试输出文件不存在: $test_output_file"
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
	# Early return if no directory to clean
	[[ -z ${TEST_ENV_DIR:-} || ! -d $TEST_ENV_DIR ]] && return 0
	[[ $VERBOSE == true ]] && log.info "清理测试环境: $TEST_ENV_DIR"
	rm -rf "$TEST_ENV_DIR"
}

# Set up cleanup trap
trap cleanup EXIT

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	main "$@"
fi
