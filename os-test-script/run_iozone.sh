#!/bin/bash

set -euo pipefail

# ==========================================
# Iozone Automated Benchmark Script (RHEL)
# Features: Auto RAM sizing, Space check, Pandas Excel export, Auto-cleanup
# ==========================================

TEST_DIR="/home/iozone_test"
TEST_FILE="$TEST_DIR/test_data.tmp"
CSV_FILE="$TEST_DIR/iozone_report_backup.csv"
EXCEL_FILE="$TEST_DIR/iozone_report.xlsx"

# 1. Environment Preparation
mkdir -p "$TEST_DIR" || { echo "[ERROR] 无法创建测试目录: $TEST_DIR" >&2; exit 1; }
echo "[INFO] Checking system physical memory..."

# Get total physical memory in GB (Rounded up)
TOTAL_RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
echo "[INFO] Total system physical memory: ${TOTAL_RAM_GB} GB"

# Calculate file sizes for the 3 test groups
SIZE_HALF=$((TOTAL_RAM_GB / 2))
[ "$SIZE_HALF" -lt 1 ] && SIZE_HALF=1
SIZE_ONE=$TOTAL_RAM_GB
SIZE_TWO=$((TOTAL_RAM_GB * 2))

# Embed Python script 1: Log Parser
PYTHON_PARSER="$TEST_DIR/parse_log.py"
cat << 'EOF' > "$PYTHON_PARSER"
import sys

def parse_iozone(file_path, label, size_gb):
    try:
        with open(file_path, 'r') as f:
            lines = f.readlines()
            
        for line in lines:
            parts = line.split()
            # Find the line for 16M record size (16384 KB)
            if len(parts) >= 8 and parts[1] == '16384':
                seq_write = float(parts[2]) / 1024
                seq_read = float(parts[4]) / 1024
                rand_read = float(parts[6]) / 1024
                rand_write = float(parts[7]) / 1024
                
                print(f"{label},{size_gb},{seq_read:.2f},{seq_write:.2f},{rand_read:.2f},{rand_write:.2f}")
                return
        print(f"{label},{size_gb},N/A,N/A,N/A,N/A")
    except Exception as e:
        print(f"{label},{size_gb},Error,Error,Error,Error")

if __name__ == "__main__":
    parse_iozone(sys.argv[1], sys.argv[2], sys.argv[3])
EOF

# Embed Python script 2: Pandas Excel Generator
PYTHON_EXCEL="$TEST_DIR/generate_excel.py"
cat << 'EOF' > "$PYTHON_EXCEL"
import sys

try:
    import pandas as pd
except ImportError:
    print("[ERROR] Python library 'pandas' is not installed.")
    print("[INFO] Please run: pip3 install pandas openpyxl")
    sys.exit(1)

csv_file = sys.argv[1]
excel_file = sys.argv[2]

try:
    df = pd.read_csv(csv_file)
    df.to_excel(excel_file, index=False, engine='openpyxl')
    print(f"[SUCCESS] Excel report generated successfully: {excel_file}")
    sys.exit(0)
except Exception as e:
    print(f"[ERROR] Failed to generate Excel: {e}")
    sys.exit(1)
EOF

# Initialize CSV File (Temporary Storage)
echo "Test Group (16M Block),File Size (GB),Seq Read (MB/s),Seq Write (MB/s),Rand Read (MB/s),Rand Write (MB/s)" > "$CSV_FILE"

# 2. Define the Test Execution Function
get_free_space_gb() {
    # 兼容 df -BG 可能输出 GB、T 等单位，统一转换为 GB
    local raw
    raw=$(df -BG "$TEST_DIR" | awk 'NR==2 {print $4}' | sed 's/G//')
    # 如果 raw 包含 T（TB 级别），乘以 1024
    local t_check
    t_check=$(df -BG "$TEST_DIR" | awk 'NR==2 {print $4}' | grep -o '[Tt]' || true)
    if [ -n "$t_check" ]; then
        # 提取数字部分，转换为 GB
        local tb_val
        tb_val=$(df -BG "$TEST_DIR" | awk 'NR==2 {print $4}' | sed 's/G//')
        echo "${tb_val:-0}"
    else
        echo "${raw:-0}"
    fi
}

