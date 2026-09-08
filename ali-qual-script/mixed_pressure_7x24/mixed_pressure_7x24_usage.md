# mixed_pressure_7x24.sh 使用说明

整机混合压力稳定性测试脚本（CPU / 内存 / 磁盘 并行加压，默认 7x24H = 168 小时）。
按测试用例要求实现：全部逻辑 CPU 加压、内存加压至可用内存 90%、fio 3.13 文件系统级 50%读/50%写带宽压测（ext4）、CPU 频率 / 内存带宽 / 温度功耗 / 系统日志全程监控。不含网卡与 GPU 加压功能。

> 警告：必须在配置文件中显式指定 `SYSTEM_DISKS`。脚本可能对 `FIO_DISKS` 测试盘执行 wipefs / 重新分区 / mkfs.ext4，测试盘上的原有数据允许被清除；同时会临时关闭 swap 并产生持续高压。仅允许在 RD/实验室机器上运行。

---

## 1. 环境要求

| 依赖 | 是否必需 | 说明 |
|---|---|---|
| root 权限 | 必需 | 启动/停止均需 root |
| bash | 必需 | Linux bash 环境 |
| bc / dmidecode | 必需 | 计算 / 内存信息采集 |
| fio 3.13 | 必需 | 版本强校验（`FIO_VERSION_STRICT=true` 时必须精确 3.13） |
| stress-ng | 必需 | CPU 与内存压测（需支持 `--vm`；0.17.08 实测通过，`MEM_ACCESS_MODE` 已按 0.17 有效方法名映射） |
| ipmitool | 可选 | 缺失时跳过 BMC 温度/功耗监控 |
| perf | 可选 | 缺失时跳过内存带宽监控（以内存负载持续运行为证据） |
| memtester | 可选 | 仅 `MEM_TOOL=memtester` 或 `auto` 时使用 |

---

## 2. 部署与快速开始

脚本与配置文件放在同一目录；日志输出到脚本同目录下的 `mixed_pressure_7x24_logs/`。

```bash
# 1. 上传（Windows/WSL 经 ssh stdin 管道，规避 scp 中文路径问题；上传前先去掉 CRLF）
tr -d '\r' < mixed_pressure_7x24.sh | ssh root@<host> "cat > /root/mixed_pressure_7x24.sh"
tr -d '\r' < mixed_pressure.conf     | ssh root@<host> "cat > /root/mixed_pressure.conf"

# 2. 语法检查
ssh root@<host> "bash -n /root/mixed_pressure_7x24.sh && chmod +x /root/mixed_pressure_7x24.sh"

# 3. 建议先跑短时冒烟（见配置范例 B），确认无误后再正式 7x24

# 4. 正式运行放 tmux，避免 ssh 断开影响
ssh root@<host>
tmux new-session -s pressure
/root/mixed_pressure_7x24.sh start
# Ctrl+B D 脱离 tmux；之后随时可:
#   tmux attach -t pressure        # 回到压测前台
#   /root/mixed_pressure_7x24.sh status   # 另开终端查看状态
```

启动前必须在 `mixed_pressure.conf` 设置 `SYSTEM_DISKS`，并核对控制台输出的 `系统盘保护列表（来自 SYSTEM_DISKS 配置）: ...` 一行。

---

## 3. 命令

```
用法: mixed_pressure_7x24.sh {start|stop|status}
```

| 命令 | 说明 |
|---|---|
| `start` | 启动测试。前台运行（监控进程在后台），到时自动 stop 并生成报告；Ctrl+C / kill 会触发 trap 自动收尾。若测试已在运行会拒绝重复启动 |
| `stop` | 停止测试：杀压测与监控进程、采集收尾日志（dmesg/journalctl/传感器复位值）、恢复 swap、卸载 fio 挂载点、生成性能报告 |
| `status` | 查看运行状态：各压测进程存活数、已运行时长（目标时长读自上次启动记录）、内存快照、日志清单 |

