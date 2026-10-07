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

# ========== -u：按 URL 直取单条 ==========

@test "hf.search_url: 打 /api/models/<id>，单对象包一层后过 hf.map" {
	dig.http.get() {
		[[ $1 == "https://huggingface.co/api/models/BAAI/m" ]] || return 1
		printf '%s' '{"id":"BAAI/m","downloads":100,"likes":7,"pipeline_tag":"text",
			"lastModified":"2026-07-23T15:21:59.000Z","tags":["safetensors"]}'
	}

	run hf.search_url "https://huggingface.co/BAAI/m"
	assert_success
	assert_jq '[.id,.source,.url,.engagement.downloads,.author]'
	assert_output '["BAAI/m","hf","https://huggingface.co/models/BAAI/m",100,"BAAI"]'
}

@test "hf.search_url: /datasets/<o>/<n> 走 datasets 端点" {
	dig.http.get() {
		[[ $1 == "https://huggingface.co/api/datasets/squad/data" ]] || return 1
		printf '%s' '{"id":"squad/data","downloads":5,"likes":1,"lastModified":"2026-01-01T00:00:00.000Z","tags":[]}'
	}

	run hf.search_url "https://huggingface.co/datasets/squad/data"
	assert_success
	assert_jq '[.url,.source]'
	assert_output '["https://huggingface.co/datasets/squad/data","hf"]'
}

@test "hf.search_url: URL 不成形时报错（路由由 test/fetch.bats 的表驱动用例覆盖）" {
	run hf.search_url "https://huggingface.co/foo"
	assert_failure
	assert_output --partial "不是合法的 Hugging Face 仓库 URL"
}
