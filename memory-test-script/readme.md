# 内存测试脚本使用说明

归档时间：2026-08-10
作者：Prz1y

---

## 目录结构

```
/
├── Memtester_Stress_Test_Linux_HE.sh   # memtester 恒定压测脚本（12h 默认）
├── Stressapptest_Stress_Test_Linux.sh  # stressapptest 压测脚本（1.5h 默认）
├── stream_30runs.sh                    # STREAM 30 次循环测试包装脚本
├── hygon-stream/                       # STREAM 工具本体（海光官方 run.sh + 编译产物）
│   ├── run.sh                          # 海光 STREAM 入口（自动识别平台/编译器/缓存）
│   ├── opencc/  gcc/  lib/             # 编译产物与依赖库
│   └── stream_30runs.sh                # 配套的 30 次循环脚本
├── eccmem_12h_test.sh                  # eccmem 12h 循环压测脚本（用例 3/4）
├── test_memscan.py                     # memscan 阶段验证脚本（绕过 memtester 直接调 mem_scan）
├── common-all-all-server-hw-eccmem/    # eccmem 工具本体（深信服提供，含源码+编译产物）
│   ├── run.py                          # eccmem 入口（memtester 阶段 + memscan 阶段）
│   ├── Makefile                        # make install 一键安装（编译 kkmmap.ko + insmod + pip）
│   ├── readme.md                       # 工具官方文档
│   ├── kkmmap/  memscan/  libcommon/   # 内核模块源码 / Python 扫描实现 / 公共库
│   ├── modules/                        # 编译产物（kkmmap.ko；memmap 缺失见注意事项）
│   └── eccmem.conf                     # 配置（threshold=2, scan_time=1）
└── 使用说明.md                         # 本文档
```

---

## 一、memtester 压力测试（Memtester_Stress_Test_Linux_HE.sh）

### 用途
内存恒定稳压压测，默认 12 小时。每物理核起 1 个 memtester 进程，CPU/内存占用率 90% 以上，全程采样取证，结束自动判定 PASS/FAIL 并保存原始日志。

### 用法
```bash
# 基本用法：X = 小时数
./Memtester_Stress_Test_Linux_HE.sh 12          # 12 小时压测
./Memtester_Stress_Test_Linux_HE.sh 0 5         # 5 分钟冒烟（自动切 5s 采样）

# 可选环境变量（均有默认值）
RESULT_DIR=/root/memtester_result ./Memtester_Stress_Test_Linux_HE.sh 12   # 指定结果目录
SAMPLE_INTERVAL=300 ./Memtester_Stress_Test_Linux_HE.sh 12                  # 采样间隔(秒)，默认120
CLEAR_SEL=0 ./Memtester_Stress_Test_Linux_HE.sh 12                          # 0=不清BMC SEL(默认1清空)
IPMITOOL="ipmitool -I lanplus -H <BMC_IP> -U <user> -P <pass>" ./Memtester_Stress_Test_Linux_HE.sh 12  # 指定 BMC 连接
```

### 前置条件
- 系统已安装 memtester（麒麟：`yum install -y memtester`，实测装 4.3.0；新版本 4.6.0 需从 pyropus.ca 下载源码放入同目录，脚本自动 make）
- root 权限（需要清日志）
- 内存充足：脚本会自动检查可用内存 ≥ 进程数×每进程分配量，不足直接退出并提示

### 测试前脚本自动做的事（不可逆，请注意）
| 操作 | 说明 |
|---|---|
| 清空 dmesg | 清空前内容先保存到结果目录 logs_before/ |
| 截断 /var/log/messages 等 | 原文件先备份到 logs_before/ |
| 清空 journald | `journalctl --flush --rotate --vacuum-time=1s`，**历史日志全部删除** |
| 清空 BMC SEL | `ipmitool sel clear`，**不可逆**（默认开启，用 CLEAR_SEL=0 关闭） |

### 结果文件（结果目录 memtester_result_<时间戳>/）
```
summary_report.txt        7 项验收自动判定 PASS/FAIL + 占用率统计
usage.log                全程 CPU%/内存%/进程数/RSS 采样（每 120s）
top_snapshots.log         全程 top -b 快照
memtester_p01~pNN.log     每进程 memtester 原始输出
proc_rc.txt               每进程退出码（124=跑满时长）
logs_before/              测试前原始日志备份（清空前）
logs_after/               测试后原始日志（dmesg/messages/journal/SEL 全量）
analysis/error_matches.log 错误模式扫描结果
test_environment.log      环境信息（版本/核数/内存/参数）
```

