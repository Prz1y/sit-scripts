#!/bin/bash

set -euo pipefail
# ==============================================================================
# NVMe Firmware Upgrade/Downgrade Automated Test Script (Standalone)
# ==============================================================================
# Dependencies: nvme-cli, ipmitool, sysstat(iostat), util-linux(dd)
# Usage: sudo bash <this_script>
#   First run starts from the beginning; after power cycle, cron @reboot
#   resumes automatically — no manual intervention required.
# Note: Ensure IPMI modules are loaded: modprobe ipmi_si ipmi_devintf

# Ensure essential commands are in PATH (important for @reboot cron execution)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"
#
# Result files produced (in a timestamped subdirectory):
#   test_report.log          Full execution log
#   fw_version_check.log     FW version checks (proves Points 1, 3, 4)
#   io_after_upgrade.log     DD + iostat after upgrade     (proves Point 2)
#   io_after_downgrade.log   DD + iostat after downgrade   (proves Point 4)
#   point5_history.log       Historical version results     (proves Point 5)
#   point6_smart_init.log    SMART before test              (proves Point 6)
#   point6_smart_final.log   SMART after test               (proves Point 6)
#   point6_bmc_init.log      BMC SEL before test            (proves Point 6)
#   point6_bmc_final.log     BMC SEL after test             (proves Point 6)
#   point6_dmesg_final.log   dmesg after test               (proves Point 6)
#   summary.log              PASS/FAIL summary of all points
# ==============================================================================

# --------------------------- Configuration (edit before running) -------------
NVME_DEVICE="/dev/nvme0n1"
FW_LOCAL_DIR="."                # Directory containing FW files (resolved to abs path at start)
VENDOR_TOOL=""              # Path to vendor tool (optional); leave empty to use nvme-cli only
DD_BS="1024k"
DD_COUNT="1000"
DD_OUTPUT="/root/test1.log" # DD destination file (as per test spec; deleted after each run)

# Paths (auto-calculated, no need to modify)
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# Resolve FW_LOCAL_DIR to absolute path: @reboot cron has different cwd than interactive shell
FW_LOCAL_DIR="$(cd "$FW_LOCAL_DIR" 2>/dev/null && pwd)" || {
    echo "[ERROR] FW_LOCAL_DIR '$FW_LOCAL_DIR' does not exist or is not accessible." >&2
    exit 1
}
STATE_FILE="${SCRIPT_DIR}/fw_test.state"  # Checkpoint file: STAGE|RESULT_DIR
RESULT_DIR=""               # Set in main() based on checkpoint
LOG_FILE=""                 # Set in main() based on checkpoint
HISTORY_FW_LIST=()

# Global variables populated in main()
LATEST_FW_LOCAL=""
OLD_FW_LOCAL=""
LATEST_VERSION=""
OLD_VERSION=""

# FW Rev polling timeout (seconds) — increase for platforms with slow PCIe enumeration
FW_REV_TIMEOUT=120

# -------------------------------- Helper functions --------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Append a PASS/FAIL line to both the main log and summary.log
record_result() {
    local tag="$1"      # short identifier, e.g. "Point1_Upgrade"
    local status="$2"   # PASS | FAIL | INFO
    local detail="$3"
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] [${status}] ${tag}: ${detail}"
    echo "$line" | tee -a "$LOG_FILE" >> "${RESULT_DIR}/summary.log"
}

collect_smart() {
    local label="$1"
    local out="${RESULT_DIR}/point6_smart_${label}.log"
    log "Collecting SMART log [${label}] -> $(basename "$out")"
    nvme smart-log "$NVME_DEVICE" > "$out" 2>&1 \
        && log "SMART saved: $out" \
        || log "WARNING: SMART collection failed"
}

collect_bmc_log() {
    local label="$1"
    local out="${RESULT_DIR}/point6_bmc_${label}.log"
    log "Collecting BMC SEL log [${label}] -> $(basename "$out")"
    ipmitool sel list > "$out" 2>&1 \
        && log "BMC SEL saved: $out" \
        || log "WARNING: BMC SEL collection failed (check ipmi_si/ipmi_devintf modules)"
}

collect_dmesg() {
    local label="$1"
    local out="${RESULT_DIR}/point6_dmesg_${label}.log"
    log "Collecting dmesg [${label}] -> $(basename "$out")"
    dmesg > "$out" 2>&1
    log "dmesg saved: $out"
}

