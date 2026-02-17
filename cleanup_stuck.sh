#!/bin/bash
# AiAgentWatchDog - 智能清理卡死进程
# 
# 功能：
# - 智能检测卡死进程
# - 保护正常持久化进程
# - systemd 服务安全重启
# - 详细的评分系统
#
# 用法：
#   ./cleanup_stuck.sh           # 执行清理
#   ./cleanup_stuck.sh --dry-run # 只显示，不清理
#   ./cleanup_stuck.sh --help    # 显示帮助

set -e

# ============================================
# 配置
# ============================================

STUCK_THRESHOLD=50
MIN_UPTIME=120
DRY_RUN=false
LOG_FILE="/var/log/cleanup_stuck.log"

# ============================================
# 解析参数
# ============================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run|-n)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --dry-run, -n    只显示要清理的进程，不实际清理"
            echo "  --help, -h       显示此帮助信息"
            echo ""
            echo "配置:"
            echo "  STUCK_THRESHOLD=$STUCK_THRESHOLD (卡死阈值分数)"
            echo "  MIN_UPTIME=$MIN_UPTIME (最小检查运行时间/秒)"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done

# ============================================
# 检测函数
# ============================================

get_process_state() {
    local pid="$1"
    cat /proc/$pid/stat 2>/dev/null | awk '{print $3}'
}

is_orphan() {
    local pid="$1"
    local ppid
    ppid=$(cat /proc/$pid/stat 2>/dev/null | awk '{print $4}')
    
    if [[ ! -d "/proc/$ppid" ]] && [[ "$ppid" != "1" ]]; then
        return 0
    fi
    
    if [[ "$ppid" == "1" ]]; then
        local cmdline
        cmdline=$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ')
        if [[ "$cmdline" == *"python"* ]]; then
            return 0
        fi
    fi
    return 1
}

get_cpu_percent() {
    local pid="$1"
    ps -p "$pid" -o %cpu --no-headers 2>/dev/null | tr -d ' '
}

get_uptime_seconds() {
    local pid="$1"
    local clk_tck
    clk_tck=$(getconf CLK_TCK)
    local jiffies
    jiffies=$(cat /proc/$pid/stat 2>/dev/null | awk '{print $22}')
    echo $((jiffies / clk_tck))
}

has_active_network() {
    local pid="$1"
    local conn_count
    conn_count=$(ss -tnp 2>/dev/null | grep "pid=$pid" | grep -E "ESTAB|SYN-RECV" | wc -l)
    [[ "$conn_count" -gt 0 ]]
}

has_active_io() {
    local pid="$1"
    if [[ -f "/proc/$pid/io" ]]; then
        local io_before io_after
        io_before=$(cat /proc/$pid/io 2>/dev/null | grep -E "read_bytes|write_bytes" | awk '{sum+=$2} END {print sum}')
        sleep 0.5
        io_after=$(cat /proc/$pid/io 2>/dev/null | grep -E "read_bytes|write_bytes" | awk '{sum+=$2} END {print sum}')
        [[ $((io_after - io_before)) -gt 1024 ]]
    fi
    return 1
}

get_systemd_service_name() {
    local pid="$1"
    local cgroup
    cgroup=$(cat /proc/$pid/cgroup 2>/dev/null)
    
    if [[ "$cgroup" == *"system.slice"* ]]; then
        echo "$cgroup" | grep -oP 'system\.slice/\K[^.]+' | head -1
        return 0
    fi
    return 1
}

is_critical_system_process() {
    local cmd="$1"
    local critical_patterns=(
        "systemd"
        "sshd"
        "dbus-daemon"
        "rsyslogd"
        "journald"
        "networkd"
        "resolved"
    )
    for pattern in "${critical_patterns[@]}"; do
        if [[ "$cmd" == *"$pattern"* ]]; then
            return 0
        fi
    done
    return 1
}

is_persistent_app() {
    local cmd="$1"
    local persist_patterns=(
        "persist"
        "daemon"
        "keepalive"
        "tmux"
        "screen"
        "byobu"
        "mosh"
        "agent"
    )
    for pattern in "${persist_patterns[@]}"; do
        if [[ "$cmd" == *"$pattern"* ]]; then
            return 0
        fi
    done
    return 1
}