### 验收条款对应
| 用例验收项 | 判定方式 |
|---|---|
| 脚本执行成功 | 自动：proc_rc.txt 全为 124 且无异常退出 |
| CPU/内存占用率 ≥90% | 自动：usage.log 稳态采样 min/avg 与阈值比较 |
| 进程数 = 核心数 | 自动：procs 采样与 nproc 比较 |
| 日志无 error/fail/告警 | 自动：dmesg/messages/journal/SEL 扫描（仅硬件相关模式，避免宽泛误报） |
| 无明显卡顿 | 人工观察（summary 标注 MANUAL） |
| 查看 BIOS 日志 | 人工：BMC Web 界面查看 POST 日志（脚本不覆盖） |

### 实测结果（参考）
64 核/14GB，SMT ON，12 小时：CPU min=99% avg=100%，MEM min=97% avg=98%，进程数 64/64，全 PASS。

---

## 二、STREAM 带宽测试（stream_30runs.sh + hygon-stream/）

### 用途
循环运行海光 STREAM（run.sh）N 次（默认 30），记录每次原始输出，汇总各轮 Copy/Scale/Add/Triad 带宽并计算平均值。

### 用法
```bash
# 需要 hygon-stream 目录（含 run.sh 和编译产物），在服务器上执行：
./stream_30runs.sh                      # 默认 30 次，调用 /root/hygon-stream/run.sh
./stream_30runs.sh /path/to/run.sh /path/to/outdir   # 自定义脚本和输出目录
N=50 ./stream_30runs.sh                 # 用环境变量改次数
```

### 结果文件（输出目录 stream_result_<时间戳>/）
```
raw/run_01.log ~ run_30.log   每次运行完整原始输出
summary.txt                   30 行汇总表 + 平均值，头部记录 SMT 状态
```

### SMT（超线程）说明
- run.sh 启动时会检测 SMT 并警告建议关闭。**建议 BIOS 关闭 SMT 后测试**（SMT OFF 实测带宽略高 0.5~0.9%）
- summary.txt 自动记录 `smt: threads_per_core=x nproc=y`，可溯源测试时 SMT 状态
- 实测对比（30 次平均，MB/s）：
  | 指标 | SMT ON | SMT OFF |
  |---|---|---|
  | Copy | 31472 | 31620 |
  | Scale | 31610 | 31613 |
  | Add | 32822 | 33099 |
  | Triad | 32717 | 32995 |

---

## 三、stressapptest 压力测试（Stressapptest_Stress_Test_Linux.sh）

### 用途
单进程多线程内存压测（`-i` invert 线程 + `-C` CPU 压力线程 + `-W` 压力拷贝），CPU/内存利用率接近 100%，默认测试 94% 内存容量，全程采样取证，结束自动判定 PASS/FAIL 并保存原始日志。

### 安装（源码编译）
麒麟源无 stressapptest 包，需源码编译：
```bash
# 依赖
yum install -y libaio-devel
# 上传 stressapptest-1.0.11.tar.gz 到服务器后
tar xzf stressapptest-1.0.11.tar.gz && cd stressapptest-1.0.11
./configure && make && make install      # 安装到 /usr/local/bin/stressapptest
```

### 用法
```bash
# 基本用法：<HOURS> [MINUTES]，小时支持小数
./Stressapptest_Stress_Test_Linux.sh 1 30     # 1.5 小时（验收默认）
./Stressapptest_Stress_Test_Linux.sh 0 1      # 1 分钟冒烟（自动切 5s 采样）

# 可选环境变量（均有默认值）
MEM_PCT=80 ./Stressapptest_Stress_Test_Linux.sh 1 30        # 测试内存百分比，默认 94
SAMPLE_INTERVAL=300 ./Stressapptest_Stress_Test_Linux.sh 1 30  # 采样间隔(秒)，默认 60
RESULT_DIR=/root/sat_result ./Stressapptest_Stress_Test_Linux.sh 1 30  # 指定结果目录
CLEAR_SEL=0 ./Stressapptest_Stress_Test_Linux.sh 1 30       # 0=不清BMC SEL
IPMITOOL="ipmitool -I lanplus -H <BMC_IP> -U <user> -P <pass>" ./Stressapptest_Stress_Test_Linux.sh 1 30  # 指定 BMC
SAT_BIN=/path/to/stressapptest ./Stressapptest_Stress_Test_Linux.sh 1 30   # 自定义二进制
```

