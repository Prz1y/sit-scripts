#!/usr/bin/env bash
# NVMe硬盘信息查询脚本
# 功能：查询OS下NVMe SSD的详细信息，按容量点分类存入不同文件夹
# 依赖：nvme-cli, lspci(pciutils), lsblk(util-linux)
# 用法：直接运行 ./nvme_info_query.sh
# WARNING: This script deletes and recreates its output directory under the current path.
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

OUTPUT_ROOT="nvme_info_output"

echo "WARNING: nvme_info_query.sh will delete and recreate ${OUTPUT_ROOT} under the current directory." >&2

# 检查依赖命令
check_deps()
{
    local missing=0
    for cmd in nvme lspci lsblk awk grep; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "错误: 命令 '$cmd' 未找到，请先安装对应软件包"
            missing=1
        fi
    done
    if [ "$missing" -eq 1 ]; then
        exit 1
    fi
}

# 从nvme list输出中获取所有NVMe设备列表
get_nvme_devices()
{
    nvme list 2>/dev/null | awk '
    NR > 2 {
        if ($0 ~ /^\/dev\/nvme/ && $0 !~ /^---/) {
            print $0
        }
    }'
}

# 解析设备信息行，提取 Node, SN, Model, Namespace, Usage, FW
parse_device_line()
{
    local line="$1"
    node=$(echo "$line" | awk '{print $1}')
    sn=$(echo "$line" | awk '{print $2}')
    fw_rev=$(echo "$line" | awk '{print $NF}')
    local nf
    nf=$(echo "$line" | awk '{print NF}')
    # Model: $3 ~ $(NF-12)
    model=""
    local i
    for i in $(seq 3 $((nf - 12))); do
        local part
        part=$(echo "$line" | awk -v idx="$i" '{print $idx}')
        if [ -z "$model" ]; then
            model="$part"
        else
            model="$model $part"
        fi
    done
    # 容量字段
    usage_val=$(echo "$line" | awk -v idx1="$((nf - 10))" -v idx2="$((nf - 9))" '{print $idx1, $idx2}')
    # Namespace
    ns=$(echo "$line" | awk -v idx="$((nf - 11))" '{print $idx}')
    # 去除 /dev/ 前缀获取 nvmeX
    nvme_name=$(basename "$node" | sed 's/n[0-9]$//')
}

# 获取 PCI BDF (Bus:Device.Function)
get_pci_bdf()
{
    local nvme_name="$1"
    if [ -f "/sys/class/nvme/${nvme_name}/address" ]; then
        cat "/sys/class/nvme/${nvme_name}/address"
    fi
}

# 从 lspci -vvv 行解析 Speed/Width 字段
parse_lspci_link_field()
{
    local line="$1"
    local speed width
    speed=$(echo "$line" | grep -Eo "Speed[[:space:]]+[0-9.]+[[:space:]]*GT/s" | head -1)
    width=$(echo "$line" | grep -Eo "Width:[[:space:]]*x[0-9]+" | head -1)
    if [ -z "$width" ]; then
        width=$(echo "$line" | grep -Eo "Width[[:space:]]+x[0-9]+" | head -1)
    fi
    if [ -n "$speed" ] && [ -n "$width" ]; then
        echo "$speed, $width"
    fi
}

# 获取PCIe链路能力（最大速率和宽度）
get_pcie_link_cap()
{
    local bdf="$1"
    if [ -z "$bdf" ]; then
        echo "N/A"
        return
    fi
    local lspci_output
    lspci_output=$(lspci -s "$bdf" -vvv 2>/dev/null)
    local cap_line
    cap_line=$(echo "$lspci_output" | grep -i "LnkCap:")
    if [ -z "$cap_line" ]; then
        echo "N/A"
        return
    fi
    local result
    result=$(parse_lspci_link_field "$cap_line")
    if [ -n "$result" ]; then
        echo "$result"
    else
        echo "N/A"
    fi
}

# 获取PCIe链路状态（当前协商速率和宽度）
get_pcie_link_sta()
{
    local bdf="$1"
    if [ -z "$bdf" ]; then
        echo "N/A"
        return
    fi
    local lspci_output
    lspci_output=$(lspci -s "$bdf" -vvv 2>/dev/null)
    local sta_line
    sta_line=$(echo "$lspci_output" | grep -i "LnkSta:")
    if [ -z "$sta_line" ]; then
        echo "N/A"
        return
    fi
    local result
    result=$(parse_lspci_link_field "$sta_line")
    if [ -n "$result" ]; then
        echo "$result"
    else
        echo "N/A"
    fi
}

