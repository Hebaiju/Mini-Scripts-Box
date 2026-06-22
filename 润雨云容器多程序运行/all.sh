#!/bin/bash
set -euo pipefail

# ---------- 配置区 ----------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
SELF="$0"

# 服务名 -> 子目录名
declare -A app=(
["nike"]="nike"
["WDDWWB"]="WDDWWB"
["hebaiju"]="hebaiju"
["liveou"]="liveou"
["superman"]="superman"
)

# 自启动列表（会自动保存回脚本）
AUTO_START=(
WDDWWB
)

# ---------- 保存自启动配置到脚本自身 ----------
save_auto_start() {
    local tempfile=$(mktemp)
    local in_block=false
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "AUTO_START=(" ]]; then
            echo "$line" >> "$tempfile"
            in_block=true
            for item in "${AUTO_START[@]}"; do
                echo "$item" >> "$tempfile"
            done
            echo ")" >> "$tempfile"
            continue
        fi
        if [[ "$in_block" == true ]]; then
            if [[ "$line" == ")" ]]; then
                in_block=false
            fi
            continue
        fi
        echo "$line" >> "$tempfile"
    done < "$SELF"
    
    mv "$tempfile" "$SELF" 2>/dev/null || { rm -f "$tempfile"; return 1; }
    chmod +x "$SELF" 2>/dev/null
    return 0
}

in_auto_list() {
    local name="$1"
    for item in "${AUTO_START[@]}"; do
        [ "$item" = "$name" ] && return 0
    done
    return 1
}

# ---------- 精准检测进程（兼容极简系统，不依赖 pgrep） ----------
cmdline_matches_service() {
    local pid="$1"
    local name="$2"
    local arg=""
    local first=""
    local second=""
    local third=""
    local prev=""
    local index=0
    local found_name=1

    [ -r "/proc/$pid/cmdline" ] || return 1

    while IFS= read -r -d '' arg || [ -n "$arg" ]; do
        case "$index" in
            0) first="$arg" ;;
            1) second="$arg" ;;
            2) third="$arg" ;;
        esac

        if [ "$prev" = "--name" ] && [ "$arg" = "$name" ]; then
            found_name=0
        fi

        prev="$arg"
        index=$((index + 1))
    done < "/proc/$pid/cmdline"

    [ "$index" -gt 0 ] || return 1

    case "$first" in
        java|*/java) ;;
        *) return 1 ;;
    esac

    [ "$second" = "-jar" ] || return 1

    case "$third" in
        ZenithProxy.jar|*/ZenithProxy.jar) ;;
        *) return 1 ;;
    esac

    [ "$found_name" -eq 0 ]
}

get_pid() {
    local name="$1"
    local proc=""
    local pid=""

    for proc in /proc/[0-9]*; do
        [ -d "$proc" ] || continue
        pid="${proc##*/}"

        if cmdline_matches_service "$pid" "$name"; then
            echo "$pid"
        fi
    done

    return 0
}

is_running() {
    local name="$1"
    local pid=""

    while IFS= read -r pid; do
        [ -n "$pid" ] && return 0
    done < <(get_pid "$name")

    return 1
}

service_dir() {
    local name="$1"
    printf '%s/%s\n' "$SCRIPT_DIR" "${app[$name]}"
}

service_log_path() {
    local name="$1"
    printf '%s/%s.log\n' "$(service_dir "$name")" "$name"
}

service_fifo_path() {
    local name="$1"
    printf '%s/.%s.stdin\n' "$(service_dir "$name")" "$name"
}

service_keeper_pid_path() {
    local name="$1"
    printf '%s/.%s.stdin.keep.pid\n' "$(service_dir "$name")" "$name"
}

pid_is_alive() {
    local pid="${1:-}"
    [ -n "$pid" ] && [ -d "/proc/$pid" ]
}

is_console_managed() {
    local name="$1"
    [ -p "$(service_fifo_path "$name")" ]
}

ensure_console_runtime() {
    local name="$1"
    local fifo=""
    local pid_file=""
    local pid=""

    fifo=$(service_fifo_path "$name")
    pid_file=$(service_keeper_pid_path "$name")

    if [ ! -p "$fifo" ]; then
        rm -f "$fifo"
        mkfifo "$fifo"
    fi

    if [ -f "$pid_file" ]; then
        read -r pid < "$pid_file" || true
        if pid_is_alive "$pid"; then
            return 0
        fi
        rm -f "$pid_file"
    fi

    nohup sh -c 'exec 3<>"$1"; while true; do sleep 3600; done' sh "$fifo" >/dev/null 2>&1 &
    echo "$!" > "$pid_file"
    return 0
}

