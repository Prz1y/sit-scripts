#!/bin/bash
# ============================================================
# 服务端 - RDMA 自动化测试（自动配 IP / 自动识别 CX7）
# 用法: sudo ./rdma_server.sh
# ============================================================

# 【服务端配置】按顺序定义要测试的网口、IP
TEST_PORTS=(
  "ens5f0np0 192.168.10.2/24"
  "ens5f1np1 192.168.20.2/24"
)

NUMA_NODE="11"
ITERATIONS=3
TIMEOUT_SEC=300
WAIT_BETWEEN_SEC=5

# 初始化
[ $EUID -ne 0 ] && echo "请用 root 权限运行" && exit 1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname -s)
RESULT_DIR="${SCRIPT_DIR}/rdma_results_${TIMESTAMP}/${HOSTNAME}_server"
mkdir -p "$RESULT_DIR"

cleanup() { echo -e "\n中断..."; pkill -P $$ 2>/dev/null; exit 130; }
trap cleanup SIGINT SIGTERM

NUMACTL_CMD=()
[ -n "$NUMA_NODE" ] && command -v numactl &>/dev/null && NUMACTL_CMD=(numactl --cpunodebind="$NUMA_NODE" --membind="$NUMA_NODE") && echo "NUMA 绑定: node $NUMA_NODE"

echo "清理旧进程..."
pkill -f "^(ib_read|ib_send|ib_write)" 2>/dev/null || true
sleep 1

# 自动检测 RDMA 设备
declare -A IFACE_TO_RDMA
echo "检测 RDMA 设备..."
for dev in $(ibv_devinfo 2>/dev/null | grep "hca_id:" | awk '{print $2}'); do
    net_dir="/sys/class/infiniband/${dev}/device/net"
    [ -d "$net_dir" ] && iface=$(ls "$net_dir" | head -1) && IFACE_TO_RDMA["$iface"]="$dev" && echo "  $iface -> $dev"
done
[ ${#IFACE_TO_RDMA[@]} -eq 0 ] && echo "未发现 RDMA 设备" && exit 1

get_rdma_dev() { echo "${IFACE_TO_RDMA[$1]}"; }

add_ip() {
    if ! ip addr show | grep -wq "${1%/*}"; then
        echo "  => 添加 IP: $1 到 $2"
        ip addr add "$1" dev "$2" || return 1
        sleep 1
    else
        echo "  => IP ${1%/*} 已存在"
    fi
}

TESTS=("ib_read_bw" "ib_read_lat" "ib_send_bw" "ib_send_lat" "ib_write_bw" "ib_write_lat")

echo "============================================"
echo " RDMA 服务端测试"
echo "============================================"

SUMMARY_FILE="${RESULT_DIR}/_summary.txt"
: > "$SUMMARY_FILE"

for cfg in "${TEST_PORTS[@]}"; do
    read -r IFACE LOCAL_CIDR <<< "$cfg"
    LOCAL_IP="${LOCAL_CIDR%/*}"
    RDMA_DEV=$(get_rdma_dev "$IFACE")
    [ -z "$RDMA_DEV" ] && echo "  [ERROR] 无 RDMA 设备" && continue

    echo ""
    echo ">>>> 服务端绑定: $IFACE ($RDMA_DEV) IP=$LOCAL_IP <<<"

    add_ip "$LOCAL_CIDR" "$IFACE" || continue

    IP_DIR="${RESULT_DIR}/${RDMA_DEV}_${LOCAL_IP//./_}"
    mkdir -p "$IP_DIR"

    for test_cmd in "${TESTS[@]}"; do
        command -v "$test_cmd" &>/dev/null || { echo "SKIP $test_cmd"; continue; }
        echo "=== $test_cmd ==="

        for i in $(seq 1 $ITERATIONS); do
            OUT="${IP_DIR}/${test_cmd}_run${i}.txt"
            echo "[$(date '+%H:%M:%S')] 第 $i 次 - 等待客户端..."

            # 注意：服务端不使用 -B，只使用 -d 指定设备
            timeout "$TIMEOUT_SEC" "${NUMACTL_CMD[@]}" \
                "$test_cmd" -d "$RDMA_DEV" --gid-index 3 2>&1 | tee "$OUT"
            ret=${PIPESTATUS[0]}

            case $ret in
                0)   echo "  [PASS]"; echo "PASS: $test_cmd run $i" >> "${IP_DIR}/_summary.txt" ;;
                124) echo "  [TIMEOUT]"; echo "TIMEOUT: $test_cmd run $i" >> "${IP_DIR}/_summary.txt" ;;
                *)   echo "  [FAIL] $ret"; echo "FAIL($ret): $test_cmd run $i" >> "${IP_DIR}/_summary.txt" ;;
            esac
            sleep "$WAIT_BETWEEN_SEC"
        done
    done
done

echo ""
echo "全部完成，结果在 $RESULT_DIR"
