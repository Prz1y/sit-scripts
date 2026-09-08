#!/bin/bash
#===============================================================================
# Memtester_Stress_Test_Linux_HE.sh
#
# memtester constant-load stress test (default 12h) with full evidence collection.
# One memtester process per CPU core; every process holds (total-RESERVE)/cores
# memory, so CPU and memory usage both stay near 100% for the whole duration.
#
# Usage:
#   ./Memtester_Stress_Test_Linux_HE.sh <HOURS> [MINUTES]
#     e.g. ./Memtester_Stress_Test_Linux_HE.sh 12        # 12h stress test
#          ./Memtester_Stress_Test_Linux_HE.sh 0 5       # 5min smoke test
#
# Acceptance mapping (result files under RESULT_DIR):
#   [1] tool uploaded/extracted/compiled  -> test_environment.log, analysis/build.log
#   [2] script ran full duration          -> proc_rc.txt (every proc rc=124/0)
#   [3] CPU & MEM usage >= threshold      -> usage.log, top_snapshots.log, summary_report.txt
#   [4] memtester proc count == cores     -> usage.log (procs column), summary_report.txt
#   [5] no FAILURE in memtester output    -> memtester_pNN.log, summary_report.txt
#   [6] no error in dmesg/messages/journal/SEL -> analysis/error_matches.log, summary_report.txt
#   [7] ORIGINAL logs saved after test    -> logs_after/* (full raw copies)
#   logs_before/* holds pre-test originals saved BEFORE clearing (nothing lost)
#
# Log clearing before test (acceptance #7, all logs PHYSICALLY cleared):
#   - dmesg ring buffer  : saved then cleared with `dmesg -c`
#   - /var/log/messages  : saved then truncated (`: > file`)
#   - journald           : flushed + rotated + vacuumed (--vacuum-time=1s) so
#                          only test-period entries remain; IRREVERSIBLE
#   - BMC SEL            : saved then `ipmitool sel clear` (default CLEAR_SEL=1,
#                          spec requires physical clear; IRREVERSIBLE)
#                          If ipmitool is unavailable or clear fails (common on
#                          OpenBMC), baseline comparison is used automatically.
#   - fallback           : if a clear fails, post-test analysis for that log is
#                          scoped via --since $TS_START (baseline comparison)
#
# Config via environment variables:
#   RESULT_DIR       output dir          (default: ./memtester_result_<ts>)
#   SAMPLE_INTERVAL  usage sampling, s   (default 120)
#   RESERVE_MB       MB kept for OS      (default: auto = 10%, min 1024)
#   CPU_THRESHOLD    pass threshold, %   (default 90)
#   MEM_THRESHOLD    pass threshold, %   (default 90)
#   CLEAR_SEL        1/0                 (default 1)
#   MEMTESTER_SRC    memtester src dir for auto build (default: auto-detect)
#   ITERATIONS       memtester iteration count (default 1000000; duration is
#                    enforced by `timeout`, iterations never exhaust)
#   IPMITOOL         full ipmitool cmd, e.g.
#                    IPMITOOL="ipmitool -I lanplus -H 10.8.149.24 -U root -P xxxx"
#
# Dependencies: bash, coreutils(timeout), procps(top/ps), optional: ipmitool,
#               journalctl (systemd), stdbuf.
#===============================================================================

export LC_ALL=C

HOURS="${1:-}"
MINUTES="${2:-0}"
DUR=$(( HOURS * 3600 + MINUTES * 60 ))

RD="${RESULT_DIR:-$(pwd)/memtester_result_$(date +%Y%m%d_%H%M%S)}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-120}"
RESERVE_MB="${RESERVE_MB:-0}"
CPU_THRESHOLD="${CPU_THRESHOLD:-90}"
MEM_THRESHOLD="${MEM_THRESHOLD:-90}"
CLEAR_SEL="${CLEAR_SEL:-1}"
MEMTESTER_SRC="${MEMTESTER_SRC:-}"
ITERATIONS="${ITERATIONS:-1000000}"
IPMITOOL="${IPMITOOL:-ipmitool}"
IPM_BIN="${IPMITOOL%% *}"

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "ERROR: $*"; exit 1; }

