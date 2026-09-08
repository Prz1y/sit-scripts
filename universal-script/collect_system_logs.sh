#!/bin/bash
# collect_system_logs.sh
# 收集系统关键日志: dmesg, messages, MCE
# 用法: bash collect_system_logs.sh [输出目录]

set -euo pipefail

###############################################################################
# 配置
###############################################################################
OUTPUT_DIR="${1:-/tmp/system_logs_$(hostname)_$(date +%Y%m%d_%H%M%S)}"
HOSTNAME="$(hostname)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

###############################################################################
# 工具函数
###############################################################################
log_info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 身份运行此脚本 (sudo bash $0)"
        exit 1
    fi
}

###############################################################################
# 初始化输出目录
###############################################################################
init_output_dir() {
    mkdir -p "${OUTPUT_DIR}"
    log_info "日志将保存到: ${OUTPUT_DIR}"
}

###############################################################################
# 收集 dmesg
###############################################################################
collect_dmesg() {
    local out="${OUTPUT_DIR}/dmesg_${TIMESTAMP}.log"
    log_info "正在收集 dmesg ..."

    if command -v dmesg &>/dev/null; then
        # -T ：可读时间戳 (内核 >= 3.5); 部分旧内核不支持, 回退到无 -T
        if dmesg -T &>/dev/null; then
            dmesg -T > "${out}" 2>&1
        else
            dmesg > "${out}" 2>&1
        fi
        log_info "dmesg 已保存: ${out} ($(wc -l < "${out}") 行)"
    else
        log_warn "dmesg 命令不存在, 跳过"
    fi
}

###############################################################################
# 收集 /var/log/messages 或 /var/log/syslog
###############################################################################
collect_messages() {
    log_info "正在收集 messages/syslog ..."

    local candidates=(
        /var/log/messages
        /var/log/syslog
        /var/log/messages-*    # RHEL/CentOS 轮转文件
        /var/log/syslog.*      # Debian/Ubuntu 轮转文件
    )

    local found=0
    shopt -s nullglob
    for pattern in "${candidates[@]}"; do
        # 使用 glob 展开
        for f in $pattern; do
            [[ -f "$f" ]] || continue
            local base_name
            base_name="$(basename "${f}")"
            local out="${OUTPUT_DIR}/messages_${base_name}_${TIMESTAMP}.log"
            cp "${f}" "${out}"
            log_info "已复制: ${f} -> ${out} ($(wc -l < "${out}") 行)"
            found=1
        done
    done

    if [[ $found -eq 0 ]]; then
        log_warn "未找到 messages/syslog 文件, 尝试通过 journalctl 导出 ..."
        if command -v journalctl &>/dev/null; then
            local out="${OUTPUT_DIR}/journal_${TIMESTAMP}.log"
            journalctl --no-pager -o short-iso > "${out}" 2>&1
            log_info "journalctl 已保存: ${out} ($(wc -l < "${out}") 行)"
        else
            log_warn "journalctl 也不可用, 跳过 messages 收集"
        fi
    fi
}

