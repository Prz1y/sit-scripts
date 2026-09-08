#!/bin/bash
# disk_order_verify.sh - test item 2: full-population recognition + sequential
# dd R/W traversal for disk order/position verification.
#
# For every NVMe data disk, in PCI BDF order, write a unique random pattern
# with dd (O_DIRECT + fsync), read it back (O_DIRECT) and compare SHA-256.
# The produced nvmeXn1 <-> PCI BDF <-> serial mapping is the disk order record
# for correlating /dev nodes with physical bay positions.
#
# Usage (root, on the test machine):
#   bash disk_order_verify.sh                    # strict: abort unless NVMe count == EXPECT_COUNT
#   ALLOW_PARTIAL=1 bash disk_order_verify.sh    # test the disks present even if count differs
#   BLOCKS_1M=1024 bash disk_order_verify.sh     # smaller per-disk pattern (MiB), smoke run
#   FULL_READ=1 bash disk_order_verify.sh        # extra full-disk read pass per disk
#
# CAUTION: writes raw data to the start of every NVMe block device (destroys
# existing content). Dedicated test machines only. Mounted disks, RAID/dm
# members and non-NVMe disks (OS on SATA/LVM) are never written.

set -u

EXPECT_COUNT="${EXPECT_COUNT:-12}"    # full population required by the test case
BLOCKS_1M="${BLOCKS_1M:-4096}"        # per-disk pattern size = BLOCKS_1M MiB (4096 = 4 GiB)
FULL_READ="${FULL_READ:-0}"           # 1 = extra full-disk read pass per disk
ALLOW_PARTIAL="${ALLOW_PARTIAL:-0}"

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="/root/disk_order_verify_${TS}"
PDIR="$OUTDIR/per_disk"
SUMMARY="$OUTDIR/summary.txt"
MAPCSV="$OUTDIR/mapping.csv"
mkdir -p "$PDIR"

pass=0; failn=0

log() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }

log "===== disk order verification @ $(hostname) $(date '+%F %T') ====="
log "per-disk pattern: ${BLOCKS_1M} MiB, full-disk read pass: $FULL_READ, expect $EXPECT_COUNT disks"

# ---- preconditions ----------------------------------------------------------
busy=""
for p in fio spdk vdbench iozone; do
  pgrep -x "$p" >/dev/null 2>&1 && busy="$busy $p"
done
if [ -n "$busy" ]; then
  log "[ABORT] workload process(es) active:$busy - never disturb a running test"
  exit 1
fi

avail_mb=$(df -Pm "$OUTDIR" | awk 'NR==2 {print $4}')
if [ "$avail_mb" -lt $((BLOCKS_1M + 2048)) ]; then
  log "[ABORT] only ${avail_mb} MiB free on $(df -P "$OUTDIR" | awk 'NR==2 {print $6}'); need $((BLOCKS_1M + 2048)) MiB for the pattern file"
  exit 1
fi

# NVMe whole-disk namespaces (partitions never appear at /sys/block top level)
all_nvme=$(ls /sys/block | grep -E '^nvme[0-9]+n[0-9]+$')
n=$(printf '%s\n' "$all_nvme" | grep -c .)
log "[CHECK] NVMe namespaces recognized: $n (expect $EXPECT_COUNT)"

# non-NVMe disks go into the recognition record but are never written
for s in $(ls /sys/block | grep -E '^(sd[a-z]+|vd[a-z]+)$'); do
  smodel=$(sed 's/ *$//' "/sys/block/$s/device/model" 2>/dev/null)
  sserial=$(sed 's/ *$//' "/sys/block/$s/device/serial" 2>/dev/null)
  [ -z "$sserial" ] && sserial=$(lsblk -dno SERIAL "/dev/$s" 2>/dev/null)
  log "[CHECK] non-NVMe disk /dev/$s recognized: $smodel SN=$sserial (excluded from dd write)"
done

if [ "$n" -ne "$EXPECT_COUNT" ] && [ "$ALLOW_PARTIAL" != "1" ]; then
  log "[ABORT] full-population precondition NOT met: found $n, expected $EXPECT_COUNT."
  log "        Check empty/failed bays, then rerun (or ALLOW_PARTIAL=1 to test present disks)."
  printf '%s\n' "Full disk list:" | tee -a "$SUMMARY"
  lsblk -d -o NAME,SIZE,MODEL,SERIAL 2>/dev/null | tee -a "$SUMMARY"
  exit 1
fi
[ "$n" -ne "$EXPECT_COUNT" ] && log "[WARN] running with $n/$EXPECT_COUNT disks (ALLOW_PARTIAL=1)"

nvme list > "$OUTDIR/nvme_list.txt" 2>&1
lsblk -o NAME,SIZE,MODEL,SERIAL,MOUNTPOINT > "$OUTDIR/lsblk.txt" 2>&1

