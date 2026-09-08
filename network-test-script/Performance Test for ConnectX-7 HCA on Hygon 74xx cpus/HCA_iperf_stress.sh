#!/bin/bash

# =======================================================
# HCA 双口并发性能测试脚本 (极致调优版：调用 lspci 获取 NUMA)
# =======================================================

# ==================== 【请在此处修改你的实际网卡信息】 ====================
# 网口 1 配置
PORT1_DEV="这里必须填ip a查到的网卡名1"       # <--- 务必修改！
PORT1_IB="mlx5_0"                            # IB 设备名
PORT1_SERVER_IP="192.168.10.1"
PORT1_CLIENT_IP="192.168.10.2"
PORT1_TEST_PORT=5001

# 网口 2 配置
PORT2_DEV="这里必须填ip a查到的网卡名2"       # <--- 务必修改！
PORT2_IB="mlx5_1"                            # IB 设备名
PORT2_SERVER_IP="192.168.20.1"
PORT2_CLIENT_IP="192.168.20.2"
PORT2_TEST_PORT=5002

# 测试参数配置
TEST_TIME=43200              # iperf 测试时间 (秒)
IPERF_THREADS=3              # iperf 单口并发线程数
# ======================================================================

FORCE_APP_NUMA=""

usage() {
    echo "用法: $0 [操作选项]"
    echo "  --env                      检查依赖包"
    echo "  --setup-ip server          为Server端配置IP"
    echo "  --setup-ip client          为Client端配置IP"
    echo "  --iperf-server             启动 iperf 服务端"
    echo "  --iperf-client             启动 iperf 客户端"
    echo "  --ib-server                启动 ib_write_bw 服务端"
    echo "  --ib-client                启动 ib_write_bw 客户端"
    echo "  --kill                     停止所有后台测试进程"
    echo "  --app-numa <节点号>         强制指定进程 NUMA (覆盖自动计算)"
    exit 1
}

# 终极侦测硬件 NUMA 节点逻辑 (优先使用 lspci)
validate_config() {
    if [[ "$PORT1_DEV" == *"这里"* ]] || [[ "$PORT2_DEV" == *"这里"* ]]; then
        echo "请先修改 PORT1_DEV/PORT2_DEV 为实际网卡名" >&2
        exit 1
    fi
}

get_hw_numa() {
    local dev="$1"
    local pci_id=""
    local node="-1"

    # 1. 解析设备的 PCI ID
    if [ -e "/sys/class/net/$dev/device" ]; then
        pci_id=$(basename "$(readlink "/sys/class/net/$dev/device")")
    elif [ -e "/sys/class/infiniband/$dev/device" ]; then
        pci_id=$(basename "$(readlink "/sys/class/infiniband/$dev/device")")
    fi

    # 2. 用 lspci 抓取最准确的 NUMA 节点
    if [ -n "$pci_id" ]; then
        local lspci_numa=$(lspci -vvv -s "$pci_id" 2>/dev/null | grep -i "NUMA node" | awk '{print $NF}')
        if [ -n "$lspci_numa" ] && [ "$lspci_numa" != "unknown" ]; then
            echo "$lspci_numa"
            return
        fi
    fi

    # 3. 兜底方案：读 sysfs
    if [ -f "/sys/class/net/$dev/device/numa_node" ]; then
        node=$(cat "/sys/class/net/$dev/device/numa_node")
    elif [ -f "/sys/class/infiniband/$dev/device/numa_node" ]; then
        node=$(cat "/sys/class/infiniband/$dev/device/numa_node")
    fi
    echo "$node"
}

# 寻找相邻且可用的 NUMA 节点 (分离策略)
get_adjacent_numa() {
    local hw_numa=$1
    local available_nodes
    mapfile -t available_nodes < <(for npath in /sys/devices/system/node/node[0-9]*; do [ -d "$npath" ] && echo "${npath##*node}"; done | sort -n)
    local target="-1"

    for n in "${available_nodes[@]}"; do
        if [ "$n" -eq "$((hw_numa - 1))" ]; then target=$n; break; fi
    done

    if [ "$target" -eq "-1" ]; then
        for n in "${available_nodes[@]}"; do
            if [ "$n" -eq "$((hw_numa + 1))" ]; then target=$n; break; fi
        done
    fi

    if [ "$target" -eq "-1" ]; then
        for n in "${available_nodes[@]}"; do
            if [ "$n" -ne "$hw_numa" ]; then target=$n; break; fi
        done
    fi

    if [ "$target" -eq "-1" ]; then target=$hw_numa; fi
    echo "$target"
}

