#!/bin/bash
# ============================================================================
# nvme_storage_perf.sh - Ali qualification: SSD basic performance under OS
# Version : 3.0
# Author  : SIT-Kit / Prz1y
# Updated : 2026-09-07
# ----------------------------------------------------------------------------
# Implements the Ali test case "OS SSD basic performance" end to end:
#   1. pre-check    : SMART std-1 collect, OS log full clear, SEL save+clear
#   2. body, per scenario in test-case order SR -> RR -> SW -> RW:
#        steady-state wipe (all target disks simultaneously):
#          SR/SW : 1M sequential write, loops=2 x 3 rounds = 6 full passes
#          RR/RW : 4K random write, numjobs=4, QD64, 8 h time_based
#        formal runs: jobs=1 and jobs=4, QD64, 10 min, libaio, direct
#      one fio job section per disk -> per-disk bw/iops/latency in JSON
#      iostat per-disk series: 1 s during formal runs, 10 s during wipes
#      temperature sampling: ipmitool sdr elist + per-disk nvme smart-log
#   3. post-check   : SMART std-2, OS/SEL log collect
#   4. report       : perf_report.py parse -> build (xlsx via openpyxl)
# Modes:
#   -m multi | single | all | report
#     multi  : pre-check -> all-disk joint suite -> post-check -> report
#     single : pre-check -> single-disk suite (first disk, own wipes) -> ...
#     all    : multi then single in one session (default)
#     report : re-run parse+build only (requires -b)
#   -b BASE_DIR     resume an interrupted run, or target dir for report mode
# Resume: every step is checkpointed in <BASE_DIR>/state/; rerun with -b.
# Requirements: root; fio / nvme-cli / smartmontools / pciutils / sysstat /
#   python3; openpyxl is auto-installed in preflight from the distro source.
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --------------------------- configuration ---------------------------------
# Every value can be overridden via environment (MODE, RUNTIME, ...).
# Flow-test example (seconds instead of the real case durations):
#   RUNTIME=10 WIPE_SEQ_RUNTIME=30 WIPE_RAND_RUNTIME=30 SETTLE_SECS=2 \
#     bash nvme_storage_perf.sh -m all
MODE="${MODE:-all}"
BASE_DIR_ARG=""
RUNTIME="${RUNTIME:-600}"           # formal run length, s (test case: 10 min)
QUEUE_DEPTH="${QUEUE_DEPTH:-64}"
JOB_LIST=(1 4)
WIPE_SEQ_ROUNDS="${WIPE_SEQ_ROUNDS:-3}"   # x loops=2 => 6 full passes (SSD)
WIPE_SEQ_LOOPS="${WIPE_SEQ_LOOPS:-2}"
WIPE_SEQ_RUNTIME="${WIPE_SEQ_RUNTIME:-}"  # set => time-based seq wipe (flow test)
WIPE_RAND_RUNTIME="${WIPE_RAND_RUNTIME:-28800}"   # 8 h (test-case text)
WIPE_RAND_JOBS="${WIPE_RAND_JOBS:-4}"
IOSTAT_FORMAL_INTERVAL="${IOSTAT_FORMAL_INTERVAL:-1}"
IOSTAT_WIPE_INTERVAL="${IOSTAT_WIPE_INTERVAL:-10}"
TEMP_INTERVAL_FORMAL="${TEMP_INTERVAL_FORMAL:-30}"
TEMP_INTERVAL_WIPE="${TEMP_INTERVAL_WIPE:-60}"
DEV_MODEL_FILTER="${DEV_MODEL_FILTER:-P7A40}"
TARGET_DEVS_OVERRIDE="${TARGET_DEVS:-}"   # env: space-separated block dev names
SINGLE_DEV="${SINGLE_DEV:-}"              # empty = first detected disk
RUN_PRE_CHECK="yes"
RUN_POST_CHECK="yes"
SETTLE_SECS="${SETTLE_SECS:-10}"
SKIP_WIPES="${SKIP_WIPES:-no}"       # yes = mark wipes done, run formal only

usage() {
    cat <<EOF
Usage: $0 [-m multi|single|all|report] [-b BASE_DIR]
  multi  : pre-check -> all-disk joint suite -> post-check -> report
  single : pre-check -> single-disk suite -> post-check -> report
  all    : multi then single in one session (default)
  report : re-run parse+build only on an existing BASE_DIR (needs -b)
  -b     : base dir to resume / to report on
EOF
}

