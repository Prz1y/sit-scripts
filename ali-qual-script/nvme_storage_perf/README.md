# nvme_storage_perf — Ali SSD Basic Performance Qualification Suite

English | [简体中文](README.zh-CN.md)

Version 3.0 (2026-09-07). End-to-end automation of the Ali test case
"SSD basic performance under the OS under test" for NVMe direct-attach
servers.

## What it does

```
Phase 0  preflight    deps (installs openpyxl/sysstat from the distro
                      remote source if missing), auto-detects target
                      NVMe disks by model, evidence: fio version,
                      NUMA nodes, dmidecode, PCIe link states, per-disk
                      firmware, device inventory, disk->BDF->NUMA map
Phase 1  pre-check    SMART std-1 per disk -> OS log full clear
                      (dmesg + messages/secure + journald vacuum +
                      restart rsyslog/journald) -> SEL save + clear
Phase 2  multi-disk   per scenario in test-case order SR -> RR -> SW -> RW:
                        steady-state wipe, all disks simultaneously
                          SR/SW: 1M seq write, loops=2 x 3 rounds = 6 passes
                          RR/RW: 4K randwrite, numjobs=4/disk, QD64, 8 h
                        formal runs jobs=1 and jobs=4, 10 min each
                      one fio job section per disk -> per-disk bw/iops/lat
                      iostat per-disk series: 1 s formal, 10 s wipes
                      temperature: ipmitool elist + per-disk nvme
                      smart-log temperature, every 30/60 s
Phase 3  single-disk  first detected disk, same per-scenario wipe structure
Phase 4  post-check   SMART std-2, OS/SEL log collect
Phase 5  report       perf_report.py parse -> csv/, build -> report/*.xlsx
                      (workbook replicates the customer 8-sheet template
                      from scratch, plus a provenance sheet)
```

Wall time (12-disk P7A40, mode=all): about 40 h. Without the
preconditioning wipes (`SKIP_WIPES=yes`): about 3 h.

## Files

| File | Purpose |
|---|---|
| `nvme_storage_perf.sh` | orchestrator: phases, fio engine, samplers, checkpoints |
| `perf_report.py`      | `parse` (stdlib only) -> csv/; `build` (openpyxl) -> xlsx |
| `deploy_194.sh`       | example driver: upload + remote syntax check + tmux launch |

## Requirements

- RHEL7/8/9-like guest, root, kernel nvme driver bound
- fio (3.13 per test case — other versions warn + record, do not block),
  nvme-cli, smartmontools, pciutils, sysstat, python3; ipmitool recommended
- openpyxl auto-installed in preflight; if the source lacks it, parse/CSV
  still succeed and `build` can run anywhere openpyxl exists

## Usage

Run on the server as root:

```bash
bash nvme_storage_perf.sh -m all          # multi + single, one session
bash nvme_storage_perf.sh -m all -b /path/NVME_ALI_QUAL_<ts>   # resume
bash nvme_storage_perf.sh -m report -b /path/NVME_ALI_QUAL_<ts>  # rebuild report
SKIP_WIPES=yes bash nvme_storage_perf.sh -m all           # formal runs only
```

Every step writes `<BASE_DIR>/state/<step>.done`; a rerun with `-b`
skips completed steps. A later `-m single -b <multi-run-dir>` folds the
single-disk suite into the same report.

The `deploy_194.sh` driver is an example of the upload pipeline:
strip CRLF -> upload via stdin -> remote `bash -n` / `py_compile` ->
tmux launch. Host and password come from the environment
(`SSH_HOST`, `SSHPASS`), never from the file.

### Environment overrides

| Variable | Default | Meaning |
|---|---|---|
| `MODE` | `all` | same as `-m` |
| `TARGET_DEVS` | auto | space-separated block dev names |
| `SINGLE_DEV` | first disk | block dev used by the single-disk suite |
| `DEV_MODEL_FILTER` | `P7A40` | lsblk MODEL filter for auto-detection |
| `RUNTIME` | `600` | formal run seconds |
| `WIPE_SEQ_RUNTIME` | unset | set => time-based seq wipe (flow tests) |
| `WIPE_SEQ_ROUNDS` / `WIPE_SEQ_LOOPS` | `3` / `2` | seq wipe passes |
| `WIPE_RAND_RUNTIME` | `28800` | 4K rand wipe seconds |
| `SETTLE_SECS` | `10` | pause between runs |
| `TEMP_INTERVAL_FORMAL` / `TEMP_INTERVAL_WIPE` | `30` / `60` | temp sampling seconds |

## Output layout

```
NVME_ALI_QUAL_<ts>/
  run.log                 whole-run log
  state/                  checkpoint markers
  inventory/              host/cpu/pcie/nvme list, dev_inventory.csv,
                          numa_map.txt (disk->BDF->NUMA), fio version
  smart_logs/             pre/post standard SMART logs
  sel_logs/               pre_clear.elist, post.elist
  logs/                   OS clear marker, post dmesg/journal/messages
  perf_data/              *.fio job files + fio JSON per run/wipe
  monitor/                <tag>_iostat.log
  temp/                   <tag>_elist.log, <tag>_nvme_temp.log
  csv/                    formal_results, consistency_<scen>, crosscheck,
                          uniformity, temp_*  (regenerable)
  report/                 SSD性能测试结果_<ts>.xlsx
```

## Report / judgment rules

- Sheets replicate the customer template: single-disk table, multi-disk
  per-slot table, per-slot averages, four consistency sheets, temperature
  sheet, plus a provenance sheet documenting every data source.
- SPEC columns are left EMPTY. Fill them in Excel; ratio and PASS/FAIL
  cells are live formulas — PASS = ratio >= 85%.
- Consistency: iostat 1 s series of the jobs=4 run, drop first 110 s and
  last 50 s (615 samples -> 455 points), in-band = mean 95%..105%.
  Thresholds 4KRR >= 80%, 4KRW >= 70%, 1M SR/SW >= 90%; separate check
  for any point < 50% of mean. Short runs that cannot be trimmed report
  `N/A(未裁剪)`. iostat's first report (since-boot average) is always
  dropped.
- `csv/crosscheck.csv`: fio per-disk sum vs iostat window mean, flagged
  when deviation > 5%. `csv/uniformity.csv`: slot 95-105% uniformity.

## Report formatting specification

- Consistency sheet layout: r1 data-source note, r2 scenario title,
  r3 disk headers, r4+ data points, stat rows directly after the data;
  charts anchor to the RIGHT of each table.
- Measured numbers (bandwidth, IOPS(K), latency, ratios, averages,
  consistency points / mean / 95% / 105%) use 2-decimal accounting
  format `0.00_);[Red]\(0.00\)`; ratios display as `0.85`.
- In-band ratio row keeps percent format `0.0%`. Temperature sheet:
  per-disk `0`, all-disk average `0.0`.
- Consistency charts 13 x 25 cells, temperature chart 13 x 30 cells.

## Notes

- Never reboot or power-cycle during a run.
- fio JSON pitfalls (handled in code, do not re-guess): `bw` is KiB/s in
  all versions (B/s lives in `bw_bytes`), 2.x `lat` is us — parse by
  field name, not by version.
- fio 3.13 on Alibaba Cloud Linux 3 / glibc >= 2.30 needs a gettid guard
  and gcc10 needs -fcommon to build.
