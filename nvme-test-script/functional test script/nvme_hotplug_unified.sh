#!/bin/bash
#
# WARNING:
#   This script will wipe partition tables, recreate partitions/filesystems,
#   mount/unmount NVMe devices, write test data, and remove on-disk signatures.
#   Run it only on RD/lab machines where data loss is acceptable.
#

set -euo pipefail
shopt -s nullglob
# ==============================================================================
# NVMe Hotplug Test 
# 功能: 物理热插拔测试 (暴力拔盘)，不通知操作系统下电
# ==============================================================================

# --- 1. 参数解析与配置 ---
DEVICE_A=$1     # 被测盘A
DEVICE_B=$2     # 被测盘B
MODE=$3         # 模式: 1=Fast, 2=Slow, 3=Slow+IO
TOTAL_LOOPS=$4  # 总循环次数

if [[ -z "$DEVICE_A" || -z "$DEVICE_B" || -z "$MODE" || -z "$TOTAL_LOOPS" ]]; then
    echo "Usage: $0 <Device_A> <Device_B> <Mode> <Total_Loops>"
    echo "Example: $0 /dev/nvme0n1 /dev/nvme1n1 1 20"
    exit 1
fi

echo "WARNING: nvme_hotplug_unified.sh will repartition, reformat, mount, write test data, and wipe NVMe devices. Use only on RD/lab machines." >&2

# 基础配置
WORK_DIR="$(pwd)/Test_Report_Surprise_Mode${MODE}_$(date +%Y%m%d_%H%M%S)"
MOUNT_DIR="/mnt/nvme_test_surprise"
mkdir -p "$WORK_DIR"
mkdir -p "$MOUNT_DIR"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量
BG_FIO_PIDS=""
CURRENT_DEVICE_NAME=""

# --- 2. 核心工具函数 ---

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg"
    echo "$msg" >> "$WORK_DIR/execution_summary.log"
}

get_bdf() {
    local dev_name=$(basename "$1")
    local sys_link
    sys_link=$(readlink -f "/sys/class/block/$dev_name/device/device" 2>/dev/null)
    if [[ -z "$sys_link" ]]; then
        sys_link=$(readlink -f /sys/class/block/$dev_name/device)
    fi
    basename "$sys_link"
}

