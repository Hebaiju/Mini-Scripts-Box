#!/bin/bash
set -euo pipefail
# ---------- 配置区 ----------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
SELF="$0"

# <<<SERVICES_CONFIG>>>
# [
#   {
#     "name": "3c3uliveou",
#     "exec_file": "ZenithProxy",
#     "work_dir": "3c3u-liveou",
#     "exec_type": "",
#     "exec_command": "./ZenithProxy",
#     "auto_start": false
#   },
#   {
#     "name": "zenith-bin",
#     "exec_file": "ZenithProxy",
#     "work_dir": "zenithproxy-bin",
#     "exec_type": "",
#     "exec_command": "",
#     "auto_start": false
#   }
# ]
# <<<END_SERVICES_CONFIG>>>

# ---------- JSON 配置解析 ----------
# 提取脚本头部的JSON配置
extract_config_json() {
    sed -n '/^# <<<SERVICES_CONFIG>>>/,/^# <<<END_SERVICES_CONFIG>>>/p' "$SELF" \
        | sed '1d;$d' \
        | sed 's/^# //' \
        | sed 's/^#//'
}

# 获取所有服务名（空格分隔）
get_service_names() {
    extract_config_json | python3 -c "
import sys, json, signal
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
data = json.load(sys.stdin)
for item in data:
    print(item['name'])
"
}

# 获取指定服务的指定字段值
get_service_field() {
    local name="$1"
    local field="$2"
    extract_config_json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data:
    if item['name'] == '$name':
        print(item.get('$field', ''))
        break
"
}

# 检查服务是否存在
service_exists() {
    local name="$1"
    local svc=""
    while IFS= read -r svc; do
        [ "$svc" = "$name" ] && return 0
    done < <(get_service_names)
    return 1
}

# 检查是否自启动
in_auto_list() {
    local name="$1"
    local val=""
    val=$(get_service_field "$name" "auto_start")
    [ "$val" = "True" ] || [ "$val" = "true" ]
}

# 获取服务工作目录（完整路径）
service_dir() {
    local name="$1"
    local dir=""
    dir=$(get_service_field "$name" "work_dir")
    printf '%s/%s\n' "$SCRIPT_DIR" "$dir"
}

# 获取执行文件名
service_exec_file() {
    local name="$1"
    get_service_field "$name" "exec_file"
}

