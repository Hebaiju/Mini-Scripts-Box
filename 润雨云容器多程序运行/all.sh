#!/bin/bash
set -euo pipefail

# ========== 环境适配（MCMS面板终端） ==========
# 设置默认TERM，避免clear命令报错
export TERM=${TERM:-xterm}

# 清屏函数：混合方式，先空行顶出旧内容，再光标上移，菜单从顶部开始
cls() {
    local i
    for ((i=0; i<30; i++)); do
        echo
    done
    printf '\033[30A'
}

# 放宽错误处理，避免MCMS环境下意外退出
set +e

# ---------- 配置区 ----------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
SELF="$0"

# ============================================================
# 服务配置（纯Bash块式，1:1复刻JSON风格）
# ============================================================
# 服务配置说明（# 开头的是注释，不影响运行）
# ============================================================
# name         - 服务名（唯一标识，英文/数字/下划线，不要有空格）
# exec_file    - 可执行文件的完整文件名
# work_dir     - 工作目录（脚本同级的子文件夹名，不是完整路径）
# exec_type    - 运行类型：java / python / binary，留空则自动根据后缀识别
# exec_command - 自定义完整启动命令，留空则自动生成标准命令
# auto_start   - 是否自启动：true / false
# ============================================================
# 添加新服务：复制下面任意一个服务块，修改内容即可
# 脚本会自动发现所有 SERVICE_ 开头的配置，无需手动添加到列表
# ============================================================

# 服务1
# ============================================================
# 服务1：wddwwb 隧道（端口25561）
# ============================================================
SERVICE_1=(
  'name: "wddwwb-25561"'
  'exec_file: "frpc_linux_amd64"'
  'work_dir: "frpc1"'
  'exec_type: "binary"'
  'exec_command: "./frpc_linux_amd64 -f "'
  'auto_start: "true"'
)

# ============================================================
# 服务自动发现与初始化
# ============================================================

# 全局变量：服务数量和服务索引列表
SERVICE_COUNT=0
SERVICE_INDEXES=()

# 自动发现所有服务配置
discover_services() {
    SERVICE_COUNT=0
    SERVICE_INDEXES=()
    
    local i=1
    while true; do
        local var_name="SERVICE_${i}"
        # 检查这个变量是否存在（是一个数组）
        if declare -p "$var_name" 2>/dev/null | grep -q 'declare -a'; then
            SERVICE_INDEXES+=("$i")
            SERVICE_COUNT=$((SERVICE_COUNT + 1))
            i=$((i + 1))
        else
            break
        fi
    done
}

# 从服务配置块中提取字段值
get_service_field_by_idx() {
    local idx="$1"
    local field="$2"
    
    local var_name="SERVICE_${idx}"
    local -n service_arr="$var_name"
    
    local line=""
    for line in "${service_arr[@]}"; do
        # 提取字段名和值（格式：'field: "value"'）
        local key="${line%%:*}"
        local value="${line#*: }"
        # 去掉可能的注释
        value="${value%%#*}"
        # 去掉首尾空格
        value="$(echo -e "${value}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        # 去掉首尾的双引号
        value="${value#\"}"
        value="${value%\"}"
        
        if [ "$key" = "$field" ]; then
            echo "$value"
            return 0
        fi
    done
    
    echo ""
    return 1
}


# 初始化：发现服务
discover_services

# ---------- 配置读取函数 ----------

# 获取所有服务名（按顺序输出）
get_service_names() {
    local i=0
    for ((i=0; i<SERVICE_COUNT; i++)); do
        local idx="${SERVICE_INDEXES[$i]}"
        get_service_field_by_idx "$idx" "name"
    done
}

# 根据服务名获取索引（返回在SERVICE_INDEXES中的位置，0-based）
get_service_pos() {
    local name="$1"
    local i=0
    for ((i=0; i<SERVICE_COUNT; i++)); do
        local idx="${SERVICE_INDEXES[$i]}"
        local sname=$(get_service_field_by_idx "$idx" "name")
        if [ "$sname" = "$name" ]; then
            echo "$i"
            return 0
        fi
    done
    echo "-1"
    return 1
}