# 从 nvme list Model 字段提取厂商名（第一个空格分隔词）
get_vendor_from_model()
{
    local model_str="$1"
    echo "$model_str" | awk '{print $1}'
}

# 获取设备厂商信息（优先 lspci 设备描述，fallback nvme list Model 前缀）
get_vendor_id()
{
    local node="$1"
    local model_str="$2"
    local nvme_name
    nvme_name=$(basename "$node" | sed 's/n[0-9]$//')
    local bdf
    bdf=$(cat /sys/class/nvme/"${nvme_name}"/address 2>/dev/null)
    local vendor_str=""
    if [ -n "$bdf" ]; then
        vendor_str=$(lspci -s "$bdf" 2>/dev/null | awk -F': ' '{print $2}' | awk -F'[' '{print $1}' | sed 's/ *$//')
    fi
    if [ -n "$vendor_str" ]; then
        echo "$vendor_str"
    else
        echo "$(get_vendor_from_model "$model_str")"
    fi
}

# 获取 nvme smart-log 信息
get_smart_info()
{
    local node="$1"
    local smart_output
    smart_output=$(nvme smart-log "$node" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$smart_output" ]; then
        echo "smart_log_error"
        return
    fi
    local pct_used power_on temp
    pct_used=$(echo "$smart_output" | grep "^percentage_used" | awk -F':' '{print $2}' | tr -d ' %')
    power_on=$(echo "$smart_output" | grep "^power_on_hours" | awk -F':' '{print $2}' | tr -d ' ')
    temp=$(echo "$smart_output" | grep "^temperature" | awk -F':' '{print $2}' | awk '{print $1}')
    echo "$pct_used|$power_on|$temp"
}

# 获取容量标签（用于文件夹命名）
get_capacity_label()
{
    local model="$1"
    local usage_val="$2"
    local cap_label
    cap_label=$(echo "$usage_val" | awk '{gsub(/ +/,""); print}')
    if [ -z "$cap_label" ]; then
        cap_label="unknown_capacity"
    fi
    echo "$cap_label"
}

# 获取设备对应的PCIe接口类型
get_interface_type()
{
    local bdf="$1"
    local link_cap="$2"
    local speed
    speed=$(echo "$link_cap" | grep -Eo "[0-9.]+ GT/s" | head -1)
    local width
    width=$(echo "$link_cap" | grep -Eo "x[0-9]+" | head -1)
    if [ -n "$speed" ] && [ -n "$width" ]; then
        local gen=""
        case "$speed" in
            "2.5 GT/s") gen="PCIe 1.0";;
            "5.0 GT/s") gen="PCIe 2.0";;
            "8.0 GT/s") gen="PCIe 3.0";;
            "16.0 GT/s") gen="PCIe 4.0";;
            "32.0 GT/s") gen="PCIe 5.0";;
            "64.0 GT/s") gen="PCIe 6.0";;
            *) gen="PCIe $speed";;
        esac
        echo "${gen} ${width}"
    else
        echo "N/A"
    fi
}

# 获取设备状态
get_device_status()
{
    local node="$1"
    local state
    state=$(cat /sys/class/nvme/"$(basename "$node" | sed 's/n[0-9]$//')"/state 2>/dev/null || echo "unknown")
    echo "$state"
}

