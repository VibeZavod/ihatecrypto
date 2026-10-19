#!/bin/sh
# swift-format's rules, set in .swift-format. Its pretty printer's layout findings are left out:
# this code keeps its own layout (aligned arguments, long lines), and lint has no switch for them.
cd "$(dirname "$0")"
out=$(xcrun swift-format lint -r -p Package.swift Sources Tests 2>&1 | grep -vE '\[(Indentation|AddLines|RemoveLine|Spacing|TrailingComma|LineLength)\]')
[ -z "$out" ] || { echo "$out"; exit 1; }