if [ -z "$HOURS" ] || ! [[ "$HOURS" =~ ^[0-9]+$ ]] || [ "$DUR" -le 0 ]; then
  echo "Usage: $0 <HOURS> [MINUTES]"
  echo "  e.g. $0 12          # 12 hour stress test"
  echo "       $0 0 5         # 5 minute smoke test"
  echo "Env : RESULT_DIR SAMPLE_INTERVAL RESERVE_MB CPU_THRESHOLD MEM_THRESHOLD CLEAR_SEL MEMTESTER_SRC ITERATIONS IPMITOOL"
  exit 1
fi
command -v timeout >/dev/null 2>&1 || die "coreutils 'timeout' not found"
[[ "$MINUTES" =~ ^[0-9]+$ ]] || die "MINUTES must be an integer"
[[ "$SAMPLE_INTERVAL" =~ ^[0-9]+$ ]] || die "SAMPLE_INTERVAL must be an integer"
[ "$SAMPLE_INTERVAL" -ge 1 ] 2>/dev/null || die "SAMPLE_INTERVAL must be >= 1 (got '$SAMPLE_INTERVAL')"
[[ "$RESERVE_MB" =~ ^[0-9]+$ ]] || die "RESERVE_MB must be an integer (0 = auto)"

[ "$DUR" -lt $(( SAMPLE_INTERVAL * 3 )) ] && { SAMPLE_INTERVAL=5; log "short duration, sampling every 5s"; }

mkdir -p "$RD/logs_before" "$RD/logs_after" "$RD/analysis"
log "result dir: $RD"
log "duration: ${HOURS}h ${MINUTES}m (${DUR}s), sample interval ${SAMPLE_INTERVAL}s"

# ---------------- locate / build memtester ----------------
MT=""
build_from_src() {
  local d="$1"
  [ -d "$d" ] || return 1
  if [ ! -x "$d/memtester" ]; then
    log "building memtester in $d ..."
    ( cd "$d" && make clean >/dev/null 2>&1; make ) >> "$RD/analysis/build.log" 2>&1 || return 1
  fi
  [ -x "$d/memtester" ] || return 1
  MT="$d/memtester"
  return 0
}
if [ -n "$MEMTESTER_SRC" ]; then
  build_from_src "$MEMTESTER_SRC" || die "cannot build memtester from MEMTESTER_SRC=$MEMTESTER_SRC (see $RD/analysis/build.log)"
elif command -v memtester >/dev/null 2>&1; then
  MT="$(command -v memtester)"
elif [ -x ./memtester ]; then
  MT="$(pwd)/memtester"
else
  for d in ./memtester-*; do
    [ -d "$d" ] && build_from_src "$d" && break
  done
fi
[ -n "$MT" ] || die "memtester not found. Install it, or extract the source tarball (newest: https://pyropus.ca/software/memtester/ memtester-4.6.0) into this directory."
MT_VERSION="$("$MT" -V 2>&1 | head -1)"
if ! echo "$MT_VERSION" | grep -qE '[0-9]+\.[0-9]+'; then
  # memtester <= 4.3 has no -V option; grab the version header from a tiny 1MB run
  MT_VERSION="$("$MT" 1M 1 2>&1 | head -1)"
fi
log "using memtester: $MT -> $MT_VERSION"
# spec wants >= 4.3, newest available is 4.6.0 - warn (not fail) if older
VER_NUM="$(echo "$MT_VERSION" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
if [ -n "$VER_NUM" ] && awk -v v="$VER_NUM" 'BEGIN{split(v,a,"."); exit (a[1]<4 || (a[1]==4 && a[2]<3))?0:1}'; then
  log "WARN: memtester $VER_NUM older than 4.3; spec requires >= 4.3 (newest 4.6.0)"
fi

# ---------------- system & param record ----------------
CORES="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)"
[[ "$CORES" =~ ^[0-9]+$ ]] && [ "$CORES" -ge 1 ] || die "no CPU cores detected (nproc='$CORES')"
TOTAL_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
if [ "$RESERVE_MB" -le 0 ]; then
  RESERVE_MB=$(( TOTAL_MB / 10 ))
  [ "$RESERVE_MB" -lt 1024 ] && RESERVE_MB=1024
fi
SIZE_MB=$(( (TOTAL_MB - RESERVE_MB) / CORES ))
[ "$SIZE_MB" -ge 64 ] || die "per-process memory too small: ${SIZE_MB}MB (total=${TOTAL_MB}MB reserve=${RESERVE_MB}MB cores=$CORES)"

