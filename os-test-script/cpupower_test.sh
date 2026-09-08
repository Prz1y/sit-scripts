#!/usr/bin/env bash
set -euo pipefail

# 脚本所在目录（即日志根目录的父目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_ROOT="${SCRIPT_DIR}/cpupower_results"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

DURATION=10
STRESS=false

usage() {
  cat <<EOF
Usage: $0 [--duration 秒] [--stress]

--duration 秒    : 压力测试持续时长，默认 ${DURATION}s
--stress         : 在每个调度器测试时运行短时CPU繁忙负载以观察频率变化

脚本会按顺序测试：ondemand, conservative, performance, userspace, powersave
需要 root 权限或使用 sudo 运行 cpupower 命令。
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --duration)
      [[ $# -gt 1 ]] || { echo "错误：--duration 需要一个参数" >&2; exit 1; }
      [[ "$2" =~ ^[1-9][0-9]*$ ]] || { echo "错误：--duration 必须为正整数，得到: $2" >&2; exit 1; }
      DURATION="$2"; shift 2;;
    --stress) STRESS=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

# 检查 cpupower 是否存在（不存在时降级为直接写 /sys）
if ! command -v cpupower >/dev/null 2>&1; then
  echo "警告：未检测到 cpupower，将降级为直接写 /sys/devices/system/cpu/*/cpufreq/scaling_governor。"
  echo "建议安装 cpupower（通常在 linux-tools 或 cpufrequtils 软件包中）并以 root 执行。"
fi

# 检查 stress 是否存在（不存在时降级为 bash busy-loop）
HAS_STRESS=false
if command -v stress >/dev/null 2>&1; then
  HAS_STRESS=true
else
  echo "提示：未检测到 stress，压力测试将使用 bash busy-loop 代替（效率低，无法达到100% CPU）。"
  echo "建议安装 stress（apt install stress 或 yum install stress）以获得更准确的负载。"
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "错误：此脚本需要 root 权限来设置 CPU governor 和读取 cpufreq 接口。" >&2
  echo "请以 root 身份运行，或使用: sudo $0" >&2
  exit 1
fi

# 创建结果目录（每个 governor 一个子目录）
for _g in ondemand conservative performance userspace powersave; do
  mkdir -p "${RESULT_ROOT}/${_g}"
done
echo "测试记录将保存至: ${RESULT_ROOT}"

# 预检：确认 cpufreq 子系统可用
if [ ! -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
  echo "提示：未找到 cpufreq 接口，尝试加载驱动..."
  modprobe acpi-cpufreq 2>/dev/null || modprobe intel_pstate 2>/dev/null || true
  sleep 1
fi
if [ ! -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
  echo "错误：此系统不支持 cpufreq 频率调节，或驱动未加载。" >&2
  echo "可能原因：" >&2
  echo "  1. 这是虚拟机且宿主机未向 guest 暴露 cpufreq 接口" >&2
  echo "  2. 请尝试：modprobe acpi-cpufreq  或  modprobe intel_pstate" >&2
  echo "  3. 该平台（如部分 ARM/RISC-V 板）本身不支持软件调频" >&2
  exit 3
fi

# 目标调度器及说明
declare -A DESC
DESC[ondemand]="按需响应模式：有计算量立即升频，空闲回落最低"
DESC[conservative]="保守模式：随着负荷逐步提升频率，再逐步下降"
DESC[performance]="高性能模式：固定最高频，不动态调节，耗电最大"
DESC[userspace]="用户空间模式：允许用户态程序控制频率（通常不建议，且需额外设定目标频率）"
DESC[powersave]="省电模式：固定最低频，节能但性能低"

GOVS=(ondemand conservative performance userspace powersave)

# 记录并备份现有第0核调度器，以便恢复
ORIG_GOV=""
if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
  ORIG_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)
fi

restore() {
  if [ -n "$ORIG_GOV" ]; then
    echo "恢复原始 governor: $ORIG_GOV"
    if command -v cpupower >/dev/null 2>&1; then
      if [ "$(id -u)" -eq 0 ]; then
        cpupower frequency-set -g "$ORIG_GOV" || true
      else
        sudo cpupower frequency-set -g "$ORIG_GOV" || true
      fi
    else
      for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "$ORIG_GOV" > "$f" 2>/dev/null || true
      done
    fi
  fi
}
# 注意：trap EXIT 不响应 SIGKILL(kill -9)，
# 如果脚本被 force kill，governor 不会自动恢复，需手动重置
trap restore EXIT

cpu_count() {
  nproc --all 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1
}

cpu_stress() {
  local dur="$1"
  local gov_name="${2:-}"
  local sample_dur
  sample_dur=$(( dur * 3 ))
  local n
  n=$(cpu_count)
  echo "--- 压力测试开始（governor: ${gov_name}，压力时长: ${dur}s，采样时长: ${sample_dur}s，CPU 线程: $n）---"

  # 启动压力负载
  local STRESS_PIDS=()
  if [ "$HAS_STRESS" = true ]; then
    echo "工具: stress --cpu $n --timeout ${dur}s"
    stress --cpu "$n" --timeout "${dur}s" >/dev/null 2>&1 &
    STRESS_PIDS+=("$!")
  else
    echo "工具: bash busy-loop（$n 线程）"
    for _ in $(seq 1 "$n"); do
      ( while :; do :; done ) &
      STRESS_PIDS+=("$!")
    done
  fi

  # 逐秒采样 cpu0 实时频率，采样时长完整覆盖压力+冷却阶段
  local SAMPLES=()
  local elapsed=0
  local khz mhz
  echo "实时频率采样（cpu0，每秒一次，共 ${sample_dur}s）："
  while [ "$elapsed" -lt "$sample_dur" ]; do
    khz=0
    if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
      khz=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)
    fi
    mhz=$(( khz / 1000 ))
    if [ "$elapsed" -lt "$dur" ]; then
      printf "  [%3ds/压力中] %d MHz\n" "$elapsed" "$mhz"
    else
      printf "  [%3ds/冷却中] %d MHz\n" "$elapsed" "$mhz"
    fi
    SAMPLES+=("$khz")
    sleep 1
    elapsed=$(( elapsed + 1 ))
    # busy-loop 模式：到达压力时长时精确 kill（stress 工具自行 --timeout 退出）
    if [ "$elapsed" -eq "$dur" ] && [ "$HAS_STRESS" = false ]; then
      local _p
      for _p in "${STRESS_PIDS[@]}"; do kill "$_p" 2>/dev/null || true; done
    fi
  done

  # 清理剩余压力进程
  local p
  for p in "${STRESS_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  if [ "${#STRESS_PIDS[@]}" -gt 0 ]; then
    wait "${STRESS_PIDS[@]}" 2>/dev/null || true
  fi

  # 频率统计：最小 / 最大 / 平均
  if [ "${#SAMPLES[@]}" -gt 0 ]; then
    local min_k max_k sum_k count avg_k s
    min_k=${SAMPLES[0]}; max_k=${SAMPLES[0]}; sum_k=0
    count=${#SAMPLES[@]}
    for s in "${SAMPLES[@]}"; do
      if [ "$s" -lt "$min_k" ]; then min_k=$s; fi
      if [ "$s" -gt "$max_k" ]; then max_k=$s; fi
      sum_k=$(( sum_k + s ))
    done
    avg_k=$(( sum_k / count ))
    echo "--- 频率统计（$count 次采样）---"
    printf "  最小: %d MHz\n" "$(( min_k / 1000 ))"
    printf "  最大: %d MHz\n" "$(( max_k / 1000 ))"
    printf "  平均: %d MHz\n" "$(( avg_k / 1000 ))"
  fi
  echo "--- 压力测试结束 ---"
}

available=""
if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]; then
  available=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || true)
fi

echo "可用 governor: ${available:-(unknown)}"

if [ -z "$available" ]; then
  echo "错误：无法读取可用 governor 列表（scaling_available_governors 为空）。" >&2
  echo "请确认 cpufreq 驱动已正确加载（cpupower frequency-info 查看详情）。" >&2
  exit 3
fi

# 输出 lscpu 一次，保存至系统信息文件
SYSINFO_FILE="${RESULT_ROOT}/system_info_${TIMESTAMP}.txt"
{
  echo "========================================"
  echo "测试时间: $(date)"
  echo "内核版本: $(uname -r)"
  echo "======== lscpu 输出 ========"
  lscpu 2>/dev/null || echo "（lscpu 不可用）"
  echo "========================================"
} | tee "$SYSINFO_FILE"
echo "系统信息已保存至: $SYSINFO_FILE"

for gov in "${GOVS[@]}"; do
  if [[ -n "$available" && ! " $available " =~ [[:space:]]${gov}[[:space:]] ]]; then
    echo "跳过 $gov（不可用）"
    continue
  fi

  LOG_FILE="${RESULT_ROOT}/${gov}/${TIMESTAMP}.log"

  # --- 设置 governor（在 tee 块外，continue 才能生效）---
  echo "========================" | tee -a "$LOG_FILE"
  echo "测试 governor: $gov" | tee -a "$LOG_FILE"
  echo "说明: ${DESC[$gov]}" | tee -a "$LOG_FILE"
  echo "测试时间: $(date)" | tee -a "$LOG_FILE"
  echo "内核版本: $(uname -r)" | tee -a "$LOG_FILE"
  echo "应用中..." | tee -a "$LOG_FILE"
  if command -v cpupower >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
      cpupower frequency-set -g "$gov" 2>&1 | tee -a "$LOG_FILE" || true
    else
      sudo cpupower frequency-set -g "$gov" 2>&1 | tee -a "$LOG_FILE" || true
    fi
  else
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      echo "$gov" > "$f" 2>/dev/null || true
    done
  fi

  # 校验是否生效（在外层循环中，continue 有效）
  ACTUAL_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)
  if [ "$ACTUAL_GOV" != "$gov" ]; then
    MSG="警告：governor 设置失败（期望 $gov，实际 ${ACTUAL_GOV:-未知}），跳过本轮测试。"
    echo "$MSG" | tee -a "$LOG_FILE"
    echo "--- $gov 测试跳过（设置失败）---" | tee -a "$LOG_FILE"
    echo
    continue
  fi

  {
    # userspace 模式需额外指定频率，否则频率状态不确定
    if [ "$gov" = "userspace" ]; then
      MAX_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || true)
      if [ -n "$MAX_FREQ" ]; then
        echo "userspace 模式：将频率固定至最大值 ${MAX_FREQ} KHz"
        if command -v cpupower >/dev/null 2>&1; then
          if [ "$(id -u)" -eq 0 ]; then
            cpupower frequency-set -f "${MAX_FREQ}" || true
          else
            sudo cpupower frequency-set -f "${MAX_FREQ}" || true
          fi
        else
          for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_setspeed; do
            echo "$MAX_FREQ" > "$f" 2>/dev/null || true
          done
        fi
      else
        echo "警告：无法获取最大频率，userspace 模式下频率状态不确定"
      fi
    fi
    sleep 1

    echo "当前每核 governor (示例):"
    grep -H . /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sed -n '1,5p' || echo "（无法读取 /sys cpufreq 信息）"

    if [ "$STRESS" = true ]; then
      cpu_stress "$DURATION" "$gov"
    else
      echo "未启用压力测试，等待 2s 以便观察默认行为"
      sleep 2
    fi

    if command -v cpupower >/dev/null 2>&1; then
      echo "频率信息（cpu0 示例）:"
      cpupower frequency-info 2>/dev/null | sed -n '1,10p' || true
    else
      echo "检查 /sys 获取频率（cpu0）:"
      if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
        awk '{print $1/1000 " MHz"}' /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || true
      fi
    fi
    echo "--- $gov 测试结束 ---"
  } 2>&1 | tee -a "$LOG_FILE"
  echo
done

echo
echo "测试完成，退出时将尝试恢复原始 governor。"
exit 0
