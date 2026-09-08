#!/bin/bash

# 网络性能测试脚本
# 功能：测试TCP/UDP吞吐量、响应时间，收集环境信息及系统日志。
# 依赖：netperf, netserver
# 用法：./network_perf_test.sh [目标IP] [测试时长(秒)]
#       IP未提供时跳过测试，仅收集环境信息

export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
RESULT_DIR="${SCRIPT_DIR}/network_test_${TIMESTAMP}"
LOG_FILE="${RESULT_DIR}/test_execution.log"

mkdir -p "${RESULT_DIR}"

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

log "=================================================="
log "开始执行网络性能测试"
log "结果目录: ${RESULT_DIR}"
log "=================================================="

# 0. 依赖检查（尽早退出，避免浪费时间采集环境信息后才发现依赖缺失）
log "[0/5] 检查依赖..."
MISSING_DEPS=()
if ! command -v netperf &> /dev/null; then
    MISSING_DEPS+=("netperf")
fi
if ! command -v netserver &> /dev/null; then
    # netserver 通常和 netperf 同包，但单独检查更明确
    MISSING_DEPS+=("netserver")
fi
if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    log "错误: 缺少依赖: ${MISSING_DEPS[*]}"
    log "请先安装: sudo apt install netperf  或  sudo yum install netperf"
    exit 1
fi
NETPERF_VER=$(netperf -V 2>&1 | head -1)
log "  netperf 版本: $NETPERF_VER"

# 1. 环境信息收集
log "[1/5] 收集环境信息..."
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
} > "${RESULT_DIR}/env_info.txt" 2>&1
log "  环境信息已保存至 env_info.txt"

# 2. 检查并启动 netserver
log "[2/5] 检查并启动 netserver..."
# 若本地已有 netserver 在监听则跳过
if ! ss -tlnp | grep -q ":12865"; then
    netserver -p 12865 >> "${LOG_FILE}" 2>&1
    sleep 1
    log "  netserver 已在端口 12865 启动"
else
    log "  netserver 已在监听端口 12865，跳过启动"
fi

# 3. 执行 netperf 测试
TARGET_IP="${1:-}"
TEST_DURATION=${2:-10}

if [ -z "$TARGET_IP" ]; then
    log "[3/5] 未提供目标IP，跳过netperf测试，仅保留环境信息"
    SKIP_TESTS=true
else
    SKIP_TESTS=false
    if [ "$TARGET_IP" = "127.0.0.1" ] || [ "$TARGET_IP" = "localhost" ]; then
        log "[3/5] 警告: 目标IP为回环地址，测试走虚拟网卡(lo)，不反映物理网卡性能"
    fi
    log "[3/5] 开始执行 netperf 测试 (目标: ${TARGET_IP}, 时长: ${TEST_DURATION}s)..."
    # 快速连通性探测
    if ! ping -c 1 -W 3 "$TARGET_IP" > /dev/null 2>&1; then
        log "  警告: 无法 ping 通 ${TARGET_IP}，netperf 测试可能会失败"
    fi
fi

run_netperf() {
    local desc="$1"
    local outfile="$2"
    shift 2
    log "  正在进行 ${desc} 测试..."
    if ! netperf "$@" > "${outfile}" 2>&1; then
        log "  错误: ${desc} 测试执行失败，请检查 ${outfile}"
    fi
}

if [ "$SKIP_TESTS" != true ]; then
    # TCP Stream 正向吞吐量
    run_netperf "TCP_STREAM (正向吞吐)" \
        "${RESULT_DIR}/tcp_stream.txt" \
        -H "${TARGET_IP}" -l "${TEST_DURATION}" -t TCP_STREAM -P 1 -- -m 1024

    # TCP Stream 反向吞吐量
    run_netperf "TCP_MAERTS (反向吞吐)" \
        "${RESULT_DIR}/tcp_maerts.txt" \
        -H "${TARGET_IP}" -l "${TEST_DURATION}" -t TCP_MAERTS -P 1 -- -m 1024

    # UDP Stream 吞吐量
    run_netperf "UDP_STREAM (UDP吞吐)" \
        "${RESULT_DIR}/udp_stream.txt" \
        -H "${TARGET_IP}" -l "${TEST_DURATION}" -t UDP_STREAM -P 1 -- -m 1024

    # TCP Request/Response 响应速率与延迟
    run_netperf "TCP_RR (TCP响应时间/速率)" \
        "${RESULT_DIR}/tcp_rr.txt" \
        -H "${TARGET_IP}" -l "${TEST_DURATION}" -t TCP_RR -P 1 -- -r 64,64

    # UDP Request/Response 响应速率与延迟
    run_netperf "UDP_RR (UDP响应时间/速率)" \
        "${RESULT_DIR}/udp_rr.txt" \
        -H "${TARGET_IP}" -l "${TEST_DURATION}" -t UDP_RR -P 1 -- -r 64,64
fi

# 4. 收集系统日志
log "[4/5] 收集系统日志..."
dmesg > "${RESULT_DIR}/dmesg.log" 2>&1
if [ -f /var/log/messages ]; then
    cp /var/log/messages "${RESULT_DIR}/messages.log"
    log "  已复制 /var/log/messages"
