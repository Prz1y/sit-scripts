#!/bin/bash
#
# WARNING:
#   This script may modify block devices, create partitions, run mkfs, disable
#   swap, clear/backup logs, and generate sustained CPU/memory/IO pressure.
#   SYSTEM_DISKS must be configured explicitly; FIO_DISKS may be wiped.
#   Run it only on RD/lab machines where data loss and service interruption are acceptable.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/mixed_pressure_7x24_logs"
START_FLAG="${LOG_DIR}/.test_running"
START_TIME_FILE="${LOG_DIR}/pressure_start_time.log"
END_TIME_FILE="${LOG_DIR}/pressure_end_time.log"

PID_STRESS="${LOG_DIR}/.pid_stress"
PID_STRESS_VM="${LOG_DIR}/.pid_stress_vm"
PID_FIO_LIST="${LOG_DIR}/.pid_fio_list"
PID_OS_MEM_MON="${LOG_DIR}/.pid_os_mem_mon"
PID_IPMI_MON="${LOG_DIR}/.pid_ipmi_mon"
PID_GUARDIAN="${LOG_DIR}/.pid_guardian"
PID_CPU_FREQ_MON="${LOG_DIR}/.pid_cpu_freq_mon"
PID_MEM_BW_MON="${LOG_DIR}/.pid_mem_bw_mon"
PID_DMESG_MON="${LOG_DIR}/.pid_dmesg_mon"
STOPPING_FLAG="${LOG_DIR}/.stopping"
OP_LOCK_DIR="${LOG_DIR}/.operation.lock"

TOTAL_DURATION_SEC=$(( 168 * 3600 ))
FIO_STEADY_WAIT=45
CSV_MON_INTERVAL=10
IPMI_MON_INTERVAL=600
CPU_TARGET_PCT=95
MEM_TARGET_PCT=90
FIO_MOUNT_BASE="/mnt/fio_pressure"

MEM_BASELINE_LOG="${LOG_DIR}/mem_baseline.log"
PMON_CSV="${LOG_DIR}/perf_monitor.csv"
CPU_FREQ_CSV="${LOG_DIR}/cpu_freq_monitor.csv"
MEM_BW_CSV="${LOG_DIR}/mem_bw_monitor.csv"
REPORT_FILE="${LOG_DIR}/pressure_performance_report.txt"

CONF_FILE="${SCRIPT_DIR}/mixed_pressure.conf"

SWAP_ORIG_FILE="${LOG_DIR}/.swap_original"
FIO_MOUNT_LIST_FILE="${LOG_DIR}/.fio_mount_points"
FIO_START_TS_FILE="${LOG_DIR}/.fio_start_ts"
FIO_RESULT_PREFIX="${LOG_DIR}/fio_result_"
FIO_RESULT_LIST_FILE="${LOG_DIR}/.fio_result_files"
FIO_MOUNT_PENDING_FILE="${LOG_DIR}/.fio_mount_pending"
DMESG_SNAPSHOT_LIST_FILE="${LOG_DIR}/.dmesg_snapshot_files"
DMESG_STATUS_FILE="${LOG_DIR}/.dmesg_status"
JOURNAL_STATUS_FILE="${LOG_DIR}/.journalctl_status"
RUN_START_TS_FILE="${LOG_DIR}/.run_start_timestamp"
CLEANUP_FAILED_FLAG="${LOG_DIR}/.cleanup_failed"

__STOPPING=0
__OP_LOCK_HELD=0

echo "[WARN] mixed_pressure_7x24.sh may repartition/format test disks, disable swap, and clear or overwrite logs. Use only on RD/lab machines." >&2

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_info()  { log "[INFO]  $*"; }
log_warn()  { log "[WARN]  $*"; }
log_error() { log "[ERROR] $*"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用 root 权限执行此脚本"
        exit 1
    fi
}

load_config() {
    CPU_TARGET_PCT=95
    MEM_TARGET_PCT=90
    MEM_TOOL="stress-ng"
    SYSTEM_DISKS=""
    FIO_DISKS=""
    FIO_FILE_SIZE_MB=10240
    FIO_FILE_NUMJOBS=1
    CSV_MON_INTERVAL=10
    IPMI_MON_INTERVAL=600
    MEM_ACCESS_MODE="all"
    FIO_REQUIRED_VERSION="3.13"
    FIO_VERSION_STRICT=true
    CPU_THROTTLE_PCT=90
    MEM_BW_MON="auto"
    DMESG_SNAP_INTERVAL=1800
    LOG_CLEANUP_MODE="backup"
    SYSTEM_LOG_ACTION="backup"
    ALLOW_AUTO_PREPARE=false
    ALLOW_EXISTING_FS=false

    if [ -f "$CONF_FILE" ]; then
        log_info "加载配置文件: ${CONF_FILE}"
        # shellcheck source=/dev/null
        source "$CONF_FILE"
    fi

    [ -n "${TOTAL_DURATION_SEC:-}" ] || TOTAL_DURATION_SEC=$(( 168 * 3600 ))
    [ -n "${FIO_STEADY_WAIT:-}" ] || FIO_STEADY_WAIT=45
    [ -n "${CSV_MON_INTERVAL:-}" ] || CSV_MON_INTERVAL=10
    [ -n "${IPMI_MON_INTERVAL:-}" ] || IPMI_MON_INTERVAL=600
    [ -n "${DMESG_SNAP_INTERVAL:-}" ] || DMESG_SNAP_INTERVAL=1800
    [ -n "${CPU_TARGET_PCT:-}" ] || CPU_TARGET_PCT=95
    [ -n "${MEM_TARGET_PCT:-}" ] || MEM_TARGET_PCT=90
    [ -n "${FIO_MOUNT_BASE:-}" ] || FIO_MOUNT_BASE="/mnt/fio_pressure"
}

proc_start_time() {
    local pid="$1"
    [ -r "/proc/${pid}/stat" ] || return 1
    sed 's/^[^)]*) //' "/proc/${pid}/stat" 2>/dev/null | awk '{print $20}'
}

proc_state() {
    local pid="$1"
    [ -r "/proc/${pid}/stat" ] || return 1
    sed 's/^[^)]*) //' "/proc/${pid}/stat" 2>/dev/null | awk '{print $1}'
}

proc_parent() {
    local pid="$1"
    [ -r "/proc/${pid}/stat" ] || return 1
    sed 's/^[^)]*) //' "/proc/${pid}/stat" 2>/dev/null | awk '{print $2}'
}

write_pid_record() {
    local file="$1" pid="$2" start
    start=$(proc_start_time "$pid") || return 1
    printf '%s %s\n' "$pid" "$start" > "${file}.tmp" || return 1
    mv -f "${file}.tmp" "$file"
}

append_pid_record() {
    local file="$1" pid="$2" start
    start=$(proc_start_time "$pid") || return 1
    if [ -e "$file" ]; then
        cat "$file" > "${file}.tmp" 2>/dev/null || return 1
    else
        : > "${file}.tmp" || return 1
    fi
    printf '%s %s\n' "$pid" "$start" >> "${file}.tmp" || return 1
    mv -f "${file}.tmp" "$file"
}

pid_line_matches() {
    local pid="$1" expected_start="$2" current_start
    current_start=$(proc_start_time "$pid" 2>/dev/null || true)
    [ -n "$expected_start" ] && [ "$expected_start" = "$current_start" ] \
        && [ "$(proc_state "$pid" 2>/dev/null || true)" != "Z" ] \
        && kill -0 "$pid" 2>/dev/null
}

pid_record_matches() {
    local file="$1" pid="$2" expected_start current_start
    [ -r "$file" ] || return 1
    expected_start=$(awk 'NF {print $2; exit}' "$file")
    current_start=$(proc_start_time "$pid" 2>/dev/null || true)
    [ -n "$expected_start" ] && [ "$expected_start" = "$current_start" ] \
        && [ "$(proc_state "$pid" 2>/dev/null || true)" != "Z" ]
}

pid_record_identity_matches() {
    local file="$1" pid="$2" expected_start current_start
    [ -r "$file" ] || return 1
    expected_start=$(awk 'NF {print $2; exit}' "$file")
    current_start=$(proc_start_time "$pid" 2>/dev/null || true)
    [ -n "$expected_start" ] && [ "$expected_start" = "$current_start" ]
}

pid_is_expected() {
    local file="$1" pid="$2"
    pid_record_matches "$file" "$pid" || return 1
    kill -0 "$pid" 2>/dev/null
}

terminate_pid_tree() {
    local pid="$1" signal="${2:-TERM}" expected_record="${3:-}" child child_parent
    if [ -n "$expected_record" ] && ! pid_record_matches "$expected_record" "$pid"; then
        return 0
    fi
    [ -d "/proc/${pid}" ] || return 0
    while read -r child; do
        [ -n "$child" ] || continue
        child_parent=$(proc_parent "$child" 2>/dev/null || true)
        [ "$child_parent" = "$pid" ] || continue
        terminate_pid_tree "$child" "$signal"
    done < <(pgrep -P "$pid" 2>/dev/null || true)
    if [ -n "$expected_record" ] && ! pid_record_matches "$expected_record" "$pid"; then
        return 0
    fi
    kill -"$signal" "$pid" 2>/dev/null || true
}

collect_pid_tree_records() {
    local pid="$1" child
    local start
    start=$(proc_start_time "$pid" 2>/dev/null || true)
    [ -n "$start" ] || return 0
    printf '%s %s\n' "$pid" "$start"
    while read -r child; do
        [ -n "$child" ] || continue
        collect_pid_tree_records "$child"
    done < <(pgrep -P "$pid" 2>/dev/null || true)
}

terminate_pid_by_start() {
    local pid="$1" expected_start="$2" signal="${3:-TERM}" child child_start
    local current_start
    current_start=$(proc_start_time "$pid" 2>/dev/null || true)
    [ "$current_start" = "$expected_start" ] || return 0
    [ "$(proc_state "$pid" 2>/dev/null || true)" != "Z" ] || return 0
    while read -r child; do
        [ -n "$child" ] || continue
        child_start=$(proc_start_time "$child" 2>/dev/null || true)
        [ -n "$child_start" ] && terminate_pid_by_start "$child" "$child_start" "$signal"
    done < <(pgrep -P "$pid" 2>/dev/null || true)
    current_start=$(proc_start_time "$pid" 2>/dev/null || true)
    [ "$current_start" = "$expected_start" ] || return 0
    kill -"$signal" "$pid" 2>/dev/null || true
}

stop_pid_records() {
    local list_file="$1" pid_prefix="$2" label="$3" delay="${4:-1}"
    local pid start record pids="" tree_records="" cleanup_failed=0
    [ -f "$list_file" ] || return 0

    while read -r pid start; do
        [ -n "$pid" ] || continue
        record="$list_file"
        [ -n "$pid_prefix" ] && record="${pid_prefix}${pid}"
        if ! pid_record_identity_matches "$record" "$pid"; then
            if kill -0 "$pid" 2>/dev/null; then
                log_error "${label} PID 记录缺失或已失效，拒绝猜测性终止: ${pid}"
                cleanup_failed=1
            fi
            continue
        fi
        if pid_record_matches "$record" "$pid"; then
            tree_records="${tree_records}$(collect_pid_tree_records "$pid")"
            tree_records="${tree_records}"$'\n'
            terminate_pid_tree "$pid" TERM "$record"
            pids="${pids} ${pid}"
        fi
    done < "$list_file"

    if [ -n "$pids" ]; then
        sleep "$delay"
        local kill_grace=0
        while read -r tree_pid tree_start; do
            [ -n "$tree_pid" ] || continue
            terminate_pid_by_start "$tree_pid" "$tree_start" KILL
            kill_grace=0
            while [ "$kill_grace" -lt 10 ] && pid_line_matches "$tree_pid" "$tree_start"; do
                sleep 1
                kill_grace=$(( kill_grace + 1 ))
            done
            if pid_line_matches "$tree_pid" "$tree_start"; then
                log_error "${label} 进程树在 TERM/KILL 后仍存活: ${tree_pid}"
                cleanup_failed=1
            fi
        done <<< "$tree_records"
        for pid in $pids; do
            log_info "  ${label} (PID: ${pid}) 已停止"
        done
    fi
    return "$cleanup_failed"
}

record_planned_fio_results() {
    has_valid_timestamp "${LOG_DIR}/.start_timestamp" || return 0
    [ -s "$FIO_RESULT_LIST_FILE" ] || return 0
    local result_file
    while IFS= read -r result_file; do
        [ -n "$result_file" ] || continue
        if [ -f "$result_file" ]; then
            local result_reason
            result_reason=$(awk -F= '$1=="stop_reason"{print $2; exit}' "$result_file")
            if [ -z "$result_reason" ]; then
                if ! { cat "$result_file"; printf '\nstop_reason=planned_stop\n'; } > "${result_file}.tmp" || ! mv -f "${result_file}.tmp" "$result_file"; then
                    log_error "计划停止 fio 结果状态写入失败: ${result_file}"
                    return 1
                fi
            fi
            continue
        fi
        if ! printf 'result_status=planned_stop_without_exit_record\nstop_reason=planned_stop\nend_timestamp=%s\n' "$(date '+%s')" > "${result_file}.tmp" || ! mv -f "${result_file}.tmp" "$result_file"; then
            log_error "计划停止 fio 结果写入失败: ${result_file}"
            return 1
        fi
    done < "$FIO_RESULT_LIST_FILE"
}

write_state_file() {
    local file="$1" value="$2"
    printf '%s\n' "$value" > "${file}.tmp" || return 1
    mv -f "${file}.tmp" "$file"
}

append_state_line() {
    local file="$1" value="$2"
    { [ -f "$file" ] && cat "$file"; printf '%s\n' "$value"; } > "${file}.tmp" || return 1
    mv -f "${file}.tmp" "$file"
}

is_mountpoint() {
    local mp="$1"
    if command -v findmnt &>/dev/null; then
        findmnt -n "$mp" &>/dev/null
        return $?
    fi
    if command -v mountpoint &>/dev/null; then
        mountpoint -q "$mp"
        return $?
    fi
    mount | awk '{print $3}' | grep -qx "$mp"
}

get_mount_source() {
    local mp="$1"
    if command -v findmnt &>/dev/null; then
        findmnt -n -o SOURCE "$mp" 2>/dev/null | head -1 || true
        return 0
    fi
    mount | awk -v t="$mp" '$3==t{print $1; exit}' 2>/dev/null || true
}

is_current_run_artifact() {
    local file="$1" run_start file_mtime
    [ -f "$file" ] || return 1
    run_start=$(cat "$RUN_START_TS_FILE" 2>/dev/null || true)
    file_mtime=$(stat -c '%Y' "$file" 2>/dev/null || echo 0)
    case "$run_start" in ''|*[!0-9]*) return 1 ;; esac
    case "$file_mtime" in ''|*[!0-9]*) return 1 ;; esac
    [ "$file_mtime" -ge "$run_start" ]
}

has_valid_timestamp() {
    local file="$1" value
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in ''|*[!0-9]*) return 1 ;; esac
    [ "$value" -gt 0 ] 2>/dev/null
}

mount_source_matches() {
    local expected="$1" mount_point="$2" expected_uuid="${3:-}"
    local source expected_resolved source_resolved current_uuid
    source=$(get_mount_source "$mount_point")
    [ -n "$source" ] || return 1
    if [ "$source" != "$expected" ]; then
        expected_resolved=$(readlink -f "$expected" 2>/dev/null || true)
        source_resolved=$(readlink -f "$source" 2>/dev/null || true)
        [ -n "$expected_resolved" ] && [ "$expected_resolved" = "$source_resolved" ] || return 1
    fi
    if [ -n "$expected_uuid" ] && [ "$expected_uuid" != "-" ]; then
        current_uuid=$(blkid -s UUID -o value "$source" 2>/dev/null || true)
        if [ -z "$current_uuid" ]; then
            log_warn "设备 ${source} UUID 无法读取（设备可能已掉线），按挂载源一致放行校验"
            return 0
        fi
        [ "$current_uuid" = "$expected_uuid" ] || return 1
    fi
    return 0
}

