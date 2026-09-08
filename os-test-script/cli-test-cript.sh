#!/bin/bash

# 设置为中文环境以触发中文报错"未找到命令"
if locale -a 2>/dev/null | grep -q "zh_CN.utf8\|zh_CN.UTF-8"; then
    export LC_ALL=zh_CN.UTF-8
    export LANG=zh_CN.UTF-8
else
    export LC_ALL=C
    export LANG=C
fi

# 获取操作系统的内核版本
OS_KERNEL=$(uname -r)

# 对应测试用例
group1=("ls" "cd" "pwd" "mkdir" "mv" "rmdir" "cp" "vi" "cat" "touch" "file" "ln" "grep" "chown" "chmod" "sort" "wc" "fdisk" "df" "mount" "mkfs" "tar" "dd" "zip" "unzip" "gzip")
group2=("ps" "vmstat" "top" "iostat" "sar")
group3=("ifconfig" "ping" "ssh" "scp" "telnet")
group4=("kill" "man" "who" "date" "more" "ps" "su" "sudo" "uname" "service" "chkconfig" "systemctl")
group5=("useradd" "userdel" "usermod" "groupadd" "groupdel" "groupmod" "id")

# 测试执行核心函数
run_test() {
    local folder_name="$1"
    shift
    local cmds=("$@")

    mkdir -p "$folder_name"
    local log_file="${folder_name}/execution.log"
    : > "$log_file"

    echo "正在执行测试并生成日志: ${folder_name}/execution.log ..."
    echo "==================================================" >> "$log_file"
    echo "系统内核版本 (uname -r): $OS_KERNEL" >> "$log_file"
    echo "==================================================" >> "$log_file"

    for cmd in "${cmds[@]}"; do
        echo "--------------------------------------------------" >> "$log_file"
        echo "执行指令: $cmd --help" >> "$log_file"
        echo "--------------------------------------------------" >> "$log_file"

        if command -v "$cmd" >/dev/null 2>&1; then
            case "$cmd" in
                vi) "$cmd" -h >> "$log_file" 2>&1 || "$cmd" --help >> "$log_file" 2>&1 ;;
                *) "$cmd" --help >> "$log_file" 2>&1 ;;
            esac
        else
            echo "command not found: $cmd" >> "$log_file"
        fi
        echo "" >> "$log_file"
    done

    # 自动化检查：搜索"未找到命令"、"command not found"、"Permission denied"
    echo "==================================================" >> "$log_file"
    local test_failed=0
    if grep -Eiq "未找到命令|command not found" "$log_file"; then
        echo "自动化测试结论: 测试不通过，日志中发现'未找到命令'或'command not found'。" >> "$log_file"
        test_failed=1
    fi
    if grep -q "Permission denied" "$log_file"; then
        echo "警告: 日志中发现'Permission denied'，部分命令因权限不足未正常执行（如 fdisk）" >> "$log_file"
        # 权限问题不影响"命令存在"的判定，仅记录警告
    fi
    if [ "$test_failed" -eq 0 ]; then
        echo "自动化测试：程序成功执行完成，日志中不包含'未找到命令'或'command not found'关键字" >> "$log_file"
    fi
}

echo "开始执行系统命令探测自动化测试..."
echo "当前内核版本: $OS_KERNEL"
echo "说明: 本脚本仅检测命令是否存在(通过--help)，不验证命令实际功能是否正常"
echo "      权限不足导致的'Permission denied'视为警告，不视为失败"
echo "--------------------------------------------------"

run_test "01_TestResult_File_And_Disk" "${group1[@]}"
run_test "02_TestResult_System_Monitor" "${group2[@]}"
run_test "03_TestResult_Network" "${group3[@]}"
run_test "04_TestResult_System_Admin" "${group4[@]}"
run_test "05_TestResult_User_And_Group" "${group5[@]}"

echo "--------------------------------------------------"
echo "所有测试脚本执行完毕！"
echo "请查看当前目录下生成的 5 个文件夹中的 execution.log 文件获取结果。"
