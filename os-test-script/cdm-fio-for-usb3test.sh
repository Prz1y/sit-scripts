#!/bin/bash

# ==========================================
# 1. 基础配置
# ==========================================
FAILED_TESTS=0
DEV="${1:-/dev/sdb}"               # 盘符
RESULT_DIR="fio_results_$(date +%Y%m%d_%H%M%S)"
SIZE="1G"                    # 测试数据范围；USB设备1G足够，NVMe/SATA SSD建议加大
RAMP="10"                    # 10秒预热
RUN="60"                     # 60秒实测
ENGINE="libaio"
DIRECT=1

# 设备安全检查
if [ ! -b "$DEV" ]; then
    echo "错误: 设备 $DEV 不存在或不是块设备"
    exit 1
fi

root_dev=$(findmnt -n -o SOURCE / 2>/dev/null || true)
if [ -n "$root_dev" ]; then
    root_real=$(readlink -f "$root_dev" 2>/dev/null || echo "$root_dev")
    dev_real=$(readlink -f "$DEV" 2>/dev/null || echo "$DEV")
    if [ "$root_real" = "$dev_real" ]; then
        echo "错误: $DEV 是系统根分区，无法安全测试"
        exit 1
    fi
fi

# 创建存放结果的文件夹
mkdir -p "$RESULT_DIR"

echo "================================================"
echo "测试开始，结果将存入文件夹: $RESULT_DIR"
echo "目标设备: $DEV"
echo "测试数据范围: $SIZE (随机读写循环覆盖)"
echo "================================================"

# ==========================================
# 2. 定义测试核心函数
# ==========================================
run_fio() {
    local name=$1
    local rw=$2
    local bs=$3
    local qd=$4
    local nj=$5
    local output_file="$RESULT_DIR/${name}.txt"
    
    echo ">> 正在运行: $name ... (预热${RAMP}s + 实测${RUN}s)"
    
    # 执行fio并将结果保存到文件
    fio --name="$name" \
        --filename="$DEV" \
        --ioengine="$ENGINE" \
        --direct="$DIRECT" \
        --rw="$rw" \
        --bs="$bs" \
        --iodepth="$qd" \
        --numjobs="$nj" \
        --size="$SIZE" \
        --ramp_time="$RAMP" \
        --runtime="$RUN" \
        --time_based \
        --group_reporting \
        --output="$output_file"

    # 在终端简单显示一下这个项的结果，不用翻文件
    local bw=$(grep -E "READ:|WRITE:" "$output_file" | awk -F'bw=' '{print $2}' | awk -F',' '{print $1}')
    echo "   [完成] 平均带宽: $bw"
    echo "   [报告]: $output_file"
}

# ==========================================
# 3. 执行 CrystalDiskMark 标准四项测试
# ==========================================

# --- 顺序性能 (Sequential) ---
run_fio "SEQ1M_Q8T1_Read"  "read"  "1M" 8 1
run_fio "SEQ1M_Q8T1_Write" "write" "1M" 8 1

run_fio "SEQ1M_Q1T1_Read"  "read"  "1M" 1 1
run_fio "SEQ1M_Q1T1_Write" "write" "1M" 1 1

# --- 随机性能 (Random 4K) ---
# USB设备: 4K随机写极慢(通常<100 IOPS)，60s实测值会持续衰减不代表稳态性能
# 如需准确稳态随机写指标，建议 --size 设为全盘容量(写全盘后再随机测试)
run_fio "RND4K_Q32T1_Read"  "randread"  "4k" 32 1
run_fio "RND4K_Q32T1_Write" "randwrite" "4k" 32 1

run_fio "RND4K_Q1T1_Read"  "randread"  "4k" 1 1
run_fio "RND4K_Q1T1_Write" "randwrite" "4k" 1 1

echo "================================================"
if [ "$FAILED_TESTS" -gt 0 ]; then
    echo "测试完成，但有 ${FAILED_TESTS} 项失败！"
    echo "请查看文件夹 $RESULT_DIR 获取详细报告。"
    ls -lh "$RESULT_DIR"
    exit 1
else
    echo "所有测试已完成！"
    echo "请查看文件夹 $RESULT_DIR 获取详细报告。"
    ls -lh "$RESULT_DIR"
fi
