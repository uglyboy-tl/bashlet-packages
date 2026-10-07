#!/usr/bin/env bats

# lib/sources/wechat.sh：只按 URL 取的源（正文能力来自 lib/browser.sh）。
# 离线测：桩掉 browser.page，URL 解析与条目映射都是纯函数。

load 'test_helper/common-setup'
load 'setup.bash'

setup() {
	_dig_setup
}

@test "wechat.url.id: 短链取 /s/<id>，长链取 mid_idx，认不出返回 1" {
	run wechat.url.id "https://mp.weixin.qq.com/s/AWnQL3forAP-gB7e2ZEXdQ"
	assert_success
	assert_output "AWnQL3forAP-gB7e2ZEXdQ"

	run wechat.url.id "https://mp.weixin.qq.com/s?__biz=MzI2&mid=2247492463&idx=2&sn=abc"
	assert_success
	assert_output "2247492463_2"

	run wechat.url.id "https://mp.weixin.qq.com/"
	assert_failure
}

@test "wechat.url.clean: 去掉会话噪声 poc_token，保留定位文章的参数" {
	run wechat.url.clean "https://mp.weixin.qq.com/s/ABC?poc_token=xyz"
	assert_output "https://mp.weixin.qq.com/s/ABC"

	run wechat.url.clean "https://mp.weixin.qq.com/s?__biz=MzI2&mid=1&idx=1&sn=a&poc_token=t"
	assert_output "https://mp.weixin.qq.com/s?__biz=MzI2&mid=1&idx=1&sn=a"
}

@test "wechat.map: browser.page 的字段进条目形状，id 用文章号" {
	run wechat.map "https://mp.weixin.qq.com/s/ABC" <<< '{"title":"标题","author":"公众号","description":"d","text":"正文"}'
	assert_success
	assert_jq '[.source, .id, .title, .author, .text, .created_at]'
	assert_output '["wechat","ABC","标题","公众号","正文",""]'
}

@test "wechat.search_url: 走 browser.page，产物过 map" {
	browser.page() { printf '%s' '{"title":"标题","author":"公众号","description":"","text":"正文"}'; }
	DIG_LIMIT=5 DIG_QUERY="" run wechat.search_url "https://mp.weixin.qq.com/s/ABC"
	assert_success
	assert_output --partial '"source":"wechat"'
	assert_output --partial '"title":"标题"'
	assert_output --partial '"id":"ABC"'
}

@test "wechat.search_url: 缺凭证时报清楚缺什么" {
	CLOUDFLARE_ACCOUNT_ID="" CLOUDFLARE_API_TOKEN="" DIG_LIMIT=5 run wechat.search_url "https://mp.weixin.qq.com/s/ABC"
	assert_failure
	assert_output --partial "Cloudflare Browser Run"
}

@test "wechat.search: 没有检索分支，并指出该怎么做" {
	run wechat.search
	assert_failure
	assert_output --partial "没有公开检索接口"
	assert_output --partial "dig fetch"
}
