#!/usr/bin/env python3
"""
Kdump 自动化测试脚本

功能说明:
    自动完成 kdump 配置、crash 触发、vmcore 验证的完整测试流程。
    测试步骤如下:
        Step 1: 启动 kdump 服务 (systemctl start/enable kdump)
        Step 2: 通过 ipmitool 打开被测机器 BMC 串口 (SOL)
        Step 3: 配置 /etc/sysctl.conf 中 NMI panic 参数
        Step 4: 配置 GRUB crashkernel=512M 并重启验证
        Step 5: 触发系统 crash (支持带内/带外两种方式)
        Step 6: 检查 /var/crash 目录下是否生成 vmcore 文件

依赖环境:
    测试控制机上需安装: sshpass, ipmitool
    被测机器需支持: kdump, kexec-tools, BMC SOL 功能

用法示例:

  # 完整测试 (带内 + 带外两种 crash 方式)
  python3 kdump_auto_test.py \
      --sut-ip 192.168.1.100 \
      --bmc-ip 192.168.1.200 \
      --bmc-user admin \
      --bmc-pass password \
      --ssh-user root \
      --ssh-pass rootpass

  # 仅测试带内触发 (inband)
  python3 kdump_auto_test.py \
      --sut-ip 192.168.1.100 \
      --bmc-ip 192.168.1.200 \
      --bmc-user admin \
      --bmc-pass password \
      --ssh-user root \
      --ssh-pass rootpass \
      --crash-method inband

  # 仅测试带外触发 (outband)
  python3 kdump_auto_test.py \
      --sut-ip 192.168.1.100 \
      --bmc-ip 192.168.1.200 \
      --bmc-user admin \
      --bmc-pass password \
      --ssh-user root \
      --ssh-pass rootpass \
      --crash-method outband

  # 跳过环境配置，直接触发 crash 和验证 (环境已提前配好)
  python3 kdump_auto_test.py \
      --sut-ip 192.168.1.100 \
      --bmc-ip 192.168.1.200 \
      --bmc-user admin \
      --bmc-pass password \
      --ssh-user root \
      --ssh-pass rootpass \
      --skip-config

参数说明:
  --sut-ip         被测机器 (SUT) 的 IP 地址，用于 SSH 连接
  --bmc-ip         被测机器 BMC 管理 IP 地址
  --bmc-user       BMC 登录用户名
  --bmc-pass       BMC 登录密码
  --ssh-user       SSH 登录用户名 (通常为 root)
  --ssh-pass       SSH 登录密码
  --ssh-port       SSH 端口，默认 22
  --crash-method   Crash 触发方式: inband(带内) / outband(带外) / both(两者都测)，默认 both
  --reboot-timeout 重启后等待 SSH 恢复的超时时间(秒)，默认 600
  --crash-timeout  Crash dump 过程等待超时时间(秒)，默认 300
  --sol-log        SOL 串口日志输出文件路径，默认 ./sol_output.log
  --skip-config    跳过 Step 1-4 环境配置，直接执行 crash 触发与验证

PASS 标准:
  /var/crash 目录下成功生成 vmcore 文件
"""

import argparse
import ipaddress
import subprocess
import time
import sys
import os
import shutil
import logging
import tempfile
from datetime import datetime

logger = logging.getLogger("kdump_test")
logger.setLevel(logging.INFO)
logger.handlers.clear()
logger.propagate = False
_log_format = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
_stream_handler = logging.StreamHandler(sys.stdout)
_stream_handler.setFormatter(_log_format)
_file_handler = logging.FileHandler("kdump_test.log", encoding="utf-8")
_file_handler.setFormatter(_log_format)
logger.addHandler(_stream_handler)
logger.addHandler(_file_handler)


