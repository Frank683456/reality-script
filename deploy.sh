#!/bin/bash
# 在自己电脑上运行：把 install.sh 传到服务器并打开（没装过＝安装，装过＝提示更新后进管理界面）
# 用法：bash deploy.sh root@服务器IP [安装选项，例如 --port 443]
#      也可以写 ~/.ssh/config 里的别名：bash deploy.sh my-vps
set -e
target=${1:?用法：bash deploy.sh root@服务器IP [安装选项]}
shift
dir=$(cd "$(dirname "$0")" && pwd)
args=''
(($#)) && args=$(printf ' %q' "$@")
scp -q "$dir/install.sh" "$target:/tmp/reality-install.sh"
ssh -t "$target" "bash /tmp/reality-install.sh$args; rc=\$?; rm -f /tmp/reality-install.sh; exit \$rc"
