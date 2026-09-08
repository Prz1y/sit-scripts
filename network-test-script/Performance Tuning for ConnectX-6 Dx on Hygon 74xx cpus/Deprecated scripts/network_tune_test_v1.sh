#!/bin/bash

set -euo pipefail


# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 全局变量
NICS=()
NIC_NUMA=0
APP_NUMA=0
QUEUES_PER_NIC=0
LOG_DIR="/tmp/iperf_logs"
TIMESTAMP=""
SERVER_PIDS=()
AUTO_YES=${AUTO_YES:-0}
MODE_ARG=${1:-}
ADDED_RAW_RULES=()

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

#############################################################################
# 清理 / 还原函数 (trap)
#############################################################################
cleanup() {
    log_warn "收到退出信号，正在清理..."
    # 终止后台 iperf 进程
    for pid in "${SERVER_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    # 终止监控进程
    for pid in "${MONITOR_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    if systemctl list-unit-files irqbalance.service >/dev/null 2>&1; then
        sudo systemctl start irqbalance 2>/dev/null || true
        log_info "已恢复 irqbalance 服务"
    fi
    log_info "清理完成"
}
trap cleanup EXIT INT TERM

#############################################################################
# 0. 依赖检查
#############################################################################
check_deps() {
    local missing=()
    for cmd in ethtool numactl iperf; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺少依赖工具: ${missing[*]}，请先安装后重试"
    fi
    log_info "依赖检查通过"
}