### 测试前脚本自动做的事（不可逆，与 memtester 相同）
清空 dmesg、截断 /var/log/messages 等（先备份到 logs_before/）、清空 journald（历史日志全部删除）、清空 BMC SEL（默认开，CLEAR_SEL=0 关闭）。执行前确认该机器没有需要保留的历史日志。

### 结果文件（结果目录 stressapptest_result_<时间戳>/）
```
summary_report.txt           6 项验收自动判定 PASS/FAIL + 占用率统计
stressapptest.log            stressapptest 自身完整输出
stressapptest_stdout.log     标准输出备份
usage.log                    全程 CPU%/内存%/used/RSS 采样
top_snapshots.log            全程 top -b 快照
logs_before/                 测试前原始日志备份
logs_after/                  测试后原始日志（dmesg/messages/journal/SEL 全量）
analysis/error_matches.log   错误模式扫描结果
test_environment.log         环境信息（版本/核数/内存/参数）
```

### 验收条款对应
| 用例验收项 | 判定方式 |
|---|---|
| 工具正常解压安装无报错 | 自动：版本识别（SAT revision）+ 启动 rc |
| CPU、内存利用率近 100% | 自动：usage.log 稳态采样 min/avg 与阈值（默认 90%）比较 |
| 测试结束内存释放 | 自动：测试中峰值 used vs 测试后 used（回落 <70% 判 PASS） |
| 日志无 error/fail/告警 | 自动：dmesg/messages/journal/SEL + stressapptest 自身输出扫描 |
| 系统正常无宕机卡死 | 自动：退出码 rc=0；人工观察（summary 标注 MANUAL） |

### 实测结果（参考）
64 核/14GB，94% 内存，60s 冒烟：CPU min=94% avg=99%，MEM min=99% avg=99%，内存峰值 14186MB → 测试后 714MB（释放），全 PASS。

---

## 四、eccmem 循环压测（eccmem_12h_test.sh + common-all-all-server-hw-eccmem/）

### 工具简介
eccmem 是深信服提供的 ECC 内存扫描工具（Author: liyl11），运行分两个阶段：
1. **memtester 阶段**：多进程 memtester 并行压测（工具自带 memtester 4.3.0 二进制）
2. **memscan 阶段**：通过 kkmmap 内核模块直接 mmap 物理内存逐页读取，触发 ECC 检错。**该阶段由 Python 原生实现**（`scan_read_write_choose()`），不调用外部二进制，只要 `/dev/kkmmap` 设备存在即可运行

测试用例（3/4）：
- 用例 3：测试 12 小时，查看 dmesg、messages 和 BMC 日志
- 用例 4：脚本循环执行，12 小时后执行 `killall -9 python3` 关闭脚本

### 安装（按 readme.md，已验证）
```bash
# 前置：kernel-devel 必须与当前内核版本一致（麒麟：yum install -y kernel-devel-<版本>）
uname -r   # 查看内核版本，如 4.19.90-89.11.v2401.ky10

# 一键安装（编译 kkmmap.ko + insmod 加载 + pip 装依赖）
cd <eccmem工具部署目录>/common-all-all-server-hw-eccmem
make install

# 验证
lsmod | grep kkmmap        # 应显示 kkmmap
ls -la /dev/kkmmap         # 设备节点应存在（major 236）
python3 -c "import psutil, oslo_concurrency"   # pip 依赖
```
网络注意：默认 pip 走清华源（pypi.tuna.tsinghua.edu.cn）；内网环境可改用
`pip3 install -r requirements.txt -i http://<内网pypi源IP>:8900/root/pypi --trusted-host <内网pypi源IP>`

### 用法
```bash
# 12h 正式测试（tmux 后台）
cd /root/eccmem_test
IPMITOOL="ipmitool -I lanplus -H <BMC_IP> -U <user> -P <pass>" ./eccmem_12h_test.sh

# 可选环境变量（均有默认值）
MINUTES=720 ./eccmem_12h_test.sh                 # 测试时长(分钟)，默认 720=12h
P_NUM=32 ./eccmem_12h_test.sh                    # run.py 进程数，默认 32=核数
CHECK_INTERVAL=600 ./eccmem_12h_test.sh          # 监控采样间隔(秒)，默认 600
IPMITOOL="ipmitool -I lanplus -H <BMC_IP> -U <user> -P <pass>" ./eccmem_12h_test.sh  # 指定 BMC
```

