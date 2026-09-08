#!/bin/bash
# disk_order_verify_interactive.sh - semi-automatic disk order/position check.
#
# One disk at a time, in PCI BDF order: a continuous dd read (O_DIRECT) keeps
# the disk busy so the bay with the blinking activity LED is identified as the
# physical position of that /dev node. The operator confirms by eye and presses
# y to stop the current dd and move to the next disk; q quits.
#
# Usage (root, interactive terminal on the machine):
#   bash disk_order_verify_interactive.sh
#   VERIFY=1 bash disk_order_verify_interactive.sh   # also run dd write+readback check per disk
#
# Keys during a disk watch:  y = next disk (current dd stops)   q = quit

set -u

EXPECT_COUNT="${EXPECT_COUNT:-12}"    # full population required by the test case
ALLOW_PARTIAL="${ALLOW_PARTIAL:-0}"
VERIFY="${VERIFY:-0}"                 # 1 = extra dd write+readback SHA-256 check per disk
BLOCKS_1M="${BLOCKS_1M:-4096}"        # pattern size (MiB) used when VERIFY=1
READ_GB="${READ_GB:-64}"              # read per dd pass (GiB); passes loop continuously,
                                      # capped so pass counts/throughput accumulate as evidence

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="/root/disk_order_interactive_${TS}"
PDIR="$OUTDIR/per_disk"
SUMMARY="$OUTDIR/summary.txt"
MAPCSV="$OUTDIR/mapping.csv"
mkdir -p "$PDIR"

RD_PID=""; CUR_DEV=""
pass=0; failn=0

log() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }

