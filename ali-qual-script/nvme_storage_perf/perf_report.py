#!/usr/bin/env python3
"""
perf_report.py - parse fio/iostat/temperature artifacts and build the Ali SSD
performance report xlsx.

Subcommands:
  parse -b BASE_DIR : read perf_data/ monitor/ temp/ inventory/ -> csv/
  build -b BASE_DIR : read csv/ + inventory/ -> report/<result xlsx>

parse is stdlib-only. build requires openpyxl.
The workbook replicates the customer template structure (8 sheets, merged
headers, ratio/PASS formulas, per-slot line charts) built from scratch, so no
template file is needed on the test host.
"""

import argparse
import csv
import glob
import json
import os
import re
import sys
import time
from collections import OrderedDict

# --------------------------------------------------------------------------
# constants
# --------------------------------------------------------------------------
SCEN_DEFS = OrderedDict([
    ('SR', dict(rw='read',      bs='1024k', metric='bw',   label='1M/SR，Bandwidth(MB/s)')),
    ('RR', dict(rw='randread',  bs='4k',    metric='iops', label='4k/RR，IOPS(K)')),
    ('SW', dict(rw='write',     bs='1024k', metric='bw',   label='1M/SW，Bandwidth(MB/s)')),
    ('RW', dict(rw='randwrite', bs='4k',    metric='iops', label='4k/RW，IOPS(K)')),
])
CONSIST_THRESH = {'SR': 0.90, 'SW': 0.90, 'RR': 0.80, 'RW': 0.70}
SPEC_PASS_RATIO = 0.85
HEAD_TRIM = 110   # drop first 110 s of the 1 s iostat series
TAIL_TRIM = 50    # drop last 50 s
CONSIST_SHEET = {'SR': '性能一致性测试1M顺序读',
                 'SW': '性能一致性测试1M顺序写',
                 'RR': '性能一致性测试4k随机读',
                 'RW': '性能一致性测试4k随机写'}
CONSIST_SHEET_ORDER = ['性能一致性测试1M顺序写', '性能一致性测试1M顺序读',
                       '性能一致性测试4k随机读', '性能一致性测试4k随机写']
FIO_RE = re.compile(r'formal_(multi|single)_(SR|RR|SW|RW)_jobs(\d+)\.json$')
TS_RE = re.compile(r'^\d{2}/\d{2}/\d{4}\s+\d{2}:\d{2}:\d{2}')


def natkey(s):
    return [int(t) if t.isdigit() else t for t in re.split(r'(\d+)', s)]


def read_text(path):
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            return fh.read()
    except OSError:
        return ''


# --------------------------------------------------------------------------
# parse: fio json
# --------------------------------------------------------------------------
def parse_fio_json(path, side):
    """Return OrderedDict dev -> (iops, bw_MBps, lat_us) for one fio run."""
    with open(path, 'r', encoding='utf-8', errors='replace') as fh:
        data = json.load(fh)
    out = OrderedDict()
    for job in data.get('jobs', []):
        dev = job.get('jobname', '?')
        blk = job.get(side, {}) or {}
        iops = float(blk.get('iops', 0) or 0)
        # fio json: bw is KiB/s in ALL versions; bw_bytes (B/s) exists in 3.x
        # (verified on 194: fio-3.13 SR bw=3812652 KiB/s, bw_bytes=3904156408)
        if 'bw_bytes' in blk:
            bw = float(blk.get('bw_bytes', 0) or 0)
        else:
            bw = float(blk.get('bw', 0) or 0) * 1024.0
        # latency: fio "lat" = slat+clat (what the report means by latency);
        # prefer lat_ns, fall back to clat_ns, then legacy 2.x lat (us)
        lat_ns = None
        for key in ('lat_ns', 'clat_ns'):
            v = (blk.get(key) or {}).get('mean')
            if v:
                lat_ns = float(v)
                break
        if lat_ns is None:
            lat_ns = float((blk.get('lat') or {}).get('mean', 0) or 0) * 1000.0
        out[dev] = (iops, bw / 1e6, lat_ns / 1000.0)
    return out


# --------------------------------------------------------------------------
# parse: iostat -xmt log
# --------------------------------------------------------------------------
def parse_iostat(path, devs):
    """Return list of per-interval samples: [{dev: {'r/s','w/s','mb'}}]."""
    devset = set(devs)
    samples, cur, colmap = [], {}, None
    for line in read_text(path).splitlines():
        stripped = line.strip()
        if stripped.startswith('Device'):
            if cur:
                samples.append(cur)
                cur = {}
            colmap = {tok: i for i, tok in enumerate(stripped.split())}
            continue
        parts = stripped.split()
        if not parts:
            if cur:
                samples.append(cur)
                cur = {}
            continue
        if parts[0] in devset and colmap is not None:
            try:
                r_s = float(parts[colmap['r/s']])
                w_s = float(parts[colmap['w/s']])
                rmb = 0.0
                for k in ('rmB/s', 'rMB/s', 'rkB/s'):
                    if k in colmap:
                        rmb = float(parts[colmap[k]])
                        if k == 'rkB/s':
                            rmb /= 1000.0
                        break
                wmb = 0.0
                for k in ('wmB/s', 'wMB/s', 'wkB/s'):
                    if k in colmap:
                        wmb = float(parts[colmap[k]])
                        if k == 'wkB/s':
                            wmb /= 1000.0
                        break
            except (KeyError, ValueError, IndexError):
                continue
            cur[parts[0]] = {'r/s': r_s, 'w/s': w_s, 'mb': rmb + wmb}
        # timestamp lines and avg-cpu lines fall through untouched
    if cur:
        samples.append(cur)
    return samples


