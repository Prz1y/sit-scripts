#!/bin/bash
# ==============================================================================
# NVMe Parallel Physical Slot Power Cycle Test
# Target: /sys/bus/pci/slots/ID/power (0=Off, 1=On)
# WARNING: This script power-cycles NVMe slots and writes test data directly to
# target devices. Run it only on RD/lab machines where data loss is acceptable.
# ==============================================================================

set -e
set -o pipefail

echo "WARNING: nvme_slot_power_test.sh will power-cycle NVMe slots and write test data directly to disks." >&2

# --- 1. 环境准备 ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="nvme_physical_test_$TIMESTAMP"
SUMMARY_LOG="$LOG_DIR/SUMMARY.log"
mkdir -p "$LOG_DIR/details" "$LOG_DIR/smart"

# 强制开启轮询模式，解决下电后自动上电或不识别问题
echo 1 > /sys/module/pciehp/parameters/pciehp_poll_mode || true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$SUMMARY_LOG"; }

# 捕获 Ctrl+C，确保杀掉所有后台 FIO 进程
trap 'log "User Abort. Cleaning up..."; kill 0; exit 1' SIGINT SIGTERM

# --- 2. 单盘测试逻辑 ---
test_drive() {
    local dev_path=$1
    local dev_name=$(basename "$dev_path")
    local detail_log="$LOG_DIR/details/${dev_name}.log"
    
    {
        echo "=== Starting Physical Power Test for $dev_name ==="
        
        # A. 获取 PCI 地址并匹配 Slot ID
        local pci_link="/sys/class/block/$dev_name/device/device"
        local pci_full=$(basename "$(readlink -f "$pci_link")")
        local pci_base=$(echo "$pci_full" | cut -d'.' -f1) # 得到 0000:41:00
        
        local slot_file=$(grep -l "^$pci_base" /sys/bus/pci/slots/*/address | head -n 1 || true)
        if [ -z "$slot_file" ]; then
            echo "ERROR: No slot found for $pci_base"
            return 1
        fi
        local slot_id=$(basename "$(dirname "$slot_file")")
        local slot_pwr_path="/sys/bus/pci/slots/$slot_id/power"
        
        echo "Device: $dev_name | PCI: $pci_full | Slot: $slot_id"

        # B. 记录初始 SMART
        echo "Action: Recording initial SMART info..."
        nvme smart-log "$dev_path" > "$LOG_DIR/smart/before_${dev_name}.log" 2>&1 || true

        # C. 启动 FIO 顺序混合读写 (7:3)
        echo "Action: Starting FIO 7:3 Stress..."
        fio --name="stress_$dev_name" --filename="$dev_path" --direct=1 --rw=rw --rwmixread=70 \
            --ioengine=libaio --bs=128k --runtime=600 --group_reporting --thread > /dev/null 2>&1 &
        sleep 5

        # D. 步骤 4: 物理下电
        echo "Action: Powering OFF via $slot_pwr_path"
        if ! echo 0 > "$slot_pwr_path"; then
            echo "RESULT_OFF: FAIL (Write Error)"
        else
            sleep 3
            # 步骤 5: 验证无法识别
            if [ ! -e "/dev/$dev_name" ]; then
                echo "RESULT_OFF: PASS (Device Disappeared)"
            else
                echo "RESULT_OFF: FAIL (Device Still Exists)"
            fi
        fi

        # E. 步骤 6: 物理上电
        echo "Action: Powering ON via $slot_pwr_path"
        echo 1 > "$slot_pwr_path"
        
        # F. 步骤 7: 验证识别与读写
        echo "Waiting for device to reappear..."
        local found=false
        for _ in {1..30}; do
            [ -e "$dev_path" ] && { found=true; break; }
            sleep 1
        done

        if [ "$found" = true ]; then
            echo "RESULT_ON: PASS (Device Recovered)"
            # 记录上电后 SMART
            nvme smart-log "$dev_path" > "$LOG_DIR/smart/after_${dev_name}.log" 2>&1 || true
            
            # 验证写功能
            echo "Action: Verifying Write Function..."
            if dd if=/dev/zero of="$dev_path" bs=1M count=100 oflag=direct status=none; then
                echo "WRITE_TEST: PASS"
            else
                echo "WRITE_TEST: FAIL"
            fi
        else
            echo "RESULT_ON: FAIL (Timeout)"
        fi
        
        echo "=== Finished Test for $dev_name ==="
    } > "$detail_log" 2>&1
}

# --- 3. 主流程控制 ---
drives=$(ls /dev/nvme*n1 | sort -V)
log "Found $(wc -w <<< \"$drives\") drives. Starting parallel physical power cycle..."

pids=()
for d in $drives; do
    test_drive "$d" &
    pids+=("$!")
done

log "All threads launched. Waiting for completion..."
failed_pids=()
for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        failed_pids+=("$pid")
    fi
done
if [ ${#failed_pids[@]} -gt 0 ]; then
    log "ERROR: Some worker threads failed: ${failed_pids[*]}"
fi

# --- 4. 结果汇总矩阵 ---
echo -e "\n======================================================================" | tee -a "$SUMMARY_LOG"
echo -e "FINAL VERIFICATION MATRIX" | tee -a "$SUMMARY_LOG"
echo -e "======================================================================" | tee -a "$SUMMARY_LOG"
printf "%-12s | %-10s | %-10s | %-10s | %-8s\n" "Drive" "Slot" "Power-Off" "Power-On" "Write" | tee -a "$SUMMARY_LOG"
echo "----------------------------------------------------------------------" | tee -a "$SUMMARY_LOG"

for d in $drives; do
    name=$(basename "$d")
    d_log="$LOG_DIR/details/${name}.log"
    
    sid=$(grep "Slot:" "$d_log" | awk '{print $NF}' || echo "N/A")
    off=$(grep "RESULT_OFF:" "$d_log" | awk '{print $2}' || echo "FAIL")
    on=$(grep "RESULT_ON:" "$d_log" | awk '{print $2}' || echo "FAIL")
    wr=$(grep "WRITE_TEST:" "$d_log" | awk '{print $2}' || echo "FAIL")
    
    printf "%-12s | %-10s | %-10s | %-10s | %-8s\n" "$name" "$sid" "$off" "$on" "$wr" | tee -a "$SUMMARY_LOG"
done

log "Test complete. Detailed logs: $LOG_DIR/details/"
if [ ${#failed_pids[@]} -gt 0 ]; then
    exit 1
fi
