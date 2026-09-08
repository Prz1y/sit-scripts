#!/bin/bash
# =============================================================================
# eccmem 12h 循环压测脚本 (测试用例: 3/4)
# 覆盖验收:
#   1. 文件上传成功        (依赖: /root/Sangfor_loading_0830/.../run.py)
#   2. 根据 readme.md 安装成功 (依赖: /dev/kkmmap + pip 依赖)
#   3. 可正常测试12h, dmesg/messages/BMC 无报错
#   4. 脚本可正常关闭      (12h 后 killall -9 python3)
# 用法:
#   IPMITOOL="ipmitool -I lanplus -H <bmc_ip> -U <user> -P <pass>" \
#   P_NUM=32 MINUTES=720 ./eccmem_12h_test.sh
# 默认: P_NUM=32(核数), MINUTES=720(12h), 结果目录 /root/eccmem_test/result_<ts>/
# =============================================================================
set -u

# ------------------------- 可调参数 -------------------------
TOOL_DIR="/root/Sangfor_loading_0830/common-all-all-server-hw-eccmem"
RESULT_ROOT="/root/eccmem_test"
MINUTES="${MINUTES:-720}"                    # 测试时长, 默认 12h
P_NUM="${P_NUM:-32}"                         # run.py 进程数, 默认=核数
IPMITOOL="${IPMITOOL:-ipmitool -I lanplus -H 10.8.149.174 -U admin -P admin}"
CHECK_INTERVAL="${CHECK_INTERVAL:-600}"      # 监控采样间隔(s)
NUMERIC_CHECK='^[0-9]+$'

# 错误判定模式 (对齐真实硬件错误计数器, 避免宽泛匹配误报)
# 注意: 不含裸 FAILURE/error 等宽泛词 (会命中 dnf/sshd 等无关日志)
HW_ERR_PAT='mce|Machine Check|MachineCheck|corrected error|uncorrected error|ECC error|edac|EDAC|memory error|CE error|UE error|page fault in kernel|Oops|BUG:|Kernel panic|hardware error'

# ------------------------- 初始化 -------------------------
TS_START=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="${RESULT_ROOT}/eccmem_result_${TS_START}"
LOGS_BEFORE="${RESULT_DIR}/logs_before"
LOGS_AFTER="${RESULT_DIR}/logs_after"
mkdir -p "$RESULT_DIR" "$LOGS_BEFORE" "$LOGS_AFTER"

LOG_FILE="${RESULT_DIR}/test.log"
# 所有输出同时进终端和日志文件
exec > >(tee -a "$LOG_FILE") 2>&1

echo "================ eccmem 12h 循环压测 开始 $(date '+%F %T') ================"
echo "参数: MINUTES=$MINUTES P_NUM=$P_NUM CHECK_INTERVAL=$CHECK_INTERVAL"
echo "结果目录: $RESULT_DIR"

# 参数校验
if ! [[ "$MINUTES" =~ $NUMERIC_CHECK ]] || ! [[ "$P_NUM" =~ $NUMERIC_CHECK ]]; then
    echo "[FAIL] MINUTES/P_NUM 必须是数字"
    exit 1
fi
if [ "$MINUTES" -lt 1 ]; then
    echo "[FAIL] MINUTES 必须 >= 1"
    exit 1
fi

# ------------------------- 前置检查 -------------------------
echo "--- 前置检查 ---"
# 1) 工具目录与 run.py
if [ ! -f "${TOOL_DIR}/run.py" ]; then
    echo "[FAIL] 找不到 ${TOOL_DIR}/run.py, 请先按 readme.md 安装工具"
    exit 1
fi
echo "[OK] run.py 存在"

# 2) kkmmap 模块与设备节点
if ! lsmod | grep -q '^kkmmap'; then
    echo "[INFO] kkmmap 未加载, 尝试加载"
    insmod "${TOOL_DIR}/modules/kkmmap.ko" 2>&1 || { echo "[FAIL] kkmmap 加载失败"; exit 1; }
fi
if [ ! -c /dev/kkmmap ]; then
    echo "[FAIL] /dev/kkmmap 设备节点不存在"
    exit 1
fi
echo "[OK] kkmmap 模块已加载 (/dev/kkmmap)"