# ---- disk order list: sort by PCI BDF (assumed physical bay order) ----------
orderlist="$OUTDIR/order_by_bdf.txt"
: > "$orderlist"
for d in $all_nvme; do
  bdf=$(cat "/sys/block/$d/device/address" 2>/dev/null)
  [ -z "$bdf" ] && bdf="ffff:ff:ff.f"
  printf '%s %s\n' "$bdf" "$d" >> "$orderlist"
done
sort "$orderlist" -o "$orderlist"

echo "device,bdf,model,serial,fw,size_gb,link,w_speed,r_speed,result" > "$MAPCSV"

# ---- sequential dd write / readback per disk --------------------------------
while read -r bdf d; do
  dev="/dev/$d"
  plog="$PDIR/$d.log"
  ctrl=${d%n*}
  model=$(sed 's/ *$//' "/sys/block/$d/device/model" 2>/dev/null)
  serial=$(sed 's/ *$//' "/sys/block/$d/device/serial" 2>/dev/null)
  fw=$(sed 's/ *$//' "/sys/block/$d/device/firmware_rev" 2>/dev/null)
  size_gb=$(awk -v b="$(cat "/sys/block/$d/size")" 'BEGIN {printf "%.0f", b*512/1073741824}')
  lspeed=$(cat "/sys/class/nvme/$ctrl/device/current_link_speed" 2>/dev/null)
  lwidth=$(cat "/sys/class/nvme/$ctrl/device/current_link_width" 2>/dev/null)
  link="${lspeed:-unknown} x${lwidth:-}"

  echo "----- $dev (BDF $bdf) $(date '+%F %T') -----" > "$plog"
  echo "model=$model serial=$serial fw=$fw size=${size_gb}GiB link=$link" >> "$plog"
  csv="$d,$bdf,$model,$serial,$fw,$size_gb,$link"

  # refuse to touch anything mounted or claimed by md/dm
  mp=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null | grep -c .)
  holders=$(ls "/sys/block/$d/holders" 2>/dev/null | grep -c .)
  if [ "$mp" -ne 0 ] || [ "$holders" -ne 0 ]; then
    log "[SKIP] $dev mounted or in use (mounts=$mp holders=$holders) - NOT written"
    echo "$csv,,,SKIP-IN-USE" >> "$MAPCSV"
    failn=$((failn + 1))
    continue
  fi

  log "[TEST] $d (BDF $bdf SN=$serial) dd write ${BLOCKS_1M}MiB ..."
  src="$PDIR/$d.pattern"
  dd if=/dev/urandom of="$src" bs=1M count="$BLOCKS_1M" status=none
  ssum=$(sha256sum "$src" | awk '{print $1}')

  dd if="$src" of="$dev" bs=1M count="$BLOCKS_1M" oflag=direct conv=fsync 2>>"$plog"
  wst=$?
  wline=$(tail -1 "$plog"); wline=${wline//,/}
  if [ $wst -ne 0 ]; then
    log "[FAIL] $d (BDF $bdf SN=$serial) dd write failed (exit $wst)"
    echo "$csv,$wline,,FAIL-WRITE" >> "$MAPCSV"
    rm -f "$src"
    failn=$((failn + 1))
    continue
  fi

  rsum=$(dd if="$dev" iflag=direct bs=1M count="$BLOCKS_1M" 2>>"$plog" | sha256sum | awk '{print $1}')
  rst=${PIPESTATUS[0]}
  rline=$(tail -1 "$plog"); rline=${rline//,/}

  result="PASS"
  [ "$ssum" != "$rsum" ] && result="FAIL-DATA"
  [ "$rst" -ne 0 ] && result="FAIL-READ"
  if [ "$FULL_READ" = "1" ]; then
    log "[TEST] $d full-disk read pass ..."
    dd if="$dev" of=/dev/null iflag=direct bs=1M 2>>"$plog"
    [ $? -ne 0 ] && result="FAIL-FULLREAD"
    fline=$(tail -1 "$plog"); rline="$rline / fullread: ${fline//,/}"
  fi

  if [ "$result" = "PASS" ]; then
    log "[PASS] $d (BDF $bdf SN=$serial) SHA-256 match  |  $wline  |  $rline"
    pass=$((pass + 1))
  else
    log "[FAIL] $d (BDF $bdf SN=$serial) $result (src=$ssum read=$rsum dd_exit=$rst)"
    failn=$((failn + 1))
  fi
  echo "$csv,$wline,$rline,$result" >> "$MAPCSV"
  rm -f "$src"
done < "$orderlist"

# ---- summary -----------------------------------------------------------------
log "===== summary $(date '+%F %T') ====="
log "full population: $n/$EXPECT_COUNT; dd R/W: PASS=$pass FAIL/SKIP=$failn"
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