elif [ -f /var/log/syslog ]; then
    cp /var/log/syslog "${RESULT_DIR}/syslog.log"
    log "  已复制 /var/log/syslog"
else
    log "  警告: 未找到 /var/log/messages 或 /var/log/syslog"
fi

# 解析 netperf 输出的通用函数
# netperf -P 1 会输出表头，数据在表头下一行
parse_throughput() {
    # TCP/UDP STREAM: 最后一行数据，吞吐量在最后一列
    local file="$1"
    [ -f "${file}" ] || { echo "N/A (文件不存在)"; return; }
    local val
    val=$(awk 'NR>1 && /^[[:space:]]*[0-9]/' "${file}" | tail -n 1 | awk '{print $NF}')
    echo "${val:-N/A}"
}

parse_rr_trans() {
    # RR 测试: Trans/sec 在最后一列
    local file="$1"
    [ -f "${file}" ] || { echo "N/A (文件不存在)"; return; }
    local val
    val=$(awk '/^[[:space:]]*[0-9]/ && NF>=5' "${file}" | tail -n 1 | awk '{print $NF}')
    echo "${val:-N/A}"
}

parse_rr_latency() {
    # RR 测试: Mean Latency (us) 通常在 Trans/sec 前一列
    local file="$1"
    [ -f "${file}" ] || { echo "N/A (文件不存在)"; return; }
    local val
    # 取数据行，字段数>=6时，倒数第二列为平均延迟
    val=$(awk '/^[[:space:]]*[0-9]/ && NF>=6' "${file}" | tail -n 1 | awk '{print $(NF-1)}')
    echo "${val:-N/A}"
}

# 5. 生成详细报告
log "[5/5] 生成测试报告..."
REPORT="${RESULT_DIR}/test_report.txt"
{
    echo "=================================================="
    echo "            网络性能测试报告                      "
    echo "=================================================="
    echo "测试时间   : $(date)"
    echo "测试目标IP : ${TARGET_IP:-N/A (未执行测试)}"
    echo "单项测试时长: ${TEST_DURATION} 秒"
    echo ""
    echo "--- 环境摘要 ---"
    echo "主机名     : $(hostname)"
    echo "内核版本   : $(uname -r)"
    echo "OS         : $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"')"
    echo "CPU        : $(lscpu | grep 'Model name' | awk -F: '{print $2}' | xargs)"
    echo "CPU核心数  : $(nproc)"
    echo "总内存     : $(free -h | awk '/Mem:/{print $2}')"
    echo "网卡 (PCI) : $(lspci | grep -i ether | head -n 1)"
    echo ""

    if [ "$SKIP_TESTS" != true ]; then
        echo "=================================================="
        echo "                性能测试结果                      "
        echo "=================================================="
        echo ""
        echo "[ 吞吐量测试 ]"
        echo "  1. TCP 正向吞吐量 (TCP_STREAM)  : $(parse_throughput "${RESULT_DIR}/tcp_stream.txt") Mbps"
        echo "  2. TCP 反向吞吐量 (TCP_MAERTS)  : $(parse_throughput "${RESULT_DIR}/tcp_maerts.txt") Mbps"
        echo "  3. UDP 吞吐量     (UDP_STREAM)  : $(parse_throughput "${RESULT_DIR}/udp_stream.txt") Mbps"
        echo ""
        echo "[ 响应时间 / 传输速率测试 (请求包大小 64B) ]"
        echo "  4. TCP 响应速率  (TCP_RR)       : $(parse_rr_trans "${RESULT_DIR}/tcp_rr.txt") Trans/sec"
        echo "     TCP 平均延迟  (TCP_RR)       : $(parse_rr_latency "${RESULT_DIR}/tcp_rr.txt") us"
        echo "  5. UDP 响应速率  (UDP_RR)       : $(parse_rr_trans "${RESULT_DIR}/udp_rr.txt") Trans/sec"
        echo "     UDP 平均延迟  (UDP_RR)       : $(parse_rr_latency "${RESULT_DIR}/udp_rr.txt") us"
    else
        echo "性能测试: 跳过 (未提供目标IP)"
    fi
    echo ""
    echo "=================================================="
    echo "原始数据文件列表:"
    echo "  env_info.txt      - 系统及网卡环境信息"
    echo "  tcp_stream.txt    - TCP_STREAM 原始输出"
    echo "  tcp_maerts.txt    - TCP_MAERTS 原始输出"
    echo "  udp_stream.txt    - UDP_STREAM 原始输出"
    echo "  tcp_rr.txt        - TCP_RR 原始输出"
    echo "  udp_rr.txt        - UDP_RR 原始输出"
    echo "  dmesg.log         - 内核环形缓冲区日志"
    echo "  test_execution.log- 测试执行日志"
    echo "结果目录: ${RESULT_DIR}"
    echo "=================================================="
} > "${REPORT}"

# 同步报告内容到执行日志
cat "${REPORT}" >> "${LOG_FILE}"

# 清理 netserver (仅本地测试时停止)
if [ "$TARGET_IP" = "127.0.0.1" ] || [ "$TARGET_IP" = "localhost" ]; then
    pkill -x netserver > /dev/null 2>&1 || true
    log "  已停止本地 netserver"
fi

log "测试完成！结果目录: ${RESULT_DIR}"
