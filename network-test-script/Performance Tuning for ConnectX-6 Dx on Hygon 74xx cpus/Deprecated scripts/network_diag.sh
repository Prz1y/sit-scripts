#!/bin/bash

set -euo pipefail

###############################################################################
#  网络性能诊断脚本 — 排查 100G Mellanox NIC 吞吐下降根因
#  用法: sudo bash network_diag.sh
###############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SEP="============================================================"
WARN_COUNT=0
ISSUE_LIST=()

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[⚠]${NC} $1"; WARN_COUNT=$((WARN_COUNT+1)); ISSUE_LIST+=("$1"); }
fail()  { echo -e "${RED}[✗]${NC} $1"; WARN_COUNT=$((WARN_COUNT+1)); ISSUE_LIST+=("$1"); }
header(){ echo -e "\n${CYAN}${BOLD}$SEP${NC}"; echo -e "${CYAN}${BOLD}  $1${NC}"; echo -e "${CYAN}${BOLD}$SEP${NC}"; }

###############################################################################
header "0. 系统基本信息"
###############################################################################
echo "  主机名: $(hostname)"
echo "  内核:   $(uname -r)"
echo "  OS:     $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
echo "  CPU:    $(lscpu | grep 'Model name' | sed 's/Model name:[[:space:]]*//')"
echo "  核心数: $(nproc) ($(lscpu | grep '^Socket' | awk '{print $NF}') sockets × $(lscpu | grep 'Core(s) per socket' | awk '{print $NF}') cores)"
echo "  内存:   $(free -g | awk '/Mem:/{print $2}') GB"
echo "  NUMA 节点数: $(numactl -H 2>/dev/null | grep '^available:' | awk '{print $2}')"

