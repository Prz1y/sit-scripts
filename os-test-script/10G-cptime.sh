#!/bin/bash

set -euo pipefail

# --- 配置参数 ---
FILE_SIZE="10G"              # 测试文件大小
TEST_DIR="."                 # 当前目录
LOG_DIR="$TEST_DIR/test_logs" # 日志存放文件夹
TEST_FILE="test_source_10G"
COPY_FILE="test_target_10G"
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/copy_test_$TIMESTAMP.log"
trap 'rm -f "$TEST_FILE" "$COPY_FILE" 2>/dev/null || true' EXIT INT TERM

# --- 创建日志目录 ---
mkdir -p "$LOG_DIR"

# 定义日志记录函数
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# --- 检查 root 权限（drop_caches 必需） ---
if [ "$EUID" -ne 0 ]; then
    log "错误: 此脚本需要 root 权限执行 (需要 echo 3 > /proc/sys/vm/drop_caches)"
    log "请使用: sudo bash $0"
    exit 1
fi

log "==========================================="
log "磁盘同盘拷贝测试开始 - $TIMESTAMP"
log "测试文件大小: $FILE_SIZE"
log "==========================================="

# 1. 生成测试文件 (如果不存在)
if [ ! -f "$TEST_FILE" ]; then
    log "[1/3] 正在生成 $FILE_SIZE 的测试文件..."
    dd if=/dev/zero of="$TEST_FILE" bs=1M count=$(( ${FILE_SIZE%G} * 1024 )) status=progress 2>&1 | tee -a "$LOG_FILE"
    sync
else
    log "[1/3] 测试文件已存在，跳过创建。"
fi

# 2. 清除系统缓存
log "[2/3] 正在清除系统缓存..."
sync && echo 3 > /proc/sys/vm/drop_caches
log "缓存已清除。"

# 3. 开始拷贝测试并计时
log "[3/3] 开始拷贝文件..."
log "命令: cp $TEST_FILE $COPY_FILE && sync"

# time 输出到 stderr，cp stdout 单独捕获
{ time ( cp "$TEST_FILE" "$COPY_FILE" && sync ) ; } >> "$LOG_FILE" 2>&1

# 4. 计算并输出简要总结
log "-------------------------------------------"
log "测试完成！"
log "详细计时结果已保存至: $LOG_FILE"
log "运行以下命令删除测试文件:"
log "rm $TEST_FILE $COPY_FILE"
log "-------------------------------------------"