### 测试前脚本自动做的事（不可逆，请注意）
| 操作 | 说明 |
|---|---|
| 清空 dmesg | 清空前内容先保存到结果目录 logs_before/ |
| 记录 /var/log/messages 行号基线 | 测后只分析基线之后的测试窗口内容（不截断原文件） |
| 保存 BMC SEL 基线 | 测后 diff 对比新增事件（不清空 SEL） |

与 memtester/stressapptest 脚本不同：**本脚本不截断 messages、不清空 journald、不清空 BMC SEL**，只做基线对比，相对温和。

### 结果文件（结果目录 eccmem_result_<时间戳>/）
```
summary_report.txt        7 项验收自动判定 PASS/FAIL
usage.log                 全程 CPU%/内存%/memtester 进程数/python 进程数采样（每 600s）
test.log                  脚本自身运行日志（含监控采样输出）
runpy_stdout.log          run.py 完整输出（memtester 启动 + memscan 循环记录）
runpy_key_events.txt      run.py 关键事件（start run memtester/memscan、UE、poison）
python3_before.txt        测试前系统 python3 进程清单（killall 影响面记录）
logs_before/              测前基线（dmesg 原文、BMC SEL）
logs_after/               测后日志（dmesg、messages 测试窗口、journal、BMC SEL）
messages_baseline_line.txt messages 基线行号
```

### 验收条款对应
| 用例验收项 | 判定方式 |
|---|---|
| 1. 文件上传成功 | 自动：run.py + memtester 存在 |
| 2. readme 安装成功 | 自动：kkmmap 模块加载 + /dev/kkmmap 设备 + pip 依赖 |
| 3a. 正常运行 12h | 自动：memtester 启动 + 重启次数 ≤1 |
| 3b. dmesg 无报错 | 自动：HW_ERR_PAT 硬件错误模式扫描（mce/ECC/EDAC/panic 等） |
| 3c. messages 无报错 | 自动：同上，只扫测试窗口（基线行号之后） |
| 3d. BMC 无报错 | 自动：SEL 测前测后 diff，无新增事件 |
| 4. 脚本可正常关闭 | 自动：killall -9 python3 后无 run.py 残留 |

### 循环执行说明
run.py 的 `--always` 参数默认 True（parser.py 中 default=True，注意与 readme 声称的"默认 False"不一致），行为是扫描进程结束后自动重启，天然循环。脚本另做 run.py 存活监控，异常退出自动重启。实测 12h 内：memtester 30 轮 + memscan 29 轮循环，每轮约 25 分钟。

### 实测结果（参考）
测试服务器（麒麟 KY10），32 核/14GB，P_NUM=32，12h（08-08 21:53 → 08-09 09:55）：
- 7 项验收全 PASS
- CPU 80~97%、32 memtester 进程稳定，usage.log 73 行采样覆盖全程
- memscan 29 轮全部 `not find UE`（未发现不可纠正错误）
- dmesg 仅 3 条 `perf: interrupt took too long`（内核采样率自动下调，非硬件错误）
- messages 测试窗口无硬件错误；BMC SEL 无新增（1→1）

### 已知缺陷与注意（重要）
1. **`modules/memmap` 二进制缺失**（工具交付缺陷）：git 仓库只有 kkmmap/memmap.c 源码，从未包含编译好的 memmap 二进制；作者 9 份运行日志也全部停在 memtester 阶段。**但经实测确认不影响默认使用**——memscan read 扫描是 Python 原生 mmap 实现，memmap 二进制仅在 WRITE_TEST=True 的写测试场景才被调用（默认 WRITE_TEST=False）。详细证据链见 eccmem_作者日志/eccmem缺memmap证据链.md
2. **`killall -9 python3` 会误杀系统进程**：脚本按用例字面要求执行 killall -9 python3，会连带杀掉系统 pcp 监控代理（pmdanfsclient.python）。实测 12h 后 pmcd 服务自动恢复（systemctl is-active pmcd = active）；若未自动恢复执行 `systemctl restart pmcd`
3. **remain 取模 bug（无害噪音）**：memtester_malloc.py 中 `remain = mem_free % p_num` 取模当余数，每次多起一个 2B~127B 的 memtester 进程必然报 `bytes < pagesize 4096` ERROR（作者日志同样存在），不影响主流程
4. **`--always` 无法用命令行关闭**：argparse `type=bool` 的坑导致 `--always False` 会被解析成 True（bool("False")==True），如需限时运行只能用 `--runtime=N` 或由测试脚本控制 killall
5. **内存占用高**：run.py 按可用内存 x0.8 分配，P_NUM 进程并行，14GB 机器测试期间勿跑其他负载