# stop the continuous reader: kill the loop shell first (no new dd spawns),
# then sweep any dd still matching this disk, then hard-sweep survivors
stop_reader() {
  local p
  [ -z "$RD_PID" ] && return 0
  kill "$RD_PID" 2>/dev/null
  for p in $(pgrep -f "if=$CUR_DEV of=/dev/null" 2>/dev/null); do kill "$p" 2>/dev/null; done
  sleep 0.5
  for p in $(pgrep -f "if=$CUR_DEV of=/dev/null" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
  kill -9 "$RD_PID" 2>/dev/null
  wait "$RD_PID" 2>/dev/null
  RD_PID=""; CUR_DEV=""
}
trap 'stop_reader; exit 130' INT TERM

log "===== disk order verification (interactive) @ $(hostname) $(date '+%F %T') ====="
log "per disk: continuous dd read until operator advances; VERIFY=$VERIFY"

# ---- preconditions -----------------------------------------------------------
busy=""
for p in fio spdk vdbench iozone; do
  pgrep -x "$p" >/dev/null 2>&1 && busy="$busy $p"
done
if [ -n "$busy" ]; then
  log "[ABORT] workload process(es) active:$busy - never disturb a running test"
  exit 1
fi

if [ "$VERIFY" = "1" ]; then
  avail_mb=$(df -Pm "$OUTDIR" | awk 'NR==2 {print $4}')
  if [ "$avail_mb" -lt $((BLOCKS_1M + 2048)) ]; then
    log "[ABORT] only ${avail_mb} MiB free, need $((BLOCKS_1M + 2048)) MiB for the pattern file"
    exit 1
  fi
fi

all_nvme=$(ls /sys/block | grep -E '^nvme[0-9]+n[0-9]+$')
n=$(printf '%s\n' "$all_nvme" | grep -c .)
log "[CHECK] NVMe namespaces recognized: $n (expect $EXPECT_COUNT)"
for s in $(ls /sys/block | grep -E '^(sd[a-z]+|vd[a-z]+)$'); do
  smodel=$(sed 's/ *$//' "/sys/block/$s/device/model" 2>/dev/null)
  sserial=$(sed 's/ *$//' "/sys/block/$s/device/serial" 2>/dev/null)
  [ -z "$sserial" ] && sserial=$(lsblk -dno SERIAL "/dev/$s" 2>/dev/null)
  log "[CHECK] non-NVMe disk /dev/$s recognized: $smodel SN=$sserial (excluded from dd)"
done
if [ "$n" -ne "$EXPECT_COUNT" ] && [ "$ALLOW_PARTIAL" != "1" ]; then
  log "[ABORT] full-population precondition NOT met: found $n, expected $EXPECT_COUNT."
  log "        Check empty/failed bays, then rerun (or ALLOW_PARTIAL=1)."
  lsblk -d -o NAME,SIZE,MODEL,SERIAL 2>/dev/null | tee -a "$SUMMARY"
  exit 1
fi
[ "$n" -ne "$EXPECT_COUNT" ] && log "[WARN] running with $n/$EXPECT_COUNT disks (ALLOW_PARTIAL=1)"

nvme list > "$OUTDIR/nvme_list.txt" 2>&1
lsblk -o NAME,SIZE,MODEL,SERIAL,MOUNTPOINT > "$OUTDIR/lsblk.txt" 2>&1

# ---- disk order list: sort by PCI BDF (assumed physical bay order) -----------
orderlist="$OUTDIR/order_by_bdf.txt"
: > "$orderlist"
for d in $all_nvme; do
  bdf=$(cat "/sys/block/$d/device/address" 2>/dev/null)
  [ -z "$bdf" ] && bdf="ffff:ff:ff.f"
  printf '%s %s\n' "$bdf" "$d" >> "$orderlist"
done
sort "$orderlist" -o "$orderlist"

echo "device,bdf,serial,link,passes,last_speed,verify,result" > "$MAPCSV"

# ---- interactive traversal -----------------------------------------------------
# NOTE: the loop reads from fd3 so the operator's keystrokes on stdin are free
# for the key prompt inside the loop body.
i=0
while read -r bdf d <&3; do
  i=$((i + 1))
  dev="/dev/$d"
  plog="$PDIR/$d.log"
  ctrl=${d%n*}
  model=$(sed 's/ *$//' "/sys/block/$d/device/model" 2>/dev/null)
  serial=$(sed 's/ *$//' "/sys/block/$d/device/serial" 2>/dev/null)
  size_gb=$(awk -v b="$(cat "/sys/block/$d/size")" 'BEGIN {printf "%.0f", b*512/1073741824}')
  lspeed=$(cat "/sys/class/nvme/$ctrl/device/current_link_speed" 2>/dev/null)
  lwidth=$(cat "/sys/class/nvme/$ctrl/device/current_link_width" 2>/dev/null)
  link="${lspeed:-unknown} x${lwidth:-}"
  csv="$d,$bdf,$serial,$link"

  mp=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null | grep -c .)
  holders=$(ls "/sys/block/$d/holders" 2>/dev/null | grep -c .)
  if [ "$mp" -ne 0 ] || [ "$holders" -ne 0 ]; then
    log "[SKIP] $dev mounted or in use (mounts=$mp holders=$holders) - not read"
    echo "$csv,0,,SKIP-IN-USE" >> "$MAPCSV"
    failn=$((failn + 1))
    continue
  fi

  vres=""
  if [ "$VERIFY" = "1" ]; then
    src="$PDIR/$d.pattern"
    echo "----- $dev verify $(date '+%F %T') -----" > "$plog"
    dd if=/dev/urandom of="$src" bs=1M count="$BLOCKS_1M" status=none
    ssum=$(sha256sum "$src" | awk '{print $1}')
    dd if="$src" of="$dev" bs=1M count="$BLOCKS_1M" oflag=direct conv=fsync 2>>"$plog"
    rsum=$(dd if="$dev" iflag=direct bs=1M count="$BLOCKS_1M" 2>>"$plog" | sha256sum | awk '{print $1}')
    rm -f "$src"
    if [ "$ssum" = "$rsum" ]; then
      vres="verify-PASS"
    else
      vres="verify-FAIL(src=$ssum read=$rsum)"
      failn=$((failn + 1))
    fi
  fi

  echo "=================================================================="
  echo " DISK $i/$n : $dev    BDF=$bdf"
  echo " model=$model  SN=$serial  ${size_gb}GiB  $link"
  echo " continuous dd read is now running on this disk only -"
  echo " the bay with the blinking activity LED is its physical position."
  echo " press:  y = next disk (stop this dd)    q = quit"
  echo "=================================================================="
  echo "----- $dev watch $(date '+%F %T') -----" > "$plog.watch"

  ( while :; do dd if="$dev" of=/dev/null iflag=direct bs=1M count=$((READ_GB * 1024)) </dev/null 2>>"$plog.watch"; done ) &
  RD_PID=$!; CUR_DEV="$dev"

  key=""
  while :; do
    printf '[%s] reading - press y for next disk, q to quit: ' "$d"
    if ! read -n 1 -r key; then
      echo
      log "[EOF] stdin closed at $d - aborting"
      stop_reader
      exit 1
    fi
    case "$key" in
      y|Y) echo; break ;;
      q|Q) echo; stop_reader
           log "[QUIT] operator quit at $d ($((i - 1))/$n confirmed); artifacts in $OUTDIR"
           exit 0 ;;
      *)   echo "  -> please press y or q" ;;
    esac
  done

  stop_reader
  passes=$(grep -c 'copied' "$plog.watch" 2>/dev/null)
  last_speed=$(grep -oE '[0-9.]+ [kMG]B/s' "$plog.watch" 2>/dev/null | tail -1)
  log "[CONFIRMED] $d (BDF $bdf SN=$serial) read passes=$passes last=$last_speed ${vres}"
  echo "$csv,$passes,$last_speed,$vres,CONFIRMED" >> "$MAPCSV"
  pass=$((pass + 1))
done 3< "$orderlist"

log "===== summary $(date '+%F %T') ====="
log "disks confirmed: $pass   failed/skipped: $failn"
log "disk order mapping (sorted by PCI BDF, assumed bay order):"
if command -v column >/dev/null 2>&1; then
  column -t -s, "$MAPCSV" | tee -a "$SUMMARY"
else
  tee -a "$SUMMARY" < "$MAPCSV"
fi
if [ "$failn" -eq 0 ]; then
  log "RESULT: PASS"
  exit 0
fi
log "RESULT: FAIL"
exit 1
