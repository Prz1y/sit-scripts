# nvme_storage_perf — 阿里 SSD 基础性能认证套件

[English](README.md) | 简体中文（当前）

版本 3.0（2026-09-07）。阿里测试用例"受测 OS 下 SSD 基础性能"端到端自动化，面向 NVMe 直连服务器。

## 套件做什么

```
Phase 0  预检        依赖（缺失时从发行版远端源安装 openpyxl/sysstat）、
                     按型号自动识别目标 NVMe 盘、留证：fio 版本、
                     NUMA 节点、dmidecode、PCIe 链路状态、每盘 FW、
                     盘清单 CSV、盘->BDF->NUMA 节点映射
Phase 1  前检查      每盘 SMART 标准1 → OS 日志全套清除
                     （dmesg + messages/secure + journalctl 截断 +
                     重启 rsyslog/journald）→ SEL 备份 + 清除
Phase 2  多盘联合    按用例顺序 SR -> RR -> SW -> RW，每场景：
                        稳态擦写，所有盘同时
                          SR/SW：1M 顺序写，loops=2 × 3 轮 = 6 遍
                          RR/RW：4K 随机写，每盘 numjobs=4，QD64，8 小时
                        正式轮 jobs=1 与 jobs=4 各 10 分钟
                     fio 每盘一个 job 段 -> JSON 内每盘独立 bw/iops/lat
                     iostat 每盘时序：正式轮 1s，擦写期 10s
                     温度采样：ipmitool elist + 每盘 nvme smart-log，
                     间隔 30/60 秒
Phase 3  单盘        首块识别到的盘，同样的分场景擦写结构
Phase 4  后检查      SMART 标准2、OS/SEL 日志收集
Phase 5  报告        perf_report.py parse -> csv/；build -> report/*.xlsx
                     （openpyxl 从零复刻客户 8 sheet 模板，另加一页
                     数据说明）
```

时长（12 盘 P7A40，mode=all）：约 40 小时。跳过擦写（`SKIP_WIPES=yes`）约 3 小时。

## 文件清单

| 文件 | 职责 |
|---|---|
| `nvme_storage_perf.sh` | 主控：各 Phase、fio 引擎、采样器、断点续跑 |
| `perf_report.py`       | `parse`（纯标准库）-> csv/；`build`（openpyxl）-> xlsx |
| `deploy_194.sh`        | 部署驱动示例：上传 + 远端语法检查 + tmux 启动 |

## 环境要求

- RHEL7/8/9 系 guest，root，内核 nvme 驱动
- fio（用例要求 3.13，其他版本仅告警留证不拦截）、nvme-cli、
  smartmontools、pciutils、sysstat、python3；建议 ipmitool
- openpyxl 预检自动安装；装不上则 parse/CSV 照常产出，`build`
  可移到任何有 openpyxl 的机器执行

## 用法

服务器上以 root 直接运行：

```bash
bash nvme_storage_perf.sh -m all          # 多盘+单盘一次跑完
bash nvme_storage_perf.sh -m all -b /path/NVME_ALI_QUAL_<ts>     # 断点续跑
bash nvme_storage_perf.sh -m report -b /path/NVME_ALI_QUAL_<ts>  # 仅重建报告
SKIP_WIPES=yes bash nvme_storage_perf.sh -m all           # 只跑正式轮
```

每步落 `<BASE_DIR>/state/<step>.done`；`-b` 重跑自动跳过已完成步骤。
多盘轮跑完后用 `-m single -b <多盘目录>` 可把单盘套件并入同一份报告。

`deploy_194.sh` 是上传管线的示例：去 CRLF -> stdin 上传 -> 远端
`bash -n` / `py_compile` -> tmux 启动。主机与密码从环境变量
（`SSH_HOST`、`SSHPASS`）读取，不写入文件。

### 环境变量覆盖