bg_io_control() {
    local action=$1
    local target_dev=$2
    
    if [[ "$action" == "stop" ]]; then
        if [[ -n "$BG_FIO_PIDS" ]]; then
            # log "Stopping Background IO..."
            kill $BG_FIO_PIDS 2>/dev/null
            wait $BG_FIO_PIDS 2>/dev/null
            BG_FIO_PIDS=""
        fi
        return
    fi

    if [[ "$action" == "start" ]]; then
        log "Starting Background IO on other NVMe drives..."
        local all_devs=(/dev/nvme*n1)
        for dev in "${all_devs[@]}"; do
            if [[ "$dev" != "$target_dev" ]]; then
                fio --name=bg_stress_${dev##*/} --filename=$dev \
                    --ioengine=libaio --direct=1 --rw=read --bs=1024k \
                    --iodepth=32 --numjobs=1 --time_based --runtime=10000 \
                    --group_reporting > /dev/null 2>&1 &
                BG_FIO_PIDS="$BG_FIO_PIDS $!"
            fi
        done
    fi
}

# --- 3. 测试循环 ---
run_cycle() {
    local cycle_id=$1
    local current_dev=$2
    local loop_dir="$WORK_DIR/Loop_${cycle_id}"
    mkdir -p "$loop_dir"
    
    log "=== Starting Loop $cycle_id (Target: $current_dev) ==="

    # [Step 1] 状态检查
    log "Step 1: Checking Initial State..."
    if [ ! -b "$current_dev" ]; then
        log "${RED}FAIL: Device $current_dev not found!${NC}"
        return 1
    fi

    local bdf=$(get_bdf "$current_dev")
    # 这里不再强制检查 Slot Power，因为暴力插拔不需要它
    
    # 记录信息
    echo "Device: $current_dev" > "$loop_dir/Result_A_Info.txt"
    echo "BDF: $bdf" >> "$loop_dir/Result_A_Info.txt"
    lspci -s "$bdf" -vvvxxx > "$loop_dir/Result_A_lspci_dump.txt"
    smartctl -x "$current_dev" > "$loop_dir/Result_A_Smart.txt" 2>&1
    ipmitool sel elist > "$loop_dir/Result_A_BMC.txt" 2>&1
    dmesg -c > "$loop_dir/dmesg_cleared_backup.txt"

    # [Step 2] 准备分区 & IO
    log "Step 2: Preparing Partition & Data..."
    
    # --- 强力清理旧挂载和分区 (同步自新逻辑) ---
    umount -R "$MOUNT_DIR" 2>/dev/null
    for part in "${current_dev}"* ; do umount "$part" 2>/dev/null || true; done
    wipefs -a -q "$current_dev" >/dev/null 2>&1
    partprobe "$current_dev" 2>/dev/null
    udevadm settle
    sleep 1
    # ------------------------------------------

    parted -s "$current_dev" mklabel gpt >/dev/null 2>&1
    parted -s "$current_dev" mkpart primary ext4 0% 10GB >/dev/null 2>&1
    parted -s "$current_dev" mkpart primary 10GB 100% >/dev/null 2>&1
    partprobe "$current_dev" 2>/dev/null
    udevadm settle
    sleep 2
    
    local p1="${current_dev}p1"; [[ ! -e "$p1" ]] && p1="${current_dev}1"
    local p2="${current_dev}p2"; [[ ! -e "$p2" ]] && p2="${current_dev}2"
    
    mkfs.ext4 -F -q "$p1"
    mount "$p1" "$MOUNT_DIR"
    dd if=/dev/urandom of="$MOUNT_DIR/test.bin" bs=1M count=1000 status=none
    local md5_pre=$(md5sum "$MOUNT_DIR/test.bin" | awk '{print $1}')
    local p1_uuid=$(blkid -s UUID -o value "$p1") 
    umount "$MOUNT_DIR"
    echo "$md5_pre" > "$loop_dir/md5_pre.txt"

    # 场景3 IO 处理
    local target_fio_pid=""
    if [[ "$MODE" == "3" ]]; then
        bg_io_control "start" "$current_dev"
        log "Step 2.5: Starting FIO on Target Partition 2 (Surprise Removal Test)..."
        mkfs.ext4 -F -q "$p2"
        mkdir -p "$MOUNT_DIR/p2"
        mount "$p2" "$MOUNT_DIR/p2"
        fio --name=target_stress --ioengine=libaio --size=100% --direct=1 --rw=write \
            --bs=1024k --numjobs=1 --iodepth=32 --directory="$MOUNT_DIR/p2" \
            --time_based --runtime=1000 > "$loop_dir/fio_target.log" 2>&1 &
        target_fio_pid=$!
        sleep 5
    fi

    # [Step 3] 执行移除 (暴力!)
    echo "================================================================"
    echo -e " ${RED}ACTION REQUIRED: SURPRISE REMOVAL${NC}"
    echo -e " Target Device: ${YELLOW}$current_dev${NC} (BDF: $bdf)"
    echo -e " Mode: ${MODE} (IO Running: $(if [[ -n $target_fio_pid ]]; then echo "YES"; else echo "NO"; fi))"
    echo "================================================================"
    log "Step 3: Waiting for physical removal..."
    
    # 循环检查直到设备消失
    local waited=0
    while [ -b "$current_dev" ]; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -gt 300 ]; then
            log "${RED}FAIL: Timed out waiting for device removal${NC}"
            return 1
        fi
    done
    
    log "${GREEN}PASS: Device node removed (Surprise).${NC}"
    
    # 暴力拔盘后，IO 进程可能会挂起或报错，强制清理
    if [[ -n "$target_fio_pid" ]]; then
        kill -9 $target_fio_pid 2>/dev/null
        wait $target_fio_pid 2>/dev/null
    fi
    if [[ "$MODE" == "3" ]]; then
        bg_io_control "stop"
        umount -f "$MOUNT_DIR/p2" 2>/dev/null
    fi

    # [Step 4] 等待
    local wait_time=30
    [[ "$MODE" == "1" ]] && wait_time=5 # 即使是快插，暴力拔除也建议稍等几秒
    
    log "Step 4: Waiting ${wait_time}s..."
    sleep $wait_time

    # [Step 5] 执行插入
    echo "================================================================"
    echo -e " ${CYAN}ACTION REQUIRED: INSERT DRIVE${NC}"
    echo "================================================================"
    
    # 简单的交互式暂停，防止人还没插好脚本就跑飞了
    read -r -p ">> 插好硬盘后，请按 Enter 键继续..."
    
    log "Step 5: Rescanning PCI bus..."
    # 暴力插入后，通常需要 rescan 才能被内核认回
    echo 1 > /sys/bus/pci/rescan
    udevadm settle
    sleep 5
    
    # [Step 6] 恢复验证
    log "Step 6: Verifying Restoration..."

    local new_p1_dev=$(blkid -U "$p1_uuid")
    local new_dev=""
    
    if [[ -n "$new_p1_dev" ]]; then
        new_dev=$(echo "$new_p1_dev" | sed 's/p[0-9]*$//')
    else
        log "${YELLOW}WARN: UUID check delayed, rescanning...${NC}"
        echo 1 > /sys/bus/pci/rescan
        sleep 5
        new_p1_dev=$(blkid -U "$p1_uuid")
        [[ -n "$new_p1_dev" ]] && new_dev=$(echo "$new_p1_dev" | sed 's/p[0-9]*$//')
    fi

    if [[ -z "$new_dev" ]]; then
        log "${RED}FAIL: Drive did not reappear!${NC}"
        return 1
    fi
    
    log "  > Drive reappeared as: $new_dev"
    
    if ! mount "$new_p1_dev" "$MOUNT_DIR" 2>>"$loop_dir/mount_error.log"; then
        log "${RED}FAIL: Mount failed${NC}"
        return 1
    fi
    
    local md5_post=$(md5sum "$MOUNT_DIR/test.bin" | awk '{print $1}')
    umount "$MOUNT_DIR"
    
    if [[ "$md5_pre" == "$md5_post" ]]; then
        log "${GREEN}PASS: MD5 Checksum Matches.${NC}"
        
        # =======================================================
        # [Step 7] 清理环境 (同步自新逻辑)
        # =======================================================
        log "Step 7: Post-Test Cleanup (Wiping Partitions)..."
        wipefs -a -q "$new_dev" >/dev/null 2>&1
        partprobe "$new_dev" 2>/dev/null
        udevadm settle
        # =======================================================
        
        CURRENT_DEVICE_NAME=$new_dev
        return 0
    else
        log "${RED}FAIL: MD5 Mismatch!${NC}"
        return 1
    fi
}