while getopts "m:b:h" opt; do
    case "$opt" in
        m) MODE="$OPTARG" ;;
        b) BASE_DIR_ARG="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done
case "$MODE" in
    multi|single|all|report) ;;
    *) usage; exit 1 ;;
esac

# --------------------------- globals ---------------------------------------
BASE_DIR=""
LOG_DIR=""; SMART_DIR=""; PERF_DIR=""; MON_DIR=""; TEMP_DIR=""
SEL_DIR=""; STATE_DIR=""; INV_DIR=""; CSV_DIR=""; REPORT_DIR=""
RUN_LOG=""
MON_PIDS=()
TARGET_DEVS=()
HAS_OPENPYXL="no"
T_START=$(date +%s)

log_info()  { echo "[INFO]  $(date '+%F %T') $*" | tee -a "$RUN_LOG" 2>/dev/null || echo "[INFO]  $(date '+%F %T') $*"; }
log_warn()  { echo "[WARN]  $(date '+%F %T') $*" | tee -a "$RUN_LOG" >&2 2>/dev/null || echo "[WARN]  $(date '+%F %T') $*" >&2; }
log_error() { echo "[ERROR] $(date '+%F %T') $*" | tee -a "$RUN_LOG" >&2 2>/dev/null || echo "[ERROR] $(date '+%F %T') $*" >&2; }
die()       { log_error "$*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "must run as root (sudo bash $0)"
}

init_dirs() {
    if [[ -n "$BASE_DIR_ARG" ]]; then
        BASE_DIR="$BASE_DIR_ARG"
        [[ -d "$BASE_DIR" ]] || die "BASE_DIR does not exist: $BASE_DIR"
    else
        BASE_DIR="${SCRIPT_DIR}/NVME_ALI_QUAL_$(date +%Y%m%d_%H%M%S)"
    fi
    LOG_DIR="$BASE_DIR/logs"; SMART_DIR="$BASE_DIR/smart_logs"
    PERF_DIR="$BASE_DIR/perf_data"; MON_DIR="$BASE_DIR/monitor"
    TEMP_DIR="$BASE_DIR/temp"; SEL_DIR="$BASE_DIR/sel_logs"
    STATE_DIR="$BASE_DIR/state"; INV_DIR="$BASE_DIR/inventory"
    CSV_DIR="$BASE_DIR/csv"; REPORT_DIR="$BASE_DIR/report"
    RUN_LOG="$BASE_DIR/run.log"
    mkdir -p "$LOG_DIR" "$SMART_DIR" "$PERF_DIR" "$MON_DIR" "$TEMP_DIR" \
             "$SEL_DIR" "$STATE_DIR" "$INV_DIR" "$CSV_DIR" "$REPORT_DIR" \
             "$BASE_DIR/bin"
}

is_done()  { [[ -f "$STATE_DIR/$1.done" ]]; }
step_done() { : > "$STATE_DIR/$1.done"; log_info "step done: $1"; }

elapsed() {
    local s=$(( $(date +%s) - T_START ))
    printf '%02dh%02dm%02ds' $((s/3600)) $(( (s%3600)/60 )) $((s%60))
}