# 获取服务指定字段
get_service_field() {
    local name="$1"
    local field="$2"
    local pos=$(get_service_pos "$name")
    
    if [ "$pos" = "-1" ]; then
        echo ""
        return 1
    fi
    
    local idx="${SERVICE_INDEXES[$pos]}"
    get_service_field_by_idx "$idx" "$field"
}

# 检查服务是否存在
service_exists() {
    local name="$1"
    local pos=$(get_service_pos "$name")
    [ "$pos" != "-1" ]
}

# 检查是否在自启动列表中
in_auto_list() {
    local name="$1"
    local val=$(get_service_field "$name" "auto_start")
    [ "$val" = "True" ] || [ "$val" = "true" ]
}

# 获取服务工作目录（完整路径）
service_dir() {
    local name="$1"
    local dir=$(get_service_field "$name" "work_dir")
    printf '%s/%s\n' "$SCRIPT_DIR" "$dir"
}

# 获取可执行文件名
service_exec_file() {
    local name="$1"
    get_service_field "$name" "exec_file"
}

# 获取执行类型（java/python/binary）
service_exec_type() {
    local name="$1"
    local type=""
    type=$(get_service_field "$name" "exec_type")
    if [ -z "$type" ]; then
        local file=""
        file=$(service_exec_file "$name")
        case "$file" in
            *.jar) echo "java" ;;
            *.py) echo "python" ;;
            *) echo "binary" ;;
        esac
    else
        echo "$type"
    fi
}

# 获取自定义启动命令
service_exec_command() {
    local name="$1"
    get_service_field "$name" "exec_command"
}

# 生成启动命令
build_start_command() {
    local name="$1"
    local custom_cmd=""
    custom_cmd=$(service_exec_command "$name")
    
    if [ -n "$custom_cmd" ]; then
        echo "$custom_cmd"
        return 0
    fi
    
    local exec_type=""
    local exec_file=""
    exec_type=$(service_exec_type "$name")
    exec_file=$(service_exec_file "$name")
    
    case "$exec_type" in
        java)
            echo "java -jar $exec_file --name $name"
            ;;
        python)
            echo "python3 $exec_file"
            ;;
        binary)
            echo "./$exec_file"
            ;;
        *)
            echo "./$exec_file"
            ;;
    esac
}

# ---------- 全局stop处理函数 ----------
# 任何界面收到stop指令都调用此函数
handle_global_stop() {
    echo
    echo "收到停止命令，正在停止所有服务..."
    stop_all
    echo "所有服务已停止，退出"
    exit 0
}

# 检查输入是否为stop指令，如果是则处理
check_stop() {
    local input="$1"
    if [ "$input" = "stop" ]; then
        handle_global_stop
        return 0
    fi
    return 1
}

# ---------- 通用进程检测 ----------
cmdline_matches_service() {
    local pid="$1"
    local name="$2"
    local env_line=""
    
    [ -r "/proc/$pid/environ" ] || return 1
    
    while IFS= read -r -d '' env_line || [ -n "$env_line" ]; do
        if [ "$env_line" = "ALLSH_SERVICE_NAME=$name" ]; then
            return 0
        fi
    done < "/proc/$pid/environ"
    
    return 1
}

# 获取服务的所有PID（最优方案：关键词过滤 + 环境变量验证）
get_pid() {
    local name="$1"
    local exec_file=$(get_service_field "$name" "exec_file")
    local pid=""
    
    # 第一步：用pgrep快速过滤出可能的进程（过滤掉99%不相关的进程）
    for pid in $(pgrep -f "$exec_file" 2>/dev/null); do
        # 第二步：用环境变量精确验证（只验证过滤后的少数进程）
        if cmdline_matches_service "$pid" "$name"; then
            echo "$pid"
        fi
    done
    return 0
}

# 检查服务是否正在运行
is_running() {
    local name="$1"
    local pid=""
    while IFS= read -r pid; do
        [ -n "$pid" ] && return 0
    done < <(get_pid "$name")
    return 1
}