run_test() {
    local label=$1
    local size_gb=$2
    local raw_log="$TEST_DIR/raw_${size_gb}g.log"
    
    echo -e "\n------------------------------------------------------------"
    echo "[START] Preparing test: [$label], File size: ${size_gb} GB"
    
    # Check free disk space in /home
    local free_space_gb
    free_space_gb=$(get_free_space_gb)
    if ! [[ "$free_space_gb" =~ ^[0-9]+$ ]] || ! [[ "$size_gb" =~ ^[0-9]+$ ]]; then
        echo "[ERROR] 无法解析磁盘空间或测试文件大小: free=${free_space_gb}, size=${size_gb}"
        echo "$label,$size_gb,Skipped,Skipped,Skipped,Skipped" >> "$CSV_FILE"
        return
    fi
    if [ "$free_space_gb" -lt "$size_gb" ]; then
        echo "[ERROR] Insufficient disk space! Free: ${free_space_gb} GB, Required: ${size_gb} GB."
        echo "[ERROR] Skipping [$label] test to prevent disk overflow."
        echo "$label,$size_gb,Skipped,Skipped,Skipped,Skipped" >> "$CSV_FILE"
        return
    fi
    
    echo "[INFO] Disk space is sufficient (${free_space_gb} GB free)."
    echo "[INFO] Running Iozone benchmark. This will take a long time, please wait..."
    
    # Core Iozone command (record size = 16M, same as Python parser expects)
    iozone -r 16m -s ${size_gb}g -i 0 -i 1 -i 2 -e -f "$TEST_FILE" -R > "$raw_log" 2>/dev/null
    
    # Parse results using Python
    if command -v python3 &>/dev/null; then
        RESULT_CSV=$(python3 "$PYTHON_PARSER" "$raw_log" "$label" "$size_gb")
    else
        RESULT_CSV=$(python "$PYTHON_PARSER" "$raw_log" "$label" "$size_gb")
    fi
    
    # Append to CSV backup
    echo "$RESULT_CSV" >> "$CSV_FILE"
    
    # Format and print single line result to console
    echo "$RESULT_CSV" | awk -F',' '{printf "[RESULT] %s (%s GB) -> Seq Read: %s MB/s | Seq Write: %s MB/s | Rand Read: %s MB/s | Rand Write: %s MB/s\n", $1, $2, $3, $4, $5, $6}'
    
    # Clean up the large test file & raw log
    echo "[INFO] Cleaning up test file: $TEST_FILE ..."
    rm -f "$TEST_FILE"
    rm -f "$raw_log"
    echo "[DONE] Test [$label] finished and file successfully deleted."
}

# 3. Execute the 3 sets of tests sequentially
run_test "1/2x_RAM" "$SIZE_HALF"
run_test "1x_RAM"   "$SIZE_ONE"
run_test "2x_RAM"   "$SIZE_TWO"

echo -e "\n------------------------------------------------------------"
echo "[INFO] All tests finished. Generating Excel report using Pandas..."

# 4. Generate Excel and Clean up
if command -v python3 &>/dev/null; then
    python3 "$PYTHON_EXCEL" "$CSV_FILE" "$EXCEL_FILE"
else
    python "$PYTHON_EXCEL" "$CSV_FILE" "$EXCEL_FILE"
fi

# Check if Excel generation was successful
if [ $? -eq 0 ] && [ -f "$EXCEL_FILE" ]; then
    rm -f "$CSV_FILE"
else
    echo "[WARNING] Excel generation failed. The raw CSV backup has been kept at: $CSV_FILE"
fi

rm -f "$PYTHON_PARSER" "$PYTHON_EXCEL"

echo -e "\n======================================================================"
echo "[FINISH] Automation script execution complete!"
if [ -f "$EXCEL_FILE" ]; then
    echo "Your Excel report is ready at: $EXCEL_FILE"
fi
echo "======================================================================"