---

## 五、部署流程（到测试服务器）

```bash
# 1. 上传脚本（规避 scp 中文路径编码，用 cat 通道）
wsl bash -c 'SSHPASS="<服务器密码>" sshpass -e ssh root@<IP> "cat > /root/memtester/Memtester_Stress_Test_Linux_HE.sh"' < Memtester_Stress_Test_Linux_HE.sh

# 2. 语法校验
ssh root@<IP> 'bash -n /root/memtester/Memtester_Stress_Test_Linux_HE.sh && echo OK'

# 3. 先冒烟（60 秒）再正式
ssh root@<IP> 'cd /root/memtester && ./Memtester_Stress_Test_Linux_HE.sh 0 1'

# 4. 正式 12h（tmux 后台，防止 ssh 断链）
ssh root@<IP> 'tmux new -s mem12h "cd /root/memtester && ./Memtester_Stress_Test_Linux_HE.sh 12"'
# 查看进度：tmux attach -t mem12h（退出用 Ctrl+B 再按 D，不中断测试）
```

上传 STREAM 工具同理（整个 hygon-stream 目录），注意 run.sh 内使用相对路径，**必须在 hygon-stream 目录内运行**（stream_30runs.sh 已自动 cd）。

eccmem 部署（12h 压测用例）：
```bash
# 1. 上传测试脚本
wsl bash -c 'SSHPASS="<服务器密码>" sshpass -e ssh root@<IP> "cat > /root/eccmem_test/eccmem_12h_test.sh"' < eccmem_12h_test.sh

# 2. 语法校验
ssh root@<IP> 'bash -n /root/eccmem_test/eccmem_12h_test.sh && echo OK'

# 3. 先短冒烟（3~6 分钟，验证全链路）
ssh root@<IP> 'cd /root/eccmem_test && MINUTES=3 P_NUM=4 CHECK_INTERVAL=60 ./eccmem_12h_test.sh'

# 4. 正式 12h（tmux 后台）
ssh root@<IP> 'tmux new -s eccmem12h "cd /root/eccmem_test && IPMITOOL=\"ipmitool -I lanplus -H <BMC_IP> -U <user> -P <pass>\" ./eccmem_12h_test.sh"'
# 查看进度：tmux attach -t eccmem12h（退出 Ctrl+B D）
```

---

## 六、注意事项

1. **脚本会清空系统日志和 BMC SEL**——执行前确认该机器没有需要保留的历史日志（memtester 和 stressapptest 脚本行为相同）
2. **内存占用接近上限**：小内存机器（如 14GB）压测会占满内存，测试期间不要跑其他负载，否则占用率不达标会误判 FAIL
3. **memtester 版本**：4.3.0 无 `-V` 选项（脚本已兼容，自动从运行输出识别版本）；`-B`（overcommit 允许）仅 4.4+ 支持
4. **SMT 状态影响 STREAM 结果**：对比测试必须在相同 SMT 状态下进行
5. **stressapptest 编译依赖**：libaio-devel（yum 安装）；yum 源本身没有 stressapptest 包，走源码编译
6. **stressapptest 收尾阶段**：测试结束前约 2 秒做结果校验，CPU 会短暂下降（内存未释放），属正常现象，脚本统计已排除该窗口
7. **eccmem 日志处理策略不同**：eccmem_12h_test.sh 不截断 messages/不清空 journald/不清空 BMC SEL，只做基线对比（dmesg 会清空，清空前备份到 logs_before/）
8. **eccmem killall 影响面**：`killall -9 python3` 会杀所有 python3 进程（含系统 pcp 代理），测试后确认 `systemctl is-active pmcd`，非 active 则 `systemctl restart pmcd`

---
