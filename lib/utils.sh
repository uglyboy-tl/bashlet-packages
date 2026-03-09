#!/usr/bin/env bash

import core/config

get_package_property() { config.array.get "packages" "$1" "$2"; }