# ============================================
# 日志函数
# ============================================

log() {
    local msg="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $msg"
    echo "[$timestamp] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

# ============================================
# 主检测逻辑
# ============================================

main() {
    local cleaned=0
    local restarted=0
    local protected=0
    
    log "========== 开始扫描 =========="
    
    while IFS= read -r proc_dir; do
        local pid
        pid=$(basename "$proc_dir")
        
        [[ "$pid" -le 1 ]] && continue
        [[ "$pid" -eq $$ ]] && continue
        
        local cmdline state uptime
        cmdline=$(cat "$proc_dir/cmdline" 2>/dev/null | tr '\0' ' ')
        [[ -z "$cmdline" ]] && continue
        
        state=$(get_process_state "$pid")
        uptime=$(get_uptime_seconds "$pid")
        
        [[ "$uptime" -lt "$MIN_UPTIME" ]] && continue
        
        local stuck_score=0
        local reasons=""
        
        if [[ "$state" == "D" ]]; then
            ((stuck_score += 100)) || true
            reasons="$reasons [状态=D]"
        fi
        
        if is_orphan "$pid"; then
            ((stuck_score += 40)) || true
            reasons="$reasons [孤儿进程]"
        fi
        
        local cpu
        cpu=$(get_cpu_percent "$pid")
        if [[ $(echo "$cpu < 0.01" | bc -l 2>/dev/null) == "1" ]]; then
            ((stuck_score += 20)) || true
            reasons="$reasons [CPU=0%]"
        fi
        
        if ! has_active_network "$pid" && ! has_active_io "$pid"; then
            ((stuck_score += 15)) || true
            reasons="$reasons [无活动]"
        fi
        
        if [[ "$uptime" -gt 600 ]]; then
            ((stuck_score += 10)) || true
            reasons="$reasons [运行>${uptime}s]"
        fi
        
        if [[ "$stuck_score" -lt "$STUCK_THRESHOLD" ]]; then
            continue
        fi
        
        if is_critical_system_process "$cmdline"; then
            log "⚠️ 跳过关键系统进程: PID=$pid CMD=${cmdline:0:50}"
            ((protected++)) || true
            continue
        fi
        
        if is_persistent_app "$cmdline"; then
            log "⚠️ 跳过持久化应用: PID=$pid CMD=${cmdline:0:50}"
            ((protected++)) || true
            continue
        fi
        
        if has_active_network "$pid"; then
            continue
        fi
        
        if has_active_io "$pid"; then
            continue
        fi
        
        local service_name
        if service_name=$(get_systemd_service_name "$pid"); then
            log "🔄 重启 systemd 服务: $service_name"
            log "   PID: $pid, 分数: $stuck_score$reasons"
            log "   CMD: ${cmdline:0:80}"
            
            if [[ "$DRY_RUN" == "true" ]]; then
                log "   [DRY-RUN] 将执行: systemctl restart $service_name"
            else
                if systemctl restart "$service_name" 2>/dev/null; then
                    log "   ✅ 服务已重启"
                    ((restarted++)) || true
                else
                    log "   ❌ 重启失败"
                fi
            fi
        else
            log "🧹 清理卡死进程:"
            log "   PID: $pid"
            log "   分数: $stuck_score (阈值: $STUCK_THRESHOLD)"
            log "   运行: ${uptime}s"
            log "   原因:$reasons"
            log "   CMD: ${cmdline:0:80}"
            
            if [[ "$DRY_RUN" == "true" ]]; then
                log "   [DRY-RUN] 将被清理"
            else
                if kill -9 "$pid" 2>/dev/null; then
                    log "   ✅ 已清理"
                    ((cleaned++)) || true
                else
                    log "   ❌ 清理失败"
                fi
            fi
        fi
        
    done < <(find /proc -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null)
    
    log "========== 扫描完成 =========="
    log "普通进程清理: $cleaned"
    log "服务重启: $restarted"
    log "受保护: $protected"
}

main
