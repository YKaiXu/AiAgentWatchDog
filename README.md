# AiAgentWatchDog

智能监控和清理 AI Agent 卡死进程的工具

## 特性

- **智能评分系统** - 多维度检测卡死进程，避免误杀
- **多层保护机制** - 保护 systemd 服务、关键进程、持久化应用
- **systemd 服务安全重启** - 通过 systemctl restart 而非 kill
- **D 状态进程强制终止** - 不可中断睡眠进程的特殊处理
- **定时清理** - 通过 systemd timer 每分钟自动执行
- **详细日志** - 记录清理原因和评分详情
- **易于配置** - 支持自定义白名单和阈值

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

### 进程状态说明

| 状态 | 名称 | 说明 | 处理 |
|------|------|------|------|
| R | 运行中 | 正常运行 | 不处理 |
| S | 可中断睡眠 | 正常等待 | 不处理 |
| **D** | **不可中断睡眠** | **可能卡死** | **强制终止** |
| Z | 僵尸进程 | 需要清理 | 清理 |
| T | 停止 | 被暂停 | 不处理 |

### 保护机制（不会被清理）

| 保护类型 | 检测方法 | 示例 |
|---------|---------|------|
| 关键系统进程 | 命令行匹配 | sshd, journald, systemd |
| 持久化应用 | 关键字匹配 | persist, daemon, tmux |
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

### 清理策略

```
检测到卡死进程 (评分 >= 50)
    ↓
判断进程类型
    ├── 关键系统进程 → 保护，不清理
    ├── 持久化应用 → 保护，不清理
    ├── 有活跃连接/I/O → 保护，不清理
    │
    └── 需要清理
        ├── systemd 服务进程
        │   ├── systemctl restart 成功 → 完成
        │   └── systemctl restart 失败
        │       └── 进程状态=D → 强制 kill -9
        │
        └── 普通进程 → kill -9
```

### D 状态进程处理

**什么是 D 状态？**

D 状态（不可中断睡眠）的进程正在等待 I/O 操作完成（磁盘、网络、NFS 等），无法响应信号。

**为什么需要特殊处理？**

- D 状态进程无法被 `kill -9` 立即杀死
- 只能等待 I/O 完成或系统重启
- 但 `kill -9` 会在进程恢复时立即终止它

**处理流程：**

```
D 状态进程检测
    ↓
尝试 systemctl restart
    ↓
失败？
    ├── 是 → 发送 kill -9 信号
    │        ↓
    │   进程恢复时会被终止
    │
    └── 否 → 完成
```

## 使用示例

```bash
# 执行清理
sudo /opt/aiagentwatchdog/cleanup_stuck.sh

# 只查看，不清理（dry-run 模式）
sudo /opt/aiagentwatchdog/cleanup_stuck.sh --dry-run

# 查看帮助
sudo /opt/aiagentwatchdog/cleanup_stuck.sh --help

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

# D 状态进程强制终止
D_STATE_FORCE_KILL=true

# 添加自定义白名单
persist_patterns=(
    "persist"
    "daemon"
    "your_custom_keyword"  # 添加这里
)
```

## 日志示例

```
[2026-02-17 15:35:02] ========== 开始扫描 ==========
[2026-02-17 15:35:02] 🔄 重启 systemd 服务: picoclaw
[2026-02-17 15:35:02]    PID: 564796, 分数: 165 [状态=D] [孤儿进程] [无活动]
[2026-02-17 15:35:02]    CMD: python3 simple_integration.py yupeng ykx130729
[2026-02-17 15:35:02]    ❌ systemctl restart 失败
[2026-02-17 15:35:02]    ⚠️ 进程处于 D 状态，尝试强制终止...
[2026-02-17 15:35:02]    🔨 强制终止进程 (原因: D状态进程-systemctl重启失败)
[2026-02-17 15:35:02]    ✅ 进程已强制终止
[2026-02-17 15:35:04] ========== 扫描完成 ==========
[2026-02-17 15:35:04] 普通进程清理: 0
[2026-02-17 15:35:04] 服务重启: 0
[2026-02-17 15:35:04] 强制终止(D状态): 1
[2026-02-17 15:35:04] 受保护: 0
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
- SSH 连接卡死的进程

## 已部署主机

- OVH VPS (51.81.223.234) - PicoClaw
- AI 主机 (192.168.1.8) - OpenClaw

## 更新日志

### v1.1.0 (2026-02-17)
- 新增 D 状态进程强制终止功能
- 改进 systemd 服务重启失败后的处理
- 添加详细的进程状态说明
- 优化日志输出格式

### v1.0.0
- 初始版本
- 智能评分系统
- systemd 服务安全重启
- 多层保护机制

## 许可证

MIT License

## 作者

YKaiXu (yukaixu@outlook.com)