def iostat_metric(sample_dev, metric):
    if metric == 'iops':
        return (sample_dev['r/s'] + sample_dev['w/s']) / 1000.0   # IOPS(K)
    return sample_dev['mb']                                       # MB/s


# --------------------------------------------------------------------------
# parse: temperature logs
# --------------------------------------------------------------------------
def parse_elist_logs(base):
    """Return list of (ts, sensor, id, status, entity, value_degC)."""
    rows = []
    ts = ''
    for path in sorted(glob.glob(os.path.join(base, 'temp', '*_elist.log'))):
        for line in read_text(path).splitlines():
            if line.startswith('#####'):
                ts = line.replace('#', '').strip()
                continue
            if 'degrees C' not in line or '|' not in line:
                continue
            fields = [f.strip() for f in line.split('|')]
            if len(fields) < 5:
                continue
            m = re.match(r'([-\d.]+)\s+degrees\s+C', fields[4])
            if not m:
                continue
            rows.append((ts, fields[0], fields[1], fields[2], fields[3],
                         float(m.group(1))))
    return rows


def parse_nvme_temp_logs(base):
    """Return list of (ts, dev, tempC) from temp/*_nvme_temp.log."""
    rows = []
    for path in sorted(glob.glob(os.path.join(base, 'temp', '*_nvme_temp.log'))):
        for line in read_text(path).splitlines():
            parts = line.split()
            # "<date> <time> <dev> <temp>"
            if len(parts) == 4 and parts[3].lstrip('-').isdigit():
                rows.append((parts[0] + ' ' + parts[1], parts[2], int(parts[3])))
    return rows