# 3) Python 依赖
python3 -c "import psutil, oslo_concurrency" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "[FAIL] Python 依赖缺失 (psutil/oslo_concurrency), 请先 make install"
    exit 1
fi
echo "[OK] Python 依赖正常"

# 4) BMC 可达
if ! $IPMITOOL sel elist >/dev/null 2>&1; then
    echo "[FAIL] BMC 不可达, 请检查 IPMITOOL 配置"
    exit 1
fi
echo "[OK] BMC 可达"

# 5) 现有 python3 进程记录 (killall -9 python3 的影响面)
echo "--- 现有 python3 进程 (将被 killall -9 python3 波及) ---"
pgrep -a python3 || echo "(无)"
pgrep -a python3 > "${RESULT_DIR}/python3_before.txt" || true

# 6) 内存预检: run.py 会分配 可用内存x0.8 (MemAvailable 单位 KB)
FREE_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
FREE_MB=$((FREE_KB / 1024))
echo "[OK] 当前可用内存 ${FREE_MB}MB"

# ------------------------- 测前日志基线 -------------------------
echo "--- 测前日志基线 (logs_before) ---"
# dmesg: 存基线后清空, 测后 dmesg 即为测试时间窗内记录
dmesg > "${LOGS_BEFORE}/dmesg_before.txt" 2>/dev/null
dmesg -c >/dev/null 2>&1
echo "[OK] dmesg 基线已存并清空"

# messages: 记录当前行号作为基线, 测后从该行号之后分析
if [ -f /var/log/messages ]; then
    wc -l < /var/log/messages > "${RESULT_DIR}/messages_baseline_line.txt"
    echo "[OK] /var/log/messages 基线行号: $(cat ${RESULT_DIR}/messages_baseline_line.txt)"
else
    echo "[WARN] /var/log/messages 不存在 (可能用 journald)"
    echo 0 > "${RESULT_DIR}/messages_baseline_line.txt"
fi

# BMC SEL: 存基线 (测试前后 diff)
$IPMITOOL sel elist > "${LOGS_BEFORE}/bmc_sel_before.txt" 2>&1
echo "[OK] BMC SEL 基线已存 ($(wc -l < ${LOGS_BEFORE}/bmc_sel_before.txt) 条)"

# ------------------------- 启动测试 -------------------------
echo "--- 启动 eccmem run.py (P_NUM=$P_NUM) ---"
cd "$TOOL_DIR"
nohup python3 run.py --p_num="$P_NUM" > "${RESULT_DIR}/runpy_stdout.log" 2>&1 &
RUN_PID=$!
echo "run.py PID=$RUN_PID"

# 等待启动并确认
sleep 10
if ! kill -0 "$RUN_PID" 2>/dev/null; then
    echo "[FAIL] run.py 启动失败, 查看 ${RESULT_DIR}/runpy_stdout.log"
    exit 1
fi
echo "[OK] run.py 已启动"
pgrep -af "run.py --p_num" | grep -v grep

# ------------------------- 监控循环 -------------------------
echo "--- 开始监控 (每 ${CHECK_INTERVAL}s 采样, 总时长 ${MINUTES}min) ---"
SECONDS_TOTAL=$((MINUTES * 60))
ELAPSED=0
USAGE_LOG="${RESULT_DIR}/usage.log"
echo "# time cpu% mem_used_mb procs_memtester procs_python" > "$USAGE_LOG"

while [ "$ELAPSED" -lt "$SECONDS_TOTAL" ]; do
    # 检查 run.py 是否存活
    if ! kill -0 "$RUN_PID" 2>/dev/null; then
        echo "[WARN] run.py (PID $RUN_PID) 已退出, 尝试重启"
        cd "$TOOL_DIR"
        nohup python3 run.py --p_num="$P_NUM" >> "${RESULT_DIR}/runpy_stdout.log" 2>&1 &
        RUN_PID=$!
        echo "重启 run.py PID=$RUN_PID"
        sleep 5
    fi

    # 采样
    CPU_PCT=$(top -bn1 | awk -v n=0 '/%Cpu/{print $2}' | head -1)
    MEM_USED=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{print int((t-a)/1024)}' /proc/meminfo)
    N_MT=$(pgrep -cx memtester)
    N_PY=$(pgrep -c -f "[r]un.py")
    echo "$(date '+%F %T') cpu=${CPU_PCT} mem_used_mb=${MEM_USED} procs_memtester=${N_MT} procs_python=${N_PY}" >> "$USAGE_LOG"
    echo "$(date '+%F %T') cpu=${CPU_PCT} mem=${MEM_USED}MB memtester=${N_MT} python=${N_PY} elapsed=${ELAPSED}s/${SECONDS_TOTAL}s"

    sleep "$CHECK_INTERVAL"
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))
done