# 获取执行类型（自动识别或手动指定）
service_exec_type() {
    local name="$1"
    local type=""
    type=$(get_service_field "$name" "exec_type")
    if [ -z "$type" ]; then
        # 自动根据文件后缀识别
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

# 生成标准启动命令
build_start_command() {
    local name="$1"
    local custom_cmd=""
    custom_cmd=$(service_exec_command "$name")
    
    if [ -n "$custom_cmd" ]; then
        # 有自定义命令，直接使用
        echo "$custom_cmd"
        return 0
    fi
    
    # 自动生成标准命令
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

# 旧版配置已废弃，使用脚本头部的 JSON 配置
# declare -A app=(
# ["nike"]="nike"
# ["WDDWWB"]="WDDWWB"
# ["hebaiju"]="hebaiju"
# ["liveou"]="liveou"
# ["superman"]="superman"
# )
# 旧版自启动列表已废弃，使用 JSON 配置中的 auto_start 字段
# AUTO_START=(
# WDDWWB
# )
# ---------- 保存自启动配置到脚本自身 ----------
# 已废弃，自启动配置现在从JSON读取
save_auto_start() {
    return 0
}
# 旧版已废弃，使用新版JSON读取
# in_auto_list() {
#     local name="$1"
#     for item in "${AUTO_START[@]}"; do
#         [ "$item" = "$name" ] && return 0
#     done
#     return 1
# }
# ---------- 通用进程检测（通过环境变量标记，兼容所有程序类型） ----------
# 检查进程是否为指定服务（通过环境变量 ALLSH_SERVICE_NAME 识别）
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
# 旧版已废弃，使用新版JSON读取
# service_dir() {
#     local name="$1"
#     printf '%s/%s\n' "$SCRIPT_DIR" "${app[$name]}"
# }
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
            echo "   如需重新进入控制台，请先停止后再用 all.sh 启动"
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
    nohup sh -c 'cd "$1" && ALLSH_SERVICE_NAME="$2" exec $3 <"$4" >>"$5" 2>&1' sh "$service_path" "$name" "$start_cmd" "$fifo" "$log_file" >/dev/null 2>&1 &
    
    # 等待进程启动（最多等待5秒，每秒检测一次）
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
    
    # 启动失败，清理控制台运行时
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
    local svc=""
    
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        services+=("$svc")
        if is_running "$svc"; then
            display_options+=("$svc (🟢 运行中)")
        else
            display_options+=("$svc (🔴 已停止)")
        fi
    done < <(get_service_names)
    
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
                if service_exists "$name"; then
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
    local svc=""
    
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        services+=("$svc")
        if is_running "$svc"; then
            display_options+=("$svc (🟢 运行中)")
        else
            display_options+=("$svc (🔴 已停止)")
        fi
    done < <(get_service_names)
    
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
                if service_exists "$name"; then
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
# ---------- 切换自启动 ----------
toggle_auto() {
    local name="$1"
    
    # 如果提供了参数，直接切换单个服务
    if [ -n "$name" ]; then
        if ! service_exists "$name"; then
            echo "❌ 无效服务：$name"
            echo "   可用服务：$(get_service_names | tr '\n' ' ')"
            return 1
        fi
        
        local current_state=""
        current_state=$(in_auto_list "$name" && echo "启用" || echo "禁用")
        
        # 用Python修改JSON配置并写回脚本
        local new_state=""
        if in_auto_list "$name"; then
            new_state="false"
        else
            new_state="true"
        fi
        
        python3 -c "
import sys
import json

script_path = '$SELF'
service_name = '$name'
new_auto_start_str = '$new_state'
new_auto_start = new_auto_start_str.lower() == 'true'

with open(script_path, 'r') as f:
    lines = f.readlines()

# 找到配置块的开始和结束
start_idx = None
end_idx = None
for i, line in enumerate(lines):
    if line.strip() == '# <<<SERVICES_CONFIG>>>':
        start_idx = i
    elif line.strip() == '# <<<END_SERVICES_CONFIG>>>':
        end_idx = i
        break

if start_idx is None or end_idx is None:
    print('❌ 找不到配置块')
    sys.exit(1)

# 提取JSON内容（去掉#前缀）
json_lines = []
for line in lines[start_idx+1:end_idx]:
    # 去掉行首的 # 或 # 
    if line.startswith('# '):
        json_lines.append(line[2:])
    elif line.startswith('#'):
        json_lines.append(line[1:])
    else:
        json_lines.append(line)

json_str = ''.join(json_lines)
data = json.loads(json_str)

# 修改指定服务的auto_start
found = False
for item in data:
    if item['name'] == service_name:
        item['auto_start'] = new_auto_start
        found = True
        break

if not found:
    print(f'❌ 找不到服务：{service_name}')
    sys.exit(1)

# 重新生成带#前缀的JSON配置
new_json_str = json.dumps(data, indent=2, ensure_ascii=False)
new_config_lines = []
for line in new_json_str.split('\n'):
    new_config_lines.append('# ' + line + '\n')

# 替换原配置块
new_lines = lines[:start_idx+1] + new_config_lines + lines[end_idx:]

with open(script_path, 'w') as f:
    f.writelines(new_lines)

print(f'✅ {service_name} 自启动已切换')
"
        
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
    local svc=""
    
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        services+=("$svc")
        if in_auto_list "$svc"; then
            display_options+=("$svc (✅ 自启动)")
        else
            display_options+=("$svc (❌ 禁用)")
        fi
    done < <(get_service_names)
    
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
                local selected_name=$(echo "$opt" | sed 's/ (.*)$//')
                if service_exists "$selected_name"; then
                    toggle_auto "$selected_name"
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
        local svc=""
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            services+=("$svc")
        done < <(get_service_names)
        
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
                    if service_exists "$name"; then
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
    
    if ! service_exists "$name"; then
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
        local svc=""
        while IFS= read -r svc; do
            [ -z "$svc" ] && continue
            services+=("$svc")
            if is_running "$svc"; then
                display_options+=("$svc (🟢 运行中)")
            else
                display_options+=("$svc (🔴 已停止)")
            fi
        done < <(get_service_names)
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
                    if service_exists "$selected_name"; then
                        name="$selected_name"
                        break
                    else
                        echo "❌ 无效选择"
                    fi
                    ;;
            esac
        done
    fi
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