# pre-check free memory: memtester mlock will fail if another workload holds RAM
AVAIL_MB="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
[ -z "$AVAIL_MB" ] && AVAIL_MB=$TOTAL_MB
NEED_MB=$(( SIZE_MB * CORES ))
if [ "$AVAIL_MB" -lt "$NEED_MB" ]; then
  die "insufficient free memory: avail=${AVAIL_MB}MB need=${NEED_MB}MB (${CORES} x ${SIZE_MB}MB); stop other workloads or raise RESERVE_MB"
fi

{
  echo "=== test environment ==="
  echo "date          : $(date)"
  echo "hostname      : $(hostname)"
  echo "kernel        : $(uname -a)"
  echo "memtester     : $MT_VERSION"
  echo "cpu cores     : $CORES"
  echo "cpu model     : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
  echo "mem total     : ${TOTAL_MB}MB"
  echo "overcommit    : $(cat /proc/sys/vm/overcommit_memory 2>/dev/null)"
  echo "memlock limit : $(ulimit -l)"
  echo "=== test params ==="
  echo "duration      : ${HOURS}h ${MINUTES}m (${DUR}s)"
  echo "procs         : $CORES x ${SIZE_MB}MB (reserve ${RESERVE_MB}MB)"
  echo "iterations    : $ITERATIONS (bounded by timeout ${DUR}s)"
  echo "interval      : ${SAMPLE_INTERVAL}s"
  echo "thresholds    : cpu>=${CPU_THRESHOLD}% mem>=${MEM_THRESHOLD}%"
  echo "clear_sel     : $CLEAR_SEL"
  echo "journald      : physical clear (flush+rotate+vacuum-time=1s)"
  echo "result dir    : $RD"
} > "$RD/test_environment.log"
log "cores=$CORES total=${TOTAL_MB}MB size/proc=${SIZE_MB}MB"

# memtester >= 4.4 supports -B (allow overcommit); probe safely
BFLAG=""
"$MT" -B 1M 1 >/dev/null 2>&1 && BFLAG="-B"
[ -n "$BFLAG" ] && log "memtester supports -B (overcommit allowed)" || log "memtester does not support -B (4.3 or older)"

# refuse to start if memtester would exit immediately (overcommit_memory=2 + no -B)
OVC="$(cat /proc/sys/vm/overcommit_memory 2>/dev/null || echo 0)"
if [ "$OVC" = "2" ] && [ -z "$BFLAG" ]; then
  die "overcommit_memory=2 and memtester has no -B support: it will refuse to run. Set vm.overcommit_memory=1 (sysctl -w) or use memtester >= 4.4."
fi

# ---------------- clear logs before test ----------------
TS_START="$(date '+%Y-%m-%d %H:%M:%S')"
echo "TEST_START_TS=$TS_START" > "$RD/test_meta.txt"
log "clearing logs before test (baseline saved to $RD/logs_before/) ..."

dmesg -c > "$RD/logs_before/dmesg_before.log" 2>&1 && log "dmesg: saved & cleared" || log "WARN: dmesg -c failed"

for mf in /var/log/messages /var/log/syslog /var/log/kern.log; do
  if [ -f "$mf" ]; then
    cp -p "$mf" "$RD/logs_before/$(basename "$mf").before.log" 2>/dev/null
    : > "$mf" 2>/dev/null && log "$mf: saved & truncated" || log "WARN: cannot truncate $mf"
  fi
done

# journald: physically cleared (flush -> rotate -> vacuum all old journals)
HAS_JOURNAL=0
JRNL_BASELINE=0
if command -v journalctl >/dev/null 2>&1 && { [ -d /run/log/journal ] || [ -d /var/log/journal ]; }; then
  HAS_JOURNAL=1
  if journalctl --flush --rotate --vacuum-time=1s >/dev/null 2>&1; then
    log "journald: flushed, rotated and vacuumed (PHYSICALLY CLEARED)"
  else
    JRNL_BASELINE=1
    log "WARN: journald clear failed; post-test analysis uses --since \"$TS_START\" (baseline)"
  fi
fi

if command -v "$IPM_BIN" >/dev/null 2>&1; then
  $IPMITOOL sel list > "$RD/logs_before/bmc_sel_before.log" 2>&1 \
    && log "BMC SEL: baseline saved" || log "WARN: ipmitool sel list failed (baseline empty)"
  if [ "$CLEAR_SEL" = "1" ]; then
    $IPMITOOL sel clear >/dev/null 2>&1 \
      && log "BMC SEL: CLEARED (irreversible; baseline kept at logs_before/)" \
      || log "WARN: sel clear failed (OpenBMC may reject; baseline comparison will be used)"
  else
    log "BMC SEL: not cleared (CLEAR_SEL=0); baseline comparison used"
  fi