class KdumpAutoTest:
    def __init__(
        self,
        sut_ip,
        bmc_ip,
        bmc_user,
        bmc_pass,
        ssh_user,
        ssh_pass,
        ssh_port=22,
        sol_log_file="./sol_output.log",
        reboot_timeout=1200,
        crash_timeout=1800,
        crashkernel_size="512M",
    ):
        self.sut_ip = sut_ip
        self.bmc_ip = bmc_ip
        self.bmc_user = bmc_user
        self.bmc_pass = bmc_pass
        self.ssh_user = ssh_user
        self.ssh_pass = ssh_pass
        self.ssh_port = ssh_port
        self.sol_log_file = sol_log_file
        self.reboot_timeout = reboot_timeout
        self.crash_timeout = crash_timeout
        self.crashkernel_size = crashkernel_size

        self.sol_process = None
        self.ipmi_pass_file = None
        self.test_result = {"vmcore_found": False, "crash_kernel_booted": False, "details": ""}

    # ==================== SSH 工具方法 ====================

    def ssh_cmd(self, command, timeout=60):
        """在 SUT 上通过 SSH 执行命令，返回 (returncode, stdout, stderr)"""
        full_cmd = [
            "sshpass", "-e",
            "ssh",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=10",
            "-p", str(self.ssh_port),
            f"{self.ssh_user}@{self.sut_ip}",
            command,
        ]
        logger.info(f"[SSH] 执行: {command}")
        env = os.environ.copy()
        env["SSHPASS"] = self.ssh_pass
        try:
            proc = subprocess.run(
                full_cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
                env=env,
            )
            return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
        except subprocess.TimeoutExpired:
            logger.error(f"[SSH] 命令超时 ({timeout}s): {command}")
            return -1, "", "TIMEOUT"
        except Exception as e:
            logger.error(f"[SSH] 执行失败: {e}")
            return -1, "", str(e)

    def ssh_ok(self, timeout=10):
        """检查 SUT 是否可以通过 SSH 连通"""
        ret, out, _ = self.ssh_cmd("echo 'ALIVE'", timeout=timeout)
        return ret == 0 and "ALIVE" in out

    def wait_ssh_ready(self, timeout=None):
        """等待 SUT SSH 服务就绪（重启后恢复连接）"""
        if timeout is None:
            timeout = self.reboot_timeout
        logger.info(f"[WAIT] 等待 SUT SSH 就绪，超时 {timeout}s ...")
        start = time.time()
        while time.time() - start < timeout:
            if self.ssh_ok(timeout=5):
                elapsed = time.time() - start
                logger.info(f"[WAIT] SUT SSH 已就绪，耗时 {elapsed:.0f}s")
                return True
            time.sleep(5)
        logger.error("[WAIT] 等待 SUT SSH 就绪超时！")
        return False

    # ==================== BMC / SOL 工具方法 ====================

    def _ensure_ipmi_password_file(self):
        if self.ipmi_pass_file and os.path.exists(self.ipmi_pass_file):
            return self.ipmi_pass_file

        fd, path = tempfile.mkstemp(prefix="kdump_ipmi_", text=True)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(self.bmc_pass)
        os.chmod(path, 0o600)
        self.ipmi_pass_file = path
        return path

    def ipmitool(self, args_list, timeout=30):
        """执行 ipmitool 命令"""
        if isinstance(args_list, str):
            raise TypeError("args_list must be a list of ipmitool arguments")

        base = [
            "ipmitool", "-I", "lanplus",
            "-H", self.bmc_ip,
            "-U", self.bmc_user,
            "-f", self._ensure_ipmi_password_file(),
        ]
        full_cmd = base + list(args_list)
        logger.info(f"[IPMI] 执行: {' '.join(args_list)}")
        try:
            proc = subprocess.run(
                full_cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            return proc.returncode, proc.stdout, proc.stderr
        except subprocess.TimeoutExpired:
            return -1, "", "TIMEOUT"
        except Exception as e:
            return -1, "", str(e)

    def start_sol_session(self):
        """在后台启动 ipmitool sol activate，持续捕获输出到日志文件"""
        cmd = [
            "ipmitool", "-I", "lanplus",
            "-H", self.bmc_ip,
            "-U", self.bmc_user,
            "-f", self._ensure_ipmi_password_file(),
            "sol", "activate",
        ]
        logger.info(f"[SOL] 启动串口会话，输出到: {self.sol_log_file}")
        with open(self.sol_log_file, "w", encoding="utf-8") as log_f:
            log_f.write(f"=== SOL 会话开始 {datetime.now()} ===\n")
            log_f.flush()
            self.sol_process = subprocess.Popen(
                cmd,
                stdout=log_f,
                stderr=log_f,
                stdin=subprocess.PIPE,
            )

    def stop_sol_session(self):
        """终止 SOL 会话"""
        if self.sol_process:
            logger.info("[SOL] 终止串口会话")
            # 发送退出序列：~. 或直接 kill
            try:
                self.sol_process.stdin.write(b"~.")
                self.sol_process.stdin.flush()
            except Exception:
                pass
            try:
                self.sol_process.terminate()
                self.sol_process.wait(timeout=10)
            except Exception:
                try:
                    self.sol_process.kill()
                except Exception:
                    pass
            self.sol_process = None
            logger.info("[SOL] 串口会话已终止")

    def _append_sol_log(self, text):
        """向 SOL 日志添加标记"""
        with open(self.sol_log_file, "a", encoding="utf-8") as f:
            f.write(f"\n=== {text} {datetime.now()} ===\n")

    def analyze_sol_log(self):
        """分析 SOL 日志，判断 kdump 是否成功"""
        try:
            with open(self.sol_log_file, "r", encoding="utf-8", errors="replace") as f:
                content = f.read()
        except FileNotFoundError:
            logger.error("[ANALYZE] SOL 日志文件不存在")
            return False

        # kdump capture kernel 启动特征
        boot_indicators = [
            "kexec: Starting new kernel",
            "kdump: saving vmcore",
            "Starting crashdump kernel",
            "Bye!",
            "Loading crash kernel",
            "Starting new kernel",
            "I'm in purgatory",
            "saving to",
            "vmcore",
            "dump saving complete",
            "saving core complete",
        ]

        reboot_indicators = [
            "reboot:",
            "Restarting system",
            "machine restart",
            "Booting",
            "Linux version",
        ]

        found_kdump = any(ind.lower() in content.lower() for ind in boot_indicators)
        found_reboot = any(ind.lower() in content.lower() for ind in reboot_indicators)

        logger.info(f"[ANALYZE] SOL 分析结果: kdump特征={'找到' if found_kdump else '未找到'}, "
                     f"重启特征={'找到' if found_reboot else '未找到'}")

        # 提取关键行
        for line in content.splitlines():
            line_lower = line.lower()
            if any(kw in line_lower for kw in ["kexec", "kdump", "vmcore", "saving", "dump", "capture", "crash kernel"]):
                logger.info(f"[SOL-LOG] {line.strip()}")

        return found_kdump

    # ==================== 测试步骤 ====================

    def step1_ensure_kdump_service(self):
        """确认并启动 kdump 服务"""
        logger.info("=" * 60)
        logger.info("[Step 1] 确认 kdump 服务")
        logger.info("=" * 60)

        # 安装 kdump 相关包（如果未安装）
        ret, out, err = self.ssh_cmd("which kdump 2>/dev/null || yum install -y kexec-tools 2>/dev/null || apt-get install -y kdump-tools 2>/dev/null || echo 'INSTALL_FAILED'", timeout=120)
        if "INSTALL_FAILED" in out:
            logger.warning("[Step 1] 无法自动安装 kdump 工具，请手动安装")

        # 启动 kdump
        self.ssh_cmd("systemctl start kdump")
        self.ssh_cmd("systemctl enable kdump")

        # 检查状态
        ret, out, err = self.ssh_cmd("systemctl status kdump --no-pager -l")
        logger.info(f"[Step 1] kdump 状态:\n{out}")

        if ret != 0 and "active" not in out.lower():
            logger.error("[Step 1] kdump 服务启动失败")
            return False

        return True

    def step2_open_sol(self):
        """打开 SOL 串口会话"""
        logger.info("=" * 60)
        logger.info("[Step 2] 打开 SOL 串口")
        logger.info("=" * 60)

        # 先测试 BMC 连通性
        ret, out, err = self.ipmitool(["power", "status"])
        if ret != 0:
            logger.error(f"[Step 2] BMC 不可达: {err}")
            return False
        logger.info(f"[Step 2] BMC 连通正常，电源状态: {out.strip()}")

        # 启动 SOL
        self.start_sol_session()
        time.sleep(2)

        # 检查 sol 进程是否存活
        if self.sol_process and self.sol_process.poll() is None:
            logger.info("[Step 2] SOL 会话已建立")
            return True
        else:
            logger.error("[Step 2] SOL 会话启动失败")
            return False

    def step3_configure_sysctl(self):
        """配置 /etc/sysctl.conf NMI panic 参数"""
        logger.info("=" * 60)
        logger.info("[Step 3] 配置 sysctl NMI panic")
        logger.info("=" * 60)

        # 备份
        self.ssh_cmd("cp /etc/sysctl.conf /etc/sysctl.conf.kdump_bak 2>/dev/null || true")

        # 删除旧配置（如果存在）再追加
        self.ssh_cmd(
            "sed -i '/kernel.unknown_nmi_panic/d; /kernel.panic_on_io_nmi/d' /etc/sysctl.conf"
        )

        self.ssh_cmd(
            'echo "kernel.unknown_nmi_panic = 1" >> /etc/sysctl.conf'
        )
        self.ssh_cmd(
            'echo "kernel.panic_on_io_nmi = 1" >> /etc/sysctl.conf'
        )

        # 应用
        ret, out, err = self.ssh_cmd("sysctl -p")
        logger.info(f"[Step 3] sysctl -p 结果: {out}")

        # 验证
        ret, out, err = self.ssh_cmd("sysctl kernel.unknown_nmi_panic kernel.panic_on_io_nmi")
        logger.info(f"[Step 3] 验证: {out}")
        return ret == 0

    def step4_configure_crashkernel(self):
        """配置 crashkernel=512M 并重启"""
        logger.info("=" * 60)
        logger.info(f"[Step 4] 配置 crashkernel={self.crashkernel_size}")
        logger.info("=" * 60)

        # 检测 grub 类型
        ret, out, _ = self.ssh_cmd("cat /etc/os-release 2>/dev/null | head -5")
        logger.info(f"[Step 4] OS 信息:\n{out}")

        # 判断是 grub2 还是 grub1
        ret1, _, _ = self.ssh_cmd("which grub2-mkconfig 2>/dev/null")
        ret2, _, _ = self.ssh_cmd("which grub-mkconfig 2>/dev/null")

        grub_mkconfig = "grub2-mkconfig" if ret1 == 0 else "grub-mkconfig"

        # CentOS/RHEL 风格
        ret_cfg, cfg_path, _ = self.ssh_cmd(
            "if [ -f /etc/default/grub ]; then echo GRUB_CFG_FOUND; fi"
        )
        if "GRUB_CFG_FOUND" in cfg_path:
            # 先清理 /etc/default/grub 中所有 crashkernel= 参数
            self.ssh_cmd(
                "sed -i 's/crashkernel=[^ \"]*//g' /etc/default/grub"
            )
            # 重新添加 crashkernel 参数
            self.ssh_cmd(
                'sed -i \'s/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="crashkernel=' + self.crashkernel_size + ' /\''
                ' /etc/default/grub'
            )

            # 阿里的 Alibaba Cloud Linux 可能从 base-setup 注入额外参数
            self.ssh_cmd(
                "if [ -f /usr/share/alinux-base-setup/cmdline ]; then "
                "sed -i 's/crashkernel=[^ ]*//g' /usr/share/alinux-base-setup/cmdline; "
                "fi; true"
            )

            # 显示当前配置
            ret, out, _ = self.ssh_cmd("grep GRUB_CMDLINE_LINUX /etc/default/grub")
            logger.info(f"[Step 4] GRUB 配置: {out}")

            # 重新生成 grub 配置
            self.ssh_cmd(f"{grub_mkconfig} -o /boot/grub2/grub.cfg 2>/dev/null || "
                         f"{grub_mkconfig} -o /boot/grub/grub.cfg 2>/dev/null || true")
        else:
            logger.error("[Step 4] 未找到 /etc/default/grub")
            return False

        # 重启
        logger.info("[Step 4] 配置完成，准备重启 SUT ...")
        self._append_sol_log("=== 开始重启 ===")

        # 异步执行重启，不等待结果（因为连接会断）
        try:
            subprocess.Popen(
                ["sshpass", "-p", self.ssh_pass, "ssh",
                 "-o", "StrictHostKeyChecking=no",
                 "-o", "UserKnownHostsFile=/dev/null",
                 "-p", str(self.ssh_port),
                 f"{self.ssh_user}@{self.sut_ip}",
                 "reboot"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception as e:
            logger.warning(f"[Step 4] 远程重启命令发送可能失败 (预期行为): {e}")

        time.sleep(3)

        # 等待 SSH 恢复
        if not self.wait_ssh_ready(timeout=self.reboot_timeout):
            logger.error("[Step 4] 重启后 SUT 未能在超时内恢复")
            return False

        # 验证 crashkernel 参数
        ret, out, _ = self.ssh_cmd("cat /proc/cmdline")
        logger.info(f"[Step 4] /proc/cmdline: {out}")
        if f"crashkernel={self.crashkernel_size}" in out:
            logger.info(f"[Step 4] crashkernel={self.crashkernel_size} 配置验证通过 [PASS]")
            return True
        else:
            logger.error(f"[Step 4] crashkernel 配置验证失败！当前 cmdline: {out}")
            return False

    def step5_trigger_crash(self, method="inband"):
        """触发系统 crash"""
        logger.info("=" * 60)
        logger.info(f"[Step 5] 触发 crash (方法: {method})")
        logger.info("=" * 60)

        # 确保 SOL 日志中有标记
        self._append_sol_log(f"=== 触发 crash (方法: {method}) ===")

        if method == "inband":
            # 带内触发：echo c > /proc/sysrq-trigger
            # 需要先启用 sysrq
            self.ssh_cmd("echo 1 > /proc/sys/kernel/sysrq")

            logger.info("[Step 5] 执行带内 crash 触发: echo c > /proc/sysrq-trigger")
            # 异步执行，因为命令发出后系统立即 crash
            try:
                subprocess.Popen(
                    ["sshpass", "-p", self.ssh_pass, "ssh",
                     "-o", "StrictHostKeyChecking=no",
                     "-o", "UserKnownHostsFile=/dev/null",
                     "-p", str(self.ssh_port),
                     f"{self.ssh_user}@{self.sut_ip}",
                     "echo 1 > /proc/sys/kernel/sysrq && echo c > /proc/sysrq-trigger"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except Exception as e:
                logger.info(f"[Step 5] 带内触发命令发送 (预期断开): {e}")

        elif method == "outband":
            # 带外触发：ipmitool chassis power diag
            logger.info("[Step 5] 执行带外 crash 触发: chassis power diag")

            # 先确保 SOL 活跃
            if self.sol_process is None or self.sol_process.poll() is not None:
                self.start_sol_session()
                time.sleep(2)

            ret, out, err = self.ipmitool(["chassis", "power", "diag"], timeout=30)
            logger.info(f"[Step 5] ipmitool chassis power diag: ret={ret}, out={out}, err={err}")
            if ret != 0:
                logger.error(f"[Step 5] 带外触发失败: {err}")
                return False

        # 等待 crash 过程（SOL 中观察）
        logger.info(f"[Step 5] 等待 crash dump 过程（{self.crash_timeout}s 超时）...")
        time.sleep(30)  # 给 crash kernel 一些启动时间

        # 监测 SOL 日志
        start = time.time()
        last_size = 0
        reboot_detected = False
        while time.time() - start < self.crash_timeout:
            time.sleep(5)

            try:
                current_size = os.path.getsize(self.sol_log_file)
            except OSError:
                current_size = 0

            if current_size > last_size:
                last_size = current_size
                # 检查是否有重启特征
                try:
                    with open(self.sol_log_file, "r", encoding="utf-8", errors="replace") as f:
                        tail = f.readlines()[-5:] if current_size > 0 else []
                    for line in tail:
                        line_lower = line.lower()
                        if any(kw in line_lower for kw in ["restarting", "reboot:", "booting", "linux version"]):
                            logger.info(f"[Step 5] SOL 检测到重启信号: {line.strip()}")
                            reboot_detected = True
                            break
                except Exception:
                    pass

            if reboot_detected:
                break

        return reboot_detected

    def cleanup(self):
        self.stop_sol_session()
        if self.ipmi_pass_file and os.path.exists(self.ipmi_pass_file):
            try:
                os.remove(self.ipmi_pass_file)
            except OSError:
                pass
            self.ipmi_pass_file = None

    def step6_verify_vmcore(self):
        """检查 /var/crash 目录下是否有 vmcore 文件"""
        logger.info("=" * 60)
        logger.info("[Step 6] 验证 vmcore 文件")
        logger.info("=" * 60)

        # 检查多个可能的目录
        check_paths = [
            "/var/crash",
            "/var/crash/127.0.0.1*",
            "/var/crash/*/vmcore",
            "/var/crash/*/vmcore.flat",
        ]

        for path in check_paths:
            ret, out, _ = self.ssh_cmd(f"ls -lh {path} 2>/dev/null | grep -i vmcore")
            if out and "vmcore" in out.lower():
                logger.info(f"[Step 6] 找到 vmcore 相关文件:\n{out}")
                self.test_result["vmcore_found"] = True
                break

        if not self.test_result["vmcore_found"]:
            ret, out, _ = self.ssh_cmd("find /var/crash -type f -name '*vmcore*' 2>/dev/null")
            if out:
                logger.info(f"[Step 6] 通过 find 找到 vmcore:\n{out}")
                self.test_result["vmcore_found"] = True

        if self.test_result["vmcore_found"]:
            logger.info("[Step 6] [PASS] vmcore 文件验证通过！")
        else:
            logger.error("[Step 6] [FAIL] 未找到 vmcore 文件")

        return self.test_result["vmcore_found"]

    # ==================== 主流程 ====================

    def run_full_test(self, crash_methods=None):
        """运行完整测试流程"""
        if crash_methods is None:
            crash_methods = ["inband", "outband"]

        logger.info("=" * 70)
        logger.info("     Kdump 自动化测试开始")
        logger.info(f"     SUT: {self.sut_ip}  BMC: {self.bmc_ip}")
        logger.info(f"     Crash 方法: {crash_methods}")
        logger.info("=" * 70)

        all_passed = True

        try:
            # Step 1: 确保 kdump 服务
            if not self.step1_ensure_kdump_service():
                logger.error("Step 1 失败，终止测试")
                return False

            # Step 2: 打开 SOL
            if not self.step2_open_sol():
                logger.error("Step 2 失败，终止测试")
                return False

            # Step 3: 配置 sysctl
            if not self.step3_configure_sysctl():
                logger.warning("Step 3 可能未完全成功，继续...")

            # Step 4: 配置 crashkernel + 重启
            if not self.step4_configure_crashkernel():
                logger.error("Step 4 失败，终止测试")
                return False

            # 重启后需要重新打开 SOL
            self.stop_sol_session()
            time.sleep(5)
            self.start_sol_session()
            time.sleep(3)

            for method in crash_methods:
                logger.info(f"\n{'#' * 60}")
                logger.info(f"# 开始 {method.upper()} crash 测试")
                logger.info(f"{'#' * 60}")

                # Step 5: 触发 crash
                if not self.step5_trigger_crash(method=method):
                    all_passed = False
                    continue

                # 分析 SOL 日志
                kdump_ok = self.analyze_sol_log()
                self.test_result["crash_kernel_booted"] = kdump_ok

                # 等待系统重启恢复
                logger.info("[MAIN] 等待 SUT crash 后重启恢复...")
                if not self.wait_ssh_ready(timeout=self.reboot_timeout):
                    logger.error(f"[MAIN] {method} crash 后 SUT 未能恢复")
                    all_passed = False
                    continue

                # 重启后重新打开 SOL（为下一次测试准备）
                self.stop_sol_session()
                time.sleep(3)
                self.start_sol_session()
                time.sleep(3)

                # Step 6: 验证 vmcore
                if not self.step6_verify_vmcore():
                    logger.error(f"[MAIN] {method} 测试: vmcore 验证失败 [FAIL]")
                    all_passed = False
                else:
                    logger.info(f"[MAIN] {method} 测试: 通过 [PASS]")

                # 清理 vmcore（可选，为下一次测试腾空间）
                # self.ssh_cmd("rm -rf /var/crash/*")

        finally:
            self.cleanup()

        logger.info("\n" + "=" * 70)
        logger.info(f"     测试结果: {'[PASS] 全部通过' if all_passed else '[FAIL] 存在失败'}")
        logger.info(f"     SOL 日志: {self.sol_log_file}")
        logger.info("=" * 70)

        return all_passed


def main():
    parser = argparse.ArgumentParser(description="Kdump 自动化测试工具")
    parser.add_argument("--sut-ip", required=True, help="被测机器 IP")
    parser.add_argument("--bmc-ip", required=True, help="BMC 管理 IP")
    parser.add_argument("--bmc-user", required=True, help="BMC 用户名")
    parser.add_argument("--bmc-pass", required=True, help="BMC 密码")
    parser.add_argument("--ssh-user", required=True, help="SSH 用户名")
    parser.add_argument("--ssh-pass", required=True, help="SSH 密码")
    parser.add_argument("--ssh-port", type=int, default=22, help="SSH 端口")
    parser.add_argument("--crashkernel-size", default="512M", help="crashkernel 参数值，默认 512M")
    parser.add_argument("--crash-method", default="both",
                        choices=["inband", "outband", "both"],
                        help="Crash 触发方式")
    parser.add_argument("--reboot-timeout", type=int, default=1200,
                        help="重启等待超时（秒），默认 1200（1TB 内存建议 >= 900）")
    parser.add_argument("--crash-timeout", type=int, default=1800,
                        help="Crash 过程等待超时（秒），默认 1800（1TB 内存建议 >= 1800）")
    parser.add_argument("--sol-log", default="./sol_output.log",
                        help="SOL 日志文件路径")
    parser.add_argument("--skip-config", action="store_true",
                        help="跳过环境配置（Step 1-4），仅执行 crash 和验证")

    args = parser.parse_args()

    for ip_value, label in ((args.sut_ip, "sut-ip"), (args.bmc_ip, "bmc-ip")):
        try:
            ipaddress.ip_address(ip_value)
        except ValueError:
            logger.error(f"无效的 {label}: {ip_value}")
            sys.exit(1)

    # 检查依赖
    for dep in ["sshpass", "ipmitool"]:
        if shutil.which(dep) is None:
            logger.error(f"缺少依赖: {dep}，请先安装 (yum install {dep} / apt-get install {dep})")
            sys.exit(1)

    methods = ["inband", "outband"] if args.crash_method == "both" else [args.crash_method]

    tester = KdumpAutoTest(
        sut_ip=args.sut_ip,
        bmc_ip=args.bmc_ip,
        bmc_user=args.bmc_user,
        bmc_pass=args.bmc_pass,
        ssh_user=args.ssh_user,
        ssh_pass=args.ssh_pass,
        ssh_port=args.ssh_port,
        sol_log_file=args.sol_log,
        reboot_timeout=args.reboot_timeout,
        crash_timeout=args.crash_timeout,
        crashkernel_size=args.crashkernel_size,
    )

    if args.skip_config:
        all_passed = True
        logger.info("[SKIP] 跳过环境配置步骤")
        try:
            tester.start_sol_session()
            time.sleep(3)
            for method in methods:
                if not tester.step5_trigger_crash(method=method):
                    all_passed = False
                    continue
                all_passed = tester.analyze_sol_log() and all_passed
                all_passed = tester.wait_ssh_ready() and all_passed
                all_passed = tester.step6_verify_vmcore() and all_passed
        finally:
            tester.cleanup()
        sys.exit(0 if all_passed else 1)
    else:
        success = tester.run_full_test(crash_methods=methods)
        sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