# --- 4. 主程序入口 ---
CUR_A=$DEVICE_A
CUR_B=$DEVICE_B

log "=== Test Suite Started (Surprise Hotplug) ==="
log "Targets: $DEVICE_A <--> $DEVICE_B"
log "Total Loops: $TOTAL_LOOPS | Mode: $MODE"

ipmitool sel clear >/dev/null 2>&1
trap 'bg_io_control stop; echo "Interrupted."; exit 1' INT TERM

for (( i=1; i<=TOTAL_LOOPS; i++ )); do
    log "--------------------------------------------"
    if (( i % 2 != 0 )); then
        TARGET_DEV=$CUR_A; LABEL="A"
    else
        TARGET_DEV=$CUR_B; LABEL="B"
    fi
    
    log "       ROUND $i / $TOTAL_LOOPS  [Testing Device $LABEL]"
    log "--------------------------------------------"

    if ! run_cycle "${i}_Dev${LABEL}" "$TARGET_DEV"; then
        log "${RED}CRITICAL: Test Failed on Device $LABEL at Loop $i${NC}"
        bg_io_control "stop"
        exit 1
    fi
    
    if (( i % 2 != 0 )); then
        CUR_A=$CURRENT_DEVICE_NAME
    else
        CUR_B=$CURRENT_DEVICE_NAME
    fi

    log ">>> Round $i Complete. <<<"
    if [ $i -lt $TOTAL_LOOPS ]; then sleep 3; fi
done

bg_io_control "stop"
log "${GREEN}=== All $TOTAL_LOOPS Rounds Completed Successfully ===${NC}"
log "Report saved to: $WORK_DIR"
