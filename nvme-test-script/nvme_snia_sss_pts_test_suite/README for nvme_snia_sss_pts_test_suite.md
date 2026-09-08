# nvme_cloud_qual_suite_chs - 使用说明书

## 概述

面向云场景的 **NVMe 存储性能自动化测试套件**。覆盖顺序读写、随机读写、混合读写全 I/O 矩阵，并采集测试前后 SMART 日志、PCIe AER 异常检测及 IPMI SEL 事件。测试结果自动汇总为结构化 Excel 报告。

遵循 **SNIA SSS PTS** 性能测试方法学，包含完整的预条件（preconditioning）流程。

## 环境要求

| 依赖 | 版本/说明 |
|------|----------|
| FIO | >= 3.41（需要 tausworthe64 随机数生成器） |
| 操作系统 | CentOS/RHEL/CTyunOS 7+, Ubuntu 18.04+ |
| 权限 | Root |
| Python | 3.6+ |
| pip 包 | pandas, openpyxl |

## 系统依赖安装

### CentOS / RHEL / CTyunOS
```bash
sudo yum install -y fio nvme-cli pciutils python3 python3-pip numactl ipmitool libaio-devel
pip3 install pandas openpyxl
```

### Ubuntu / Debian
```bash
sudo apt-get install -y fio nvme-cli pciutils python3 python3-pip numactl ipmitool libaio-dev
pip3 install pandas openpyxl
```

### 编译 FIO 3.41（如果仓库版本过低）
```bash
wget https://github.com/axboe/fio/archive/refs/tags/fio-3.41.tar.gz
tar xzf fio-3.41.tar.gz && cd fio-fio-3.41/
./configure && make -j$(nproc) && make install
```

## 快速开始

```bash
# 1. 编辑核心配置区（根据需要修改目标设备和测试参数）
vim nvme_cloud_qual_suite_chs.sh

# 2. 以 root 运行
sudo bash nvme_cloud_qual_suite_chs.sh
```

## 核心配置参数

### 测试模式

```bash
TEST_MODE="single"   # "single" = 单盘全矩阵 | "multi" = 多盘代表性组合
```

| 模式 | 说明 | 测试点数 |
|------|------|---------|
| single | 9块大小 × 5并发 × 9队列深度 = 405点/阶段 | ~1700+ |
| multi | 代表性组合，多盘并发 | ~100+ |

### 目标设备

```bash
# 单盘测试
TARGET_DEVS=("/dev/nvme0n1")

# 多盘并发测试
TARGET_DEVS=("/dev/nvme0n1" "/dev/nvme1n1" "/dev/nvme2n1")
```

### 时间参数

```bash
RUNTIME=300        # 顺序/随机每测试点运行时长（秒），建议 >= 300
MIX_RUNTIME=1200   # 混合读写每测试点运行时长（秒），建议 >= 1200
```
- **生产测试**：RUNTIME=300, MIX_RUNTIME=1200
- **快速验证**：RUNTIME=5, MIX_RUNTIME=10
- **脚本调试 (dry run)**：RUNTIME=1, MIX_RUNTIME=2

### 预条件 (Preconditioning)

```bash
DO_SEQ_PRECON="yes"     # 顺序写预调教：用 128k/QD128 顺序写填满100%容量
SEQ_PRE_LOOPS=2         # 预调教循环次数
DO_RAND_PRECON="yes"    # 随机写预调教：用 4k/QD128/4jobs 随机写覆盖全盘
RAND_PRE_LOOPS=1        # 预调教循环次数
```

预条件目的：将 SSD 内部映射表刷新到稳态，排除空盘性能虚高。

### 测试阶段开关

```bash
RUN_SEQ_READ="yes"      # 顺序读矩阵
RUN_SEQ_WRITE="yes"     # 顺序写矩阵
RUN_RAND_READ="yes"     # 随机读矩阵
RUN_RAND_WRITE="yes"    # 随机写矩阵
RUN_MIXED_RW="yes"      # 混合读写矩阵
```

设为 `"no"` 可跳过对应阶段。

### 块大小

```bash
TEST_BS_LIST="4k 8k 16k 32k 64k 128k 256k 512k 1m"
```

### 断点续测

```bash
RESUME_FROM="/path/to/NVME_TEST_20260401_120000"
```

设置为已有的测试工作目录路径，留空则新建目录从头开始。

> **注意**：断点续测会跳过格式化（format）和预条件（preconditioning）阶段。如果设备在中断期间被重新格式化或写入，续测结果可能不准确。

### NUMA 绑定

```bash
ENABLE_NUMA_BIND="yes"           # 启用 NUMA 绑定
NUMA_BIND_METHOD="numactl"       # 唯一支持的方式（通过 numactl 命令包装）
NUMA_FALLBACK_NODE="0"           # sysfs 读不到时的回退节点
```

多 NUMA 架构（如 2-socket 或 Hygon/AMD）下建议开启，避免跨节点内存访问带来性能抖动。

### 其他

```bash
SERVER_MODEL="Server"            # 服务器标识，用于报告文件名
MIX_NUMJOBS=4                    # 混合读写并发数
MIX_IODEPTH=64                   # 混合读写队列深度
```

## 测试流程