run_cmd() {
    local cmd="$1"
    local log_file="$2"
    local dev="$3"
    
    local hw_numa=$(get_hw_numa "$dev")
    local app_numa=""

    if [ -n "$FORCE_APP_NUMA" ]; then
        app_numa="$FORCE_APP_NUMA"
        echo ">>> [手动干预] 硬件所在 NUMA: ${hw_numa} | 强制 App 绑定至 NUMA: ${app_numa}"
    else
        if [ "$hw_numa" -ge 0 ] 2>/dev/null; then
            app_numa=$(get_adjacent_numa "$hw_numa")
            echo ">>> [智能分离] 硬件所在 NUMA: ${hw_numa} | App 已自动分离至邻近 NUMA: ${app_numa}"
        else
            app_numa="0"
            echo ">>> [告警] 未能侦测到硬件 NUMA，回退使用 NUMA: 0"
        fi
    fi

    read -r -a cmd_parts <<< "$cmd"
    local -a full_cmd=(numactl -N "$app_numa" -m "$app_numa" "${cmd_parts[@]}")
    echo ">>> [设备: $dev] 执行命令: ${full_cmd[*]}"
    nohup "${full_cmd[@]}" > "$log_file" 2>&1 &
    echo ">>> 进程 PID: $! | 日志: $log_file"
    echo "------------------------------------------------------"
}

check_env() {
    for pkg in iperf numactl pciutils; do
        if ! command -v "$pkg" &> /dev/null; then
            yum install epel-release -y &>/dev/null
            yum install "$pkg" -y
        fi
    done
    if ! command -v ib_write_bw &> /dev/null; then
        yum install perftest -y
    fi
}

setup_ip() {
    local role=$1
    ip addr flush dev "$PORT1_DEV" 2>/dev/null
    ip addr flush dev "$PORT2_DEV" 2>/dev/null
    if [ "$role" == "server" ]; then
        ip addr add "$PORT1_SERVER_IP"/24 dev "$PORT1_DEV"
        ip addr add "$PORT2_SERVER_IP"/24 dev "$PORT2_DEV"
    elif [ "$role" == "client" ]; then
        ip addr add "$PORT1_CLIENT_IP"/24 dev "$PORT1_DEV"
        ip addr add "$PORT2_CLIENT_IP"/24 dev "$PORT2_DEV"
    fi
    ip link set dev "$PORT1_DEV" up
    ip link set dev "$PORT2_DEV" up
}

run_iperf_server() {
    run_cmd "iperf -s -i 5 -p $PORT1_TEST_PORT" "iperf_p1_server.log" "$PORT1_DEV"
    run_cmd "iperf -s -i 5 -p $PORT2_TEST_PORT" "iperf_p2_server.log" "$PORT2_DEV"
}

run_iperf_client() {
    run_cmd "iperf -c $PORT1_SERVER_IP -B $PORT1_CLIENT_IP -i 5 -P $IPERF_THREADS -p $PORT1_TEST_PORT -t $TEST_TIME" "iperf_p1_client.log" "$PORT1_DEV"
    run_cmd "iperf -c $PORT2_SERVER_IP -B $PORT2_CLIENT_IP -i 5 -P $IPERF_THREADS -p $PORT2_TEST_PORT -t $TEST_TIME" "iperf_p2_client.log" "$PORT2_DEV"
}

run_ib_server() {
    run_cmd "ib_write_bw -d $PORT1_IB --report_gbits --run_infinitely -p $PORT1_TEST_PORT" "ib_p1_server.log" "$PORT1_IB"
    run_cmd "ib_write_bw -d $PORT2_IB --report_gbits --run_infinitely -p $PORT2_TEST_PORT" "ib_p2_server.log" "$PORT2_IB"
}

run_ib_client() {
    run_cmd "ib_write_bw -d $PORT1_IB --report_gbits --run_infinitely -p $PORT1_TEST_PORT $PORT1_SERVER_IP" "ib_p1_client.log" "$PORT1_IB"
    run_cmd "ib_write_bw -d $PORT2_IB --report_gbits --run_infinitely -p $PORT2_TEST_PORT $PORT2_SERVER_IP" "ib_p2_client.log" "$PORT2_IB"
}

kill_tests() {
    pkill -9 iperf
    pkill -9 ib_write_bw
    echo ">>> 已清理所有进程。"
}

ACTION=""
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --env) ACTION="env"; shift ;;
        --setup-ip) ACTION="setup_ip"; ROLE_ARG="$2"; shift 2 ;;
        --iperf-server) ACTION="iperf_server"; shift ;;
        --iperf-client) ACTION="iperf_client"; shift ;;
        --ib-server) ACTION="ib_server"; shift ;;
        --ib-client) ACTION="ib_client"; shift ;;
        --kill) ACTION="kill_tests"; shift ;;
        --app-numa) FORCE_APP_NUMA="$2"; shift 2 ;;
        *) usage ;;
    esac
done

validate_config

case "$ACTION" in
    env) check_env ;;
    setup_ip) setup_ip "$ROLE_ARG" ;;
    iperf_server) run_iperf_server ;;
    iperf_client) run_iperf_client ;;
    ib_server) run_ib_server ;;
    ib_client) run_ib_client ;;
    kill_tests) kill_tests ;;
    *) usage ;;
esac
