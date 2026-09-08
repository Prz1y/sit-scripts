#!/bin/bash
#===============================================================================
# stream_30runs.sh
# Run STREAM (/root/hygon-stream/run.sh) N times (default 30), keep the full
# original output of every run, and build a summary table of the best rates
# (Copy/Scale/Add/Triad) plus the average of all valid runs.
#
# Usage:
#   ./stream_30runs.sh [run.sh] [result_dir]
#     defaults: run.sh     = /root/hygon-stream/run.sh
#               result_dir = <run.sh dir>/stream_result_<ts>
#     env:      N          = number of runs (default 30)
#
# Outputs (under result_dir):
#   raw/run_01.log ... raw/run_30.log   full original STREAM output per run
#   summary.txt                         per-run table + averages
#===============================================================================

RUN_SH="${1:-/root/hygon-stream/run.sh}"
N="${N:-30}"
RUNS_DIR="$(cd "$(dirname "$RUN_SH")" 2>/dev/null && pwd)"
OUT="${2:-$RUNS_DIR/stream_result_$(date +%Y%m%d_%H%M%S)}"

[ -f "$RUN_SH" ] || { echo "ERROR: $RUN_SH not found"; exit 1; }
[ "$N" -ge 1 ] 2>/dev/null || { echo "ERROR: N must be >= 1"; exit 1; }
mkdir -p "$OUT/raw"

echo "STREAM ${N}-run benchmark - $(date '+%F %T')"
echo "run.sh: $RUN_SH   runs: $N   out: $OUT"

SUMMARY="$OUT/summary.txt"
{
  echo "STREAM ${N}-run summary"
  echo "date      : $(date '+%F %T')"
  echo "run.sh    : $RUN_SH"
  echo "runs      : $N"
  echo "smt       : threads_per_core=$(lscpu 2>/dev/null | awk -F: '/^Thread\(s\) per core/{gsub(/ /,"",$2);print $2}') nproc=$(nproc)"
  echo
  printf '%-4s %12s %12s %12s %12s\n' "Run" "Copy" "Scale" "Add" "Triad"
} > "$SUMMARY"

ACC="$OUT/.acc"
: > "$ACC"

for (( i=1; i<=N; i++ )); do
  log="$(printf '%s/raw/run_%02d.log' "$OUT" "$i")"
  # cd to the run.sh dir first (relative paths inside run.sh), feed /dev/null
  # in case run.sh asks anything, 900s safety timeout per run
  ( cd "$RUNS_DIR" && timeout 900 bash ./run.sh < /dev/null ) > "$log" 2>&1
  rc=$?
  vals="$(awk '/^Copy:/{c=$2} /^Scale:/{s=$2} /^Add:/{a=$2} /^Triad:/{t=$2} END{print c,s,a,t}' "$log")"
  if [ "$rc" -eq 0 ] && [ -n "$vals" ]; then
    read -r c s a t <<< "$vals"
    printf '%-4d %12.1f %12.1f %12.1f %12.1f\n' "$i" "$c" "$s" "$a" "$t" >> "$SUMMARY"
    printf '%s %s %s %s\n' "$c" "$s" "$a" "$t" >> "$ACC"
    echo "run $i: Copy=$c Scale=$s Add=$a Triad=$t"
  else
    printf '%-4d %12s %12s %12s %12s   [rc=%d]\n' "$i" "-" "-" "-" "-" "$rc" >> "$SUMMARY"
    echo "WARN: run $i rc=$rc, check $log"
  fi
done

{
  echo
  echo "average of valid runs:"
  printf '%-4s %12s %12s %12s %12s\n' "Avg" \
    "$(awk '{s+=$1;n++} END{if(n) printf "%.1f", s/n; else print "-"}' "$ACC")" \
    "$(awk '{s+=$2;n++} END{if(n) printf "%.1f", s/n; else print "-"}' "$ACC")" \
    "$(awk '{s+=$3;n++} END{if(n) printf "%.1f", s/n; else print "-"}' "$ACC")" \
    "$(awk '{s+=$4;n++} END{if(n) printf "%.1f", s/n; else print "-"}' "$ACC")"
} >> "$SUMMARY"

rm -f "$ACC"
echo "done, summary: $SUMMARY"