main()
{
    check_deps

    rm -rf "$OUTPUT_ROOT"
    mkdir -p "$OUTPUT_ROOT"

    local devices
    devices=$(get_nvme_devices)
    if [ -z "$devices" ]; then
        echo "未检测到NVMe设备"
        exit 1
    fi

    echo "检测到NVMe设备，开始信息采集..."
    echo ""

    local disk_count=0
    local line

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        disk_count=$((disk_count + 1))

        parse_device_line "$line"

        echo "[$disk_count] 正在处理: $node ($model)"

        local bdf
        bdf=$(get_pci_bdf "$nvme_name")

        local link_cap
        link_cap=$(get_pcie_link_cap "$bdf")

        local link_sta
        link_sta=$(get_pcie_link_sta "$bdf")

        local interface_type
        interface_type=$(get_interface_type "$bdf" "$link_cap")

        local vendor_id
        vendor_id=$(get_vendor_id "$node" "$model")

        local smart_info
        smart_info=$(get_smart_info "$node")
        local pct_used="N/A"
        local power_on="N/A"
        local temp="N/A"
        if [ "$smart_info" != "smart_log_error" ]; then
            pct_used=$(echo "$smart_info" | awk -F'|' '{print $1}')
            power_on=$(echo "$smart_info" | awk -F'|' '{print $2}')
            temp=$(echo "$smart_info" | awk -F'|' '{print $3}')
        fi

        local nvme_state
        nvme_state=$(get_device_status "$node")

        local cap_label
        cap_label=$(get_capacity_label "$model" "$usage_val")
        local cap_dir="${OUTPUT_ROOT}/${cap_label}"
        mkdir -p "$cap_dir"

        local health_status=""
        if [ "$pct_used" != "N/A" ]; then
            health_status="寿命: ${pct_used}% used, 上电时间: ${power_on} hrs"
        else
            health_status="N/A"
        fi

        # 保存原始命令输出到容量文件夹（用于测试备注）
        local raw_dir="${cap_dir}/${node##*/}_raw_cmd_output"
        mkdir -p "$raw_dir"
        nvme id-ctrl "$node" > "${raw_dir}/nvme_id-ctrl.txt" 2>&1
        nvme smart-log "$node" > "${raw_dir}/nvme_smart-log.txt" 2>&1
        if [ -n "$bdf" ]; then
            lspci -s "$bdf" -vvv > "${raw_dir}/lspci-vvv.txt" 2>&1
        fi

        # 判断设备是否正常
        local device_status="异常"
        if [ "$nvme_state" = "live" ] || [ "$nvme_state" = "active" ]; then
            device_status="正常"
        fi

        # 输出单盘详细报告到容量文件夹
        local detail_file="${cap_dir}/${node##*/}_detail.txt"
        {
            echo "============================================"
            echo "NVMe 硬盘信息报告"
            echo "============================================"
            echo "查询时间: $(date '+%Y-%m-%d %H:%M:%S')"
            echo ""
            echo "--- 基本信息 ---"
            echo "设备节点:       $node"
            echo "厂商:           $vendor_id"
            echo "型号:           $model"
            echo "序列号(SN):     $sn"
            echo "Firmware版本:   $fw_rev"
            echo "容量:           $usage_val"
            echo "槽位号:         N/A (直连无法获取)"
            echo "命名空间:       $ns"
            echo ""
            echo "--- PCIe 信息 ---"
            echo "PCI BDF:        $bdf"
            echo "接口类型:       $interface_type"
            echo "最大链路:       $link_cap"
            echo "当前链路:       $link_sta"
            echo ""
            echo "--- 健康状态 ---"
            echo "健康状态:       $health_status"
            echo "温度:           ${temp} C"
            echo "NVMe状态:       $nvme_state ($device_status)"
            echo ""
            echo "--- 查询命令 ---"
            echo "1) nvme list"
            echo "2) nvme id-ctrl ${node}"
            echo "3) nvme smart-log ${node}"
            echo "4) lspci -s ${bdf} -vvv"
            echo "5) lsblk | grep ${nvme_name}"
            echo ""
            echo "--- 原始命令输出已保存至 ---"
            echo "${raw_dir}/nvme_id-ctrl.txt"
            echo "${raw_dir}/nvme_smart-log.txt"
            echo "${raw_dir}/lspci-vvv.txt"
            echo "============================================"
        } > "$detail_file"

        echo "   -> 已保存至: $cap_dir/"
        echo ""

    done <<< "$devices"

    echo "============================================"
    echo "采集完成！共处理 $disk_count 个NVMe设备"
    echo ""
    echo "输出目录结构:"
    echo "  $OUTPUT_ROOT/"
    local dir
    for dir in $(ls -d "${OUTPUT_ROOT}"/*/ 2>/dev/null | sort); do
        local cap_name
        cap_name=$(basename "$dir")
        local count
        count=$(ls "$dir"/*_detail.txt 2>/dev/null | wc -l)
        echo "    ${cap_name}/   (${count} 个设备)"
    done
}

main "$@"
