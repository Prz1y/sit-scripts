#!/bin/bash

# Memory Test Procedure Using memtester (4 Hours)
# ================================================

set -euo pipefail

# 初始化变量
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DURATION="4h"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOG_DIR="$SCRIPT_DIR/memtest_logs_$TIMESTAMP"
MEMTESTER_LOG="$LOG_DIR/memtester_output_$TIMESTAMP.log"
TEST_RESULT="UNKNOWN"

# 创建日志目录
mkdir -p "$LOG_DIR"

echo "============================================================"
echo " Memory Test Procedure Using memtester (4 Hours)"
echo "============================================================"
echo "Test Objective:"
echo "    Run memtester for 4 hours to validate memory stability."
echo "    No system hang or ECC errors should occur during the test."
echo ""
echo "Prerequisites:"
echo "    - memtester installed (yum install memtester / apt install memtester)"
echo "    - Root or sudo privileges"
echo "    - Sufficient free memory available"
echo ""

# 检查是否为root用户
if [[ $EUID -ne 0 ]]; then
   echo "This script should be run as root for full functionality"
   echo "Some log collection features may not work properly"
fi

echo "--------------------------------------------------"
echo "Step 1: Check Available Memory"
echo "--------------------------------------------------"
free -h
echo ""
grep MemAvailable /proc/meminfo

# 计算可用于测试的内存大小
# 预留至少1GB或总内存的5%（取较大值），防止OOM killer触发
AVAILABLE_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RESERVE_MIN_KB=$((1024*1024))                         # 1GB 最小预留
RESERVE_PCT_KB=$((TOTAL_KB * 5 / 100))                 # 总内存的 5%
if [ "$RESERVE_PCT_KB" -gt "$RESERVE_MIN_KB" ]; then
    RESERVE_KB=$RESERVE_PCT_KB
else
    RESERVE_KB=$RESERVE_MIN_KB
fi
echo "Reserving $((RESERVE_KB / 1024)) MB for system ($((RESERVE_KB * 100 / TOTAL_KB))% of total)"

TEST_KB=$((AVAILABLE_KB - RESERVE_KB))
if [ $TEST_KB -lt 524288 ]; then  # 小于512MB
    echo "ERROR: Not enough memory available for testing"
    exit 1
fi
MEM_SIZE="${TEST_KB}K"
echo "Will test with: $MEM_SIZE"

# Check if memtester is installed
if ! command -v memtester >/dev/null 2>&1; then
    echo "ERROR: memtester not found. Please install it first:"
    echo "  CentOS/RHEL: yum install memtester"
    echo "  Ubuntu/Debian: apt install memtester"
    exit 1
fi

echo "--------------------------------------------------"
echo "Step 2: Clear System Log Before Test"
echo "--------------------------------------------------"
echo "[Step 2] Clearing system log before test..."
dmesg -C 2>/dev/null || echo "Unable to clear dmesg (need root)"
echo "Test started at $(date)" > "$LOG_DIR/test_start_marker.txt"

echo "--------------------------------------------------"
echo "Step 3: Start memtester (Run for 4 Hours)"
echo "--------------------------------------------------"
echo "[Step 3] Starting memtester for 4 hours..."
echo "  Command: timeout $DURATION memtester $MEM_SIZE 0"
timeout "$DURATION" memtester "$MEM_SIZE" 0 > "$MEMTESTER_LOG" 2>&1 &
MEMTESTER_PID=$!
echo "  memtester PID: $MEMTESTER_PID"

echo "  Test running... (checking every 60 seconds)"
while kill -0 "$MEMTESTER_PID" 2>/dev/null; do
    echo "  $(date): memtester still running (PID: $MEMTESTER_PID)"
    tail -n 5 "$MEMTESTER_LOG" 2>/dev/null | grep -v "^$"
    sleep 60
done

set +e
wait "$MEMTESTER_PID" 2>/dev/null
MEMTESTER_EXIT=$?
set -e
echo "[Step 3] memtester finished (exit code: $MEMTESTER_EXIT)."

echo "--------------------------------------------------"
echo "Step 4: Collect BMC Log During / After Test"
echo "--------------------------------------------------"
echo "[Step 4] Collecting BMC SEL log..."
if command -v ipmitool >/dev/null 2>&1; then
    ipmitool sel list  > "$LOG_DIR/bmc_sel_log_$TIMESTAMP.log" 2>&1 || echo "BMC SEL collection failed" >> "$LOG_DIR/bmc_sel_log_$TIMESTAMP.log"
    ipmitool sel elist >> "$LOG_DIR/bmc_sel_log_$TIMESTAMP.log" 2>&1 || true
    ipmitool event list > "$LOG_DIR/bmc_event_log_$TIMESTAMP.log" 2>&1 || echo "BMC event collection failed" >> "$LOG_DIR/bmc_event_log_$TIMESTAMP.log"
    echo "  BMC logs saved to $LOG_DIR/"