clear_dmesg() {
    log "Clearing dmesg ring buffer"
    dmesg -c > /dev/null 2>&1 || log "WARNING: dmesg clear failed"
}

# ---------------------------------------------------------------------------
# get_fw_rev — triple-path FW revision read with retry
#   Path A: sysfs         /sys/class/nvme/<ctrl>/firmware_rev  (fastest, no nvme-cli)
#   Path B: nvme id-ctrl  (traditional)
#   Path C: nvme list     (fallback, greps the device line)
#   Retries up to (FW_REV_TIMEOUT/2) times (2 s apart) before giving up.
# ---------------------------------------------------------------------------
get_fw_rev() {
    local ctrl="${NVME_DEVICE##*/}"    # nvme0n1
    ctrl="${ctrl%n*}"                  # nvme0
    local out retry=0 max_retry=$((FW_REV_TIMEOUT / 2))

    while [ $retry -lt $max_retry ]; do
        # --- Path A: sysfs (fastest, most reliable, no nvme-cli dependency) ---
        if [ -f "/sys/class/nvme/${ctrl}/firmware_rev" ]; then
            out=$(cat "/sys/class/nvme/${ctrl}/firmware_rev" 2>/dev/null | tr -d '[:space:]')
            [ -n "$out" ] && { echo "$out"; return 0; }
        fi

        # --- Path B: nvme id-ctrl ---
        out=$(nvme id-ctrl "/dev/${ctrl}" 2>/dev/null \
            | grep -E "^fr\s+" | awk '{print $3}' | tr -d '[:space:]')
        [ -n "$out" ] && { echo "$out"; return 0; }

        # --- Path C: nvme list (no args, grep the device line) ---
        out=$(nvme list 2>/dev/null \
            | grep -F "${NVME_DEVICE}" \
            | awk '{print $NF}' | tr -d '[:space:]')
        [ -n "$out" ] && { echo "$out"; return 0; }

        sleep 2
        retry=$((retry + 1))
    done
    echo "UNKNOWN"
    return 1
}

extract_version_from_filename() {
    # Filename format: UI8030V1_FW_<build>_<version>.bin
    # Extract the last underscore-delimited token before the extension -> e.g. U4A00002
    local fname
    fname=$(basename "$1")
    echo "${fname%.*}" | awk -F'_' '{print $NF}'
}

# Write version check result to fw_version_check.log
verify_fw_version() {
    local expected="$1"
    local label="$2"
    local out="${RESULT_DIR}/fw_version_check.log"
    local actual
    actual=$(get_fw_rev)
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Check: ${label}"
        echo "  Expected : ${expected}"
        echo "  Actual   : ${actual}"
    } | tee -a "$LOG_FILE" >> "$out"

    if [ "$actual" = "$expected" ]; then
        echo "  Result   : PASS" | tee -a "$LOG_FILE" >> "$out"
        return 0
    else
        echo "  Result   : FAIL" | tee -a "$LOG_FILE" >> "$out"
        return 1
    fi
}

