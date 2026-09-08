#!/bin/bash
# ============================================================
# LTP 服务器全负载压力测试脚本
# 用途：通过 LTP 对服务器进行 CPU/内存/IO/网络综合压力测试
#       CPU 目标占用 ~100%，内存目标占用 ~95%
# WARNING: This script clears kernel/journal logs, removes prior stress logs in
# /tmp, and drives the host to sustained high utilization. Run it only on RD/lab machines.
# ============================================================

echo "WARNING: ltp_stress_server.sh will clear logs, remove old /tmp stress artifacts, and push the host to sustained high load." >&2

# -------- 基础配置 --------
LTPROOT="/opt/ltp"
LOGDIR="/tmp/ltp_stress_$(date +%Y%m%d_%H%M%S)"
DURATION="24h"          # 测试时长，可改为 48h / 72h
ENABLE_NETWORK=false    # 是否启用网络测试（需要特定网络配置）
CPU_BURNER_PIDS=()      # 额外 CPU 占满进程的 PID 列表
MEM_STRESS_PIDS=()      # 独立内存压力进程的 PID 列表
TIMER_PID=""            # 后台定时器 PID

# -------- 时长字符串转换为秒 --------
duration_to_secs() {
    local d="$1"
    local num="${d%[hHmMsS]}"
    local unit="${d: -1}"
    case "$unit" in
        h|H) echo $(( num * 3600 )) ;;
        m|M) echo $(( num * 60 ))   ;;
        s|S) echo "$num"            ;;
        *)   echo "$d"              ;;  # 无单位视为秒
    esac
}
DURATION_SECS=$(duration_to_secs "$DURATION")

# -------- 获取系统信息 --------
CPU_COUNT=$(nproc)
# Use portable memory/disk detection (not GNU-only free -g / df -BG)
MEM_GB=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || awk '/^MemTotal:/ {printf "%d", $2/1048576}' /proc/meminfo)
DISK_FREE_GB=$(df /tmp --output=avail -BG 2>/dev/null | tail -1 | tr -d 'G' || \
    awk '/\/tmp/ {printf "%d", $4/1024/1024}' /proc/mounts)

echo "========================================"
echo " LTP 服务器全负载压力测试"
echo "========================================"
echo " 系统信息："
echo "   CPU 核心数   : $CPU_COUNT"
echo "   内存总量     : ${MEM_GB} GB"
echo "   /tmp 可用空间: ${DISK_FREE_GB} GB"
echo "   测试时长     : $DURATION  (${DURATION_SECS}s)"
echo "   日志目录     : $LOGDIR"
echo "========================================"

# -------- 检查 LTP 是否存在 --------
if [ ! -f "$LTPROOT/runltp" ]; then
    echo "[ERROR] 未找到 LTP，请确认安装路径: $LTPROOT"
    exit 1
fi

# ============================================================
# 函数定义
# ============================================================

# -------- 跑前清理旧日志 --------
cleanup_logs() {
    echo ""
    echo "[PRE] ===== 清理旧日志与系统缓冲 ====="

    local old_count
    old_count=$(find /tmp -maxdepth 1 -name "ltp_stress_*" -type d 2>/dev/null | wc -l)
    if [ "$old_count" -gt 0 ]; then
        find /tmp -maxdepth 1 -name "ltp_stress_*" -type d -exec rm -rf {} + 2>/dev/null
        echo "[PRE] 已删除 ${old_count} 个旧 LTP 日志目录"
    else
        echo "[PRE] 无旧 LTP 日志目录"
    fi

    # 清除 dmesg 缓冲区（需要 root）
    if dmesg -C 2>/dev/null; then
        echo "[PRE] dmesg 缓冲区已清除"
    else
        echo "[PRE][WARN] dmesg -C 失败（建议以 root 运行）"
    fi

    # 轮转 journal，减少历史噪音
    if command -v journalctl &>/dev/null; then
        journalctl --rotate 2>/dev/null
        journalctl --vacuum-time=1s 2>/dev/null
        echo "[PRE] journal 日志已轮转清理"
    fi

    echo "[PRE] ===== 清理完成 ====="
}