else
  log "WARN: ipmitool not found - BMC SEL check must be done manually"
fi

# ---------------- spawn one memtester per core ----------------
STDBUF=""
command -v stdbuf >/dev/null 2>&1 && STDBUF="stdbuf -oL -eL"
log "spawning $CORES memtester processes, each ${SIZE_MB}MB, timeout ${DUR}s ..."
PIDS=()
for (( i=1; i<=CORES; i++ )); do
  f="$RD/memtester_p$(printf '%02d' "$i").log"
  echo "### proc $i: $STDBUF $MT $BFLAG ${SIZE_MB}M $ITERATIONS  (timeout ${DUR}s) ###" > "$f"
  $STDBUF timeout --kill-after=15s "$DUR" "$MT" $BFLAG "${SIZE_MB}M" "$ITERATIONS" >> "$f" 2>&1 &
  PIDS+=($!)
done

# ---------------- usage monitor ----------------
cpu_usage_pct() {
  local c1 i1 c2 i2
  c1=$(awk '/^cpu /{s=0; for(i=2;i<=NF;i++) s+=$i; print s}' /proc/stat)
  i1=$(awk '/^cpu /{print $5}' /proc/stat)
  sleep 1
  c2=$(awk '/^cpu /{s=0; for(i=2;i<=NF;i++) s+=$i; print s}' /proc/stat)
  i2=$(awk '/^cpu /{print $5}' /proc/stat)
  local total=$(( c2 - c1 )) idle=$(( i2 - i1 ))
  [ "$total" -le 0 ] && { echo 0; return; }
  echo $(( (total - idle) * 100 / total ))
}
mem_usage_pct() {
  awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} /MemFree/{if(a=="")a=$2} END{if(t>0) printf "%d",(t-a)*100/t; else print 0}' /proc/meminfo
}
proc_count() {
  if command -v pgrep >/dev/null 2>&1; then pgrep -xc memtester; else ps -e -o comm= | grep -xc '^memtester$'; fi
}
monitor() {
  local n=0 exp_rss=$(( SIZE_MB * CORES ))
  while :; do
    n=$(( n + 1 ))
    local now cpu mem pc rss st
    now="$(date '+%F %T')"
    cpu="$(cpu_usage_pct)"; mem="$(mem_usage_pct)"; pc="$(proc_count)"
    rss="$(ps -C memtester -o rss= 2>/dev/null | awk '{s+=$1} END{print int(s/1024)}')"
    # steady-state marker: exclude startup/teardown samples (procs not full,
    # or RSS below 80% of expected = mlock still ramping / processes dying)
    st="ok=1"
    [ "$pc" -ne "$CORES" ] && st="ok=0"
    [ "$rss" -lt $(( exp_rss * 8 / 10 )) ] && st="ok=0"
    echo "$now cpu=$cpu mem=$mem procs=$pc rss_mb=$rss $st" >> "$RD/usage.log"
    { echo "--- top snapshot $now ---"; top -b -n1 2>/dev/null | head -25; } >> "$RD/top_snapshots.log"
    [ $(( n % 30 )) -eq 0 ] && log "sample $n: cpu=${cpu}% mem=${mem}% procs=$pc rss=${rss}MB"
    sleep "$SAMPLE_INTERVAL"
  done
}
monitor &
MONPID=$!