# ---------- 控制台桥接相关路径 ----------

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
    
    if ! service_exists "$name"; then
        echo "❌ 无效服务：$name"
        return 1
    fi
    
    if is_running "$name"; then
        if is_console_managed "$name"; then
            echo "ℹ️ $name 已经在运行"
        else
            echo "ℹ️ $name 已在运行（非控制台桥接模式）"
        fi
        return 0
    fi
    
    local service_path=""
    local fifo=""
    local log_file=""
    local start_cmd=""
    service_path=$(service_dir "$name")
    fifo=$(service_fifo_path "$name")
    log_file=$(service_log_path "$name")
    start_cmd=$(build_start_command "$name")
    
    echo "→ 启动 $name"
    echo "  命令: $start_cmd"
    
    touch "$log_file"
    ensure_console_runtime "$name"
    
    nohup sh -c 'cd "$1" && ALLSH_SERVICE_NAME="$2" exec $3 <"$4" >>"$5" 2>&1' \
        sh "$service_path" "$name" "$start_cmd" "$fifo" "$log_file" >/dev/null 2>&1 &
    
    local max_wait=5
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if is_running "$name"; then
            echo "✅ $name 已启动"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    
    cleanup_console_runtime "$name"
    echo "❌ $name 启动失败，请查看日志"
    return 1
}

