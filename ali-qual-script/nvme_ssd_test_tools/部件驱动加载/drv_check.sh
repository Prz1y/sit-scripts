#!/bin/bash
# OS compatibility evidence collector (test case: verify driver loading under test OS)
# Usage: bash /root/drv_check_194.sh   (run as root)
# Output: /root/drv_check_194/ — files overwritten on each re-run

OUT=/root/drv_check_194
mkdir -p "$OUT"

{
  echo "host=$(hostname)  date=$(date '+%F %T')  kernel=$(uname -r)"
  head -2 /etc/os-release 2>/dev/null
  dmidecode -s system-product-name 2>/dev/null
} > "$OUT/host_info.log"

# [case step 1] driver loading info: full dmesg + filtered driver-load view
dmesg > "$OUT/dmesg_full.log" 2>&1
dmesg | grep -iE 'loaded|loading|nvme|igb|ixgbe|i40e|mlx5|ahci|xhci|ccp|psp|hygon|k10temp' > "$OUT/dmesg_driver_load.log" 2>&1

# [case step 2] component inventory
lspci -nn > "$OUT/lspci_nn.log" 2>&1
lspci -nnvvv > "$OUT/lspci_nvvv.log" 2>&1
lspci -tv > "$OUT/lspci_tree.log" 2>&1

if command -v nvme >/dev/null 2>&1; then
    nvme list > "$OUT/nvme_list.log" 2>&1
    nvme list -o json > "$OUT/nvme_list.json" 2>&1
else
    echo "nvme-cli NOT installed" > "$OUT/nvme_list.log"
fi

for c in /sys/class/nvme/nvme*; do
    n=$(basename "$c")
    echo "$n pci=$(cat "$c/address" 2>/dev/null) model=$(cat "$c/model" 2>/dev/null) serial=$(cat "$c/serial" 2>/dev/null) fw=$(cat "$c/firmware_rev" 2>/dev/null)"
done > "$OUT/nvme_detail.log" 2>&1

lsblk -o NAME,TYPE,SIZE,MODEL,SERIAL,REV > "$OUT/lsblk.log" 2>&1
if command -v lsscsi >/dev/null 2>&1; then lsscsi > "$OUT/lsscsi.log" 2>&1; else echo "lsscsi not installed" > "$OUT/lsscsi.log"; fi
fdisk -l > "$OUT/fdisk_l.log" 2>&1

# NIC inventory + driver/firmware versions
{
  for i in $(ls /sys/class/net 2>/dev/null | grep -v '^lo$'); do
      echo "== $i =="
      ip -br link show "$i" 2>/dev/null
      ethtool -i "$i" 2>/dev/null
  done
} > "$OUT/nic_inventory.log" 2>&1

# CPU / memory / board (BIOS-presented config)
dmidecode -t bios > "$OUT/dmidecode_bios.log" 2>&1
dmidecode -t processor > "$OUT/dmidecode_processor.log" 2>&1
dmidecode -t memory > "$OUT/dmidecode_memory.log" 2>&1
dmidecode -t baseboard > "$OUT/dmidecode_baseboard.log" 2>&1
lscpu > "$OUT/lscpu.log" 2>&1
free -h > "$OUT/free.log" 2>&1

# key kernel module states
for m in nvme nvme_core igb ixgbe mlx5_core ahci sd_mod; do
    if lsmod | grep -qw "$m"; then echo "$m: LOADED  $(lsmod | grep -w "$m" | head -1)"; else echo "$m: NOT-LOADED"; fi
done > "$OUT/lsmod_key.log" 2>&1

# summary counts for BIOS cross-check
{
  echo "NVMe controllers (sysfs class/nvme): $(ls /sys/class/nvme 2>/dev/null | wc -l)"
  echo "NVMe namespaces (/dev/nvme*n1):      $(ls /dev/nvme*n1 2>/dev/null | wc -l)"
  echo "PCI NVMe endpoints (lspci [0108]):   $(lspci -nn 2>/dev/null | grep -c '\[0108\]')"
  echo "PCI NIC ports (lspci [0200]):        $(lspci -nn 2>/dev/null | grep -c '\[0200\]')"
  echo "Disks in lsscsi (SATA + NVMe N:):    $(lsscsi 2>/dev/null | grep -c ' disk ')"
  echo "DIMMs populated (dmidecode):         $(dmidecode -t memory 2>/dev/null | grep -c 'Size: [0-9]')"
  echo "CPU sockets populated (dmidecode):   $(dmidecode -t processor 2>/dev/null | grep -c 'Status: Populated')"
} > "$OUT/summary_counts.txt" 2>&1

echo "== DONE: $OUT =="
ls -la "$OUT"
