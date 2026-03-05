#!/usr/bin/env bats

load 'test_helper/common-setup'

setup() {
  _common_setup
}

teardown() {
  : # No cleanup needed
}

# ============ 功能检测测试 ============

@test "test" {
  echo "OK"
}
