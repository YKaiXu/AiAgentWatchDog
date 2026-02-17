#!/bin/bash
# stuck-process-cleaner - 智能清理卡死进程
# 
# 功能：
# - 智能检测卡死进程
# - 保护正常持久化进程
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

# 卡死阈值分数（>= 此分数则清理）
STUCK_THRESHOLD=50

# 最小运行时间（秒），小于此时间不检查
MIN_UPTIME=120

# 是否只显示不清理
DRY_RUN=false

# 日志文件
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
# 保护名单 - 这些进程永远不会被清理
# ============================================

# 1. systemd 管理的服务进程
is_systemd_service() {
    local pid="$1"
    if [[ -f "/proc/$pid/cgroup" ]]; then
        if grep -q "system.slice\|user.slice" /proc/$pid/cgroup 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# 2. 关键系统进程
is_critical_process() {
    local cmd="$1"
    local critical_patterns=(
        "systemd"
        "sshd"
        "dbus-daemon"
        "rsyslogd"
        "journald"
        "networkd"
        "resolved"
        "cron"
        "atd"
        "postfix"
        "dovecot"
        "nginx"
        "apache"
        "mysql"
        "postgres"
        "redis"
        "memcached"
        "docker"
        "containerd"
    )
    for pattern in "${critical_patterns[@]}"; do
        if [[ "$cmd" == *"$pattern"* ]]; then
            return 0
        fi
    done
    return 1
}

# 3. 持久化应用进程（白名单）
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

# 4. 有活跃网络连接的进程
has_active_network() {
    local pid="$1"
    local conn_count
    conn_count=$(ss -tnp 2>/dev/null | grep "pid=$pid" | grep -E "ESTAB|SYN-RECV" | wc -l)
    [[ "$conn_count" -gt 0 ]]
}

# 5. 有活跃 I/O 的进程
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

# ============================================
# 卡死特征检测
# ============================================

# 检测进程状态
get_process_state() {
    local pid="$1"
    cat /proc/$pid/stat 2>/dev/null | awk '{print $3}'
}

# 检测是否为孤儿进程
is_orphan() {
    local pid="$1"
    local ppid
    ppid=$(cat /proc/$pid/stat 2>/dev/null | awk '{print $4}')
    
    # 父进程不存在
    if [[ ! -d "/proc/$ppid" ]]; then
        return 0
    fi
    
    # 父进程是 1 且进程是 Python 脚本（通常是卡死的）
    if [[ "$ppid" == "1" ]]; then
        local cmdline
        cmdline=$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ')
        if [[ "$cmdline" == *"python"* ]]; then
            return 0
        fi
    fi
    return 1
}

# 检测 CPU 使用率
get_cpu_percent() {
    local pid="$1"
    ps -p "$pid" -o %cpu --no-headers 2>/dev/null | tr -d ' '
}

# 检测进程运行时间（秒）
get_uptime_seconds() {
    local pid="$1"
    local clk_tck
    clk_tck=$(getconf CLK_TCK)
    local jiffies
    jiffies=$(cat /proc/$pid/stat 2>/dev/null | awk '{print $22}')
    echo $((jiffies / clk_tck))
}

# ============================================
# 日志函数
# ============================================

log() {
    local msg="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $msg"
    if [[ -w "$(dirname "$LOG_FILE")" ]] || [[ "$DRY_RUN" == "true" ]]; then
        echo "[$timestamp] $msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# ============================================
# 主检测逻辑
# ============================================

main() {
    local cleaned=0
    local protected=0
    local checked=0
    
    log "========== 开始扫描 =========="
    
    while IFS= read -r proc_dir; do
        local pid
        pid=$(basename "$proc_dir")
        
        # 跳过特殊 PID
        [[ "$pid" -le 1 ]] && continue
        [[ "$pid" -eq $$ ]] && continue
        
        # 获取进程信息
        local cmdline state uptime
        cmdline=$(cat "$proc_dir/cmdline" 2>/dev/null | tr '\0' ' ')
        [[ -z "$cmdline" ]] && continue
        
        state=$(get_process_state "$pid")
        uptime=$(get_uptime_seconds "$pid")
        
        ((checked++)) || true
        
        # === 保护检查 ===
        
        # 1. systemd 服务进程 - 保护
        if is_systemd_service "$pid"; then
            ((protected++)) || true
            continue
        fi
        
        # 2. 关键系统进程 - 保护
        if is_critical_process "$cmdline"; then
            ((protected++)) || true
            continue
        fi
        
        # 3. 持久化应用 - 保护
        if is_persistent_app "$cmdline"; then
            ((protected++)) || true
            continue
        fi
        
        # 4. 有活跃网络连接 - 保护
        if has_active_network "$pid"; then
            continue
        fi
        
        # 5. 有活跃 I/O - 保护
        if has_active_io "$pid"; then
            continue
        fi
        
        # === 运行时间检查 ===
        [[ "$uptime" -lt "$MIN_UPTIME" ]] && continue
        
        # === 卡死评分 ===
        local stuck_score=0
        local reasons=""
        
        # 1. 进程状态为 D (不可中断睡眠)
        if [[ "$state" == "D" ]]; then
            ((stuck_score += 100)) || true
            reasons="$reasons [状态=D]"
        fi
        
        # 2. 孤儿进程
        if is_orphan "$pid"; then
            ((stuck_score += 40)) || true
            reasons="$reasons [孤儿进程]"
        fi
        
        # 3. CPU 使用率长期为 0
        local cpu
        cpu=$(get_cpu_percent "$pid")
        if [[ $(echo "$cpu < 0.01" | bc -l 2>/dev/null) == "1" ]]; then
            ((stuck_score += 20)) || true
            reasons="$reasons [CPU=0%]"
        fi
        
        # 4. 无网络连接且无 I/O
        if ! has_active_network "$pid" && ! has_active_io "$pid"; then
            ((stuck_score += 15)) || true
            reasons="$reasons [无活动]"
        fi
        
        # 5. 运行时间过长
        if [[ "$uptime" -gt 600 ]]; then
            ((stuck_score += 10)) || true
            reasons="$reasons [运行>${uptime}s]"
        fi
        
        # === 执行清理 ===
        if [[ "$stuck_score" -ge "$STUCK_THRESHOLD" ]]; then
            log "🧹 发现卡死进程:"
            log "   PID: $pid"
            log "   分数: $stuck_score (阈值: $STUCK_THRESHOLD)"
            log "   运行: ${uptime}s"
            log "   原因:$reasons"
            log "   命令: ${cmdline:0:100}"
            
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
    log "检查: $checked 个进程"
    log "保护: $protected 个进程"
    log "清理: $cleaned 个进程"
}

main
