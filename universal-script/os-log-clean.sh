#!/bin/bash
set -euo pipefail
# 清理日志用
# Author : Prz1y
# WARNING:
#   This script truncates and deletes system logs under /var/log and /tmp.
#   Run it only on RD/lab machines where loss of diagnostic history is acceptable.

echo "WARNING: os-log-clean.sh will truncate or delete system logs and temporary log directories." >&2

echo "[$(date)] ========== 开始清理日志 =========="

# 1. 清空 systemd journalctl 日志
echo "[$(date)] 清理 journalctl..."
sudo journalctl --rotate
sudo journalctl --vacuum-size=1M 2>/dev/null || true

# 2. 清空系统日志文件
echo "[$(date)] 清空 /var/log/ 下的日志..."
sudo find /var/log -type f \( -name "*.log" -o -name "*.log.*" \) \
    ! -name "*.gz" ! -name "*.zip" ! -name "*.xz" ! -name "*.bz2" \
    -exec truncate -s 0 {} \; 2>/dev/null

# 3. 删除压缩的旧日志
echo "[$(date)] 删除压缩日志..."
sudo find /var/log -type f -name "*.gz" -delete 2>/dev/null
sudo find /var/log -type f -name "*.zip" -delete 2>/dev/null
sudo find /var/log -type f -name "*.xz" -delete 2>/dev/null
sudo find /var/log -type f -name "*.bz2" -delete 2>/dev/null
sudo find /var/log -type f -regex '.*\.[0-9]+$' -delete 2>/dev/null

# 4. 清空内核 ring buffer（dmesg）
echo "[$(date)] 清空 dmesg..."
sudo dmesg --clear 2>/dev/null || true

# 5. 清空特定服务日志（如果有的话）
echo "[$(date)] 清空特定服务日志..."
sudo truncate -s 0 /var/log/auth.log 2>/dev/null
sudo truncate -s 0 /var/log/syslog 2>/dev/null
sudo truncate -s 0 /var/log/messages 2>/dev/null
sudo truncate -s 0 /var/log/secure 2>/dev/null
sudo truncate -s 0 /var/log/kern.log 2>/dev/null
sudo truncate -s 0 /var/log/wtmp 2>/dev/null
sudo truncate -s 0 /var/log/btmp 2>/dev/null
sudo truncate -s 0 /var/log/lastlog 2>/dev/null
sudo find /var/log/audit -type f -exec truncate -s 0 {} \; 2>/dev/null

# 6. 清理临时日志目录
echo "[$(date)] 清理临时日志..."
sudo find /tmp -maxdepth 1 -type f -name "sit-kit*.log*" -delete 2>/dev/null || true
sudo find /tmp -maxdepth 1 \( -type f -o -type d \) -name "sit-kit-test*" -exec rm -rf {} + 2>/dev/null || true

# 7. 如果有 BMC/iLO 本地缓存日志
echo "[$(date)] 清理 BMC 相关缓存..."
sudo truncate -s 0 /var/log/ipmitool.log 2>/dev/null

# 8. 清理应用日志（根据你的实际应用调整）
# sudo truncate -s 0 /path/to/app/*.log 2>/dev/null

echo "[$(date)] 验证清理结果..."
echo "journalctl 占用: $(sudo journalctl --disk-usage 2>/dev/null || echo 'N/A')"
echo "/var/log 目录大小: $(sudo du -sh /var/log 2>/dev/null || echo 'N/A')"
echo "dmesg 缓冲: $(dmesg | wc -l) 行"

echo "[$(date)] ========== 日志清理完成 =========="
