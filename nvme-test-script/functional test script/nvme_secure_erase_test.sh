#!/bin/bash
# ==============================================================================
# Script Name: nvme_full_disk_audit.sh
# Description: 对 NVMe 进行全盘 Secure Erase 并生成覆盖全物理空间的 Hex Dump 审计报告
# WARNING: This script issues secure erase commands against target NVMe devices
# and destroys all data on those disks. Run it only on RD/lab machines.
# ==============================================================================

set -euo pipefail

echo "WARNING: nvme_secure_erase_test.sh will issue secure erase commands and destroy all data on target NVMe devices." >&2

# --- 参数配置 ---
# 限制异常情况下的日志大小（例如擦除失败时，防止 Hex 文本撑爆系统盘）
# 100MB 的文本量足够证明“没擦干净”了
MAX_LOG_SIZE="100M" 
BASE_LOG_DIR="NVME_AUDIT_$(date +%Y%m%d_%H%M%S)"

# --- 核心逻辑 ---
do_full_audit() {
    local DEV_NAME="$1"
    local TARGET_DEV="/dev/${DEV_NAME}"
    local DEV_SIZE_BYTES
    DEV_SIZE_BYTES=$(blockdev --getsize64 "${TARGET_DEV}") || { echo "blockdev failed for ${TARGET_DEV}" >&2; return 1; }
    local DEV_LOG_DIR="${BASE_LOG_DIR}/${DEV_NAME}"
    
    mkdir -p "${DEV_LOG_DIR}"
    local SUMMARY="${DEV_LOG_DIR}/summary.log"
    local PROCESS_LOG="${DEV_LOG_DIR}/analysis_process.log"
    local HEX_DUMP_FILE="${DEV_LOG_DIR}/full_disk_evidence.hex"

    echo "[$DEV_NAME] 开始全盘审计..."

    # 1. 擦除前：记录 SMART
    smartctl -a "${TARGET_DEV}" > "${DEV_LOG_DIR}/smart_before.log" 2>&1

    # 2. 执行擦除
    echo "[$DEV_NAME] 正在下发全盘擦除指令 (Format)..."
    local T_START=$(date +%s)
    nvme format "${TARGET_DEV}" -s 1 --force > "${DEV_LOG_DIR}/format_exec.log" 2>&1
    local T_END=$(date +%s)
    local DURATION=$((T_END - T_START))

    # 3. 关键步骤：全盘 Hex Dump 审计
    # 我们直接对整个设备文件执行 hexdump，不加任何 skip 或 count
    echo "[$DEV_NAME] 正在启动全盘物理扫描 (Hex Dump)..."
    
    # 使用 head 限制大小是防御性编程，防止擦除失败时产生数 TB 的文本
    # 如果擦除成功，hexdump 会在几秒内完成全盘扫描并输出 3 行代码
    set +e
    hexdump -C "${TARGET_DEV}" | head -c "${MAX_LOG_SIZE}" > "${HEX_DUMP_FILE}"
    set -e

    # 4. 自动化分析过程
    echo "[$DEV_NAME] 正在分析审计证据..."
    {
        echo "--- 结果分析 ---"
        
        # 检查耗时
        if [ ${DURATION} -gt 0 ]; then
            echo "结果: [PASS] 擦除耗时: ${DURATION}s"
        else
            echo "结果: [FAIL] 擦除动作异常 (耗时过短)"
        fi

        # 检查 Hex Dump 证据
        # 逻辑：如果全盘为 0，文件行数应为 3，且最后一行地址应接近硬盘总容量
        local LINE_COUNT=$(wc -l < "${HEX_DUMP_FILE}")
        local LAST_ADDR=$(awk '{if($1 != "*") print $1}' "${HEX_DUMP_FILE}" | tail -n 1)
        
        # 将十六进制地址转换为十进制进行比对
        local LAST_ADDR_DEC=$((16#${LAST_ADDR:-0}))
        
        echo -n "数据: "
        if [ "${LINE_COUNT}" -le 5 ] && [ "${LAST_ADDR_DEC}" -ge $((DEV_SIZE_BYTES - 1024)) ]; then
            echo "[PASS] LBA 区域已完全抹除 (全0)"
            local DATA_RES="PASS"
        else
            echo "[FAIL] 数据残留或扫描未覆盖全盘"
            local DATA_RES="FAIL"
        fi

        # 写入详细过程日志
        {
            echo "===================================================="
            echo "全盘审计技术细节"
            echo "===================================================="
            echo "1. 物理设备: ${TARGET_DEV}"
            echo "2. 标称容量: ${DEV_SIZE_BYTES} 字节"
            echo "3. 擦除指令: nvme format -s 1 (User Data Erase)"
            echo "4. 扫描范围: 0x00000000 至 $(printf '0x%x' "${DEV_SIZE_BYTES}")"
            echo -e "\n[Hex Dump 原始证据]"
            cat "${HEX_DUMP_FILE}"
            echo -e "\n[逻辑判定依据]"
            echo "- 证据行数: ${LINE_COUNT} (预期 <= 5)"
            echo "- 最终偏移地址: 0x${LAST_ADDR} (十进制: ${LAST_ADDR_DEC})"
            echo "- 判定结论: $( [ "$DATA_RES" == "PASS" ] && echo "全盘扫描通过，未发现非零数据。" || echo "发现非零数据或扫描异常。")"
        } > "${PROCESS_LOG}"

    } > "${SUMMARY}"

    echo "[$DEV_NAME] 审计完成，报告已生成。"
}

# --- 主程序 ---
mkdir -p "${BASE_LOG_DIR}"
DEVS=$(lsblk -dno NAME,TYPE,MOUNTPOINT | awk '$2=="disk" && $1 ~ /^nvme/ {print $1, $3}')

while read -r dev mountpoint; do
    [[ -n "${dev:-}" ]] || continue
    if [[ -n "${mountpoint:-}" ]]; then
        echo "Skip mounted/system disk: /dev/${dev} (${mountpoint})" >&2
        continue
    fi
    do_full_audit "$dev"
done <<< "$DEVS"

echo "所有测试已完成。请查看 ${BASE_LOG_DIR} 下的报告。"
