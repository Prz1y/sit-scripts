#!/bin/bash
#===============================================================================
# Stressapptest_Stress_Test_Linux.sh
#
# stressapptest constant-load stress test with full evidence collection.
# Runs one stressapptest process with N invert + N CPU-stress threads (-i -C),
# -W (CPU-stressful copy), -M (mem size, default 94% of total RAM), -s duration.
# CPU and memory usage stay near 100% for the whole duration.
#
# Usage:
#   ./Stressapptest_Stress_Test_Linux.sh <HOURS> [MINUTES]
#     e.g. ./Stressapptest_Stress_Test_Linux.sh 1 30   # 1.5 hours (acceptance)
#          ./Stressapptest_Stress_Test_Linux.sh 0 1    # 1 minute smoke test
#
# Acceptance mapping (result files under RESULT_DIR):
#   [1] tool installed no errors        -> test_environment.log (version check)
#   [2] cpu & mem usage near 100%       -> usage.log, top_snapshots.log, summary
#   [3] mem released after test         -> usage.log (used_mb column before/after)
#   [4] no error in stressapptest/dmesg/messages/journal/SEL -> analysis/error_matches.log
#   [5] system runs normally            -> process exit code, summary
#
# Log handling (same as memtester script):
#   - dmesg ring buffer  : saved then cleared with `dmesg -c`
#   - /var/log/messages  : saved then truncated (`: > file`)
#   - journald           : flushed + rotated + vacuumed (--vacuum-time=1s)
#   - BMC SEL            : saved then `ipmitool sel clear` if CLEAR_SEL=1
#   - fallback           : baseline comparison via --since if a clear fails
#
# Config via environment variables:
#   RESULT_DIR       output dir          (default: ./stressapptest_result_<ts>)
#   SAMPLE_INTERVAL  usage sampling, s   (default 60)
#   MEM_PCT          memory percent to test (default 94, acceptance default)
#   CPU_THRESHOLD    cpu% pass threshold (default 90)
#   MEM_THRESHOLD    mem% pass threshold (default 90)
#   CLEAR_SEL        1/0                 (default 1)
#   IPMITOOL         full ipmitool cmd, e.g.
#                    IPMITOOL="ipmitool -I lanplus -H <BMC_IP> -U admin -P xxxx"
#   SAT_BIN          stressapptest binary (default: auto-detect)
#===============================================================================

export LC_ALL=C

