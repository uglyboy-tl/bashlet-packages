#!/usr/bin/env bash
# imagine 测试共用环境：各 bats 文件先 load 'test_helper/common-setup'，再 load 'setup.bash'

_imagine_setup() {
	_common_setup
	cd "$PROJECT_ROOT"
	TEST_DIR=$(mktemp -d)
	# 隔离模型目录缓存，并禁掉后台回源（测试不联网）
	export SCRIPT_CACHE_DIR="$TEST_DIR/cache"
	export IMAGINE_REGISTRY_OFF=1
	# _fast_load：bats 开着 functrace，直接 import 会让每条命令都过 DEBUG trap
	# （见 test_helper/common-setup.bash 里的说明）
	_fast_load import size common provider registry compose providers/index
}

_imagine_teardown() {
	rm -rf "${TEST_DIR:-}"
}