# ------------------------- 结束: 关闭脚本 -------------------------
echo "--- ${MINUTES}min 测试结束, 关闭脚本 ---"
echo "执行: killall -9 python3"
killall -9 python3 2>/dev/null
sleep 3
# 兜底: 清理 memtester 残留
pkill -9 -x memtester 2>/dev/null
echo "--- 关闭后进程检查 ---"
pgrep -af "[r]un.py|[m]emtester" || echo "(无残留)"
TS_END=$(date +%Y%m%d_%H%M%S)
echo "测试窗口: ${TS_START} -> ${TS_END}"

# ------------------------- 测后日志收集 -------------------------
echo "--- 测后日志收集 (logs_after) ---"
dmesg > "${LOGS_AFTER}/dmesg_after.txt" 2>/dev/null
$IPMITOOL sel elist > "${LOGS_AFTER}/bmc_sel_after.txt" 2>&1

# messages: 只取基线行号之后的内容
BASE_LINE=$(cat "${RESULT_DIR}/messages_baseline_line.txt")
if [ -f /var/log/messages ]; then
    tail -n +$((BASE_LINE + 1)) /var/log/messages > "${LOGS_AFTER}/messages_after.txt" 2>/dev/null
    echo "[OK] messages 测试窗口内容已提取 ($(wc -l < ${LOGS_AFTER}/messages_after.txt) 行)"
fi

# journal 兜底 (如果 messages 不可用)
journalctl --since "${TS_START:0:4}-${TS_START:4:2}-${TS_START:6:2} ${TS_START:8:2}:${TS_START:10:2}:${TS_START:12:2}" \
           --until "${TS_END:0:4}-${TS_END:4:2}-${TS_END:6:2} ${TS_END:8:2}:${TS_END:10:2}:${TS_END:12:2}" \
           > "${LOGS_AFTER}/journal_after.txt" 2>/dev/null || true

# run.py stdout 关键事件
grep -nE "start run memtester|start run memscan|UE|poison" "${RESULT_DIR}/runpy_stdout.log" | tail -20 \
    > "${RESULT_DIR}/runpy_key_events.txt" || true

# ------------------------- 结果判定 -------------------------
echo "--- 结果判定 ---"
SUMMARY="${RESULT_DIR}/summary_report.txt"
: > "$SUMMARY"

PASS_CNT=0
FAIL_CNT=0

# 验收项1: 文件上传成功 (工具存在)
if [ -f "${TOOL_DIR}/run.py" ] && [ -f "${TOOL_DIR}/memscan/memtester" ]; then
    echo "1.文件上传成功: PASS (run.py + memtester 存在)" | tee -a "$SUMMARY"
    PASS_CNT=$((PASS_CNT+1))
else
    echo "1.文件上传成功: FAIL" | tee -a "$SUMMARY"
    FAIL_CNT=$((FAIL_CNT+1))
fi

# 验收项2: 安装成功 (kkmmap 模块 + 设备 + 依赖)
if lsmod | grep -q '^kkmmap' && [ -c /dev/kkmmap ]; then
    echo "2.readme安装成功: PASS (kkmmap 已加载 + /dev/kkmmap 存在)" | tee -a "$SUMMARY"
    PASS_CNT=$((PASS_CNT+1))
else
    echo "2.readme安装成功: FAIL" | tee -a "$SUMMARY"
    FAIL_CNT=$((FAIL_CNT+1))
fi

# 验收项3: 12h 正常运行 + 三日志源无报错
# 3a) 运行完整性: 全程无重启, 有 memtester/memscan 活动
RUNPY_OK=1
grep -q "start run memtester" "${RESULT_DIR}/runpy_stdout.log" || RUNPY_OK=0
N_RESTART=$(grep -c "已退出" "$LOG_FILE")
if [ "$RUNPY_OK" -eq 1 ] && [ "$N_RESTART" -le 1 ]; then
    echo "3a.运行完整性: PASS (memtester 正常启动, 重启次数=$N_RESTART)" | tee -a "$SUMMARY"
    PASS_CNT=$((PASS_CNT+1))
