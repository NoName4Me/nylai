#!/bin/sh
set -eu

subject=$(head -n 1 "$1")
if ! printf '%s\n' "$subject" | LC_ALL=C grep -Eq '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-zA-Z0-9_. /-]+\))?!?: [^[:space:]].*$'; then
    printf '%s\n' '提交信息必须使用 type(scope): 描述，例如 feat: 完善剪贴板分组' >&2
    exit 1
fi
