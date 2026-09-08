#!/bin/bash
# ============================================================
# 客户端 - RDMA 自动化测试（自动配 IP / 自动识别 CX7）
# 用法: sudo ./rdma_client.sh
# ============================================================

TEST_PORTS=(
  "ens5f0np0 192.168.10.1/24 192.168.10.2"
  "ens5f1np1 192.168.20.1/24 192.168.20.2"
)

NUMA_NODE="11"
ITERATIONS=3
TIMEOUT_SEC=60
WAIT_BETWEEN_SEC=5
MAX_RETRIES=3

[ $EUID -ne 0 ] && echo "请用 root 权限运行" && exit 1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname -s)
RESULT_DIR="${SCRIPT_DIR}/rdma_results_${TIMESTAMP}/${HOSTNAME}_client"
mkdir -p "$RESULT_DIR"

# 捕获 Ctrl+C 瞬间安全退出
cleanup() { echo -e "\n[!] 收到中断信号，正在安全退出..."; kill 0; exit 130; }
trap cleanup SIGINT SIGTERM

NUMACTL_CMD=()
[ -n "$NUMA_NODE" ] && command -v numactl &>/dev/null && NUMACTL_CMD=(numactl --cpunodebind="$NUMA_NODE" --membind="$NUMA_NODE") && echo "NUMA 绑定: node $NUMA_NODE"

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
echo " RDMA 客户端测试"
echo "============================================"

SUMMARY_FILE="${RESULT_DIR}/_summary.txt"
: > "$SUMMARY_FILE"

for cfg in "${TEST_PORTS[@]}"; do
    read -r IFACE LOCAL_CIDR SERVER_IP <<< "$cfg"
    LOCAL_IP="${LOCAL_CIDR%/*}"
    RDMA_DEV=$(get_rdma_dev "$IFACE")
    [ -z "$RDMA_DEV" ] && echo "  [ERROR] 无 RDMA 设备" && continue

    echo ""
    echo ">>>> 客户端: $IFACE ($RDMA_DEV) 本地=$LOCAL_IP 目标=$SERVER_IP <<<"

    add_ip "$LOCAL_CIDR" "$IFACE" || continue

    IP_DIR="${RESULT_DIR}/${RDMA_DEV}_${SERVER_IP//./_}"
    mkdir -p "$IP_DIR"

    for test_cmd in "${TESTS[@]}"; do
        command -v "$test_cmd" &>/dev/null || continue
        echo "=== $test_cmd ==="

        for i in $(seq 1 $ITERATIONS); do
            OUT="${IP_DIR}/${test_cmd}_run${i}.txt"
            attempt=1
            
            # 【优化1】：由于客户端和服务端步调几乎一致，给服务端1秒时间启动进程和绑定端口
            sleep 1 

            while [ $attempt -le $MAX_RETRIES ]; do
                echo "[$(date '+%H:%M:%S')] 第 $i 次 (尝试 $attempt)..."
                
                # 【优化2】：取消直接 tee 刷屏，先捕获到文件里，成功了再打印，避免失败时的乱码和报错
                timeout "$TIMEOUT_SEC" "${NUMACTL_CMD[@]}" \
                    "$test_cmd" -d "$RDMA_DEV" --gid-index 3 "$SERVER_IP" > "$OUT" 2>&1
                
                ret=$?
                
                [ $ret -eq 130 ] && exit 130
                
                if [ $ret -eq 0 ]; then
                    # 成功时：将内容原样输出，控制台十分清爽
                    cat "$OUT"
                    echo "  [PASS]"
                    break
                elif [ $ret -eq 124 ]; then
                    cat "$OUT"
                    echo "  [TIMEOUT]"
                    break
                else
                    # 失败时判断是否还要重试
                    if [ $attempt -lt $MAX_RETRIES ]; then
                        echo "  => 服务端未就绪或连接失败，2秒后重试..."
                        sleep 2
                        attempt=$((attempt+1))
                    else
                        # 彻底失败，把报错印出来方便排查
                        cat "$OUT"
                        echo "  [FAIL] $ret"
                        break
                    fi
                fi
            done
            
            case $ret in
                0)   echo "PASS: $test_cmd run $i" >> "${IP_DIR}/_summary.txt" ;;
                124) echo "TIMEOUT: $test_cmd run $i" >> "${IP_DIR}/_summary.txt" ;;
                130) exit 130 ;;
                *)   echo "FAIL($ret): $test_cmd run $i" >> "${IP_DIR}/_summary.txt" ;;
            esac
            sleep "$WAIT_BETWEEN_SEC"
        done
    done
done

echo ""
echo "全部完成，结果在 $RESULT_DIR"