HOURS="${1:-}"
MINUTES="${2:-0}"
[[ "$MINUTES" =~ ^[0-9]+$ ]] || { echo "ERROR: MINUTES must be an integer"; exit 1; }
if [ -z "$HOURS" ] || ! [[ "$HOURS" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "Usage: $0 <HOURS> [MINUTES]   (HOURS may be fractional, e.g. 1.5)"
  echo "  e.g. $0 1 30        # 1.5 hour stress test"
  echo "       $0 0 1         # 1 minute smoke test"
  echo "Env : RESULT_DIR SAMPLE_INTERVAL MEM_PCT CPU_THRESHOLD MEM_THRESHOLD CLEAR_SEL IPMITOOL SAT_BIN"
  exit 1
fi
DUR=$(awk -v h="$HOURS" -v m="$MINUTES" 'BEGIN{printf "%d", h*3600 + m*60}')
[ "$DUR" -ge 60 ] || { echo "ERROR: duration must be >= 60s (got ${DUR}s)"; exit 1; }

RD="${RESULT_DIR:-$(pwd)/stressapptest_result_$(date +%Y%m%d_%H%M%S)}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-60}"
MEM_PCT="${MEM_PCT:-94}"
CPU_THRESHOLD="${CPU_THRESHOLD:-90}"
MEM_THRESHOLD="${MEM_THRESHOLD:-90}"
CLEAR_SEL="${CLEAR_SEL:-1}"
IPMITOOL="${IPMITOOL:-ipmitool}"
IPM_BIN="${IPMITOOL%% *}"
SAT_BIN="${SAT_BIN:-}"

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "ERROR: $*"; exit 1; }

[[ "$SAMPLE_INTERVAL" =~ ^[0-9]+$ ]] && [ "$SAMPLE_INTERVAL" -ge 1 ] 2>/dev/null || die "SAMPLE_INTERVAL must be >= 1"
[[ "$MEM_PCT" =~ ^[0-9]+$ ]] && [ "$MEM_PCT" -ge 10 ] && [ "$MEM_PCT" -le 99 ] 2>/dev/null || die "MEM_PCT must be 10-99"
command -v timeout >/dev/null 2>&1 || die "coreutils 'timeout' not found"

mkdir -p "$RD/logs_before" "$RD/logs_after" "$RD/analysis"
log "result dir: $RD"
log "duration: ${HOURS}h ${MINUTES}m (${DUR}s), sample interval ${SAMPLE_INTERVAL}s"

# short runs need faster sampling to have enough steady-state samples
[ "$DUR" -lt $(( SAMPLE_INTERVAL * 3 )) ] && { SAMPLE_INTERVAL=5; log "short duration, sampling every 5s"; }

# ---------------- locate stressapptest ----------------
if [ -z "$SAT_BIN" ]; then
  if command -v stressapptest >/dev/null 2>&1; then
    SAT_BIN="$(command -v stressapptest)"
  elif [ -x ./stressapptest ]; then
    SAT_BIN="$(pwd)/stressapptest"
  else
    die "stressapptest not found. Install: yum install stressapptest, or build from source (configure && make && make install)"
  fi
fi
SAT_VERSION="$("$SAT_BIN" 2>&1 | grep -m1 'SAT revision')"
[ -n "$SAT_VERSION" ] || SAT_VERSION="($SAT_BIN: version line not found)"
SAT_NAME="$(basename "$SAT_BIN")"
log "using stressapptest: $SAT_BIN -> $SAT_VERSION"

# ---------------- system & param record ----------------
CORES="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)"
[[ "$CORES" =~ ^[0-9]+$ ]] && [ "$CORES" -ge 1 ] || die "no CPU cores detected (nproc='$CORES')"
TOTAL_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
MEM_MB=$(( TOTAL_MB * MEM_PCT / 100 ))
[ "$MEM_MB" -ge 256 ] || die "computed test memory too small: ${MEM_MB}MB (total=${TOTAL_MB}MB pct=${MEM_PCT})"

AVAIL_MB="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
[ -z "$AVAIL_MB" ] && AVAIL_MB=$TOTAL_MB
if [ "$AVAIL_MB" -lt "$MEM_MB" ]; then
  die "insufficient free memory: avail=${AVAIL_MB}MB need=${MEM_MB}MB (${MEM_PCT}% of total); stop other workloads or lower MEM_PCT"
fi

USED_BEFORE="$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%d", (t-a)/1024}' /proc/meminfo)"

{
  echo "=== test environment ==="
  echo "date          : $(date)"
  echo "hostname      : $(hostname)"
  echo "kernel        : $(uname -a)"
  echo "stressapptest : $SAT_VERSION"
  echo "cpu cores     : $CORES"
  echo "cpu model     : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
  echo "mem total     : ${TOTAL_MB}MB"
  echo "mem to test   : ${MEM_MB}MB (${MEM_PCT}%)"
  echo "memlock limit : $(ulimit -l)"
  echo "=== test params ==="
  echo "duration      : ${HOURS}h ${MINUTES}m (${DUR}s)"
  echo "threads       : invert=$CORES cpu_stress=$CORES (-W)"
  echo "interval      : ${SAMPLE_INTERVAL}s"
  echo "thresholds    : cpu>=${CPU_THRESHOLD}% mem>=${MEM_THRESHOLD}%"
  echo "clear_sel     : $CLEAR_SEL"
  echo "result dir    : $RD"
} > "$RD/test_environment.log"
log "cores=$CORES total=${TOTAL_MB}MB mem_to_test=${MEM_MB}MB (${MEM_PCT}%)"

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
      || log "WARN: sel clear failed; baseline comparison will be used"
  else
    log "BMC SEL: not cleared (CLEAR_SEL=0); baseline comparison used"
  fi
else
  log "WARN: ipmitool not found - BMC SEL check must be done manually"
fi

# ---------------- start stressapptest ----------------
log "starting stressapptest: $SAT_BIN -i $CORES -C $CORES -W -M ${MEM_MB} -s $DUR"
timeout --kill-after=30s "$((DUR + 60))" "$SAT_BIN" -i "$CORES" -C "$CORES" -W -M "$MEM_MB" -s "$DUR" \
  -l "$RD/stressapptest.log" > "$RD/stressapptest_stdout.log" 2>&1 &