# --------------------------------------------------------------------------
# parse command
# --------------------------------------------------------------------------
def cmd_parse(base):
    perf_dir = os.path.join(base, 'perf_data')
    mon_dir = os.path.join(base, 'monitor')
    csv_dir = os.path.join(base, 'csv')
    os.makedirs(csv_dir, exist_ok=True)
    all_devs = set()

    # ---- formal_results.csv ------------------------------------------------
    results = {}          # (phase, scen, jobs) -> OrderedDict dev->(iops,bw,lat)
    for path in sorted(glob.glob(os.path.join(perf_dir, 'formal_*.json'))):
        m = FIO_RE.search(os.path.basename(path))
        if not m:
            continue
        phase, scen, jobs = m.group(1), m.group(2), int(m.group(3))
        side = 'read' if SCEN_DEFS[scen]['rw'].endswith('read') else 'write'
        try:
            results[(phase, scen, jobs)] = parse_fio_json(path, side)
        except (OSError, ValueError) as exc:
            print('WARN: cannot parse %s: %s' % (path, exc), file=sys.stderr)
    with open(os.path.join(csv_dir, 'formal_results.csv'), 'w', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['phase', 'scen', 'jobs', 'dev', 'iops', 'bw_MBps', 'latency_us'])
        for (phase, scen, jobs), per_dev in sorted(results.items()):
            all_devs.update(per_dev.keys())
            for dev, (iops, bw, lat) in per_dev.items():
                w.writerow([phase, scen, jobs, dev,
                            round(iops, 1), round(bw, 1), round(lat, 1)])
            w.writerow([phase, scen, jobs, 'AGGREGATE',
                        round(sum(v[0] for v in per_dev.values()), 1),
                        round(sum(v[1] for v in per_dev.values()), 1),
                        round(sum(v[2] for v in per_dev.values()) / max(len(per_dev), 1), 1)])
    if not results:
        print('WARN: no formal fio json found under %s' % perf_dir, file=sys.stderr)

    devs = sorted(all_devs, key=natkey)

    # ---- consistency series (multi jobs=4 preferred, single as fallback) ----
    consist_meta = {}
    for scen in SCEN_DEFS:
        series = None
        for phase in ('multi', 'single'):
            mon = os.path.join(mon_dir, '%s_%s_jobs4_iostat.log' % (phase, scen))
            if not os.path.exists(mon):
                continue
            samples = [s for s in parse_iostat(mon, devs) if s]
            # iostat's first report is the since-boot average, never a real
            # interval sample -> always drop it
            if samples:
                samples = samples[1:]
            n_raw = len(samples)
            if n_raw <= HEAD_TRIM + TAIL_TRIM:
                print('WARN: %s: only %d samples, too few to trim %d/%d; '
                      'keeping all (consistency verdicts will be N/A)'
                      % (os.path.basename(mon), n_raw, HEAD_TRIM, TAIL_TRIM),
                      file=sys.stderr)
                kept = samples
                trimmed = False
            else:
                kept = samples[HEAD_TRIM:n_raw - TAIL_TRIM]
                trimmed = True
            per_dev = OrderedDict()
            for d in devs:
                col = [iostat_metric(s[d], SCEN_DEFS[scen]['metric'])
                       for s in kept if d in s]
                if col:
                    per_dev[d] = col
            if per_dev:
                series = per_dev
                consist_meta[scen] = dict(phase=phase, n_raw=n_raw,
                                          n_kept=len(kept), trimmed=trimmed)
                break
        if series:
            out = os.path.join(csv_dir, 'consistency_%s.csv' % scen)
            with open(out, 'w', newline='') as fh:
                w = csv.writer(fh)
                w.writerow(['point'] + list(series.keys()))
                rows = list(series.values())
                for i in range(max(len(c) for c in rows)):
                    w.writerow([i + 1] + [('%.2f' % c[i]) if i < len(c) else ''
                                          for c in rows])
    with open(os.path.join(csv_dir, 'consistency_meta.json'), 'w') as fh:
        json.dump(consist_meta, fh, indent=2, ensure_ascii=False)

    # ---- crosscheck: fio aggregate vs iostat mean --------------------------
    xrows = []
    for (phase, scen, jobs), per_dev in sorted(results.items()):
        mon = os.path.join(mon_dir, '%s_%s_jobs%d_iostat.log' % (phase, scen, jobs))
        if not os.path.exists(mon):
            continue
        samples = parse_iostat(mon, list(per_dev.keys()))
        if len(samples) <= HEAD_TRIM + TAIL_TRIM:
            window = samples
        else:
            window = samples[HEAD_TRIM:len(samples) - TAIL_TRIM]
        metric = SCEN_DEFS[scen]['metric']
        fio_val = sum((v[0] / 1000.0) if metric == 'iops' else v[1]
                      for v in per_dev.values())
        tot = []
        for s in window:
            vals = [iostat_metric(s[d], metric) for d in per_dev if d in s]
            if vals:
                tot.append(sum(vals))
        if tot:
            ios_val = sum(tot) / len(tot)
            ratio = ios_val / fio_val if fio_val else float('nan')
            note = ''
            if abs(ratio - 1.0) > 0.05:
                note = 'DEVIATION>5%: check fio bw unit / sampling window'
            xrows.append([phase, scen, jobs, metric,
                          round(fio_val, 2), round(ios_val, 2),
                          round(ratio, 4), note])
    with open(os.path.join(csv_dir, 'crosscheck.csv'), 'w', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['phase', 'scen', 'jobs', 'metric', 'fio_sum',
                    'iostat_mean_sum', 'iostat/fio', 'note'])
        w.writerows(xrows)

    # ---- slot uniformity (95%-105% of mean, multi runs) --------------------
    urows = []
    for scen in SCEN_DEFS:
        for jobs in (1, 4):
            per_dev = results.get(('multi', scen, jobs))
            if not per_dev:
                continue
            metric = SCEN_DEFS[scen]['metric']
            vals = {d: ((v[0] / 1000.0) if metric == 'iops' else v[1])
                    for d, v in per_dev.items()}
            mean = sum(vals.values()) / len(vals)
            ratios = {d: v / mean for d, v in vals.items() if mean}
            if not ratios:
                continue
            urows.append([scen, jobs,
                          round(mean, 2),
                          round(min(ratios.values()), 4),
                          round(max(ratios.values()), 4),
                          'PASS' if all(0.95 <= r <= 1.05 for r in ratios.values())
                          else 'FAIL'])
    with open(os.path.join(csv_dir, 'uniformity.csv'), 'w', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['scen', 'jobs', 'mean', 'min_ratio', 'max_ratio',
                    'all_within_95_105'])
        w.writerows(urows)

    # ---- temperature --------------------------------------------------------
    elist_rows = parse_elist_logs(base)
    with open(os.path.join(csv_dir, 'temp_elist.csv'), 'w', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['ts', 'sensor', 'id', 'status', 'entity', 'value_C'])
        w.writerows(elist_rows)
    nv_rows = parse_nvme_temp_logs(base)
    with open(os.path.join(csv_dir, 'temp_nvme.csv'), 'w', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['ts', 'dev', 'value_C'])
        w.writerows(nv_rows)
    summary = []
    for source, rows, idx in (('elist', elist_rows, 1), ('nvme', nv_rows, 1)):
        agg = OrderedDict()
        for row in rows:
            agg.setdefault(row[idx], []).append(row[5] if source == 'elist' else row[2])
        for name, vals in agg.items():
            summary.append([source, name, min(vals), max(vals),
                            round(sum(vals) / len(vals), 1), len(vals)])
    with open(os.path.join(csv_dir, 'temp_summary.csv'), 'w', newline='') as fh:
        w = csv.writer(fh)
        w.writerow(['source', 'name', 'min_C', 'max_C', 'avg_C', 'samples'])
        w.writerows(summary)

    print('parse done -> %s' % csv_dir)
    return 0


# --------------------------------------------------------------------------
# build command helpers
# --------------------------------------------------------------------------
def load_csv(base, name):
    path = os.path.join(base, 'csv', name)
    if not os.path.exists(path):
        return []
    with open(path, 'r', newline='') as fh:
        return list(csv.reader(fh))


def load_results(base):
    results = {}
    for row in load_csv(base, 'formal_results.csv')[1:]:
        if row[3] == 'AGGREGATE':
            continue
        results[(row[0], row[1], int(row[2]), row[3])] = (
            float(row[4]), float(row[5]), float(row[6]))
    return results


def fio_cmd_str(scen, jobs, devs):
    d = SCEN_DEFS[scen]
    fn = ':'.join('/dev/' + x for x in devs)
    cmd = ('fio --name=%s --filename=%s --ioengine=libaio --direct=1 '
           '--thread=1 --numjobs=%d --iodepth=64 --rw=%s --bs=%s '
           '--runtime=600 --time_based=1 --size=100%% --group_reporting'
           % (scen, fn, jobs, d['rw'], d['bs']))
    if d['rw'].startswith('rand'):
        cmd += ' --norandommap=1 --randrepeat=0'
    return cmd