backup_and_prepare_log_dir() {
    mkdir -p "$LOG_DIR"

    local mode="${LOG_CLEANUP_MODE:-backup}"
    case "$mode" in
        backup)
            local ts backup_dir moved_any=0
            ts=$(date '+%Y%m%d_%H%M%S')
            backup_dir="${LOG_DIR}/backup_${ts}"
            mkdir -p "$backup_dir"

            shopt -s nullglob
            local candidates=(
                "${LOG_DIR}"/*.log
                "${LOG_DIR}"/.pid_*
                "${LOG_DIR}"/.test_running
                "${LOG_DIR}"/.start_timestamp
                "${LOG_DIR}"/.end_timestamp
                "${LOG_DIR}"/.stopping
                "${LOG_DIR}"/.resource_usage.log
                "${LOG_DIR}"/crash_*.log
                "${LOG_DIR}"/perf_monitor.csv
                "${LOG_DIR}"/cpu_freq_monitor.csv
                "${LOG_DIR}"/mem_bw_monitor.csv
                "${LOG_DIR}"/pressure_performance_report.txt
                "${LOG_DIR}"/.swap_original
                "${LOG_DIR}"/.swap_restore_status
                "${LOG_DIR}"/.fio_mount_points
                "${LOG_DIR}"/.fio_mount_pending
                "${LOG_DIR}"/.fio_result_files
                "${LOG_DIR}"/.vm_worker_count
                "${LOG_DIR}"/fio_result_*.result
                "${LOG_DIR}"/.dmesg_snapshot_files
                "${LOG_DIR}"/.dmesg_status
                "${LOG_DIR}"/.journalctl_status
                "${LOG_DIR}"/.run_start_timestamp
                "${LOG_DIR}"/.partition_*.sfdisk
                "${LOG_DIR}"/.pid_cpu_freq_mon
                "${LOG_DIR}"/.pid_mem_bw_mon
                "${LOG_DIR}"/.pid_dmesg_mon
            )
            shopt -u nullglob

            local f
            for f in "${candidates[@]}"; do
                [ -e "$f" ] || continue
                mv "$f" "$backup_dir/" 2>/dev/null && moved_any=1
            done
            if [ "$moved_any" -eq 1 ]; then
                log_info "旧日志已备份到: ${backup_dir}"
            fi
            ;;
        delete)
            rm -f "${LOG_DIR}"/*.log "${LOG_DIR}"/.pid_* "${LOG_DIR}"/.test_running \
                  "${LOG_DIR}"/.start_timestamp "${LOG_DIR}"/.end_timestamp "${LOG_DIR}"/.stopping "${LOG_DIR}"/.resource_usage.log \
                   "${LOG_DIR}"/crash_*.log "$PMON_CSV" "$CPU_FREQ_CSV" "$MEM_BW_CSV" "$REPORT_FILE" "$SWAP_ORIG_FILE" "$FIO_MOUNT_LIST_FILE" \
                   "${LOG_DIR}"/.fio_result_files "${LOG_DIR}"/fio_result_*.result \
                   "${LOG_DIR}"/.fio_mount_pending "${LOG_DIR}"/.dmesg_snapshot_files "${LOG_DIR}"/.dmesg_status \
                   "${LOG_DIR}"/.journalctl_status \
                   "${LOG_DIR}"/.run_start_timestamp "${LOG_DIR}"/.partition_*.sfdisk "${LOG_DIR}"/.swap_restore_status "${LOG_DIR}"/.vm_worker_count
            ;;
        keep)
            ;;
        *)
            log_warn "未知 LOG_CLEANUP_MODE=${mode}，回退为 keep"
            ;;
    esac
}

handle_system_logs_on_start() {
    local action="${SYSTEM_LOG_ACTION:-backup}"
    case "$action" in
        backup)
            log_info "系统日志处理: backup（保存压测开始前快照，不清空）"
            dmesg > "${LOG_DIR}/dmesg_before.log" 2>&1 || true
            if [ -f /var/log/messages ]; then
                cp /var/log/messages "${LOG_DIR}/var_log_messages_before.log" 2>/dev/null || true
            fi
            ;;
        clear)
            log_info "系统日志处理: clear（清空 dmesg 和 /var/log/messages）"
            dmesg -C 2>/dev/null || true
            : > /var/log/messages 2>/dev/null || true
            ;;
        none)
            log_info "系统日志处理: none（不操作）"
            ;;
        *)
            log_warn "未知 SYSTEM_LOG_ACTION=${action}，回退为 backup"
            SYSTEM_LOG_ACTION="backup"
            handle_system_logs_on_start
            ;;
    esac
}

record_original_swap() {
    : > "${SWAP_ORIG_FILE}.tmp" || return 1
    if command -v swapon &>/dev/null; then
        swapon --noheadings --show=NAME 2>/dev/null | awk '{print $1}' >> "${SWAP_ORIG_FILE}.tmp" || return 1
    else
        awk 'NR>1{print $1}' /proc/swaps 2>/dev/null >> "${SWAP_ORIG_FILE}.tmp" || return 1
    fi
    mv -f "${SWAP_ORIG_FILE}.tmp" "$SWAP_ORIG_FILE"
}

restore_original_swap() {
    [ -f "$SWAP_ORIG_FILE" ] || return 0
    command -v swapon >/dev/null 2>&1 || {
        log_error "缺少 swapon，无法校验或恢复原始 swap 状态"
        return 1
    }

    log_info "恢复 swap（按启动时记录的 swap 列表）..."
    local current_swap current_swaps
    if ! current_swaps=$(swapon --noheadings --show=NAME 2>/dev/null); then
        log_error "无法读取当前 swap 列表，拒绝继续恢复"
        return 1
    fi
    while read -r current_swap; do
        [ -n "$current_swap" ] || continue
        if ! grep -Fxq "$current_swap" "$SWAP_ORIG_FILE"; then
            swapoff "$current_swap" 2>/dev/null || log_warn "关闭额外 swap 失败: ${current_swap}"
        fi
    done < <(printf '%s\n' "$current_swaps" | awk 'NF{print $1}')

    while read -r swap_dev; do
        [ -n "$swap_dev" ] || continue
        if swapon --noheadings --show=NAME 2>/dev/null | awk 'NF{print $1}' | grep -Fxq "$swap_dev"; then
            continue
        fi
        swapon "$swap_dev" 2>/dev/null || log_warn "swapon 失败: ${swap_dev}"
    done < "$SWAP_ORIG_FILE"
    local remaining expected
    if ! remaining=$(swapon --noheadings --show=NAME 2>/dev/null | awk 'NF{print $1}' | sort -u); then
        log_error "无法读取恢复后的 swap 列表"
        return 1
    fi
    expected=$(sort -u "$SWAP_ORIG_FILE")
    if [ "$remaining" != "$expected" ]; then
        log_error "swap 恢复校验失败: expected=[${expected}] actual=[${remaining}]"
        return 1
    fi
    if [ -s "$SWAP_ORIG_FILE" ]; then
        log_info "swap 恢复校验通过"
    else
        log_info "原始 swap 列表为空，swap 已确认保持关闭"
    fi
}

check_prerequisites() {
    STRESS_CMD=""
    local missing=0
    local optional_missing=0
    for cmd in bc dmidecode fio; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "缺少依赖: $cmd"
            missing=1
        fi
    done
    if command -v stress-ng &>/dev/null; then
        STRESS_CMD="stress-ng"
    else
        log_error "必须安装 stress-ng 才能进行高级内存压测 (不支持普通 stress)"
        missing=1
    fi
    if ! command -v ipmitool &>/dev/null; then
        log_warn "ipmitool 未安装，将跳过 BMC 硬件监控"
        SKIP_IPMI=true
        optional_missing=1
    else
        SKIP_IPMI=false
    fi
    if [ "$missing" -ne 0 ]; then
        exit 1
    fi
    log_info "所有必需依赖检查通过 (bc / dmidecode / fio / ${STRESS_CMD})"
    if [ "$optional_missing" -ne 0 ]; then
        log_warn "部分可选依赖缺失，相关功能将跳过（不影响整体流程）"
    fi
    log_info "压测工具: ${STRESS_CMD}"

    local fio_ver
    fio_ver=$(fio --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0.0")
    log_info "fio 版本: ${fio_ver} (要求 ${FIO_REQUIRED_VERSION:-3.13})"
    if [ "$fio_ver" != "$FIO_REQUIRED_VERSION" ]; then
        if [ "${FIO_VERSION_STRICT:-true}" = "true" ]; then
            log_error "fio 版本必须为 ${FIO_REQUIRED_VERSION}，当前 ${fio_ver}；如确需继续请设 FIO_VERSION_STRICT=false"
            exit 1
        fi
        log_warn "fio 版本 ${fio_ver} 与要求 ${FIO_REQUIRED_VERSION} 不一致（FIO_VERSION_STRICT=false，仅告警）"
    fi

    if ! "${STRESS_CMD}" --help 2>&1 | grep -q '\-\-vm '; then
        log_error "${STRESS_CMD} 不支持 --vm 内存压测，升级到 stress-ng 0.09+"
        exit 1
    fi
}

check_test_running() {
    if [ -f "$START_FLAG" ]; then
        local any_alive=0
        if [ -f "$PID_FIO_LIST" ]; then
            while read -r pid _; do
                [ -n "$pid" ] && pid_record_matches "${LOG_DIR}/.pid_fio_${pid}" "$pid" && any_alive=1 && break
            done < "$PID_FIO_LIST"
        fi
        local stress_pid
        stress_pid=$(awk 'NF{print $1; exit}' "$PID_STRESS" 2>/dev/null || true)
        [ "$any_alive" -eq 0 ] && [ -n "$stress_pid" ] && pid_is_expected "$PID_STRESS" "$stress_pid" && any_alive=1
        if [ "$any_alive" -eq 0 ] && [ -f "$PID_STRESS_VM" ]; then
            while read -r vp _; do
                [ -n "$vp" ] && pid_record_matches "${LOG_DIR}/.pid_vm_${vp}" "$vp" && any_alive=1 && break
            done < "$PID_STRESS_VM"
        fi
        if [ "$any_alive" -eq 0 ]; then
            local state_file state_pid state_start
            for state_file in "$PID_GUARDIAN" "$PID_OS_MEM_MON" "$PID_IPMI_MON" "$PID_CPU_FREQ_MON" "$PID_MEM_BW_MON" "$PID_DMESG_MON"; do
                [ -f "$state_file" ] || continue
                while read -r state_pid state_start; do
                    [ -n "$state_pid" ] && pid_line_matches "$state_pid" "$state_start" && any_alive=1 && break
                done < "$state_file"
                [ "$any_alive" -eq 1 ] && break
            done
        fi
        [ "$any_alive" -eq 1 ] && return 0
    fi
    return 1
}

acquire_operation_lock() {
    if ! mkdir "$OP_LOCK_DIR" 2>/dev/null; then
        local owner
        owner=$(awk 'NF{print $1; exit}' "${OP_LOCK_DIR}/pid" 2>/dev/null || echo "")
        if [[ "$owner" =~ ^[0-9]+$ ]] && pid_record_matches "${OP_LOCK_DIR}/pid" "$owner"; then
            log_error "已有 start/stop 操作正在进行，拒绝并发执行"
            return 1
        fi

        # A lock without a stable owner record may still belong to a process
        # between mkdir and its owner-record write; fail closed in that case.
        if [ ! -s "${OP_LOCK_DIR}/pid" ]; then
            log_error "发现无所有者记录的残留操作锁，拒绝自动接管"
            return 1
        fi
        if ! mkdir "${OP_LOCK_DIR}/reclaim" 2>/dev/null; then
            log_error "无法取得残留操作锁的回收权，拒绝执行"
            return 1
        fi
        owner=$(awk 'NF{print $1; exit}' "${OP_LOCK_DIR}/pid" 2>/dev/null || echo "")
        if [[ "$owner" =~ ^[0-9]+$ ]] && pid_record_matches "${OP_LOCK_DIR}/pid" "$owner"; then
            rmdir "${OP_LOCK_DIR}/reclaim" 2>/dev/null || true
            log_error "操作锁回收期间发现原所有者仍在运行，拒绝并发执行"
            return 1
        fi
        if ! rm -f "${OP_LOCK_DIR}/pid" 2>/dev/null || ! rmdir "${OP_LOCK_DIR}/reclaim" 2>/dev/null || ! rmdir "$OP_LOCK_DIR" 2>/dev/null; then
            log_error "无法清理残留操作锁，拒绝执行"
            return 1
        fi
        if ! mkdir "$OP_LOCK_DIR" 2>/dev/null; then
            log_error "无法重新创建操作锁，拒绝执行"
            return 1
        fi
    fi
    if ! write_pid_record "${OP_LOCK_DIR}/pid" "$$"; then
        rmdir "$OP_LOCK_DIR" 2>/dev/null || true
        log_error "操作锁所有者记录写入失败，拒绝执行"
        return 1
    fi
    __OP_LOCK_HELD=1
    return 0
}

release_operation_lock() {
    [ "$__OP_LOCK_HELD" -eq 1 ] || return 0
    local owner
    owner=$(awk 'NF{print $1; exit}' "${OP_LOCK_DIR}/pid" 2>/dev/null || echo "")
    if [ "$owner" = "$$" ] && pid_record_matches "${OP_LOCK_DIR}/pid" "$$"; then
        rm -f "${OP_LOCK_DIR}/pid" 2>/dev/null || true
        rmdir "$OP_LOCK_DIR" 2>/dev/null || true
    fi
    __OP_LOCK_HELD=0
}

disk_base_devices() {
    local dev="$1" resolved
    resolved=$(readlink -f "$dev" 2>/dev/null || echo "$dev")
    lsblk -s -nrpo NAME,TYPE "$resolved" 2>/dev/null | awk '$2 == "disk" {print $1}' | sort -u
}

configure_system_disk_protection() {
    SYSTEM_DISK_BASES=""

    if [ -z "${SYSTEM_DISKS:-}" ]; then
        log_error "未配置 SYSTEM_DISKS，拒绝启动：必须显式指定所有系统盘"
        return 1
    fi

    add_base() {
        local dev="$1" base bases
        [ -z "$dev" ] && return 0
        [ -b "$dev" ] || dev="/dev/${dev}"
        [ -b "$dev" ] || return 0
        bases=$(disk_base_devices "$dev")
        [ -n "$bases" ] || return 1
        for base in $bases; do
            [ -b "$base" ] || return 1
            case " ${SYSTEM_DISK_BASES} " in
                *" ${base} ") ;;
                *) SYSTEM_DISK_BASES="${SYSTEM_DISK_BASES} ${base}" ;;
            esac
        done
        return 0
    }

    for configured_disk in $SYSTEM_DISKS; do
        if [ ! -b "$configured_disk" ] && [ ! -b "/dev/${configured_disk}" ]; then
            log_error "SYSTEM_DISKS 中的设备不存在或不是块设备: ${configured_disk}"
            return 1
        fi
        local before="$SYSTEM_DISK_BASES"
        add_base "$configured_disk"
        if [ "$before" = "$SYSTEM_DISK_BASES" ]; then
            log_error "无法解析 SYSTEM_DISKS 中的设备: ${configured_disk}"
            return 1
        fi
    done

    SYSTEM_DISK_BASES=$(echo "$SYSTEM_DISK_BASES" | xargs)

    log_info "系统盘保护列表（来自 SYSTEM_DISKS 配置）: ${SYSTEM_DISK_BASES}"
    log_info "以上磁盘及其分区不会被分区/格式化/压测"
}

is_system_disk() {
    local d="$1" base bases
    bases=$(disk_base_devices "$d")
    if [ -z "$bases" ]; then
        log_error "无法解析设备所属物理磁盘，按系统盘处理以拒绝危险操作: ${d}"
        return 0
    fi
    while read -r base; do
        [ -n "$base" ] || continue
        for protected in $SYSTEM_DISK_BASES; do
            [ "$base" = "$protected" ] && return 0
        done
    done <<< "$bases"
    for protected in $SYSTEM_DISK_BASES; do
        [ "$d" = "$protected" ] && return 0
    done
    return 1
}

gather_block_devices() {
    local disks=""
    for dev in /dev/sd[a-z] /dev/sd[a-z][a-z] /dev/nvme[0-9]*n[0-9] /dev/nvme[0-9]*n[0-9][0-9] /dev/vd[a-z] /dev/vd[a-z][a-z]; do
        [ -b "$dev" ] && disks="${disks} ${dev}"
    done
    [ -z "$disks" ] && return 1
    echo "$disks" | tr ' ' '\n' | sort -u
    return 0
}

is_safe_test_disk() {
    local disk="$1"
    command -v lsblk >/dev/null 2>&1 || return 1
    command -v blkid >/dev/null 2>&1 || return 1
    local dev sig blkid_rc devices
    if ! devices=$(lsblk -nrpo NAME "$disk" 2>/dev/null); then
        return 1
    fi
    [ -n "$devices" ] || return 1
    while read -r dev; do
        [ -b "$dev" ] || continue
        sig=$(blkid -p -o value -s TYPE "$dev" 2>/dev/null)
        blkid_rc=$?
        case "$blkid_rc" in
            0|2) ;;
            *) return 1 ;;
        esac
        [ -z "$sig" ] || return 1
    done <<< "$devices"
    return 0
}

is_whole_disk() {
    local disk="$1" disk_type
    command -v lsblk >/dev/null 2>&1 || return 1
    disk_type=$(lsblk -dnro TYPE "$disk" 2>/dev/null) || return 1
    [ "$disk_type" = "disk" ]
}

authorize_disk() {
    local disk="$1"
    [ "${ALLOW_AUTO_PREPARE:-false}" = "true" ] && return 0
    local trimmed
    trimmed=$(echo " ${FIO_DISKS:-} " | xargs)
    [ -z "${trimmed}" ] && return 0
    echo " ${trimmed} " | grep -q " ${disk} "
}

prompt_format_confirm() {
    local disk="$1"
    [ "${ALLOW_AUTO_PREPARE:-false}" = "true" ] && return 0
    if [ ! -e /dev/tty ]; then
        log_warn "非交互环境且未设置 ALLOW_AUTO_PREPARE=true，跳过自动格式化: ${disk}" >&2
        return 1
    fi
    local ans=""
    read -r -p "[CONFIRM] 即将 wipefs + 重新分区 + mkfs.ext4，清空磁盘 ${disk} 全部数据！输入 yes 确认: " ans < /dev/tty || true
    if [ "$ans" = "yes" ]; then
        return 0
    fi
    log_warn "用户未确认格式化，跳过: ${disk}" >&2
    return 1
}

restore_partition_table() {
    local disk="$1" backup="$2"
    [ -s "$backup" ] || return 0
    if sfdisk "$disk" < "$backup" >/dev/null 2>&1; then
        log_warn "已回滚分区表: ${disk}" >&2
        return 0
    fi
    log_error "分区表回滚失败，保留现场并阻止后续测试: ${disk}" >&2
    write_state_file "$CLEANUP_FAILED_FLAG" "partition_rollback_failed:${disk}" || true
    return 1
}

prepare_and_format_disk() {
    local disk="$1"
    if is_system_disk "$disk"; then
        log_warn "系统盘 ${disk} 被请求准备/格式化，已拒绝（保护生效）" >&2
        echo ""
        return 0
    fi
    local best_part=""
    local disk_fstype existing_fs=0
    disk_fstype=$(blkid -s TYPE -o value "$disk" 2>/dev/null || echo "")
    if [ -n "$disk_fstype" ]; then
        existing_fs=1
        if [ "$disk_fstype" = "ext4" ] && [ "${ALLOW_EXISTING_FS:-false}" = "true" ]; then
            best_part="$disk"
        else
            log_warn "检测到已有 ${disk_fstype} 文件系统，拒绝重新分区/格式化: ${disk}" >&2
        fi
    fi

    local disk_name part_parent
    disk_name=$(basename "$disk")
    for part in ${disk}p* ${disk}[0-9]*; do
        [ -b "$part" ] || continue
        part_parent=$(lsblk -nlo PKNAME "$part" 2>/dev/null | awk 'NF{print; exit}')
        [ "$part_parent" = "$disk_name" ] || continue
        local fstype
        fstype=$(blkid -s TYPE -o value "$part" 2>/dev/null || echo "")
        [ -n "$fstype" ] || continue
        existing_fs=1
        if [ "$fstype" = "ext4" ] && [ "${ALLOW_EXISTING_FS:-false}" = "true" ] && [ -z "$best_part" ]; then
            best_part="$part"
        else
            log_warn "检测到已有 ${fstype} 文件系统，拒绝重新分区/格式化: ${part}" >&2
        fi
    done

    if [ "$existing_fs" -eq 1 ] && [ -z "$best_part" ]; then
        echo ""
        return 0
    fi
    
    if [ -z "$best_part" ]; then
        if ! lsblk -nlo MOUNTPOINT "$disk" 2>/dev/null | grep -q "[a-zA-Z0-9]"; then
            if ! is_safe_test_disk "$disk"; then
                log_warn "非系统盘 ${disk} 检测到受保护签名(Raid/LVM/加密/swap)，跳过自动格式化" >&2
                echo ""
                return 0
            fi
            if ! prompt_format_confirm "$disk"; then
                echo ""
                return 0
            fi
            log_info "非系统盘 ${disk} 无可用文件系统且未挂载，执行自动分区与 ext4 格式化..." >&2
            local partition_backup
            partition_backup="${LOG_DIR}/.partition_$(basename "$disk").sfdisk"
            local partition_backup_valid=0
            : > "$partition_backup" || return 1
            if sfdisk --dump "$disk" > "$partition_backup" 2>/dev/null; then
                partition_backup_valid=1
            elif lsblk -nrpo NAME "$disk" 2>/dev/null | awk 'NR > 1 {found=1} END {exit !found}'; then
                log_error "无法备份已有分区表，拒绝继续破坏性分区: ${disk}" >&2
                return 1
            else
                log_info "${disk} 无现有分区表，继续准备且无旧分区表可回滚" >&2
            fi
            if ! parted -s "$disk" mklabel gpt mkpart primary ext4 0% 100% >/dev/null 2>&1; then
                log_error "parted 分区失败: ${disk}" >&2
                if [ "$partition_backup_valid" -eq 1 ] && ! restore_partition_table "$disk" "$partition_backup"; then
                    log_error "${disk} 需要人工确认分区表现场" >&2
                fi
                return 1
            fi
            sleep 2
            
            local new_part=""
            for p in "${disk}1" "${disk}p1"; do
                [ -b "$p" ] && new_part="$p" && break
            done
            if [ -z "$new_part" ]; then
                local auto_p
                auto_p=$(lsblk -nlo NAME "$disk" 2>/dev/null | grep -v "^$(basename "$disk")$" | head -1)
                [ -n "$auto_p" ] && new_part="/dev/$auto_p"
            fi
            
            if [ -n "$new_part" ] && [ -b "$new_part" ]; then
                if mkfs.ext4 -F "$new_part" >/dev/null 2>&1; then
                    best_part="$new_part"
                else
                    log_error "mkfs.ext4 失败: ${new_part}" >&2
                    if [ "$partition_backup_valid" -eq 1 ] && ! restore_partition_table "$disk" "$partition_backup"; then
                        log_error "${disk} 需要人工确认分区表现场" >&2
                    fi
                    return 1
                fi
            else
                log_error "自动分区后未发现可用分区: ${disk}" >&2
                if [ "$partition_backup_valid" -eq 1 ] && ! restore_partition_table "$disk" "$partition_backup"; then
                    log_error "${disk} 需要人工确认分区表现场" >&2
                fi
                return 1
            fi
        else
            log_warn "非系统盘 ${disk} 存在已挂载分区，跳过自动格式化" >&2
        fi
    fi
    echo "$best_part"
}

find_data_disks() {
    local valid_disks=""
    if [ -n "${FIO_DISKS:-}" ]; then
        log_info "使用配置文件指定的测试盘: ${FIO_DISKS}" >&2
        for disk in $FIO_DISKS; do
            if [ ! -b "$disk" ]; then
                log_error "指定测试盘不存在: ${disk}" >&2
                return 1
            fi
            if ! is_whole_disk "$disk"; then
                log_error "FIO_DISKS 必须指定整块物理磁盘，拒绝分区/LVM 等设备: ${disk}" >&2
                return 1
            fi
            if is_system_disk "$disk"; then
                log_error "指定测试盘是系统盘，拒绝: ${disk}" >&2
                return 1
            fi
            local bp
            if ! bp=$(prepare_and_format_disk "$disk"); then
                log_error "指定测试盘准备失败: ${disk}" >&2
                return 1
            fi
            [ -n "$bp" ] && valid_disks="${valid_disks} ${bp}"
        done
        valid_disks=$(echo "$valid_disks" | xargs)
        if [ -n "$valid_disks" ]; then
            echo "$valid_disks"
            return 0
        fi
        log_error "配置指定的测试盘均未产生可用分区 (FIO_DISKS=\"${FIO_DISKS}\")，中止，不回退" >&2
        return 1
    fi

    local all_disks
    all_disks=$(gather_block_devices) || return 1

    for disk in $all_disks; do
        is_system_disk "$disk" && continue
        authorize_disk "$disk" || { log_warn "未授权磁盘，跳过: ${disk}" >&2; continue; }
        local bp
        if ! bp=$(prepare_and_format_disk "$disk"); then
            log_warn "自动发现磁盘准备失败，跳过: ${disk}" >&2
            continue
        fi
        [ -z "$bp" ] && continue
        valid_disks="${valid_disks} ${bp}"
        log_info "  数据盘/分区: ${bp} (ext4)" >&2
    done

    valid_disks=$(echo "$valid_disks" | xargs)
    [ -z "$valid_disks" ] && return 1
    echo "$valid_disks"
    return 0
}

mount_data_disk() {
    local part_dev="$1" index="$2"
    local mount_point base_mount
    [ "$index" -eq 1 ] && base_mount="${FIO_MOUNT_BASE}" || base_mount="${FIO_MOUNT_BASE}_${index}"

    local existing_mp=""
    if command -v findmnt &>/dev/null; then
        existing_mp=$(findmnt -n -S "$part_dev" -o TARGET 2>/dev/null | head -1 || echo "")
    fi
    if [ -n "$existing_mp" ]; then
        log_warn "${part_dev} 已挂载于 ${existing_mp}，拒绝使用现有业务挂载点" >&2
        return 1
    fi

    mount_point="$base_mount"
    if is_mountpoint "$mount_point"; then
        log_warn "挂载点已被占用（不会 umount）: ${mount_point} <- $(get_mount_source "$mount_point")" >&2
    fi

    local try=0
    while [ -e "$mount_point" ] || [ -L "$mount_point" ] || is_mountpoint "$mount_point"; do
        try=$(( try + 1 ))
        if [ "$try" -gt 8 ]; then
            log_warn "无法找到可用挂载点(尝试次数过多): base=${base_mount}" >&2
            return 1
        fi
        mount_point="${base_mount}_$(date '+%s')_${RANDOM}"
    done

    mkdir -p "$mount_point" || return 1
    local mount_uuid
    mount_uuid=$(blkid -s UUID -o value "$part_dev" 2>/dev/null || true)
    if [ -z "$mount_uuid" ]; then
        log_error "无法读取 ${part_dev} 的文件系统 UUID，拒绝记录和使用挂载点" >&2
        return 1
    fi
    if ! write_state_file "$FIO_MOUNT_PENDING_FILE" "${part_dev} ${mount_point} ${mount_uuid}"; then
        log_error "fio 待清理挂载状态写入失败，拒绝挂载: ${part_dev}" >&2
        return 1
    fi
    if ! mount "$part_dev" "$mount_point" 2>/dev/null; then
        log_warn "挂载失败: ${part_dev} -> ${mount_point}" >&2
        write_state_file "$FIO_MOUNT_PENDING_FILE" "" || true
        return 1
    fi

    if ! append_state_line "$FIO_MOUNT_LIST_FILE" "${part_dev} ${mount_point} ${mount_uuid}"; then
        log_error "fio 挂载状态写入失败: ${part_dev} ${mount_point}" >&2
        if ! mount_source_matches "$part_dev" "$mount_point" "$mount_uuid" || ! umount "$mount_point" 2>/dev/null; then
            log_error "挂载状态写入失败且卸载失败，记录待清理挂载点: ${part_dev} ${mount_point}" >&2
            write_state_file "$FIO_MOUNT_PENDING_FILE" "${part_dev} ${mount_point} ${mount_uuid}" || true
        fi
        return 1
    fi
    if ! write_state_file "$FIO_MOUNT_PENDING_FILE" ""; then
        log_error "fio 待清理挂载状态清理失败: ${part_dev} ${mount_point}" >&2
        return 1
    fi
    log_info "已挂载: ${part_dev} -> ${mount_point}" >&2
    echo "$mount_point"
    return 0
}

start_fio_pressure() {
    local target="$1" fio_log="$2" mode="$3"
    local fio_name="fio_pressure"
    local fio_result_file
    fio_result_file="${FIO_RESULT_PREFIX}$(basename "$fio_log" .log).result"
    local fio_runtime_sec=$(( TOTAL_DURATION_SEC + FIO_STEADY_WAIT + 10 ))
    [ -f "$STOPPING_FLAG" ] && return 1

    if [ "$mode" = "file" ]; then
        local testfile="/var/tmp/fio_pressure_testfile"
        log_info "启动文件级 fio 压测 (file: ${testfile}, size=${FIO_FILE_SIZE_MB}M, numjobs=${FIO_FILE_NUMJOBS})"
        rm -f "$testfile" 2>/dev/null || true
        local fio_direct="--direct=1"
        local fio_engine="--ioengine=libaio"
        local fstype
        fstype=$(df -T "$(dirname "$testfile")" 2>/dev/null | tail -1 | awk '{print $2}')
        if [ "$fstype" = "tmpfs" ]; then
            log_warn "/var/tmp 检测为 tmpfs，去除 --direct=1 改用 sync IO"
            fio_direct=""
            fio_engine="--ioengine=sync"
        fi
        if ! append_state_line "$FIO_RESULT_LIST_FILE" "$fio_result_file"; then
            log_error "fio 结果状态文件写入失败: ${fio_result_file}"
            return 1
        fi
        ( fio --name=${fio_name} --filename=${testfile} --rw=rw --rwmixread=50 \
            ${fio_engine} ${fio_direct} --bs=1M --size=${FIO_FILE_SIZE_MB}M \
            --numjobs=${FIO_FILE_NUMJOBS} --iodepth=16 --group_reporting --time_based \
            --runtime=${fio_runtime_sec}s --end_fsync=0 --thread --norandommap --randrepeat=0 --exitall \
            ; rc=$?; printf 'exit_code=%s\nend_timestamp=%s\n' "$rc" "$(date '+%s')" > "${fio_result_file}.tmp" && mv -f "${fio_result_file}.tmp" "$fio_result_file" ) &> "$fio_log" &
    else
        log_info "启动块设备级 fio 压测 (目录: ${target})"
        local numjobs=4
        local disk_free_kb
        disk_free_kb=$(df -k "$target" | tail -1 | awk '{print $4}')
        local target_size_mb=$(( disk_free_kb / 1024 * 90 / 100 / numjobs ))
        if [ "$target_size_mb" -lt 1024 ]; then
            log_error "${target} 可用空间不足以支持 ${numjobs} 个 fio job，每 job 至少 1GB" >&2
            return 1
        fi
        
        log_info "目标压测数据大小: 每线程 ${target_size_mb}M (共 ${numjobs} 线程，总占用 90% 空闲空间)"
        if ! append_state_line "$FIO_RESULT_LIST_FILE" "$fio_result_file"; then
            log_error "fio 结果状态文件写入失败: ${fio_result_file}"
            return 1
        fi
        ( fio --name=${fio_name} --directory=${target} --rw=rw --rwmixread=50 \
            --ioengine=libaio --direct=1 --bs=1M --size=${target_size_mb}M --numjobs=${numjobs} --iodepth=64 \
            --group_reporting --time_based --runtime=${fio_runtime_sec}s \
            --end_fsync=0 --thread --norandommap --randrepeat=0 --exitall \
            ; rc=$?; printf 'exit_code=%s\nend_timestamp=%s\n' "$rc" "$(date '+%s')" > "${fio_result_file}.tmp" && mv -f "${fio_result_file}.tmp" "$fio_result_file" ) &> "$fio_log" &
    fi
    local fio_pid=$!
    if [ -f "$STOPPING_FLAG" ]; then
        terminate_pid_tree "$fio_pid" KILL
        return 1
    fi
    if ! append_pid_record "$PID_FIO_LIST" "$fio_pid" || ! write_pid_record "${LOG_DIR}/.pid_fio_${fio_pid}" "$fio_pid"; then
        log_error "fio PID 记录写入失败: ${fio_pid}"
        terminate_pid_tree "$fio_pid" KILL
        return 1
    fi
    log_info "fio 已启动 (PID: ${fio_pid}), 日志: ${fio_log}"
}

compute_fio_usage() {
    local total_cpus fio_cpus
    total_cpus=$(nproc)
    fio_cpus=0
    if [ -f "$PID_FIO_LIST" ]; then
        local pids
        pids=$(while read -r pid _; do
            [ -n "$pid" ] && collect_pid_tree_records "$pid"
        done < "$PID_FIO_LIST" | awk 'NF{print $1}' | sort -nu | paste -sd, -)
        if [ -n "$pids" ]; then
            local pct
            pct=$(top -b -d 3 -n 2 -p "$pids" 2>/dev/null | awk '
                /^[[:space:]]*[0-9]+/ {
                    if (NF >= 9) {
                        val[$1]=$9
                    }
                }
                END {
                    for (p in val) sum += val[p]
                    print sum+0
                }
            ')
            local cc
            cc=$(echo "scale=0; ${pct:-0} / 100" | bc 2>/dev/null || echo "0")
            fio_cpus=$(( cc > 0 ? cc : 0 ))
        fi
    fi

    local total_mem_kb fio_mem_kb
    total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    fio_mem_kb=0
    if [ -f "$PID_FIO_LIST" ]; then
        while read -r pid _; do
            [ -z "$pid" ] && continue
            while read -r tree_pid _; do
                local rss
                rss=$(ps -o rss= -p "$tree_pid" 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
                fio_mem_kb=$(( fio_mem_kb + (rss > 0 ? rss : 0) ))
            done < <(collect_pid_tree_records "$pid")
        done < "$PID_FIO_LIST"
    fi
    local cached_kb
    cached_kb=$(grep -E '^(Cached|Buffers):' /proc/meminfo | awk '{sum+=$2} END {print sum+0}')
    echo "${fio_cpus} ${fio_mem_kb} ${total_cpus} ${total_mem_kb} ${cached_kb}"
}

collect_mem_stats() {
    local label="$1"
    local total_kb free_kb avail_kb swap_total_kb swap_free_kb cached_kb buff_kb
    total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    free_kb=$(grep MemFree  /proc/meminfo | awk '{print $2}')
    avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    swap_total_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    swap_free_kb=$(grep SwapFree /proc/meminfo | awk '{print $2}')
    cached_kb=$(grep '^Cached:' /proc/meminfo | awk '{print $2}')
    buff_kb=$(grep '^Buffers:' /proc/meminfo | awk '{print $2}')

    local used_kb=$(( total_kb - free_kb - buff_kb - cached_kb ))
    local swap_used_kb=$(( swap_total_kb - swap_free_kb ))
    local mem_pct
    mem_pct=$(echo "scale=1; ${used_kb} * 100 / ${total_kb}" | bc)

    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    {
        echo "=== ${label} @ ${ts} ==="
        echo "total_kb=${total_kb}"
        echo "free_kb=${free_kb}"
        echo "avail_kb=${avail_kb}"
        echo "used_kb=${used_kb}"
        echo "cached_kb=${cached_kb}"
        echo "buff_kb=${buff_kb}"
        echo "swap_total_kb=${swap_total_kb}"
        echo "swap_used_kb=${swap_used_kb}"
        echo "mem_usage_pct=${mem_pct}"
        echo "timestamp=$(date '+%s')"
    }
}

get_mem_stat_val() {
    local key="$1" file="$2"
    grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2 || echo "0"
}

start_csv_monitor() {
    local interval="$1"
    local duration="$2"
    [ -f "$STOPPING_FLAG" ] && return 1

    log_info "启动 OS 内存指标监控 (间隔 ${interval}s, 持续 ${duration}s)"

    {
        local start_ts
        start_ts=$(date '+%s')
        echo "timestamp,mem_total_kb,mem_free_kb,mem_avail_kb,mem_used_pct,swap_total_kb,swap_used_kb,cached_kb,buffer_kb" > "$PMON_CSV"
        local end_ts=$(( start_ts + duration ))
        while [ "$(date '+%s')" -lt "$end_ts" ]; do
            local ts total_kb free_kb avail_kb swap_total_kb swap_free_kb cached_kb buff_kb
            ts=$(date '+%s')
            total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
            free_kb=$(grep MemFree  /proc/meminfo | awk '{print $2}')
            avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
            swap_total_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
            swap_free_kb=$(grep SwapFree /proc/meminfo | awk '{print $2}')
            cached_kb=$(grep '^Cached:' /proc/meminfo | awk '{print $2}')
            buff_kb=$(grep '^Buffers:' /proc/meminfo | awk '{print $2}')
            local used_kb=$(( total_kb - free_kb - buff_kb - cached_kb ))
            local swap_used_kb=$(( swap_total_kb - swap_free_kb ))
            local mem_pct
            mem_pct=$(echo "scale=1; ${used_kb} * 100 / ${total_kb}" | bc)
            echo "${ts},${total_kb},${free_kb},${avail_kb},${mem_pct},${swap_total_kb},${swap_used_kb},${cached_kb},${buff_kb}" >> "$PMON_CSV"
            sleep "$interval"
        done
        log_info "OS 内存指标监控已结束"
    } &
    local csv_pid=$!
    if ! append_pid_record "$PID_OS_MEM_MON" "$csv_pid"; then
        log_error "OS 内存监控 PID 记录写入失败"
        terminate_pid_tree "$csv_pid" KILL
        return 1
    fi
    log_info "OS 内存指标监控已启动 (PID: ${csv_pid})"
}

start_ipmi_monitor() {
    local mon_log="$1"
    local pid_file="$2"
    local interval="$3"
    local duration="$4"
    [ -f "$STOPPING_FLAG" ] && return 1

    log_info "启动 ipmitool BMC 硬件监控 (间隔 ${interval}s, 持续 ${duration}s)"

    {
        echo "=== RUN_START $(cat "$RUN_START_TS_FILE" 2>/dev/null || echo unknown) ===" >> "$mon_log"
        local end_ts=$(( $(date '+%s') + duration ))
        while [ "$(date '+%s')" -lt "$end_ts" ]; do
            local ts
            ts=$(date '+%Y-%m-%d %H:%M:%S')
            echo "=== SNAPSHOT ${ts} ===" >> "$mon_log"
            timeout 30 ipmitool sensor list 2>/dev/null >> "$mon_log" || {
                echo "[WARN] ipmitool sensor list 超时或失败 @ ${ts}" >> "$mon_log"
            }
            echo "" >> "$mon_log"
            sleep "$interval"
        done
    } &
    local ipmi_pid=$!
    if ! append_pid_record "$pid_file" "$ipmi_pid"; then
        log_error "ipmitool 监控 PID 记录写入失败"
        terminate_pid_tree "$ipmi_pid" KILL
        return 1
    fi
    log_info "ipmitool 监控已启动 (PID: ${ipmi_pid})"
}

start_cpu_freq_monitor() {
    local interval="$1"
    local duration="$2"
    [ -f "$STOPPING_FLAG" ] && return 1

    local cpu_list
    cpu_list=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | sort -V)
    if [ -z "$cpu_list" ]; then
        log_warn "未找到 CPU sysfs 目录，跳过 CPU 频率监控"
        return 0
    fi
    local first_dir
    first_dir=$(echo "$cpu_list" | head -1)
    if [ ! -d "${first_dir}/cpufreq" ]; then
        log_warn "未检测到 CPUFreq 驱动接口 (${first_dir}/cpufreq 不存在)，跳过 CPU 频率监控"
        return 0
    fi

    log_info "启动 CPU 频率监控 (间隔 ${interval}s, 持续 ${duration}s)"

    {
        local start_ts
        start_ts=$(date '+%s')
        {
            echo -n "timestamp"
            local dir
            for dir in $cpu_list; do
                echo -n ",$(basename "${dir}")_freq_khz"
            done
            echo ",first_cpu_scaling_max_khz"
        } > "$CPU_FREQ_CSV"

        local end_ts=$(( start_ts + duration ))
        while [ "$(date '+%s')" -lt "$end_ts" ]; do
            local ts
            ts=$(date '+%s')
            echo -n "${ts}"
            local maxf=0
            for dir in $cpu_list; do
                local f
                f=$(cat "${dir}/cpufreq/scaling_cur_freq" 2>/dev/null | tr -d '[:space:]')
                [ -z "$f" ] && f=0
                echo -n ",${f}"
                if [ "$f" -gt "$maxf" ]; then maxf="$f"; fi
            done
            local max_scaling
            max_scaling=$(cat "${first_dir}/cpufreq/scaling_max_freq" 2>/dev/null | tr -d '[:space:]')
            [ -z "$max_scaling" ] && max_scaling="$maxf"
            echo ",${max_scaling}" >> "$CPU_FREQ_CSV"
            sleep "$interval"
        done
        log_info "CPU 频率监控已结束"
    } &
    local freq_pid=$!
    if ! write_pid_record "$PID_CPU_FREQ_MON" "$freq_pid"; then
        log_error "CPU 频率监控 PID 记录写入失败"
        terminate_pid_tree "$freq_pid" KILL
        return 1
    fi
    log_info "CPU 频率监控已启动 (PID: ${freq_pid})"
}

start_mem_bw_monitor() {
    local interval="$1"
    local duration="$2"
    [ -f "$STOPPING_FLAG" ] && return 1

    if [ "${MEM_BW_MON:-auto}" = "off" ]; then
        log_info "MEM_BW_MON=off，跳过内存带宽监控"
        return 0
    fi
    if ! command -v perf &>/dev/null; then
        log_warn "perf 未安装，跳过内存带宽监控（以内存压测负载持续运行为满负载证据）"
        return 0
    fi

    local use_read="" use_write=""
    if timeout 15 perf stat -a -e "uncore_imc/data_reads/" -x, sleep 1 >/dev/null 2>&1; then
        use_read="uncore_imc/data_reads/"
    fi
    if timeout 15 perf stat -a -e "uncore_imc/data_writes/" -x, sleep 1 >/dev/null 2>&1; then
        use_write="uncore_imc/data_writes/"
    fi
    if [ -z "$use_read" ] && [ -z "$use_write" ]; then
        log_warn "未能探测到可用内存带宽硬件计数器 (uncore_imc)，跳过内存带宽监控（以内存压测负载持续运行为满负载证据）"
        return 0
    fi

    log_info "启动内存带宽监控 (间隔 ${interval}s, 持续 ${duration}s, 事件: ${use_read:-无} ${use_write:-无})"

    {
        echo "timestamp,mem_read_MBps,mem_write_MBps" > "$MEM_BW_CSV"
        local prev_r=0 prev_w=0 first=1
        local end_ts=$(( $(date '+%s') + duration ))
        while [ "$(date '+%s')" -lt "$end_ts" ]; do
            local ts
            ts=$(date '+%s')
            local r w events="" out r_unit="" w_unit=""
            [ -n "$use_read" ] && events="$use_read"
            [ -n "$use_write" ] && events="${events:+${events},}${use_write}"
            # perf stat -x, CSV columns: value,unit,event,... (value=$1, unit=$2)
            out=$(timeout 60 perf stat -a -e "$events" -x, sleep "$interval" 2>&1)
            r=$(echo "$out" | awk -F, '$0 ~ /data_reads/  && $1 ~ /^[0-9]+(\.[0-9]+)?$/ {sum+=$1} END{print sum+0}')
            w=$(echo "$out" | awk -F, '$0 ~ /data_writes/ && $1 ~ /^[0-9]+(\.[0-9]+)?$/ {sum+=$1} END{print sum+0}')
            r_unit=$(echo "$out" | awk -F, '$0 ~ /data_reads/  {u=$2; gsub(/^[ \t]+|[ \t]+$/,"",u); print u; exit}')
            w_unit=$(echo "$out" | awk -F, '$0 ~ /data_writes/ {u=$2; gsub(/^[ \t]+|[ \t]+$/,"",u); print u; exit}')
            if [ "$first" -eq 1 ]; then
                prev_r="$r"; prev_w="$w"; first=0
                continue
            fi
            local r_mbw w_mbw
            if [ -n "$use_read" ] && [ "$r" -ge "$prev_r" ] && [ "$r" -gt 0 ]; then
                if [ "$r_unit" = "MiB" ]; then
                    r_mbw=$(echo "scale=1; ($r - $prev_r) / $interval" | bc 2>/dev/null || echo "0")
                else
                    r_mbw=$(echo "scale=1; ($r - $prev_r) / 1048576 / $interval" | bc 2>/dev/null || echo "0")
                fi
            else
                r_mbw=0
            fi
            if [ -n "$use_write" ] && [ "$w" -ge "$prev_w" ] && [ "$w" -gt 0 ]; then
                if [ "$w_unit" = "MiB" ]; then
                    w_mbw=$(echo "scale=1; ($w - $prev_w) / $interval" | bc 2>/dev/null || echo "0")
                else
                    w_mbw=$(echo "scale=1; ($w - $prev_w) / 1048576 / $interval" | bc 2>/dev/null || echo "0")
                fi
            else
                w_mbw=0
            fi
            echo "${ts},${r_mbw},${w_mbw}" >> "$MEM_BW_CSV"
            prev_r="$r"; prev_w="$w"
        done
        log_info "内存带宽监控已结束"
    } &
    local bw_pid=$!
    if ! write_pid_record "$PID_MEM_BW_MON" "$bw_pid"; then
        log_error "内存带宽监控 PID 记录写入失败"
        terminate_pid_tree "$bw_pid" KILL
        return 1
    fi
    log_info "内存带宽监控已启动 (PID: ${bw_pid})"
}

start_dmesg_monitor() {
    local interval="$1"
    local duration="$2"
    [ -f "$STOPPING_FLAG" ] && return 1

    log_info "启动 dmesg 中途快照监控 (每 ${interval}s 保存一次，不清空内核 ring buffer, 持续 ${duration}s)"

    {
        local end_ts=$(( $(date '+%s') + duration ))
        local seq=0
        while [ "$(date '+%s')" -lt "$end_ts" ]; do
            seq=$(( seq + 1 ))
            local snapshot_file
            snapshot_file="${LOG_DIR}/dmesg_snapshot_$(date '+%Y%m%d_%H%M%S')_${seq}.log"
            if ! append_state_line "$DMESG_SNAPSHOT_LIST_FILE" "$snapshot_file"; then
                log_error "dmesg 快照清单写入失败"
                append_state_line "$DMESG_STATUS_FILE" "snapshot_list=FAIL" || true
                break
            fi
            if dmesg > "$snapshot_file" 2>/dev/null; then
                append_state_line "$DMESG_STATUS_FILE" "snapshot=${snapshot_file}:PASS" || log_error "dmesg 状态写入失败"
            else
                append_state_line "$DMESG_STATUS_FILE" "snapshot=${snapshot_file}:FAIL" || log_error "dmesg 状态写入失败"
            fi
            sleep "$interval"
        done
        log_info "dmesg 中途快照监控已结束"
    } &
    local dmesg_pid=$!
    if ! write_pid_record "$PID_DMESG_MON" "$dmesg_pid"; then
        log_error "dmesg 监控 PID 记录写入失败"
        terminate_pid_tree "$dmesg_pid" KILL
        return 1
    fi
    log_info "dmesg 中途快照监控已启动 (PID: ${dmesg_pid})"
}

parse_ipmi_thermal() {
    local mon_log="$1"
    local run_marker="${2:-}"
    [ -f "$mon_log" ] || return 0
    awk -v run_marker="$run_marker" '
        /^=== RUN_START / { in_run=($0 == run_marker); in_snap=0; next }
        !in_run { next }
        /^=== SNAPSHOT/ { in_snap=1; next }
        in_snap {
            if ($0 ~ /^[[:space:]]*$/) { in_snap=0; next }
            if ($0 ~ /WARN|ipmitool|not available/) next
            n=split($0,a,"|")
            if (n<3) next
            name=a[1]; gsub(/^[ \t]+|[ \t]+$/,"",name)
            val=a[2]+0; unit=a[3]; gsub(/^[ \t]+|[ \t]+$/,"",unit)
            u=tolower(unit)
            if (u ~ /degrees c/) {
                if (!(name in cmin)){cmin[name]=val;cmax[name]=val;csum[name]=val;cn[name]=1;cl[cln++]=name}
                else { if(val<cmin[name])cmin[name]=val; if(val>cmax[name])cmax[name]=val; csum[name]+=val; cn[name]++ }
            }
            else if (u ~ /watt/) {
                if (!(name in pmin)){pmin[name]=val;pmax[name]=val;psum[name]=val;pn[name]=1;pl[pln++]=name}
                else { if(val<pmin[name])pmin[name]=val; if(val>pmax[name])pmax[name]=val; psum[name]+=val; pn[name]++ }
            }
        }
        END {
            for(i=0;i<cln;i++){ nm=cl[i]; printf "温度 %s: min=%.1fC max=%.1fC avg=%.1fC n=%d\n", nm, cmin[nm], cmax[nm], csum[nm]/cn[nm], cn[nm] }
            for(i=0;i<pln;i++){ nm=pl[i]; printf "功耗 %s: min=%.1fW max=%.1fW avg=%.1fW n=%d\n", nm, pmin[nm], pmax[nm], psum[nm]/pn[nm], pn[nm] }
        }
    ' "$mon_log"
}

start_stress_guardian() {
    local duration="$1"
    [ -f "$STOPPING_FLAG" ] && return 1

    {
        local end_ts=$(( $(date '+%s') + duration + 30 ))
        local cpu_died=0 vm_died=0
        local cpu_early_death_ts=0 vm_early_death_ts=0
        local deadline
        local pressure_start_ts=""
        has_valid_timestamp "${LOG_DIR}/.start_timestamp" && pressure_start_ts=$(cat "${LOG_DIR}/.start_timestamp" 2>/dev/null || echo "")
        if [ -n "$pressure_start_ts" ] && [ "$pressure_start_ts" -gt 0 ] 2>/dev/null; then
            deadline=$(( pressure_start_ts + duration - 5 ))
        else
            deadline=$(( $(date '+%s') + duration - 5 ))
        fi
        local fio_initial="" fio_alive=0 recorded_fio=""
        local vm_recorded_dead="" loop_count=0
        local disk_watch_list=""
        if [ -s "$FIO_MOUNT_LIST_FILE" ]; then
            while read -r wpart _wmp; do
                [ -n "$wpart" ] || continue
                local pbase
                pbase=$(lsblk -nlo PKNAME "$wpart" 2>/dev/null | awk 'NF{print; exit}')
                if [ -n "$pbase" ] && [ -b "/dev/${pbase}" ]; then
                    disk_watch_list="${disk_watch_list} ${wpart}:/dev/${pbase}"
                else
                    disk_watch_list="${disk_watch_list} ${wpart}:${wpart}"
                fi
            done < "$FIO_MOUNT_LIST_FILE"
        fi
        if [ -s "$PID_FIO_LIST" ]; then
            fio_initial=$(awk 'NF{print $1}' "$PID_FIO_LIST" | paste -sd ' ' -)
            fio_alive=$(echo "$fio_initial" | wc -w)
        fi

        while [ "$(date '+%s')" -lt "$end_ts" ]; do
            loop_count=$(( loop_count + 1 ))
            if [ -f "$STOPPING_FLAG" ]; then
                log_info "检测到停止标志，进程守护静默退出"
                break
            fi
            local stress_pid=""
            if [ -f "$PID_STRESS" ] && [ "$cpu_died" -eq 0 ]; then
                stress_pid=$(awk 'NF{print $1; exit}' "$PID_STRESS" 2>/dev/null || echo "")
                if [ -n "$stress_pid" ] && ! pid_is_expected "$PID_STRESS" "$stress_pid"; then
                    cpu_died=1
                    local now_ts
                    now_ts=$(date '+%s')
                    if [ "$now_ts" -lt "$deadline" ]; then
                        cpu_early_death_ts="$now_ts"
                        log_error "stress-ng CPU 异常退出 (PID: ${stress_pid}, 提前于预期结束时间)"
                        {
                            echo "=== STRESS CPU CRASH @ $(date '+%Y-%m-%d %H:%M:%S') ==="
                            echo "pid=${stress_pid}"
                            echo "expected_end_ts=${deadline}"
                            echo "crash_ts=${cpu_early_death_ts}"
                            echo "=== Memory state ==="
                            free -m
                        } > "${LOG_DIR}/crash_stress_cpu.log"
                    else
                        log_info "stress-ng CPU 正常结束 (PID: ${stress_pid})"
                    fi
                fi
            fi

            if [ -f "$PID_STRESS_VM" ] && [ "$vm_died" -eq 0 ]; then
                # multi-PID aware (memtester writes 2 PIDs, stress-ng writes 1):
                # record each newly-dead PID once; all-dead => vm_died=1
                local vm_alive=0 vm_total=0 vm_newly_dead=""
                while read -r vp vstart; do
                    [ -n "$vp" ] || continue
                    vm_total=$(( vm_total + 1 ))
                    if pid_line_matches "$vp" "$vstart"; then
                        vm_alive=$(( vm_alive + 1 ))
                    elif ! echo "$vm_recorded_dead" | grep -qw "$vp"; then
                        vm_recorded_dead="${vm_recorded_dead} ${vp}"
                        vm_newly_dead="${vm_newly_dead} ${vp}"
                    fi
                done < "$PID_STRESS_VM"
                if [ -n "$vm_newly_dead" ]; then
                    local now_ts
                    now_ts=$(date '+%s')
                    if [ "$now_ts" -lt "$deadline" ]; then
                        vm_early_death_ts="$now_ts"
                        log_error "内存压测进程异常退出 (PID:${vm_newly_dead}, 存活 ${vm_alive}/${vm_total}, 提前于预期结束时间)"
                        {
                            echo "=== STRESS VM CRASH @ $(date '+%Y-%m-%d %H:%M:%S') ==="
                            echo "pids=${vm_newly_dead}"
                            echo "alive=${vm_alive}/${vm_total}"
                            echo "expected_end_ts=${deadline}"
                            echo "crash_ts=${vm_early_death_ts}"
                            echo "=== Memory state ==="
                            free -m
                            echo "=== stress-ng/memtester VM log tail ==="
                            tail -30 "${LOG_DIR}/stress_vm.log" 2>/dev/null || echo "(log not available)"
                        } > "${LOG_DIR}/crash_stress_vm.log"
                    else
                        log_info "内存压测进程结束 (PID:${vm_newly_dead}, 存活 ${vm_alive}/${vm_total})"
                    fi
                fi
                if [ "$vm_total" -gt 0 ] && [ "$vm_alive" -eq 0 ]; then
                    vm_died=1
                fi
            fi

            [ "$cpu_died" -eq 1 ] && [ "$vm_died" -eq 1 ] && break
            [ -n "$fio_initial" ] && [ "$fio_alive" -eq 0 ] && break

            if [ -n "$fio_initial" ]; then
                local new_alive=0
                for fpid in $fio_initial; do
                    if pid_record_matches "${LOG_DIR}/.pid_fio_${fpid}" "$fpid"; then
                        new_alive=$(( new_alive + 1 ))
                    elif ! echo "$recorded_fio" | grep -qw "$fpid"; then
                        recorded_fio="${recorded_fio} ${fpid}"
                        local fnow_ts
                        fnow_ts=$(date '+%s')
                        if [ "$fnow_ts" -lt "$deadline" ]; then
                            local fio_cmd="" fio_dir fio_name
                            if [ -r "/proc/${fpid}/cmdline" ]; then
                                fio_cmd=$(tr '\0' ' ' < "/proc/${fpid}/cmdline" 2>/dev/null || echo "")
                            fi
                            fio_dir=$(echo "$fio_cmd" | grep -oE -- '--directory=[^ ]+' | cut -d= -f2 || echo "N/A")
                            fio_name=$(echo "$fio_cmd" | grep -oE -- '--name=[^ ]+' | cut -d= -f2 || echo "N/A")
                            [ -n "$fio_dir" ] || fio_dir="N/A"
                            [ -n "$fio_name" ] || fio_name="N/A"
                            log_error "fio 进程异常退出 (PID: ${fpid}, job: ${fio_name}, directory: ${fio_dir}, 提前于预期结束时间)"
                            {
                                echo "=== FIO CRASH @ $(date '+%Y-%m-%d %H:%M:%S') ==="
                                echo "pid=${fpid}"
                                echo "job=${fio_name}"
                                echo "directory=${fio_dir}"
                                echo "expected_end_ts=${deadline}"
                                echo "crash_ts=${fnow_ts}"
                                echo "=== matching fio log tail ==="
                                local fio_log_match=""
                                fio_log_match=$(ls -t "${LOG_DIR}"/fio_pressure_*.log 2>/dev/null | head -3)
                                for f in $fio_log_match; do
                                    echo "----- $f -----"
                                    tail -15 "$f" 2>/dev/null
                                done
                                echo "=== Memory state ==="
                                free -m
                            } >> "${LOG_DIR}/crash_fio.log"
                        fi
                    fi
                done
                fio_alive="$new_alive"
            fi

            # disk-drop detection: every 60s verify test partitions/disks still exist
            if [ $(( loop_count % 12 )) -eq 0 ] && [ -n "$disk_watch_list" ]; then
                for entry in $disk_watch_list; do
                    local dpart dbase
                    dpart="${entry%%:*}"
                    dbase="${entry##*:}"
                    if [ ! -b "$dpart" ] && [ ! -b "$dbase" ]; then
                        if ! grep -q "partition=${dpart}" "${LOG_DIR}/crash_disk.log" 2>/dev/null; then
                            log_error "测试盘疑似掉盘: ${dpart} (base ${dbase}) 设备节点消失"
                            {
                                echo "=== DISK LOST @ $(date '+%Y-%m-%d %H:%M:%S') ==="
                                echo "partition=${dpart}"
                                echo "base=${dbase}"
                                echo "=== lsblk snapshot ==="
                                lsblk 2>/dev/null
                                echo "=== dmesg tail ==="
                                dmesg 2>/dev/null | tail -30
                            } >> "${LOG_DIR}/crash_disk.log"
                        fi
                    fi
                done
            fi

            sleep 5
        done
        log_info "进程守护已退出"
    } &
    local guardian_pid=$!
    if ! write_pid_record "$PID_GUARDIAN" "$guardian_pid"; then
        log_error "guardian PID 记录写入失败"
        terminate_pid_tree "$guardian_pid" KILL
        return 1
    fi
    log_info "进程守护已启动 (PID: ${guardian_pid})"
}

start_stress_cpu() {
    local cpu_cores="$1"
    local stress_log="$2"

    log_info "启动 CPU 压测 (${STRESS_CMD}, ${cpu_cores} 核)"

    ${STRESS_CMD} --cpu "$cpu_cores" --timeout ${TOTAL_DURATION_SEC}s >> "$stress_log" 2>&1 &
    local stress_pid=$!
    if [ -f "$STOPPING_FLAG" ]; then
        terminate_pid_tree "$stress_pid" KILL
        return 1
    fi
    if ! write_pid_record "$PID_STRESS" "$stress_pid"; then
        log_error "CPU 压测 PID 记录写入失败"
        terminate_pid_tree "$stress_pid" KILL
        return 1
    fi

    wait "$stress_pid" 2>/dev/null && exit_code=0 || exit_code=$?
    {
        echo "stress CPU exit code: ${exit_code}"
        echo "stress CPU cores: ${cpu_cores}"
        echo "stress CPU duration: ${TOTAL_DURATION_SEC}s"
        [ -f "$STOPPING_FLAG" ] && echo "stress CPU stop reason: planned_stop"
    } >> "$stress_log"
    log_info "stress CPU 已结束 (PID: ${stress_pid}, exit: ${exit_code})"
}

start_stress_vm() {
    local mem_pct="$1"
    local vm_mode="$2"
    local vm_log="$3"

    local mem_tool
    if [ "${MEM_TOOL:-auto}" = "auto" ]; then
        if command -v memtester &>/dev/null; then
            mem_tool="memtester"
        else
            mem_tool="stress-ng"
        fi
    else
        mem_tool="${MEM_TOOL}"
    fi

    case "$mem_tool" in
        memtester)
            local vm_workers mem_mb each_mb
            mem_mb=$(echo "$mem_pct" | sed 's/[Mm]$//')
            vm_workers=4
            each_mb=$(( mem_mb / vm_workers ))
            [ "$each_mb" -lt 1 ] && each_mb=1
            log_info "启动 memtester 内存压测 (${mem_pct} 物理内存, ${vm_workers} workers x ${each_mb}M/worker)"
            write_state_file "${LOG_DIR}/.vm_worker_count" "$vm_workers"
            if ! write_state_file "$PID_STRESS_VM" ""; then
                log_error "内存压测 PID 状态文件初始化失败"
                return 1
            fi
            local w
            for w in $(seq 1 "$vm_workers"); do
                nohup memtester "${each_mb}M" 9999999 >> "$vm_log" 2>&1 &
                local vm_pid=$!
                if [ -f "$STOPPING_FLAG" ]; then
                    terminate_pid_tree "$vm_pid" KILL
                    return 1
                fi
                if ! append_pid_record "$PID_STRESS_VM" "$vm_pid" || ! write_pid_record "${LOG_DIR}/.pid_vm_${vm_pid}" "$vm_pid"; then
                    log_error "内存压测 PID 记录写入失败: ${vm_pid}"
                    terminate_pid_tree "$vm_pid" KILL
                    return 1
                fi
            done
            ;;
        stress-ng|*)
            # NOTE: stress-ng >= 0.17 divides --vm-bytes across all vm workers,
            # so pass the FULL target here. 4 workers only speed up first-touch
            # page-in; the resident set always equals the target with --vm-keep.
            local mb_total mb_workers
            mb_total=$(echo "$mem_pct" | sed 's/[Mm]$//')
            mb_workers=4
            write_state_file "${LOG_DIR}/.vm_worker_count" "$mb_workers"
            log_info "启动 ${STRESS_CMD} 内存压测 (总计 ${mem_pct}, ${mb_workers} workers, mode=${vm_mode})"
            local vm_args="--vm ${mb_workers} --vm-bytes ${mb_total}M --vm-keep"
            case "$vm_mode" in
                rand|random)  vm_args="${vm_args} --vm-method rand-set" ;;
                seq|sequential) vm_args="${vm_args} --vm-method incdec" ;;
                flip)         vm_args="${vm_args} --vm-method flip" ;;
                rowhammer)    vm_args="${vm_args} --vm-method rowhammer" ;;
                walk)         vm_args="${vm_args} --vm-method walk-0d" ;;
                write)        vm_args="${vm_args} --vm-method write64" ;;
                all)          vm_args="${vm_args}" ;;
                *)            log_warn "未知内存访问模式: ${vm_mode}, 使用默认 all"; vm_args="${vm_args}" ;;
            esac
            ${STRESS_CMD} ${vm_args} --timeout ${TOTAL_DURATION_SEC}s >> "$vm_log" 2>&1 &
            local vm_pid=$!
            if [ -f "$STOPPING_FLAG" ]; then
                terminate_pid_tree "$vm_pid" KILL
                return 1
            fi
            if ! write_pid_record "$PID_STRESS_VM" "$vm_pid" || ! write_pid_record "${LOG_DIR}/.pid_vm_${vm_pid}" "$vm_pid"; then
                log_error "内存压测 PID 记录写入失败: ${vm_pid}"
                terminate_pid_tree "$vm_pid" KILL
                return 1
            fi
            ;;
    esac

    local vm_rc=0
    wait || vm_rc=$?
    {
        echo "stress VM exit code: ${vm_rc}"
        echo "stress VM tool: ${mem_tool}"
        echo "stress VM bytes: ${mem_pct}"
        echo "stress VM mode: ${vm_mode}"
        [ -f "$STOPPING_FLAG" ] && echo "stress VM stop reason: planned_stop"
    } >> "$vm_log"
    log_info "内存压测已结束 (tool=${mem_tool}, bytes=${mem_pct})"
}

generate_performance_report() {
    log_info "生成性能报告..."

    local rep="$REPORT_FILE"
    local report_duration_sec="${TOTAL_DURATION_SEC}"
    if [ -f "${LOG_DIR}/.resource_usage.log" ]; then
        local saved_duration
        saved_duration=$(get_mem_stat_val total_duration_sec "${LOG_DIR}/.resource_usage.log")
        case "$saved_duration" in
            ''|*[!0-9]*) ;;
            *) report_duration_sec="$saved_duration" ;;
        esac
    fi
    local report_target_hours
    report_target_hours=$(echo "scale=1; ${report_duration_sec} / 3600" | bc 2>/dev/null || echo "N/A")
    if ! {
        echo "=============================================================="
        echo "  整机 7x24H 混合压力测试 - 性能报告"
        echo "=============================================================="
        echo "  生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "--------------------------------------------------------------"

        if [ -f "$START_TIME_FILE" ]; then
            echo "  开始时间: $(cat "$START_TIME_FILE")"
        fi
        if [ -f "$END_TIME_FILE" ]; then
            echo "  结束时间: $(cat "$END_TIME_FILE")"
        fi

        local actual_hours="N/A"
        if has_valid_timestamp "${LOG_DIR}/.start_timestamp" && has_valid_timestamp "${LOG_DIR}/.end_timestamp"; then
            local st et
            st=$(cat "${LOG_DIR}/.start_timestamp")
            et=$(cat "${LOG_DIR}/.end_timestamp")
            actual_hours=$(echo "scale=1; (${et} - ${st}) / 3600" | bc)
        fi
        echo "  实际运行: ${actual_hours} 小时 (目标: ${report_target_hours}H)"
        echo ""

        echo "========== 内存性能指标 =========="
        if [ -f "${LOG_DIR}/mem_baseline.log" ]; then
            local bl_total bl_free bl_avail bl_swap_total bl_swap_used
            bl_total=$(get_mem_stat_val total_kb "${LOG_DIR}/mem_baseline.log")
            bl_free=$(get_mem_stat_val free_kb "${LOG_DIR}/mem_baseline.log")
            bl_avail=$(get_mem_stat_val avail_kb "${LOG_DIR}/mem_baseline.log")
            bl_swap_total=$(get_mem_stat_val swap_total_kb "${LOG_DIR}/mem_baseline.log")
            bl_swap_used=$(get_mem_stat_val swap_used_kb "${LOG_DIR}/mem_baseline.log")

            echo "  [压测前-基线]"
            echo "    总内存:      $(echo "scale=1; ${bl_total} / 1024 / 1024" | bc) GB"
            echo "    可用内存:    $(echo "scale=1; ${bl_avail} / 1024 / 1024" | bc) GB"
            echo "    空闲内存:    $(echo "scale=1; ${bl_free} / 1024 / 1024" | bc) GB"
            echo "    Swap 总量:   $(echo "scale=1; ${bl_swap_total} / 1024 / 1024" | bc) GB"
            echo "    Swap 已用:   $(echo "scale=1; ${bl_swap_used} / 1024" | bc) MB"
            echo ""
        fi

        if [ -f "${LOG_DIR}/mem_reset.log" ]; then
            local rs_total rs_free rs_avail rs_swap_used
            rs_total=$(get_mem_stat_val total_kb "${LOG_DIR}/mem_reset.log")
            rs_free=$(get_mem_stat_val free_kb "${LOG_DIR}/mem_reset.log")
            rs_avail=$(get_mem_stat_val avail_kb "${LOG_DIR}/mem_reset.log")
            rs_swap_used=$(get_mem_stat_val swap_used_kb "${LOG_DIR}/mem_reset.log")

            echo "  [压测后-复位]"
            echo "    总内存:      $(echo "scale=1; ${rs_total} / 1024 / 1024" | bc) GB"
            echo "    可用内存:    $(echo "scale=1; ${rs_avail} / 1024 / 1024" | bc) GB"
            echo "    空闲内存:    $(echo "scale=1; ${rs_free} / 1024 / 1024" | bc) GB"
            echo "    Swap 已用:   $(echo "scale=1; ${rs_swap_used} / 1024" | bc) MB"
            echo ""
        fi

        if [ -f "$PMON_CSV" ]; then
            local total_lines peak_mem_use min_mem_free avg_mem_use peak_swap_use
            total_lines=$(tail -n +2 "$PMON_CSV" | wc -l)
            if [ "$total_lines" -gt 0 ]; then
                peak_mem_use=$(tail -n +2 "$PMON_CSV" | awk -F, '{if($5>max)max=$5} END{print max+0}')
                min_mem_free=$(tail -n +2 "$PMON_CSV" | awk -F, 'NR==1{min=$3}{if($3<min)min=$3} END{print min+0}')
                avg_mem_use=$(tail -n +2 "$PMON_CSV" | awk -F, '{sum+=$5;n++} END{printf "%.1f", sum/n}')
                peak_swap_use=$(tail -n +2 "$PMON_CSV" | awk -F, '{if($7>max)max=$7} END{print max+0}')

                echo "  [压测期间统计 - ${total_lines} 个采样点]"
                echo "    峰值使用率:  ${peak_mem_use}%"
                echo "    平均使用率:  ${avg_mem_use}%"
                echo "    最小可用内存: $(echo "scale=1; ${min_mem_free} / 1024 / 1024" | bc) GB"
                echo "    Swap 峰值:   $(echo "scale=1; ${peak_swap_use} / 1024" | bc) MB"
                echo ""
            fi
        fi

        echo "========== 部件状态 =========="
        if [ -f "${LOG_DIR}/stress_vm.log" ]; then
            local vm_exit vm_reason vm_workers_info
            vm_exit=$(grep "exit code:" "${LOG_DIR}/stress_vm.log" 2>/dev/null | tail -1 | awk '{print $NF}' || echo "?")
            vm_reason=$(grep "stop reason:" "${LOG_DIR}/stress_vm.log" 2>/dev/null | tail -1 | awk -F': ' '{print $2}' || true)
            vm_workers_info=""
            [ -f "${LOG_DIR}/.vm_worker_count" ] && vm_workers_info=" workers=$(cat "${LOG_DIR}/.vm_worker_count")"
            echo "  stress-ng VM:  exit=${vm_exit}${vm_workers_info} reason=${vm_reason:-process_exit}"
        fi
        if [ -f "${LOG_DIR}/stress_cpu.log" ]; then
            local cpu_exit cpu_reason
            cpu_exit=$(grep "exit code:" "${LOG_DIR}/stress_cpu.log" 2>/dev/null | tail -1 | awk '{print $NF}' || echo "?")
            cpu_reason=$(grep "stop reason:" "${LOG_DIR}/stress_cpu.log" 2>/dev/null | tail -1 | awk -F': ' '{print $2}' || true)
            echo "  stress-ng CPU: exit=${cpu_exit} reason=${cpu_reason:-process_exit}"
        fi

        echo ""
        echo "========== fio 结果 =========="
        local fio_result_count=0 fio_result_fail=0 fio_result_missing=0 fio_result_uncollected=0 fio_result_file fio_exit fio_reason fio_status
        if [ -s "$FIO_RESULT_LIST_FILE" ]; then
            while IFS= read -r fio_result_file; do
                [ -n "$fio_result_file" ] || continue
                fio_result_count=$(( fio_result_count + 1 ))
                if [ ! -f "$fio_result_file" ]; then
                    echo "  $(basename "$fio_result_file"): 结果记录缺失"
                    fio_result_missing=$(( fio_result_missing + 1 ))
                    continue
                fi
                fio_exit=$(awk -F= '$1=="exit_code"{print $2; exit}' "$fio_result_file")
                fio_reason=$(awk -F= '$1=="stop_reason"{print $2; exit}' "$fio_result_file")
                fio_status=$(awk -F= '$1=="result_status"{print $2; exit}' "$fio_result_file")
                if [ -n "$fio_status" ]; then
                    echo "  $(basename "$fio_result_file"): status=${fio_status} reason=${fio_reason:-unknown}"
                    fio_result_uncollected=$(( fio_result_uncollected + 1 ))
                else
                    echo "  $(basename "$fio_result_file"): exit=${fio_exit:-N/A} reason=${fio_reason:-fio_exit}"
                fi
                if [ -z "$fio_status" ] && [ "${fio_reason:-}" != "planned_stop" ] && [ "${fio_exit:-1}" != "0" ]; then
                    fio_result_fail=$(( fio_result_fail + 1 ))
                fi
            done < "$FIO_RESULT_LIST_FILE"
        fi
        if [ "$fio_result_count" -eq 0 ]; then
            echo "  fio 结果记录缺失"
        elif [ "$fio_result_fail" -gt 0 ] || [ "$fio_result_missing" -gt 0 ]; then
            echo "  *** fio 结果异常: 非零退出 ${fio_result_fail}，记录缺失 ${fio_result_missing}，共 ${fio_result_count} ***"
        elif [ "$fio_result_uncollected" -gt 0 ]; then
            echo "  fio 计划停止但未取得退出码: ${fio_result_uncollected}/${fio_result_count}"
        fi
        if [ -f "${LOG_DIR}/.swap_restore_status" ]; then
            echo "  swap 恢复: $(cat "${LOG_DIR}/.swap_restore_status")"
        fi

        echo ""
        echo "========== CPU 频率与降频检查 =========="
        if [ -f "$CPU_FREQ_CSV" ] && [ -s "$CPU_FREQ_CSV" ]; then
            local freq_summary
            freq_summary=$(tail -n +2 "$CPU_FREQ_CSV" | awk -F, -v t="${CPU_THROTTLE_PCT:-90}" '
                {
                    nf=NF
                    maxf=$nf
                    minf=maxf
                    for(i=2;i<nf;i++){ if($i!="" && $i+0<minf) minf=$i+0 }
                    if(maxf>0 && minf < maxf*t/100) thr++
                    s++
                }
                END { printf "%d %d", s+0, thr+0 }
            ')
            local freq_samples freq_throttle
            read -r freq_samples freq_throttle <<< "$freq_summary"
            echo "  CPU 频率采样点数: ${freq_samples:-0}"
            echo "  疑似降频样本数 (任一核 < max*${CPU_THROTTLE_PCT:-90}%): ${freq_throttle:-0}"
            [ "${freq_throttle:-0}" -gt 0 ] && echo "  *** 检测到疑似降频，请人工核查 cpu_freq_monitor.csv ***"
        else
            echo "  (CPU 频率监控未运行或无数据)"
        fi

        echo ""
        echo "========== 内存带宽监控 =========="
        if [ -f "$MEM_BW_CSV" ] && [ -s "$MEM_BW_CSV" ]; then
            local bw_summary
            bw_summary=$(tail -n +2 "$MEM_BW_CSV" | awk -F, '
                { if($2!="" && $2+0>rmax) rmax=$2+0; rsum+=$2; rc++; if($3!="" && $3+0>wmax) wmax=$3+0; wsum+=$3; wc++ }
                END { printf "%.1f %.1f %.1f %.1f", (rc?rsum/rc:0), rmax, (wc?wsum/wc:0), wmax }
            ')
            local r_avg r_max w_avg w_max
            read -r r_avg r_max w_avg w_max <<< "$bw_summary"
            echo "  读带宽: 平均 ${r_avg} MBps, 峰值 ${r_max} MBps"
            echo "  写带宽: 平均 ${w_avg} MBps, 峰值 ${w_max} MBps"
            echo "  (数值为 perf uncore 计数器近似值，平台不支持时该项为空)"
        else
            echo "  (内存带宽硬件计数器不可用，以内存压测进程持续运行作为满负载证据)"
        fi

        echo ""
        echo "========== 温度与功耗监控 (BMC) =========="
        if [ -f "${LOG_DIR}/ipmi_monitor.log" ]; then
            local thermal_summary
            local ipmi_run_marker
            ipmi_run_marker="=== RUN_START $(cat "$RUN_START_TS_FILE" 2>/dev/null || echo unknown) ==="
            thermal_summary=$(parse_ipmi_thermal "${LOG_DIR}/ipmi_monitor.log" "$ipmi_run_marker")
            if [ -n "$thermal_summary" ]; then
                while IFS= read -r line; do
                    echo "  ${line}"
                done <<< "$thermal_summary"
            else
                echo "  (未从 ipmi_monitor.log 解析到温度/功耗传感器)"
            fi
        else
            echo "  (ipmitool 监控未运行或未安装)"
        fi

        echo ""
        echo "========== 系统日志检查 =========="
        if has_valid_timestamp "${LOG_DIR}/.start_timestamp"; then
            local dmesg_err_pattern="Oops:|Call Trace:|(^|[[:space:]:])BUG:|Kernel panic|Hardware Error:|mce:|MCE|segfault|task hung|KASAN|EDAC|I/O error|nvme .*reset|controller reset|device disconnected|device blocked|ata[0-9]+ .*(error|reset)"
            local dmesg_err=0
            local dmesg_snapshot_count=0
            local dmesg_snapshot_error_files=0 dmesg_snapshot_missing=0 dmesg_collection_failed=0 dmesg_snapshot_file
            if [ -s "$DMESG_SNAPSHOT_LIST_FILE" ]; then
                while IFS= read -r dmesg_snapshot_file; do
                    [ -n "$dmesg_snapshot_file" ] || continue
                    if [ ! -f "$dmesg_snapshot_file" ]; then
                        dmesg_snapshot_missing=$(( dmesg_snapshot_missing + 1 ))
                        continue
                    fi
                    dmesg_snapshot_count=$(( dmesg_snapshot_count + 1 ))
                    if comm -13 <(sort "${LOG_DIR}/dmesg_pressure_start.log") <(sort "$dmesg_snapshot_file") 2>/dev/null | grep -qiE "$dmesg_err_pattern"; then
                        dmesg_snapshot_error_files=$(( dmesg_snapshot_error_files + 1 ))
                    fi
                done < "$DMESG_SNAPSHOT_LIST_FILE"
            fi
            if [ -f "${LOG_DIR}/dmesg_pressure.log" ]; then
                dmesg_err=$(grep -ciE "$dmesg_err_pattern" "${LOG_DIR}/dmesg_pressure.log" 2>/dev/null || true)
                echo "  dmesg 压力窗口异常: ${dmesg_err} 行（中途快照 ${dmesg_snapshot_count} 个，含异常快照 ${dmesg_snapshot_error_files} 个）"
            else
                echo "  dmesg 压力窗口结果缺失（中途快照 ${dmesg_snapshot_count} 个）"
                dmesg_collection_failed=1
            fi
            if [ "$dmesg_snapshot_error_files" -gt 0 ]; then
                echo "  *** 中途 dmesg 快照发现异常，不能判定为日志干净 ***"
            fi
            if [ "$dmesg_snapshot_missing" -gt 0 ]; then
                echo "  *** 中途 dmesg 快照缺失: ${dmesg_snapshot_missing} 个 ***"
                dmesg_collection_failed=1
            fi
            if [ ! -f "$DMESG_STATUS_FILE" ] || grep -qE '(^start=PENDING$|^start=FAIL$|^end=FAIL$|^snapshot_list=FAIL$|:FAIL$)' "$DMESG_STATUS_FILE" 2>/dev/null; then
                dmesg_collection_failed=1
            fi
            if [ "$dmesg_collection_failed" -ne 0 ]; then
                echo "  *** dmesg 采集失败或不完整，不能判定为日志干净 ***"
            fi
        else
            echo "  压力窗口未开始，跳过 dmesg 判定"
        fi

        if [ -f "${LOG_DIR}/journalctl_pressure.log" ]; then
            local j_err
            j_err=$(grep -ciE "Out of memory|Killed process|Oops:|Call Trace:|(^|[[:space:]:])BUG:|Kernel panic|Hardware Error:|mce:|MCE|EDAC|task hung|I/O error|nvme .*reset|controller reset" "${LOG_DIR}/journalctl_pressure.log" 2>/dev/null || echo "0")
            echo "  journalctl 异常关键词: ${j_err} 行"
            if [ "$(cat "$JOURNAL_STATUS_FILE" 2>/dev/null || echo FAIL)" != "PASS" ]; then
                echo "  *** journalctl 采集失败，不能判定为日志干净 ***"
            fi
        elif [ -f "$JOURNAL_STATUS_FILE" ]; then
            echo "  journalctl 结果缺失（状态: $(cat "$JOURNAL_STATUS_FILE")）"
        else
            echo "  journalctl 结果缺失（状态文件不存在）"
        fi

        local current_crash_count=0 crash_file
        for crash_file in "${LOG_DIR}"/crash_*.log; do
            if is_current_run_artifact "$crash_file"; then
                current_crash_count=$(( current_crash_count + 1 ))
            fi
        done
        if [ "$current_crash_count" -gt 0 ]; then
            echo ""
            echo "  *** 检测到本轮异常终止/掉盘记录，请检查 crash_*.log (含 crash_disk.log) ***"
        fi

        echo ""
        echo "=============================================================="
    } > "$rep"; then
        log_error "性能报告写入失败: ${rep}"
        return 1
    fi

    log_info "性能报告已生成: ${rep}"
}

do_start() {
    check_root
    load_config
    check_prerequisites

    mkdir -p "$LOG_DIR"
    acquire_operation_lock || exit 1

    if [ -f "$CLEANUP_FAILED_FLAG" ]; then
        log_error "上一次停止未完成清理，拒绝启动；请先执行 stop 并处理 ${CLEANUP_FAILED_FLAG}"
        release_operation_lock
        exit 1
    fi

    if [ -f "$START_FLAG" ]; then
        if check_test_running; then
            log_warn "混合压力测试已在运行中"
        else
            log_error "发现上一轮残留测试状态，拒绝覆盖现场"
        fi
        log_warn "如需重新开始，请先执行: $0 stop"
        release_operation_lock
        exit 1
    fi

    backup_and_prepare_log_dir
    if ! write_state_file "$RUN_START_TS_FILE" "$(date '+%s')"; then
        log_error "本轮测试起始状态文件写入失败，中止测试"
        release_operation_lock
        exit 1
    fi
    exec &> >(tee -a "${LOG_DIR}/console_output.log")

    log_info "========== 整机 7x24H 混合压力测试 - 启动 =========="

    trap 'log_warn "收到信号，开始自动收尾..."; do_stop; exit 130' INT TERM HUP
    trap 'if [ "$(awk '\''NF{sub(/[[:space:]].*/, "");print;exit}'\'' "$START_FLAG" 2>/dev/null || echo "")" = "$$" ]; then do_stop; fi' EXIT
    if ! write_state_file "$START_FLAG" "$$"; then
        log_error "测试状态文件写入失败，中止测试"
        exit 1
    fi
    if ! write_state_file "${LOG_DIR}/.start_timestamp" "" || ! write_state_file "${LOG_DIR}/.end_timestamp" ""; then
        log_error "测试时间状态初始化失败，中止测试"
        exit 1
    fi
    rm -f "$STOPPING_FLAG"

    log_info "Step 1: 处理系统日志..."
    handle_system_logs_on_start

    log_info "Step 2: 记录测试开始时间..."
    log_info "测试时间将在所有压力进程启动后开始计时"

    log_info "Step 3: 收集 dmidecode 内存信息..."
    dmidecode -t memory > "${LOG_DIR}/dmidecode_memory.log" 2>&1 || true
    log_info "dmidecode 内存信息已保存"

    log_info "Step 4: 采集内存基线数据..."
    collect_mem_stats "BASELINE" > "$MEM_BASELINE_LOG"
    log_info "内存基线数据已保存: ${MEM_BASELINE_LOG}"

    log_info "Step 5: 收集测试前 BMC 传感器数据..."
    if [ "$SKIP_IPMI" = "false" ]; then
        timeout 30 ipmitool sensor list > "${LOG_DIR}/sensor_before.log" 2>/dev/null || {
            log_warn "ipmitool sensor list 执行失败或超时"
        }
        log_info "传感器数据已保存至: ${LOG_DIR}/sensor_before.log"
    else
        log_info "ipmitool 未安装, 跳过 BMC 传感器采集"
    fi

    log_info "Step 6: 记录并关闭 swap..."
    if ! write_state_file "${LOG_DIR}/.swap_restore_status" "RECORDING"; then
        log_error "swap 恢复状态初始化失败，中止测试"
        exit 1
    fi
    if ! record_original_swap; then
        log_error "原始 swap 状态记录失败，中止测试"
        exit 1
    fi
    if ! write_state_file "${LOG_DIR}/.swap_restore_status" "PENDING"; then
        log_error "swap 恢复状态更新失败，中止测试"
        exit 1
    fi
    if ! swapoff -a 2>/dev/null; then
        log_error "swapoff -a 失败，拒绝在未关闭 swap 的状态下开始内存压力测试"
        if restore_original_swap; then
            write_state_file "${LOG_DIR}/.swap_restore_status" "PASS" || log_error "swap 恢复状态写入失败"
        else
            write_state_file "${LOG_DIR}/.swap_restore_status" "FAIL" || log_error "swap 恢复状态写入失败"
        fi
        exit 1
    fi
    local swap_total
    swap_total=$(free -m | awk '/Swap/{print $2}')
    if [ "${swap_total:-}" = "0" ]; then
        log_info "swap 已成功关闭"
        if ! write_state_file "${LOG_DIR}/.swap_restore_status" "DISABLED"; then
            log_error "swap 状态更新失败，中止测试"
            exit 1
        fi
    else
        log_error "swapoff -a 返回成功但 swap 仍处于启用状态 (${swap_total:-unknown}MB)，拒绝继续"
        if restore_original_swap; then
            write_state_file "${LOG_DIR}/.swap_restore_status" "PASS" || log_error "swap 恢复状态写入失败"
        else
            write_state_file "${LOG_DIR}/.swap_restore_status" "FAIL" || log_error "swap 恢复状态写入失败"
        fi
        exit 1
    fi

    log_info "Step 7: 检测系统盘..."
    if ! configure_system_disk_protection; then
        log_error "系统盘保护配置无效，中止测试"
        exit 1
    fi

    log_info "Step 8: 查找可用数据盘..."
    local data_disks
    if ! data_disks=$(find_data_disks); then
        if [ -n "${FIO_DISKS:-}" ]; then
            log_error "指定测试盘准备失败 (FIO_DISKS=\"${FIO_DISKS}\")，中止测试（不回退文件级模式）"
            exit 1
        fi
        log_warn "查找或准备数据盘失败，回退到文件级压测模式"
        data_disks=""
    fi
    data_disks=$(echo "$data_disks" | xargs)

    local fio_mode
    local disk_index=0
    if ! write_state_file "$PID_FIO_LIST" "" || ! write_state_file "$FIO_MOUNT_LIST_FILE" "" || ! write_state_file "$FIO_MOUNT_PENDING_FILE" "" || ! write_state_file "$FIO_START_TS_FILE" "$(date '+%s')" || ! write_state_file "$FIO_RESULT_LIST_FILE" ""; then
        log_error "fio 状态文件初始化失败，中止测试"
        exit 1
    fi

    log_info "Step 9: 挂载数据盘并启动 fio 压测..."
    if [ -n "$data_disks" ]; then
        fio_mode="block"
        log_info "可用数据盘: ${data_disks}"
        for part in $data_disks; do
            disk_index=$(( disk_index + 1 ))
            local mount_point
            if ! mount_point=$(mount_data_disk "$part" "$disk_index"); then
                log_error "测试盘挂载失败，拒绝继续启动: ${part}"
                exit 1
            fi
            local disk_label
            disk_label=$(echo "$part" | sed 's|/dev/||g' | sed 's|/|_|g')
            if ! start_fio_pressure "$mount_point" "${LOG_DIR}/fio_pressure_${disk_label}.log" "block"; then
                log_error "fio 启动失败: ${part}"
                exit 1
            fi
        done
    else
        fio_mode="file"
        log_warn "==============================================="
        log_warn "未找到任何可用的非系统数据盘，将退化到对系统盘进行安全文件级压测"
        log_warn "目标路径: /var/tmp 下创建测试文件"
        
        # 计算系统盘安全压测文件大小
        local root_free_kb
        root_free_kb=$(df -k /var/tmp | tail -1 | awk '{print $4}')
        local root_free_mb=$(( root_free_kb / 1024 ))
        
        # 预留 5GB 安全空间，其余作为压测文件大小，若不足 5GB 则退出
        if [ "$root_free_mb" -lt 5120 ]; then
            log_error "系统盘 /var/tmp 剩余空间不足 5GB (${root_free_mb}MB)，无法进行安全的压测，退出！"
            exit 1
        fi
        
        # 使用配置文件指定的 FIO_FILE_SIZE_MB，如果是多线程，则检查总大小
        local safe_fio_mb=$(( root_free_mb - 5120 ))
        local total_req_mb=$(( FIO_FILE_SIZE_MB * FIO_FILE_NUMJOBS ))
        if [ "$total_req_mb" -gt "$safe_fio_mb" ]; then
            local new_size=$(( safe_fio_mb / FIO_FILE_NUMJOBS ))
            log_warn "配置的总压测文件大小 (${total_req_mb}MB) 过大，为保护系统盘，自动调整每线程大小为 ${new_size}MB"
            FIO_FILE_SIZE_MB=$new_size
        fi
        
        log_warn "最终确定的系统盘压测文件大小为: ${FIO_FILE_SIZE_MB} MB"
        log_warn "==============================================="
        if ! start_fio_pressure "/var/tmp" "${LOG_DIR}/fio_pressure_file.log" "file"; then
            log_error "文件级 fio 启动失败"
            exit 1
        fi
    fi

    if [ ! -s "$PID_FIO_LIST" ]; then
        log_error "fio 压测未能启动，请检查磁盘状态"
        exit 1
    fi

    log_info ""
    log_info "Step 10: 等待 ${FIO_STEADY_WAIT}s 让 fio 达到稳态..."
    sleep "$FIO_STEADY_WAIT"

    local fio_dead=0 fio_pid_check
    while read -r fio_pid_check _; do
        [ -n "$fio_pid_check" ] || continue
        if ! pid_record_matches "${LOG_DIR}/.pid_fio_${fio_pid_check}" "$fio_pid_check"; then
            log_error "fio 在稳态等待期间退出或失去有效 PID 记录: ${fio_pid_check}"
            fio_dead=1
        fi
    done < "$PID_FIO_LIST"
    if [ "$fio_dead" -ne 0 ]; then
        log_error "fio 未能保持运行，拒绝启动 CPU/内存压力"
        exit 1
    fi

    log_info "Step 11: 获取 fio 资源占用，计算 CPU 压测参数..."
    local usage_info
    usage_info=$(compute_fio_usage)
    [ -z "$usage_info" ] && usage_info="0 0 $(nproc) $(grep MemTotal /proc/meminfo | awk '{print $2}') 0"
    local fio_cpus fio_mem_kb total_cpus total_mem_kb cached_kb
    read -r fio_cpus fio_mem_kb total_cpus total_mem_kb cached_kb <<< "$usage_info"

    local cpu_cores
    cpu_cores=$(echo "${total_cpus} * ${CPU_TARGET_PCT} / 100 - ${fio_cpus}" | bc | cut -d. -f1)
    [ -z "$cpu_cores" ] && cpu_cores=1
    [ "$cpu_cores" -lt 1 ] && cpu_cores=1

    local total_mem_gb
    total_mem_gb=$(echo "scale=1; ${total_mem_kb} / 1024 / 1024" | bc)

    local avail_mem_kb target_mem_mb
    avail_mem_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    target_mem_mb=$(echo "${avail_mem_kb} * ${MEM_TARGET_PCT} / 100 / 1024" | bc | cut -d. -f1)
    [ -z "$target_mem_mb" ] && target_mem_mb=1024
    [ "$target_mem_mb" -lt 1024 ] && target_mem_mb=1024

    local resource_tmp="${LOG_DIR}/.resource_usage.log.tmp"
    if ! {
        echo "=== Resource Usage Snapshot (after fio steady state) ==="
        echo "total_cpus=${total_cpus}"
        echo "cpu_cores=${cpu_cores}"
        echo "total_mem_kb=${total_mem_kb}"
        echo "avail_mem_kb=${avail_mem_kb}"
        echo "target_mem_mb=${target_mem_mb}"
        echo "vm_mode=${MEM_ACCESS_MODE}"
        echo "fio_mode=${fio_mode}"
        echo "total_duration_sec=${TOTAL_DURATION_SEC}"
    } > "$resource_tmp" || ! mv -f "$resource_tmp" "${LOG_DIR}/.resource_usage.log"; then
        log_error "资源状态文件写入失败，中止测试"
        exit 1
    fi

    log_info "  总 CPU 核心: ${total_cpus}"
    log_info "  stress CPU 核数: ${cpu_cores}"
    log_info "  总内存: ${total_mem_gb} GB"
    log_info "  stress-ng VM 加压: ${target_mem_mb}M (基于可用内存 ${MEM_TARGET_PCT}%, 4 workers, mode=${MEM_ACCESS_MODE})"
    log_info ""

    log_info "Step 12: 启动 stress-ng CPU 压测..."
    start_stress_cpu "$cpu_cores" "${LOG_DIR}/stress_cpu.log" &
    sleep 2
    local cpu_pid_check
    cpu_pid_check=$(awk 'NF{print $1; exit}' "$PID_STRESS" 2>/dev/null || true)
    if [ -z "$cpu_pid_check" ] || ! pid_is_expected "$PID_STRESS" "$cpu_pid_check"; then
        log_error "CPU 压测进程未能确认存活"
        exit 1
    fi

    log_info "Step 13: 启动内存压测..."
    start_stress_vm "${target_mem_mb}M" "$MEM_ACCESS_MODE" "${LOG_DIR}/stress_vm.log" &
    sleep 2
    local vm_alive_check=0 vm_expected=1 vm_pid_check vm_start_check
    if [ "${MEM_TOOL:-auto}" = "memtester" ] || { [ "${MEM_TOOL:-auto}" = "auto" ] && command -v memtester >/dev/null 2>&1; }; then
        vm_expected=$(cat "${LOG_DIR}/.vm_worker_count" 2>/dev/null || echo 2)
        case "$vm_expected" in ''|*[!0-9]*) vm_expected=2 ;; esac
        [ "$vm_expected" -lt 1 ] && vm_expected=2
    fi
    if [ -s "$PID_STRESS_VM" ]; then
        while read -r vm_pid_check vm_start_check; do
            pid_line_matches "$vm_pid_check" "$vm_start_check" && vm_alive_check=$(( vm_alive_check + 1 ))
        done < "$PID_STRESS_VM"
    fi
    if [ "$vm_alive_check" -lt "$vm_expected" ]; then
        log_error "内存压测进程数量不足: ${vm_alive_check}/${vm_expected}"
        exit 1
    fi

    log_info "Step 14: 记录压力开始时间并启动监控..."
    if ! write_state_file "$START_TIME_FILE" "$(date '+%Y-%m-%d %H:%M:%S')" || ! write_state_file "${LOG_DIR}/.start_timestamp" "$(date '+%s')" || ! write_state_file "$PID_OS_MEM_MON" "" || ! write_state_file "$PID_IPMI_MON" "" || ! write_state_file "$DMESG_SNAPSHOT_LIST_FILE" "" || ! write_state_file "$DMESG_STATUS_FILE" "start=PENDING"; then
        log_error "压力开始状态文件写入失败，中止测试"
        exit 1
    fi
    cat "$START_TIME_FILE"
    if dmesg > "${LOG_DIR}/dmesg_pressure_start.log" 2>&1; then
        if ! write_state_file "$DMESG_STATUS_FILE" "start=PASS"; then
            log_error "dmesg 状态写入失败"
            exit 1
        fi
    else
        if ! write_state_file "$DMESG_STATUS_FILE" "start=FAIL"; then
            log_error "dmesg 状态写入失败"
            exit 1
        fi
    fi
    if ! start_csv_monitor "$CSV_MON_INTERVAL" "$TOTAL_DURATION_SEC"; then
        log_error "OS 内存监控启动失败"
        exit 1
    fi
    if [ "$SKIP_IPMI" = "false" ]; then
        if ! start_ipmi_monitor "${LOG_DIR}/ipmi_monitor.log" "$PID_IPMI_MON" "$IPMI_MON_INTERVAL" "$TOTAL_DURATION_SEC"; then
            log_error "ipmitool 监控启动失败"
            exit 1
        fi
    else
        log_info "ipmitool 未安装, 跳过 BMC 传感器监控"
    fi
    if ! start_cpu_freq_monitor "$CSV_MON_INTERVAL" "$TOTAL_DURATION_SEC"; then
        log_error "CPU 频率监控启动失败"
        exit 1
    fi
    if ! start_mem_bw_monitor "$CSV_MON_INTERVAL" "$TOTAL_DURATION_SEC"; then
        log_error "内存带宽监控启动失败"
        exit 1
    fi
    if ! start_dmesg_monitor "$DMESG_SNAP_INTERVAL" "$TOTAL_DURATION_SEC"; then
        log_error "dmesg 监控启动失败"
        exit 1
    fi

    log_info "Step 15: 启动进程守护..."
    if ! start_stress_guardian "$TOTAL_DURATION_SEC"; then
        log_error "进程守护启动失败"
        exit 1
    fi

    release_operation_lock

    local end_time
    end_time=$(date -d "+${TOTAL_DURATION_SEC} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$(( TOTAL_DURATION_SEC / 3600 )) 小时后")

    echo ""
    echo "=============================================="
    echo "  整机 7x24H 混合压力测试 - 已启动"
    echo "=============================================="
    echo "  测试开始时间: $(cat "$START_TIME_FILE")"
    echo "  预计完成时间: ${end_time}"
    echo "----------------------------------------------"
    echo "  压测组件:"
    echo "    CPU:    ${STRESS_CMD} --cpu (${cpu_cores} 核)"
    echo "    内存:   ${MEM_TOOL:-auto} (${target_mem_mb}M, 可用内存${MEM_TARGET_PCT}%, mode=${MEM_ACCESS_MODE})"
    echo "    硬盘:   fio $(fio --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1) (50%读 50%写, 模式: ${fio_mode})"
    local monitor_suffix=""
    if [ "${SKIP_IPMI:-false}" = "true" ]; then
        monitor_suffix=" [跳过]"
    fi
    echo "    监控:   ipmitool BMC 硬件监控 (每${IPMI_MON_INTERVAL}s) / OS内存 (每${CSV_MON_INTERVAL}s)${monitor_suffix}"
    echo "----------------------------------------------"
    echo "  注意事项:"
    echo "  1. ${end_time} 后会自动执行 stop 进行收尾"
    echo "  2. 按 Ctrl+C 可提前终止并自动收尾"
    echo "  3. 查看状态:      $0 status"
    echo "=============================================="
    echo ""

    log_info "脚本将等待 ${TOTAL_DURATION_SEC}s (${TOTAL_DURATION_SEC}秒) 后自动停止..."
    sleep "$TOTAL_DURATION_SEC"
    log_info "压测时长已到 (${TOTAL_DURATION_SEC}s)，开始自动停止..."
    if [ "$(awk 'NF{print $1; exit}' "$START_FLAG" 2>/dev/null || echo "")" = "$$" ]; then
        do_stop
    else
        log_warn "本进程对应的测试已被外部 stop 结束或替换，跳过自动停止，避免影响新一轮测试"
    fi
}

