#!/usr/bin/env bats

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

# 让 view 接口返回一个 cid，其余走各用例自己的桩
_stub_view() {
	dig.http.get() {
		case "$1" in
			*/x/web-interface/view) printf '%s' '{"data":{"cid":1}}' ;;
			*) return 1 ;;
		esac
	}
}

@test "bilibili.enrich_one: 抓不到字幕和弹幕时保留原简介" {
	_stub_view
	bilibili.subtitle() { return 0; }
	bilibili.danmaku_text() { return 0; }

	run bilibili.enrich_one '{"id":"BV1xx","text":"原简介"}' 1 1 1
	assert_success
	assert_output '{"id":"BV1xx","text":"原简介"}'
}

@test "bilibili.enrich_one: 抓到弹幕时覆盖 text" {
	_stub_view
	bilibili.subtitle() { return 0; }
	bilibili.danmaku_text() { printf '%s' "弹幕A"; }

	run bilibili.enrich_one '{"id":"BV1xx","text":"原简介"}' 1 1 0
	assert_success
	assert_output '{"id":"BV1xx","text":"弹幕A"}'
}

@test "bilibili.subtitle: 多条 ai-zh 轨只取第一条（避免拼出多行 URL）" {
	dig.http.get() {
		case "$1" in
			*/x/player/v2)
				printf '%s' '{"data":{"subtitle":{"subtitles":[
					{"lan":"ai-zh","subtitle_url":"//a"},
					{"lan":"ai-zh","subtitle_url":"//b"}]}}}'
				;;
			https://a) printf '%s' '{"body":[{"content":"字幕内容"}]}' ;;
			*) return 1 ;;
		esac
	}

	run bilibili.subtitle BV1xx 1
	assert_success
	assert_output '字幕内容'
}

@test "bilibili.map: 去高亮标签并映射播放/弹幕/评论" {
	cat > "$BATS_TEST_TMPDIR/bl.json" << 'JSON'
{"code":0,"data":{"result":[{"result_type":"video","data":[{
  "bvid":"BV1xx","title":"<em class=\"keyword\">Bash</em> 教程","author":"A",
  "pubdate":1700000000,"play":10,"danmaku":"2","review":3,
  "tag":"x,y","typename":"科技","description":"<b>desc</b>"
}]}]}}
JSON
	run bilibili.map < "$BATS_TEST_TMPDIR/bl.json"
	assert_success
	assert_jq '[.id,.title,.created_at,.engagement,(.tags|join("/"))]'
	assert_output '["BV1xx","Bash 教程","2023-11-14T22:13:20Z",{"play":10,"danmaku":2,"comments":3},"x/y/科技"]'
}

@test "bilibili.danmaku_sample: 按步长抽样并拼接" {
	local xml="<i>" i
	for i in $(seq 1 100); do xml+="<d p=\"1,1,25\">dm$i</d>"; done
	xml+="</i>"
	run bilibili.danmaku_sample "$xml"
	assert_success
	assert_output "dm1 / dm42 / dm83"
}

@test "bilibili.subtitle: 优先 ai-zh，其次任意中文" {
	dig.http.get() {
		case "$1" in
			*/x/player/v2)
				printf '%s' '{"data":{"subtitle":{"subtitles":[
					{"lan":"en","subtitle_url":"//en"},
					{"lan":"zh-CN","subtitle_url":"//zh"}]}}}'
				;;
			https://zh) printf '%s' '{"body":[{"content":"中文字幕"}]}' ;;
			*) return 1 ;;
		esac
	}

	run bilibili.subtitle BV1xx 1
	assert_success
	assert_output '中文字幕'
}

# ========== -u：按 URL 直取单条（隐式 -t 1 -d 1）==========

@test "bilibili.search_url: view 换 cid，弹幕进 text" {
	dig.http.get() {
		case "$1" in
			*/x/web-interface/view)
				printf '%s' '{"code":0,"data":{"bvid":"BV1xx","cid":1,"title":"T",
					"owner":{"name":"A"},"pubdate":1700000000,
					"stat":{"view":10,"danmaku":2,"reply":3},"tname":"科技","desc":"简介"}}'
				;;
			*/x/v1/dm/list.so) printf '%s' '<i><d p="1,1">dm1</d></i>' ;;
			*/x/player/v2) printf '%s' '{"code":0,"data":{"subtitle":{"subtitles":[]}}}' ;;
			*) return 1 ;;
		esac
	}
	export BILI_SESSDATA=fake

	run bilibili.search_url "https://www.bilibili.com/video/BV1xx411c7mD"
	assert_success
	assert_jq '[.id,.source,.title,.author,.text,.engagement.play]'
	assert_output '["BV1xx","bilibili","T","A","dm1",10]'
}

@test "bilibili.search_url: 没有 BILI_SESSDATA 时只警告不失败，text 退回简介" {
	unset BILI_SESSDATA
	dig.http.get() {
		case "$1" in
			*/x/web-interface/view)
				printf '%s' '{"code":0,"data":{"bvid":"BV1xx","cid":1,"title":"T",
					"owner":{"name":"A"},"pubdate":1700000000,
					"stat":{"view":1,"danmaku":0,"reply":0},"tname":"","desc":"简介"}}'
				;;
			*) return 1 ;;
		esac
	}

	run bilibili.search_url "https://www.bilibili.com/video/BV1xx411c7mD"
	assert_success
	assert_output --partial "BILI_SESSDATA"
	assert_output --partial '"text":"简介"'
}

@test "fetch.route: bilibili 的 BV/av 链接归到 bilibili，短链与别的站不认" {
	run fetch.route "https://www.bilibili.com/video/BV1xx411c7mD"
	assert_success
	[[ $output == "bilibili"$'\t'* ]]

	run fetch.route "https://www.bilibili.com/video/av170001"
	assert_success
	[[ $output == "bilibili"$'\t'* ]]

	run fetch.route "https://b23.tv/abc"
	assert_failure
}

@test "bilibili.search_url: URL 里没有 BV/av 号时报「不是合法的 B 站视频 URL」" {
	run bilibili.search_url "https://www.bilibili.com/"
	assert_failure
	assert_output --partial "不是合法的 B 站视频 URL"
}