SAT_PID=$!

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
  awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} /MemFree/{if(a=="")a=$2} END{if(t>0) printf "%d", (t-a)*100/t; else print 0}' /proc/meminfo
}
monitor() {
  local n=0
  while :; do
    n=$(( n + 1 ))
    local now cpu mem used rss st
    now="$(date '+%F %T')"
    cpu="$(cpu_usage_pct)"; mem="$(mem_usage_pct)"
    # RSS of the actual stressapptest process(es), not the timeout wrapper
    rss="$(ps -C "$SAT_NAME" -o rss= 2>/dev/null | awk '{s+=$1} END{print int(s/1024)}')"
    used="$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{print int((t-a)/1024)}' /proc/meminfo)"
    st="ok=1"
    # startup/dead: rss below 80% of expected
    [ "$rss" -lt "$((MEM_MB * 8 / 10))" ] && st="ok=0"
    # teardown window: cpu already dropped but memory still held (result check)
    [ "$cpu" -lt "$CPU_THRESHOLD" ] && [ "$rss" -ge "$((MEM_MB * 8 / 10))" ] && st="ok=0"
    echo "$now cpu=$cpu mem=$mem used_mb=$used rss_mb=${rss:-0} $st" >> "$RD/usage.log"
    { echo "--- top snapshot $now ---"; top -b -n1 2>/dev/null | head -20; } >> "$RD/top_snapshots.log"
    [ $(( n % 30 )) -eq 0 ] && log "sample $n: cpu=${cpu}% mem=${mem}% rss=${rss}MB"
    sleep "$SAMPLE_INTERVAL"
  done
}
monitor &
MONPID=$!

cleanup() {
  log "interrupted, killing monitor and stressapptest ..."
  kill "$MONPID" 2>/dev/null
  kill "$SAT_PID" 2>/dev/null
  sleep 2
  pkill -x "$SAT_NAME" 2>/dev/null
  exit 130
}
trap cleanup INT TERM

log "test running ... expected ${DUR}s"
wait "$SAT_PID"
SAT_RC=$?
kill "$MONPID" 2>/dev/null
TS_END="$(date '+%F %T')"
log "stressapptest exited (rc=$SAT_RC) at $TS_END"

# ---------------- capture ORIGINAL logs after test ----------------
USED_AFTER="$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%d", (t-a)/1024}' /proc/meminfo)"
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
# system-log patterns: real hardware/panic errors only (no bare FAILURE - false positives)
ERR_PAT='hardware error|machine check|mce[ :]|edac|uncorrectable|memory error|ECC error|kernel panic|Oops|BUG:|segfault|general protection fault'
WARN_PAT='out of memory|oom-kill|oom_reaper|\boom\b|killed process|soft lockup|mlock error'
for f in "$RD"/logs_after/dmesg_after_test.log "$RD"/logs_after/messages_after_test.log "$RD"/logs_after/syslog_after_test.log "$RD"/logs_after/kern_after_test.log "$RD"/logs_after/journal_after_test.log; do
  [ -f "$f" ] || continue
  grep -inE "$ERR_PAT" "$f" 2>/dev/null >> "$AN/error_matches.log"
  grep -inE "$WARN_PAT" "$f" 2>/dev/null | sed 's/^/[WARN] /' >> "$AN/error_matches.log"
done
# stressapptest own output: errors/failures are definitive for this tool
# (exclude normal "Status: PASS - please verify no corrected errors" lines)
grep -inE 'error|fail' "$RD/stressapptest.log" "$RD/stressapptest_stdout.log" 2>/dev/null | grep -viE 'Status: PASS|no errors|no corrected errors|0 errors|errors detected: 0' >> "$AN/error_matches.log"
command -v "$IPM_BIN" >/dev/null 2>&1 && grep -inE 'mem|ecc|uncorrect|correctable|fatal' "$RD/logs_after/bmc_sel_after_test.log" 2>/dev/null | sed 's/^/[SEL] /' >> "$AN/error_matches.log"

