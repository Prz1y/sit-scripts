#!/bin/bash

# 获取脚本所在目录
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 用户配置（直接修改这里）
TARGET_DEVICE="${1:-/dev/sdb}"
DURATION=14400
FIO_SIZE="100G"               # 测试数据范围 per job；大容量盘建议设为全盘容量或更大

# 日志文件
REPORT_FILE="$SCRIPT_DIR/fio_test_report_${TIMESTAMP}.log"
DMESG_LOG="$SCRIPT_DIR/dmesg_${TIMESTAMP}.log"
MESSAGE_LOG="$SCRIPT_DIR/message_${TIMESTAMP}.log"
BMC_LOG="$SCRIPT_DIR/bmc_${TIMESTAMP}.log"
FIO_RESULT="$SCRIPT_DIR/fio_result_${TIMESTAMP}.log"

# 全局 PID 变量
DMESG_PID=""
MESSAGE_PID=""
BMC_PID=""

check_device_safety() {
    local dev="$1"

    if [ ! -b "$dev" ]; then
        echo "错误: 设备 $dev 不存在或不是块设备"
        exit 1
    fi

    # 检查是否被挂载为根分区
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    if [ -n "$root_dev" ]; then
        local root_real dev_real
        root_real=$(readlink -f "$root_dev" 2>/dev/null || echo "$root_dev")
        dev_real=$(readlink -f "$dev" 2>/dev/null || echo "$dev")
        if [ "$root_real" = "$dev_real" ]; then
            echo "错误: $dev 是系统根分区，无法安全测试"
            exit 1
        fi
    fi

    # 检查设备是否有任何挂载点
    local mounts
    mounts=$(lsblk -n -o MOUNTPOINT "$dev" 2>/dev/null | grep -v '^$' || true)
    if [ -n "$mounts" ]; then
        echo "警告: $dev 存在挂载点，继续测试将破坏数据："
        echo "$mounts"
        echo ""
        read -p "确认继续？(y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "已取消"
            exit 1
        fi
    fi

    # 获取设备容量信息
    local dev_size_human
    dev_size_human=$(lsblk -d -n -o SIZE "$dev" 2>/dev/null | tr -d ' ')
    echo "设备 $dev 容量: ${dev_size_human:-未知}"
}

check_device_safety "$TARGET_DEVICE"
echo "[WARN] 即将对 $TARGET_DEVICE 执行随机读写测试，设备上的现有数据可能被覆盖"

start_log_collection() {
    dmesg -w > "$DMESG_LOG" 2>&1 &
    DMESG_PID=$!
    
    tail -f /var/log/messages > "$MESSAGE_LOG" 2>&1 &
    MESSAGE_PID=$!
    
    {
        while true; do
            echo "=== $(date) ===" >> "$BMC_LOG"
            ipmitool sel list >> "$BMC_LOG" 2>&1
            sleep 60
        done
    } &
    BMC_PID=$!
}

stop_log_collection() {
    local pids=()
    # dmesg -w 在旧内核上可能不响应 SIGTERM，先 TERM 再 KILL 兜底
    if [ -n "$DMESG_PID" ]; then
        kill "$DMESG_PID" 2>/dev/null
        sleep 1
        kill -0 "$DMESG_PID" 2>/dev/null && kill -9 "$DMESG_PID" 2>/dev/null
        pids+=("$DMESG_PID")
    fi
    [ -n "$MESSAGE_PID" ] && kill "$MESSAGE_PID" 2>/dev/null && pids+=("$MESSAGE_PID")
    [ -n "$BMC_PID" ] && kill "$BMC_PID" 2>/dev/null && pids+=("$BMC_PID")
    [ ${#pids[@]} -gt 0 ] && wait "${pids[@]}" 2>/dev/null
}

{
    echo "================ FIO 测试记录 - $(date '+%Y-%m-%d %H:%M:%S') ================"
    echo "--- 环境记录 ---"
    echo "内核版本: $(uname -a)"
    echo "操作系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'N/A')"
    echo "CPU信息: $(lscpu 2>/dev/null | grep 'Model name' | sed 's/Model name:[[:space:]]*//' || echo 'N/A')"
    echo "内存信息: $(free -h 2>/dev/null | grep Mem | awk '{print $2}' || echo 'N/A')"
    echo "FIO版本: $(fio --version 2>/dev/null || echo 'N/A')"
    echo "磁盘信息: $(lsblk -d -n -o NAME,SIZE 2>/dev/null | grep -E "^${TARGET_DEVICE##*/}" || echo 'N/A')"
    echo "------------------------------------------------"
    echo "测试设备: $TARGET_DEVICE"
    echo "测试数据范围: $FIO_SIZE (每个 job)"
    echo "测试时长: $(( DURATION / 3600 ))小时 ($DURATION 秒)"
    echo "测试开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "日志位置: $SCRIPT_DIR"
    echo "------------------------------------------------"
} >> "$REPORT_FILE" 2>&1

start_log_collection

fio --name=rw_test --rw=randrw --rwmixread=70 --bs=4k --size="$FIO_SIZE" \
    --numjobs=4 --runtime="$DURATION" --time_based --group_reporting \
    --filename="$TARGET_DEVICE" --output="$FIO_RESULT" 2>&1
FIO_EXIT=$?

sleep 2
stop_log_collection

{
    echo "测试结束时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================"
    echo "输出文件："
    echo "  - 测试报告: $(basename "$REPORT_FILE")"
    echo "  - dmesg日志: $(basename "$DMESG_LOG")"
    echo "  - message日志: $(basename "$MESSAGE_LOG")"
    echo "  - BMC日志: $(basename "$BMC_LOG")"
    echo "  - FIO结果: $(basename "$FIO_RESULT")"
    echo "================================================"
} >> "$REPORT_FILE" 2>&1

if [ "$FIO_EXIT" -ne 0 ]; then
    {
        echo "错误: fio 测试失败 (退出码: $FIO_EXIT)"
        echo "测试结束时间: $(date '+%Y-%m-%d %H:%M:%S')"
    } >> "$REPORT_FILE" 2>&1
    echo "✗ FIO 测试失败 (退出码: $FIO_EXIT)"
    echo "✗ 详细结果请查看: $(basename "$FIO_RESULT")"
    exit 1
fi

echo "✓ FIO 测试已完成"
echo "✓ 所有结果已保存至: $SCRIPT_DIR"
echo "✓ 报告文件: $(basename "$REPORT_FILE")"