do_stop() {
    if [ "${__STOPPING}" -eq 1 ]; then
        log_warn "do_stop 已在执行中，忽略重复调用"
        return 0
    fi
    __STOPPING=1

    check_root
    mkdir -p "$LOG_DIR"
    if [ "$__OP_LOCK_HELD" -eq 0 ]; then
        acquire_operation_lock || { __STOPPING=0; return 1; }
    fi
    exec &> >(tee -a "${LOG_DIR}/console_output.log")

    if ! check_test_running; then
        if [ -f "$START_FLAG" ]; then
            log_warn "未检测到正在运行的测试进程, 但发现残留标记文件, 将继续收集日志"
        else
            log_warn "测试未在运行, 无需停止"
            __STOPPING=0
            release_operation_lock
            return 0
        fi
    fi

    log_info "========== 停止 7x24H 混合压力测试 =========="

    local cleanup_failed=0
    if ! write_state_file "$STOPPING_FLAG" "$$"; then
        log_error "停止状态文件写入失败，继续清理但本轮不能标记为成功"
        cleanup_failed=1
    fi

    log_info "停止进程守护..."
    stop_pid_records "$PID_GUARDIAN" "" "进程守护" 1 || cleanup_failed=1

    log_info "停止 dmesg 快照监控进程..."
    stop_pid_records "$PID_DMESG_MON" "" "dmesg 快照监控" 1 || cleanup_failed=1

    local pressure_window_started=0
    if has_valid_timestamp "${LOG_DIR}/.start_timestamp"; then
        pressure_window_started=1
        log_info "收集压力窗口 dmesg 日志..."
        if dmesg > "${LOG_DIR}/dmesg_pressure_end.log" 2>&1; then
            append_state_line "$DMESG_STATUS_FILE" "end=PASS" || { log_error "dmesg 状态写入失败"; cleanup_failed=1; }
        else
            append_state_line "$DMESG_STATUS_FILE" "end=FAIL" || true
            log_error "dmesg 收尾快照采集失败"
            cleanup_failed=1
        fi
        if [ -f "${LOG_DIR}/dmesg_pressure_start.log" ] && [ -f "${LOG_DIR}/dmesg_pressure_end.log" ]; then
            if ! comm -13 <(sort "${LOG_DIR}/dmesg_pressure_start.log") <(sort "${LOG_DIR}/dmesg_pressure_end.log") > "${LOG_DIR}/dmesg_pressure.log"; then
                log_error "dmesg 压力窗口差分失败"
                cleanup_failed=1
            fi
        else
            : > "${LOG_DIR}/dmesg_pressure.log"
            cleanup_failed=1
        fi
        if ! write_state_file "$END_TIME_FILE" "$(date '+%Y-%m-%d %H:%M:%S')" || ! write_state_file "${LOG_DIR}/.end_timestamp" "$(date '+%s')"; then
            log_error "测试结束状态文件写入失败"
            cleanup_failed=1
        fi
    else
        log_info "压力窗口尚未开始，跳过压力窗口 dmesg/journal 采集"
    fi

    log_info "停止 fio 进程..."
    stop_pid_records "$PID_FIO_LIST" "${LOG_DIR}/.pid_fio_" "fio" 3 || cleanup_failed=1

    log_info "停止 stress-ng CPU 进程..."
    stop_pid_records "$PID_STRESS" "" "stress-ng CPU" 3 || cleanup_failed=1

    log_info "停止内存压测进程 (stress-ng VM / memtester)..."
    stop_pid_records "$PID_STRESS_VM" "${LOG_DIR}/.pid_vm_" "内存压测" 1 || cleanup_failed=1

    log_info "停止 OS 内存监控进程..."
    stop_pid_records "$PID_OS_MEM_MON" "" "OS 内存监控" 1 || cleanup_failed=1

    log_info "停止 ipmitool 监控进程..."
    stop_pid_records "$PID_IPMI_MON" "" "ipmitool 监控" 1 || cleanup_failed=1

    log_info "停止 CPU 频率监控进程..."
    stop_pid_records "$PID_CPU_FREQ_MON" "" "CPU 频率监控" 1 || cleanup_failed=1

    log_info "停止内存带宽监控进程..."
    stop_pid_records "$PID_MEM_BW_MON" "" "内存带宽监控" 1 || cleanup_failed=1

    if has_valid_timestamp "${LOG_DIR}/.start_timestamp"; then
        for required_state in "$PID_FIO_LIST" "$PID_STRESS" "$PID_STRESS_VM"; do
            if [ ! -s "$required_state" ]; then
                log_error "必需压力进程状态文件缺失或为空: ${required_state}"
                cleanup_failed=1
            fi
        done
    fi

    sleep 2

    if [ "$pressure_window_started" -eq 1 ]; then
        log_info "记录测试结束时间..."
        cat "$END_TIME_FILE" 2>/dev/null || true
    fi

    log_info "采集内存复位数据..."
    collect_mem_stats "RESET" > "${LOG_DIR}/mem_reset.log"
    log_info "内存复位数据已保存"

    log_info "收集测试后 BMC 传感器数据..."
    if command -v ipmitool &>/dev/null; then
        timeout 30 ipmitool sensor list > "${LOG_DIR}/sensor_after.log" 2>/dev/null || {
            log_warn "ipmitool sensor list 执行失败或超时"
        }
        log_info "传感器数据已保存至: ${LOG_DIR}/sensor_after.log"
    else
        log_info "ipmitool 未安装，跳过 BMC 传感器采集"
    fi

    log_info "收集系统日志..."
    if [ -f /var/log/messages ]; then
        cp /var/log/messages "${LOG_DIR}/var_log_messages.log" 2>/dev/null || true
    fi

    log_info "收集 journalctl 日志..."
    if [ "$pressure_window_started" -eq 0 ]; then
        write_state_file "$JOURNAL_STATUS_FILE" "SKIP" || { log_error "journalctl 状态写入失败"; cleanup_failed=1; }
    elif command -v journalctl &>/dev/null; then
        local since_arg until_arg
        since_arg="@$(cat "${LOG_DIR}/.start_timestamp" 2>/dev/null || echo 0)"
        until_arg="@$(cat "${LOG_DIR}/.end_timestamp" 2>/dev/null || echo now)"
        if journalctl --since "$since_arg" --until "$until_arg" --no-pager > "${LOG_DIR}/journalctl_pressure.log" 2>&1; then
            write_state_file "$JOURNAL_STATUS_FILE" "PASS" || { log_error "journalctl 状态写入失败"; cleanup_failed=1; }
        else
            write_state_file "$JOURNAL_STATUS_FILE" "FAIL" || true
            log_error "journalctl 采集失败"
            cleanup_failed=1
        fi
    else
        log_info "systemd-journal 不可用，跳过 journalctl"
        write_state_file "$JOURNAL_STATUS_FILE" "SKIP" || { log_error "journalctl 状态写入失败"; cleanup_failed=1; }
    fi

    log_info "恢复 swap..."
    local swap_state
    swap_state="$(cat "${LOG_DIR}/.swap_restore_status" 2>/dev/null || true)"
    if [ -f "$SWAP_ORIG_FILE" ]; then
        if restore_original_swap; then
            if ! write_state_file "${LOG_DIR}/.swap_restore_status" "PASS"; then
                log_error "swap 恢复状态写入失败"
                cleanup_failed=1
            fi
        else
            cleanup_failed=1
            if ! write_state_file "${LOG_DIR}/.swap_restore_status" "FAIL"; then
                log_error "swap 恢复状态写入失败"
            fi
        fi
    elif [ "$swap_state" = "RECORDING" ]; then
        log_info "swap 原始状态尚未记录完成，确认未执行 swap 修改"
        write_state_file "${LOG_DIR}/.swap_restore_status" "SKIP" || { log_error "swap 状态写入失败"; cleanup_failed=1; }
    else
        log_error "缺少原始 swap 状态记录，拒绝将清理标记为成功"
        cleanup_failed=1
        if ! write_state_file "${LOG_DIR}/.swap_restore_status" "FAIL"; then
            log_error "swap 恢复状态写入失败"
        fi
    fi

    log_info "卸载 fio 挂载点..."
    if [ -f "$FIO_MOUNT_LIST_FILE" ]; then
        while read -r part_dev mp mount_uuid; do
            [ -n "$mp" ] || continue
            if is_mountpoint "$mp"; then
                if ! mount_source_matches "$part_dev" "$mp" "$mount_uuid"; then
                    log_error "挂载源或 UUID 与记录不一致，拒绝卸载替代挂载: ${mp} (记录 ${part_dev} uuid=${mount_uuid}, 当前 $(get_mount_source "$mp") uuid=$(blkid -s UUID -o value "$(get_mount_source "$mp")" 2>/dev/null || echo 无法读取))"
                    cleanup_failed=1
                elif umount "$mp" 2>/dev/null; then
                    log_info "已卸载: ${mp}"
                else
                    log_error "卸载失败(可能被占用): ${mp} <- $(get_mount_source "$mp")"
                    cleanup_failed=1
                fi
            fi
        done < "$FIO_MOUNT_LIST_FILE"
    fi
    local pending_mount_failed=0
    if [ -s "$FIO_MOUNT_PENDING_FILE" ]; then
        while read -r part_dev mp mount_uuid; do
            [ -n "$mp" ] || continue
            if is_mountpoint "$mp"; then
                if mount_source_matches "$part_dev" "$mp" "$mount_uuid" && umount "$mp" 2>/dev/null; then
                    log_info "已卸载待清理挂载点: ${mp}"
                else
                    log_error "待清理挂载点卸载失败或源不一致: ${mp}"
                    cleanup_failed=1
                    pending_mount_failed=1
                fi
            fi
        done < "$FIO_MOUNT_PENDING_FILE"
    fi
    if [ "$pending_mount_failed" -eq 0 ] && ! write_state_file "$FIO_MOUNT_PENDING_FILE" ""; then
        log_error "待清理挂载状态清理失败"
        cleanup_failed=1
    fi
    rm -f /var/tmp/fio_pressure_testfile 2>/dev/null || true

    if ! record_planned_fio_results; then
        cleanup_failed=1
    fi
    if [ -f "$CLEANUP_FAILED_FLAG" ]; then
        cleanup_failed=1
    fi
    if [ "$pressure_window_started" -eq 1 ] && grep -qE '(^start=PENDING$|^start=FAIL$|^end=FAIL$|^snapshot_list=FAIL$|:FAIL$)' "$DMESG_STATUS_FILE" 2>/dev/null; then
        cleanup_failed=1
    fi

    log_info "生成性能报告..."
    if ! generate_performance_report; then
        cleanup_failed=1
    fi

    if [ "$cleanup_failed" -ne 0 ]; then
        log_error "清理未完全成功，保留运行标志并写入 ${CLEANUP_FAILED_FLAG}，拒绝允许下一轮覆盖现场"
        if [ -f "$CLEANUP_FAILED_FLAG" ]; then
            log_warn "保留既有清理失败原因: $(cat "$CLEANUP_FAILED_FLAG" 2>/dev/null || true)"
        else
            write_state_file "$CLEANUP_FAILED_FLAG" "$(date '+%s')" || true
        fi
        release_operation_lock
        __STOPPING=0
        return 1
    fi
    rm -f "$START_FLAG"
    rm -f "$STOPPING_FLAG"
    rm -f "$CLEANUP_FAILED_FLAG"
    release_operation_lock
    __STOPPING=0

    log_info ""
    log_info "=============================================="
    log_info "  整机 7x24H 混合压力测试 - 已停止"
    log_info "  报告文件: ${REPORT_FILE}"
    log_info "  日志目录: ${LOG_DIR}"
    log_info "=============================================="
}