###############################################################################
header "1. Mellanox NIC 检测与 PCIe 链路状态"
###############################################################################
NICS=()
for path in /sys/class/net/*/; do
    nic=$(basename "$path")
    if ethtool -i "$nic" 2>/dev/null | grep -q "driver: mlx5_core"; then
        NICS+=("$nic")
    fi
done

if [ ${#NICS[@]} -eq 0 ]; then
    fail "未检测到 mlx5_core 网卡！"
else
    info "检测到 ${#NICS[@]} 个 Mellanox 网口: ${NICS[*]}"
fi

for nic in "${NICS[@]}"; do
    echo ""
    echo -e "  ${BOLD}--- $nic ---${NC}"
    
    # 驱动信息
    # (bare-word declarations removed; variables assigned below)
    drv_ver=$(ethtool -i "$nic" 2>/dev/null | grep 'version' | head -1)
    fw_ver=$(ethtool -i "$nic" 2>/dev/null | grep 'firmware' | head -1)
    echo "  $drv_ver"
    echo "  $fw_ver"
    
    # 链路状态
    link_speed=$(ethtool "$nic" 2>/dev/null | grep 'Speed:' | awk '{print $2}')
    link_status=$(ethtool "$nic" 2>/dev/null | grep 'Link detected:' | awk '{print $3}')
    echo "  链路速率: $link_speed | 链路状态: $link_status"
    
    if [ "$link_status" != "yes" ]; then
        fail "$nic 链路未连接！"
    fi
    if [[ "$link_speed" != "100000Mb/s" ]]; then
        warn "$nic 链路速率非 100G ($link_speed)，请检查线缆/模块"
    else
        info "$nic 链路速率 100G 正常"
    fi

    # PCIe 带宽 (关键！)
    pci_addr=$(basename "$(readlink -f /sys/class/net/${nic}/device)" 2>/dev/null)
    if [ -n "$pci_addr" ]; then
        echo "  PCI 地址: $pci_addr"
        
        pcie_speed=$(lspci -vvs "$pci_addr" 2>/dev/null | grep "LnkSta:" | head -1 | grep -oP 'Speed \K[^,]+')
        pcie_width=$(lspci -vvs "$pci_addr" 2>/dev/null | grep "LnkSta:" | head -1 | grep -oP 'Width \K[^,]+')
        
        pcie_cap_speed=$(lspci -vvs "$pci_addr" 2>/dev/null | grep "LnkCap:" | head -1 | grep -oP 'Speed \K[^,]+')
        pcie_cap_width=$(lspci -vvs "$pci_addr" 2>/dev/null | grep "LnkCap:" | head -1 | grep -oP 'Width \K[^,]+')
        
        echo "  PCIe 实际: Speed=${pcie_speed} Width=${pcie_width}"
        echo "  PCIe 能力: Speed=${pcie_cap_speed} Width=${pcie_cap_width}"
        
        if [ "$pcie_speed" != "$pcie_cap_speed" ]; then
            fail "$nic PCIe 速率降级！实际=${pcie_speed} 能力=${pcie_cap_speed} — 这是性能瓶颈！"
        fi
        if [ "$pcie_width" != "$pcie_cap_width" ]; then
            fail "$nic PCIe 宽度降级！实际=${pcie_width} 能力=${pcie_cap_width} — 这是性能瓶颈！"
        fi
        if [ "$pcie_speed" = "$pcie_cap_speed" ] && [ "$pcie_width" = "$pcie_cap_width" ]; then
            info "$nic PCIe 链路正常 (${pcie_speed} × ${pcie_width})"
        fi
        
        # ASPM 状态 (应为 Disabled)
        aspm=$(lspci -vvs "$pci_addr" 2>/dev/null | grep "ASPM" | head -1)
        if echo "$aspm" | grep -qi "enabled\|L0s\|L1"; then
            warn "$nic PCIe ASPM 已启用 (省电模式会增加延迟): $aspm"
        else
            info "$nic ASPM 已禁用"
        fi
    fi

    # NUMA 节点
    nic_numa=$(cat /sys/class/net/${nic}/device/numa_node 2>/dev/null)
    echo "  NUMA 节点: $nic_numa"

    # MTU
    mtu=$(cat /sys/class/net/${nic}/mtu 2>/dev/null)
    echo "  MTU: $mtu"
    if [ "$mtu" -lt 9000 ] 2>/dev/null; then
        warn "$nic MTU=$mtu (建议 9000 jumbo frame)"
    else
        info "$nic MTU=$mtu (Jumbo Frame 已启用)"
    fi

    # Ring buffer
    # 更可靠的方式
    echo "  Ring Buffer (ethtool -g):"
    ethtool -g "$nic" 2>/dev/null | grep -A1 "Current" | head -5 | sed 's/^/    /'

    # 队列数
    combined_q=$(ethtool -l "$nic" 2>/dev/null | awk '/Current/{found=1} found && /Combined/{print $2; exit}')
    echo "  Combined 队列数: $combined_q"

    # Coalesce 设置
    echo "  中断合并 (ethtool -c):"
    ethtool -c "$nic" 2>/dev/null | grep -E "rx-usecs|tx-usecs|adaptive" | sed 's/^/    /'

    # Offloads
    echo "  关键 Offload:"
    ethtool -k "$nic" 2>/dev/null | grep -E "^(tcp-segmentation|generic-segmentation|generic-receive|large-receive|rx-checksumming|tx-checksumming)" | sed 's/^/    /'

    # 流控
    echo "  流控 (ethtool -a):"
    ethtool -a "$nic" 2>/dev/null | grep -E "RX|TX" | sed 's/^/    /'

    # 错误/丢包统计
    echo "  关键错误计数器:"
    ethtool -S "$nic" 2>/dev/null | grep -E "rx_discards|rx_out_of_buffer|tx_errors|rx_errors|rx_crc_err|rx_length_err|tx_dropped|rx_dropped" | while read line; do
        val=$(echo "$line" | awk '{print $2}')
        if [ "$val" -gt 0 ] 2>/dev/null; then
            echo -e "    ${RED}$line${NC}"
        else
            echo "    $line"
        fi
    done
done

###############################################################################
header "2. IOMMU / VT-d 状态 (关键性能杀手)"
###############################################################################
echo "  内核命令行:"
cat /proc/cmdline | tr ' ' '\n' | grep -iE "iommu|intel_iommu|amd_iommu" | sed 's/^/    /'

# 检查 IOMMU 是否活跃
if dmesg 2>/dev/null | grep -qi "DMAR.*IOMMU enabled\|AMD-Vi.*enabled\|IOMMU.*enabled"; then
    fail "IOMMU 已启用！这会导致 DMA 重映射开销，严重影响网络吞吐 (可降低 20-40%)"
    echo "  修复方法: 在 GRUB 内核参数中添加 intel_iommu=off 或 iommu=off"
elif cat /proc/cmdline | grep -qi "intel_iommu=on\|iommu=pt\|iommu=on"; then
    iommu_mode
    iommu_mode=$(cat /proc/cmdline | tr ' ' '\n' | grep -iE "iommu")
    if echo "$iommu_mode" | grep -q "iommu=pt"; then
        warn "IOMMU 为 passthrough 模式 (iommu=pt)，性能影响较小但仍有开销"
    else
        warn "IOMMU 参数检测到: $iommu_mode — 可能影响性能"
    fi
else
    info "IOMMU 未启用 (或已关闭)"
fi

# 检查 VFIO
if lsmod 2>/dev/null | grep -q vfio; then
    warn "检测到 VFIO 模块已加载，可能与 IOMMU 相关"
fi

###############################################################################
header "3. CPU 频率与电源管理"
###############################################################################

# Governor
echo "  CPU 频率调节器:"
gov_list=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | sort -rn)
if [ -n "$gov_list" ]; then
    echo "$gov_list" | sed 's/^/    /'
    if echo "$gov_list" | grep -qv performance; then
        warn "部分 CPU 未设置 performance 调节器！"
    else
        info "所有 CPU 均为 performance 调节器"
    fi
else
    warn "无法读取 CPU 调节器 (可能使用 intel_pstate 或无 cpufreq)"
fi

# 实际频率
echo "  CPU 当前频率 (采样 4 个核心):"
for cpu in 0 1 $(( $(nproc) / 2 )) $(( $(nproc) - 1 )); do
    freq
    freq=$(cat /sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_cur_freq 2>/dev/null)
    if [ -n "$freq" ]; then
        echo "    CPU $cpu: $((freq / 1000)) MHz"
    fi
done

# Turbo Boost
turbo_file="/sys/devices/system/cpu/intel_pstate/no_turbo"
if [ -f "$turbo_file" ]; then
    turbo_off
    turbo_off=$(cat "$turbo_file" 2>/dev/null)
    if [ "$turbo_off" = "1" ]; then
        warn "Intel Turbo Boost 已禁用！影响单核/少核性能"
    else
        info "Intel Turbo Boost 已启用"
    fi
fi

# C-States
echo "  C-State 状态:"
max_cstate=""
if cat /proc/cmdline | grep -qoP "intel_idle.max_cstate=\K\d+"; then
    max_cstate=$(cat /proc/cmdline | grep -oP "intel_idle.max_cstate=\K\d+")
    echo "    intel_idle.max_cstate=$max_cstate"
    if [ "$max_cstate" -gt 1 ] 2>/dev/null; then
        warn "深度 C-State 未限制 (max_cstate=$max_cstate)，可能增加中断唤醒延迟"
    fi
elif cat /proc/cmdline | grep -q "idle=poll"; then
    info "CPU idle=poll (无 C-State，最低延迟)"
else
    warn "未在内核参数中限制 C-State (建议 intel_idle.max_cstate=1 或 processor.max_cstate=1)"
fi

# P-State 驱动
pstate_drv
pstate_drv=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null)
echo "  频率调节驱动: ${pstate_drv:-未知}"

###############################################################################
header "4. 内核安全缓解措施 (Spectre/Meltdown)"
###############################################################################
echo "  内核缓解状态:"
if [ -d /sys/devices/system/cpu/vulnerabilities ]; then
    for v in /sys/devices/system/cpu/vulnerabilities/*; do
        name status
        name=$(basename "$v")
        status=$(cat "$v" 2>/dev/null)
        if echo "$status" | grep -qi "mitigation"; then
            echo -e "    ${YELLOW}$name${NC}: $status"
        elif echo "$status" | grep -qi "not affected\|vulnerable"; then
            echo "    $name: $status"
        else
            echo "    $name: $status"
        fi
    done
else
    echo "    无法读取漏洞缓解状态"
fi

# 检查是否禁用了缓解措施
if cat /proc/cmdline | grep -q "mitigations=off"; then
    info "内核参数已设置 mitigations=off (最大性能)"
else
    warn "未设置 mitigations=off — Spectre/Meltdown 缓解措施会降低 5-15% 网络吞吐"
    echo "  如果是纯测试环境，可在 GRUB 中添加 mitigations=off"
fi

# retpoline
if cat /proc/cmdline | grep -q "spectre_v2=off\|nospectre_v2"; then
    info "Spectre V2 缓解已关闭"
else
    if dmesg 2>/dev/null | grep -qi "retpoline"; then
        warn "Retpoline 已启用 (间接调用开销增加，影响网络栈性能)"
    fi
fi

###############################################################################
header "5. 内存与 NUMA 配置"
###############################################################################

# 透明大页
thp
thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
echo "  透明大页 (THP): $thp"

# NUMA balancing
numa_bal
numa_bal=$(sysctl -n kernel.numa_balancing 2>/dev/null)
echo "  NUMA Balancing: $numa_bal"
if [ "$numa_bal" = "1" ]; then
    warn "NUMA 自动均衡已启用 (kernel.numa_balancing=1) — 会导致页面在 NUMA 节点间迁移，增加延迟"
    echo "  修复: sysctl -w kernel.numa_balancing=0"
fi

# NUMA 距离表
echo "  NUMA 距离表:"
numactl -H 2>/dev/null | grep -A20 "^node distances" | head -15 | sed 's/^/    /'

###############################################################################
header "6. 关键 Sysctl 网络参数"
###############################################################################
declare -A EXPECTED_PARAMS
EXPECTED_PARAMS=(
    ["net.core.rmem_max"]="2147483647"
    ["net.core.wmem_max"]="2147483647"
    ["net.core.netdev_max_backlog"]="250000"
    ["net.core.netdev_budget"]="1200"
    ["net.core.netdev_budget_usecs"]="20000"
    ["net.core.busy_read"]="50"
    ["net.core.busy_poll"]="50"
    ["net.core.somaxconn"]="65535"
    ["net.ipv4.tcp_congestion_control"]="cubic"
    ["net.ipv4.tcp_tw_reuse"]="1"
    ["net.ipv4.tcp_timestamps"]="1"
    ["net.ipv4.tcp_sack"]="1"
    ["net.ipv4.tcp_slow_start_after_idle"]="0"
    ["net.ipv4.tcp_mtu_probing"]="1"
)

for param in "${!EXPECTED_PARAMS[@]}"; do
    actual expected
    actual=$(sysctl -n "$param" 2>/dev/null | tr -d '[:space:]' | head -1)
    expected="${EXPECTED_PARAMS[$param]}"
    if [ "$actual" = "$expected" ]; then
        echo -e "  ${GREEN}✓${NC} $param = $actual"
    else
        echo -e "  ${RED}✗${NC} $param = $actual (期望: $expected)"
        warn "$param 值异常: $actual (期望 $expected)"
    fi
done

# TCP 缓冲区 (特殊处理多值)
echo ""
echo "  TCP 缓冲区:"
echo "    tcp_rmem: $(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
echo "    tcp_wmem: $(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
echo "    tcp_mem:  $(sysctl -n net.ipv4.tcp_mem 2>/dev/null)"

# qdisc
echo ""
echo "  默认 qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null)"

###############################################################################
header "7. IRQ 亲和性检查"
###############################################################################
for nic in "${NICS[@]}"; do
    echo ""
    echo -e "  ${BOLD}--- $nic IRQ 绑核状态 ---${NC}"
    pci_addr
    pci_addr=$(basename "$(readlink -f /sys/class/net/${nic}/device)" 2>/dev/null)
    
    if [ -z "$pci_addr" ]; then
        warn "无法获取 $nic 的 PCI 地址"
        continue
    fi
    
    irqs
    mapfile -t irqs < <(grep "mlx5_comp.*${pci_addr}" /proc/interrupts 2>/dev/null | awk -F:':' '{print $1}' | tr -d ' ' || true)

    if [ ${#irqs[@]} -eq 0 ]; then
        mapfile -t irqs < <(grep "${pci_addr}" /proc/interrupts 2>/dev/null | awk -F:':' '{print $1}' | tr -d ' ' || true)
    fi
    
    echo "  中断向量数: ${#irqs[@]}"
    
    cpu_set=()
    for irq in "${irqs[@]}"; do
        aff
        aff=$(cat /proc/irq/${irq}/smp_affinity_list 2>/dev/null)
        cpu_set+=("$aff")
    done
    
    # 统计绑定情况
    unique_cpus
    unique_cpus=$(printf '%s\n' "${cpu_set[@]}" | sort -un | tr '\n' ' ')
    echo "  绑定的 CPU: $unique_cpus"
    
    # 检查是否有 IRQ 绑到同一个 CPU
    dup_count
    dup_count=$(printf '%s\n' "${cpu_set[@]}" | sort | uniq -d | wc -l)
    if [ "$dup_count" -gt 0 ]; then
        warn "$nic 有 $dup_count 个 CPU 被多个 IRQ 共享"
    fi
    
    # 检查 irqbalance 是否在运行
    if systemctl is-active irqbalance &>/dev/null 2>&1; then
        fail "irqbalance 仍在运行！会覆盖手动 IRQ 绑核"
    fi
done

###############################################################################
header "8. 内核模块与驱动参数"
###############################################################################

# mlx5_core 参数
echo "  mlx5_core 模块参数:"
if [ -d /sys/module/mlx5_core/parameters ]; then
    for p in /sys/module/mlx5_core/parameters/*; do
        pname pval
        pname=$(basename "$p")
        pval=$(cat "$p" 2>/dev/null)
        echo "    $pname = $pval"
    done
else
    warn "无法读取 mlx5_core 模块参数"
fi

###############################################################################
header "9. 进程与服务干扰检查"
###############################################################################

# 高 CPU 使用率进程
echo "  TOP 10 CPU 消耗进程:"
ps -eo pid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null | head -11 | sed 's/^/    /'

# irqbalance 检查
echo ""
if systemctl is-active irqbalance &>/dev/null 2>&1; then
    fail "irqbalance 服务正在运行！"
else
    info "irqbalance 已停止"
fi

# tuned / power-profiles-daemon
tuned_profile=""
if command -v tuned-adm &>/dev/null; then
    tuned_profile=$(tuned-adm active 2>/dev/null)
    echo "  tuned 配置: $tuned_profile"
    if echo "$tuned_profile" | grep -qiE "balanced|powersave|virtual-guest"; then
        warn "tuned 配置非 throughput-performance！当前: $tuned_profile"
        echo "  修复: tuned-adm profile throughput-performance"
    fi
fi

# NetworkManager 干扰
if systemctl is-active NetworkManager &>/dev/null 2>&1; then
    warn "NetworkManager 正在运行 — 可能干扰手动网络配置"
fi

###############################################################################
header "10. 内核命令行完整参数"
###############################################################################
echo "  $(cat /proc/cmdline)"

###############################################################################
header "11. PCIe ACS (Access Control Services) 检查"
###############################################################################
echo "  检查 PCIe ACS 状态 (影响 DMA 路由):"
for nic in "${NICS[@]}"; do
    pci_addr
    pci_addr=$(basename "$(readlink -f /sys/class/net/${nic}/device)" 2>/dev/null)
    if [ -n "$pci_addr" ]; then
        acs
        acs=$(lspci -vvs "$pci_addr" 2>/dev/null | grep -i "ACSCtl" | head -1)
        if [ -n "$acs" ]; then
            echo "    $nic ($pci_addr): $acs"
        else
            echo "    $nic ($pci_addr): ACS 未检测到"
        fi
    fi
done

###############################################################################
header "12. RPS/RFS 状态 (可能的干扰源)"
###############################################################################
for nic in "${NICS[@]}"; do
    echo ""
    echo -e "  ${BOLD}--- $nic ---${NC}"
    
    # RPS
    echo "  RPS (Receive Packet Steering):"
    for f in /sys/class/net/${nic}/queues/rx-*/rps_cpus; do
        if [ -f "$f" ]; then
            val
            val=$(cat "$f" 2>/dev/null)
            q
            q=$(echo "$f" | grep -oP 'rx-\K\d+')
            # 非零 RPS 可能与硬件 RSS 冲突
            if [ "$val" != "00000000" ] && [ "$val" != "0" ] && echo "$val" | grep -qvE '^[0,]*$'; then
                echo -e "    rx-$q rps_cpus = ${YELLOW}$val${NC} (非零!)"
            fi
        fi
    done 2>/dev/null | head -5
    
    nonzero_rps
    nonzero_rps=$(cat /sys/class/net/${nic}/queues/rx-*/rps_cpus 2>/dev/null | grep -cvE '^[0,]*$')
    if [ "$nonzero_rps" -gt 0 ] 2>/dev/null; then
        warn "$nic 有 $nonzero_rps 个队列启用了 RPS — 可能与硬件 RSS 冲突导致性能下降！"
        echo "  修复: for f in /sys/class/net/${nic}/queues/rx-*/rps_cpus; do echo 0 > \$f; done"
    else
        info "$nic RPS 未启用 (正确，依赖硬件 RSS)"
    fi
    
    # RFS
    rfs_entries
    rfs_entries=$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null)
    echo "  RFS (rps_sock_flow_entries): $rfs_entries"
    if [ "$rfs_entries" -gt 0 ] 2>/dev/null; then
        warn "全局 RFS 已启用 (rps_sock_flow_entries=$rfs_entries)"
    fi