#############################################################################
# 1. 自动检测网卡 (安全遍历，不用 ls 解析)
#############################################################################
detect_nics() {
    log_info "检测 Mellanox 网卡..."

    NICS=()
    local nic
    for path in /sys/class/net/*/; do
        nic=$(basename "$path")
        if ethtool -i "$nic" 2>/dev/null | grep -q "driver: mlx5_core"; then
            NICS+=("$nic")
        fi
    done

    if [ ${#NICS[@]} -lt 2 ]; then
        log_error "检测到的 Mellanox 网卡/网口数不足 2 个 (当前: ${#NICS[@]})，退出"
    fi

    log_info "检测到 ${#NICS[@]} 个网卡/网口: ${NICS[*]}"
}

#############################################################################
# 2. 获取 NUMA 信息
#############################################################################
get_numa_info() {
    local nic=$1
    local node
    if [ -f "/sys/class/net/$nic/device/numa_node" ]; then
        node=$(cat "/sys/class/net/$nic/device/numa_node")
        # 某些系统返回 -1 表示无 NUMA 亲和，回退到 0
        if [ "$node" -lt 0 ] 2>/dev/null; then
            echo "0"
        else
            echo "$node"
        fi
    else
        echo "0"
    fi
}

#############################################################################
# 3. 获取 CPU 列表（根据 NUMA 节点）
#############################################################################
get_numa_cpus() {
    local numa_node=$1
    numactl -H | grep "node $numa_node cpus:" | awk '{for(i=4;i<=NF;i++) printf "%s ", $i}' | sed 's/ $//'
}

#############################################################################
# 4. 获取系统 NUMA 节点总数
#############################################################################
get_numa_count() {
    numactl -H | grep "^available:" | awk '{print $2}'
}

#############################################################################
# 4.1 选择离目标 NUMA 最近的其他 NUMA 节点 (解析 distance 表)
#############################################################################
select_nearest_numa() {
    local target=$1
    local best_node=""
    local best_dist=9999

    # 从 numactl -H 的 distance 表中读取目标行
    # 格式: "  5:  27  25  27  27  15  10  15  15"
    local dist_line
    dist_line=$(numactl -H | awk "/^  *${target}:/{print}")

    if [ -z "$dist_line" ]; then
        # 解析失败，回退: 选 target+1 或 target-1
        local count
        count=$(get_numa_count)
        echo $(( (target + 1) % count ))
        return
    fi

    # 去掉 "N:" 前缀，得到纯距离数组
    local distances
    distances=$(echo "$dist_line" | sed 's/^[[:space:]]*[0-9]*://')
    local idx=0
    for dist in $distances; do
        if [ "$idx" -ne "$target" ] && [ "$dist" -lt "$best_dist" ]; then
            best_dist=$dist
            best_node=$idx
        fi
        idx=$((idx + 1))
    done

    if [ -n "$best_node" ]; then
        echo "$best_node"
    else
        echo $(( (target + 1) % $(get_numa_count) ))
    fi
}

#############################################################################
# 5. 执行并打印指令状态
#############################################################################
run_cmd() {
    local cmd="$1"
    local tmp_script
    tmp_script=$(mktemp)
    printf "#!/bin/bash
set -e
%s
" "$cmd" > "$tmp_script"
    chmod +x "$tmp_script"
    echo -n -e "  ${cmd} ... "
    local rc=0
    if sudo bash "$tmp_script" >/dev/null 2>&1; then
        echo -e "${GREEN}[成功]${NC}"
    else
        rc=$?
        echo -e "${RED}[失败或不支持]${NC}"
    fi
    rm -f "$tmp_script"
    return $rc
}

#############################################################################
# 5.1 生成 CPU hex 位掩码 (用于 XPS 等需要 bitmask 的内核接口)
#############################################################################
write_root_file() {
    local value="$1"
    local target_file="$2"
    printf "%s\n" "$value" | sudo tee "$target_file" >/dev/null
}

set_all_governors_performance() {
    local gov
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$gov" ] || continue
        write_root_file "performance" "$gov" 2>/dev/null || true
    done
}

add_raw_notrack_rule() {
    local chain="$1"
    local proto_field="$2"
    local port_range="$3"
    if command -v iptables >/dev/null 2>&1; then
        sudo iptables -t raw -C "$chain" -p tcp "$proto_field" "$port_range" -j NOTRACK 2>/dev/null || {
            sudo iptables -t raw -A "$chain" -p tcp "$proto_field" "$port_range" -j NOTRACK 2>/dev/null && ADDED_RAW_RULES+=("$chain|$proto_field|$port_range")
        }
    fi
}

remove_added_raw_rules() {
    local rule
    for rule in "${ADDED_RAW_RULES[@]:-}"; do
        [ -n "$rule" ] || continue
        IFS="|" read -r chain proto_field port_range <<< "$rule"
        sudo iptables -t raw -D "$chain" -p tcp "$proto_field" "$port_range" -j NOTRACK 2>/dev/null || true
    done
}

cpu_to_mask() {
    local cpu=$1
    local total_cpus
    total_cpus=$(nproc)
    local num_groups=$(( (total_cpus + 31) / 32 ))
    local mask=""
    for ((g = num_groups - 1; g >= 0; g--)); do
        local group_start=$((g * 32))
        local word=0
        if [ "$cpu" -ge "$group_start" ] && [ "$cpu" -lt $((group_start + 32)) ]; then
            word=$(( 1 << (cpu - group_start) ))
        fi
        if [ -n "$mask" ]; then
            mask=$(printf "%s,%08x" "$mask" "$word")
        else
            mask=$(printf "%08x" "$word")
        fi
    done
    echo "$mask"
}

#############################################################################
# 6. 路由调优 - 设置大 initcwnd/initrwnd 加速 TCP 起速
#############################################################################
setup_route_tuning() {
    log_info "设置路由初始窗口 (initcwnd/initrwnd)..."
    # 对 100/110 子网设置大初始窗口
    for subnet in 192.168.100.0/24 192.168.110.0/24; do
        local existing
        existing=$(ip route show "$subnet" 2>/dev/null | head -1)
        if [ -n "$existing" ]; then
            sudo bash -c "ip route change $existing initcwnd 128 initrwnd 128" 2>/dev/null || true
            log_info "  $subnet: initcwnd=128 initrwnd=128"
        fi
    done
}

#############################################################################
# 6.1 监控: 启动后台诊断采集
#############################################################################
start_monitoring() {
    local duration=$1
    local nic1=${NICS[0]}
    local nic2=${NICS[1]}

    mkdir -p "$LOG_DIR"

    log_info "启动后台监控 (softnet / ethtool-S / sar)..."

    # softnet_stat 采样
    cat /proc/net/softnet_stat > "${LOG_DIR}/softnet_before.log" 2>/dev/null

    # ethtool -S 快照 (测试前)
    ethtool -S "$nic1" > "${LOG_DIR}/${nic1}_ethtool_S_before.log" 2>/dev/null || true
    ethtool -S "$nic2" > "${LOG_DIR}/${nic2}_ethtool_S_before.log" 2>/dev/null || true

    # sar 网卡流量 (如果可用)
    if command -v sar &>/dev/null; then
        sar -n DEV 5 $((duration / 5 + 1)) > "${LOG_DIR}/sar_net.log" 2>&1 &
        MONITOR_PIDS+=("$!")
    fi
}

#############################################################################
# 6.2 监控: 停止采集并生成诊断报告
#############################################################################
stop_monitoring() {
    local nic1=${NICS[0]}
    local nic2=${NICS[1]}

    # 发送 SIGINT 使 mpstat/sar 打印 Average 摘要后退出 (SIGTERM 会直接杀死进程导致无汇总)
    for pid in "${MONITOR_PIDS[@]}"; do
        kill -INT "$pid" 2>/dev/null || true
    done
    # 等待监控进程优雅退出并写完日志
    for pid in "${MONITOR_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    sleep 1

    # softnet_stat (测试后)
    cat /proc/net/softnet_stat > "${LOG_DIR}/softnet_after.log" 2>/dev/null

    # ethtool -S 快照 (测试后)
    ethtool -S "$nic1" > "${LOG_DIR}/${nic1}_ethtool_S_after.log" 2>/dev/null || true
    ethtool -S "$nic2" > "${LOG_DIR}/${nic2}_ethtool_S_after.log" 2>/dev/null || true

    # --- 生成诊断摘要 ---
    echo ""
    log_info "=== 诊断信息 ==="

    # 拥塞控制
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    log_info "TCP 拥塞控制: $cc"

    # NIC 丢包/错误统计
    for nic in "$nic1" "$nic2"; do
        local before="${LOG_DIR}/${nic}_ethtool_S_before.log"
        local after="${LOG_DIR}/${nic}_ethtool_S_after.log"
        if [ -f "$before" ] && [ -f "$after" ]; then
            echo ""
            log_info "--- $nic 网卡关键计数器变化 ---"
            local drops_b drops_a errs_b errs_a
            drops_b=$(grep -E 'rx_.*_dropped|rx_out_of_buffer' "$before" | awk '{s+=$2}END{print s+0}')
            drops_a=$(grep -E 'rx_.*_dropped|rx_out_of_buffer' "$after" | awk '{s+=$2}END{print s+0}')
            errs_b=$(grep -E 'tx_errors|rx_errors' "$before" | awk '{s+=$2}END{print s+0}')
            errs_a=$(grep -E 'tx_errors|rx_errors' "$after" | awk '{s+=$2}END{print s+0}')
            log_info "  rx_drops: $((drops_a - drops_b)) | errors: $((errs_a - errs_b))"
        fi
    done

    # softnet drops
    if [ -f "${LOG_DIR}/softnet_before.log" ] && [ -f "${LOG_DIR}/softnet_after.log" ]; then
        local sn_drop_b sn_drop_a
        # NOTE: strtonum() requires GNU awk. On mawk (Debian default) the diff will report 0.
        sn_drop_b=$(awk '{s+=strtonum("0x"$2)}END{print s}' "${LOG_DIR}/softnet_before.log" 2>/dev/null || echo 0)
        sn_drop_a=$(awk '{s+=strtonum("0x"$2)}END{print s}' "${LOG_DIR}/softnet_after.log" 2>/dev/null || echo 0)
        echo ""
        log_info "softnet_stat 丢包 (全局): $((sn_drop_a - sn_drop_b))"
    fi

    echo ""
    log_info "完整诊断日志: ${LOG_DIR}/"
}

# 监控进程 PID 列表

#############################################################################
# 6.3 防火墙放通 iperf 端口
#############################################################################
setup_firewall() {
    log_info "配置防火墙放通 iperf 端口 (5001/5002)..."

    # 方案1: firewalld (CentOS/RHEL/Rocky 等)
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        log_info "检测到 firewalld 正在运行，添加端口规则..."
        sudo firewall-cmd --zone=public --add-port=5001/tcp --permanent 2>/dev/null || true
        sudo firewall-cmd --zone=public --add-port=5002/tcp --permanent 2>/dev/null || true
        sudo firewall-cmd --reload 2>/dev/null || true
        log_info "firewalld 已放通 5001/5002"
        return
    fi

    # 方案2: iptables 直接插入
    if command -v iptables &>/dev/null; then
        log_info "使用 iptables 放通端口..."
        # 先删除旧规则（避免重复）
        sudo iptables -D INPUT -p tcp --dport 5001 -j ACCEPT 2>/dev/null || true
        sudo iptables -D INPUT -p tcp --dport 5002 -j ACCEPT 2>/dev/null || true
        # 插入到 INPUT 链最前面
        sudo iptables -I INPUT 1 -p tcp --dport 5001 -j ACCEPT 2>/dev/null || true
        sudo iptables -I INPUT 1 -p tcp --dport 5002 -j ACCEPT 2>/dev/null || true
        log_info "iptables 已放通 5001/5002"
        return
    fi

    # 方案3: nftables
    if command -v nft &>/dev/null; then
        log_info "使用 nft 放通端口..."
        sudo nft add rule inet filter input tcp dport 5001 accept 2>/dev/null || true
        sudo nft add rule inet filter input tcp dport 5002 accept 2>/dev/null || true
        log_info "nft 已放通 5001/5002"
        return
    fi

    log_warn "未检测到防火墙工具，跳过 (如仍连不上请手动关闭防火墙)"
}

#############################################################################
# 7. 系统与网卡优化 (含双口分离绑核 + 跨 NUMA 感知)
#############################################################################
optimize_all() {
    local nic1=${NICS[0]}
    local nic2=${NICS[1]}

    # 获取两个口各自的 NUMA 节点
    local nic1_numa
    local nic2_numa
    nic1_numa=$(get_numa_info "$nic1")
    nic2_numa=$(get_numa_info "$nic2")

    if [ "$nic1_numa" != "$nic2_numa" ]; then
        log_warn "两个网口不在同一 NUMA 节点 ($nic1 -> NUMA $nic1_numa, $nic2 -> NUMA $nic2_numa)"
        log_warn "将分别使用各自 NUMA 节点的 CPU 绑核"
    else
        log_info "两个网口均在 NUMA $nic1_numa"
    fi

    log_info "关闭 irqbalance 并设置 CPU P-State..."
    run_cmd "systemctl stop irqbalance"
    set_all_governors_performance

    log_info "基础网络与 TCP 参数优化..."
    run_cmd "sysctl -w net.core.rmem_max=2147483647"
    run_cmd "sysctl -w net.core.wmem_max=2147483647"
    run_cmd "sysctl -w net.ipv4.tcp_rmem='4096 87380 2147483647'"
    run_cmd "sysctl -w net.ipv4.tcp_wmem='4096 65536 2147483647'"
    run_cmd "sysctl -w net.core.netdev_max_backlog=250000"
    run_cmd "sysctl -w net.ipv4.tcp_tw_reuse=1"
    run_cmd "sysctl -w net.core.somaxconn=65535"
    run_cmd "sysctl -w net.ipv4.tcp_max_syn_backlog=65535"
    run_cmd "sysctl -w net.ipv4.tcp_timestamps=1"
    run_cmd "sysctl -w net.ipv4.tcp_sack=1"
    run_cmd "sysctl -w net.core.optmem_max=2147483647"
    # 关闭 TCP 慢启动重启，保持长连接高吞吐
    run_cmd "sysctl -w net.ipv4.tcp_slow_start_after_idle=0"
    run_cmd "sysctl -w net.ipv4.tcp_mtu_probing=1"

    # 拥塞控制: 直连 back-to-back 场景使用 cubic (比 BBR 更激进，无 pacing 限速)
    # BBR 适合有丢包/高延迟的广域网，直连微秒级 RTT 下 cubic 吞吐更高
    run_cmd "sysctl -w net.core.default_qdisc=fq_codel"
    run_cmd "sysctl -w net.ipv4.tcp_congestion_control=cubic"

    # 提高软中断处理能力 (budget 加大到 1200，每轮处理更多包)
    run_cmd "sysctl -w net.core.netdev_budget=1200"
    run_cmd "sysctl -w net.core.netdev_budget_usecs=20000"
    # busy_poll 减少延迟
    run_cmd "sysctl -w net.core.busy_read=50"
    run_cmd "sysctl -w net.core.busy_poll=50"

    # --- 按网口分别优化与绑核 ---
    local nic_list=("$nic1" "$nic2")
    local numa_list=("$nic1_numa" "$nic2_numa")

    for i in 0 1; do
        local nic="${nic_list[$i]}"
        local this_numa="${numa_list[$i]}"

        # 获取该 NUMA 节点的 CPU 列表
        local cpus_str
        cpus_str=$(get_numa_cpus "$this_numa")
        local -a cpus_all=()
        read -r -a cpus_all <<< "$cpus_str"
        local total=${#cpus_all[@]}

        local bind_cpus
        local queues

        if [ "$nic1_numa" = "$nic2_numa" ]; then
            # 同 NUMA: 均分前后各一半核心
            local half=$((total / 2))
            if [ $i -eq 0 ]; then
                bind_cpus="${cpus_all[*]:0:$half}"
            else
                bind_cpus="${cpus_all[*]:$half}"
            fi
            queues=$half
        else
            # 跨 NUMA: 每口独占本 NUMA 全部核心
            bind_cpus="${cpus_all[*]}"
            queues=$total
        fi

        # 保存队列数供 iperf -P 使用 (取较小值)
        if [ $i -eq 0 ] || [ "$queues" -lt "$QUEUES_PER_NIC" ]; then
            QUEUES_PER_NIC=$queues
        fi

        log_info "------------------------------------------"
        log_info "优化网卡 $nic (NUMA $this_numa, 队列=${queues}, 绑核: ${bind_cpus})"
        run_cmd "ip link set dev $nic mtu 9000"
        run_cmd "ethtool -L $nic combined $queues"
        run_cmd "ethtool -G $nic rx 8192 tx 8192"
        run_cmd "ethtool -C $nic adaptive-rx off adaptive-tx off rx-usecs 128 tx-usecs 128"

        # 网卡 offload 优化
        run_cmd "ethtool -K $nic rx on tx on tso on gso on gro on lro on"
        run_cmd "ethtool -K $nic tx-nocache-copy off"
        run_cmd "ethtool -K $nic ntuple on"
        run_cmd "ethtool -K $nic rxhash on"
        # 关闭流控，避免暂停帧导致吞吐抖动
        run_cmd "ethtool -A $nic rx off tx off"

        # 中断绑核分配 (通过 PCI 地址匹配 mlx5 中断向量)
        local pci_dev
        pci_dev=$(basename "$(readlink -f /sys/class/net/${nic}/device)" 2>/dev/null)
        local irqs=()
        if [ -n "$pci_dev" ]; then
            mapfile -t irqs < <(grep "mlx5_comp.*${pci_dev}" /proc/interrupts | awk -F: '{print $1}' | tr -d ' ' || true)
            # 如果 mlx5_comp 匹配不到，回退到仅 PCI 地址匹配
            if [ ${#irqs[@]} -eq 0 ]; then
                mapfile -t irqs < <(grep "${pci_dev}" /proc/interrupts | awk -F: '{print $1}' | tr -d ' ' || true)
            fi
        fi
        local -a cpu_arr=()
        read -r -a cpu_arr <<< "$bind_cpus"
        local count=${#cpu_arr[@]}
        local idx=0
        local success_irq=0
        for irq in "${irqs[@]}"; do
            local target_cpu=${cpu_arr[$((idx % count))]}
            if write_root_file "$target_cpu" "/proc/irq/${irq}/smp_affinity_list" 2>/dev/null; then
                success_irq=$((success_irq + 1))
            fi
            idx=$((idx + 1))
        done
        echo -e "  [绑核] $nic 中断绑核 ... ${GREEN}[成功绑核 ${success_irq}/${#irqs[@]} 个中断向量]${NC}"

        # RSS 调优: 重置间接表确保流量均匀分布到所有队列
        run_cmd "ethtool -X $nic equal $queues"
        # RSS 哈希使用完整 4-tuple (src IP + dst IP + src port + dst port) 最大化流分散
        run_cmd "ethtool -N $nic rx-flow-hash tcp4 sdfn"
        run_cmd "ethtool -N $nic rx-flow-hash udp4 sdfn"

        # XPS (Transmit Packet Steering): 每个 TX 队列绑定对应 CPU，提升发送效率
        local q=0
        local xps_ok=0
        for cpuid in "${cpu_arr[@]}"; do
            local xps_file="/sys/class/net/${nic}/queues/tx-${q}/xps_cpus"
            if [ -f "$xps_file" ]; then
                local mask
                mask=$(cpu_to_mask "$cpuid")
                if write_root_file "$mask" "$xps_file" 2>/dev/null; then
                    xps_ok=$((xps_ok + 1))
                fi
            fi
            q=$((q + 1))
            if [ "$q" -ge "$queues" ]; then break; fi
        done
        echo -e "  [XPS] $nic TX 队列绑核 ... ${GREEN}[成功 ${xps_ok}/${queues}]${NC}"
    done
    log_info "------------------------------------------"
    log_info "每口队列数: $QUEUES_PER_NIC | iperf 并行流 (-P): $((QUEUES_PER_NIC * 2))"
}

#############################################################################
# 7. 配置网卡 IP（服务端）
#############################################################################
setup_server_ips() {
    log_info "配置服务端 IP..."

    local nic1=${NICS[0]}
    local nic2=${NICS[1]}

    log_info "配置 $nic1 -> 192.168.100.2/24"
    sudo ip addr flush dev "$nic1" 2>/dev/null || true
    sudo ip addr add 192.168.100.2/24 dev "$nic1"
    sudo ip link set dev "$nic1" up

    log_info "配置 $nic2 -> 192.168.110.2/24"
    sudo ip addr flush dev "$nic2" 2>/dev/null || true
    sudo ip addr add 192.168.110.2/24 dev "$nic2"
    sudo ip link set dev "$nic2" up

    log_info "服务端 IP 配置完成"
    ip addr show | grep -E "192.168\.(100|110)" || true

    # 设置路由初始窗口 (加速 TCP 起速)
    setup_route_tuning
    # 放通防火墙
    setup_firewall
}

#############################################################################
# 8. 配置网卡 IP（客户端）
#############################################################################
setup_client_ips() {
    log_info "配置客户端 IP..."

    local nic1=${NICS[0]}
    local nic2=${NICS[1]}

    log_info "配置 $nic1 -> 192.168.100.1/24"
    sudo ip addr flush dev "$nic1" 2>/dev/null || true
    sudo ip addr add 192.168.100.1/24 dev "$nic1"
    sudo ip link set dev "$nic1" up

    log_info "配置 $nic2 -> 192.168.110.1/24"
    sudo ip addr flush dev "$nic2" 2>/dev/null || true
    sudo ip addr add 192.168.110.1/24 dev "$nic2"
    sudo ip link set dev "$nic2" up

    log_info "客户端 IP 配置完成"
    ip addr show | grep -E "192.168\.(100|110)" || true

    # 设置路由初始窗口 (加速 TCP 起速)
    setup_route_tuning
    # 放通防火墙
    setup_firewall
}

#############################################################################
# 9. 运行服务端 (iperf server 每口独立实例 + 独立日志)
#############################################################################
run_server() {
    local app_numa=$1

    log_info "启动 iperf 服务端 (业务隔离在 NUMA $app_numa)..."


    mkdir -p "$LOG_DIR"

    local nic1=${NICS[0]}
    local nic2=${NICS[1]}

    log_info "启动 iperf server: 端口 5001 ($nic1 / 192.168.100.x)"
    numactl -N "$app_numa" -m "$app_numa" \
        iperf -s -p 5001 > "${LOG_DIR}/${nic1}_server_port5001.log" 2>&1 &
    SERVER_PIDS+=("$!")
    sleep 1

    log_info "启动 iperf server: 端口 5002 ($nic2 / 192.168.110.x)"
    numactl -N "$app_numa" -m "$app_numa" \
        iperf -s -p 5002 > "${LOG_DIR}/${nic2}_server_port5002.log" 2>&1 &
    SERVER_PIDS+=("$!")
    sleep 1

    log_info "服务端已启动，监听端口 5001/5002"
    # 使用 ss 替代已过时的 netstat
    ss -tulpn 2>/dev/null | grep -E ":(5001|5002)" || true

    log_info "服务端日志:"
    log_info "  $nic1: ${LOG_DIR}/${nic1}_server_port5001.log"
    log_info "  $nic2: ${LOG_DIR}/${nic2}_server_port5002.log"
}

#############################################################################
# 10. 连通性预检
#############################################################################
check_connectivity() {
    local ip1=$1
    local ip2=$2

    log_info "检测与服务端的连通性..."

    local ok=true
    if ! ping -c 2 -W 2 "$ip1" &>/dev/null; then
        log_warn "Pair1: 无法 ping 通 $ip1"
        ok=false
    else
        log_info "Pair1: $ip1 可达"
    fi

    if ! ping -c 2 -W 2 "$ip2" &>/dev/null; then
        log_warn "Pair2: 无法 ping 通 $ip2"
        ok=false
    else
        log_info "Pair2: $ip2 可达"
    fi

    if [ "$ok" = false ]; then
        log_warn "部分链路不通，是否继续测试？(y/N)"
        if [ "$AUTO_YES" -eq 1 ]; then
            ans="y"
        else
            read -r ans
        fi
        if [[ ! "$ans" =~ ^[yY] ]]; then
            log_error "用户取消测试"
        fi
    fi
}

#############################################################################
# 11. 运行客户端测试 (每口独立日志 + 动态 -P)
#############################################################################
run_client() {
    local server_ip=$1
    local app_numa=$2
    local duration=$3

    local server_ip2
    server_ip2=$(echo "$server_ip" | sed 's/\.100\./.110./')

    local nic1=${NICS[0]}
    local nic2=${NICS[1]}

    # 连通性预检
    check_connectivity "$server_ip" "$server_ip2"

    log_info "启动 iperf 客户端 (业务隔离在 NUMA $app_numa)..."
    log_info "连接服务器 Pair1 ($nic1): $server_ip:5001"
    log_info "连接服务器 Pair2 ($nic2): $server_ip2:5002"


    mkdir -p "$LOG_DIR"

    # 并行流数 = 队列数 × 2，确保 RSS 哈希能覆盖所有队列 (避免单队列空闲)
    local parallel=$((QUEUES_PER_NIC * 2))
    if [ "$parallel" -lt 2 ] 2>/dev/null; then
        parallel=14
        log_warn "队列数异常，回退并行流为 $parallel"
    fi

    log_info "测试时长: ${duration}s | 并行流: ${parallel} | TCP: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"

    # 启动后台诊断监控
    start_monitoring "$duration"

    # Pair1 测试 (-N: 关闭 Nagle, -w 4m: 大窗口)
    log_info "启动 Pair1 ($nic1 -> $server_ip:5001) 测试..."
    numactl -N "$app_numa" -m "$app_numa" \
        iperf -c "${server_ip}" -p 5001 -P "$parallel" -t "$duration" -i 5 -w 4m -N \
        > "${LOG_DIR}/${nic1}_client_pair1.log" 2>&1 &
    local pid1=$!

    sleep 1

    # Pair2 测试
    log_info "启动 Pair2 ($nic2 -> $server_ip2:5002) 测试..."
    numactl -N "$app_numa" -m "$app_numa" \
        iperf -c "${server_ip2}" -p 5002 -P "$parallel" -t "$duration" -i 5 -w 4m -N \
        > "${LOG_DIR}/${nic2}_client_pair2.log" 2>&1 &
    local pid2=$!

    # 分别等待，捕获退出码但不因失败退出脚本
    local rc1=0 rc2=0
    wait "$pid1" || rc1=$?
    wait "$pid2" || rc2=$?

    # 停止监控采集
    stop_monitoring

    echo ""
    log_info "=========================================="
    log_info "  测试完成！"
    log_info "=========================================="

    if [ $rc1 -ne 0 ]; then
        log_warn "Pair1 ($nic1) iperf 退出码: $rc1 (可能存在错误)"
    fi
    if [ $rc2 -ne 0 ]; then
        log_warn "Pair2 ($nic2) iperf 退出码: $rc2 (可能存在错误)"
    fi

    log_info "日志文件:"
    log_info "  $nic1 (Pair1): ${LOG_DIR}/${nic1}_client_pair1.log"
    log_info "  $nic2 (Pair2): ${LOG_DIR}/${nic2}_client_pair2.log"

    # 显示每口测试结果汇总
    echo ""
    log_info "=== $nic1 (Pair1) 测试结果 ==="
    if grep -q "\[SUM\]" "${LOG_DIR}/${nic1}_client_pair1.log" 2>/dev/null; then
        grep "\[SUM\]" "${LOG_DIR}/${nic1}_client_pair1.log" | tail -1
    else
        tail -3 "${LOG_DIR}/${nic1}_client_pair1.log" 2>/dev/null || log_warn "日志为空"
    fi

    echo ""
    log_info "=== $nic2 (Pair2) 测试结果 ==="
    if grep -q "\[SUM\]" "${LOG_DIR}/${nic2}_client_pair2.log" 2>/dev/null; then
        grep "\[SUM\]" "${LOG_DIR}/${nic2}_client_pair2.log" | tail -1
    else
        tail -3 "${LOG_DIR}/${nic2}_client_pair2.log" 2>/dev/null || log_warn "日志为空"
    fi

    # 显示前5秒 vs 后5秒吞吐对比 (验证起速效果)
    echo ""
    log_info "=== 起速分析 (前 5s vs 最后 5s) ==="
    for f in "${LOG_DIR}/${nic1}_client_pair1.log" "${LOG_DIR}/${nic2}_client_pair2.log"; do
        local name
        name=$(basename "$f" .log)
        local first_sum last_sum
        first_sum=$(grep '\[SUM\]' "$f" 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i~/bits\/sec/) print $(i-1)" "$i}')
        last_sum=$(grep '\[SUM\]' "$f" 2>/dev/null | tail -2 | head -1 | awk '{for(i=1;i<=NF;i++) if($i~/bits\/sec/) print $(i-1)" "$i}')
        log_info "  $name: 起步=${first_sum:-N/A} -> 稳态=${last_sum:-N/A}"
    done
}

#############################################################################
# 12. 主菜单
#############################################################################
main() {
    log_info "=========================================="
    log_info "  网络性能调优与测试脚本 (修正版)"
    log_info "=========================================="

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    LOG_DIR="/tmp/iperf_logs/${TIMESTAMP}"

    # 依赖检查
    check_deps

    # 检测网卡
    detect_nics

    # 获取 NUMA 信息和规划职责
    NIC_NUMA=$(get_numa_info "${NICS[0]}")
    local numa_count
    numa_count=$(get_numa_count)

    if [ "$numa_count" -le 1 ] 2>/dev/null; then
        # 单 NUMA 系统: 业务和中断都在 NUMA 0
        APP_NUMA=0
        log_warn "单 NUMA 节点系统，中断与业务均使用 NUMA 0"
    else
        # 多 NUMA: 从 distance 表中找离 NIC 所在节点最近的其他节点
        APP_NUMA=$(select_nearest_numa "$NIC_NUMA")
        log_info "-> 中断处理节点 (NIC 直连): NUMA $NIC_NUMA"
        log_info "-> 业务运行节点 (iperf 隔离): NUMA $APP_NUMA (最近邻)"
    fi

    # 整合执行各项优化与绑核
    optimize_all

    # 选择角色
    echo ""
    echo "选择运行模式:"
    echo "  1) 服务端 (Server)"
    echo "  2) 客户端 (Client)"
    local mode="${1:-${MODE_ARG:-}}"
    if [ -z "$mode" ]; then
        echo ""
        echo "选择运行模式:"
        echo "  1) 服务端 (Server)"
        echo "  2) 客户端 (Client)"
        read -r -p "请输入选择 [1-2]: " mode
    fi

    case $mode in
        1)
            setup_server_ips
            run_server "$APP_NUMA"
            log_info "服务端已启动，等待客户端连接... (Ctrl+C 退出)"
            # 等待后台 server 进程，不会因为非零退出码崩溃
            for pid in "${SERVER_PIDS[@]}"; do
                wait "$pid" 2>/dev/null || true
            done
            ;;
        2)
            setup_client_ips

            local server_ip="${2:-192.168.100.2}"
            local duration="${3:-60}"
            if [ $# -lt 2 ] && [ "$AUTO_YES" -ne 1 ]; then
                read -r -p "请输入服务器 IP (Pair1) [默认: 192.168.100.2]: " server_ip
                server_ip=${server_ip:-192.168.100.2}
            fi
            if [ $# -lt 3 ] && [ "$AUTO_YES" -ne 1 ]; then
                read -r -p "测试时长(秒) [默认: 60]: " duration
                duration=${duration:-60}
            fi

            run_client "$server_ip" "$APP_NUMA" "$duration"
            ;;
        *)
            log_error "无效选择"
            ;;
    esac
}

# 运行主函数
main "$@"
