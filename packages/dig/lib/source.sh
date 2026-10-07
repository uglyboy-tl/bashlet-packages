#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016

# 源注册表：每个源在文件末尾调用 source.register 声明自己的静态属性。
#
# 只做「枚举 + 声明」。dig 的源是互不相同的取数器（HN 换不成 arXiv），不能互相替换，
# 所以这里**没有** auto_select / 能力协商 / failover —— 那是 imagine 的 provider 注册表
# 要解决的问题，对取数工具不成立。
#
# 源适配器契约（lib/sources/<源>.sh 必须提供）：
#   <源>.search    读 DIG_* 全局，写 JSONL 到 stdout
#   <源>.map       响应 JSON -> 条目对象流（纯函数，不触网，可离线测）
#   <源>.options   可选，声明该源特有参数
#   <源>.probe     可选，探活；0=ok 1=失败 2=网络不通 3=缺依赖，stdout 给一行说明
#
# source.register <名> <说明> <能力> <依赖命令>
#   能力形如 "tier:core period:yes proxy:no key:none"；依赖为空格分隔，可空。
#   机器可读的只有 period：写成具体窗口名时表示该源的默认窗口（如 period:pastyear，用户给的 -p 仍优先）；
#   写 yes/no 只表示「支持 / 不支持 -p」。tier（文档里的三层分组）与 proxy / key 供文档与测试读；
#   凭证不在注册表里，由该源的 <源>.probe / 取数函数直接读环境变量，并向用户报出缺什么。

import core/log

declare -ga _SOURCE_ORDER=()
declare -gA _SOURCE_DESC=() _SOURCE_CAPS=() _SOURCE_REQUIRES=() _SOURCE_URL_HOSTS=()

source.register() {
	local name="$1"
	[[ -n $name ]] || {
		log.error "source.register 缺少源名"
		return 1
	}
	_SOURCE_ORDER+=("$name")
	_SOURCE_DESC[$name]="${2:-}"
	_SOURCE_CAPS[$name]="${3:-}"
	_SOURCE_REQUIRES[$name]="${4:-}"
}

source.list() { printf '%s\n' "${_SOURCE_ORDER[@]}"; }

source.desc() { printf '%s' "${_SOURCE_DESC[$1]:-}"; }

source.requires() { printf '%s' "${_SOURCE_REQUIRES[$1]:-}"; }

# URL 直取的路由表：源声明自己认领哪些 host，fetch.route 只照着表比对。
# 多实例的源（discourse）不给静态清单，改写 <源>.url.hosts 函数动态提供。
source.url.register() {
	local src="$1"
	shift
	[[ -n $src && $# -gt 0 ]] || {
		log.error "source.url.register 需要 <源> <host...>"
		return 1
	}
	_SOURCE_URL_HOSTS[$src]="$*"
}

source.url.hosts() { printf '%s' "${_SOURCE_URL_HOSTS[$1]:-}"; }

# source.cap <名> <键> → 输出能力值，未声明返回 1
source.cap() {
	local caps=" ${_SOURCE_CAPS[$1]:-} " key="$2"
	[[ $caps == *" $key:"* ]] || return 1
	caps="${caps#* "$key":}"
	printf '%s' "${caps%% *}"
}