def inventory_meta(base, devs):
    inv = os.path.join(base, 'inventory')
    host = ''
    for line in read_text(os.path.join(inv, 'host.txt')).splitlines():
        if 'Product Name' in line:
            host = line.split(':', 1)[1].strip()
            break
    cpu = ''
    for line in read_text(os.path.join(inv, 'cpu.txt')).splitlines():
        if line.startswith('Model name'):
            cpu = line.split(':', 1)[1].strip()
            break
    disks, model, fw = [], '', ''
    inv_csv = os.path.join(inv, 'dev_inventory.csv')
    if os.path.exists(inv_csv):
        with open(inv_csv, newline='') as fh:
            disks = [r for r in csv.reader(fh) if r][1:]
    if disks:
        model = disks[0][1]
        fw = disks[0][3]
    disk_cfg = '%d x %s (FW %s) NVMe' % (len(disks), model, fw) if disks else ''
    return host, cpu, disk_cfg, 'NVMe 直连（无 RAID 卡 / SAS 卡）'


# --------------------------------------------------------------------------
# build command
# --------------------------------------------------------------------------
def cmd_build(base):
    try:
        from openpyxl import Workbook
        from openpyxl.chart import LineChart, Reference, Series
        from openpyxl.drawing.spreadsheet_drawing import (AnchorMarker,
                                                          TwoCellAnchor)
        from openpyxl.styles import Alignment, Border, Font, Side, PatternFill
        from openpyxl.utils import get_column_letter
    except ImportError:
        print('ERROR: openpyxl not available; install it and rerun build',
              file=sys.stderr)
        return 2

    def tca(c1, r1, co1, ro1, c2, r2, co2, ro2):
        _from = AnchorMarker(col=c1, row=r1, colOff=co1, rowOff=ro1)
        to = AnchorMarker(col=c2, row=r2, colOff=co2, rowOff=ro2)
        return TwoCellAnchor(editAs='twoCell', _from=_from, to=to)

    # charts anchor to the RIGHT of each table (owner's hand-edited
    # reference, 2026-09-08), not at fixed template positions
    CHART_W_COLS, CHART_H_ROWS = 13, 25      # consistency charts
    TEMP_CHART_W, TEMP_CHART_H = 13, 30      # temperature chart
    # owner format spec (hand-edited reference, 2026-09-08): all measured
    # numbers use 2-decimal accounting style, ratios included (0.85 not 85%)
    NUM2 = '0.00_);[Red]\(0.00\)'

    def num2(ws, row, col, value):
        c = ws.cell(row=row, column=col, value=value)
        c.number_format = NUM2
        return c

    results = load_results(base)
    multi_devs = sorted({k[3] for k in results if k[0] == 'multi'}, key=natkey)
    single_devs = sorted({k[3] for k in results if k[0] == 'single'}, key=natkey)
    devs = multi_devs or single_devs
    if not devs:
        print('ERROR: no parsed results; run parse first', file=sys.stderr)
        return 2
    host, cpu, disk_cfg, backplane = inventory_meta(base, devs)

    thin = Side(style='thin')
    border = Border(left=thin, right=thin, top=thin, bottom=thin)
    hdr_font = Font(bold=True)
    hdr_fill = PatternFill('solid', fgColor='DDEBF7')
    center = Alignment(horizontal='center', vertical='center')
    left_wrap = Alignment(horizontal='left', vertical='center', wrap_text=True)

    wb = Workbook()
    wb.remove(wb.active)
    wb.properties.creator = 'SIT-Kit'

    def box(ws, rng, value, bold=False, fill=None):
        ws.merge_cells(rng)
        first = rng.split(':')[0]
        c = ws[first]
        c.value = value
        if bold:
            c.font = hdr_font
        if fill:
            c.fill = fill
        c.alignment = center
        return c

    def style_header_row(ws, row, c1, c2):
        for col in range(c1, c2 + 1):
            c = ws.cell(row=row, column=col)
            c.font = hdr_font
            c.fill = hdr_fill
            c.alignment = center
            c.border = border

    # ===================== sheet 1: single-disk basic perf ==================
    ws = wb.create_sheet('基础性能测试模板')
    box(ws, 'A1:AE2', 'SSD性能测试', bold=True)
    ws['A3'] = '硬盘配置（典型配置由产品侧给出，按实际增减）'
    ws.merge_cells('A3:A4')
    for rng, txt in [('B3:B4', 'Jobs'), ('C3:C4', 'Queue Depth'),
                     ('D3:E3', 'Bandwidth(MB/s)'), ('F3:G3', 'SPEC带宽(MB/S)'),
                     ('H3:I3', 'IOPS(K）'), ('J3:K3', 'SpecIOPS(K)'),
                     ('L3:M3', '带宽占比'), ('N3:O3', 'IOPS占比'),
                     ('P3:S3', 'Lantency(us)'), ('T3:W3', 'spec Lantency(us)'),
                     ('X3:AA3', 'Lantency占比'), ('AB3:AE3', '测试结果（PASS/FAIL）')]:
        box(ws, rng, txt)
    subs = ['1024K/SR', '1024K/SW'] * 2 + ['4K/RR', '4K/RW'] * 2 + \
           ['1024k/SR', '1024k/SW', '4K/RR', '4K/RW'] * 5
    for i, txt in enumerate(subs):
        ws.cell(row=4, column=4 + i, value=txt)
    ws['A3'].font = hdr_font
    style_header_row(ws, 3, 1, 31)
    style_header_row(ws, 4, 1, 31)
    box(ws, 'A5:A6', '单盘RAID0-单盘')
    box(ws, 'A7:A8', 'JBOD-单盘')
    for r, jobs in ((5, 1), (6, 4), (7, 1), (8, 4)):
        ws.cell(row=r, column=2, value=jobs)
        ws.cell(row=r, column=3, value=64)
    if single_devs:
        sd = single_devs[0]
        for r, jobs in ((7, 1), (8, 4)):
            for col, key in ((4, ('single', 'SR', jobs, sd)),
                             (5, ('single', 'SW', jobs, sd)),
                             (8, ('single', 'RR', jobs, sd)),
                             (9, ('single', 'RW', jobs, sd)),
                             (16, ('single', 'SR', jobs, sd)),
                             (17, ('single', 'SW', jobs, sd)),
                             (18, ('single', 'RR', jobs, sd)),
                             (19, ('single', 'RW', jobs, sd))):
                v = results.get(key)
                if not v:
                    continue
                if col in (4, 5):
                    num2(ws, r, col, round(v[1], 2))
                elif col in (8, 9):
                    num2(ws, r, col, round(v[0] / 1000, 2))
                else:
                    num2(ws, r, col, round(v[2], 2))
    for c1 in ('F', 'G', 'J', 'K', 'T', 'U', 'V', 'W'):
        ws.merge_cells('%s5:%s8' % (c1, c1))
    # (ratio col, value col, spec cell): template L5 = D5/$F$5
    RATIO_MAP = (('L', 'D', '$F$5'), ('M', 'E', '$G$5'), ('N', 'H', '$J$5'),
                 ('O', 'I', '$K$5'), ('X', 'P', '$T$5'), ('Y', 'Q', '$U$5'),
                 ('Z', 'R', '$V$5'), ('AA', 'S', '$W$5'))
    for r in range(5, 9):
        for rc, vc, spec in RATIO_MAP:
            cell = ws['%s%d' % (rc, r)]
            cell.value = '=IFERROR(%s%d/%s," ")' % (vc, r, spec)
            cell.number_format = NUM2
        for c1, rc in (('AB', 'L'), ('AC', 'M'), ('AD', 'N'), ('AE', 'O')):
            ws['%s%d' % (c1, r)].value = \
                '=IF(%s%d=" ","",IF(%s%d>=%s,"PASS","FAIL"))' % (
                    rc, r, rc, r, SPEC_PASS_RATIO)
    cmds = '\n'.join(fio_cmd_str(s, j, single_devs or devs)
                     for s in SCEN_DEFS for j in (1, 4))
    box(ws, 'A9:AE9', 'FIO命令：\n' + cmds).alignment = left_wrap
    ws.row_dimensions[9].height = 90
    for r, label, val in ((10, '服务器型号', host), (11, 'CPU型号', cpu),
                          (12, '硬盘配置', disk_cfg), (13, '背板配置', backplane)):
        ws.cell(row=r, column=1, value=label).font = hdr_font
        box(ws, 'B%d:C%d' % (r, r), val)

    # ===================== sheet 2: multi-disk basic perf ===================
    ws2 = wb.create_sheet('多盘基础性能测试')
    n = len(multi_devs)
    last = 4 + 2 * max(n, 1)
    box(ws2, 'A1:AE2', '多盘基础性能测试', bold=True)
    ws2['A3'] = '硬盘配置（典型配置由产品侧给出，按实际增减）'
    ws2.merge_cells('A3:A4')
    for rng, txt in [('B3:B4', 'Jobs'), ('C3:C4', 'Queue Depth'),
                     ('D3:E3', 'Bandwidth(MB/s)'), ('F3:G3', 'SPEC带宽(MB/S)'),
                     ('H3:I3', 'IOPS(K）'), ('J3:K3', 'SpecIOPS(K)'),
                     ('L3:M3', '带宽占比'), ('N3:O3', 'IOPS占比'),
                     ('P3:S3', 'Lantency(us)'), ('T3:W3', 'spec Lantency(us)'),
                     ('X3:AA3', 'Lantency占比'), ('AB3:AE3', '测试结果（PASS/FAIL）')]:
        box(ws2, rng, txt)
    for i, txt in enumerate(subs):
        ws2.cell(row=4, column=4 + i, value=txt)
    ws2['A3'].font = hdr_font
    style_header_row(ws2, 3, 1, 31)
    style_header_row(ws2, 4, 1, 31)
    for i, d in enumerate(multi_devs):
        r = 5 + 2 * i
        box(ws2, 'A%d:A%d' % (r, r + 1), d)
        for rr, jobs in ((r, 1), (r + 1, 4)):
            ws2.cell(row=rr, column=2, value=jobs)
            ws2.cell(row=rr, column=3, value=64)
            for col, scen in ((4, 'SR'), (5, 'SW'), (8, 'RR'), (9, 'RW'),
                              (16, 'SR'), (17, 'SW'), (18, 'RR'), (19, 'RW')):
                v = results.get(('multi', scen, jobs, d))
                if not v:
                    continue
                if col in (4, 5):
                    num2(ws2, rr, col, round(v[1], 2))
                elif col in (8, 9):
                    num2(ws2, rr, col, round(v[0] / 1000, 2))
                else:
                    num2(ws2, rr, col, round(v[2], 2))
    if n:
        for c1 in ('F', 'G', 'J', 'K', 'T', 'U', 'V', 'W'):
            ws2.merge_cells('%s5:%s%d' % (c1, c1, last))
        for r in range(5, last + 1):
            for rc, vc, spec in RATIO_MAP:
                cell = ws2['%s%d' % (rc, r)]
                cell.value = '=IFERROR(%s%d/%s," ")' % (vc, r, spec)
                cell.number_format = NUM2
            for c1, rc in (('AB', 'L'), ('AC', 'M'), ('AD', 'N'), ('AE', 'O')):
                ws2['%s%d' % (c1, r)].value = \
                    '=IF(%s%d=" ","",IF(%s%d>=%s,"PASS","FAIL"))' % (
                        rc, r, rc, r, SPEC_PASS_RATIO)
    row_cmd = last + 1
    cmds = '\n'.join(fio_cmd_str(s, j, multi_devs or devs)
                     for s in SCEN_DEFS for j in (1, 4))
    box(ws2, 'A%d:AE%d' % (row_cmd, row_cmd), 'FIO命令：\n' + cmds).alignment = left_wrap
    ws2.row_dimensions[row_cmd].height = 90
    for k, label in enumerate(('服务器型号', 'CPU型号', '硬盘配置', '背板配置')):
        r = row_cmd + 1 + k
        ws2.cell(row=r, column=1, value=label).font = hdr_font
        box(ws2, 'B%d:C%d' % (r, r), (host, cpu, disk_cfg, backplane)[k])

    # ===================== sheet 3: per-slot averages =======================
    ws3 = wb.create_sheet('性能平均值测试')
    ws3['B4'], ws3['C4'] = 'Jobs', 1
    ws3['D4'], ws3['E4'] = 'Queue Depth', 64
    ws3['H4'], ws3['I4'] = 'Jobs', 4
    ws3['J4'], ws3['K4'] = 'Queue Depth', 64
    for rng, txt in [('A5:A6', 'slot号'), ('B5:E5', 'Bandwidth(MB/s)平均值对比'),
                     ('G5:G6', 'slot号'), ('H5:K5', 'IOPS(K）平均值对比')]:
        box(ws3, rng, txt)
    for c1, txt in (('B', '1024k/SR'), ('C', '平均值占比'), ('D', '1024k/SW'),
                    ('E', '平均值占比'), ('H', '4K/RR'), ('I', '平均值占比'),
                    ('J', '4K/RW'), ('K', '平均值占比')):
        ws3['%s6' % c1] = txt
    style_header_row(ws3, 4, 1, 11)
    style_header_row(ws3, 5, 1, 11)
    style_header_row(ws3, 6, 1, 11)
    slot_rows = range(7, 31)          # template: 24 slots
    for i, r in enumerate(slot_rows):
        if i < len(devs):
            d = devs[i]
            ws3.cell(row=r, column=1, value='slot%d(%s)' % (i + 1, d))
            ws3.cell(row=r, column=7, value='slot%d(%s)' % (i + 1, d))
            v = results.get(('multi', 'SR', 1, d))
            if v:
                num2(ws3, r, 2, round(v[1], 2))
            v = results.get(('multi', 'SW', 1, d))
            if v:
                num2(ws3, r, 4, round(v[1], 2))
            v = results.get(('multi', 'RR', 4, d))
            if v:
                num2(ws3, r, 8, round(v[0] / 1000, 2))
            v = results.get(('multi', 'RW', 4, d))
            if v:
                num2(ws3, r, 10, round(v[0] / 1000, 2))
        for c1, avg in (('C', 'B'), ('E', 'D'), ('I', 'H'), ('K', 'J')):
            cell = ws3['%s%d' % (c1, r)]
            cell.value = '=IFERROR(%s%d/%s$31," ")' % (avg, r, avg)
            cell.number_format = NUM2
    ws3['A31'] = '平均值'
    ws3['G31'] = '平均值'
    for c1 in ('B', 'D', 'H', 'J'):
        ws3['%s31' % c1] = '=IFERROR(AVERAGE(%s7:%s30)," ")' % (c1, c1)

    # ===================== sheets 4-7: consistency ==========================
    # Layout follows the owner's hand-edited reference (2026-09-08):
    #   r1 note, r2 scenario title, r3 disk headers, r4+ data points,
    #   stat rows directly after the data, chart anchored to the RIGHT of
    #   the table (from col = 1 + ndevs + 1).
    for sheet_name in CONSIST_SHEET_ORDER:
        scen = next(s for s, nm in CONSIST_SHEET.items() if nm == sheet_name)
        wsc = wb.create_sheet(sheet_name)
        data = load_csv(base, 'consistency_%s.csv' % scen)
        meta_c = load_meta(base)
        scen_meta = meta_c.get(scen, {})
        trimmed = scen_meta.get('trimmed', True)
        if trimmed:
            note = ('数据来源: %s jobs=4 轮 iostat 1s 采样, 有效采样 %d 点, '
                    '去头 %ds 去尾 %ds 后保留 %d 点'
                    % (scen_meta.get('phase', '?'), scen_meta.get('n_raw', 0),
                       HEAD_TRIM, TAIL_TRIM, scen_meta.get('n_kept', 0)))
        else:
            note = ('数据来源: %s jobs=4 轮 iostat 1s 采样, 仅 %d 点(不足裁剪 '
                    '%d/%d), 未做去头去尾, 含爬坡点; 一致性判定标记为 N/A, '
                    '仅流程验证用, 正式 600s 轮会正常裁剪'
                    % (scen_meta.get('phase', '?'), scen_meta.get('n_raw', 0),
                       HEAD_TRIM, TAIL_TRIM))
        wsc['A1'] = note
        wsc['A2'] = '%s，Jobs=4，Queue Depth=64' % SCEN_DEFS[scen]['label']
        wsc['A2'].font = hdr_font
        hdr_row, first = 3, 4
        cols = []
        if data:
            devs_c = data[0][1:]
            for j, d in enumerate(devs_c):
                col = 2 + j
                wsc.cell(row=hdr_row, column=col, value=d).font = hdr_font
                cols.append(col)
            m = len(data) - 1
            for i in range(1, len(data)):
                wsc.cell(row=first + i - 1, column=1, value='性能数值%d' % i)
                for j, col in enumerate(cols):
                    val = data[i][1 + j]
                    if val != '':
                        c = wsc.cell(row=first + i - 1, column=col,
                                     value=round(float(val), 2))
                        c.number_format = NUM2
            last_r = first + m - 1
        else:
            last_r = first + 139
            for i in range(1, 141):
                wsc.cell(row=first + i - 1, column=1, value='性能数值%d' % i)
        stat = last_r + 1
        for col in cols:
            c1 = get_column_letter(col)
            cells = []
            cells.append(('平均值', '=AVERAGE(%s%d:%s%d)' % (c1, first, c1, last_r), NUM2))
            cells.append(('平均值的95%', '=%s%d*95%%' % (c1, stat), NUM2))
            cells.append(('平均值的105%', '=%s%d*105%%' % (c1, stat), NUM2))
            cells.append(('剩余点在95-105%的比例',
                          '=IFERROR(SUMPRODUCT((%s%d:%s%d>=%s%d)*(%s%d:%s%d<=%s%d))'
                          '/COUNT(%s%d:%s%d)," ")'
                          % (c1, first, c1, last_r, c1, stat + 1,
                             c1, first, c1, last_r, c1, stat + 2,
                             c1, first, c1, last_r), '0.0%'))
            cells.append(('最低点/平均值',
                          '=IFERROR(MIN(%s%d:%s%d)/%s%d," ")'
                          % (c1, first, c1, last_r, c1, stat), '0.00'))
            cells.append(('低于平均值50%的点数',
                          '=COUNTIF(%s%d:%s%d,"<"&%s%d*0.5)'
                          % (c1, first, c1, last_r, c1, stat), '0'))
            for k, (label, formula, fmt) in enumerate(cells):
                r = stat + k
                wsc.cell(row=r, column=1, value=label).font = hdr_font
                cell = wsc.cell(row=r, column=col, value=formula)
                cell.number_format = fmt
        thr = CONSIST_THRESH[scen]
        r_thr, r_verdict, r_low = stat + 6, stat + 7, stat + 8
        wsc.cell(row=r_thr, column=1, value='一致性阈值(PASS标准)').font = hdr_font
        wsc.cell(row=r_verdict, column=1, value='一致性判定').font = hdr_font
        wsc.cell(row=r_low, column=1, value='低于50%点判定').font = hdr_font
        for col in cols:
            c1 = get_column_letter(col)
            wsc.cell(row=r_thr, column=col, value=thr).number_format = '0%'
            if trimmed:
                wsc.cell(row=r_verdict, column=col,
                         value='=IF(%s%d>=%s,"PASS","FAIL")' % (c1, stat + 3, thr))
                wsc.cell(row=r_low, column=col,
                         value='=IF(%s%d=0,"PASS","FAIL")' % (c1, stat + 5))
            else:
                wsc.cell(row=r_verdict, column=col, value='N/A(未裁剪)')
                wsc.cell(row=r_low, column=col, value='N/A(未裁剪)')
        if cols:
            ch = LineChart()
            ch.title = SCEN_DEFS[scen]['label']
            ch.y_axis.title = ('IOPS(K)' if SCEN_DEFS[scen]['metric'] == 'iops'
                               else 'MB/s')
            ch.x_axis.title = '采样点'
            for col in cols:
                ref = Reference(wsc, min_col=col, min_row=hdr_row,
                                max_row=last_r)
                ch.add_data(ref, titles_from_data=True)
            # right of the table: last data col (1-based) equals the
            # 0-based anchor col of the column right after it
            c0 = cols[-1]
            ch.anchor = tca(c0, 0, 0, 0, c0 + CHART_W_COLS, CHART_H_ROWS, 0, 0)
            wsc.add_chart(ch)

    # ===================== sheet 8: temperature =============================
    # per-disk nvme smart-log temperatures (csv/temp_nvme.csv, one timestamp
    # per sampler round covering all disks) + a per-round all-disk average;
    # BMC elist sensors stay in csv/temp_elist.csv as evidence only.
    ws8 = wb.create_sheet('各个硬盘的温度记录')
    nv_rows = load_csv(base, 'temp_nvme.csv')
    rounds = OrderedDict()          # ts -> {dev: temp}
    order = []
    for row in nv_rows[1:]:
        if len(row) < 3:
            continue
        ts, dev, val = row[0], row[1], row[2]
        if ts not in rounds:
            rounds[ts] = OrderedDict()
            order.append(ts)
        try:
            rounds[ts][dev] = float(val)
        except ValueError:
            continue
    all_devs = devs
    hdr_row = 3
    first_row = 4
    ws8.cell(row=hdr_row, column=1, value='采样点(时间)').font = hdr_font
    for j, d in enumerate(all_devs):
        ws8.cell(row=hdr_row, column=2 + j, value=d).font = hdr_font
    avg_col = 2 + len(all_devs)
    ws8.cell(row=hdr_row, column=avg_col, value='全盘平均').font = hdr_font
    style_header_row(ws8, hdr_row, 1, avg_col)
    r = first_row
    for ts in sorted(order):   # chronological, not tag-file order
        vals = rounds[ts]
        ws8.cell(row=r, column=1, value=ts)
        for j, d in enumerate(all_devs):
            if d in vals:
                ws8.cell(row=r, column=2 + j, value=vals[d]).number_format = '0'
        present = [vals[d] for d in all_devs if d in vals]
        if present:
            c = ws8.cell(row=r, column=avg_col,
                         value=round(sum(present) / len(present), 1))
            c.number_format = '0.0'
        r += 1
    last_r = r - 1
    if last_r >= first_row:
        ch = LineChart()
        ch.title = '硬盘温度(nvme smart-log, 30-60s采样)'
        ch.y_axis.title = 'degrees C'
        ch.x_axis.title = '采样点'
        # per-disk lines (thin default) + average line made prominent
        for j in range(len(all_devs)):
            col = 2 + j
            ref = Reference(ws8, min_col=col, min_row=hdr_row, max_row=last_r)
            ch.add_data(ref, titles_from_data=True)
        avg_ref = Reference(ws8, min_col=avg_col, min_row=hdr_row,
                            max_row=last_r)
        ch.add_data(avg_ref, titles_from_data=True)
        s = ch.series[-1]
        s.graphicalProperties.line.width = 28000     # ~2.2pt, bold average
        c0 = avg_col              # right of the table (owner's reference)
        ch.anchor = tca(c0, 2, 0, 0, c0 + TEMP_CHART_W, 2 + TEMP_CHART_H, 0, 0)
        ws8.add_chart(ch)

    # ===================== sheet 9: provenance ===============================
    ws9 = wb.create_sheet('数据说明')
    meta_c = load_meta(base)
    fio_ver = read_text(os.path.join(base, 'inventory',
                                     'fio_version.txt')).strip() or 'unknown'
    prov = [
        ('数据说明（数据来源与判定规则）', ''),
        ('', ''),
        ('生成时间', time.strftime('%Y-%m-%d %H:%M:%S')),
        ('fio 版本', fio_ver),
        ('每盘数据来源',
         'fio 每盘一个 job 段（new_group=1 + 段内 group_reporting），'
         'JSON 内该盘 iops/bw/latency；bw 单位按 fio 版本换算'
         '（3.x=B/s，2.x=KiB/s）'),
        ('sheet1 基础性能测试模板',
         '单盘阶段实测值：D/E=1M SR/SW 带宽(MB/s)，H/I=4K RR/RW IOPS(K)，'
         'P-S=对应轮次 avg latency(us)。spec 列(F/G/J/K/T-W)留空待填，'
         '填入后占比列(L-O/X-AA)与 PASS/FAIL(AB-AE，阈值85%)自动计算'),
        ('sheet2 多盘基础性能测试',
         '多盘联合实测值，每盘两行(jobs=1/4)，列含义同 sheet1'),
        ('sheet3 性能平均值测试',
         '左块=多盘 jobs=1 的 1M SR/SW 带宽，右块=jobs=4 的 4K RR/RW IOPS(K)；'
         '第31行 AVERAGE 公式，占比列对平均值计算'),
        ('sheet4-7 一致性',
         '数据源=该场景 jobs=4 正式轮的 iostat 1s 逐盘采样；'
         '去头110s去尾50s后按剩余点数计算；'
         '指标：1M场景=MB/s，4K场景=IOPS(K)；'
         '判定行=剩余点在95%-105%均值的比例，PASS阈值 4KRR>=80%/4KRW>=70%/1M>=90%，'
         '并要求无低于均值50%的点'),
        ('sheet8 温度',
         '每盘 nvme smart-log 温度（采样间隔30-60s，同一轮时间戳对齐），'
         '末列为全盘平均；BMC 传感器原始数据在 csv/temp_elist.csv'),
        ('交叉核对',
         'csv/crosscheck.csv：每轮 fio 汇总 vs iostat 窗口均值，偏差>5%标注；'
         'csv/uniformity.csv：盘间95%-105%均匀性'),
        ('原始数据', 'perf_data/*.json(fio) monitor/*_iostat.log csv/*.csv'),
    ]
    for i, (k, v) in enumerate(prov, start=1):
        ws9.cell(row=i, column=1, value=k).font = hdr_font if i == 1 else Font(bold=(k != ''))
        c = ws9.cell(row=i, column=2, value=v)
        c.alignment = left_wrap
    ws9.column_dimensions['A'].width = 26
    ws9.column_dimensions['B'].width = 100

    out = os.path.join(base, 'report',
                       'SSD性能测试结果_%s.xlsx' % os.path.basename(base))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    wb.save(out)
    print('report saved -> %s' % out)
    return 0


def load_meta(base):
    path = os.path.join(base, 'csv', 'consistency_meta.json')
    if not os.path.exists(path):
        return {}
    with open(path) as fh:
        return json.load(fh)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name in ('parse', 'build'):
        p = sub.add_parser(name)
        p.add_argument('-b', '--base', required=True)
    args = ap.parse_args()
    if not os.path.isdir(args.base):
        print('ERROR: base dir not found: %s' % args.base, file=sys.stderr)
        return 2
    return cmd_parse(args.base) if args.cmd == 'parse' else cmd_build(args.base)


if __name__ == '__main__':
    sys.exit(main())
