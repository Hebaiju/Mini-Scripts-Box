#!/bin/bash

# 进入当前目录（确保路径正确）
cd "$(dirname "$0")" || exit 1

# 1. 后台启动 all.sh（不阻塞，放后台）
./all.sh start all &

# 2. 前台启动 ttyd（保持前台，容器不退出）
chmod +x ./ttyd
env PATH="./bin:$PATH" ./ttyd --writable -p 12119 -c admin:123456 sh