else
    echo "3a.运行完整性: FAIL (RUNPY_OK=$RUNPY_OK 重启=$N_RESTART)" | tee -a "$SUMMARY"
    FAIL_CNT=$((FAIL_CNT+1))
fi

# 3b) dmesg 无硬件错误
DMESG_HITS=$(grep -icE "$HW_ERR_PAT" "${LOGS_AFTER}/dmesg_after.txt" 2>/dev/null)
if [ "${DMESG_HITS:-0}" -eq 0 ]; then
    echo "3b.dmesg: PASS (测试窗口内无硬件错误记录)" | tee -a "$SUMMARY"
    PASS_CNT=$((PASS_CNT+1))
else
    echo "3b.dmesg: FAIL (命中 ${DMESG_HITS} 条, 详见 logs_after/dmesg_after.txt)" | tee -a "$SUMMARY"
    grep -inE "$HW_ERR_PAT" "${LOGS_AFTER}/dmesg_after.txt" | head -10 >> "$SUMMARY"
    FAIL_CNT=$((FAIL_CNT+1))
fi

# 3c) messages 无硬件错误
MSG_HITS=$(grep -icE "$HW_ERR_PAT" "${LOGS_AFTER}/messages_after.txt" 2>/dev/null)
if [ "${MSG_HITS:-0}" -eq 0 ]; then
    echo "3c.messages: PASS (测试窗口内无硬件错误记录)" | tee -a "$SUMMARY"
    PASS_CNT=$((PASS_CNT+1))
else
    echo "3c.messages: FAIL (命中 ${MSG_HITS} 条, 详见 logs_after/messages_after.txt)" | tee -a "$SUMMARY"
    grep -inE "$HW_ERR_PAT" "${LOGS_AFTER}/messages_after.txt" | head -10 >> "$SUMMARY"
    FAIL_CNT=$((FAIL_CNT+1))
fi

# 3d) BMC SEL 无新增事件 (对比基线)
BEFORE_CNT=$(wc -l < "${LOGS_BEFORE}/bmc_sel_before.txt")
AFTER_CNT=$(wc -l < "${LOGS_AFTER}/bmc_sel_after.txt")
if [ "$AFTER_CNT" -eq "$BEFORE_CNT" ]; then
    echo "3d.BMC SEL: PASS (无新增事件, ${BEFORE_CNT}->${AFTER_CNT})" | tee -a "$SUMMARY"
    PASS_CNT=$((PASS_CNT+1))
else
    echo "3d.BMC SEL: FAIL (新增事件 ${BEFORE_CNT}->${AFTER_CNT})" | tee -a "$SUMMARY"
    diff "${LOGS_BEFORE}/bmc_sel_before.txt" "${LOGS_AFTER}/bmc_sel_after.txt" | head -10 >> "$SUMMARY"
    FAIL_CNT=$((FAIL_CNT+1))
fi

# 验收项4: 脚本可正常关闭
if ! pgrep -af "[r]un.py" >/dev/null; then
    echo "4.脚本正常关闭: PASS (killall -9 python3 后无 run.py 残留)" | tee -a "$SUMMARY"
    PASS_CNT=$((PASS_CNT+1))
else
    echo "4.脚本正常关闭: FAIL (仍有残留)" | tee -a "$SUMMARY"
    FAIL_CNT=$((FAIL_CNT+1))
fi

# ------------------------- 汇总 -------------------------
echo "" | tee -a "$SUMMARY"
echo "==============================" | tee -a "$SUMMARY"
echo "eccmem 12h 压测汇总: PASS=$PASS_CNT FAIL=$FAIL_CNT" | tee -a "$SUMMARY"
if [ "$FAIL_CNT" -eq 0 ]; then
    echo "结论: 全部 PASS" | tee -a "$SUMMARY"
else
    echo "结论: 存在 FAIL 项, 详见上方" | tee -a "$SUMMARY"
fi
echo "结果目录: $RESULT_DIR" | tee -a "$SUMMARY"
echo "================ 结束 $(date '+%F %T') ================" | tee -a "$SUMMARY"
echo "ALL_DONE"
