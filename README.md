# AiAgentWatchDog

🐕 智能监控和清理 AI Agent 卡死进程的工具

## 特性

- 🎯 **智能评分系统** - 多维度检测卡死进程，避免误杀
- 🛡️ **多层保护机制** - 保护 systemd 服务、关键进程、持久化应用
- ⏱️ **定时清理** - 通过 systemd timer 每分钟自动执行
- 📊 **详细日志** - 记录清理原因和评分详情
- 🔧 **易于配置** - 支持自定义白名单和阈值

## 快速安装

```bash
# 一键安装
curl -fsSL https://raw.githubusercontent.com/YKaiXu/AiAgentWatchDog/main/install.sh | sudo bash
```

或手动安装：

```bash
# 克隆仓库
git clone https://github.com/YKaiXu/AiAgentWatchDog.git
cd AiAgentWatchDog

# 安装
sudo ./install.sh
```

## 工作原理

### 保护机制（不会被清理）

| 保护类型 | 检测方法 | 示例 |
|---------|---------|------|
| systemd 服务 | 检查 cgroup | nginx, picoclaw, openclaw |
| 关键系统进程 | 命令行匹配 | sshd, journald, docker |
| 持久化应用 | 关键字匹配 | persist, daemon, agent |
| 活跃网络连接 | ss 检查 ESTAB | SSH 会话 |
| 活跃 I/O | /proc/pid/io | 读写文件的进程 |

### 卡死评分系统

| 特征 | 分数 | 说明 |
|------|------|------|
| 进程状态 D (不可中断睡眠) | +100 | 几乎肯定是卡死 |
| 孤儿进程 | +40 | 父进程已结束 |
| CPU = 0% | +20 | 无 CPU 活动 |
| 无网络 + 无 I/O | +15 | 完全无活动 |
| 运行 > 10 分钟 | +10 | 时间过长 |

**总分 >= 50 才会被清理**

## 使用示例

```bash
# 执行清理
sudo /opt/aiagentwatchdog/cleanup_stuck.sh

# 只查看，不清理（dry-run 模式）
sudo /opt/aiagentwatchdog/cleanup_stuck.sh --dry-run

# 查看日志
tail -f /var/log/cleanup_stuck.log
```

## 配置

编辑 `/opt/aiagentwatchdog/cleanup_stuck.sh` 中的配置：

```bash
# 卡死阈值分数
STUCK_THRESHOLD=50

# 最小运行时间（秒）
MIN_UPTIME=120

# 添加自定义白名单
persist_patterns=(
    "persist"
    "daemon"
    "your_custom_keyword"  # 添加这里
)
```

## 卸载

```bash
sudo /opt/aiagentwatchdog/install.sh --uninstall
```

## 适用场景

- AI Agent 服务（PicoClaw, OpenClaw 等）
- 长时间运行的自动化脚本
- 容易产生僵尸进程的环境
- VPS/云服务器资源管理

## 许可证

MIT License

## 作者

YKaiXu (yukaixu@outlook.com)