else
    echo "  ipmitool not found, skipping BMC log collection"
    echo "ipmitool not available" > "$LOG_DIR/bmc_missing.txt"
fi

echo "--------------------------------------------------"
echo "Step 5: Collect System Log After Test"
echo "--------------------------------------------------"
echo "[Step 5] Collecting system logs..."
dmesg > "$LOG_DIR/dmesg_after_test_$TIMESTAMP.log" 2>&1
if [ -f /var/log/messages ]; then
    cp /var/log/messages "$LOG_DIR/system_messages_$TIMESTAMP.log"
else
    echo "No /var/log/messages found" > "$LOG_DIR/messages_missing.txt"
fi
journalctl --since "$(cut -d' ' -f4- "$LOG_DIR/test_start_marker.txt")" > "$LOG_DIR/journalctl_$TIMESTAMP.log" 2>&1 || echo "journalctl failed" > "$LOG_DIR/journalctl_error.txt"

echo "  Checking ECC errors in dmesg..."
ECC_ERRORS=$(dmesg | grep -i "ecc\|edac\|memory error\|corrected\|uncorrected" || true)
if [ -n "$ECC_ERRORS" ]; then
    echo "$ECC_ERRORS" > "$LOG_DIR/ecc_errors_found.log"
    echo "  [WARN] ECC errors found! Check $LOG_DIR/ecc_errors_found.log"
else
    echo "  No ECC errors found in dmesg"
fi

echo "  Checking ECC via edac tools..."
if command -v edac-util >/dev/null 2>&1; then
    edac-util -s > "$LOG_DIR/edac_status.log" 2>&1 || true
else
    echo "edac-util not available" > "$LOG_DIR/edac_missing.txt"
fi

echo "--------------------------------------------------"
echo "Step 6: Check memtester Result"
echo "--------------------------------------------------"
echo "[Step 6] Checking memtester result..."
if [ -f "$MEMTESTER_LOG" ]; then
    FAILURES=$(grep -i "FAILURE\|fail\|error" "$MEMTESTER_LOG" | head -10 || true)
    if [ -n "$FAILURES" ] || [ "$MEMTESTER_EXIT" -ne 0 ]; then
        echo "  [WARN] Failures/Errors found or non-zero exit (${MEMTESTER_EXIT}):"
        echo "$FAILURES" | tee "$LOG_DIR/memtester_failures.log"
        TEST_RESULT="FAIL"
    else
        echo "  No failures found in memtester log."
        TEST_RESULT="PASS"
    fi
else
    echo "  [ERROR] memtester log not found!"
    TEST_RESULT="FAIL"
fi

echo "--------------------------------------------------"
echo "Step 7: Package All Logs"
echo "--------------------------------------------------"
echo "[Step 7] Packaging all logs..."
PACKAGE="$SCRIPT_DIR/memtest_logs_$TIMESTAMP.tar.gz"
tar -czf "$PACKAGE" -C "$SCRIPT_DIR" "memtest_logs_$TIMESTAMP" 2>/dev/null || echo "Failed to create package"
echo "  All logs packaged to $PACKAGE"

echo "--------------------------------------------------"
echo "Test Record"
echo "--------------------------------------------------"
RECORD_FILE="$LOG_DIR/test_record_$TIMESTAMP.txt"
cat <<EOF > "$RECORD_FILE"
============================================================
 Test Record
============================================================
Test Date       : $(date)
Tester          : $(whoami)
Server Model    : $(dmidecode -s system-product-name 2>/dev/null || echo "N/A")
Memory Config   : $(free -h | head -2)
Test Duration   : 4 Hours
memtester Cmd   : timeout "$DURATION" memtester "$MEM_SIZE" 0
System Hang     : NO
ECC Error       : $([ -f "$LOG_DIR/ecc_errors_found.log" ] && echo "YES (check ecc_errors_found.log)" || echo "NO")
BMC Log File    : $LOG_DIR/bmc_sel_log_$TIMESTAMP.log
System Log File : $LOG_DIR/system_messages_$TIMESTAMP.log
Test Result     : $TEST_RESULT
Package File    : $PACKAGE
Remarks         : $([ "$TEST_RESULT" = "FAIL" ] && echo "Check failure logs" || echo "Test completed successfully")
============================================================
EOF

echo "  Test record saved to $RECORD_FILE"
echo "============================================================"
echo " Test completed. Result: $TEST_RESULT"
echo "============================================================"

echo ""
echo "Log Files Summary:"
echo "=================="
echo "Main log directory: $LOG_DIR"
echo "Test record: $RECORD_FILE"
echo "Packaged logs: $PACKAGE"
echo "Key files to check:"
echo "  - memtester output: $MEMTESTER_LOG"
echo "  - ECC errors: $LOG_DIR/ecc_errors_found.log (if exists)"
echo "  - System logs: $LOG_DIR/dmesg_after_test_$TIMESTAMP.log"
echo "  - BMC logs: $LOG_DIR/bmc_sel_log_$TIMESTAMP.log (if ipmitool available)"

exit 0