# ---------- 停止单个服务 ----------
stop_service() {
    local name="$1"
    
    if ! service_exists "$name"; then
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

# ---------- 交互式启动菜单 ----------
interactive_start() {
    while true; do
        cls
        echo
        echo "╔══════════════════════════════════════╗"
        echo "║            启动服务                 ║"
        echo "╠══════════════════════════════════════╣"
        echo "║  0) 返回主菜单                       ║"
        echo "║  9) 全部启动                         ║"
        echo "║ ─────────────────────────────────── ║"
        
        local services=()
        local svc=""
        local max_len=0
        local idx=1
        
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            local len=${#svc}
            if [ "$len" -gt "$max_len" ]; then
                max_len=$len
            fi
        done < <(get_service_names)
        
        max_len=$((max_len + 2))
        
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            services+=("$svc")
            local padded_name=""
            padded_name=$(printf "%-${max_len}s" "$svc")
            local status=""
            if is_running "$svc"; then
                status="(🟢 运行中)"
            else
                status="(🔴 已停止)"
            fi
            local num_str=$(printf "%2d" "$idx")
            echo "║  ${num_str}) ${padded_name}${status} ║"
            idx=$((idx + 1))
        done < <(get_service_names)
        
        echo "╚══════════════════════════════════════╝"
        echo
        read -p "请选择 (0返回, 9全部): " choice
        
        # 全局stop检测
        check_stop "$choice" && return 0
        
        case "$choice" in
            0)
                return 0
                ;;
            9)
                start_all
                sleep 1
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    local svc_idx=$((choice))
                    if [ $svc_idx -ge 1 ] && [ $svc_idx -le ${#services[@]} ]; then
                        start_service "${services[$((svc_idx - 1))]}"
                        sleep 1
                    else
                        echo "❌ 无效选择"
                        sleep 1
                    fi
                else
                    echo "❌ 无效选择"
                    sleep 1
                fi
                ;;
        esac
    done
}

# ---------- 交互式停止菜单 ----------
interactive_stop() {
    while true; do
        cls
        echo
        echo "╔══════════════════════════════════════╗"
        echo "║            停止服务                 ║"
        echo "╠══════════════════════════════════════╣"
        echo "║  0) 返回主菜单                       ║"
        echo "║  9) 全部停止                         ║"
        echo "║ ─────────────────────────────────── ║"
        
        local services=()
        local svc=""
        local max_len=0
        local idx=1
        
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            local len=${#svc}
            if [ "$len" -gt "$max_len" ]; then
                max_len=$len
            fi
        done < <(get_service_names)
        
        max_len=$((max_len + 2))
        
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            services+=("$svc")
            local padded_name=""
            padded_name=$(printf "%-${max_len}s" "$svc")
            local status=""
            if is_running "$svc"; then
                status="(🟢 运行中)"
            else
                status="(🔴 已停止)"
            fi
            local num_str=$(printf "%2d" "$idx")
            echo "║  ${num_str}) ${padded_name}${status} ║"
            idx=$((idx + 1))
        done < <(get_service_names)
        
        echo "╚══════════════════════════════════════╝"
        echo
        read -p "请选择 (0返回, 9全部): " choice
        
        # 全局stop检测
        check_stop "$choice" && return 0
        
        case "$choice" in
            0)
                return 0
                ;;
            9)
                stop_all
                sleep 1
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    local svc_idx=$((choice))
                    if [ $svc_idx -ge 1 ] && [ $svc_idx -le ${#services[@]} ]; then
                        stop_service "${services[$((svc_idx - 1))]}"
                        sleep 1
                    else
                        echo "❌ 无效选择"
                        sleep 1
                    fi
                else
                    echo "❌ 无效选择"
                    sleep 1
                fi
                ;;
        esac
    done
}

# ---------- 启动所有自启动服务 ----------
start_all() {
    echo "==== 启动所有自启动服务 ===="
    local count=0
    local name=""
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        if in_auto_list "$name"; then
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
        fi
    done < <(get_service_names)
    
    if [ $count -eq 0 ]; then
        echo "ℹ️ 没有设置自启动的服务"
    fi
}

# ---------- 停止所有服务 ----------
stop_all() {
    echo "==== 停止所有服务 ===="
    local name=""
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        stop_service "$name"
    done < <(get_service_names)
}

# ---------- 切换自启动状态 ----------
toggle_auto() {
    local name="$1"
    
    # 命令行模式：指定服务名
    if [ -n "$name" ]; then
        if ! service_exists "$name"; then
            echo "❌ 无效服务：$name"
            echo "   可用服务：$(get_service_names | tr '\n' ' ')"
            return 1
        fi
        
        local pos=$(get_service_pos "$name")
        local idx="${SERVICE_INDEXES[$pos]}"
        local var_name="SERVICE_${idx}"
        local -n service_arr="$var_name"
        
        local new_val=""
        if in_auto_list "$name"; then
            new_val="false"
            echo "✅ $name 自启动已禁用"
        else
            new_val="true"
            echo "✅ $name 自启动已启用"
        fi
        
        # 1. 修改脚本文件本体（持久化）
        sed -i "/^SERVICE_${idx}=(/,/^)/s/  'auto_start: \"[a-z]*\"'/  'auto_start: \"$new_val\"'/" "$SELF"
        
        # 2. 同时修改内存中的数组（当前会话立即生效）
        local j=0
        for ((j=0; j<${#service_arr[@]}; j++)); do
            local line="${service_arr[$j]}"
            local key="${line%%:*}"
            if [ "$key" = "auto_start" ]; then
                service_arr[$j]="auto_start: \"$new_val\""
                break
            fi
        done
        
        return 0
    fi
    
    # 交互模式：显示菜单
    while true; do
        cls
        echo
        echo "╔══════════════════════════════════════╗"
        echo "║          自启动管理                 ║"
        echo "╠══════════════════════════════════════╣"
        echo "║  0) 返回主菜单                       ║"
        echo "║ ─────────────────────────────────── ║"
        
        local services=()
        local svc=""
        local max_len=0
        local idx=1
        
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            local len=${#svc}
            if [ "$len" -gt "$max_len" ]; then
                max_len=$len
            fi
        done < <(get_service_names)
        
        max_len=$((max_len + 2))
        
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            services+=("$svc")
            local padded_name=""
            padded_name=$(printf "%-${max_len}s" "$svc")
            local status=""
            if in_auto_list "$svc"; then
                status="(✅ 自启动)"
            else
                status="(❌ 禁用)"
            fi
            local num_str=$(printf "%2d" "$idx")
            echo "║  ${num_str}) ${padded_name}${status} ║"
            idx=$((idx + 1))
        done < <(get_service_names)
        
        echo "╚══════════════════════════════════════╝"
        echo
        read -p "请选择 (0返回): " choice
        
        # 全局stop检测
        check_stop "$choice" && return 0
        
        case "$choice" in
            0)
                return 0
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    local svc_idx=$((choice))
                    if [ $svc_idx -ge 1 ] && [ $svc_idx -le ${#services[@]} ]; then
                        toggle_auto "${services[$((svc_idx - 1))]}"
                        sleep 1
                    else
                        echo "❌ 无效选择"
                        sleep 1
                    fi
                else
                    echo "❌ 无效选择"
                    sleep 1
                fi
                ;;
        esac
    done
}
# ---------- 查看日志 ----------
log_service() {
    local name="$1"
    
    # 交互模式：显示服务列表
    if [ -z "$name" ]; then
        while true; do
            cls
            echo
            echo "╔══════════════════════════════════════╗"
            echo "║            查看日志                 ║"
            echo "╠══════════════════════════════════════╣"
            echo "║  0) 返回主菜单                       ║"
            echo "║ ─────────────────────────────────── ║"
            
            local services=()
            local svc=""
            local max_len=0
            local idx=1
            
            while IFS= read -r svc; do
                [ -z "$svc" ] && continue
                local len=${#svc}
                if [ "$len" -gt "$max_len" ]; then
                    max_len=$len
                fi
            done < <(get_service_names)
            
            max_len=$((max_len + 2))
            
            while IFS= read -r svc; do
                [ -z "$svc" ] && continue
                services+=("$svc")
                local padded_name=""
                padded_name=$(printf "%-${max_len}s" "$svc")
                local status=""
                if is_running "$svc"; then
                    status="(🟢 运行中)"
                else
                    status="(🔴 已停止)"
                fi
                local num_str=$(printf "%2d" "$idx")
                echo "║  ${num_str}) ${padded_name}${status} ║"
                idx=$((idx + 1))
            done < <(get_service_names)
            
            echo "╚══════════════════════════════════════╝"
            echo
            read -p "请选择 (0返回): " choice
            
            # 全局stop检测
            check_stop "$choice" && return 0
            
            case "$choice" in
                0)
                    return 0
                    ;;
                *)
                    if [[ "$choice" =~ ^[0-9]+$ ]]; then
                        local svc_idx=$((choice))
                        if [ $svc_idx -ge 1 ] && [ $svc_idx -le ${#services[@]} ]; then
                            local selected_name="${services[$((svc_idx - 1))]}"
                            if service_exists "$selected_name"; then
                                local log_file=""
                                log_file=$(service_log_path "$selected_name")
                                touch "$log_file"
                                cls
                                echo
                                echo "╔══════════════════════════════════════╗"
                                echo "║        $selected_name 日志         ║"
                                echo "╚══════════════════════════════════════╝"
                                echo "[输入 0 返回列表，输入 00 直接回主菜单]"
                                echo
                                tail -n 30 -f "$log_file" &
                                local tail_pid=$!
                                trap 'echo; echo "请输入 0 返回列表"' INT
                                while true; do
                                    printf "log> "
                                    IFS= read -r cmd
                                    
                                    # 全局stop检测
                                    if [ "$cmd" = "stop" ]; then
                                        kill "$tail_pid" 2>/dev/null || true
                                        wait "$tail_pid" 2>/dev/null || true
                                        trap - INT
                                        handle_global_stop
                                        return 0
                                    fi
                                    
                                    case "$cmd" in
                                        0)
                                            break
                                            ;;
                                        00)
                                            kill "$tail_pid" 2>/dev/null || true
                                            wait "$tail_pid" 2>/dev/null || true
                                            trap - INT
                                            return 0
                                            ;;
                                        *)
                                            ;;
                                    esac
                                done
                                trap - INT
                                kill "$tail_pid" 2>/dev/null || true
                                wait "$tail_pid" 2>/dev/null || true
                                sleep 1
                            fi
                        else
                            echo "❌ 无效选择"
                            sleep 1
                        fi
                    else
                        echo "❌ 无效选择"
                        sleep 1
                    fi
                    ;;
            esac
        done
    else
        # 命令行模式：直接查看指定服务日志
        if ! service_exists "$name"; then
            echo "❌ 无效服务：$name"
            return 1
        fi
        local log_file=""
        log_file=$(service_log_path "$name")
        touch "$log_file"
        cls
        echo
        echo "╔══════════════════════════════════════╗"
        echo "║        $name 日志                 ║"
        echo "╚══════════════════════════════════════╝"
        echo "[输入 0 退出]"
        echo
        tail -n 30 -f "$log_file" &
        local tail_pid=$!
        trap 'echo; echo "请输入 0 退出"' INT
        while true; do
            printf "log> "
            IFS= read -r cmd
            
            # 全局stop检测
            if [ "$cmd" = "stop" ]; then
                kill "$tail_pid" 2>/dev/null || true
                wait "$tail_pid" 2>/dev/null || true
                trap - INT
                handle_global_stop
                return 0
            fi
            
            case "$cmd" in
                0)
                    break
                    ;;
                *)
                    ;;
            esac
        done
        trap - INT
        kill "$tail_pid" 2>/dev/null || true
        wait "$tail_pid" 2>/dev/null || true
    fi
}

# ---------- 进入服务控制台 ----------
console_service() {
    local name="$1"
    
    # 交互模式：显示服务列表
    if [ -z "$name" ]; then
        while true; do
            cls
            echo
            echo "╔══════════════════════════════════════╗"
            echo "║          进入服务控制台             ║"
            echo "╠══════════════════════════════════════╣"
            echo "║  0) 返回主菜单                       ║"
            echo "║ ─────────────────────────────────── ║"
            
            local services=()
            local svc=""
            local max_len=0
            local idx=1
            
            while IFS= read -r svc; do
                [ -z "$svc" ] && continue
                local len=${#svc}
                if [ "$len" -gt "$max_len" ]; then
                    max_len=$len
                fi
            done < <(get_service_names)
            
            max_len=$((max_len + 2))
            
            while IFS= read -r svc; do
                [ -z "$svc" ] && continue
                services+=("$svc")
                local padded_name=""
                padded_name=$(printf "%-${max_len}s" "$svc")
                local status=""
                if is_running "$svc"; then
                    status="(🟢 运行中)"
                else
                    status="(🔴 已停止)"
                fi
                local num_str=$(printf "%2d" "$idx")
                echo "║  ${num_str}) ${padded_name}${status} ║"
                idx=$((idx + 1))
            done < <(get_service_names)
            
            echo "╚══════════════════════════════════════╝"
            echo
            read -p "请选择 (0返回): " choice
            
            # 全局stop检测
            check_stop "$choice" && return 0
            
            case "$choice" in
                0)
                    return 0
                    ;;
                *)
                    if [[ "$choice" =~ ^[0-9]+$ ]]; then
                        local svc_idx=$((choice))
                        if [ $svc_idx -ge 1 ] && [ $svc_idx -le ${#services[@]} ]; then
                            name="${services[$((svc_idx - 1))]}"
                            break
                        else
                            echo "❌ 无效选择"
                            sleep 1
                        fi
                    else
                        echo "❌ 无效选择"
                        sleep 1
                    fi
                    ;;
            esac
        done
    fi
    
    # 进入控制台
    if ! service_exists "$name"; then
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
    
    cls
    echo
    echo "╔══════════════════════════════════════╗"
    echo "║        $name 控制台桥接            ║"
    echo "╚══════════════════════════════════════╝"
    echo "输入命令后回车发送，输入 0 返回，输入 00 直接回主菜单"
    echo
    
    tail -n 30 -f "$log_file" &
    tail_pid=$!
    
    trap 'echo; echo "请输入 0 返回"' INT
    
    while true; do
        printf "\n[%s] console> " "$name"
        IFS= read -r cmd
        read_status=$?
        
        # 全局stop检测
        if [ "$cmd" = "stop" ]; then
            kill "$tail_pid" 2>/dev/null || true
            wait "$tail_pid" 2>/dev/null || true
            trap - INT
            handle_global_stop
            return 0
        fi
        
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
            0)
                break
                ;;
            00)
                kill "$tail_pid" 2>/dev/null || true
                wait "$tail_pid" 2>/dev/null || true
                trap - INT
                return 0
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
    echo
    echo "↩ 已返回主菜单"
    sleep 1
}

# ---------- 显示服务状态总览 ----------
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
    
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        
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
    done < <(get_service_names)
    
    echo
}

# ---------- 帮助信息 ----------
show_help() {
    cat <<EOF
使用方式：
  \$0                    # 进入交互模式
  \$0 <命令> [参数]       # 命令行模式

==== 命令行模式 ====
  \$0 s                  # 查看所有服务状态
  \$0 start all          # 启动所有自启动服务
  \$0 start <服务名>     # 启动单个服务
  \$0 stop all           # 停止所有服务
  \$0 stop <服务名>      # 停止单个服务
  \$0 auto <服务名>      # 切换自启动状态
  \$0 log <服务名>       # 查看服务日志
  \$0 console <服务名>   # 进入服务控制台

==== 交互模式菜单 ====
  1. start          启动服务
  2. stop           停止服务
  3. auto           自启动管理
  4. log            查看日志
  5. console        进入服务控制台
  6. 0              退出

  0               返回上一级
  00              直接回主菜单（日志/控制台内）
EOF
}

# ---------- 命令行模式执行 ----------
execute() {
    local cmd="${1:-}"
    local arg="${2:-}"
    
    case "$cmd" in
        s|"")
            show
            ;;
        start)
            if [ -z "$arg" ]; then
                interactive_start || true
            elif [ "$arg" = "all" ]; then
                start_all
            else
                start_service "$arg"
            fi
            ;;
        stop)
            if [ -z "$arg" ]; then
                interactive_stop || true
            elif [ "$arg" = "all" ]; then
                stop_all
            else
                stop_service "$arg"
            fi
            ;;
        auto)
            if [ -z "$arg" ]; then
                toggle_auto "" || true
            else
                toggle_auto "$arg"
            fi
            ;;
        log)
            if [ -z "$arg" ]; then
                log_service "" || true
            else
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
        0|quit|exit)
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

