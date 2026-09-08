#!/bin/bash
# ============================================================================
# nvme_cloud_qual_suite_chs
# 版本   : 3.0
# 作者   : SIT-Kit / Prz1y
# 更新   : 2026-05
# WARNING: This suite includes fio preconditioning and secure erase related
# operations that can destroy data on target NVMe devices. Run it only on RD/lab machines.
# ----------------------------------------------------------------------------
# 说明:
#   面向云场景的 NVMe 存储性能自动化测试套件。
#   覆盖顺序读写、随机读写、混合读写全矩阵，并采集测试前后 SMART 日志、
#   PCIe AER 异常检测及 IPMI SEL 事件。
#   测试结果自动汇总为结构化 Excel 报告，包含各模式下的 IOPS 矩阵
#   和 clat（盘侧完成延迟）矩阵。
#
#   随机 I/O 使用 FIO 3.41+ 新增的 sprandom (Xoshiro256+) 随机数生成器，
#   相比传统 tausworthe64 在大容量 NVMe 上具有更均匀的 LBA 分布。
#
# 环境要求:
#   - FIO >= 3.41  （sprandom 随机数生成器支持）
#   - Root 权限
#
# 系统依赖:
#   sudo yum/apt-get install -y fio nvme-cli pciutils python3 python3-pip \
#                               numactl ipmitool libaio-devel
#   pip3 install pandas openpyxl
#
# 使用方法:
#   1. 编辑下方 [ 核心配置区 ]，按实际测试环境填写参数。
#   2. 以 root 运行:  sudo bash nvme_cloud_qual_suite_chs.sh
#   3. 断点续测: 将 RESUME_FROM 设为已有的测试工作目录路径后重新执行即可。
# ============================================================================

set -euo pipefail

echo "WARNING: nvme_snia_sss_pts_test_suite.sh may overwrite or secure-erase target NVMe devices during qualification." >&2

# ============================================================================
# 全局信号处理 (trap) -- 确保 Ctrl+C / kill 时清理所有 FIO 子进程
# ============================================================================
cleanup_on_exit() {
    echo ""
    echo "[INFO] Signal received. Cleaning up all running fio processes..."
    pkill -f "fio.*--name=" 2>/dev/null || true
    sleep 1
    rm -f "${SYSINFO_TMP:-}"
    echo "[INFO] Cleanup complete. Exiting."
}
trap cleanup_on_exit EXIT INT TERM

# ============================================================================
#[ 核心配置区 ]  <-- 运行前只需修改这里
# ============================================================================

# 测试模式: "single" = 单盘全矩阵(numjobs x iodepth 完整扫描)
#           "multi"  = 多盘并发(仅跑 SEQ_COMBOS/RAND_COMBOS 代表性组合)
TEST_MODE="single"

# 目标块设备列表。single 模式填1个，multi 模式可填多个，用空格分隔数组元素
# 示例(多盘): TARGET_DEVS=("/dev/nvme0n1" "/dev/nvme1n1")
TARGET_DEVS=("/dev/nvme1n1")

# 服务器型号标识，用于生成报告文件名，不含空格
SERVER_MODEL="Server"

# 单个顺序/随机测试点的运行时长（秒）。建议 >= 300s 以保证稳态数据
RUNTIME=300

# 混合读写每个测试点的运行时长（秒）。需更长时间平衡读写队列
MIX_RUNTIME=1200

# 混合读写并发参数: numjobs 和 iodepth
MIX_NUMJOBS=4
MIX_IODEPTH=64

# 是否在顺序测试前执行顺序写预调教 (yes/no)
# 目的：将盘内部映射表刷新到稳定状态，排除空盘性能虚高
DO_SEQ_PRECON="yes"

# 顺序预调教循环次数。每次 loop 以 128k/QD128 顺序写填满 100% 容量
SEQ_PRE_LOOPS=2

# 是否在随机测试前执行随机写预调教 (yes/no)
DO_RAND_PRECON="yes"

# 随机预调教循环次数。以 4k/QD128/4jobs 随机写覆盖一次全盘
RAND_PRE_LOOPS=1

# 以下开关控制各测试阶段是否执行，设为 "no" 可跳过对应阶段
RUN_SEQ_READ="yes"   # 顺序读矩阵
RUN_SEQ_WRITE="yes"  # 顺序写矩阵
RUN_RAND_READ="yes"  # 随机读矩阵
RUN_RAND_WRITE="yes" # 随机写矩阵
RUN_MIXED_RW="yes"   # 混合读写矩阵 (4k/8k/16k/32k x 9种读写比)

# 块大小列表，空格分隔，所有阶段均遍历此列表
TEST_BS_LIST="4k 8k 16k 32k 64k 128k 256k 512k 1m"

# 断点续测：填写已有的测试工作目录路径（如 /path/to/NVME_TEST_20260401_120000）
# 留空则新建工作目录并从头开始
RESUME_FROM=""

# 是否启用 NUMA 绑定，将 fio 进程绑定到 NVMe 控制器所在的 NUMA 节点
# 多 NUMA 架构（如 2-socket 或 Hygon/AMD）下建议开启，避免跨节点内存访问带来性能抖动
ENABLE_NUMA_BIND="yes"

# NUMA 绑定实现方式（仅支持 numactl）:
#   "numactl" - 通过 numactl 命令包装整个 fio 进程（需已安装 numactl）
NUMA_BIND_METHOD="numactl"

# 当 sysfs 中读不到 NUMA 节点信息时的回退节点编号
NUMA_FALLBACK_NODE="0"

# ============================================================================
#[ 环境与安全前置检查 ]
# ============================================================================

echo "[INFO] Commencing pre-flight system checks..."

# 记录系统环境信息
echo "[INFO] Recording system environment..."
SYSINFO_TMP=$(mktemp /tmp/nvme_test_sysinfo.XXXXXX)
uname -a > "$SYSINFO_TMP" 2>/dev/null || true
lscpu >> "$SYSINFO_TMP" 2>/dev/null || true
free -h >> "$SYSINFO_TMP" 2>/dev/null || true

if [[ "$EUID" -ne 0 ]]; then
    echo "[ERROR] This suite requires root privileges. Please run as root."
    exit 1
