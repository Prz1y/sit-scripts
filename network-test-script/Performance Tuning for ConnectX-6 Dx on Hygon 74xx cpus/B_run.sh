#!/bin/bash
# 71机 (客户端) — IRQ绑核 + IP配置 + iperf测试
# 网卡: ens2f0np0 / ens2f1np1, NIC NUMA: 0, APP NUMA: 自动检测最近邻

set -euo pipefail
NIC1=ens2f0np0
NIC2=ens2f1np1

# ---------- 自动获取 NUMA 信息 ----------
NIC_NUMA=$(cat "/sys/class/net/${NIC1}/device/numa_node")
echo "NIC NUMA 节点: $NIC_NUMA"

# 获取该 NUMA 的 CPU 列表
read -r -a CPUS_ALL <<< "$(numactl -H | grep "node $NIC_NUMA cpus:" | sed 's/.*cpus: //')"
echo "NUMA $NIC_NUMA CPU 列表: ${CPUS_ALL[*]}"
TOTAL=${#CPUS_ALL[@]}
HALF=$((TOTAL / 2))

# NIC1 用前半, NIC2 用后半
CPUS_NIC1=("${CPUS_ALL[@]:0:$HALF}")
CPUS_NIC2=("${CPUS_ALL[@]:$HALF}")
echo "NIC1 ($NIC1) IRQ 绑核 CPU: ${CPUS_NIC1[*]}"
echo "NIC2 ($NIC2) IRQ 绑核 CPU: ${CPUS_NIC2[*]}"

# ★ 跳过最近邻 NUMA (共享 die, 与 IRQ 争抢内存总线), 用第 2、3 近的
read APP_NUMA1 APP_NUMA2 <<< "$(numactl -H | awk "/^ *${NIC_NUMA}:/{print}" | awk '{
    for(i=2;i<=NF;i++){node=i-2; if(node!='"$NIC_NUMA"'){d[node]=$i}}
    b1=-1;b1d=99999; b2=-1;b2d=99999; b3=-1;b3d=99999;
    for(node in d){
        if(d[node]+0<b1d+0){b3=b2;b3d=b2d;b2=b1;b2d=b1d;b1=node;b1d=d[node]}
        else if(d[node]+0<b2d+0){b3=b2;b3d=b2d;b2=node;b2d=d[node]}
        else if(d[node]+0<b3d+0){b3=node;b3d=d[node]}
    }
    print b2, b3}')"
echo "Pair1 iperf -> NUMA $APP_NUMA1 | Pair2 iperf -> NUMA $APP_NUMA2 (跳过最近邻, 避免 die 争抢)"

# ---------- IRQ 绑核 ----------
echo ""
echo "===== IRQ 绑核 ====="

# NIC1
PCI=$(basename "$(readlink -f "/sys/class/net/${NIC1}/device")")
i=0
for irq in $(grep "mlx5_comp.*$PCI" /proc/interrupts | awk -F: '{print $1}' | tr -d ' '); do
    echo ${CPUS_NIC1[$((i % ${#CPUS_NIC1[@]}))]} > /proc/irq/$irq/smp_affinity_list
    i=$((i+1))
done
echo "NIC1 ($NIC1) 绑核完成: $i 个中断 -> CPU ${CPUS_NIC1[*]}"

# NIC2
PCI=$(basename "$(readlink -f "/sys/class/net/${NIC2}/device")")
i=0
for irq in $(grep "mlx5_comp.*$PCI" /proc/interrupts | awk -F: '{print $1}' | tr -d ' '); do
    echo ${CPUS_NIC2[$((i % ${#CPUS_NIC2[@]}))]} > /proc/irq/$irq/smp_affinity_list
    i=$((i+1))
done
echo "NIC2 ($NIC2) 绑核完成: $i 个中断 -> CPU ${CPUS_NIC2[*]}"

# ---------- IP 配置 ----------
echo ""
echo "===== 配置 IP (客户端 .1) ====="
ip addr flush dev "$NIC1" 2>/dev/null || true
ip addr add 192.168.100.1/24 dev "$NIC1"
ip link set "$NIC1" up

ip addr flush dev "$NIC2" 2>/dev/null || true
ip addr add 192.168.110.1/24 dev "$NIC2"
ip link set "$NIC2" up

echo "$NIC1: $(ip -4 addr show "$NIC1" | grep inet | awk '{print $2}')"
echo "$NIC2: $(ip -4 addr show "$NIC2" | grep inet | awk '{print $2}')"

# ---------- 路由初始窗口 + busy_poll ----------
ip route change 192.168.100.0/24 dev "$NIC1" initcwnd 128 initrwnd 128 2>/dev/null || \
  ip route add 192.168.100.0/24 dev "$NIC1" initcwnd 128 initrwnd 128 2>/dev/null || true
ip route change 192.168.110.0/24 dev "$NIC2" initcwnd 128 initrwnd 128 2>/dev/null || \
  ip route add 192.168.110.0/24 dev "$NIC2" initcwnd 128 initrwnd 128 2>/dev/null || true
echo "路由 initcwnd/initrwnd=128 已设置"

sysctl -w net.core.busy_read=100  >/dev/null 2>&1
sysctl -w net.core.busy_poll=100  >/dev/null 2>&1
echo "busy_poll=100 已设置"

# ---------- 防火墙 ----------
firewall-cmd --zone=public --add-port=5001-5016/tcp --permanent 2>/dev/null || true
firewall-cmd --zone=public --add-port=6001-6016/tcp --permanent 2>/dev/null || true
firewall-cmd --reload 2>/dev/null || true

# ---------- 连通性检查 ----------
echo ""
echo "===== 连通性检查 ====="
ping -c 2 -W 2 192.168.100.2 && echo "Pair1 OK" || echo "Pair1 不通!"
ping -c 2 -W 2 192.168.110.2 && echo "Pair2 OK" || echo "Pair2 不通!"

# ---------- iperf 客户端 ----------
echo ""
read -p "连通性OK? 开始测试? (y/N): " ans
if [[ ! "$ans" =~ ^[yY] ]]; then
    echo "已取消"; exit 0
fi

read -p "测试时长(秒) [默认60]: " dur
dur=${dur:-60}

pkill -x iperf 2>/dev/null || true
sleep 1

echo ""
echo "===== 启动 iperf 客户端 (-P 14, ${dur}s) ====="
echo "Pair1 -> NUMA $APP_NUMA1 | Pair2 -> NUMA $APP_NUMA2"

numactl --cpunodebind=$APP_NUMA1 --membind=$APP_NUMA1 \
    iperf -c 192.168.100.2 -p 5001 -P 14 -t $dur -i 5 -w 4m -l 1M -N \
    > /tmp/pair1_result.log 2>&1 &
P1=$!

numactl --cpunodebind=$APP_NUMA2 --membind=$APP_NUMA2 \
    iperf -c 192.168.110.2 -p 6001 -P 14 -t $dur -i 5 -w 4m -l 1M -N \
    > /tmp/pair2_result.log 2>&1 &
P2=$!

echo "Pair1 PID=$P1, Pair2 PID=$P2"
echo "等待 ${dur} 秒..."
wait "$P1" "$P2"

echo ""
echo "===== 测试结果 ====="
echo "--- Pair1 ($NIC1 -> 192.168.100.2) ---"
grep '\[SUM\]' /tmp/pair1_result.log | tail -1
echo "--- Pair2 ($NIC2 -> 192.168.110.2) ---"
grep '\[SUM\]' /tmp/pair2_result.log | tail -1
echo ""
echo "完整日志: /tmp/pair1_result.log, /tmp/pair2_result.log"