```
1. 环境检查
   - FIO 版本验证 (>= 3.41)
   - Python 依赖检查 (pandas, openpyxl)
   - 目标设备存在性检查
   - NUMA 拓扑检测
   - 数据安全确认（强制交互）

2. 设备格式化 (nvme format)
   - 仅 flash/SSD 设备执行
   - 需要 --force 确认

3. 测试前置采集
   - SMART 日志 (`nvme smart-log`)
   - PCIe AER 计数
   - IPMI SEL 事件

4. SEQ Preconditioning (顺序写预条件)
   - 128k / QD128 / 1job / SEQ_WRITE
   - 填满 100% 容量 × SEQ_PRE_LOOPS 次

5. SEQ_Read 顺序读矩阵
   - 9 个块大小 × 5 个 numjobs × 9 个 iodepth

6. SEQ_Write 顺序写矩阵
   - 9 个块大小 × 5 个 numjobs × 9 个 iodepth

7. RAND Preconditioning (随机写预条件)
   - 4k / QD128 / 4jobs / RAND_WRITE
   - 覆盖全盘 × RAND_PRE_LOOPS 次

8. RAND_Read 随机读矩阵
   - 9 个块大小 × 5 个 numjobs × 9 个 iodepth

9. RAND_Write 随机写矩阵
   - 9 个块大小 × 5 个 numjobs × 9 个 iodepth

10. MixedRW 混合读写矩阵
    - 4k/8k/16k/32k × 9 种读写比

11. Excel 报告生成
    - 各阶段独立报告 (IOPS + clat 延迟矩阵)
    - 全阶段聚合报告 FULL_report

12. 测试后置采集
    - SMART 日志对比
    - PCIe AER 差异检测
    - dmesg 错误检查
```

## 输出产物

工作目录结构（`NVME_TEST_YYYYMMDD_HHMMSS/`）：

```
NVME_TEST_20260514_134101/
├── raw_data/                              # FIO JSON 原始输出
│   ├── SEQ_Read_4k_nj1_qd1_nvme0n1.json
│   ├── SEQ_Write_128k_nj4_qd32_nvme0n1.json
│   └── ...
├── logs/                                  # 系统日志
│   ├── sysinfo.log                        # 系统环境信息
│   ├── dmesg_before.log                   # 测试前 dmesg
│   └── dmesg_after.log                    # 测试后 dmesg
├── smart_log.txt                          # SMART 前后对比
├── Server_SeqRead_single_report.xlsx      # 顺序读 IOPS/延迟矩阵
├── Server_SeqWrite_single_report.xlsx     # 顺序写 IOPS/延迟矩阵
├── Server_RandRead_single_report.xlsx     # 随机读 IOPS/延迟矩阵
├── Server_RandWrite_single_report.xlsx    # 随机写 IOPS/延迟矩阵
├── Server_MixedRW_single_report.xlsx      # 混合读写 IOPS/延迟矩阵
└── Server_FULL_single_report.xlsx         # 全阶段聚合报告
```

### Excel 报告内容

每份报告包含 4 个 sheet：
- **IOPS Matrix**：块大小 × 参数组合 的 IOPS 矩阵
- **IOPS Table**：详细 IOPS 数据表
- **Latency Matrix (clat)**：完成延迟矩阵（ms）
- **Latency Table**：详细延迟数据表

## 后台运行

```bash
nohup bash nvme_cloud_qual_suite_chs.sh > test.log 2>&1 &
```

## 进程监控

```bash
# 检查测试进程
ps aux | grep -E 'nvme_cloud_qual|nvme_fio_engine' | grep -v grep

# 查看进度（Python 引擎日志）
tail -f NVME_TEST_*/logs/*.log

# 统计已完成测试点
ls NVME_TEST_*/raw_data/*.json | wc -l

# 检查 Excel 是否生成
ls NVME_TEST_*/*.xlsx
```

## 安全机制

1. **数据安全确认**：测试前强制交互式确认，需手动输入 `yes`。只有通过 `--force` 参数或管道输入 `echo yes |` 才能跳过。
2. **格式化保护**：仅对 NVMe SSD（非 HDD）执行 `nvme format`。
3. **信号处理**：`Ctrl+C` 或 `kill` 时自动清理所有 FIO 子进程。
4. **设备锁定**：格式化阶段会检查设备是否已被其他 FIO 使用。

## 故障排查

| 问题 | 原因 | 解决 |
|------|------|------|
| `fio: engine sprandom not loadable` | FIO 编译时未启用 sprandom 引擎 | 脚本已自动降级到 tausworthe64 |
| `missing pandas or openpyxl` | Python 依赖未安装 | `pip3 install pandas openpyxl` |
| `numa_cpu_nodes` not supported | FIO 编译时缺少 libnuma-dev | 脚本已自动切换为 numactl 方式 |
| `nvme format` 失败 | 设备有活跃挂载/fio 进程 | 卸载分区并杀掉 fio 进程 |
| Excel 报告缺失某个阶段 | 该阶段被跳过或数据为空 | 检查对应 `RUN_*` 开关和数据 |
| 测试中途中断 | 进程被杀或系统重启 | 设置 `RESUME_FROM` 断点续测 |

## 性能调优建议

1. **RUNTIME >= 300s**：确保 I/O 进入稳态后再采集数据
2. **启用 NUMA 绑定**：多 socket 系统避免跨 NUMA 访问
3. **关闭 CPU 变频**：`cpupower frequency-set -g performance`
4. **增大系统限制**：脚本已自动设置 `ulimit -n 65535`
5. **IRQ 亲和性**：手动绑定 NVMe IRQ 到本地 NUMA 核心
