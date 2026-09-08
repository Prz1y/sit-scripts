#!/usr/bin/env bash
# stress 一小时测试脚本：运行 stress 1h，保留 BMC 日志和系统日志，并写入测试记录
# 用法: sudo ./stress_test_1h.sh

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="${SCRIPT_DIR}/stress-test-${TIMESTAMP}"
RECORD_FILE="${OUTDIR}/test_record.txt"
CHECK_INTERVAL=60
STRESS_SECONDS=3600
STRESS_TIMEOUT="${STRESS_SECONDS}s"
RECORD_SAVED=0

mkdir -p "${OUTDIR}" || { echo "无法创建输出目录 ${OUTDIR}"; exit 1; }

log() { echo "[$(date +'%F %T')] $*"; }

collect_bmc_logs() {
	if command -v ipmitool >/dev/null 2>&1; then
		log "收集 BMC: mc info"
		ipmitool mc info > "${OUTDIR}/bmc_mc_info.txt" 2>&1 || true
		log "收集 BMC: SEL list"
		ipmitool sel list > "${OUTDIR}/bmc_sel_list.txt" 2>&1 || true
		ipmitool sel elist > "${OUTDIR}/bmc_sel_elist.txt" 2>&1 || true
	else
		echo "ipmitool not found; 跳过 BMC 日志收集" > "${OUTDIR}/bmc_missing.txt"
	fi
}

collect_system_logs() {
	log "收集 dmesg"
	dmesg -T > "${OUTDIR}/dmesg.txt" 2>&1 || true
	log "收集 journalctl (本次启动)"
	journalctl -b --no-pager > "${OUTDIR}/journalctl_boot.txt" 2>&1 || true
	[ -f /var/log/messages ] && cp -a /var/log/messages "${OUTDIR}/messages" || true
	[ -f /var/log/syslog ] && cp -a /var/log/syslog "${OUTDIR}/syslog" || true
	[ -f /var/log/kern.log ] && cp -a /var/log/kern.log "${OUTDIR}/kern.log" || true
}

save_record() {
	if [ "$RECORD_SAVED" -eq 1 ]; then
		return 0
	fi
	RECORD_SAVED=1
	local status="$1"; shift
	local msg="$*"
	echo "timestamp=${TIMESTAMP}" >> "${RECORD_FILE}"
	echo "result=${status}" >> "${RECORD_FILE}"
	echo "note=${msg}" >> "${RECORD_FILE}"
	echo "logs_dir=${OUTDIR}" >> "${RECORD_FILE}"
	echo "" >> "${RECORD_FILE}"
}

on_exit_collect() {
	local reason="$1"
	log "触发日志收集: ${reason}"
	collect_system_logs
	collect_bmc_logs
	save_record "FAIL" "异常终止: ${reason}"
	log "日志已保存至 ${OUTDIR}"
}

trap 'on_exit_collect "SIGINT/SIGTERM/Caught"' INT TERM

log "测试开始，输出目录: ${OUTDIR}"
echo "start_time=$(date +%F_%T)" > "${RECORD_FILE}"

if ! command -v stress >/dev/null 2>&1; then
	echo "请先安装 stress，Debian/Ubuntu: apt install stress" > "${OUTDIR}/error_install_stress.txt"
	save_record "FAIL" "缺少 stress"
	exit 1
fi

# 检查 stress --hdd 的工作目录是否在 tmpfs 上；tmpfs 不产生真实磁盘 I/O
HDD_WORK_DIR="."
hdd_fstype=$(df -T "$HDD_WORK_DIR" 2>/dev/null | awk 'NR==2 {print $2}')
if [ "$hdd_fstype" = "tmpfs" ]; then
	log "警告: 当前工作目录($HDD_WORK_DIR)文件系统为 tmpfs"
	log "stress --hdd 在 tmpfs 上不产生真实磁盘 I/O，测试无效"
	log "切换到有真实磁盘的目录执行本脚本，例如 cd /tmp/test_dir && bash $0"
	save_record "FAIL" "工作目录为 tmpfs，--hdd 测试无效"
	exit 1
fi

log "启动 stress，持续时间 1小时"
stress --cpu "$(nproc)" --io 4 --vm 2 --vm-bytes 128M --hdd 2 --hdd-bytes 1G --timeout "$STRESS_TIMEOUT" --verbose > "${OUTDIR}/stress_out.txt" 2>&1 &
STRESS_PID=$!

log "stress PID=${STRESS_PID}"

# 监控循环：每 CHECK_INTERVAL 秒检查本机响应与收集快照日志
SECONDS_BEFORE=$(awk '{print $1}' /proc/uptime)
end_time=$(( $(date +%s) + STRESS_SECONDS ))
failed=0

while kill -0 "${STRESS_PID}" 2>/dev/null; do
	sleep "${CHECK_INTERVAL}"

	# 健康检查：whoami 可能因瞬时 fork 失败而返回错误
	# 高负载下 fork 失败不代表系统无响应，重试 3 次再判定
	whoami_ok=0
	for _ in 1 2 3; do
		if whoami >/dev/null 2>&1; then
			whoami_ok=1
			break
		fi
		sleep 2
	done
	if [ "$whoami_ok" -eq 0 ]; then
		failed=1
		on_exit_collect "3次whoami均失败，可能系统无响应"
		break
	fi

	SECONDS_NOW=$(awk '{print $1}' /proc/uptime 2>/dev/null)
	if [ -z "${SECONDS_NOW}" ]; then
		failed=1
		on_exit_collect "无法读取 /proc/uptime"
		break
	fi

	if command -v bc >/dev/null 2>&1; then
		diff=$(echo "${SECONDS_NOW} - ${SECONDS_BEFORE}" | bc)
		if [ "$(echo "${diff} < 30" | bc)" -eq 1 ]; then
			log "警告: /proc/uptime 增长缓慢(${diff}s)，记录快照"
			collect_system_logs
			collect_bmc_logs
		fi
	else
		diff_int=$(( ${SECONDS_NOW%.*} - ${SECONDS_BEFORE%.*} ))
		if [ "${diff_int}" -lt 30 ]; then
			log "警告: /proc/uptime 增长缓慢(${diff_int}s)，记录快照"
			collect_system_logs
			collect_bmc_logs
		fi
	fi

	dmesg -T 2>/dev/null | tail -n 200 > "${OUTDIR}/dmesg_snapshot_$(date +%Y%m%d_%H%M%S).txt" 2>&1 || true
	SECONDS_BEFORE="${SECONDS_NOW}"
	if [ "$(date +%s)" -ge "${end_time}" ]; then
		log "达到预定测试时长"
		break
	fi
done

STRESS_EXIT=0
if kill -0 "${STRESS_PID}" 2>/dev/null; then
	set +e
	wait "${STRESS_PID}"
	STRESS_EXIT=$?
	set -e
fi

if [ "${failed}" -eq 1 ] || [ "${STRESS_EXIT}" -ne 0 ]; then
	log "检测到失败 (stress exit: ${STRESS_EXIT})"
	echo "end_time=$(date +%F_%T)" >> "${RECORD_FILE}"
	exit 1
fi

log "测试完成，收集最终日志"
collect_system_logs
collect_bmc_logs
save_record "PASS" "1小时压力测试完成，无检测到死机/宕机（按脚本检查）"
echo "end_time=$(date +%F_%T)" >> "${RECORD_FILE}"
log "测试记录已写入 ${RECORD_FILE}"
log "全部日志保存在 ${OUTDIR}"