cleanup() {
    if [[ ${#MON_PIDS[@]} -gt 0 ]]; then
        kill "${MON_PIDS[@]}" 2>/dev/null || true
        local p
        for p in "${MON_PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
        MON_PIDS=()
    fi
}
trap cleanup EXIT INT TERM

# --------------------------- phase 0: preflight ----------------------------
install_pkg() {
    # install_pkg <pkg>  — best effort from remote distro source
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y "$1" >/dev/null 2>&1 && return 0
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$1" >/dev/null 2>&1 && return 0
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1; apt-get install -y "$1" >/dev/null 2>&1 && return 0
    fi
    return 1
}

check_deps() {
    local missing=() t
    for t in fio nvme smartctl lspci python3; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "missing tools: ${missing[*]} (install fio nvme-cli smartmontools pciutils python3)"
    fi

    if ! command -v iostat >/dev/null 2>&1; then
        log_warn "iostat missing, installing sysstat from remote source"
        install_pkg sysstat || die "cannot install sysstat"
    fi

    if ! command -v ipmitool >/dev/null 2>&1; then
        log_warn "ipmitool missing: SEL handling and elist temperature sampling are skipped"
    fi

    # openpyxl for the report builder (parse itself is stdlib-only)
    if python3 -c "import openpyxl" >/dev/null 2>&1; then
        HAS_OPENPYXL=yes
    else
        log_warn "openpyxl missing, trying remote source install"
        if install_pkg python3-openpyxl || python3 -m pip install openpyxl >/dev/null 2>&1; then
            python3 -c "import openpyxl" >/dev/null 2>&1 && HAS_OPENPYXL=yes
        fi
        [[ "$HAS_OPENPYXL" == "yes" ]] || log_warn "openpyxl unavailable: parse/CSV still produced, xlsx build must run elsewhere"
    fi

    local fio_v
    fio_v=$(fio --version 2>/dev/null || echo unknown)
    echo "$fio_v" > "$INV_DIR/fio_version.txt"
    [[ "$fio_v" == "fio-3.13" ]] || log_warn "fio version is '$fio_v', test case requires fio-3.13 (recorded as evidence, continuing)"
    log_info "dependency check passed (fio=$fio_v)"
}

detect_devs() {
    if [[ ${#TARGET_DEVS[@]} -eq 0 && -n "$TARGET_DEVS_OVERRIDE" ]]; then
        read -ra TARGET_DEVS <<< "$TARGET_DEVS_OVERRIDE"
    fi
    if [[ ${#TARGET_DEVS[@]} -eq 0 ]]; then
        local line name model
        while read -r line; do
            [[ -z "$line" ]] && continue
            name=$(awk '{print $1}' <<< "$line")
            model=$(cut -d' ' -f2- <<< "$line")
            if grep -qi "$DEV_MODEL_FILTER" <<< "$model"; then
                TARGET_DEVS+=("$name")
            fi
        done < <(lsblk -dno NAME,MODEL | grep -v '^$')
    fi
    [[ ${#TARGET_DEVS[@]} -gt 0 ]] || die "no block device matches model filter '$DEV_MODEL_FILTER'; set TARGET_DEVS manually"
    local d
    for d in "${TARGET_DEVS[@]}"; do
        [[ -b "/dev/$d" ]] || die "/dev/$d is not a block device"
    done
    SINGLE_DEV="${SINGLE_DEV:-${TARGET_DEVS[0]}}"
    log_info "target disks (${#TARGET_DEVS[@]}): ${TARGET_DEVS[*]}"
    log_info "single-disk suite target: $SINGLE_DEV"
}

inventory_collect() {
    log_info "collecting environment evidence"
    dmidecode -t1 2>/dev/null | grep -E 'Manufacturer|Product Name|Serial Number' \
        > "$INV_DIR/host.txt" || true
    lscpu | grep -E '^Model name|^Socket\(s\)|^Core|^NUMA node\(s\)' \
        > "$INV_DIR/cpu.txt" || true
    local numa_n
    numa_n=$(awk -F: '/^NUMA node\(s\)/{gsub(/ /,"",$2); print $2}' "$INV_DIR/cpu.txt" 2>/dev/null || echo 0)
    [[ "$numa_n" -le 1 ]] || log_warn "NUMA node(s)=$numa_n: test case requires NUMA OFF (BIOS)"

    nvme list > "$INV_DIR/nvme_list.txt" 2>/dev/null || true
    lspci -Dnn | grep -i nvme > "$INV_DIR/pcie_link.txt" || true
    local d addr node
    : > "$INV_DIR/numa_map.txt"
    for d in "${TARGET_DEVS[@]}"; do
        addr=$(cat "/sys/block/$d/device/address" 2>/dev/null || true)
        [[ -n "$addr" ]] && lspci -s "$addr" -vv 2>/dev/null \
            | grep -E 'LnkCap:|LnkSta:' >> "$INV_DIR/pcie_link.txt" || true
        # dev -> BDF -> NUMA node mapping (evidence; no binding is applied)
        if [[ -n "$addr" ]]; then
            node=$(cat "/sys/bus/pci/devices/$addr/numa_node" 2>/dev/null || echo "?")
            printf '%s  BDF=%s  numa_node=%s\n' "$d" "$addr" "$node" >> "$INV_DIR/numa_map.txt"
        fi
    done
    lscpu | grep -E '^NUMA node' >> "$INV_DIR/numa_map.txt" 2>/dev/null || true
    log_info "dev->BDF->NUMA mapping saved to $INV_DIR/numa_map.txt"

    echo "dev,model,serial,firmware,size" > "$INV_DIR/dev_inventory.csv"
    for d in "${TARGET_DEVS[@]}"; do
        {
            printf '%s,%s,%s,%s,%s\n' "$d" \
                "$(nvme id-ctrl "/dev/$d" 2>/dev/null | awk -F: '/^mn /{gsub(/^ +/,"",$2); print $2}' | tr -d ',')" \
                "$(nvme id-ctrl "/dev/$d" 2>/dev/null | awk -F: '/^sn /{gsub(/^ +/,"",$2); print $2}')" \
                "$(nvme id-ctrl "/dev/$d" 2>/dev/null | awk -F: '/^fr /{gsub(/^ +/,"",$2); print $2}')" \
                "$(lsblk -dno SIZE "/dev/$d" 2>/dev/null)"
        } >> "$INV_DIR/dev_inventory.csv"
    done
    log_info "inventory saved to $INV_DIR"
}

# --------------------------- phase 1: pre-check ----------------------------
smart_collect() { # smart_collect <tag pre|post>
    local tag="$1" d out
    log_info "SMART standard-$( [[ $tag == pre ]] && echo 1 || echo 2 ) collect"
    for d in "${TARGET_DEVS[@]}"; do
        out="$SMART_DIR/${tag}_standard_$d.log"
        if nvme smart-log "/dev/$d" > "$out" 2>&1; then
            log_info "$d: $out"
        elif smartctl -a "/dev/$d" > "$out" 2>/dev/null; then
            log_info "$d: $out (smartctl fallback)"
        else
            log_warn "$d: SMART collect failed"
        fi
    done
}

os_log_clear() {
    log_info "OS log full clear (dmesg + messages/secure + journald)"
    dmesg -C 2>/dev/null || log_warn "dmesg -C failed"
    local f
    for f in /var/log/messages /var/log/secure; do
        [[ -f "$f" ]] && truncate -s 0 "$f"
    done
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --rotate 2>/dev/null || true
        journalctl --vacuum-time=1s >/dev/null 2>&1 || true
    fi
    systemctl restart systemd-journald 2>/dev/null || true
    systemctl restart rsyslog 2>/dev/null || service rsyslog restart >/dev/null 2>&1 || true
    date '+%F %T' > "$LOG_DIR/os_log_clean_marker.txt"
    log_info "OS logs cleared, marker: $(cat "$LOG_DIR/os_log_clean_marker.txt")"
}

sel_clear() {
    log_info "SEL save + clear"
    if command -v ipmitool >/dev/null 2>&1; then
        ipmitool sel elist > "$SEL_DIR/pre_clear.elist" 2>&1 || true
        ipmitool sel clear >/dev/null 2>&1 || log_warn "ipmitool sel clear failed"
        log_info "SEL saved to $SEL_DIR/pre_clear.elist and cleared"
    else
        log_warn "ipmitool unavailable, SEL handling skipped"
    fi
}

# --------------------------- monitors --------------------------------------
write_temp_sampler() {
    cat > "$BASE_DIR/bin/temp_sampler.sh" <<'EOS'
#!/bin/bash
# temp_sampler.sh <tag> <interval> <dev...>  (env: TEMP_DIR)
tag=$1; tint=$2; shift 2
devs=("$@")
: "${TEMP_DIR:?TEMP_DIR not set}"
while true; do
    echo "##### $(date '+%F %T')" >> "$TEMP_DIR/${tag}_elist.log"
    ipmitool sdr elist >> "$TEMP_DIR/${tag}_elist.log" 2>/dev/null || true
    ts=$(date '+%F %T')
    for d in "${devs[@]}"; do
        # "temperature : 39 C (312 Kelvin)" -> first standalone integer = 39
        t=$(nvme smart-log "/dev/$d" 2>/dev/null \
            | awk '/^temperature/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}')
        [ -n "$t" ] && echo "$ts $d $t" >> "$TEMP_DIR/${tag}_nvme_temp.log"
    done
    sleep "$tint"
done
EOS
    chmod +x "$BASE_DIR/bin/temp_sampler.sh"
}

start_mon() { # start_mon <tag> <iostat-int> <temp-int> <dev...>
    local tag=$1 iint=$2 tint=$3; shift 3
    iostat -xmt "$iint" "$@" > "$MON_DIR/${tag}_iostat.log" 2>&1 &
    MON_PIDS+=($!)
    TEMP_DIR="$TEMP_DIR" bash "$BASE_DIR/bin/temp_sampler.sh" "$tag" "$tint" "$@" &
    MON_PIDS+=($!)
}

stop_mon() {
    cleanup
    log_info "monitors stopped"
}

# --------------------------- fio engine ------------------------------------
scen_rw()  { case "$1" in SR) echo read;; RR) echo randread;; SW) echo write;; RW) echo randwrite;; esac; }
scen_bs()  { case "$1" in SR|SW) echo 1024k;; RR|RW) echo 4k;; esac; }

build_formal_jobfile() { # <out> <scen> <jobs> <dev...>
    local out=$1 scen=$2 jobs=$3; shift 3
    local rw bs d
    rw=$(scen_rw "$scen"); bs=$(scen_bs "$scen")
    {
        echo "[global]"
        echo "ioengine=libaio"; echo "direct=1"; echo "thread=1"
        echo "group_reporting=1"; echo "time_based=1"; echo "runtime=$RUNTIME"
        echo "size=100%"; echo "rw=$rw"; echo "bs=$bs"
        echo "iodepth=$QUEUE_DEPTH"; echo "numjobs=$jobs"
        case "$rw" in rand*) echo "norandommap=1"; echo "randrepeat=0";; esac
        # new_group=1: each section is its own fio group, so group_reporting
        # aggregates that section only (with its numjobs clones) instead of
        # merging the whole file into one entry
        for d in "$@"; do printf '\n[%s]\nnew_group=1\nfilename=/dev/%s\n' "$d" "$d"; done
    } > "$out"
}

build_wipe_jobfile() { # <out> <scen> <dev...>  (seq: loops x passes / rand: 8h time_based)
    local out=$1 scen=$2; shift 2
    local rw d
    rw=$(scen_rw "$scen")
    {
        echo "[global]"
        echo "ioengine=libaio"; echo "direct=1"; echo "thread=1"
        echo "group_reporting=1"; echo "size=100%"
        case "$scen" in
            SR|SW) echo "rw=write"; echo "bs=1024k"
                   echo "iodepth=$QUEUE_DEPTH"; echo "numjobs=1"
                   if [[ -n "$WIPE_SEQ_RUNTIME" ]]; then
                       echo "time_based=1"; echo "runtime=$WIPE_SEQ_RUNTIME"
                   else
                       echo "loops=$WIPE_SEQ_LOOPS"
                   fi ;;
            RR|RW) echo "rw=randwrite"; echo "bs=4k"
                   echo "iodepth=$QUEUE_DEPTH"; echo "numjobs=$WIPE_RAND_JOBS"
                   echo "time_based=1"; echo "runtime=$WIPE_RAND_RUNTIME"
                   echo "norandommap=1"; echo "randrepeat=0" ;;
        esac
        for d in "$@"; do printf '\n[%s]\nnew_group=1\nfilename=/dev/%s\n' "$d" "$d"; done
    } > "$out"
}

verify_json_jobs() { # verify_json_jobs <json> <label>
    local js=$1 label=$2 njobs
    njobs=$(python3 - "$js" <<'PYEOF' 2>/dev/null || echo 0
import json, sys
try:
    print(len(json.load(open(sys.argv[1])).get("jobs", [])))
except Exception:
    print(0)
PYEOF
)
    [[ "$njobs" -gt 0 ]] || die "fio produced no job results ($label)"
    log_info "fio done: $label, jobs in json: $njobs ($(elapsed))"
}

incremental_parse() {
    python3 "$SCRIPT_DIR/perf_report.py" parse -b "$BASE_DIR" >/dev/null 2>&1 \
        || log_warn "incremental parse failed (non-fatal, will retry in report phase)"
}

# --------------------------- test steps ------------------------------------
formal_step() { # formal_step <phase> <scen> <jobs> <dev...>
    local phase=$1 scen=$2 jobs=$3; shift 3
    local step="${phase}_${scen}_jobs${jobs}"
    is_done "$step" && { log_info "skip done step: $step"; return; }
    local jf="$PERF_DIR/formal_${step}.fio"
    local js="$PERF_DIR/formal_${step}.json"
    build_formal_jobfile "$jf" "$scen" "$jobs" "$@"
    start_mon "$step" "$IOSTAT_FORMAL_INTERVAL" "$TEMP_INTERVAL_FORMAL" "$@"
    if ! fio "$jf" --output-format=json --output="$js" > "${js%.json}.stdout" 2>&1; then
        stop_mon
        die "fio FAILED ($step); see ${js%.json}.stdout"
    fi
    stop_mon
    verify_json_jobs "$js" "$step"
    step_done "$step"
    incremental_parse
    sleep "$SETTLE_SECS"
}

run_fio_job_verify() { # verify json has one job entry per device
    local js=$1 label=$2 want=$3
    want=$(python3 -c "import sys;print(len(sys.argv)-3)" "$@" 2>/dev/null || echo 0)
    local njobs
    njobs=$(python3 - "$js" <<'PYEOF' 2>/dev/null || echo 0
import json, sys
try:
    print(len(json.load(open(sys.argv[1])).get("jobs", [])))
except Exception:
    print(0)
PYEOF
)
    [[ "$njobs" -gt 0 ]] || die "fio produced no job results ($label)"
    log_info "fio done: $label, jobs in json: $njobs ($(elapsed))"
}

wipe_step() { # wipe_step <phase> <scen> <dev...>
    local phase=$1 scen=$2; shift 2
    local step="${phase}_${scen}_wipe"
    is_done "$step" && { log_info "skip done step: $step"; return; }
    if [[ "$SKIP_WIPES" == "yes" ]]; then
        log_info "SKIP_WIPES=yes: mark $step done without preconditioning"
        step_done "$step"
        return
    fi
    local tag="wipe_${phase}_${scen}"
    start_mon "$tag" "$IOSTAT_WIPE_INTERVAL" "$TEMP_INTERVAL_WIPE" "$@"
    case "$scen" in
        SR|SW)
            local r jf js
            for r in $(seq 1 "$WIPE_SEQ_ROUNDS"); do
                jf="$PERF_DIR/wipe_${step}_seq_r${r}.fio"
                js="$PERF_DIR/wipe_${step}_seq_r${r}.json"
                build_wipe_jobfile "$jf" "$scen" "$@"
                log_info "seq wipe round $r/$WIPE_SEQ_ROUNDS (loops=$WIPE_SEQ_LOOPS each) start"
                if ! fio "$jf" --output-format=json --output="$js" > "${js%.json}.stdout" 2>&1; then
                    stop_mon
                    die "fio FAILED (seq wipe $step round $r); see ${js%.json}.stdout"
                fi
                verify_json_jobs "$js" "wipe_${step}_seq_r${r}"
                log_info "seq wipe round $r done ($(elapsed))"
            done
            log_info "seq wipe complete: $WIPE_SEQ_ROUNDS x $WIPE_SEQ_LOOPS = $((WIPE_SEQ_ROUNDS*WIPE_SEQ_LOOPS)) full passes"
            ;;
        RR|RW)
            local jf="$PERF_DIR/wipe_${step}_rand.fio"
            local js="$PERF_DIR/wipe_${step}_rand.json"
            build_wipe_jobfile "$jf" "$scen" "$@"
            log_info "rand wipe start: ${WIPE_RAND_RUNTIME}s ($(( WIPE_RAND_RUNTIME/3600 ))h), jobs=$WIPE_RAND_JOBS per disk"
            if ! fio "$jf" --output-format=json --output="$js" > "${js%.json}.stdout" 2>&1; then
                stop_mon
                die "fio FAILED (rand wipe $step); see ${js%.json}.stdout"
            fi
            verify_json_jobs "$js" "wipe_${step}_rand"
            log_info "rand wipe done ($(elapsed))"
            ;;
    esac
    stop_mon
    step_done "$step"
}

run_suite() { # run_suite <phase> <dev...>
    local phase=$1; shift
    local scen jobs
    for scen in SR RR SW RW; do
        log_info "================ $phase scenario $scen ================"
        wipe_step "$phase" "$scen" "$@"
        for jobs in "${JOB_LIST[@]}"; do
            formal_step "$phase" "$scen" "$jobs" "$@"
        done
    done
}

# --------------------------- phase 4: post-check ---------------------------
os_log_post() {
    log_info "post OS log collect"
    dmesg > "$LOG_DIR/dmesg_post.log" 2>&1 || true
    if [[ -f "$LOG_DIR/os_log_clean_marker.txt" ]] && command -v journalctl >/dev/null 2>&1; then
        journalctl --since="$(cat "$LOG_DIR/os_log_clean_marker.txt")" --no-pager \
            > "$LOG_DIR/journalctl_post.log" 2>&1 || true
    fi
    [[ -f /var/log/messages ]] && cp /var/log/messages "$LOG_DIR/messages_post.log" 2>/dev/null || true
    log_info "OS logs saved to $LOG_DIR"
}

sel_post() {
    if command -v ipmitool >/dev/null 2>&1; then
        ipmitool sel elist > "$SEL_DIR/post.elist" 2>&1 || true
        log_info "post SEL saved to $SEL_DIR/post.elist"
    fi
}

# --------------------------- phase 5: report -------------------------------
phase_report() {
    log_info "report phase: parse"
    python3 "$SCRIPT_DIR/perf_report.py" parse -b "$BASE_DIR" \
        || die "parse failed; artifacts remain under $BASE_DIR"
    if [[ "$HAS_OPENPYXL" == "yes" ]]; then
        log_info "report phase: build xlsx"
        python3 "$SCRIPT_DIR/perf_report.py" build -b "$BASE_DIR" \
            || die "xlsx build failed; CSVs remain under $CSV_DIR"
    else
        log_warn "openpyxl unavailable on this host: run 'perf_report.py build -b $BASE_DIR' where openpyxl exists"
    fi
    ls -l "$REPORT_DIR" "$CSV_DIR" 2>/dev/null || true
}

# --------------------------- main ------------------------------------------
main() {
    require_root
    init_dirs
    write_temp_sampler

    case "$MODE" in
        report)
            [[ -n "$BASE_DIR_ARG" ]] || die "report mode requires -b BASE_DIR"
            phase_report
            ;;
        multi|single|all)
            check_deps
            detect_devs
            inventory_collect
            if [[ "$RUN_PRE_CHECK" == "yes" ]] && ! is_done pre_smart1; then
                smart_collect pre; step_done pre_smart1
            fi
            if [[ "$RUN_PRE_CHECK" == "yes" ]] && ! is_done pre_osclear; then
                os_log_clear; step_done pre_osclear
            fi
            if [[ "$RUN_PRE_CHECK" == "yes" ]] && ! is_done pre_selclear; then
                sel_clear; step_done pre_selclear
            fi
            if [[ "$MODE" == "multi" || "$MODE" == "all" ]]; then
                run_suite multi "${TARGET_DEVS[@]}"
            fi
            if [[ "$MODE" == "single" || "$MODE" == "all" ]]; then
                run_suite single "$SINGLE_DEV"
            fi
            if [[ "$RUN_POST_CHECK" == "yes" ]] && ! is_done post_smart2; then
                smart_collect post; step_done post_smart2
            fi
            if [[ "$RUN_POST_CHECK" == "yes" ]] && ! is_done post_oslogs; then
                os_log_post; step_done post_oslogs
            fi
            if [[ "$RUN_POST_CHECK" == "yes" ]] && ! is_done post_sel; then
                sel_post; step_done post_sel
            fi
            phase_report
            ;;
    esac

    log_info "============================================================"
    log_info "MODE=$MODE finished in $(elapsed)"
    log_info "base dir : $BASE_DIR"
    log_info "perf json: $PERF_DIR | csv: $CSV_DIR | report: $REPORT_DIR"
    log_info "smart: $SMART_DIR | sel: $SEL_DIR | logs: $LOG_DIR"
    log_info "monitor: $MON_DIR | temp: $TEMP_DIR | inventory: $INV_DIR"
    log_info "============================================================"
}

main "$@"
