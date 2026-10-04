#!/bin/bash
# Final simplified version

# Check if --agent grader is provided (used by qualitative_assess)
if [[ "$*" == *"--agent grader"* ]]; then
	# Check if this is the specific test case with "输出包含 hello" and "输出包含 world"
	if [[ "$*" == *"输出包含 hello"* && "$*" == *"输出包含 world"* ]]; then
		echo '{"type":"text","part":{"text":"[{\"text\": \"输出包含 hello\", \"passed\": true, \"evidence\": \"找到 Hello world\"}, {\"text\": \"输出包含 world\", \"passed\": true, \"evidence\": \"找到 Hello world\"}]"}}'
	else
		# Default to 2 generic expectations
		echo '{"type":"text","part":{"text":"[{\"text\": \"期望 1\", \"passed\": true, \"evidence\": \"找到相关证据\"}, {\"text\": \"期望 2\", \"passed\": true, \"evidence\": \"找到相关证据\"}]"}}'
	fi
else
	# Return complete standard output format for test commands
	cat <<'EOF'
{"type": "step_start", "part": {"id": "1"}}
{"type": "text", "part": {"text": "Hello world", "time": {"start": 1000, "end": 2000}}}
{"type": "tool_use", "part": {"tool": "Bash", "state": {"status": "completed"}}}
{"type": "tool_use", "part": {"tool": "Read", "state": {"status": "completed"}}}
{"type": "tool_use", "part": {"tool": "Write", "state": {"status": "completed"}}}
{"type": "step_finish", "part": {"reason": "stop", "tokens": {"total": 250, "input": 180, "output": 70}}}
EOF
fi
exit 0
