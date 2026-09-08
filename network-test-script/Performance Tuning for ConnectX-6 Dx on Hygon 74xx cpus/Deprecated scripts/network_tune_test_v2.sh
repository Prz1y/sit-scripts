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
SERVER_IP_ARG=${2:-}
DURATION_ARG=${3:-}
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
    for pid in "${SERVER_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${MONITOR_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    # 恢复 irqbalance
    if systemctl list-unit-files irqbalance.service >/dev/null 2>&1; then
        sudo systemctl start irqbalance 2>/dev/null || true
        log_info "已恢复 irqbalance 服务"
    fi
    sudo sysctl -w kernel.numa_balancing=1 &>/dev/null || true
    remove_added_raw_rules
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
# 1. 自动检测网卡
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
# 4.1 选择离目标 NUMA 最近的其他 NUMA 节点
#############################################################################
select_nearest_numa() {
    local target=$1
    local best_node=""
    local best_dist=9999
    local dist_line
    dist_line=$(numactl -H | awk "/^  *${target}:/{print}")
    if [ -z "$dist_line" ]; then
        local count
        count=$(get_numa_count)
        echo $(( (target + 1) % count ))
        return
    fi
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
    echo -n -e "  执行: ${cmd} ... "
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
# 5.1 生成 CPU hex 位掩码
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
# 6. 路由调优
#############################################################################
setup_route_tuning() {
    log_info "设置路由初始窗口 (initcwnd/initrwnd)..."
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
    cat /proc/net/softnet_stat > "${LOG_DIR}/softnet_before.log" 2>/dev/null
    ethtool -S "$nic1" > "${LOG_DIR}/${nic1}_ethtool_S_before.log" 2>/dev/null || true
    ethtool -S "$nic2" > "${LOG_DIR}/${nic2}_ethtool_S_before.log" 2>/dev/null || true
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
    for pid in "${MONITOR_PIDS[@]}"; do
        kill -INT "$pid" 2>/dev/null || true
    done
    for pid in "${MONITOR_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    sleep 1
    cat /proc/net/softnet_stat > "${LOG_DIR}/softnet_after.log" 2>/dev/null
    ethtool -S "$nic1" > "${LOG_DIR}/${nic1}_ethtool_S_after.log" 2>/dev/null || true
    ethtool -S "$nic2" > "${LOG_DIR}/${nic2}_ethtool_S_after.log" 2>/dev/null || true

    echo ""
    log_info "=== 诊断信息 ==="
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    log_info "TCP 拥塞控制: $cc"

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

    if [ -f "${LOG_DIR}/softnet_before.log" ] && [ -f "${LOG_DIR}/softnet_after.log" ]; then
        local sn_drop_b sn_drop_a
        sn_drop_b=$(awk '{s+=strtonum("0x"$2)}END{print s}' "${LOG_DIR}/softnet_before.log" 2>/dev/null)
        sn_drop_a=$(awk '{s+=strtonum("0x"$2)}END{print s}' "${LOG_DIR}/softnet_after.log" 2>/dev/null)
        echo ""
        log_info "softnet_stat 丢包 (全局): $((sn_drop_a - sn_drop_b))"
    fi
    echo ""
    log_info "完整诊断日志: ${LOG_DIR}/"
}


#############################################################################
# 6.3 防火墙放通 iperf 端口
#############################################################################
setup_firewall() {
    log_info "配置防火墙放通 iperf 端口 (5001-5016 / 6001-6016)..."
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        log_info "检测到 firewalld 正在运行，添加端口规则..."
        sudo firewall-cmd --zone=public --add-port=5001-5016/tcp --permanent 2>/dev/null || true
        sudo firewall-cmd --zone=public --add-port=6001-6016/tcp --permanent 2>/dev/null || true
        sudo firewall-cmd --reload 2>/dev/null || true
        log_info "firewalld 已放通 5001-5016 / 6001-6016"
        return
    fi
    if command -v iptables &>/dev/null; then
        log_info "使用 iptables 放通端口..."
        sudo iptables -D INPUT -p tcp --dport 5001:5016 -j ACCEPT 2>/dev/null || true
        sudo iptables -D INPUT -p tcp --dport 6001:6016 -j ACCEPT 2>/dev/null || true
        sudo iptables -I INPUT 1 -p tcp --dport 5001:5016 -j ACCEPT 2>/dev/null || true
        sudo iptables -I INPUT 1 -p tcp --dport 6001:6016 -j ACCEPT 2>/dev/null || true
        log_info "iptables 已放通 5001-5016 / 6001-6016"
        return
    fi
    if command -v nft &>/dev/null; then
        log_info "使用 nft 放通端口..."
        sudo nft add rule inet filter input tcp dport 5001-5016 accept 2>/dev/null || true
        sudo nft add rule inet filter input tcp dport 6001-6016 accept 2>/dev/null || true
        log_info "nft 已放通 5001-5016 / 6001-6016"
        return
    fi
    log_warn "未检测到防火墙工具，跳过"
}

#############################################################################
# 7. 系统与网卡优化 (修正版: 去掉 RPS, 队列上限 16, 并行流回归合理值)
#############################################################################
optimize_all() {
    local nic1=${NICS[0]}
    local nic2=${NICS[1]}

    local nic1_numa nic2_numa
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
    run_cmd "systemctl disable irqbalance"
    # 确保 irqbalance 进程彻底终止 (防止残留进程覆盖 IRQ 亲和性)
    sudo pkill -9 irqbalance 2>/dev/null || true
    sleep 0.5
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
    run_cmd "sysctl -w net.ipv4.tcp_slow_start_after_idle=0"
    run_cmd "sysctl -w net.ipv4.tcp_mtu_probing=1"

    # 拥塞控制: 直连场景 cubic 无 pacing 限速
    run_cmd "sysctl -w net.core.default_qdisc=fq_codel"
    run_cmd "sysctl -w net.ipv4.tcp_congestion_control=cubic"

    # 软中断预算
    run_cmd "sysctl -w net.core.netdev_budget=1200"
    run_cmd "sysctl -w net.core.netdev_budget_usecs=20000"
    run_cmd "sysctl -w net.core.busy_read=50"
    run_cmd "sysctl -w net.core.busy_poll=50"

    # 禁用 NUMA 自动均衡 (防止内存页在 NUMA 节点间迁移导致延迟抖动)
    run_cmd "sysctl -w kernel.numa_balancing=0"

    # --- 按网口分别优化与绑核 ---
    local nic_list=("$nic1" "$nic2")
    local numa_list=("$nic1_numa" "$nic2_numa")

    for i in 0 1; do
        local nic="${nic_list[$i]}"
        local this_numa="${numa_list[$i]}"

        local cpus_str
        cpus_str=$(get_numa_cpus "$this_numa")
        local -a cpus_all=()
        read -r -a cpus_all <<< "$cpus_str"
        local total=${#cpus_all[@]}

        local bind_cpus
        local queues

        if [ "$nic1_numa" = "$nic2_numa" ]; then
            local half=$((total / 2))
            if [ $i -eq 0 ]; then
                bind_cpus="${cpus_all[*]:0:$half}"
            else
                bind_cpus="${cpus_all[*]:$half}"
            fi
            queues=$half
        else
            bind_cpus="${cpus_all[*]}"
            queues=$total
        fi

        # ★ 队列数上限 16: 100G 网卡最优区间 8~16, 超过反而增加中断开销
        if [ "$queues" -gt 16 ]; then
            queues=16
            # 截取前 16 个 CPU 用于绑核
            local -a cpu_tmp=()
            read -r -a cpu_tmp <<< "$bind_cpus"
            bind_cpus="${cpu_tmp[*]:0:16}"
        fi

        # 保存队列数 (取两口中较小值)
        if [ $i -eq 0 ] || [ "$queues" -lt "$QUEUES_PER_NIC" ]; then
            QUEUES_PER_NIC=$queues
        fi

        log_info "------------------------------------------"
        log_info "优化网卡 $nic (NUMA $this_numa, 队列=${queues}, 绑核: ${bind_cpus})"
        run_cmd "ip link set dev $nic mtu 9000"
        run_cmd "ethtool -L $nic combined $queues"
        run_cmd "ethtool -G $nic rx 8192 tx 8192"
        # rx-usecs: 7队列各处理~14G, 128μs间隔太长导致延迟累积, 64μs更适合高吞吐
        run_cmd "ethtool -C $nic adaptive-rx off adaptive-tx off rx-usecs 64 tx-usecs 64"

        # 网卡 offload
        run_cmd "ethtool -K $nic rx on tx on tso on gso on gro on lro on"
        run_cmd "ethtool -K $nic tx-nocache-copy off"
        run_cmd "ethtool -K $nic ntuple on"
        run_cmd "ethtool -K $nic rxhash on"
        # 关闭流控
        run_cmd "ethtool -A $nic rx off tx off"

        # 中断绑核 (mlx5_comp 中断向量)
        local pci_dev
        pci_dev=$(basename "$(readlink -f /sys/class/net/${nic}/device)" 2>/dev/null)
        local irqs=()
        if [ -n "$pci_dev" ]; then
            mapfile -t irqs < <(grep "mlx5_comp.*${pci_dev}" /proc/interrupts | awk -F: '{print $1}' | tr -d ' ' || true)
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

        # RSS 间接表均匀分布 + 4-tuple 哈希
        run_cmd "ethtool -X $nic equal $queues"
        run_cmd "ethtool -N $nic rx-flow-hash tcp4 sdfn"
        run_cmd "ethtool -N $nic rx-flow-hash udp4 sdfn"

        # XPS: 每个 TX 队列绑定对应 CPU
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

        # ★ 不启用 RPS: mlx5 硬件 RSS + IRQ 绑核已足够, 软件 RPS 只增加开销
    done

    log_info "------------------------------------------"

    # ==================== 清除 RPS 残留 (防止与硬件 RSS 冲突) ====================
    # RPS (软件包转向) 与硬件 RSS 同时启用会导致:
    #   1. 额外 IPI (核间中断) 将包从 RSS 选择的 CPU 转发到 RPS 选择的 CPU
    #   2. 严重 CPU cache miss (包数据在错误的 CPU 缓存中)
    #   3. 实测可导致 100G 降至 50-60G
    log_info "清除所有网卡 RPS 设置 (防止与硬件 RSS 冲突)..."
    for nic in "${nic_list[@]}"; do
        local rps_cleared=0
        for f in /sys/class/net/${nic}/queues/rx-*/rps_cpus; do
            if [ -f "$f" ]; then
                write_root_file 0 "$f" 2>/dev/null && rps_cleared=$((rps_cleared + 1))
            fi
        done
        echo -e "  [RPS] $nic 已清除 ${rps_cleared} 个队列的 RPS ... ${GREEN}[完成]${NC}"
    done
    # 清除 RFS
    run_cmd "sysctl -w net.core.rps_sock_flow_entries=0"

    # ==================== 绕过 conntrack 连接跟踪 ====================
    # nf_conntrack 对每个包做连接跟踪哈希查找, 100G 下开销显著
    log_info "为 iperf 端口绕过 conntrack 连接跟踪..."
    if command -v iptables &>/dev/null; then
        # 先清理旧规则 (避免重复)
        add_raw_notrack_rule PREROUTING --dport 5001:5100
        add_raw_notrack_rule PREROUTING --dport 6001:6100
        add_raw_notrack_rule PREROUTING --sport 5001:5100
        add_raw_notrack_rule PREROUTING --sport 6001:6100
        add_raw_notrack_rule OUTPUT --sport 5001:5100
        add_raw_notrack_rule OUTPUT --sport 6001:6100
        log_info "  已为端口 5001-5100 / 6001-6100 绕过 conntrack"
    fi

    log_info "每口队列数: $QUEUES_PER_NIC | 多进程模式: 每口${QUEUES_PER_NIC}进程×2流"
}

#############################################################################
# 配置网卡 IP（服务端）
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
    setup_route_tuning
    setup_firewall
}

#############################################################################
# 配置网卡 IP（客户端）
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
    setup_route_tuning
    setup_firewall
}