cleanup_console_runtime() {
    local name="$1"
    local fifo=""
    local pid_file=""
    local pid=""

    fifo=$(service_fifo_path "$name")
    pid_file=$(service_keeper_pid_path "$name")

    if [ -f "$pid_file" ]; then
        read -r pid < "$pid_file" || true
        if pid_is_alive "$pid"; then
            kill "$pid" 2>/dev/null || true
            sleep 1
            if pid_is_alive "$pid"; then
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$pid_file"
    fi

    rm -f "$fifo"
    return 0
}

# ---------- 启动单个服务 ----------
start_service() {
    local name="$1"
    if [ -z "${app[$name]-}" ]; then
        echo "❌ 无效服务：$name"
        return 1
    fi

    if is_running "$name"; then
        if is_console_managed "$name"; then
            echo "ℹ️ $name 已经在运行"
        else
            echo "ℹ️ $name 已在运行（非控制台桥接模式）"
            echo "   如需重新进入控制台，请先停止后再用 all.sh 启动"
        fi
        return 0
    fi

    local service_path=""
    local fifo=""
    local log_file=""

    service_path=$(service_dir "$name")
    fifo=$(service_fifo_path "$name")
    log_file=$(service_log_path "$name")

    echo "→ 启动 $name"
    touch "$log_file"
    ensure_console_runtime "$name"
    nohup sh -c 'cd "$1" && exec java -jar ZenithProxy.jar --name "$2" <"$3" >>"$4" 2>&1' sh "$service_path" "$name" "$fifo" "$log_file" >/dev/null 2>&1 &
    sleep 1

    if is_running "$name"; then
        echo "✅ $name 已启动"
        return 0
    fi

    cleanup_console_runtime "$name"
    echo "❌ $name 启动失败，请查看日志"
    return 1
}

# ---------- 停止单个服务 ----------
stop_service() {
    local name="$1"
    if [ -z "${app[$name]-}" ]; then
        echo "❌ 无效服务：$name"
        return 1
    fi

    local pids=()
    local pid=""

    while IFS= read -r pid; do
        [ -n "$pid" ] && pids+=("$pid")
    done < <(get_pid "$name")

    if [ "${#pids[@]}" -eq 0 ]; then
        echo "ℹ️ $name 未运行"
        cleanup_console_runtime "$name"
        return 0
    fi

    echo "→ 停止 $name (PID:${pids[*]})"
    kill "${pids[@]}"
    sleep 1
    if is_running "$name"; then
        kill -9 "${pids[@]}"
        echo "⚠️ 强制停止 $name"
    fi

    cleanup_console_runtime "$name"
    echo "✅ $name 已停止"
    return 0
}

# ---------- 交互式启动 ----------
interactive_start() {
    /usr/bin/clear
    echo
    echo "╔══════════════════════════════════════╗"
    echo "║            启动服务                 ║"
    echo "╚══════════════════════════════════════╝"
    echo
    
    # 构建服务列表（包含状态）
    local services=()
    local display_options=("返回")
    
    for svc in "${!app[@]}"; do
        services+=("$svc")
        if is_running "$svc"; then
            display_options+=("$svc (🟢 运行中)")
        else
            display_options+=("$svc (🔴 已停止)")
        fi
    done
    
    PS3="请选择: "
    select opt in "${display_options[@]}" "all - 启动所有"; do
        if [[ "$REPLY" == "q" ]] || [[ -z "$REPLY" ]]; then
            return 0
        fi
        
        case "$opt" in
            "返回")
                break
                ;;
            "all - 启动所有")
                start_all
                break
                ;;
            "")
                echo "❌ 无效选择"
                ;;
            *)
                # 提取服务名（去掉括号内的状态）
                local name=$(echo "$opt" | sed 's/ (.*)$//')
                if [[ " ${services[*]} " == *" $name "* ]]; then
                    start_service "$name"
                    break
                else
                    echo "❌ 无效选择"
                fi
                ;;
        esac
    done
}

