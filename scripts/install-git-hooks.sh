#!/bin/sh
set -eu
git config --local core.hooksPath .githooks
printf '%s\n' '已启用提交信息校验。'