done

###############################################################################
header "13. 网卡 RSS Hash 与间接表"
###############################################################################
for nic in "${NICS[@]}"; do
    echo ""
    echo -e "  ${BOLD}--- $nic ---${NC}"
    
    # RSS hash function
    echo "  RSS 流哈希配置 (tcp4):"
    ethtool -n "$nic" rx-flow-hash tcp4 2>/dev/null | sed 's/^/    /'
    
    # 间接表分布
    echo "  RSS 间接表队列分布:"
    ethtool -x "$nic" 2>/dev/null | tail -n +3 | awk '{for(i=2;i<=NF;i++) print $i}' | sort -n | uniq -c | sort -rn | head -10 | sed 's/^/    /'
done

###############################################################################
header "14. iptables / nftables 规则 (可能阻断或增加开销)"
###############################################################################
echo "  iptables INPUT 链 (前 20 条):"
if command -v iptables >/dev/null 2>&1; then
    iptables -L INPUT -n --line-numbers 2>/dev/null | head -20 | sed 's/^/    /'
    echo ""
    echo "  iptables 规则总数: $(iptables -L -n 2>/dev/null | wc -l)"

    ipt_count=$(iptables -L -n 2>/dev/null | wc -l)
else
    echo "    未安装 iptables"
    ipt_count=0