运行中任一压测进程提前退出或发生掉盘时，由进程守护记录到 `crash_*.log`。

---

## 4. 启动流程（start 内部步骤）

1. 处理系统日志（默认 backup：压测前快照，不清空）
2. 记录测试准备信息；dmidecode 内存信息；内存基线；BMC 传感器基线
3. 记录并关闭 swap（结束时按原列表恢复）
4. 按 `SYSTEM_DISKS` 生成系统盘保护列表
5. 查找数据盘：优先用配置 `FIO_DISKS`；否则自动发现。找到则挂载到 `FIO_MOUNT_BASE` 下并启动 ext4 文件系统级 fio（4 线程，占盘 90% 空闲空间，iodepth 64）；**显式指定的盘准备失败会直接中止，不会回退**；未指定且无可用数据盘时回退为系统盘 `/var/tmp` 文件级压测（预留 5GB 安全空间）
6. 等 fio 稳态（默认 45s）→ 按"总核数 × CPU_TARGET_PCT% − fio 占用"计算 stress-ng CPU 核数；按"可用内存 × MEM_TARGET_PCT%"计算内存加压总量，`--vm-bytes` 直接传该总量（stress-ng ≥ 0.17 内部在 4 个 worker 间均分），`--vm-keep` 保持驻留；访问模式由 `MEM_ACCESS_MODE` 映射为 0.17 有效方法名（机制与风险见 5.1）
7. 启动 stress-ng CPU / 内存压测（两者的 `--timeout` 与主计时同长，自启动起算）→ 记录压力开始时间
8. 启动监控：OS 内存（默认 10s）、BMC 传感器（默认 600s）、CPU 频率（10s）、内存带宽（perf，10s）、dmesg 快照（默认 1800s，不清空内核 ring buffer）
9. 启动进程守护；达到完整压力时长后自动 stop

---

## 5. 配置文件

- 路径：脚本同目录下 `mixed_pressure.conf`（不存在则全部用默认值）
- 格式：bash 语法，启动时 `source` 加载，可加注释
- 注意：`status`/`stop` 是独立调用，不加载配置文件；目标时长等信息以启动时落盘的 `.resource_usage.log` 为准

### 参数总表

