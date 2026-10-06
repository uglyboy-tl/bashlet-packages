#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "hf.map: 下载量与点赞，毫秒时间戳归一" {
	cat > "$BATS_TEST_TMPDIR/hf.json" << 'JSON'
[{"id":"BAAI/m","downloads":100,"likes":7,"pipeline_tag":"text-classification",
  "lastModified":"2026-07-23T15:21:59.000Z","tags":["safetensors","transformers"]}]
JSON
	run hf.map models < "$BATS_TEST_TMPDIR/hf.json"
	assert_success
	assert_jq '[.id,.url,.created_at,.engagement.downloads,.author,(.tags|join(","))]'
	assert_output '["BAAI/m","https://huggingface.co/models/BAAI/m","2026-07-23T15:21:59Z",100,"BAAI","safetensors,transformers"]'
}