fi
if [ "$ipt_count" -gt 50 ]; then
    warn "iptables 规则较多 ($ipt_count 行)，大量规则匹配会增加 per-packet 开销"
fi

# conntrack
echo ""
echo "  conntrack 状态:"
ct_count ct_max
ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || true)
ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true)
echo "    当前连接数: ${ct_count:-N/A} / 最大: ${ct_max:-N/A}"
if [ -n "$ct_count" ] && [ -n "$ct_max" ] && [ "$ct_max" -gt 0 ] 2>/dev/null; then
    usage_pct=$(( ct_count * 100 / ct_max ))
    if [ "$usage_pct" -gt 50 ]; then
        warn "conntrack 使用率 ${usage_pct}% — 高使用率增加延迟"
    fi
fi

# 是否加载了 nf_conntrack
if lsmod | grep -q nf_conntrack; then
    warn "nf_conntrack 模块已加载 — 连接跟踪对高吞吐场景有 per-packet 开销"
    echo "  如果不需要防火墙，考虑: iptables -t raw -A PREROUTING -j NOTRACK"
fi

###############################################################################
header "15. 快速带宽测试 (本地 loopback 基线)"
###############################################################################
echo "  跳过 loopback 测试 (需要手动执行 iperf 验证)"
echo "  建议在两台机器间执行单口测试确认基线:"
echo "    服务端: iperf -s -p 5001"
echo "    客户端: iperf -c <SERVER_IP> -p 5001 -P 8 -t 30 -w 4m -N"