| 参数 | 默认值 | 说明 |
|---|---|---|
| `TOTAL_DURATION_SEC` | `604800`（168H） | 测试持续秒数 |
| `CPU_TARGET_PCT` | `95` | CPU 压测目标百分比（总核数口径） |
| `MEM_TARGET_PCT` | `90` | 内存压测目标（按 fio 稳态后的可用内存百分比，下限钳位 1024MB）。注意：`MEM_ACCESS_MODE=all` 时 >88% 会确定性超卖死机（见 5.1 节） |
| `MEM_TOOL` | `stress-ng` | 内存压测工具：`stress-ng` / `memtester` / `auto`（auto=优先 memtester） |
| `MEM_ACCESS_MODE` | `all` | 内存访问模式：`all` / `rand` / `seq` / `flip` / `rowhammer` / `walk` / `write`。映射 stress-ng 0.17 方法名：rand→rand-set、seq→incdec、walk→walk-0d、write→write64。**推荐 `write`**；`all` 有 ×9/8 超卖风险（见 5.1 节） |
| `SYSTEM_DISKS` | 空（必填） | 显式指定所有系统盘，空格分隔。未配置、设备不存在或不是块设备时直接中止；不再自动探测 |
| `ALLOW_EXISTING_FS` | `false` | 只有显式设为 `true` 才直接复用已有 ext4 文件系统；否则进入测试盘准备流程 |
| `FIO_DISKS` | 空（自动发现） | 指定测试盘，空格分隔，如 `"/dev/nvme1n1 /dev/nvme2n1"`。**指定后准备失败即中止，不回退**；测试盘数据允许被清除 |
| `FIO_MOUNT_BASE` | `/mnt/fio_pressure` | fio 挂载基础路径（第 2 块盘起追加 `_2`、`_3`…） |
| `FIO_FILE_SIZE_MB` | `10240` | 文件级（回退模式）fio 单线程文件大小 MB |
| `FIO_FILE_NUMJOBS` | `1` | 文件级 fio 并发数 |
| `FIO_REQUIRED_VERSION` | `3.13` | fio 要求版本 |
| `FIO_VERSION_STRICT` | `true` | 是否强制校验 fio 版本 |
| `CPU_THROTTLE_PCT` | `90` | 疑似降频判定阈值%（任一核低于 max 频率该比例即标记） |
| `MEM_BW_MON` | `auto` | 内存带宽监控：`auto` / `off`（auto 依赖 perf uncore 计数器） |
| `CSV_MON_INTERVAL` | `10` | OS 内存 / CPU 频率 / 内存带宽监控间隔秒 |
| `IPMI_MON_INTERVAL` | `600` | ipmitool BMC 监控间隔秒 |
| `DMESG_SNAP_INTERVAL` | `1800` | dmesg 中途快照间隔秒，不清空内核 ring buffer |
| `FIO_STEADY_WAIT` | `45` | fio 稳态等待秒数 |
| `LOG_CLEANUP_MODE` | `backup` | 启动时旧日志处理：`backup`（移入 `backup_<时间戳>/`）/ `delete` / `keep` |
| `SYSTEM_LOG_ACTION` | `backup` | 系统日志策略：`backup`（压测前快照）/ `clear`（清空 dmesg 与 /var/log/messages）/ `none` |
| `ALLOW_AUTO_PREPARE` | `false` | `true` 时对空白盘自动 wipefs/分区/mkfs 不再交互确认（危险，仅无人值守且盘位已核对时用） |

### 5.1 内存压测机制与安全边界（重要）

- **目标量计算**：`fio 稳态后的 MemAvailable × MEM_TARGET_PCT%`，下限 1024MB。基于可用内存而非 MemTotal，不同内存容量机器自动适配。
- **stress-ng ≥ 0.17 语义**：`--vm-bytes` 传的是总量，内部在 4 个 worker 间均分；配合 `--vm-keep` 常驻总量 = 目标量。
- **`MEM_ACCESS_MODE=all` 的 ×9/8 超卖**：默认 all 模式轮询全部 vm 方法，部分方法会额外申请"每 worker 配额/8"的临时内存，总驻留可达目标量 ×9/8。`90% × 9/8 = 101.25% > 100%`，且脚本已关闭 swap → `all` + `MEM_TARGET_PCT>88` 会爆内存硬锁死机（实测复现，且 OOM 来不及触发、事后无内核日志）。
  - 规避：`MEM_ACCESS_MODE=write`（write64，实测无超卖，7x24 长稳验证）；或坚持 all 模式时 `MEM_TARGET_PCT≤80`。
- **memtester 路径**：脚本自动拆 4 个实例均分目标量，无上述超卖问题。

---

## 6. 配置文件范例

### 范例 A — 正式 7x24H（本次 10.8.149.204 实际使用配置）

`mixed_pressure.conf`：

```bash
# ===== mixed_pressure_7x24 正式压测配置 =====
TOTAL_DURATION_SEC=604800              # 168h
SYSTEM_DISKS="/dev/sda"                # 必须显式指定所有系统盘（204 系统盘为 sda，LVM）
# FIO_DISKS 不指定 = 自动发现全部数据盘（204 = 12 块 NVMe）
ALLOW_EXISTING_FS=true                 # 数据盘已有 ext4 分区时直接复用，不重新格式化
ALLOW_AUTO_PREPARE=true                # 空白数据盘自动 wipefs+分区+mkfs.ext4（无人值守）
FIO_VERSION_STRICT=false               # 主机 fio 3.42 != 用例要求 3.13，仅告警不退出
MEM_TOOL="stress-ng"                   # 按用例要求使用 stress-ng
MEM_TARGET_PCT=90                      # 可用内存的 90%
MEM_ACCESS_MODE="write"                # write64，无 ×9/8 超卖；用 "all" 时须 MEM_TARGET_PCT<=80（见 5.1）
CPU_TARGET_PCT=95
```