# ---------- 交互式停止 ----------
interactive_stop() {
    /usr/bin/clear
    echo
    echo "╔══════════════════════════════════════╗"
    echo "║            停止服务                 ║"
    echo "╚══════════════════════════════════════╝"
    echo
    
    # 构建服务列表（包含状态）
    local services=()
    local display_options=("返回")
    
    for svc in "${!app[@]}"; do
        services+=("$svc")
        if is_running "$svc"; then
            display_options+=("$svc (🟢 运行中)")
        else
            display_options+=("$svc (🔴 已停止)")
        fi
    done
    
    PS3="请选择: "
    select opt in "${display_options[@]}" "all - 停止所有"; do
        if [[ "$REPLY" == "q" ]] || [[ -z "$REPLY" ]]; then
            return 0
        fi
        
        case "$opt" in
            "返回")
                break
                ;;
            "all - 停止所有")
                stop_all
                break
                ;;
            "")
                echo "❌ 无效选择"
                ;;
            *)
                # 提取服务名（去掉括号内的状态）
                local name=$(echo "$opt" | sed 's/ (.*)$//')
                if [[ " ${services[*]} " == *" $name "* ]]; then
                    stop_service "$name"
                    break
                else
                    echo "❌ 无效选择"
                fi
                ;;
        esac
    done
}

# ---------- 启动所有自启动服务 ----------
start_all() {
    echo "==== 启动所有自启动服务 ===="
    local count=0
    for name in "${AUTO_START[@]}"; do
        if [ $count -gt 0 ]; then
            echo -n "⏳ 等待下一个服务启动: "
            for i in {10..1}; do
                echo -n "$i "
                /usr/bin/sleep 1
            done
            echo
        fi
        start_service "$name"
        count=$((count + 1))
    done
}

# ---------- 停止所有服务 ----------
stop_all() {
    echo "==== 停止所有服务 ===="
    for name in "${!app[@]}"; do
        stop_service "$name"
    done
}

# ---------- 切换自启动 ----------
toggle_auto() {
    local name="$1"
    
    # 如果提供了参数，直接切换单个服务
    if [ -n "$name" ]; then
        if [ -z "${app[$name]-}" ]; then
            echo "❌ 无效服务：$name"
            echo "   可用服务：${!app[*]}"
            return 1
        fi

        if in_auto_list "$name"; then
            AUTO_START=($(for i in "${AUTO_START[@]}"; do [ "$i" != "$name" ] && echo "$i"; done))
            echo "✅ $name 已启用 → ❌ $name 已禁用"
        else
            AUTO_START=("${AUTO_START[@]}" "$name")
            echo "❌ $name 已禁用 → ✅ $name 已启用"
        fi

        if save_auto_start; then
            echo "✅ 配置已保存"
        else
            echo "⚠️ 配置保存失败"
        fi
        return 0
    fi

    # 无参数时，进入交互式选择模式
    /usr/bin/clear
    echo
    echo "╔══════════════════════════════════════╗"
    echo "║          自启动管理                 ║"
    echo "╚══════════════════════════════════════╝"
    echo
    
    # 显示所有服务列表（包含状态）
    local services=()
    local display_options=("返回")
    
    for svc in "${!app[@]}"; do
        services+=("$svc")
        if in_auto_list "$svc"; then
            display_options+=("$svc (✅ 自启动)")
        else
            display_options+=("$svc (❌ 禁用)")
        fi
    done
    
    PS3="请选择: "
    select opt in "${display_options[@]}"; do
        if [[ "$REPLY" == "q" ]] || [[ -z "$REPLY" ]]; then
            return 0
        fi
        
        case "$opt" in
            "返回")
                break
                ;;
            "")
                echo "❌ 无效选择"
                ;;
            *)
                # 提取服务名（去掉括号内的状态）
                local name=$(echo "$opt" | sed 's/ (.*)$//')
                if [[ " ${services[*]} " == *" $name "* ]]; then
                    # 执行切换
                    if in_auto_list "$name"; then
                        AUTO_START=($(for i in "${AUTO_START[@]}"; do [ "$i" != "$name" ] && echo "$i"; done))
                        echo "✅ $name 已启用 → ❌ $name 已禁用"
                    else
                        AUTO_START=("${AUTO_START[@]}" "$name")
                        echo "❌ $name 已禁用 → ✅ $name 已启用"
                    fi

                    if save_auto_start; then
                        echo "✅ 配置已保存"
                    else
                        echo "⚠️ 配置保存失败"
                    fi
                    break
                else
                    echo "❌ 无效选择"
                fi
                ;;
        esac
    done
}