do_status() {
    mkdir -p "$LOG_DIR"

    echo "=============================================="
    echo "  整机 7x24H 混合压力测试 - 状态"
    echo "=============================================="

    if check_test_running; then
        echo "  状态: 运行中"

        if has_valid_timestamp "${LOG_DIR}/.start_timestamp"; then
            local start_ts
            start_ts=$(cat "${LOG_DIR}/.start_timestamp")
            local now_ts elapsed_h
            now_ts=$(date '+%s')
            elapsed_h=$(echo "scale=1; (${now_ts} - ${start_ts}) / 3600" | bc)
            local target_h=168
            if [ -f "${LOG_DIR}/.resource_usage.log" ]; then
                local dur_saved
                dur_saved=$(get_mem_stat_val total_duration_sec "${LOG_DIR}/.resource_usage.log")
                case "$dur_saved" in ''|*[!0-9]*) ;; *) target_h=$(( dur_saved / 3600 )) ;; esac
            fi
            echo "  已运行: ${elapsed_h} 小时 (目标: ${target_h}H)"
        fi
    else
        echo "  状态: 未运行"
        if [ -f "${LOG_DIR}/.end_timestamp" ]; then
            local end_ts_text
            end_ts_text=$(cat "${LOG_DIR}/.end_timestamp")
            echo "  上次结束: $(date -d "@${end_ts_text}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'N/A')"
        fi
        if [ -f "$REPORT_FILE" ]; then
            echo "  报告文件: ${REPORT_FILE}"
        fi
    fi

    echo "----------------------------------------------"

    echo "  进程状态:"
    if [ -f "$PID_FIO_LIST" ] && [ -s "$PID_FIO_LIST" ]; then
        local fio_count=0 fio_total=0
        fio_total=$(awk 'NF{n++} END{print n+0}' "$PID_FIO_LIST")
        while read -r pid _; do
            [ -n "$pid" ] && pid_record_matches "${LOG_DIR}/.pid_fio_${pid}" "$pid" && fio_count=$(( fio_count + 1 ))
        done < "$PID_FIO_LIST"
        echo "    fio:            ${fio_count}/${fio_total} 进程运行中"
        if [ "$fio_total" -gt 0 ] && [ "$fio_count" -lt "$fio_total" ]; then
            echo "    *** 警告: $(( fio_total - fio_count )) 个 fio 进程已提前退出，请检查 ${LOG_DIR}/crash_fio.log ***"
        fi
    else
        echo "    fio:            未运行"
    fi

    if [ -f "$PID_STRESS" ]; then
        local stress_status_pid
        stress_status_pid=$(awk 'NF{print $1; exit}' "$PID_STRESS")
    fi
    if [ -n "${stress_status_pid:-}" ] && pid_is_expected "$PID_STRESS" "$stress_status_pid"; then
        echo "    stress-ng CPU:  运行中 (PID: ${stress_status_pid})"
    else
        echo "    stress-ng CPU:  未运行"
    fi

    if [ -s "$PID_STRESS_VM" ]; then
        local vm_alive=0 vm_total=0
        vm_total=$(awk 'NF{n++} END{print n+0}' "$PID_STRESS_VM")
        while read -r vpid vstart; do
            [ -n "$vpid" ] && pid_line_matches "$vpid" "$vstart" && vm_alive=$(( vm_alive + 1 ))
        done < "$PID_STRESS_VM"
        if [ "$vm_alive" -gt 0 ]; then
            echo "    内存压测:       ${vm_alive}/${vm_total} 进程运行中"
        else
            echo "    内存压测:       未运行 (${vm_total} 记录)"
        fi
    else
        echo "    内存压测:       未运行"
    fi

    if [ -f "$PID_OS_MEM_MON" ] && [ -s "$PID_OS_MEM_MON" ]; then
        local os_mem_count=0
        while read -r pid start; do
            [ -n "$pid" ] && pid_line_matches "$pid" "$start" && os_mem_count=$(( os_mem_count + 1 ))
        done < "$PID_OS_MEM_MON"
        echo "    OS 内存监控:    ${os_mem_count} 进程"
    else
        echo "    OS 内存监控:    未运行"
    fi

    if [ -f "$PID_IPMI_MON" ] && [ -s "$PID_IPMI_MON" ]; then
        local ipmi_count=0
        while read -r pid start; do
            [ -n "$pid" ] && pid_line_matches "$pid" "$start" && ipmi_count=$(( ipmi_count + 1 ))
        done < "$PID_IPMI_MON"
        echo "    ipmitool 监控:  ${ipmi_count} 进程"
    else
        echo "    ipmitool 监控:  未运行"
    fi

    if [ -f "$PID_CPU_FREQ_MON" ] && [ -s "$PID_CPU_FREQ_MON" ] && read -r status_pid status_start < "$PID_CPU_FREQ_MON" && pid_line_matches "$status_pid" "$status_start"; then
        echo "    CPU 频率监控:    运行中"
    else
        echo "    CPU 频率监控:    未运行"
    fi

    if [ -f "$PID_MEM_BW_MON" ] && [ -s "$PID_MEM_BW_MON" ] && read -r status_pid status_start < "$PID_MEM_BW_MON" && pid_line_matches "$status_pid" "$status_start"; then
        echo "    内存带宽监控:    运行中"
    else
        echo "    内存带宽监控:    未运行"
    fi

    if [ -f "$PID_DMESG_MON" ] && [ -s "$PID_DMESG_MON" ] && read -r status_pid status_start < "$PID_DMESG_MON" && pid_line_matches "$status_pid" "$status_start"; then
        echo "    dmesg 快照:      运行中"
    else
        echo "    dmesg 快照:      未运行"
    fi

    local guardian_status_pid=""
    [ -f "$PID_GUARDIAN" ] && guardian_status_pid=$(awk 'NF{print $1; exit}' "$PID_GUARDIAN")
    if [ -n "$guardian_status_pid" ] && pid_is_expected "$PID_GUARDIAN" "$guardian_status_pid"; then
        echo "    进程守护:       运行中 (PID: ${guardian_status_pid})"
    else
        echo "    进程守护:       未运行"
    fi

    echo "----------------------------------------------"

    local total_kb free_kb avail_kb swap_used_kb
    total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    free_kb=$(grep MemFree  /proc/meminfo | awk '{print $2}')
    avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    swap_total_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    swap_free_kb=$(grep SwapFree /proc/meminfo | awk '{print $2}')
    swap_used_kb=$(( swap_total_kb - swap_free_kb ))

    echo "  内存快照:"
    echo "    总内存:      $(echo "scale=1; ${total_kb} / 1024 / 1024" | bc) GB"
    echo "    可用内存:    $(echo "scale=1; ${avail_kb} / 1024 / 1024" | bc) GB"
    echo "    空闲内存:    $(echo "scale=1; ${free_kb} / 1024 / 1024" | bc) GB"
    echo "    Swap 已用:   $(echo "scale=1; ${swap_used_kb} / 1024" | bc) MB"

    echo "----------------------------------------------"

    echo "  日志目录: ${LOG_DIR}"
    if [ -d "$LOG_DIR" ]; then
        echo "  日志文件:"
        ls -lh "${LOG_DIR}"/*.log 2>/dev/null || echo "    (无)"
    fi

    echo "=============================================="
}

usage() {
    echo "用法: $0 {start|stop|status}"
    echo ""
    echo "  start   - 启动 7x24H 整机混合压力测试"
    echo "  stop    - 停止测试并生成性能报告"
    echo "  status  - 查看测试状态"
    echo ""
    echo "  配置文件: ${CONF_FILE}"
    echo ""
    echo "  可配置参数 (在配置文件中设置):"
    echo "    TOTAL_DURATION_SEC    测试持续秒数 (默认: 604800 = 168H)"
    echo "    CPU_TARGET_PCT        CPU 压测目标百分比 (默认: 95)"
    echo "    MEM_TARGET_PCT        内存压测目标百分比 (默认: 90)"
    echo "    MEM_ACCESS_MODE       内存访问模式: all/rand/seq/flip/rowhammer/walk/write"
    echo "    CSV_MON_INTERVAL     OS内存监控间隔秒数 (默认: 10)"
    echo "    IPMI_MON_INTERVAL     ipmitool BMC 监控间隔秒数 (默认: 600 = 10min)"
    echo "    MEM_TOOL              内存压测工具: stress-ng/memtester/auto (默认: stress-ng，按用例要求；auto=优先 memtester)"
    echo "    FIO_REQUIRED_VERSION  fio 要求版本 (默认: 3.13)"
    echo "    FIO_VERSION_STRICT    是否强制校验 fio 版本 true/false (默认: true)"
    echo "    CPU_THROTTLE_PCT      疑似降频判定阈值% (默认: 90，任一核频率低于 max 该比例即标记)"
    echo "    MEM_BW_MON            内存带宽监控: auto/off (默认: auto，依赖 perf uncore 计数器)"
    echo "    DMESG_SNAP_INTERVAL   dmesg 中途快照间隔秒数 (默认: 1800 = 30min，不清空 ring buffer)"
    echo "    FIO_STEADY_WAIT       fio 稳态等待秒数 (默认: 45)"
    echo "    SYSTEM_DISKS          显式指定所有系统盘 (必填，空格分隔；不再自动探测)"
    echo "    FIO_DISKS             指定测试盘 (空格分隔, 默认: 自动发现)"
    echo "    FIO_FILE_SIZE_MB      文件级 fio 文件大小 MB (默认: 10240)"
    echo "    FIO_FILE_NUMJOBS      文件级 fio 并发数 (默认: 1)"
    echo "    FIO_MOUNT_BASE        fio 挂载基础路径 (默认: /mnt/fio_pressure)"
    echo "    LOG_CLEANUP_MODE      日志目录清理策略: backup/delete/keep (默认: backup)"
    echo "    SYSTEM_LOG_ACTION     系统日志策略: backup/clear/none (默认: backup)"
}

case "${1:-}" in
    start)
        do_start
        ;;
    stop)
        do_stop
        ;;
    status)
        do_status
        ;;
    *)
        usage
        exit 1
        ;;
esac