### 范例 B — 短时冒烟（部署验证用）

```bash
# 10 分钟冒烟：验证盘识别/系统盘保护/无 OOM/报告生成
TOTAL_DURATION_SEC=600
SYSTEM_DISKS="/dev/nvme0n1"
FIO_DISKS="/dev/nvme1n1"
FIO_STEADY_WAIT=20
```

冒烟检查点：
1. 控制台 `系统盘保护列表` 包含真实系统盘
2. `stress_vm.log` 无 OOM / mmap 失败
3. status 显示目标 0H（短时长）、压测进程全部运行
4. stop 后报告正常生成

### 范例 C — memtester 内存压测

```bash
MEM_TOOL="memtester"
# memtester 固定 4 个实例均分目标内存（脚本自动处理）
```

### 范例 D — 无人值守自动准备空白盘（谨慎）

```bash
FIO_DISKS="/dev/sdb /dev/sdc"
ALLOW_AUTO_PREPARE=true   # 空白盘自动 wipefs+分区+mkfs.ext4，不再询问 yes
```

不设 `ALLOW_AUTO_PREPARE=true` 时，对需要格式化的空白盘会在终端交互式要求输入 `yes` 确认（从 `/dev/tty` 读，重定向不失效）；非交互环境（如 cron）无 /dev/tty 则直接跳过该盘。

---

## 7. 磁盘安全机制

| 机制 | 行为 |
|---|---|
| 系统盘保护 | 从 `SYSTEM_DISKS` 配置读取系统盘并解析为整盘（含全部分区），拒绝分区/格式化/压测；未配置或设备无效时直接中止 |
| FIO_DISKS 显式指定 | 指定盘不存在 / 是系统盘 / 准备失败 → **中止测试**，绝不回退到系统盘文件级模式 |
| 自动发现模式 | 只接受非系统盘；带 LVM/RAID/LUKS/swap 签名的盘跳过；已有 ext4 分区直接复用不格式化；空白盘需交互确认（或 ALLOW_AUTO_PREPARE） |
| 文件级回退 | 仅当未指定 FIO_DISKS 且找不到任何数据盘时，对系统盘 `/var/tmp` 做文件级压测，预留 5GB，空间不足直接退出 |
| fio 全部走文件系统 | `--directory` + `--direct=1`，不写裸块设备，不做 reset/低级操作，不会主动导致掉盘 |

---

## 8. 日志与报告

日志目录：`<脚本目录>/mixed_pressure_7x24_logs/`（再次 start 时旧日志移入 `backup_<时间戳>/`）

| 文件 | 内容 |
|---|---|
| `console_output.log` | start/stop 全程控制台输出 |
| `pressure_performance_report.txt` | 最终性能报告（判定主要依据） |
| `fio_pressure_<盘名>.log` / `fio_pressure_file.log` | fio 输出（每盘一个） |
| `stress_cpu.log` / `stress_vm.log` | stress-ng 输出（末尾有 exit code） |
| `perf_monitor.csv` / `cpu_freq_monitor.csv` / `mem_bw_monitor.csv` | OS 内存 / CPU 频率 / 内存带宽时序数据 |
| `ipmi_monitor.log` / `sensor_before.log` / `sensor_after.log` | BMC 传感器全程 + 前后快照 |
| `mem_baseline.log` / `mem_reset.log` / `dmidecode_memory.log` | 内存基线 / 复位 / SPD 信息 |
| `dmesg_before.log` / `dmesg_snapshot_*.log` / `dmesg_pressure.log` | dmesg 压测前快照 / 每 30min 中途快照 / 收尾全量 |
| `var_log_messages*.log` / `journalctl_pressure.log` | 系统日志（压测窗口内） |
| `crash_stress_cpu.log` / `crash_stress_vm.log` / `crash_fio.log` / `crash_disk.log` | 守护检测到的异常终止 / 掉盘记录（出现即异常） |