# ---------- 查看日志 ----------
log_service() {
    local name="$1"
    
    # 无参数时进入交互式选择
    if [ -z "$name" ]; then
        /usr/bin/clear
        echo
        echo "╔══════════════════════════════════════╗"
        echo "║            查看日志                 ║"
        echo "╚══════════════════════════════════════╝"
        echo
        
        local services=()
        for svc in "${!app[@]}"; do
            services+=("$svc")
        done
        
        PS3="请选择 (1-$(( ${#services[@]} + 1 ))): "
        select opt in "返回" "${services[@]}"; do
            if [[ "$REPLY" == "q" ]] || [[ -z "$REPLY" ]]; then
                return 0
            fi
            
            case "$opt" in
                "返回")
                    break
                    ;;
                "")
                    echo "❌ 无效选择"
                    ;;
                *)
                    name="$opt"
                    if [[ " ${services[*]} " == *" $name "* ]]; then
                        break
                    else
                        echo "❌ 无效选择"
                    fi
                    ;;
            esac
        done
        
        [[ -z "$name" ]] && return 0
        [[ "$name" == "返回" ]] && return 0
    fi
    
    if [ -z "${app[$name]-}" ]; then
        echo "❌ 无效服务：$name"
        return 1
    fi

    local log_file=""
    log_file=$(service_log_path "$name")
    touch "$log_file"

    /usr/bin/clear
    echo
    echo "╔══════════════════════════════════════╗"
    echo "║        $name 日志                 ║"
    echo "╚══════════════════════════════════════╝"
    echo "[Ctrl+C 退出查看]"
    echo
    tail -f "$log_file"
}

# ---------- 进入控制台 ----------
console_service() {
    local name="$1"

    if [ -z "$name" ]; then
        /usr/bin/clear
        echo
        echo "╔══════════════════════════════════════╗"
        echo "║          进入服务控制台             ║"
        echo "╚══════════════════════════════════════╝"
        echo

        local services=()
        local display_options=("返回")

        for svc in "${!app[@]}"; do
            services+=("$svc")
            if is_running "$svc"; then
                display_options+=("$svc (🟢 运行中)")
            else
                display_options+=("$svc (🔴 已停止)")
            fi
        done

        PS3="请选择: "
        select opt in "${display_options[@]}"; do
            if [[ "$REPLY" == "q" ]] || [[ -z "$REPLY" ]]; then
                return 0
            fi

            case "$opt" in
                "返回")
                    return 0
                    ;;
                "")
                    echo "❌ 无效选择"
                    ;;
                *)
                    local selected_name=""
                    selected_name=$(echo "$opt" | sed 's/ (.*)$//')
                    if [[ " ${services[*]} " == *" $selected_name "* ]]; then
                        name="$selected_name"
                        break
                    else
                        echo "❌ 无效选择"
                    fi
                    ;;
            esac
        done
    fi

    if [ -z "${app[$name]-}" ]; then
        echo "❌ 无效服务：$name"
        return 1
    fi

    if ! is_running "$name"; then
        echo "❌ $name 未运行"
        return 1
    fi

    if ! is_console_managed "$name"; then
        echo "❌ $name 当前不是通过 all.sh 控制台模式启动"
        echo "   请先停止该服务，再通过 all.sh 重新启动"
        return 1
    fi

    local fifo=""
    local log_file=""
    local tail_pid=""
    local cmd=""
    local read_status=0

    fifo=$(service_fifo_path "$name")
    log_file=$(service_log_path "$name")

    touch "$log_file"
    ensure_console_runtime "$name"

    /usr/bin/clear
    echo
    echo "╔══════════════════════════════════════╗"
    echo "║        $name 控制台桥接            ║"
    echo "╚══════════════════════════════════════╝"
    echo "输入命令后回车发送，输入 /exit 返回主菜单"
    echo

    tail -n 30 -f "$log_file" &
    tail_pid=$!
    trap 'echo; echo "请输入 /exit 返回主菜单"' INT

    while true; do
        printf "\n[%s] console> " "$name"
        IFS= read -r cmd
        read_status=$?

        if [ "$read_status" -ne 0 ]; then
            if [ "$read_status" -eq 130 ]; then
                continue
            fi
            break
        fi

        case "$cmd" in
            "" )
                continue
                ;;
            /exit|exit|quit)
                break
                ;;
            *)
                if ! is_running "$name"; then
                    echo
                    echo "⚠️ $name 已停止，退出控制台"
                    break
                fi

                if ! printf '%s\n' "$cmd" > "$fifo"; then
                    echo
                    echo "⚠️ 命令发送失败，退出控制台"
                    break
                fi
                ;;
        esac
    done

    trap - INT
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true
    echo
    echo "↩ 已返回主菜单"
    echo "按任意键继续..."
    read -n 1 -s -r
}

# ---------- 显示状态 ----------
show() {
    local name=""
    local run=""
    local status=""
    local auto=""
    local console=""

    echo
    echo "╔══════════════════════════════════════╗"
    echo "║           服务状态总览               ║"
    echo "╚══════════════════════════════════════╝"
    echo
    for name in "${!app[@]}"; do
        if is_running "$name"; then
            run="🟢"
            status="运行中"
            if is_console_managed "$name"; then
                console="✅"
            else
                console="❌"
            fi
        else
            run="🔴"
            status="已停止"
            console="-"
        fi
        if in_auto_list "$name"; then
            auto="✅"
        else
            auto="❌"
        fi
        printf "  $run %-10s %-8s (自启动：$auto 控制台：$console)\n" "$name" "$status"
    done
    echo
}