| 变量 | 默认 | 含义 |
|---|---|---|
| `MODE` | `all` | 同 `-m` |
| `TARGET_DEVS` | 自动 | 空格分隔的块设备名 |
| `SINGLE_DEV` | 第一块盘 | 单盘套件使用的块设备 |
| `DEV_MODEL_FILTER` | `P7A40` | lsblk MODEL 自动识别过滤串 |
| `RUNTIME` | `600` | 正式轮时长（秒） |
| `WIPE_SEQ_RUNTIME` | 未设 | 设了则顺序擦写改为定时制（流程测试用） |
| `WIPE_SEQ_ROUNDS` / `WIPE_SEQ_LOOPS` | `3` / `2` | 顺序擦写遍数 |
| `WIPE_RAND_RUNTIME` | `28800` | 4K 随机擦写时长（秒） |
| `SETTLE_SECS` | `10` | 轮次间停顿 |
| `TEMP_INTERVAL_FORMAL` / `TEMP_INTERVAL_WIPE` | `30` / `60` | 温度采样间隔（秒） |

## 输出目录

```
NVME_ALI_QUAL_<ts>/
  run.log                 全程日志
  state/                  断点标记
  inventory/              主机/CPU/PCIe/nvme list、dev_inventory.csv、
                          numa_map.txt（盘->BDF->NUMA）、fio 版本
  smart_logs/             前后 SMART 标准日志
  sel_logs/               pre_clear.elist、post.elist
  logs/                   OS 清除标记、dmesg/journal/messages 后采
  perf_data/              *.fio job 文件 + 每轮/每次擦写的 fio JSON
  monitor/                <tag>_iostat.log
  temp/                   <tag>_elist.log、<tag>_nvme_temp.log
  csv/                    formal_results、consistency_<scen>、crosscheck、
                          uniformity、temp_*（可随时重新生成）
  report/                 SSD性能测试结果_<ts>.xlsx
```

## 报告与判定规则

- 工作表复刻客户模板：单盘表、多盘每盘表、每盘平均值表、4 张一致性
  表、温度表，另加"数据说明"页记录数据链路。
- SPEC 列留空。填入后占比与 PASS/FAIL 单元格是活公式——
  PASS = 占比 >= 85%。
- 一致性：jobs=4 轮的 iostat 1s 序列，去头 110s 去尾 50s
  （615 采样 -> 455 点），在带 = 均值 95%~105%。每盘判定阈值
  4KRR >= 80%、4KRW >= 70%、1M SR/SW >= 90%；另查低于均值 50% 的点。
  采样不足裁剪时（短跑）判定行写 `N/A(未裁剪)`。iostat 首份输出
  （开机以来均值）永远丢弃。
- `csv/crosscheck.csv`：每轮 fio 汇总 vs iostat 窗口均值，偏差 >5% 打标。
  `csv/uniformity.csv`：盘间 95-105% 均匀性。

## 报告格式规格

- 一致性表布局：r1 数据来源注释、r2 场景标题、r3 盘头、r4 起数据点、
  统计行紧随数据；表格置于 sheet 左上，图表锚定在表格右侧。
- 全部实测数（带宽、IOPS(K)、延迟、占比、平均值、一致性数据点/平均/
  95%/105% 行）使用 2 位小数会计格式 `0.00_);[Red]\(0.00\)`；
  占比显示 `0.85`。
- "在带比例"行保持百分比 `0.0%`。温度表：每盘 `0`、全盘平均 `0.0`。
- 一致性图 13 × 25 单元格，温度图 13 × 30 单元格。

## 注意事项

- 测试窗口内禁止重启/断电。
- fio JSON 的坑（代码已处理，勿按版本重猜）：`bw` 各版本都是 KiB/s
  （B/s 在 `bw_bytes`），2.x 的 `lat` 单位是 us——按字段名解析。
- fio 3.13 在 Alibaba Cloud Linux 3 / glibc >= 2.30 上编译需要 gettid
  守卫补丁，gcc10 需要额外 -fcommon。