### 8.1 stop 状态标志（`.cleanup_failed` / `.stopping`）

日志目录下的隐藏状态文件，控制"停止是否彻底完成、是否允许下一轮覆盖现场"：

- **写入时机**：stop 过程中任一清理步骤失败即写入 `.cleanup_failed` 并保留 `.stopping`。失败来源包括：压测进程 TERM/KILL 后仍存活、fio 挂载点卸载失败或挂载源/UUID 与记录不一致、swap 恢复失败、dmesg/journalctl 状态 FAIL、报告生成失败、分区回滚失败。文件内容为失败时的 unix 时间戳或 `partition_rollback_failed:<盘名>`，具体原因看 `console_output.log`。
- **关键行为：不会被后续 stop 自动清除**。只要该标志存在，之后即使完全成功的 stop 也会在末尾报 `清理未完全成功，保留运行标志并写入 ... .cleanup_failed`（并提示 `保留既有清理失败原因: <旧内容>`），且下一轮 `start` 被拒绝（`上一次停止未完成清理，拒绝启动`）。这是防止未确认的失败现场被覆盖的设计，**不代表本次 stop 又出了新故障**。
- **人工解锁**（确认现场已干净后）：
  1. 核验：无 stress-ng / fio 残留进程、无 `fio_pressure` 挂载点（`grep fio_pressure /proc/mounts`）、swap 与 fstab 一致（`swapon --show`）
  2. 删除或改名备份日志目录下的 `.cleanup_failed` 与 `.stopping`
  3. 重新 `start`
- **数据盘中途掉线的特例**：NVMe 链路故障后设备重枚举（如 nvme1n1 → nvme1n2），stop 对"挂载源一致但 UUID 已不可读"的挂载点放行卸载并仅告警；若卸载仍失败，可 `umount -l <挂载点>` 后重新执行 stop。

---

## 9. 常见问题

| 现象 | 处理 |
|---|---|
| fio 版本报错退出 | 机器 fio 非 3.13。确认用例允许后可设 `FIO_VERSION_STRICT=false`，否则安装 fio 3.13 |
| 报"指定测试盘准备失败"后中止 | 按设计行为（显式指定不回退）：检查盘符、是否系统盘、wipefs/mkfs 报错原因（错误信息在 console_output.log） |
| 想重新开始一轮 | 先 `stop`，旧日志自动移入 `backup_<时间戳>/`，再 `start` |
| 中途机器重启过 | 测试进程已丢失：`status` 会显示未运行；`stop` 清理残留并出报告，然后重新 start |
| 不想动系统盘但也没有数据盘 | 会回退 /var/tmp 文件级压测；不想压系统盘就直接指定 `FIO_DISKS`（找不到即中止） |
| swap 被动了 | 脚本启动时关 swap、结束按启动前记录恢复；异常中断后可手动 `swapon -a` |
| 高内存负载一段时间后整机硬锁死机、事后无 OOM 日志 | 典型为 `MEM_ACCESS_MODE=all` ×9/8 超卖（见 5.1）：改 `MEM_ACCESS_MODE=write`，或 all 模式下 `MEM_TARGET_PCT≤80` |
| stop 报 `清理未完全成功，保留运行标志`，或 start 被拒 `上一次停止未完成清理` | 上次 stop 失败留下的 `.cleanup_failed` 标志未清（脚本不会自动清除，后续成功的 stop 也会报这条）。按 8.1 核验现场干净后，手动删除 `.cleanup_failed` 与 `.stopping` 再 start |
