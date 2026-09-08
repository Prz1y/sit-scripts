#!/bin/bash

set -euo pipefail

# ================= Configuration =================
LOOP_COUNT=10
WAIT_TIME=10
# =============================================

# Check Root
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Please run as root (sudo)."
  exit 1
fi

echo "============================================================"
echo "NVMe Driver Stress Test (Visible Checks)"
echo "Loop Count: $LOOP_COUNT"
echo "============================================================"

for ((i=1; i<=LOOP_COUNT; i++)); do
    echo ""
    echo "############################################################"
    echo " ROUND $i / $LOOP_COUNT"
    echo "############################################################"

    # ================= Step 2: Unload Driver =================
    echo "[Action] Executing: modprobe -r nvme"
    if ! modprobe -r nvme; then
        echo "FATAL ERROR: modprobe -r nvme failed." >&2
        exit 1
    fi
    
    echo ""
    echo "[Check 1] Executing command: ls -1 /dev/nvme*"
    echo "------------------------------------------------"
    # 执行 ls 命令，并将 标准输出 和 错误输出 都捕获
    # 预期结果是看到 "No such file or directory"
    LS_OUTPUT=$(ls -1 /dev/nvme* 2>&1 || true)
    echo "$LS_OUTPUT"
    echo "------------------------------------------------"

    echo ""
    echo "[Check 2] Executing command: lsmod | grep '^nvme '"
    echo "------------------------------------------------"
    # 执行 lsmod 命令
    # 预期结果是没有任何输出 (Empty)
    LSMOD_OUTPUT=$(lsmod | grep "^nvme " 2>&1 || true)
    if [ -z "$LSMOD_OUTPUT" ]; then
        echo "(No Output - Module is unloaded)"
    else
        echo "$LSMOD_OUTPUT"
    fi
    echo "------------------------------------------------"

    # 逻辑判断是否继续
    if [[ "$LS_OUTPUT" != *"No such file"* && "$LS_OUTPUT" != "" ]]; then
        echo "FATAL ERROR: NVMe devices still exist. Stopping test."
        exit 1
    fi

    sleep 2

    # ================= Step 3: Load Driver =================
    echo ""
    echo "[Action] Executing: modprobe nvme"
    modprobe nvme
    
    echo "Waiting ${WAIT_TIME}s for devices to initialize..."
    sleep $WAIT_TIME
    
    # Check if devices appeared
    CONTROLLERS=$(for f in /dev/nvme*; do [[ "$f" =~ n[0-9]+p[0-9]+$ ]] || echo "$f"; done 2>/dev/null)
    if [ -z "$CONTROLLERS" ]; then
            echo "FATAL ERROR: No devices found after load."
            exit 1
    fi

    # ================= Grouped dmesg Logic =================
    echo ""
    echo "[Check 3] Kernel Log (dmesg) - Grouped by Capacity:"
    
    TMP_LOGS="/tmp/nvme_dmesg_grouped.txt"
    : > "$TMP_LOGS"

    for ctrl in $CONTROLLERS; do
        # 1. Get Capacity
        SIZE=$(lsblk -d -n -o SIZE "${ctrl}n1" 2>/dev/null | tr -d ' ')
        if [ -z "$SIZE" ]; then SIZE="Unknown"; fi
        
        # 2. Get Device Name
        NAME=$(basename "$ctrl")
        
        # 3. Fetch log
        LOG_LINE=$(dmesg | grep "$NAME:" | grep "queues" | tail -n 1)
        if [ -z "$LOG_LINE" ]; then LOG_LINE="(No init log found)"; fi

        echo "${SIZE}__${LOG_LINE}" >> "$TMP_LOGS"
    done

    # 4. Sort and Display
    LAST_SIZE=""
    sort -V "$TMP_LOGS" | while read -r line; do
        CURRENT_SIZE=${line%%__*}
        LOG_TEXT=${line#*__}

        if [ "$CURRENT_SIZE" != "$LAST_SIZE" ]; then
            echo "------------------------------------------------"
            echo " Capacity Group: $CURRENT_SIZE"
            echo "------------------------------------------------"
            LAST_SIZE="$CURRENT_SIZE"
        fi
        echo "$LOG_TEXT"
    done
    
    echo "------------------------------------------------"
    rm -f "$TMP_LOGS"

done

echo ""
echo "============================================================"
echo "Test Completed."
echo "============================================================"