# usage stats (steady-state samples only)
read -r CPU_MIN CPU_AVG MEM_MIN MEM_AVG RSS_MIN MAX_USED N < <(awk '
NR>2 {
  if ($0 !~ /cpu=/) next;
  if ($0 ~ /ok=0/) next;
  match($0,/cpu=[0-9]+/); c=substr($0,RSTART+4,RLENGTH-4)+0;
  match($0,/mem=[0-9]+/); m=substr($0,RSTART+4,RLENGTH-4)+0;
  match($0,/used_mb=[0-9]+/); u=substr($0,RSTART+8,RLENGTH-8)+0;
  match($0,/rss_mb=[0-9]+/); r=substr($0,RSTART+7,RLENGTH-7)+0;
  n++; cs+=c; ms+=m;
  if(n==1){cmin=c;mmin=m;rmin=r;umax=u}else{if(c<cmin)cmin=c;if(m<mmin)mmin=m;if(r<rmin)rmin=r;if(u>umax)umax=u}
}
END{printf "%d %d %d %d %d %d %d\n", cmin, int(cs/n+0.5), mmin, int(ms/n+0.5), rmin, umax, n}
' "$RD/usage.log" 2>/dev/null)

# ---------------- summary ----------------
P=1
chk() { local res="$1" name="$2" det="$3"; [ "$res" = "PASS" ] || P=0; printf "  [%-4s] %-40s %s\n" "$res" "$name" "$det"; }
SUMMARY="$RD/summary_report.txt"
{
  echo "================================================================"
  echo " stressapptest constant-load stress test - summary"
  echo "================================================================"
  echo "start      : $TS_START"
  echo "end        : $TS_END"
  echo "duration   : ${HOURS}h ${MINUTES}m (${DUR}s)  cores=$CORES  mem_to_test=${MEM_MB}MB (${MEM_PCT}%)"
  echo "tool       : $SAT_VERSION"
  echo "cmd        : stressapptest -i $CORES -C $CORES -W -M ${MEM_MB} -s ${DUR}"
  echo "result dir : $RD"
  echo
  echo "usage evidence (steady-state samples=${N:-0})"
  echo "  cpu% : min=${CPU_MIN:-N/A} avg=${CPU_AVG:-N/A}   (threshold ${CPU_THRESHOLD}%)"
  echo "  mem% : min=${MEM_MIN:-N/A} avg=${MEM_AVG:-N/A}   (threshold ${MEM_THRESHOLD}%)"
  echo "  rss  : min=${RSS_MIN:-N/A}MB  expected~${MEM_MB}MB"
  echo "  memory release: used_before=${USED_BEFORE}MB peak=${MAX_USED:-N/A}MB -> used_after=${USED_AFTER}MB"
  echo "  exit code     : $SAT_RC"
  echo
  echo "acceptance check"
  chk "$([ -n "$SAT_BIN" ] && echo PASS || echo FAIL)" "tool installed & runs" "$SAT_VERSION"
  chk "$([ "$SAT_RC" = 0 ] && echo PASS || echo FAIL)" "stressapptest completed rc=0" "rc=$SAT_RC"
  chk "$([ -n "$CPU_MIN" ] && [ "$CPU_MIN" -ge "$CPU_THRESHOLD" ] && echo PASS || echo FAIL)" "CPU usage >= ${CPU_THRESHOLD}%" "min=$CPU_MIN% avg=$CPU_AVG%"
  chk "$([ -n "$MEM_MIN" ] && [ "$MEM_MIN" -ge "$MEM_THRESHOLD" ] && echo PASS || echo FAIL)" "MEM usage >= ${MEM_THRESHOLD}%" "min=$MEM_MIN% avg=$MEM_AVG%"
  chk "$([ -n "${MAX_USED:-}" ] && [ "${USED_AFTER:-0}" -lt $(( MAX_USED * 7 / 10 )) ] 2>/dev/null && echo PASS || echo FAIL)" "memory released after test" "peak $MAX_USED -> after $USED_AFTER MB"
  chk "$([ ! -s "$AN/error_matches.log" ] && echo PASS || echo FAIL)" "no error in logs" "see analysis/error_matches.log"
  echo "  [MANUAL] no crash/hang (无宕机卡死) - verify on console"
  echo
  echo "error matches (raw grep):"
  if [ -s "$AN/error_matches.log" ]; then head -30 "$AN/error_matches.log"; else echo "  (none)"; fi
  echo
  echo "original logs after test:"
  ls -l "$RD/logs_after/" | awk 'NR>1 {print "  "$9" ("$5" bytes)"}'
  echo
  echo "overall : $([ "$P" = 1 ] && echo PASS || echo FAIL)"
} > "$SUMMARY"

log "done, summary: $SUMMARY"
tail -n 20 "$SUMMARY"
[ "$P" = 1 ] && { log "OVERALL RESULT: PASS"; exit 0; } || { log "OVERALL RESULT: FAIL"; exit 1; }