###############################################################################
# 收集 MCE (Machine Check Exception) 日志
###############################################################################
collect_mce() {
    log_info "正在收集 MCE 日志 ..."

    local found=0

    # 1. /var/log/mcelog (传统 mcelog daemon)
    if [[ -f /var/log/mcelog ]]; then
        local out="${OUTPUT_DIR}/mcelog_${TIMESTAMP}.log"
        cp /var/log/mcelog "${out}"
        log_info "mcelog 已保存: ${out} ($(wc -l < "${out}") 行)"
        found=1
    fi

    # 2. mcelog 命令实时读取 /dev/mcelog
    if command -v mcelog &>/dev/null; then
        local out="${OUTPUT_DIR}/mcelog_live_${TIMESTAMP}.log"
        mcelog --client > "${out}" 2>&1 || mcelog > "${out}" 2>&1 || true
        if [[ -s "${out}" ]]; then
            log_info "mcelog 实时输出已保存: ${out} ($(wc -l < "${out}") 行)"
            found=1
        else
            rm -f "${out}"
        fi
    fi

    # 3. rasdaemon / ras-mc-ctl (现代替代方案)
    if command -v ras-mc-ctl &>/dev/null; then
        local out="${OUTPUT_DIR}/rasdaemon_errors_${TIMESTAMP}.log"
        ras-mc-ctl --errors > "${out}" 2>&1 || true
        if [[ -s "${out}" ]]; then
            log_info "rasdaemon 错误已保存: ${out} ($(wc -l < "${out}") 行)"
            found=1
        else
            rm -f "${out}"
        fi
    fi

    # 4. /sys/firmware/acpi/tables/BERT (Boot Error Record Table)
    if [[ -f /sys/firmware/acpi/tables/BERT ]]; then
        local out="${OUTPUT_DIR}/acpi_bert_${TIMESTAMP}.bin"
        cp /sys/firmware/acpi/tables/BERT "${out}" 2>/dev/null || true
        [[ -s "${out}" ]] && log_info "ACPI BERT 已保存: ${out}" && found=1
    fi

    # 5. 从 dmesg 中过滤 MCE 相关信息
    local out="${OUTPUT_DIR}/mce_from_dmesg_${TIMESTAMP}.log"
    if command -v dmesg &>/dev/null; then
        if dmesg -T 2>/dev/null | grep -iE 'mce|machine.check|hardware.error|edac|corrected|uncorrected|dimm|rank|bank|socket' > "${out}" 2>&1; then
            if [[ -s "${out}" ]]; then
                log_info "dmesg 中 MCE 相关行已保存: ${out} ($(wc -l < "${out}") 行)"
                found=1
            else
                rm -f "${out}"
            fi
        else
            rm -f "${out}"
        fi
    fi

    # 6. EDAC sysfs
    local edac_out="${OUTPUT_DIR}/edac_sysfs_${TIMESTAMP}.log"
    if [[ -d /sys/devices/system/edac ]]; then
        find /sys/devices/system/edac -type f -name "*.count" -o -name "*.size" \
             -o -name "ce_count" -o -name "ue_count" \
             -o -name "ce_noinfo_count" -o -name "ue_noinfo_count" 2>/dev/null \
        | sort \
        | while read -r sysfs_file; do
            printf '%-80s : %s\n' "${sysfs_file}" "$(cat "${sysfs_file}" 2>/dev/null)"
        done > "${edac_out}" 2>&1
        if [[ -s "${edac_out}" ]]; then
            log_info "EDAC sysfs 信息已保存: ${edac_out} ($(wc -l < "${edac_out}") 行)"
            found=1
        else
            rm -f "${edac_out}"
        fi
    fi

    if [[ $found -eq 0 ]]; then
        log_warn "未发现任何 MCE 日志来源"
    fi
}

###############################################################################
# 收集基本系统信息 (辅助诊断)
###############################################################################
collect_sysinfo() {
    log_info "正在收集基本系统信息 ..."
    local out="${OUTPUT_DIR}/sysinfo_${TIMESTAMP}.log"

    {
        echo "===== 采集时间 ====="
        date
        echo
        echo "===== 主机名 ====="
        hostname -f 2>/dev/null || hostname
        echo
        echo "===== 内核版本 ====="
        uname -a
        echo
        echo "===== OS 发行版 ====="
        cat /etc/os-release 2>/dev/null || cat /etc/redhat-release 2>/dev/null || echo "未知"
        echo
        echo "===== 运行时间 ====="
        uptime
        echo
        echo "===== CPU 信息 ====="
        lscpu 2>/dev/null || head -40 /proc/cpuinfo
        echo
        echo "===== 内存信息 ====="
        free -h
        echo
        echo "===== DIMM 信息 (dmidecode) ====="
        if command -v dmidecode &>/dev/null; then
            dmidecode -t 17 2>/dev/null | grep -E 'Locator|Size|Speed|Manufacturer|Part|Serial|Type|Rank|Configured' || echo "无法读取 DMI 信息"
        else
            echo "dmidecode 不可用"
        fi
    } >> "${out}" 2>&1

    log_info "系统信息已保存: ${out}"
}

###############################################################################
# 打包归档
###############################################################################
package_logs() {
    local archive="/tmp/system_logs_${HOSTNAME}_${TIMESTAMP}.tar.gz"
    log_info "正在打包日志到 ${archive} ..."
    tar -czf "${archive}" -C "$(dirname "${OUTPUT_DIR}")" "$(basename "${OUTPUT_DIR}")"
    log_info "打包完成: ${archive} ($(du -sh "${archive}" | cut -f1))"
    echo
    echo "----------------------------------------------------------------------"
    echo "日志归档: ${archive}"
    echo "日志目录: ${OUTPUT_DIR}"
    echo "----------------------------------------------------------------------"
}

###############################################################################
# 主流程
###############################################################################
main() {
    require_root
    init_output_dir

    collect_dmesg
    collect_messages
    collect_mce
    collect_sysinfo
    package_logs

    log_info "所有日志收集完成"
}

main "$@"