# ---------------- wait for completion ----------------
cleanup() {
  log "interrupted, killing monitor and memtester ..."
  kill "$MONPID" 2>/dev/null
  [ ${#PIDS[@]} -gt 0 ] && kill "${PIDS[@]}" 2>/dev/null
  sleep 2   # give timeout a chance to forward TERM to memtester
  pkill -x memtester 2>/dev/null   # last-resort sweep (this test's own processes)
  exit 130
}
trap cleanup INT TERM

log "test running ... expected ${DUR}s (use top/htop to watch; memtester pids listed)"
for p in "${PIDS[@]}"; do
  wait "$p"; echo "$?" >> "$RD/proc_rc.txt"
done
kill "$MONPID" 2>/dev/null
TS_END="$(date '+%F %T')"
log "all memtester processes exited at $TS_END"

# ---------------- capture ORIGINAL logs after test ----------------
dmesg -T > "$RD/logs_after/dmesg_after_test.log" 2>&1
for mf in /var/log/messages /var/log/syslog /var/log/kern.log; do
  [ -f "$mf" ] && cat "$mf" > "$RD/logs_after/$(basename "$mf").after.log" 2>/dev/null
done
if [ "$HAS_JOURNAL" = "1" ]; then
  if [ "$JRNL_BASELINE" = "1" ]; then
    journalctl --since "$TS_START" --no-pager -q > "$RD/logs_after/journal_after_test.log" 2>&1
  else
    journalctl --no-pager -q > "$RD/logs_after/journal_after_test.log" 2>&1
  fi
fi
command -v "$IPM_BIN" >/dev/null 2>&1 && $IPMITOOL sel list > "$RD/logs_after/bmc_sel_after_test.log" 2>&1
log "original logs saved under $RD/logs_after/"

# ---------------- analysis ----------------
AN="$RD/analysis"
: > "$AN/error_matches.log"
# system-log patterns: real hardware/panic errors only. NO bare FAILURE here -
# case-insensitive 'failure' matches systemd dnf failures and sshd auth-failure
# noise (verified on 12h run); memtester's own FAILURE is checked separately below.
ERR_PAT='hardware error|machine check|mce[ :]|edac|uncorrectable|memory error|ECC error|kernel panic|Oops|BUG:|segfault|general protection fault'
# NOTE: oom must be word-bounded - bare 'oom' matches systemd-oomd journal lines
WARN_PAT='out of memory|oom-kill|oom_reaper|\boom\b|killed process|soft lockup|mlock error'
for f in "$RD"/logs_after/dmesg_after_test.log "$RD"/logs_after/messages_after_test.log "$RD"/logs_after/syslog_after_test.log "$RD"/logs_after/kern_after_test.log "$RD"/logs_after/journal_after_test.log; do
  [ -f "$f" ] || continue
  grep -inE "$ERR_PAT" "$f" 2>/dev/null >> "$AN/error_matches.log"
  grep -inE "$WARN_PAT" "$f" 2>/dev/null | sed 's/^/[WARN] /' >> "$AN/error_matches.log"
done
grep -inE "FAILURE|$ERR_PAT" "$RD"/memtester_p*.log 2>/dev/null >> "$AN/error_matches.log"
command -v "$IPM_BIN" >/dev/null 2>&1 && grep -inE 'mem|ecc|uncorrect|correctable|fatal' "$RD/logs_after/bmc_sel_after_test.log" 2>/dev/null | sed 's/^/[SEL] /' >> "$AN/error_matches.log"

# usage stats (only steady-state samples: ok=1, skip startup/teardown ramp)
read -r CPU_MIN CPU_AVG MEM_MIN MEM_AVG PROC_MIN RSS_MIN N < <(awk '
NR>2 {
  if ($0 !~ /cpu=/) next;    # skip partial/invalid sample lines
  if ($0 ~ /ok=0/) next;     # skip startup/teardown samples (procs<cores or rss low)
  match($0,/cpu=[0-9]+/); c=substr($0,RSTART+4,RLENGTH-4)+0;
  match($0,/mem=[0-9]+/); m=substr($0,RSTART+4,RLENGTH-4)+0;
  match($0,/procs=[0-9]+/); p=substr($0,RSTART+6,RLENGTH-6)+0;
  match($0,/rss_mb=[0-9]+/); r=substr($0,RSTART+7,RLENGTH-7)+0;
  n++; cs+=c; ms+=m; ps+=p;
  if(n==1){cmin=c;mmin=m;pmin=p;rmin=r}else{if(c<cmin)cmin=c;if(m<mmin)mmin=m;if(p<pmin)pmin=p;if(r<rmin)rmin=r}
}
END{printf "%d %d %d %d %d %d %d\n", cmin, int(cs/n+0.5), mmin, int(ms/n+0.5), pmin, rmin, n}
' "$RD/usage.log" 2>/dev/null)

# per-process exit code classification (124 = full duration by timeout)
TIMEOUT_OK=0; EARLY_END=0; ABNORMAL=0
while read -r rc; do
  case "$rc" in
    124) TIMEOUT_OK=$((TIMEOUT_OK+1)) ;;
    0)   EARLY_END=$((EARLY_END+1)) ;;
    *)   ABNORMAL=$((ABNORMAL+1)) ;;
  esac
done < "$RD/proc_rc.txt" 2>/dev/null
[ -s "$RD/proc_rc.txt" ] || ABNORMAL=$CORES