#############################################################################
# 运行服务端
#############################################################################
run_server() {
    local app_numa=$1
    log_info "启动 iperf 服务端 (多实例模式, NUMA $app_numa)..."
    mkdir -p "$LOG_DIR"
    local nic1=${NICS[0]}
    local nic2=${NICS[1]}

    # 获取 APP NUMA 的 CPU 列表
    local app_cpus_str
    app_cpus_str=$(get_numa_cpus "$app_numa")
    local -a app_cpus=()
    read -r -a app_cpus <<< "$app_cpus_str"
    local num_app_cpus=${#app_cpus[@]}

    # ★ 实例数固定 3: 实测 7 进程×2 流开销过大 (进程调度 + 系统调用),
    #   3 进程×5 流是最佳平衡 (足够覆盖 RSS 队列, 进程开销最小化)
    local num_inst=3

    # Pair1: 端口 5001..5000+num_inst
    log_info "Pair1 ($nic1): 启动 ${num_inst} 个 server 实例 (端口 5001-$((5000+num_inst)))..."
    for ((j=0; j<num_inst; j++)); do
        local port=$((5001 + j))
        local cpu=${app_cpus[$((j % num_app_cpus))]}
        taskset -c "$cpu" \
            iperf -s -p "$port" > "${LOG_DIR}/${nic1}_server_p${j}.log" 2>&1 &
        SERVER_PIDS+=("$!")
    done
    sleep 1

    # Pair2: 端口 6001..6000+num_inst
    log_info "Pair2 ($nic2): 启动 ${num_inst} 个 server 实例 (端口 6001-$((6000+num_inst)))..."
    for ((j=0; j<num_inst; j++)); do
        local port=$((6001 + j))
        local cpu=${app_cpus[$(( (j + num_inst) % num_app_cpus ))]}
        taskset -c "$cpu" \
            iperf -s -p "$port" > "${LOG_DIR}/${nic2}_server_p${j}.log" 2>&1 &
        SERVER_PIDS+=("$!")
    done
    sleep 1

    log_info "服务端已启动: Pair1 端口 5001-$((5000+num_inst)), Pair2 端口 6001-$((6000+num_inst))"
    log_info "每口 ${num_inst} 个独立 server 进程，各自绑核"
    ss -tulpn 2>/dev/null | grep -E ":(5001|5002|6001|6002)" || true
    log_info "服务端日志: ${LOG_DIR}/"
}

#############################################################################
# 连通性预检
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
# 运行客户端测试
#############################################################################
run_client() {
    local server_ip=$1
    local app_numa=$2
    local duration=$3

    local server_ip2
    server_ip2=$(echo "$server_ip" | sed 's/\.100\./.110./')

    local nic1=${NICS[0]}
    local nic2=${NICS[1]}

    check_connectivity "$server_ip" "$server_ip2"

    mkdir -p "$LOG_DIR"

    # ★ 多端口多实例: 客户端和服务端各 N 个进程, 一一对应, 消除双端锁竞争
    local app_cpus_str
    app_cpus_str=$(get_numa_cpus "$app_numa")
    local -a app_cpus=()
    read -r -a app_cpus <<< "$app_cpus_str"
    local num_app_cpus=${#app_cpus[@]}
    # ★ 3 进程 × 5 流 = 15 流/口: 最佳平衡
    #   - 3 进程: 最小化进程调度和系统调用开销
    #   - 5 流/进程: 15 流 > 7 队列, 确保 RSS 间接表每个队列都有流量
    #   - 对比: 7进程×2流=122G, 单进程×14流=164G → 3进程×5流预期接近最优
    local num_inst=3
    local flows_per_inst=5

    log_info "启动 iperf 客户端 (多实例模式, NUMA $app_numa)..."
    log_info "连接服务器 Pair1 ($nic1): $server_ip:5001-$((5000+num_inst))"
    log_info "连接服务器 Pair2 ($nic2): $server_ip2:6001-$((6000+num_inst))"
    log_info "测试时长: ${duration}s | 每口${num_inst}实例×${flows_per_inst}流 | 总流数/口: $((num_inst*flows_per_inst)) | TCP: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"

    start_monitoring "$duration"

    local all_pids=()

    # Pair1: 每实例连接对应端口 5001+j, 绑核到前半 CPU
    log_info "启动 Pair1 ($nic1 -> $server_ip) ${num_inst} 个实例..."
    for ((j=0; j<num_inst; j++)); do
        local port=$((5001 + j))
        local cpu=${app_cpus[$((j % num_app_cpus))]}
        taskset -c "$cpu" \
            iperf -c "${server_ip}" -p "$port" -P "$flows_per_inst" \
            -t "$duration" -i 5 -w 4m -N \
            > "${LOG_DIR}/${nic1}_pair1_p${j}.log" 2>&1 &
        all_pids+=("$!")
    done
    sleep 1

    # Pair2: 每实例连接对应端口 6001+j, 绑核到后半 CPU
    log_info "启动 Pair2 ($nic2 -> $server_ip2) ${num_inst} 个实例..."
    for ((j=0; j<num_inst; j++)); do
        local port=$((6001 + j))
        local cpu=${app_cpus[$(( (j + num_inst) % num_app_cpus ))]}
        taskset -c "$cpu" \
            iperf -c "${server_ip2}" -p "$port" -P "$flows_per_inst" \
            -t "$duration" -i 5 -w 4m -N \
            > "${LOG_DIR}/${nic2}_pair2_p${j}.log" 2>&1 &
        all_pids+=("$!")
    done

    # 等待所有进程完成
    for pid in "${all_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    stop_monitoring

    echo ""
    log_info "=========================================="
    log_info "  测试完成！"
    log_info "=========================================="
    log_info "日志目录: ${LOG_DIR}/"

    # ★ 聚合各实例结果
    echo ""
    log_info "=== $nic1 (Pair1) 测试结果 ==="
    local pair1_gbps=0
    for ((j=0; j<num_inst; j++)); do
        local f="${LOG_DIR}/${nic1}_pair1_p${j}.log"
        local bw
        bw=$(grep '\[SUM\]' "$f" 2>/dev/null | tail -1 | awk '{
            for(i=1;i<=NF;i++){
                if($i=="Gbits/sec"){printf "%.2f",$(i-1);exit}
                if($i=="Mbits/sec"){printf "%.4f",$(i-1)/1000;exit}
            }}')
        if [ -z "$bw" ]; then
            # 单流 (无 SUM 行)
            bw=$(tail -1 "$f" 2>/dev/null | awk '{
                for(i=1;i<=NF;i++){
                    if($i=="Gbits/sec"){printf "%.2f",$(i-1);exit}
                    if($i=="Mbits/sec"){printf "%.4f",$(i-1)/1000;exit}
                }}')
        fi
        if [ -n "$bw" ]; then
            log_info "  实例$j (端口$((5001+j))): ${bw} Gbits/sec"
            pair1_gbps=$(awk "BEGIN{printf \"%.2f\",$pair1_gbps+$bw}")
        fi
    done
    log_info "  ★ Pair1 合计: ${pair1_gbps} Gbits/sec"

    echo ""
    log_info "=== $nic2 (Pair2) 测试结果 ==="
    local pair2_gbps=0
    for ((j=0; j<num_inst; j++)); do
        local f="${LOG_DIR}/${nic2}_pair2_p${j}.log"
        local bw
        bw=$(grep '\[SUM\]' "$f" 2>/dev/null | tail -1 | awk '{
            for(i=1;i<=NF;i++){
                if($i=="Gbits/sec"){printf "%.2f",$(i-1);exit}
                if($i=="Mbits/sec"){printf "%.4f",$(i-1)/1000;exit}
                }}')
        if [ -z "$bw" ]; then
            bw=$(tail -1 "$f" 2>/dev/null | awk '{
                for(i=1;i<=NF;i++){
                    if($i=="Gbits/sec"){printf "%.2f",$(i-1);exit}
                    if($i=="Mbits/sec"){printf "%.4f",$(i-1)/1000;exit}
                }}')
        fi
        if [ -n "$bw" ]; then
            log_info "  实例$j (端口$((6001+j))): ${bw} Gbits/sec"
            pair2_gbps=$(awk "BEGIN{printf \"%.2f\",$pair2_gbps+$bw}")
        fi
    done
    log_info "  ★ Pair2 合计: ${pair2_gbps} Gbits/sec"

    echo ""
    local total_gbps
    total_gbps=$(awk "BEGIN{printf \"%.2f\",$pair1_gbps+$pair2_gbps}")
    log_info "★★★ 双口总计: ${total_gbps} Gbits/sec ★★★"
}

#############################################################################
# 主菜单
#############################################################################
main() {
    log_info "=========================================="
    log_info "  网络性能调优与测试脚本 - 双口 100G        "
    log_info "=========================================="

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    LOG_DIR="/tmp/iperf_logs/${TIMESTAMP}"

    check_deps
    detect_nics

    NIC_NUMA=$(get_numa_info "${NICS[0]}")
    local numa_count
    numa_count=$(get_numa_count)

    if [ "$numa_count" -le 1 ] 2>/dev/null; then
        APP_NUMA=0
        log_warn "单 NUMA 节点系统，中断与业务均使用 NUMA 0"
    else
        APP_NUMA=$(select_nearest_numa "$NIC_NUMA")
        log_info "-> 中断处理节点 (NIC 直连): NUMA $NIC_NUMA"
        log_info "-> 业务运行节点 (iperf 隔离): NUMA $APP_NUMA (最近邻)"
    fi

    optimize_all

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
            for pid in "${SERVER_PIDS[@]}"; do
                wait "$pid" 2>/dev/null || true
            done
            ;;
        2)
            setup_client_ips
            local server_ip="${2:-${SERVER_IP_ARG:-192.168.100.2}}"
            local duration="${3:-${DURATION_ARG:-60}}"
            if [ -z "${SERVER_IP_ARG:-}" ] && [ "$AUTO_YES" -ne 1 ]; then
                read -r -p "请输入服务器 IP (Pair1) [默认: 192.168.100.2]: " server_ip
                server_ip=${server_ip:-192.168.100.2}
            fi
            if [ -z "${DURATION_ARG:-}" ] && [ "$AUTO_YES" -ne 1 ]; then
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

main "$@"