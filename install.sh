#!/bin/bash
# AiAgentWatchDog 安装脚本
#
# 用法:
#   sudo ./install.sh           # 安装
#   sudo ./install.sh --uninstall # 卸载

set -e

# 配置
INSTALL_DIR="/opt/aiagentwatchdog"
SCRIPT_NAME="cleanup_stuck.sh"
SERVICE_NAME="cleanup-stuck"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "需要 root 权限，请使用 sudo"
        exit 1
    fi
}

# 安装
install() {
    log_info "开始安装 AiAgentWatchDog..."
    
    # 创建安装目录
    log_info "创建安装目录: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    
    # 复制脚本
    log_info "安装清理脚本..."
    cp "$SCRIPT_NAME" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
    
    # 创建 systemd service
    log_info "创建 systemd 服务..."
    cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=AiAgentWatchDog - Cleanup stuck processes
After=network.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/$SCRIPT_NAME
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # 创建 systemd timer
    log_info "创建 systemd 定时器..."
    cat > "/etc/systemd/system/$SERVICE_NAME.timer" << EOF
[Unit]
Description=AiAgentWatchDog - Run cleanup every minute

[Timer]
OnCalendar=*:*:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # 创建日志目录
    mkdir -p /var/log
    touch /var/log/cleanup_stuck.log
    chmod 644 /var/log/cleanup_stuck.log
    
    # 重载 systemd
    log_info "重载 systemd..."
    systemctl daemon-reload
    
    # 启用并启动 timer
    log_info "启用定时器..."
    systemctl enable --now "$SERVICE_NAME.timer"
    
    # 验证
    log_info "验证安装..."
    if systemctl is-active "$SERVICE_NAME.timer" &>/dev/null; then
        log_info "✅ 安装成功！"
        echo ""
        echo "状态:"
        systemctl status "$SERVICE_NAME.timer" --no-pager | head -5
        echo ""
        echo "日志: /var/log/cleanup_stuck.log"
        echo "配置: $INSTALL_DIR/$SCRIPT_NAME"
        echo ""
        echo "使用方法:"
        echo "  sudo $INSTALL_DIR/$SCRIPT_NAME           # 执行清理"
        echo "  sudo $INSTALL_DIR/$SCRIPT_NAME --dry-run # 只查看不清理"
    else
        log_error "安装失败，请检查日志"
        exit 1
    fi
}

# 卸载
uninstall() {
    log_info "开始卸载 AiAgentWatchDog..."
    
    # 停止并禁用 timer
    log_info "停止服务..."
    systemctl disable --now "$SERVICE_NAME.timer" 2>/dev/null || true
    
    # 删除 systemd 文件
    log_info "删除 systemd 配置..."
    rm -f "/etc/systemd/system/$SERVICE_NAME.timer"
    rm -f "/etc/systemd/system/$SERVICE_NAME.service"
    
    # 重载 systemd
    systemctl daemon-reload
    
    # 删除安装目录
    log_info "删除安装文件..."
    rm -rf "$INSTALL_DIR"
    
    # 保留日志文件（可选）
    log_warn "日志文件保留在: /var/log/cleanup_stuck.log"
    
    log_info "✅ 卸载完成！"
}

# 显示帮助
show_help() {
    echo "AiAgentWatchDog 安装脚本"
    echo ""
    echo "用法:"
    echo "  sudo ./install.sh             # 安装"
    echo "  sudo ./install.sh --uninstall # 卸载"
    echo "  sudo ./install.sh --help      # 显示帮助"
    echo ""
    echo "安装后:"
    echo "  - 定时器每分钟执行一次"
    echo "  - 日志: /var/log/cleanup_stuck.log"
    echo "  - 配置: $INSTALL_DIR/$SCRIPT_NAME"
}

# 主入口
case "${1:-}" in
    --uninstall|-u)
        check_root
        uninstall
        ;;
    --help|-h)
        show_help
        ;;
    *)
        check_root
        install
        ;;
esac