# ---------- 交互模式主循环 ----------
interactive() {
    # ============================================================
    # 启动时自动启动所有标记为自启动的服务
    # ============================================================
    echo "==== 服务管理控制台 ===="
    echo
    echo "正在检查自启动服务..."
    
    local auto_count=0
    local name=""
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        if in_auto_list "$name"; then
            auto_count=$((auto_count + 1))
        fi
    done < <(get_service_names)
    
    if [ $auto_count -gt 0 ]; then
        echo "发现 $auto_count 个自启动服务，正在启动..."
        echo
        start_all
        echo
        echo "自启动服务启动完成"
        sleep 2
    else
        echo "没有设置自启动的服务"
        sleep 1
    fi
    
    # ============================================================
    # 主菜单循环
    # ============================================================
    while true; do
        cls
        echo "==== 服务管理控制台 ===="
        show
        
        echo
        echo "╔══════════════════════════════════════╗"
        echo "║            命令菜单                 ║"
        echo "╠══════════════════════════════════════╣"
        echo "║  1) start          启动服务           ║"
        echo "║  2) stop           停止服务           ║"
        echo "║  3) auto           自启动管理         ║"
        echo "║  4) log            查看日志           ║"
        echo "║  5) console        进入服务控制台     ║"
        echo "║  0) 退出                             ║"
        echo "╚══════════════════════════════════════╝"
        echo
        
        read -p "请选择操作 (1-5, 0退出): " choice
        
        # 全局stop检测
        check_stop "$choice" && return 0
        
        case "$choice" in
            1|start)
                interactive_start || true
                ;;
            2|stop)
                interactive_stop || true
                ;;
            3|auto)
                toggle_auto "" || true
                ;;
            4|log)
                log_service "" || true
                ;;
            5|console)
                console_service "" || true
                ;;
            0)
                echo
                echo "正在停止所有服务..."
                stop_all
                echo "再见！"
                return 0
                ;;
            *)
                echo "❌ 无效选择: $choice"
                sleep 1
                ;;
        esac
    done
}

# ---------- 主逻辑入口 ----------
if [ $# -gt 0 ]; then
    execute "$@"
else
    interactive
fi
