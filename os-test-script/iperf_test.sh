#!/bin/bash

# 获取脚本所在目录
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 用户配置（直接修改这里）
SERVER_IP="${1:-}"                  # 必填: 服务端IP地址，回环地址(127.0.0.1)走内核虚拟网卡，不测物理网卡
DURATION=14400
IPERF_FORMAT="m"              # iperf -f 单位: m=Mbps, g=Gbps; 高速网卡(>=10Gbps)建议 g

# 参数校验
if [ -z "$SERVER_IP" ]; then
    echo "错误: 请指定服务器IP"
    echo "用法: bash $0 <server_ip>"
    echo "注意: 127.0.0.1 为回环接口，测试结果不反映物理网卡性能"
    exit 1
fi

if [ "$SERVER_IP" = "127.0.0.1" ] || [ "$SERVER_IP" = "localhost" ]; then
    echo "警告: SERVER_IP=$SERVER_IP 为回环接口"
    echo "测试走内核虚拟网卡(lo)，吞吐量反映CPU/内存上限，非物理网卡性能"
    echo ""
    read -p "确认继续？(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "已取消"
        exit 1
    fi
fi

# 日志文件
RESULT_DIR="$SCRIPT_DIR/iperf_test_${TIMESTAMP}"
REPORT_FILE="$RESULT_DIR/test_execution.log"
ENV_INFO="$RESULT_DIR/env_info.txt"
DMESG_LOG="$RESULT_DIR/dmesg.log"
MESSAGE_LOG="$RESULT_DIR/message.log"
BMC_LOG="$RESULT_DIR/bmc.log"
IPERF_RAW="$RESULT_DIR/iperf_raw.log"

mkdir -p "$RESULT_DIR"

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${REPORT_FILE}"
}

log "=================================================="
log "开始执行 iPerf 测试"
log "服务器: ${SERVER_IP}, 时长: ${DURATION}s, 单位: ${IPERF_FORMAT}"
log "结果目录: ${RESULT_DIR}"
log "=================================================="

# 1. 检查 iperf（先检查依赖，失败时尽早退出，避免浪费时间采集环境信息）
log "[1/5] 检查 iPerf..."
if ! command -v iperf &> /dev/null; then
    log "错误: 未找到 iperf 命令，请先安装 (例如: sudo apt install iperf)"
    exit 1
fi
IPERF_VER=$(iperf --version 2>&1 | head -1)
log "  iPerf 版本: $IPERF_VER"

# 2. 环境信息收集
log "[2/5] 收集环境信息..."
{
    echo "===== 系统基本信息 ====="
    uname -a
    echo ""
    echo "--- 内核版本 ---"
    uname -r
    echo ""
    echo "--- OS Release ---"
    [ -f /etc/os-release ] && cat /etc/os-release
    echo ""
    echo "===== CPU 信息 ====="
    lscpu
    echo ""
    echo "===== 内存信息 ====="
    free -h
    echo ""
    echo "===== 网络接口详情 ====="
    ip addr
    echo ""
    echo "===== 网络接口统计 ====="
    ip -s link
    echo ""
    echo "===== 网卡硬件信息 (PCI) ====="
    lspci | grep -i ether
    echo ""
    echo "===== 网卡驱动信息 ====="
    for iface in $(ip -o link show | awk -F': ' '{print $2}' | awk -F'@' '{print $1}' | grep -v lo); do
        echo "--- ${iface} ---"
        ethtool "${iface}" 2>/dev/null || echo "  (ethtool 不可用或无此接口信息)"
        ethtool -i "${iface}" 2>/dev/null
    done
    echo ""
    echo "===== 路由表 ====="
    ip route
} > "$ENV_INFO" 2>&1
log "  环境信息已保存至 env_info.txt"

# 3. 检查并启动 iperf 服务端（仅本地回环测试时自动启动）
log "[3/5] 检查 iperf 服务端..."
IPERF_SERVER_PID=""
if [ "$SERVER_IP" = "127.0.0.1" ] || [ "$SERVER_IP" = "localhost" ]; then
    if ! ss -tlnp | grep -q ":5001"; then
        iperf -s >> "${REPORT_FILE}" 2>&1 &
        IPERF_SERVER_PID=$!
        sleep 1
        log "  iperf 服务端已在端口 5001 后台启动 (PID: $IPERF_SERVER_PID)"
    else
        log "  iperf 服务端已在监听端口 5001，跳过启动"
    fi
else
    log "  远程服务器模式，请确认 ${SERVER_IP}:5001 上 iperf -s 已启动"
fi

# 4. 执行 iPerf 测试
# 参数说明：-c 客户端模式  -t 测试时长  -i 1 每秒输出一次报告  -f 单位
log "[4/5] 开始执行 iPerf 测试 (服务器: ${SERVER_IP}, 时长: ${DURATION}s)..."
IPERF_EXIT=0
iperf -c "$SERVER_IP" -t "$DURATION" -i 1 -f "$IPERF_FORMAT" > "$IPERF_RAW" 2>&1 || IPERF_EXIT=$?
if [ "$IPERF_EXIT" -ne 0 ]; then
    log "错误: iPerf 测试执行失败 (退出码: $IPERF_EXIT)，请检查 $IPERF_RAW"
fi

# 停止本地 iperf 服务端（仅本脚本自行启动的情况）
if [ -n "$IPERF_SERVER_PID" ] && kill -0 "$IPERF_SERVER_PID" 2>/dev/null; then
    kill "$IPERF_SERVER_PID" 2>/dev/null
    wait "$IPERF_SERVER_PID" 2>/dev/null
    log "  已停止本地 iperf 服务端 (PID: $IPERF_SERVER_PID)"
fi

# 5. 收集系统日志
log "[5/5] 收集系统日志..."
dmesg > "$DMESG_LOG" 2>&1
if [ -f /var/log/messages ]; then
    cp /var/log/messages "$MESSAGE_LOG"
    log "  已复制 /var/log/messages"
elif [ -f /var/log/syslog ]; then
    cp /var/log/syslog "$MESSAGE_LOG"
    log "  已复制 /var/log/syslog"
else
    log "  警告: 未找到 /var/log/messages 或 /var/log/syslog"
fi

if command -v ipmitool >/dev/null 2>&1; then
    ipmitool sel elist > "$BMC_LOG" 2>&1 || log "  警告: ipmitool sel elist 执行失败"
else
    log "  警告: 未安装 ipmitool，跳过 BMC 日志收集"
fi

{
    echo ""
    echo "=================================================="
    echo "测试完成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "结果目录: ${RESULT_DIR}"
    echo "输出文件："
    echo "  - env_info.txt       - 系统及网卡环境信息"
    echo "  - iperf_raw.log      - iPerf 原始输出"
    echo "  - dmesg.log          - 内核环形缓冲区日志"
    echo "  - message.log        - 系统日志"
    echo "  - bmc.log            - BMC 事件日志"
    echo "  - test_execution.log - 测试执行日志"
    echo "=================================================="
} >> "$REPORT_FILE" 2>&1

log "测试已完成"
log "所有结果已保存至: $RESULT_DIR"
chmod -R a+rX "$RESULT_DIR"