do_fw_update() {
    local fw_file_path="$1"
    local slot="${2:-1}"
    local action="${3:-3}"

    log "Starting firmware update: $fw_file_path"

    # Check frmw bit1 to confirm action=3 (immediate activate) is supported
    local frmw
    frmw=$(nvme id-ctrl "$NVME_DEVICE" 2>/dev/null | grep -E "^frmw\s+" | awk '{print $3}')
    if [ -n "$frmw" ]; then
        local support_no_reset=$(( (frmw >> 1) & 1 ))
        if [ "$action" -eq 3 ] && [ "$support_no_reset" -eq 0 ]; then
            log "WARNING: Device frmw=0x$(printf '%x' $frmw) does not support action=3; falling back to action=1"
            action=1
        fi
    fi

    # Capture current FW rev before update so we can detect whether
    # a controller reset activated the new image. Some controllers
    # require a full power-cycle to activate (reset may be insufficient).
    local prev_fw
    prev_fw=$(get_fw_rev 2>/dev/null || echo "UNKNOWN")

    clear_dmesg

    local start_ts end_ts
    start_ts=$(date +%s)
    log "fw-download started at: $(date '+%Y-%m-%d %H:%M:%S')"

    nvme fw-download "$NVME_DEVICE" -f "$fw_file_path" 2>&1 | tee -a "$LOG_FILE"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        log "ERROR: fw-download failed"
        return 1
    fi

    nvme fw-commit "$NVME_DEVICE" -s "$slot" -a "$action" 2>&1 | tee -a "$LOG_FILE"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        log "ERROR: fw-commit failed"
        return 1
    fi

    end_ts=$(date +%s)
    log "Firmware update done at: $(date '+%Y-%m-%d %H:%M:%S'), elapsed: $((end_ts - start_ts))s"

    # When action=1 (activate-at-reset) the new firmware does not run until the
    # controller is reset.  Perform a controller reset now so the version check
    # immediately afterwards sees the new firmware.
    if [ "$action" -eq 1 ]; then
        log "Performing NVMe controller reset to activate firmware (action=1)..."
        local ctrl_device="${NVME_DEVICE%n1}"  # /dev/nvme0n1 -> /dev/nvme0
        nvme reset "$ctrl_device" 2>&1 | tee -a "$LOG_FILE" || true
        # Wait for the device to reappear (up to 30 s)
        local waited=0
        while [ ! -b "$NVME_DEVICE" ] && [ $waited -lt 30 ]; do
            sleep 1
            waited=$((waited + 1))
        done
        if [ -b "$NVME_DEVICE" ]; then
            log "NVMe device $NVME_DEVICE is back after reset (waited ${waited}s)"
            # Give the block layer a short extra settle time
            sleep 2
        else
            log "WARNING: NVMe device $NVME_DEVICE did not reappear within 30s"
        fi

        # Check whether firmware actually changed after controller reset.
        local cur_fw
        cur_fw=$(get_fw_rev 2>/dev/null || echo "UNKNOWN")
        if [ "$cur_fw" = "$prev_fw" ]; then
            log "Firmware unchanged after controller reset (was: ${prev_fw})."
            log "Some controllers require a full power-cycle to activate firmware."
            log "Falling back to full power-cycle to activate firmware now."
            # Use existing helper to checkpoint and perform power cycle.
            # Save the expected firmware version so the resume logic knows
            # which version to verify after the reboot.
            local target_ver
            target_ver=$(extract_version_from_filename "$fw_file_path")
            handle_power_cycle "$target_ver"
            # handle_power_cycle will not return (it exits after issuing power-cycle).
        else
            log "Firmware changed after controller reset: ${cur_fw}"
        fi
    fi

    return 0
}

# DD read + iostat IO observation — output saved to io_<label>.log
do_io_test() {
    local label="$1"
    local io_log="${RESULT_DIR}/io_${label}.log"

    log "===== IO test [${label}] ====="
    {
        echo "=== IO Test: ${label} ==="
        echo "Timestamp : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Command   : dd if=${NVME_DEVICE} of=${DD_OUTPUT} bs=${DD_BS} count=${DD_COUNT}"
        echo ""
    } > "$io_log"

    # Start iostat background monitor
    local iostat_tmp="/tmp/iostat_$$.log"
    iostat -x 1 70 > "$iostat_tmp" 2>&1 &
    local iostat_pid=$!
    sleep 2

    # DD read test (reads NVMe, writes to DD_OUTPUT)
    log "Running: dd if=${NVME_DEVICE} of=${DD_OUTPUT} bs=${DD_BS} count=${DD_COUNT}"
    local dd_ok=0
    if dd if="$NVME_DEVICE" of="$DD_OUTPUT" bs="$DD_BS" count="$DD_COUNT" 2>&1 \
            | tee -a "$io_log" "$LOG_FILE"; then
        dd_ok=1
        log "DD completed successfully"
    else
        log "ERROR: DD failed"
    fi

    # Remove DD output file to avoid filling disk
    rm -f "$DD_OUTPUT"

    # Wait for iostat to finish naturally (max 80s)
    local w=0
    while kill -0 "$iostat_pid" 2>/dev/null && [ $w -lt 80 ]; do sleep 1; w=$((w + 1)); done
    kill "$iostat_pid" 2>/dev/null || true

    # Append iostat result
    { echo ""; echo "=== iostat -x output ==="; cat "$iostat_tmp"; } >> "$io_log"
    rm -f "$iostat_tmp"
    log "IO result saved: $io_log"

    [ $dd_ok -eq 1 ] && return 0 || return 1
}