###############################################################################
# 汇总
###############################################################################
header "诊断汇总"

if [ $WARN_COUNT -eq 0 ]; then
    echo -e "\n  ${GREEN}${BOLD}未发现明显系统级问题${NC}\n"
else
    echo -e "\n  ${RED}${BOLD}发现 $WARN_COUNT 个潜在问题:${NC}\n"
    idx=1
    for issue in "${ISSUE_LIST[@]}"; do
        echo -e "  ${RED}${idx}.${NC} $issue"
        idx=$((idx + 1))
    done
    
    echo ""
    echo -e "  ${BOLD}最常见的 100G 性能杀手排序:${NC}"
    echo "    1. IOMMU/VT-d 开启 (降低 20-40%)"
    echo "    2. PCIe 链路降级 (x4 代替 x8, 或 Gen3 代替 Gen4)"
    echo "    3. CPU C-State 深度睡眠 (中断唤醒延迟 50-200μs)"
    echo "    4. Spectre/Meltdown 缓解措施 (降低 5-15%)"
    echo "    5. NUMA 自动均衡 / 跨 NUMA 访问"
    echo "    6. irqbalance 覆盖手动绑核"
    echo "    7. nf_conntrack 连接跟踪开销"
    echo "    8. RPS 与硬件 RSS 冲突"
    echo "    9. NetworkManager 干扰网卡配置"
    echo "   10. tuned 配置非 throughput-performance"
fi

echo ""
echo -e "${CYAN}诊断完成。请将输出发给我分析。${NC}"
echo -e "${CYAN}导出命令: sudo bash network_diag.sh 2>&1 | tee /tmp/network_diag_$(date +%Y%m%d_%H%M%S).log${NC}"