fi

for tool in fio nvme lspci python3; do
    if ! command -v $tool >/dev/null 2>&1; then
        echo "[ERROR] Required dependency '$tool' is not installed."
        exit 1
    fi
done

# 调整系统资源限制，避免大并发 I/O 测试时触发上限
echo "[INFO] Adjusting system resource limits for high-concurrency I/O testing..."
ulimit -n 65536 2>/dev/null || echo "[WARNING] Could not raise nofile ulimit."
if [[ -w /proc/sys/fs/aio-max-nr ]]; then
    echo 1048576 > /proc/sys/fs/aio-max-nr 2>/dev/null || true
fi

# FIO version validation -- sprandom random generator requires FIO >= 3.41
FIO_VERSION_OUTPUT=$(fio --version 2>/dev/null | head -1)
FIO_VER_RAW=$(echo "$FIO_VERSION_OUTPUT" | sed -n 's/.*fio-\([0-9]\+\.[0-9]\+\).*/\1/p' | head -1)
if [[ -z "$FIO_VER_RAW" ]]; then
    FIO_VER_RAW=$(echo "$FIO_VERSION_OUTPUT" | sed -n 's/.*\([0-9]\+\.[0-9]\+\).*/\1/p' | head -1)
fi
FIO_MAJOR=$(echo "$FIO_VER_RAW" | cut -d'.' -f1)
FIO_MINOR=$(echo "$FIO_VER_RAW" | cut -d'.' -f2)
if ! [[ "$FIO_MAJOR" =~ ^[0-9]+$ ]] || ! [[ "$FIO_MINOR" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Unable to determine FIO version. Output was: $FIO_VERSION_OUTPUT"
    echo "[ERROR] Please verify your FIO installation."
    exit 1
fi
if [[ "$FIO_MAJOR" -lt 3 ]] || { [[ "$FIO_MAJOR" -eq 3 ]] && [[ "$FIO_MINOR" -lt 41 ]]; }; then
    echo "[ERROR] FIO version ${FIO_VER_RAW} is not supported."
    echo "[ERROR] This suite requires FIO >= 3.41 for sprandom I/O generator support."
    exit 1
fi
echo "[INFO] FIO version check passed: ${FIO_VER_RAW} (>= 3.41 required)"

if [[ "$ENABLE_NUMA_BIND" == "yes" ]] && [[ "$NUMA_BIND_METHOD" == "numactl" ]]; then
    if ! command -v numactl >/dev/null 2>&1; then
        echo "[WARNING] numactl not found. NUMA binding will be disabled."
        ENABLE_NUMA_BIND="no"
    fi
fi

# 验证 Python 依赖 (pandas, openpyxl) -- 提前发现问题，避免测试完成后才报错
echo "[INFO] Verifying Python dependencies (pandas, openpyxl)..."
if ! python3 -c "import pandas, openpyxl" 2>/dev/null; then
    echo "[ERROR] Python dependencies missing. Please run:"
    echo "         pip3 install pandas openpyxl"
    exit 1
fi
echo "[INFO] Python dependencies OK."

for dev in "${TARGET_DEVS[@]}"; do
    if [[ ! -b "$dev" ]]; then
        echo "[ERROR] Block device '$dev' does not exist or is invalid."
        exit 1
    fi
done

# 验证 RESUME_FROM 工作目录有效性
if [[ -n "$RESUME_FROM" ]]; then
    if [[ ! -d "$RESUME_FROM" ]]; then
        echo "[ERROR] RESUME_FROM directory '$RESUME_FROM' does not exist."
        exit 1
    fi
    if [[ ! -d "${RESUME_FROM}/raw_data" ]]; then
        echo "[WARNING] raw_data/ not found in RESUME_FROM. Resume may not work correctly."
    fi
    BASE_DIR="$RESUME_FROM"
    RESUME_FLAG="--resume"
    echo "[INFO] Resuming from existing workspace: $BASE_DIR"
else
    BASE_DIR="$(pwd)/NVME_TEST_$(date +%Y%m%d_%H%M%S)"
    RESUME_FLAG=""
    echo "[INFO] Test workspace created at: $BASE_DIR"
fi

RAW_DIR="${BASE_DIR}/raw_data"
LOG_DIR="${BASE_DIR}/logs"

mkdir -p "$RAW_DIR" "$LOG_DIR"

# 保存系统环境信息到日志目录
cp "$SYSINFO_TMP" "$LOG_DIR/system_info.log" 2>/dev/null || true
rm -f "$SYSINFO_TMP"

# dmesg 采集：先尝试 -T（人类可读时间戳），失败则回退到无 -T
if ! dmesg -T > "$LOG_DIR/pre_dmesg.log" 2>/dev/null; then
    echo "[WARNING] dmesg -T not supported on this kernel. Falling back to dmesg without timestamps."
    dmesg > "$LOG_DIR/pre_dmesg.log" 2>/dev/null || echo "[WARNING] dmesg collection failed." > "$LOG_DIR/pre_dmesg.log"
fi

lspci -vvv > "$LOG_DIR/pre_lspci.log" 2>/dev/null || true
for dev in "${TARGET_DEVS[@]}"; do
    dev_tag=$(basename "$dev")
    if ! nvme smart-log "$dev" > "$LOG_DIR/pre_smart_${dev_tag}.log" 2>/dev/null; then
        echo "[WARNING] Failed to collect pre-test SMART log for $dev. Device may be unhealthy."
    fi
done

# ============================================================================
# 数据安全确认 -- 强制交互式确认，防止误操作导致不可逆数据丢失
# ============================================================================
if [[ -z "$RESUME_FROM" ]]; then
    echo ""
    echo "========================================================================"
    echo "  WARNING: DATA DESTRUCTION NOTICE"
    echo "========================================================================"
    echo "  This script will perform 'nvme format -s 1' (Secure Erase) on the"
    echo "  following devices. ALL DATA will be IRREVERSIBLY DESTROYED."
    echo ""
    for dev in "${TARGET_DEVS[@]}"; do
        dev_info=$(lsblk -dno SIZE,MODEL "$dev" 2>/dev/null || echo "unknown")
        echo "    -> $dev  [$dev_info]"
    done
    echo ""
    echo "  This data CANNOT be recovered by any means."
    echo "========================================================================"
    echo ""
    read -r -p "  Type 'ERASE' (uppercase) to confirm and proceed: " confirm
    if [[ "$confirm" != "ERASE" ]]; then
        echo ""
        echo "[ABORT] User declined. No data was harmed. Exiting."
        exit 0
    fi
    echo ""
    echo "[INFO] User confirmation received. Proceeding with secure erase..."
fi

# ====================[ Python 测试引擎注入 ] ====================
PYTHON_ENGINE="${BASE_DIR}/nvme_fio_engine.py"

cat << 'PYEOF' > "$PYTHON_ENGINE"
import os, sys, json, time, subprocess, argparse, datetime, shlex, re
import atexit, signal, traceback
from concurrent.futures import ThreadPoolExecutor, as_completed, TimeoutError as FutureTimeoutError
import pandas as pd

# ----------------------------------------------------------------------------
# I/O 参数矩阵定义 (single 模式全量扫描, multi 模式仅跑代表性组合)
# ----------------------------------------------------------------------------
NUMJOBS_LIST = [1, 2, 4, 8]
IODEPTH_LIST = [1, 2, 4, 8, 16, 32, 64, 128, 256]
MIX_RATIO_LIST = [10, 20, 30, 40, 50, 60, 70, 80, 90]

# multi 模式代表性顺序组合 (bs, numjobs, iodepth)
SEQ_COMBOS = [
    ('128k', 1, 32), ('128k', 1, 64), ('128k', 1, 128), ('128k', 1, 256), ('128k', 1, 512),
    ('4k', 2, 32), ('64k', 2, 32), ('256k', 2, 32), ('1m', 2, 32),
]
# multi 模式代表性随机组合 (bs, numjobs, iodepth)
RAND_COMBOS = [
    ('4k', 1, 32), ('4k', 1, 64), ('4k', 1, 128), ('4k', 1, 256),
    ('4k', 4, 32), ('8k', 4, 32), ('16k', 4, 32),
]

# ----------------------------------------------------------------------------
# 日志与工具函数
# ----------------------------------------------------------------------------
def log_print(msg):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)

def get_drive_info(dev):
    try:
        res = subprocess.run(["nvme", "id-ctrl", dev],
                             capture_output=True, text=True, timeout=30)
        if res.returncode != 0:
            log_print(f"[WARNING] nvme id-ctrl {dev} failed: {res.stderr.strip()}")
            return {"dev": dev, "model": "unknown", "serial": "unknown", "fw": "unknown", "namespace": 1}
        model = "unknown"; sn = "unknown"; fw = "unknown"; ns = 1
        for line in res.stdout.splitlines():
            line_stripped = line.strip()
            if line_stripped.startswith("mn "):
                model = line_stripped.split(":", 1)[-1].strip()
            elif line_stripped.startswith("sn "):
                sn = line_stripped.split(":", 1)[-1].strip()
            elif line_stripped.startswith("fr "):
                fw = line_stripped.split(":", 1)[-1].strip()
            elif line_stripped.startswith("nn "):
                try:
                    ns = int(line_stripped.split(":", 1)[-1].strip())
                except ValueError:
                    ns = 1
        return {"dev": dev, "model": model, "serial": sn, "fw": fw, "namespace": ns}
    except subprocess.TimeoutExpired:
        log_print(f"[ERROR] nvme id-ctrl {dev} timed out after 30s.")
        return {"dev": dev, "model": "timeout", "serial": "timeout", "fw": "timeout", "namespace": 1}
    except Exception as e:
        log_print(f"[ERROR] get_drive_info({dev}) exception: {e}")
        return {"dev": dev, "model": "error", "serial": "error", "fw": "error", "namespace": 1}

def get_numa_node(dev_path, fallback):
    dev_name = os.path.basename(dev_path)
    sysfs_path = f"/sys/block/{dev_name}/device/numa_node"
    try:
        if os.path.isfile(sysfs_path):
            with open(sysfs_path) as f:
                val = f.read().strip()
                if val.isdigit() or (val.startswith('-') and val[1:].isdigit()):
                    node = int(val)
                    return node if node >= 0 else fallback
    except Exception:
        pass
    try:
        res = subprocess.run(["lsblk", "-ndo", "NAME", dev_path],
                             capture_output=True, text=True, timeout=5)
        if res.returncode == 0:
            name = res.stdout.strip()
            ctrl = name.split('n')[0]
            ctrl_path = f"/sys/class/nvme/{ctrl}/device/numa_node"
            if os.path.isfile(ctrl_path):
                with open(ctrl_path) as f:
                    val = f.read().strip()
                    if val.isdigit() or (val.startswith('-') and val[1:].isdigit()):
                        node = int(val)
                        return node if node >= 0 else fallback
    except Exception:
        pass
    log_print(f"[WARNING] Cannot determine NUMA node for {dev_name}, falling back to node {fallback}.")
    return fallback

def run_cmd(cmd_args, log_file=None, timeout=None):
    if isinstance(cmd_args, str):
        cmd_args = shlex.split(cmd_args)
    try:
        res = subprocess.run(cmd_args, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, timeout=timeout)
        if log_file:
            with open(log_file, 'a', encoding='utf-8') as f:
                f.write(res.stdout or "")
        return res.returncode == 0
    except subprocess.TimeoutExpired:
        log_print(f"[ERROR] Command timed out: {' '.join(cmd_args[:3])}...")
        return False
    except Exception as e:
        log_print(f"[ERROR] Command execution failed: {e}")
        return False

def is_valid_fio_json(path):
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
            return 'jobs' in data and len(data.get('jobs', [])) > 0
    except Exception:
        return False

def format_drive(dev, base_dir):
    for attempt in range(1, 4):
        log_print(f"[INFO] Formatting {dev} (Attempt {attempt}/3)...")
        success = run_cmd(["nvme", "format", dev, "-s", "1"], timeout=300)
        if success:
            time.sleep(10)
            return True
        time.sleep(5)
    log_print(f"[CRITICAL] Failed to secure erase {dev} after 3 attempts.")
    log_print(f"[CRITICAL] Attempting to collect error-log for diagnostics...")
    run_cmd(["nvme", "error-log", dev],
            log_file=f"{base_dir}/logs/format_error_{os.path.basename(dev)}.log", timeout=30)
    return False

# ----------------------------------------------------------------------------
# FIO 命令构建与执行
# ----------------------------------------------------------------------------
def compute_ramp_runtime(numjobs, iodepth, base_runtime):
    concurrency = numjobs * iodepth
    if base_runtime <= 5:
        return base_runtime, 1
    if concurrency <= 32:
        return base_runtime, min(int(base_runtime * 0.15), 60)
    elif concurrency <= 128:
        rt = max(base_runtime, 120)
        return rt, min(int(rt * 0.2), 60)
    else:
        rt = max(base_runtime, 180)
        return rt, min(int(rt * 0.2), 60)

def detect_fio_random_generator():
    try:
        result = subprocess.run(["fio", "--cmdhelp=random_generator"],
                                capture_output=True, text=True, timeout=10)
        if "sprandom" in result.stdout.lower():
            return "sprandom"
    except Exception:
        pass
    return "tausworthe64"

FIO_RANDOM_GENERATOR = detect_fio_random_generator()

def build_fio_cmd(dev, rw, bs, numjobs, iodepth, runtime, rwmixread=None,
                  numa_info=None, engine="libaio", direct=True, json_out=None):
    ramp_time, calculated_ramp = compute_ramp_runtime(numjobs, iodepth, runtime)
    actual_runtime = ramp_time + calculated_ramp
    cmd = [
        "fio",
        "--name=nvme_test",
        f"--filename={dev}",
        f"--rw={rw}",
        f"--bs={bs}",
        f"--numjobs={numjobs}",
        f"--iodepth={iodepth}",
        f"--runtime={actual_runtime}",
        f"--ramp_time={calculated_ramp}",
        f"--ioengine={engine}",
        "--thread",
        "--direct=1" if direct else "--direct=0",
        "--time_based",
        "--group_reporting",
        "--output-format=json",
        "--norandommap",
        f"--random_generator={FIO_RANDOM_GENERATOR}",
        "--end_fsync=0",
        "--buffer_compress_percentage=0",
        "--eta=never",
        "--status-interval=60",
    ]
    if json_out is not None:
        cmd.append(f"--output={json_out}")
    if rwmixread is not None:
        cmd.append(f"--rwmixread={rwmixread}")
    if numa_info and numa_info.get("enabled"):
        if numa_info.get("method") == "numactl":
            cmd = ["numactl", f"--cpunodebind={numa_info['node']}",
                   f"--membind={numa_info['node']}"] + cmd

    return cmd, actual_runtime

def run_fio_task(dev, rw, bs, numjobs, iodepth, runtime, rwmixread, numa_info,
                 raw_dir, task_label, resume):
    safe_label = task_label.replace('/', '_').replace(' ', '_')
    json_out = os.path.join(raw_dir, f"{safe_label}.json")
    if resume and is_valid_fio_json(json_out):
        log_print(f"[RESUME] Skipping task (valid JSON found): {os.path.basename(json_out)}")
        return (json_out, os.path.basename(dev))

    cmd, effective_runtime = build_fio_cmd(dev, rw, bs, numjobs, iodepth, runtime,
                                            rwmixread, numa_info, json_out=json_out)
    log_print(f"[FIO] {task_label} | runtime={effective_runtime}s | device={os.path.basename(dev)}")
    cmd_str = ' '.join(cmd)
    log_file = os.path.join(raw_dir, f"{safe_label}.log")
    safe_timeout = effective_runtime + 300
    success = run_cmd(cmd, log_file=log_file, timeout=safe_timeout)
    if not success:
        log_print(f"[ERROR] FIO task failed: {task_label}")
        return (None, os.path.basename(dev))

    time.sleep(1)
    if os.path.exists(json_out):
        return (json_out, os.path.basename(dev))
    else:
        log_print(f"[ERROR] FIO JSON output not found: {json_out}")
        return (None, os.path.basename(dev))

def execute_synchronized_parallel(devs, rw, bs, numjobs, iodepth, runtime, rwmixread,
                                   numa_map, raw_dir, task_label_prefix, resume,
                                   parallel_timeout=None):
    json_results = []
    tasks = []
    for dev in devs:
        dev_name = os.path.basename(dev)
        task_label = f"{task_label_prefix}_{dev_name}"
        tasks.append((dev, rw, bs, numjobs, iodepth, runtime, rwmixread,
                       numa_map.get(dev), raw_dir, task_label, resume))

    with ThreadPoolExecutor(max_workers=len(devs)) as executor:
        future_map = {executor.submit(run_fio_task, *t): t for t in tasks}
        try:
            for future in as_completed(future_map, timeout=parallel_timeout):
                task = future_map[future]
                try:
                    result = future.result()
                    if result[0] is not None:
                        json_results.append(result)
                    else:
                        log_print(f"[ERROR] Task failed for device {task[0]}")
                except Exception as e:
                    log_print(f"[ERROR] Unhandled exception in task {task[-2]}: {e}")
                    traceback.print_exc()
        except FutureTimeoutError:
            log_print("[CRITICAL] Parallel execution timed out. Partial results will be used.")
        except KeyboardInterrupt:
            log_print("[INFO] Keyboard interrupt. Shutting down executor...")
            executor.shutdown(wait=False, cancel_futures=True)
            raise

    return json_results

# ----------------------------------------------------------------------------
# FIO JSON 数据分析
# ----------------------------------------------------------------------------
def parse_fio_json(json_path, dev_name):
    if not os.path.exists(json_path):
        log_print(f"[WARNING] JSON file not found for parsing: {json_path}")
        return None
    try:
        with open(json_path, encoding='utf-8') as f:
            data = json.load(f)
    except Exception as e:
        log_print(f"[ERROR] Failed to parse JSON {os.path.basename(json_path)}: {e}")
        return None

    jobs = data.get("jobs", [])
    if not jobs:
        log_print(f"[WARNING] No jobs found in {os.path.basename(json_path)}")
        return None

    results = []
    for job in jobs:
        job_name = job.get("jobname", "unknown")
        read_metrics = job.get("read", {})
        write_metrics = job.get("write", {})

        r_iops = read_metrics.get("iops", 0)
        w_iops = write_metrics.get("iops", 0)
        r_bw = read_metrics.get("bw_bytes", 0) / (1024 * 1024) if read_metrics.get("bw_bytes") else 0
        w_bw = write_metrics.get("bw_bytes", 0) / (1024 * 1024) if write_metrics.get("bw_bytes") else 0

        r_clat = read_metrics.get("clat_ns", {})
        w_clat = write_metrics.get("clat_ns", {})

        def extract_latency_ns(clat_dict, percentile_key, fallback_key=None):
            val = clat_dict.get("percentile", {}).get(percentile_key, 0)
            if val == 0 and fallback_key:
                val = clat_dict.get("percentile", {}).get(fallback_key, 0)
                if val > 0:
                    log_print(f"[INFO] {percentile_key} not available, using {fallback_key} as fallback (value={val}ns)")
            return val / 1000.0

        r_mean_us = r_clat.get("mean", 0) / 1000.0
        r_p99_us = r_clat.get("percentile", {}).get("99.000000", 0) / 1000.0
        r_p999_us = r_clat.get("percentile", {}).get("99.900000", 0) / 1000.0
        r_p9999_us = extract_latency_ns(r_clat, "99.990000", "99.900000")

        w_mean_us = w_clat.get("mean", 0) / 1000.0
        w_p99_us = w_clat.get("percentile", {}).get("99.000000", 0) / 1000.0
        w_p999_us = w_clat.get("percentile", {}).get("99.900000", 0) / 1000.0
        w_p9999_us = extract_latency_ns(w_clat, "99.990000", "99.900000")

        results.append({
            "dev": dev_name, "job": job_name,
            "r_iops": round(r_iops, 1), "w_iops": round(w_iops, 1),
            "r_bw_mb": round(r_bw, 2), "w_bw_mb": round(w_bw, 2),
            "r_avg_us": round(r_mean_us, 2), "r_p99_us": round(r_p99_us, 2),
            "r_p999_us": round(r_p999_us, 2), "r_p9999_us": round(r_p9999_us, 2),
            "w_avg_us": round(w_mean_us, 2), "w_p99_us": round(w_p99_us, 2),
            "w_p999_us": round(w_p999_us, 2), "w_p9999_us": round(w_p9999_us, 2),
        })
    return results

# ----------------------------------------------------------------------------
# Excel 报告生成
# ----------------------------------------------------------------------------
def _create_matrix_sheet(writer, sheet_name, bs_list, nj_list, qd_list, data_dict, metric_col,
                         title, numfmt="0.00"):
    if not data_dict:
        return
    headers = ["BlockSize \\ NJxQD"] + [f"NJ-{nj}_QD-{qd}" for nj in nj_list for qd in qd_list]
    rows = []
    for bs in bs_list:
        row = [bs]
        for nj in nj_list:
            for qd in qd_list:
                val = data_dict.get((bs, nj, qd))
                row.append(val if val is not None else "")
        rows.append(row)
    df = pd.DataFrame(rows, columns=headers)
    df.to_excel(writer, sheet_name=sheet_name, index=False)

def generate_excel(args, json_files, suite_type, test_mode):
    report_path = os.path.join(args.base_dir,
        f"{args.server_model}_{suite_type}_{test_mode}_report.xlsx")
    try:
        writer = pd.ExcelWriter(report_path, engine='openpyxl')
    except Exception as e:
        log_print(f"[ERROR] Failed to create Excel writer: {e}")
        return

    all_data = []
    for json_path, dev_name in json_files:
        if json_path is None or not os.path.exists(json_path):
            continue
        parsed = parse_fio_json(json_path, dev_name)
        if parsed:
            for entry in parsed:
                basename = os.path.basename(json_path).replace('.json', '')
                parts = basename.split('_')
                entry['rw'] = "?"
                entry['bs'] = "?"
                entry['nj'] = 0
                entry['qd'] = 0
                if basename.startswith('SEQ_Read_') or basename.startswith('RAND_Read_'):
                    entry['rw'] = 'Read'
                elif basename.startswith('SEQ_Write_') or basename.startswith('RAND_Write_'):
                    entry['rw'] = 'Write'
                elif basename.startswith('MixedRW_'):
                    entry['rw'] = 'MixedRW'
                for p in parts:
                    m = re.match(r'^(\d+[km])$', p)
                    if m:
                        entry['bs'] = m.group(1)
                        break
                for p in parts:
                    m = re.match(r'^nj(\d+)$', p)
                    if m:
                        entry['nj'] = int(m.group(1))
                        break
                for p in parts:
                    m = re.match(r'^qd(\d+)$', p)
                    if m:
                        entry['qd'] = int(m.group(1))
                        break
                for p in parts:
                    m = re.match(r'^r(\d+)$', p)
                    if m:
                        entry['rwmixread'] = int(m.group(1))
                        break
                all_data.append(entry)

    if not all_data:
        log_print("[WARNING] No valid data to generate Excel report.")
        return

    df = pd.DataFrame(all_data)
    bs_order = ['4k','8k','16k','32k','64k','128k','256k','512k','1m']
    bs_present = [b for b in bs_order if b in df['bs'].unique()]
    nj_present = sorted(df['nj'].unique())
    qd_present = sorted(df['qd'].unique())

    for rw_mode, rw_label in [("read","Read"), ("write","Write")]:
        sub = df[df['rw'].str.lower() == rw_mode].copy()
        if sub.empty:
            continue
        pfx = "r_" if rw_mode == "read" else "w_"
        for metric, col, fmt in [
            ("IOPS_Matrix", f"{pfx}iops", "0.00"),
            ("BW_MB_Matrix", f"{pfx}bw_mb", "0.00"),
            ("AvgLat_us_Matrix", f"{pfx}avg_us", "0.00"),
            ("P99_us_Matrix", f"{pfx}p99_us", "0.00"),
            ("P999_us_Matrix", f"{pfx}p999_us", "0.00"),
            ("P9999_us_Matrix", f"{pfx}p9999_us", "0.00"),
        ]:
            data_dict = {}
            for _, row in sub.iterrows():
                key = (row['bs'], row['nj'], row['qd'])
                data_dict[key] = row[col]
            sheet = f"{rw_label}_{metric}"[:31]
            _create_matrix_sheet(writer, sheet, bs_present, nj_present, qd_present,
                                 data_dict, col, f"{rw_label} {metric}", fmt)

    if suite_type == "MixedRW":
        sub = df.copy()
        ratio_present = sorted(sub['rwmixread'].unique() if 'rwmixread' in sub.columns else [])
        if not ratio_present:
            ratio_present = sorted(sub['r_iops'].unique())
        for bs in bs_present:
            bs_sub = sub[sub['bs'] == bs]
            if bs_sub.empty:
                continue
            for metric, col, fmt in [
                ("IOPS", "r_iops", "0.00"),
                ("AvgLat_us", "r_avg_us", "0.00"),
                ("P99_us", "r_p99_us", "0.00"),
            ]:
                sheet_name = f"Mix_{bs}_{metric}"[:31]
                ratio_data = {}
                for _, row in bs_sub.iterrows():
                    ratio = row.get('rwmixread', row['r_iops'])
                    ratio_data[ratio] = row[col]
                ratios_sorted = sorted(ratio_data.keys())
                if ratios_sorted:
                    df_mix = pd.DataFrame({"rwmixread": ratios_sorted,
                        col: [ratio_data[r] for r in ratios_sorted]})
                    df_mix.to_excel(writer, sheet_name=sheet_name, index=False)

    if test_mode == "multi":
        for rw_mode, rw_label in [("read","Read"), ("write","Write")]:
            sub = df[df['rw'].str.lower() == rw_mode].copy()
            if sub.empty:
                continue
            pfx = "r_" if rw_mode == "read" else "w_"
            for metric, col in [("IOPS", f"{pfx}iops"), ("AvgLat_us", f"{pfx}avg_us")]:
                sheet_name = f"MultiDev_{rw_label}_{metric}"[:31]
                pivot = sub.pivot_table(values=col, index='rwmixread' if 'rwmixread' in sub.columns else 'bs',
                                        columns='dev', aggfunc='mean')
                pivot.to_excel(writer, sheet_name=sheet_name)

    writer.close()
    log_print(f"[INFO] Excel report generated: {report_path}")

# ----------------------------------------------------------------------------
# 预调教 (Preconditioning)
# ----------------------------------------------------------------------------
def run_preconditioning(devs, bs, numjobs, iodepth, loops, rw_mode, desc, numa_map):
    log_print(f"[PRECON] Starting {desc} (bs={bs} nj={numjobs} qd={iodepth} loops={loops})...")
    for loop in range(1, loops + 1):
        log_print(f"[PRECON] {desc} loop {loop}/{loops}")
        for dev in devs:
            dev_name = os.path.basename(dev)
            task_label = f"precon_{desc.replace(' ','_')}_{dev_name}_L{loop}"
            cmd, runtime = build_fio_cmd(dev, rw_mode, bs, numjobs, iodepth, 0,
                                          None, numa_map.get(dev))
            cmd.append("--loops=1")
            cmd.append("--size=100%")
            safe_timeout = 3600
            run_cmd(cmd, timeout=safe_timeout)
        log_print(f"[PRECON] {desc} loop {loop}/{loops} complete.")

# ----------------------------------------------------------------------------
# atexit: 确保脚本异常退出时也清理 FIO 子进程
# ----------------------------------------------------------------------------
def cleanup_fio():
    subprocess.run(["pkill", "-f", "fio.*--name="], stderr=subprocess.DEVNULL, check=False)
atexit.register(cleanup_fio)
signal.signal(signal.SIGINT, lambda s, f: sys.exit(0))
signal.signal(signal.SIGTERM, lambda s, f: sys.exit(0))

# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="NVMe FIO Test Engine v3.0")
    parser.add_argument("--base_dir", required=True)
    parser.add_argument("--raw_dir", required=True)
    parser.add_argument("--log_dir", required=True)
    parser.add_argument("--test_mode", required=True, choices=["single", "multi"])
    parser.add_argument("--server_model", default="Server")
    parser.add_argument("--runtime", type=int, default=300)
    parser.add_argument("--mix_runtime", type=int, default=1200)
    parser.add_argument("--mix_numjobs", type=int, default=4)
    parser.add_argument("--mix_iodepth", type=int, default=64)
    parser.add_argument("--seq_pre_loops", type=int, default=2)
    parser.add_argument("--rand_pre_loops", type=int, default=1)
    parser.add_argument("--do_seq_precon", default="yes")
    parser.add_argument("--do_rand_precon", default="yes")
    parser.add_argument("--run_seq_read", default="yes")
    parser.add_argument("--run_seq_write", default="yes")
    parser.add_argument("--run_rand_read", default="yes")
    parser.add_argument("--run_rand_write", default="yes")
    parser.add_argument("--run_mixed_rw", default="yes")
    parser.add_argument("--bs_list", default="4k 8k 16k 32k 64k 128k 256k 512k 1m")
    parser.add_argument("--enable_numa", default="yes")
    parser.add_argument("--numa_method", default="numactl")
    parser.add_argument("--numa_fallback", type=int, default=0)
    parser.add_argument("--devs", nargs="*", default=[])
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()

    devs = args.devs
    log_print(f"[INFO] Test mode: {args.test_mode} | Devices: {devs}")
    log_print(f"[INFO] Runtime per point: {args.runtime}s | Mixed RW runtime: {args.mix_runtime}s")

    bs_list = args.bs_list.split()

    # 收集驱动器信息
    drive_info_map = {}
    for dev in devs:
        info = get_drive_info(dev)
        drive_info_map[dev] = info
        log_print(f"[DRIVE] {dev}: model={info['model']} sn={info['serial']} fw={info['fw']}")

    # NUMA 映射
    numa_map = {}
    for dev in devs:
        node = get_numa_node(dev, args.numa_fallback)
        numa_map[dev] = {"enabled": args.enable_numa == "yes",
                          "node": node, "method": args.numa_method}
        log_print(f"[NUMA] {os.path.basename(dev)} -> node {node} (enabled={args.enable_numa})")

    # ---- 阶段 0: 格式化 ----
    if not args.resume:
        log_print("[STAGE] Starting drive format (Secure Erase)...")
        for dev in devs:
            if not format_drive(dev, args.base_dir):
                log_print(f"[CRITICAL] Failed to format {dev}. Aborting.")
                sys.exit(1)
        log_print("[STAGE] All drives formatted successfully.")

    # ---- 阶段 1: 顺序写预调教 ----
    if args.do_seq_precon == "yes" and not args.resume:
        run_preconditioning(devs, "128k", 1, 128, args.seq_pre_loops,
                           "write", "SEQ_WRITE_PRECON", numa_map)

    json_registry = []

    # ---- 阶段 2: 顺序读矩阵 ----
    if args.run_seq_read == "yes":
        log_print("[STAGE] Sequential Read Matrix")
        if args.test_mode == "single":
            for bs in bs_list:
                for nj in NUMJOBS_LIST:
                    for qd in IODEPTH_LIST:
                        label = f"SEQ_Read_{bs}_nj{nj}_qd{qd}"
                        json_files = execute_synchronized_parallel(
                            devs, "read", bs, nj, qd, args.runtime, None,
                            numa_map, args.raw_dir, label, args.resume)
                        json_registry.extend(json_files)
        else:
            for bs, nj, qd in SEQ_COMBOS:
                label = f"SEQ_Read_{bs}_nj{nj}_qd{qd}"
                json_files = execute_synchronized_parallel(
                    devs, "read", bs, nj, qd, args.runtime, None,
                    numa_map, args.raw_dir, label, args.resume)
                json_registry.extend(json_files)
        generate_excel(args, json_registry, "SeqRead", args.test_mode)

    # ---- 阶段 3: 顺序写矩阵 ----
    if args.run_seq_write == "yes":
        log_print("[STAGE] Sequential Write Matrix")
        seq_write_files = []
        if args.test_mode == "single":
            for bs in bs_list:
                for nj in NUMJOBS_LIST:
                    for qd in IODEPTH_LIST:
                        label = f"SEQ_Write_{bs}_nj{nj}_qd{qd}"
                        json_files = execute_synchronized_parallel(
                            devs, "write", bs, nj, qd, args.runtime, None,
                            numa_map, args.raw_dir, label, args.resume)
                        seq_write_files.extend(json_files)
        else:
            for bs, nj, qd in SEQ_COMBOS:
                label = f"SEQ_Write_{bs}_nj{nj}_qd{qd}"
                json_files = execute_synchronized_parallel(
                    devs, "write", bs, nj, qd, args.runtime, None,
                    numa_map, args.raw_dir, label, args.resume)
                seq_write_files.extend(json_files)
        json_registry.extend(seq_write_files)
        generate_excel(args, seq_write_files + [f for f in json_registry if 'SEQ_Write' in (f[0] or '')],
                       "SeqWrite", args.test_mode)

    # ---- 阶段 4: 随机写预调教 ----
    if args.do_rand_precon == "yes" and not args.resume:
        run_preconditioning(devs, "4k", 4, 128, args.rand_pre_loops,
                           "randwrite", "RAND_WRITE_PRECON", numa_map)

    # ---- 阶段 5: 随机读矩阵 ----
    if args.run_rand_read == "yes":
        log_print("[STAGE] Random Read Matrix")
        rand_read_files = []
        if args.test_mode == "single":
            for bs in bs_list:
                for nj in NUMJOBS_LIST:
                    for qd in IODEPTH_LIST:
                        label = f"RAND_Read_{bs}_nj{nj}_qd{qd}"
                        json_files = execute_synchronized_parallel(
                            devs, "randread", bs, nj, qd, args.runtime, None,
                            numa_map, args.raw_dir, label, args.resume)
                        rand_read_files.extend(json_files)
        else:
            for bs, nj, qd in RAND_COMBOS:
                label = f"RAND_Read_{bs}_nj{nj}_qd{qd}"
                json_files = execute_synchronized_parallel(
                    devs, "randread", bs, nj, qd, args.runtime, None,
                    numa_map, args.raw_dir, label, args.resume)
                rand_read_files.extend(json_files)
        json_registry.extend(rand_read_files)
        generate_excel(args, rand_read_files, "RandRead", args.test_mode)

    # ---- 阶段 6: 随机写矩阵 ----
    if args.run_rand_write == "yes":
        log_print("[STAGE] Random Write Matrix")
        rand_write_files = []
        if args.test_mode == "single":
            for bs in bs_list:
                for nj in NUMJOBS_LIST:
                    for qd in IODEPTH_LIST:
                        label = f"RAND_Write_{bs}_nj{nj}_qd{qd}"
                        json_files = execute_synchronized_parallel(
                            devs, "randwrite", bs, nj, qd, args.runtime, None,
                            numa_map, args.raw_dir, label, args.resume)
                        rand_write_files.extend(json_files)
        else:
            for bs, nj, qd in RAND_COMBOS:
                label = f"RAND_Write_{bs}_nj{nj}_qd{qd}"
                json_files = execute_synchronized_parallel(
                    devs, "randwrite", bs, nj, qd, args.runtime, None,
                    numa_map, args.raw_dir, label, args.resume)
                rand_write_files.extend(json_files)
        json_registry.extend(rand_write_files)
        generate_excel(args, rand_write_files, "RandWrite", args.test_mode)

    # ---- 阶段 7: 混合读写矩阵 ----
    if args.run_mixed_rw == "yes":
        log_print("[STAGE] Mixed Read/Write Matrix")
        mixed_bs = [b for b in ['4k', '8k', '16k', '32k'] if b in bs_list]
        mixed_files = []
        for bs in mixed_bs:
            for ratio in MIX_RATIO_LIST:
                label = f"MixedRW_{bs}_r{ratio}_w{100-ratio}_nj{args.mix_numjobs}_qd{args.mix_iodepth}"
                json_files = execute_synchronized_parallel(
                    devs, "randrw", bs, args.mix_numjobs, args.mix_iodepth,
                    args.mix_runtime, ratio, numa_map, args.raw_dir, label, args.resume,
                    parallel_timeout=args.mix_runtime + 600)
                mixed_files.extend(json_files)
        json_registry.extend(mixed_files)
        generate_excel(args, mixed_files, "MixedRW", args.test_mode)

    # ---- 最终全量报告 ----
    all_valid = [(p, d) for p, d in json_registry if p is not None]
    if all_valid:
        generate_excel(args, all_valid, "FULL", args.test_mode)
    else:
        log_print("[ERROR] Final dataset is empty. No Excel report generated.")

    log_print("[DONE] All test stages completed.")


if __name__ == "__main__":
    main()
PYEOF

chmod +x "$PYTHON_ENGINE"

# ============================================================================
#[ 执行 Python 测试引擎 ]
# ============================================================================

echo "[INFO] Starting Python FIO test engine..."

# Disable errexit before Python call so post-test diagnostics always run
set +e
python3 "$PYTHON_ENGINE" \
    --base_dir "$BASE_DIR" \
    --raw_dir "$RAW_DIR" \
    --log_dir "$LOG_DIR" \
    --test_mode "$TEST_MODE" \
    --server_model "$SERVER_MODEL" \
    --runtime "$RUNTIME" \
    --mix_runtime "$MIX_RUNTIME" \
    --mix_numjobs "$MIX_NUMJOBS" \
    --mix_iodepth "$MIX_IODEPTH" \
    --seq_pre_loops "$SEQ_PRE_LOOPS" \
    --rand_pre_loops "$RAND_PRE_LOOPS" \
    --do_seq_precon "$DO_SEQ_PRECON" \
    --do_rand_precon "$DO_RAND_PRECON" \
    --run_seq_read "$RUN_SEQ_READ" \
    --run_seq_write "$RUN_SEQ_WRITE" \
    --run_rand_read "$RUN_RAND_READ" \
    --run_rand_write "$RUN_RAND_WRITE" \
    --run_mixed_rw "$RUN_MIXED_RW" \
    --bs_list "$TEST_BS_LIST" \
    --enable_numa "$ENABLE_NUMA_BIND" \
    --numa_method "$NUMA_BIND_METHOD" \
    --numa_fallback "$NUMA_FALLBACK_NODE" \
    --devs "${TARGET_DEVS[@]}" \
    $RESUME_FLAG

PYTHON_EXIT_CODE=$?

# ============================================================================
#[ 测试后诊断采集 ]
# ============================================================================

echo ""
echo "[INFO] Collecting post-test diagnostics..."

for dev in "${TARGET_DEVS[@]}"; do
    dev_tag=$(basename "$dev")
    nvme smart-log "$dev" > "$LOG_DIR/post_smart_${dev_tag}.log" 2>/dev/null || \
        echo "[WARNING] Failed to collect post-test SMART log for $dev." > "$LOG_DIR/post_smart_${dev_tag}.log"
done

if ! dmesg -T > "$LOG_DIR/post_dmesg.log" 2>/dev/null; then
    echo "[WARNING] dmesg -T not supported. Falling back to dmesg without timestamps."
    dmesg > "$LOG_DIR/post_dmesg.log" 2>/dev/null || \
        echo "[WARNING] dmesg collection failed." > "$LOG_DIR/post_dmesg.log"
fi

# PCIe AER 异常扫描 -- 检测 PCIe 总线级别的传输错误
echo "[INFO] Scanning for PCIe AER anomalies..."
anomaly_log="${LOG_DIR}/pcie_aer_anomaly_scan.log"
dmesg_log="${LOG_DIR}/pre_dmesg.log"
if [[ -f "$dmesg_log" ]]; then
    err_count=$(grep -iE 'pcieport.*error|aer.*error|pcie bus error' "$dmesg_log" 2>/dev/null | wc -l)
    warn_count=$(grep -iE 'corrected error|replay timer|receiver error|bad tlp|bad dllp|poisoned tlp|completer abort|unexpected completion|surprise down' "$dmesg_log" 2>/dev/null | wc -l)
    {
        echo "PCIe AER Anomaly Scan Report"
        echo "=============================="
        echo "PCIe Errors (severe): $err_count"
        echo "PCIe Warnings (corrected): $warn_count"
        echo ""
        echo "--- Error Details ---"
        grep -iE 'pcieport.*error|aer.*error|pcie bus error' "$dmesg_log" 2>/dev/null || echo "None found."
        echo ""
        echo "--- Warning Details ---"
        grep -iE 'corrected error|replay timer|receiver error|bad tlp|bad dllp|poisoned tlp|completer abort|unexpected completion|surprise down' "$dmesg_log" 2>/dev/null || echo "None found."
        echo ""
    } > "$anomaly_log"
    echo "[INFO] PCIe AER scan complete. Errors: $err_count, Warnings: $warn_count"
else
    echo "[WARNING] pre_dmesg.log not found. Skipping anomaly scan."
fi

# 收集 IPMI SEL (System Event Log) -- 硬件级别事件记录，BMC 独立于操作系统
if command -v ipmitool >/dev/null 2>&1; then
    echo "[INFO] Collecting IPMI SEL (System Event Log)..."
    ipmitool sel list > "$LOG_DIR/ipmi_sel.log" 2>/dev/null || \
        echo "[WARNING] ipmitool sel list failed. Check BMC connectivity." > "$LOG_DIR/ipmi_sel.log"
else
    echo "[INFO] ipmitool not found. Skipping IPMI SEL collection."
fi

# ============================================================================
#[ 测试完成汇总 ]
# ============================================================================

echo ""
echo "========================================================================"
echo "  NVMe Cloud Qualification Suite -- v3.0 -- Completed"
echo "========================================================================"
echo "  Workspace       : $BASE_DIR"
echo "  Raw data        : $RAW_DIR"
echo "  Logs            : $LOG_DIR"
echo "  Python exit     : $PYTHON_EXIT_CODE"
echo "========================================================================"

exit $PYTHON_EXIT_CODE