handle_power_cycle() {
    local expected_after="${1:-${EXPECTED_FW:-}}"
    log "====== Initiating power cycle ======"

    # Save checkpoint: stage + result directory path + expected FW after powercycle
    printf 'STAGE_AFTER_POWERCYCLE|%s|%s\n' "$RESULT_DIR" "$expected_after" > "$STATE_FILE"
    log "Checkpoint saved: $STATE_FILE (expected FW: ${expected_after})"

    # Register cron @reboot to resume after reboot
        ( crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH" ; \
            echo "@reboot bash \"$SCRIPT_PATH\"" ) | crontab -
        log "Registered cron @reboot: bash \"$SCRIPT_PATH\""

    log "Executing: ipmitool power cycle — system will power off now..."
    sync
    ipmitool power cycle 2>/dev/null || true

    # Fallback if system doesn't power off within 30s
    sleep 30
    log "WARNING: System did not power off. Please reboot manually."
    log "         Script will auto-resume from checkpoint after reboot."
    exit 0
}

# ----------------------------- Post power-cycle flow --------------------------------
run_after_powercycle() {
    # ---------------------------------------------------------------
    # Step 0: Wait for block device to appear (long timeout for slow PCIe enumeration)
    # ---------------------------------------------------------------
    local dev_wait=0
    while [ ! -b "$NVME_DEVICE" ] && [ $dev_wait -lt 120 ]; do
        sleep 2
        ((dev_wait+=2))
    done
    if [ ! -b "$NVME_DEVICE" ]; then
        log "ERROR: NVMe device $NVME_DEVICE not found after ${dev_wait}s — aborting"
        exit 1
    fi
    log "NVMe device $NVME_DEVICE is ready (waited ${dev_wait}s)"

    # ---------------------------------------------------------------
    # Step 1: Wait until we can actually read the firmware revision
    #         (get_fw_rev has its own internal retry up to FW_REV_TIMEOUT)
    # ---------------------------------------------------------------
    local fw_now
    fw_now=$(get_fw_rev)
    if [ "$fw_now" = "UNKNOWN" ]; then
        log "ERROR: NVMe controller still unresponsive after $FW_REV_TIMEOUT s — aborting"
        exit 1
    fi
    log "NVMe controller FW Rev: ${fw_now}"

    # Determine which firmware version we should expect after this power-cycle.
    # Prefer the value stored in the state file (backed into EXPECTED_FROM_STATE by main),
    # otherwise fall back to LATEST_VERSION for backward compatibility.
    local expected_after
    expected_after="${EXPECTED_FROM_STATE:-${LATEST_VERSION}}"

    # Remove checkpoint and cron entry immediately to prevent infinite reboot loop
    rm -f "$STATE_FILE"
    ( crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH" ) | crontab -
    log "Checkpoint and cron @reboot entry cleared (expected after reboot: ${expected_after})"

    # ---- Point 4 (power cycle): verify FW version survives reboot ----
    log "===== Point 4: FW version check after power cycle ====="
    if verify_fw_version "$expected_after" "After power cycle"; then
        record_result "Point4_PowerCycle" "PASS" "FW version matches target after power cycle: ${expected_after}"
    else
        record_result "Point4_PowerCycle" "FAIL" "FW version mismatch after power cycle (expected: ${expected_after})"
        exit 1
    fi

    # ---- Point 3: Downgrade FW back to oldest version ----
    log "===== Point 3: Downgrade FW ${LATEST_VERSION} -> ${OLD_VERSION} ====="
    if do_fw_update "$OLD_FW_LOCAL" 1 3; then
        if verify_fw_version "$OLD_VERSION" "After downgrade (no power cycle)"; then
            record_result "Point3_Downgrade" "PASS" "FW downgraded successfully to ${OLD_VERSION}"
        else
            record_result "Point3_Downgrade" "FAIL" "FW version mismatch after downgrade (expected: ${OLD_VERSION})"
            exit 1
        fi
    else
        record_result "Point3_Downgrade" "FAIL" "fw-download/fw-commit failed during downgrade"
        exit 1
    fi

    # ---- Point 4 (IO after downgrade): DD + iostat ----
    log "===== Point 4 IO: DD read after downgrade ====="
    if do_io_test "after_downgrade"; then
        record_result "Point4_DowngradeIO" "PASS" "DD read and iostat IO observed after downgrade"
    else
        record_result "Point4_DowngradeIO" "FAIL" "DD read failed after downgrade"
    fi

    # ---- Point 5: Traverse all historical versions ----
    log "===== Point 5: Historical version upgrade/downgrade traversal ====="
    local hist_log="${RESULT_DIR}/point5_history.log"
    {
        echo "=== Historical Version Upgrade/Downgrade Results ==="
        echo "Latest version : ${LATEST_VERSION}"
        echo "Test started   : $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
    } > "$hist_log"

    # First, upgrade back to latest as starting point
    do_fw_update "$LATEST_FW_LOCAL" 1 3
    verify_fw_version "$LATEST_VERSION" "Reset to latest (before traversal)"

    local all_pass=1
    local fw_file target_version
    for fw_file in "${HISTORY_FW_LIST[@]}"; do
        target_version=$(extract_version_from_filename "$fw_file")
        [ "$target_version" = "$LATEST_VERSION" ] && continue

        echo "--- Version: ${target_version} ---" | tee -a "$hist_log" "$LOG_FILE"

        # Downgrade to historical version
        local dg_result="FAIL" ug_result="FAIL"
        if do_fw_update "$fw_file" 1 3 \
                && verify_fw_version "$target_version" "Downgrade to ${target_version}"; then
            dg_result="PASS"
        else
            all_pass=0
        fi
        echo "  Downgrade ${LATEST_VERSION} -> ${target_version} : ${dg_result}" >> "$hist_log"

        # Upgrade back to latest
        if do_fw_update "$LATEST_FW_LOCAL" 1 3 \
                && verify_fw_version "$LATEST_VERSION" "Upgrade back to ${LATEST_VERSION}"; then
            ug_result="PASS"
        else
            all_pass=0
            log "ERROR: Failed to upgrade back to latest — aborting traversal"
            echo "  Upgrade ${target_version} -> ${LATEST_VERSION} : FAIL (ABORTED)" >> "$hist_log"
            break
        fi
        echo "  Upgrade   ${target_version} -> ${LATEST_VERSION} : ${ug_result}" >> "$hist_log"
    done

    if [ $all_pass -eq 1 ]; then
        record_result "Point5_History" "PASS" "All historical versions passed upgrade/downgrade (see point5_history.log)"
    else
        record_result "Point5_History" "FAIL" "One or more versions failed — see point5_history.log"
    fi

    # ---- Point 6: Final SMART / dmesg / BMC ----
    log "===== Point 6: Final diagnostics (SMART, BMC SEL, dmesg) ====="
    collect_smart "final"
    collect_bmc_log "final"
    collect_dmesg "final"
    record_result "Point6_Diagnostics" "INFO" "Files: point6_smart_final.log, point6_bmc_final.log, point6_dmesg_final.log — review for errors"

    # ---- Summary ----
    log "================================================================"
    log "All tests complete. Results directory: $RESULT_DIR"
    log "================================================================"
    log "PASS/FAIL Summary:"
    cat "${RESULT_DIR}/summary.log" | tee -a "$LOG_FILE"
}

# -------------------------------- Main flow --------------------------------
main() {
    # Read checkpoint (format: STAGE|RESULT_DIR)
    local state_line stage saved_result_dir
    # Backward-compatible: state file format is now STAGE|RESULT_DIR|EXPECTED_FW
    local rest saved_expected
    state_line=$(cat "$STATE_FILE" 2>/dev/null || echo "INITIAL||")
    stage="${state_line%%|*}"
    rest="${state_line#*|}"
    saved_result_dir="${rest%%|*}"
    saved_expected="${rest#*|}"

    # Set RESULT_DIR and LOG_FILE
    if [ "$stage" = "STAGE_AFTER_POWERCYCLE" ] && [ -n "$saved_result_dir" ] && [ -d "$saved_result_dir" ]; then
        RESULT_DIR="$saved_result_dir"
        LOG_FILE="${RESULT_DIR}/test_report.log"
        EXPECTED_FROM_STATE="${saved_expected:-}"
        log "===== Resuming after power cycle ====="
    else
        RESULT_DIR="${SCRIPT_DIR}/fw_test_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$RESULT_DIR"
        LOG_FILE="${RESULT_DIR}/test_report.log"
        stage="INITIAL"
        log "===== NVMe FW Upgrade/Downgrade Test Started ====="
        log "Results directory: $RESULT_DIR"
    fi

    # Scan FW directory (needed on both first run and resume)
    log "Scanning FW directory: $FW_LOCAL_DIR"
    if [ ! -d "$FW_LOCAL_DIR" ]; then
        log "ERROR: FW directory not found: $FW_LOCAL_DIR"
        exit 1
    fi

    # Scan FW directory for firmware files, sorted lexicographically by filename.
    # NOTE: Files are sorted by filename, not by embedded version number.
    # If your naming convention doesn't sort correctly by version (e.g. v2, v10),
    # rename files to include zero-padded version numbers (e.g. v02_..., v10_...).
    mapfile -t HISTORY_FW_LIST < <(find "$FW_LOCAL_DIR" -maxdepth 1 -type f \( -iname "*.bin" -o -iname "*.fw" \) | sort)
    if [ ${#HISTORY_FW_LIST[@]} -lt 2 ]; then
        log "ERROR: At least 2 firmware files required (latest + historical)"
        exit 1
    fi

    log "Firmware files:"
    for f in "${HISTORY_FW_LIST[@]}"; do log "  $f"; done

    LATEST_FW_LOCAL="${HISTORY_FW_LIST[-1]}"
    OLD_FW_LOCAL="${HISTORY_FW_LIST[0]}"
    LATEST_VERSION=$(extract_version_from_filename "$LATEST_FW_LOCAL")
    OLD_VERSION=$(extract_version_from_filename "$OLD_FW_LOCAL")
    log "Latest version : ${LATEST_VERSION}  ($(basename "$LATEST_FW_LOCAL"))"
    log "Oldest version : ${OLD_VERSION}  ($(basename "$OLD_FW_LOCAL"))"

    # Log vendor tool if configured
    if [ -n "$VENDOR_TOOL" ]; then
        log "Vendor tool    : $VENDOR_TOOL"
    fi

    # Resume path
    if [ "$stage" = "STAGE_AFTER_POWERCYCLE" ]; then
        run_after_powercycle
        return
    fi

    # ---- If we reach a power-cycle at the end of the normal path (after upgrade/io),
    #      ensure the expected version is set to the latest before calling handler. ----

    # ---- Point 6 (baseline): Initial SMART + BMC before any operation ----
    log "===== Point 6 (baseline): Initial SMART and BMC collection ====="
    collect_smart "init"
    collect_bmc_log "init"
    clear_dmesg
    log "Initial fw-log output:"
    nvme fw-log "$NVME_DEVICE" 2>&1 | tee -a "$LOG_FILE"
    log "FW version before test: $(get_fw_rev)"

    # ---- Point 1: Upgrade FW to latest version ----
    log "===== Point 1: Upgrade FW to latest (${LATEST_VERSION}) ====="
    if do_fw_update "$LATEST_FW_LOCAL" 1 3; then
        if verify_fw_version "$LATEST_VERSION" "After upgrade (no power cycle)"; then
            record_result "Point1_Upgrade" "PASS" \
                "FW upgraded to ${LATEST_VERSION} successfully (no power cycle)"
        else
            record_result "Point1_Upgrade" "FAIL" \
                "Version mismatch after upgrade (expected: ${LATEST_VERSION})"
            exit 1
        fi
    else
        record_result "Point1_Upgrade" "FAIL" "fw-download or fw-commit command failed"
        exit 1
    fi

    # ---- Point 2: IO test after upgrade (no power cycle) ----
    log "===== Point 2: IO test after upgrade (no power cycle) ====="
    if do_io_test "after_upgrade"; then
        record_result "Point2_UpgradeIO" "PASS" \
            "DD read succeeded and iostat IO observed after upgrade (see io_after_upgrade.log)"
    else
        record_result "Point2_UpgradeIO" "FAIL" "DD read failed after upgrade"
    fi

    # ---- Points 3 & 4: Power cycle, then continue in run_after_powercycle() ----
    EXPECTED_FW="$LATEST_VERSION"
    handle_power_cycle "$EXPECTED_FW"
    # Normal execution does not reach here — system powers off above
}

main