MT_FAIL="$(grep -h 'FAILURE' "$RD"/memtester_p*.log 2>/dev/null | wc -l)"

# ---------------- summary ----------------
P=1
chk() { local res="$1" name="$2" det="$3"; [ "$res" = "PASS" ] || P=0; printf "  [%-4s] %-40s %s\n" "$res" "$name" "$det"; }
SUMMARY="$RD/summary_report.txt"
{
  echo "================================================================"
  echo " memtester constant-load stress test - summary"
  echo "================================================================"
  echo "start      : $TS_START"
  echo "end        : $TS_END"
  echo "duration   : ${HOURS}h${MINUTES}m (${DUR}s)  cores=$CORES  total=${TOTAL_MB}MB  size/proc=${SIZE_MB}MB  reserve=${RESERVE_MB}MB"
  echo "memtester  : $MT_VERSION"
  echo "result dir : $RD"
  echo
  echo "usage evidence (steady-state samples=${N:-0})"
  echo "  cpu% : min=${CPU_MIN:-N/A} avg=${CPU_AVG:-N/A}   (threshold ${CPU_THRESHOLD}%)"
  echo "  mem% : min=${MEM_MIN:-N/A} avg=${MEM_AVG:-N/A}   (threshold ${MEM_THRESHOLD}%)"
  echo "  procs: min=${PROC_MIN:-N/A}  expected=$CORES"
  echo "  rss  : min=${RSS_MIN:-N/A}MB  expected=${SIZE_MB}x$CORES=$((SIZE_MB*CORES))MB (mlock proof)"
  echo "  per-proc exit: timeout_ok=$TIMEOUT_OK early_end=$EARLY_END abnormal=$ABNORMAL (124=ran full duration)"
  echo
  echo "acceptance check"
  chk "$([ -n "$MT" ] && echo PASS || echo FAIL)" "memtester available" "$MT_VERSION"
  chk "$([ "$ABNORMAL" = 0 ] && [ "$TIMEOUT_OK" -ge 1 ] && echo PASS || echo FAIL)" "ran full duration" "timeout=$TIMEOUT_OK early=$EARLY_END abnormal=$ABNORMAL"
  chk "$([ -n "$CPU_MIN" ] && [ "$CPU_MIN" -ge "$CPU_THRESHOLD" ] && echo PASS || echo FAIL)" "CPU usage >= ${CPU_THRESHOLD}%" "min=$CPU_MIN% avg=$CPU_AVG%"
  chk "$([ -n "$MEM_MIN" ] && [ "$MEM_MIN" -ge "$MEM_THRESHOLD" ] && echo PASS || echo FAIL)" "MEM usage >= ${MEM_THRESHOLD}%" "min=$MEM_MIN% avg=$MEM_AVG%"
  chk "$([ -n "$PROC_MIN" ] && [ "$PROC_MIN" -eq "$CORES" ] && echo PASS || echo FAIL)" "proc count == cores" "min=$PROC_MIN expected=$CORES"
  chk "$([ "${MT_FAIL:-0}" -eq 0 ] 2>/dev/null && echo PASS || echo FAIL)" "memtester no FAILURE" "failure lines=$MT_FAIL"
  chk "$([ ! -s "$AN/error_matches.log" ] && echo PASS || echo FAIL)" "logs no error/fail/alert" "see analysis/error_matches.log"
  echo "  [MANUAL] no obvious lag (无明显卡顿) - verify on console"
  echo
  echo "error matches (raw grep against original logs):"
  if [ -s "$AN/error_matches.log" ]; then head -30 "$AN/error_matches.log"; else echo "  (none)"; fi
  echo
  echo "original logs after test:"
  ls -l "$RD/logs_after/" | awk 'NR>1 {print "  "$9" ("$5" bytes)"}'
  echo
  echo "overall : $([ "$P" = 1 ] && echo PASS || echo FAIL)"
  echo "note    : SEL clear irreversible; pre-clear SEL at logs_before/bmc_sel_before.log"
  echo "note    : SEL grep covers memory-related events; review full bmc_sel_after_test.log for other alerts"
} > "$SUMMARY"

log "done, summary: $SUMMARY"
tail -n 20 "$SUMMARY"
[ "$P" = 1 ] && { log "OVERALL RESULT: PASS"; exit 0; } || { log "OVERALL RESULT: FAIL"; exit 1; }