# ---------- 帮助信息 ----------
show_help() {
    cat <<EOF
使用方式：
  $0                    # 进入交互模式
  $0 <命令> [参数]       # 命令行模式

==== 命令行模式 ====
  $0 s                  # 查看所有服务状态
  $0 start all          # 启动所有自启动服务
  $0 start <服务名>     # 启动单个服务
  $0 stop all           # 停止所有服务
  $0 stop <服务名>      # 停止单个服务
  $0 auto <服务名>      # 切换自启动状态
  $0 log <服务名>       # 查看服务日志
  $0 console <服务名>   # 进入服务控制台

==== 交互模式菜单 ====
  1. start          启动服务
  2. stop           停止服务
  3. auto           自启动管理
  4. log            查看日志
  5. console        进入服务控制台
  6. q              退出

  Ctrl+C         退出日志查看
  /exit          退出控制台桥接
EOF
}

# ---------- 命令执行 ----------
execute() {
    local cmd="${1:-}"
    local arg="${2:-}"

    case "$cmd" in
        s|"")
            show
            ;;
        start)
            if [ -z "$arg" ]; then
                # 无参数时进入交互模式（仅在交互模式下）
                interactive_start || true
            elif [ "$arg" = "all" ]; then
                # 命令行模式：直接启动所有
                start_all
            else
                # 命令行模式：启动单个服务
                start_service "$arg"
            fi
            ;;
        stop)
            if [ -z "$arg" ]; then
                # 无参数时进入交互模式（仅在交互模式下）
                interactive_stop || true
            elif [ "$arg" = "all" ]; then
                # 命令行模式：直接停止所有
                stop_all
            else
                # 命令行模式：停止单个服务
                stop_service "$arg"
            fi
            ;;
        auto)
            if [ -z "$arg" ]; then
                # 无参数时进入交互模式
                toggle_auto "" || true
            else
                # 命令行模式：切换单个服务
                toggle_auto "$arg"
            fi
            ;;
        log)
            if [ -z "$arg" ]; then
                # 无参数时进入交互模式
                log_service "" || true
            else
                # 命令行模式：查看单个服务日志
                log_service "$arg"
            fi
            ;;
        console|enter)
            if [ -z "$arg" ]; then
                console_service "" || true
            else
                console_service "$arg"
            fi
            ;;
        help|"?")
            show_help
            ;;
        q|quit|exit)
            echo "再见！"
            exit 0
            ;;
        *)
            if [ -n "$cmd" ]; then
                echo "❌ 未知命令：$cmd"
            fi
            show_help
            return 1
            ;;
    esac
}

# ---------- 交互模式 ----------
interactive() {
    while true; do
        /usr/bin/clear
        echo "==== 服务管理控制台 ===="
        show
        
        # 显示命令菜单
        echo
        echo "╔══════════════════════════════════════╗"
        echo "║            命令菜单                 ║"
        echo "╠══════════════════════════════════════╣"
        echo "║  1) start          启动服务           ║"
        echo "║  2) stop           停止服务           ║"
        echo "║  3) auto           自启动管理         ║"
        echo "║  4) log            查看日志           ║"
        echo "║  5) console        进入服务控制台     ║"
        echo "║  6) q              退出               ║"
        echo "╚══════════════════════════════════════╝"
        echo
        
        PS3="请选择操作 (1-6): "
        select opt in "启动服务" "停止服务" "自启动管理" "查看日志" "进入服务控制台" "退出"; do
            case "$REPLY" in
                1)
                    interactive_start || true
                    break
                    ;;
                2)
                    interactive_stop || true
                    break
                    ;;
                3)
                    toggle_auto "" || true
                    break
                    ;;
                4)
                    log_service "" || true
                    break
                    ;;
                5)
                    console_service "" || true
                    break
                    ;;
                6)
                    echo "再见！"
                    return 0
                    ;;
                q)
                    echo "再见！"
                    return 0
                    ;;
                *)
                    echo "❌ 无效选择: $REPLY"
                    echo "按任意键继续..."
                    read -n 1 -s -r
                    break
                    ;;
            esac
        done
    done
}

# ---------- 主逻辑 ----------
if [ $# -gt 0 ]; then
    execute "$@"
else
    interactive
fi
