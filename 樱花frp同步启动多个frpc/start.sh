#!/bin/sh
export TERM=dumb

# ===================== 隧道配置区 =====================
FRPC_DIR="./"
FRPC_BIN="frpc_linux_amd64"

# 格式：MC账号 本地端口 远程地址 frpc完整-f参数
# 已经加盐处理，自己替换下面的账号、端口、远程地址和密钥即可
# 适用于樱花frp
TUNNEL_INFO="
yg1sytwdyg1syt 25561   yt1yfbfdad.com:5974t1yfb    -f r9417btgbmzuhu09q7kmt3d4vfb6s7mf:27779315rb
kajpaermankajpae 25562   i9jfrp-use.com:13549s51j    -f 9g22c4tgbm7kmtf25xfu3d4vfb6s7mf:277793522c4
zws5crzws5cr 25563   md68wp-dad.com:117d68wm    -f c1cicdby3ohu6emz1pxlt8eu1x5w7i5wnaxsfm:2778018cicd
362o6g362o6g 25564   2lf6frp-fun.com:5042lf6qc    -f 9d8qxrby3emz1pxlt8eu1x5w7i5wnaxsfm:277889d8qxr
"
# ======================================================

FRPC_PIDS=""
TAIL_PID=""

# 停止所有进程
stop_all() {
    echo ""
    echo "正在关闭全部隧道进程..."
    kill $FRPC_PIDS $TAIL_PID 2>/dev/null
    wait $FRPC_PIDS $TAIL_PID 2>/dev/null
    pkill -9 -f "$FRPC_BIN" 2>/dev/null
    pkill -9 -f "tail -f frpc" 2>/dev/null
    echo "服务已全部停止，实例退出"
    exit 0
}

trap stop_all TERM

# 初始化清理
echo "【初始化】清理残留进程"
pkill -9 -f "$FRPC_BIN" 2>/dev/null
pkill -9 -f "tail -f frpc" 2>/dev/null
sleep 1

# 初始化日志文件
idx=1
echo "$TUNNEL_INFO" | while read acc lport raddr arg; do
    [ -z "$acc" ] && continue
    > "frpc${idx}.log"
    idx=$((idx + 1))
done

# 校验程序
BIN_PATH="./$FRPC_BIN"
if [ ! -f "$BIN_PATH" ]; then
    echo "❌ 错误：$FRPC_BIN 不存在"
    exit 1
fi
chmod +x "$BIN_PATH" 2>/dev/null

# 批量启动（精简输出，只打印编号+PID，去掉冗长详情）
echo ""
echo "【启动隧道】"
idx=1
echo "$TUNNEL_INFO" | while read acc lport raddr arg; do
    [ -z "$acc" ] && continue
    ./$FRPC_BIN $arg > frpc${idx}.log 2>&1 &
    pid=$!
    FRPC_PIDS="$FRPC_PIDS $pid"
    echo "隧道$idx PID:$pid | $acc"
    sleep 0.3
    idx=$((idx + 1))
done

sleep 2

# 精简汇总面板，无多余文字
echo ""
echo "======================================"
echo "✅ 4条隧道启动完成 | 隧道清单"
echo "======================================"
printf "%-10s %-8s %-22s %s\n" "账号" "本地端口" "远程地址" "密钥"
echo "$TUNNEL_INFO" | while read acc lport raddr arg; do
    [ -z "$acc" ] && continue
    printf "%-10s %-8s %-22s %s\n" "$acc" "$lport" "$raddr" "$arg"
done
echo "======================================"
echo "指令：1/2/3/4查看对应日志 | quit关闭日志 | ps进程列表 | stop停止全部"
echo "======================================"

# 主交互循环
while true; do
    printf "\n[FRP管理] > "
    read cmd
    cmd=$(echo "$cmd" | tr '[:upper:]' '[:lower:]')
    case "$cmd" in
        1|log1)
            [ -n "$TAIL_PID" ] && kill $TAIL_PID 2>/dev/null
            echo "=== wddwwb 隧道日志 ==="
            tail -f frpc1.log & TAIL_PID=$!
            echo "输入 quit 关闭日志"
            ;;
        2|log2)
            [ -n "$TAIL_PID" ] && kill $TAIL_PID 2>/dev/null
            echo "=== superman 隧道日志 ==="
            tail -f frpc2.log & TAIL_PID=$!
            echo "输入 quit 关闭日志"
            ;;
        3|log3)
            [ -n "$TAIL_PID" ] && kill $TAIL_PID 2>/dev/null
            echo "=== nike 隧道日志 ==="
            tail -f frpc3.log & TAIL_PID=$!
            echo "输入 quit 关闭日志"
            ;;
        4|log4)
            [ -n "$TAIL_PID" ] && kill $TAIL_PID 2>/dev/null
            echo "=== G3G2G4G3443 隧道日志 ==="
            tail -f frpc4.log & TAIL_PID=$!
            echo "输入 quit 关闭日志"
            ;;
        quit)
            if [ -n "$TAIL_PID" ]; then
                kill $TAIL_PID 2>/dev/null
                TAIL_PID=""
                echo "日志输出已关闭"
            else
                echo "当前无日志输出"
            fi
            ;;
        ps)
            echo "=== 运行进程 ==="
            ps aux | grep -E "$FRPC_BIN|tail" | grep -v grep
            ;;
        stop|exit)
            stop_all
            ;;
        "") continue ;;
        *) echo "无效指令" ;;
    esac
done