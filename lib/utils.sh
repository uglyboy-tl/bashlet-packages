#!/usr/bin/env bash

import std/ansi
import std/console
import std/system
import core/config

UNDERLINE_CACHE=$(console.repeat "=" 20)

title.format() {
	console.stdout "$1:"
	console.stdout "=${UNDERLINE_CACHE:0:$(console.mixed_width $1)}"
}

item.format() {
	local level=$1
	console.align $(( ${level}*2 )) "" "${*:2}"
}

get_package_property() { echo "$(config.array.get "packages" "$1" "$2")"; }