# -------- 启动额外 CPU 占满进程，确保 100% --------
start_cpu_burners() {
    echo "[INFO] 启动 ${CPU_COUNT} 个 CPU 占满进程（sha256sum /dev/zero）..."
    for (( i=0; i<CPU_COUNT; i++ )); do
        sha256sum /dev/zero &>/dev/null &
        CPU_BURNER_PIDS+=($!)
    done
    echo "[INFO] CPU 占满进程已启动，PID 列表: ${CPU_BURNER_PIDS[*]}"
}

# -------- 停止额外 CPU 占满进程 --------
stop_cpu_burners() {
    if [ ${#CPU_BURNER_PIDS[@]} -gt 0 ]; then
        echo "[INFO] 停止 CPU 占满进程..."
        kill "${CPU_BURNER_PIDS[@]}" 2>/dev/null
        CPU_BURNER_PIDS=()
    fi
}

# -------- 启动独立内存压力进程，强制 touch 物理页确保 ~95% 占用 --------
# 原因：runltp -m 依赖 genload --mem，其内部 malloc 不触摸页面，
#       OS 延迟分配导致物理内存实际不占用，故改用外部工具。
start_mem_stress() {
    echo "[INFO] 启动内存压力进程（${MEM_PROCS} 进程 × ${MEM_PER_PROC} MB，目标 ~95% 物理内存）..."
    if command -v stress-ng &>/dev/null; then
        # --vm-keep: 保持 mmap 映射不释放；每个 worker 持续写入所有页面
        stress-ng --vm "$MEM_PROCS" --vm-bytes "${MEM_PER_PROC}M" \
            --vm-keep &>/dev/null &
        MEM_STRESS_PIDS+=($!)
        echo "[INFO] stress-ng 内存压力已启动 (PID: ${MEM_STRESS_PIDS[-1]})"
    elif command -v python3 &>/dev/null; then
        # Python fallback：bytearray 逐页写入，强制内核提交物理页
        for (( _mi=0; _mi<MEM_PROCS; _mi++ )); do
            python3 -c "
import time
size = ${MEM_PER_PROC} * 1024 * 1024
buf = bytearray(size)
for j in range(0, size, 4096):
    buf[j] = 0x55
while True:
    time.sleep(3600)
" &>/dev/null &
            MEM_STRESS_PIDS+=($!)
        done
        echo "[INFO] Python 内存压力已启动 (${MEM_PROCS} 进程 × ${MEM_PER_PROC} MB)"
    else
        echo "[WARN] 未找到 stress-ng 或 python3，内存压力将不足，建议安装 stress-ng"
    fi
}

# -------- 停止内存压力进程 --------
stop_mem_stress() {
    if [ ${#MEM_STRESS_PIDS[@]} -gt 0 ]; then
        echo "[INFO] 停止内存压力进程..."
        kill "${MEM_STRESS_PIDS[@]}" 2>/dev/null
        MEM_STRESS_PIDS=()
    fi
}

# -------- 后台定时器：每 30s 刷新进度 --------
show_timer() {
    local start=$1
    local total=$2
    while true; do
        local now elapsed remaining pct h_e m_e s_e h_r m_r s_r
        now=$(date +%s)
        elapsed=$(( now - start ))
        remaining=$(( total - elapsed ))
        [ "$remaining" -le 0 ] && break
        pct=$(( elapsed * 100 / total ))
        h_e=$(( elapsed / 3600 ));  m_e=$(( elapsed % 3600 / 60 ));  s_e=$(( elapsed % 60 ))
        h_r=$(( remaining / 3600 )); m_r=$(( remaining % 3600 / 60 )); s_r=$(( remaining % 60 ))
        printf "\r[进度] 已运行: %02d:%02d:%02d | 剩余: %02d:%02d:%02d | 完成: %3d%%" \
            "$h_e" "$m_e" "$s_e" "$h_r" "$m_r" "$s_r" "$pct"
        sleep 30
    done
    echo ""
}

# -------- 跑完收集系统日志 --------
collect_system_logs() {
    echo ""
    echo "[POST] ===== 收集系统日志到 $LOGDIR ====="

    # dmesg（测试期间内核日志）
    dmesg > "$LOGDIR/dmesg_after.log" 2>/dev/null
    echo "[POST] dmesg → dmesg_after.log"

    # journalctl（测试时段）
    if command -v journalctl &>/dev/null; then
        journalctl -b --no-pager --since "@${START_TIME}" \
            > "$LOGDIR/journalctl_test_period.log" 2>/dev/null
        echo "[POST] journalctl → journalctl_test_period.log"
    fi

    # /var/log/messages 或 syslog（按发行版复制）
    [ -f /var/log/messages ] && cp /var/log/messages "$LOGDIR/messages.log" 2>/dev/null \
        && echo "[POST] /var/log/messages → messages.log"
    [ -f /var/log/syslog ] && cp /var/log/syslog "$LOGDIR/syslog.log" 2>/dev/null \
        && echo "[POST] /var/log/syslog   → syslog.log"

    # 系统状态快照
    {
        echo "=== lscpu ==="
        lscpu
        echo ""
        echo "=== free -h ==="
        free -h
        echo ""
        echo "=== df -h ==="
        df -h
        echo ""
        echo "=== ps aux (top 30 by CPU) ==="
        ps aux --sort=-%cpu | head -31
        echo ""
        echo "=== vmstat -s ==="
        vmstat -s 2>/dev/null
        echo ""
        echo "=== last reboot ==="
        last reboot | head -5
    } > "$LOGDIR/system_snapshot.log" 2>/dev/null
    echo "[POST] 系统快照 → system_snapshot.log"

    echo "[POST] ===== 日志收集完成 ====="
}

# -------- Ctrl+C 信号处理 --------
on_interrupt() {
    echo ""
    echo "[WARN] 收到中断信号，正在清理并收集日志..."
    stop_cpu_burners
    stop_mem_stress
    [ -n "$TIMER_PID" ] && kill "$TIMER_PID" 2>/dev/null
    collect_system_logs
    exit 130
}
trap on_interrupt INT TERM

# ============================================================
# 跑前清理（在 mkdir LOGDIR 之前，避免把新目录也删掉）
# ============================================================
cleanup_logs
mkdir -p "$LOGDIR"

# -------- 计算负载参数 --------
# CPU：每个物理核各一个 LTP hackbench 进程 + 额外 sha256sum 占满
CPU_PROCS=$CPU_COUNT

# IO Bus 负载进程数 = 核心数一半，最少 2
IO_PROCS=$(( CPU_COUNT / 2 ))
[ "$IO_PROCS" -lt 2 ] && IO_PROCS=2

# 内存负载：目标占用 ~95%，进程数=核心数一半，单位 MB（runltp -m 要求纯整数）
MEM_PROCS=$(( CPU_COUNT / 2 ))
[ "$MEM_PROCS" -lt 2 ] && MEM_PROCS=2
MEM_PER_PROC=$(( MEM_GB * 1024 * 95 / 100 / MEM_PROCS ))
[ "$MEM_PER_PROC" -lt 1 ] && MEM_PER_PROC=1

# 磁盘 IO 负载：进程数=核心数一半，使用最多 50% 可用空间，单位 MB（runltp -D 要求纯整数）
DISK_PROCS=$(( CPU_COUNT / 2 ))
[ "$DISK_PROCS" -lt 2 ] && DISK_PROCS=2
DISK_PER_PROC=$(( DISK_FREE_GB * 1024 * 50 / 100 / DISK_PROCS ))
[ "$DISK_PER_PROC" -lt 1 ] && DISK_PER_PROC=1

echo ""
echo " 负载参数："
echo "   -c $CPU_PROCS           (CPU 负载进程数，另有 ${CPU_COUNT} 个 sha256sum 确保 100%)"
echo "   -i $IO_PROCS             (IO Bus 负载进程数)"
echo "   内存压力            : stress-ng/python3 独立运行 (${MEM_PROCS} × ${MEM_PER_PROC} MB ≈ 95%)"
echo "   -D $DISK_PROCS,10,${DISK_PER_PROC},1   (磁盘 IO 负载，每进程 ${DISK_PER_PROC} MB)"
echo "========================================"
echo ""

# -------- 构造运行命令 --------
LOGFILE="$LOGDIR/result.log"
OUTFILE="$LOGDIR/output.txt"
FAILFILE="$LOGDIR/failed.txt"

CMD="$LTPROOT/runltp \
  -c $CPU_PROCS \
  -i $IO_PROCS \
  -D ${DISK_PROCS},10,${DISK_PER_PROC},1 \
  -t $DURATION \
  -p \
  -q \
  -R \
  -l $LOGFILE \
  -o $OUTFILE \
  -C $FAILFILE \
  -d $LOGDIR"

# 可选：追加网络测试
if [ "$ENABLE_NETWORK" = true ]; then
    CMD="$CMD -N"
fi

echo "[INFO] 开始运行 LTP 全负载压力测试..."
echo "[INFO] 实时监控命令："
echo "       tail -f $OUTFILE"
echo "       watch -n 2 'top -bn1 | head -20'"
echo ""

# -------- 记录测试开始时间 --------
START_TIME=$(date +%s)
{
    echo "START_TIME=$(date)"
    echo "DURATION=$DURATION  (${DURATION_SECS}s)"
    echo "CPU_COUNT=$CPU_COUNT"
    echo "MEM_GB=$MEM_GB"
    echo "MEM_TARGET=95%  TOOL=stress-ng/python3  ${MEM_PROCS} procs x ${MEM_PER_PROC}MB"
    echo "CMD=$CMD"
} > "$LOGDIR/test_info.txt"

# -------- 启动 CPU 占满进程 --------
start_cpu_burners

# -------- 启动独立内存压力进程 --------
start_mem_stress

# -------- 启动后台定时器 --------
show_timer "$START_TIME" "$DURATION_SECS" &
TIMER_PID=$!

# -------- 执行测试 --------
eval "$CMD"
EXIT_CODE=$?

# -------- 停止辅助进程 --------
stop_cpu_burners
stop_mem_stress
kill "$TIMER_PID" 2>/dev/null
wait "$TIMER_PID" 2>/dev/null
echo ""

# -------- 记录结果 --------
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
{
    echo "END_TIME=$(date)"
    echo "ELAPSED=${ELAPSED}s  ($(( ELAPSED/3600 ))h $(( ELAPSED%3600/60 ))m $(( ELAPSED%60 ))s)"
    echo "EXIT_CODE=$EXIT_CODE"
} >> "$LOGDIR/test_info.txt"

# -------- 收集系统日志 --------
collect_system_logs

echo ""
echo "========================================"
echo " 测试完成"
echo "   总耗时  : $(( ELAPSED/3600 ))h $(( ELAPSED%3600/60 ))m $(( ELAPSED%60 ))s"
echo "   结果日志: $LOGFILE"
echo "   失败用例: $FAILFILE"
echo "   系统日志: $LOGDIR"
echo "========================================"

# -------- 输出失败摘要 --------
if [ -f "$FAILFILE" ] && [ -s "$FAILFILE" ]; then
    FAIL_COUNT=$(wc -l < "$FAILFILE")
    echo ""
    echo "[WARNING] 共 ${FAIL_COUNT} 个失败用例："
    cat "$FAILFILE"
else
    echo "[OK] 无失败用例"
fi

exit $EXIT_CODE
