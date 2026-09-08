"""
Network IP Scanner - GUI Tool
Scan a subnet for online IPs, save results, and compare two scans
to find which IPs disappeared (e.g., after unplugging a cable).
"""

import json
import os
import subprocess
import sys
import threading
import tkinter as tk
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from tkinter import messagebox, ttk


# ---- Paths ----
if getattr(sys, 'frozen', False):
    SCRIPT_DIR = os.path.dirname(os.path.abspath(sys.executable))
else:
    SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SCAN_DIR = os.path.join(SCRIPT_DIR, "scans")


def ensure_scan_dir():
    os.makedirs(SCAN_DIR, exist_ok=True)


# ---- Subnet parsing ----

def parse_subnet(target: str) -> dict:
    """Parse target: CIDR (192.168.1.0/24) or wildcard (10.8.149.X)."""
    target = target.strip().upper()

    if "/" in target:
        # CIDR notation: 192.168.1.0/24
        ip_str, prefix_str = target.split("/")
        prefix = int(prefix_str)
        if prefix < 16 or prefix > 30:
            raise ValueError("Prefix must be 16-30")
        octets = [int(x) for x in ip_str.split(".")]
        if len(octets) != 4 or any(o < 0 or o > 255 for o in octets):
            raise ValueError("Invalid IP address")

        ip_int = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
        mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF
        network = ip_int & mask
        broadcast = network | (~mask & 0xFFFFFFFF)
        total = broadcast - network + 1

        ips = []
        for i in range(1, total - 1):
            addr = network + i
            ips.append(f"{(addr >> 24) & 0xFF}.{(addr >> 16) & 0xFF}."
                       f"{(addr >> 8) & 0xFF}.{addr & 0xFF}")

        return {
            "network": f"{octets[0]}.{octets[1]}.{octets[2]}.{octets[3]}",
            "prefix": prefix,
            "total_hosts": total - 2,
            "ips": ips,
        }

    # Wildcard notation: 10.8.149.X or 192.168.X.X
    parts = target.split(".")
    if len(parts) != 4:
        raise ValueError("Invalid format. Use e.g. 10.8.149.X or 192.168.1.0/24")

    ranges = []
    wildcard_count = 0
    for p in parts:
        if p.upper() == "X":
            ranges.append(range(1, 255))
            wildcard_count += 1
        else:
            try:
                v = int(p)
                if v < 0 or v > 255:
                    raise ValueError(f"Invalid octet: {p}")
                ranges.append(range(v, v + 1))
            except ValueError:
                raise ValueError(f"Invalid octet: {p}. Use numbers or X")

    ips = []
    if wildcard_count == 1:
        for r3 in ranges[3]:
            ips.append(f"{ranges[0].start}.{ranges[1].start}.{ranges[2].start}.{r3}")
    elif wildcard_count == 2:
        for r2 in ranges[2]:
            for r3 in ranges[3]:
                ips.append(f"{ranges[0].start}.{ranges[1].start}.{r2}.{r3}")
    elif wildcard_count == 3:
        for r1 in ranges[1]:
            for r2 in ranges[2]:
                for r3 in ranges[3]:
                    ips.append(f"{ranges[0].start}.{r1}.{r2}.{r3}")
    elif wildcard_count == 4:
        for r0 in ranges[0]:
            for r1 in ranges[1]:
                for r2 in ranges[2]:
                    for r3 in ranges[3]:
                        ips.append(f"{r0}.{r1}.{r2}.{r3}")
    else:
        raise ValueError("No wildcard (X) found. Single IP not supported, use CIDR or X.")

    network_str = ".".join(str(r.start) if r.start == r.stop - 1 else "X" for r in ranges)
    return {
        "network": network_str,
        "prefix": 0,
        "total_hosts": len(ips),
        "ips": ips,
    }


# ---- Ping ----

def ping_ip(ip: str, timeout_ms: int) -> dict:
    """Ping a single IP, return result dict."""
    try:
        proc = subprocess.run(
            ["ping", "-n", "1", "-w", str(timeout_ms), ip],
            capture_output=True,
            timeout=(timeout_ms / 1000) + 2,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        online = proc.returncode == 0
        # Parse latency from output
        latency = None
        if online:
            for line in proc.stdout.decode("gbk", errors="ignore").splitlines():
                if "time" in line.lower() or "时间" in line:
                    # Extract time value
                    import re
                    m = re.search(r"(?:time|时间)\s*[<>=]\s*(\d+)\s*ms", line, re.IGNORECASE)
                    if m:
                        latency = int(m.group(1))
                        break
        return {"ip": ip, "online": online, "latency": latency}
    except Exception:
        return {"ip": ip, "online": False, "latency": None}


# ---- Scanner App ----

class ScannerApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("Network IP Scanner")
        self.root.geometry("650x820")
        self.root.minsize(650, 550)

        self._scanning = False
        self._cancel_flag = False
        self._scan_results = []  # list of {ip, online, latency}
        self._scan_files = []    # list of scan json file paths

        self._build_ui()
        self._refresh_scan_list()

    # ----------------------------------------------------------
    # UI construction
    # ----------------------------------------------------------

    def _build_ui(self):
        # Style
        style = ttk.Style()
        style.theme_use("clam")

        main_frame = ttk.Frame(self.root, padding="10")
        main_frame.pack(fill=tk.BOTH, expand=True)

        # ---- Scan section ----
        scan_frame = ttk.LabelFrame(main_frame, text="Scan Subnet", padding="10")
        scan_frame.pack(fill=tk.X, pady=(0, 10))

        row1 = ttk.Frame(scan_frame)
        row1.pack(fill=tk.X, pady=(0, 8))
        ttk.Label(row1, text="Subnet:").pack(side=tk.LEFT)
        self.subnet_var = tk.StringVar(value="10.8.149.X")
        self.subnet_entry = ttk.Entry(row1, textvariable=self.subnet_var, width=22)
        self.subnet_entry.pack(side=tk.LEFT, padx=(5, 15))

        ttk.Label(row1, text="Timeout:").pack(side=tk.LEFT)
        self.timeout_var = tk.StringVar(value="300")
        ttk.Entry(row1, textvariable=self.timeout_var, width=6).pack(side=tk.LEFT)
        ttk.Label(row1, text="ms").pack(side=tk.LEFT, padx=(2, 15))

        ttk.Label(row1, text="Threads:").pack(side=tk.LEFT)
        self.threads_var = tk.StringVar(value="64")
        ttk.Entry(row1, textvariable=self.threads_var, width=5).pack(side=tk.LEFT)

        self.scan_btn = ttk.Button(row1, text="Start Scan", command=self._start_scan)
        self.scan_btn.pack(side=tk.RIGHT, padx=(10, 0))

        # Progress
        self.progress_var = tk.StringVar(value="Ready")
        ttk.Label(scan_frame, textvariable=self.progress_var).pack(fill=tk.X)
        self.progress_bar = ttk.Progressbar(scan_frame, mode="determinate")
        self.progress_bar.pack(fill=tk.X, pady=(5, 0))

        # ---- Online IPs list ----
        list_frame = ttk.LabelFrame(main_frame, text="Online IPs Found", padding="5")
        list_frame.pack(fill=tk.BOTH, expand=True, pady=(0, 10))

        columns = ("ip", "latency")
        self.ip_tree = ttk.Treeview(list_frame, columns=columns, show="headings", height=5)
        self.ip_tree.heading("ip", text="IP Address")
        self.ip_tree.heading("latency", text="Latency")
        self.ip_tree.column("ip", width=200)
        self.ip_tree.column("latency", width=100, anchor="center")
        self.ip_tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        ip_scroll = ttk.Scrollbar(list_frame, orient=tk.VERTICAL, command=self.ip_tree.yview)
        ip_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        self.ip_tree.configure(yscrollcommand=ip_scroll.set)

        # ---- Compare section ----
        cmp_frame = ttk.LabelFrame(main_frame, text="Compare Scans", padding="10")
        cmp_frame.pack(fill=tk.X, pady=(0, 10))

        cmp_row1 = ttk.Frame(cmp_frame)
        cmp_row1.pack(fill=tk.X)

        ttk.Label(cmp_row1, text="Scan 1:").pack(side=tk.LEFT)
        self.cmp1_var = tk.StringVar()
        self.cmp1_combo = ttk.Combobox(cmp_row1, textvariable=self.cmp1_var, state="readonly", width=35)
        self.cmp1_combo.pack(side=tk.LEFT, padx=(5, 10))

        ttk.Label(cmp_row1, text="Scan 2:").pack(side=tk.LEFT)
        self.cmp2_var = tk.StringVar()
        self.cmp2_combo = ttk.Combobox(cmp_row1, textvariable=self.cmp2_var, state="readonly", width=35)
        self.cmp2_combo.pack(side=tk.LEFT, padx=(5, 10))

        cmp_row2 = ttk.Frame(cmp_frame)
        cmp_row2.pack(fill=tk.X, pady=(8, 0))

        ttk.Button(cmp_row2, text="Compare", command=self._compare).pack(side=tk.LEFT, padx=(0, 5))
        ttk.Button(cmp_row2, text="Compare Last 2", command=self._compare_last).pack(side=tk.LEFT, padx=(0, 5))
        ttk.Button(cmp_row2, text="Delete All Scans", command=self._delete_all_scans).pack(side=tk.LEFT)

        # ---- Compare result ----
        result_frame = ttk.LabelFrame(main_frame, text="Comparison Result", padding="5")
        result_frame.pack(fill=tk.BOTH, expand=True)

        self.result_text = tk.Text(result_frame, wrap=tk.WORD, state=tk.DISABLED,
                                   font=("Consolas", 10))
        self.result_text.pack(fill=tk.BOTH, expand=True)

    # ----------------------------------------------------------
    # Scan logic
    # ----------------------------------------------------------

    def _start_scan(self):
        if self._scanning:
            self._cancel_flag = True
            return

        cidr = self.subnet_var.get().strip()
        if not cidr:
            messagebox.showerror("Error", "Please enter a subnet (e.g., 192.168.1.0/24)")
            return

        try:
            timeout = int(self.timeout_var.get())
            threads = int(self.threads_var.get())
        except ValueError:
            messagebox.showerror("Error", "Timeout and Threads must be integers")
            return

        try:
            subnet = parse_subnet(cidr)
        except Exception as e:
            messagebox.showerror("Error", f"Invalid subnet: {e}")
            return

        # Clear previous
        for item in self.ip_tree.get_children():
            self.ip_tree.delete(item)

        self._scanning = True
        self._cancel_flag = False
        self._scan_results = []
        self.scan_btn.configure(text="Cancel")
        self.progress_bar["value"] = 0
        self.progress_bar["maximum"] = len(subnet["ips"])
        self.progress_var.set(f"Scanning {subnet['total_hosts']} hosts...")

        thread = threading.Thread(
            target=self._run_scan,
            args=(subnet["ips"], timeout, threads, subnet),
            daemon=True,
        )
        thread.start()

    def _run_scan(self, ips: list, timeout: int, threads: int, subnet: dict):
        results = []
        total = len(ips)
        done = 0

        with ThreadPoolExecutor(max_workers=threads) as executor:
            futures = {executor.submit(ping_ip, ip, timeout): ip for ip in ips}
            for future in as_completed(futures):
                if self._cancel_flag:
                    executor.shutdown(wait=False, cancel_futures=True)
                    break
                try:
                    r = future.result()
                    results.append(r)
                except Exception:
                    pass
                done += 1
                # Update progress (throttled)
                if done % 8 == 0 or done == total:
                    self.root.after(0, self._update_progress, done, results)

        if not self._cancel_flag:
            self.root.after(0, self._scan_done, results, subnet)
        else:
            self.root.after(0, self._scan_cancelled, results)

    def _update_progress(self, done: int, results: list):
        self.progress_bar["value"] = done
        online = sum(1 for r in results if r["online"])
        self.progress_var.set(f"Scanning... {done}/{self.progress_bar['maximum']}  Online: {online}")

    def _scan_done(self, results: list, subnet: dict):
        self._scanning = False
        self.scan_btn.configure(text="Start Scan")
        self._scan_results = results

        online_list = sorted(
            [r for r in results if r["online"]],
            key=lambda x: tuple(map(int, x["ip"].split("."))),
        )
        for r in online_list:
            lat = f"{r['latency']}ms" if r["latency"] is not None else "-"
            self.ip_tree.insert("", tk.END, values=(r["ip"], lat))

        online_count = len(online_list)
        self.progress_var.set(f"Done. {online_count} online / {len(results)} scanned.")

        # Save to JSON
        ensure_scan_dir()
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"scan_{timestamp}.json"
        filepath = os.path.join(SCAN_DIR, filename)
        data = {
            "scan_time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "subnet": f"{subnet['network']}/{subnet['prefix']}",
            "timeout": int(self.timeout_var.get()),
            "total_hosts": subnet["total_hosts"],
            "online_count": online_count,
            "online_ips": [r["ip"] for r in online_list],
        }
        with open(filepath, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)

        self._refresh_scan_list()
        self.progress_var.set(
            f"Done. {online_count} online. Saved to scans/{filename}"
        )

    def _scan_cancelled(self):
        self._scanning = False
        self.scan_btn.configure(text="Start Scan")
        online = sum(1 for r in self._scan_results if r["online"])
        self.progress_var.set(f"Cancelled. {online} online IPs found before cancel.")

    # ----------------------------------------------------------
    # Compare logic
    # ----------------------------------------------------------

    def _delete_all_scans(self):
        try:
            files = [f for f in os.listdir(SCAN_DIR) if f.startswith("scan_") and f.endswith(".json")]
        except FileNotFoundError:
            files = []
        if not files:
            messagebox.showinfo("Info", "No scan files to delete.")
            return
        if not messagebox.askyesno("Confirm", f"Delete all {len(files)} scan files?"):
            return
        for f in files:
            os.remove(os.path.join(SCAN_DIR, f))
        self._refresh_scan_list()
        self.cmp1_var.set("")
        self.cmp2_var.set("")
        messagebox.showinfo("Info", f"Deleted {len(files)} scan files.")

    def _refresh_scan_list(self):
        ensure_scan_dir()
        files = sorted(
            [f for f in os.listdir(SCAN_DIR) if f.startswith("scan_") and f.endswith(".json")],
            reverse=True,
        )
        self._scan_files = files
        self.cmp1_combo["values"] = files
        self.cmp2_combo["values"] = files
        if files:
            if not self.cmp1_var.get():
                self.cmp1_var.set(files[0])
            if not self.cmp2_var.get() and len(files) >= 2:
                self.cmp2_var.set(files[1])
            elif not self.cmp2_var.get():
                self.cmp2_var.set(files[0])

    def _compare_last(self):
        if len(self._scan_files) < 2:
            messagebox.showwarning("Warning", "Need at least 2 scan results to compare.")
            return
        self.cmp1_var.set(self._scan_files[1])
        self.cmp2_var.set(self._scan_files[0])
        self._compare()

    def _compare(self):
        f1 = self.cmp1_var.get()
        f2 = self.cmp2_var.get()
        if not f1 or not f2:
            messagebox.showwarning("Warning", "Please select both scan files.")
            return

        path1 = os.path.join(SCAN_DIR, f1)
        path2 = os.path.join(SCAN_DIR, f2)

        try:
            with open(path1, "r", encoding="utf-8") as f:
                scan1 = json.load(f)
            with open(path2, "r", encoding="utf-8") as f:
                scan2 = json.load(f)
        except Exception as e:
            messagebox.showerror("Error", f"Failed to read scan file: {e}")
            return

        ips1 = set(scan1.get("online_ips", []))
        ips2 = set(scan2.get("online_ips", []))

        only_in_1 = sorted(ips1 - ips2, key=lambda x: tuple(map(int, x.split("."))))
        only_in_2 = sorted(ips2 - ips1, key=lambda x: tuple(map(int, x.split("."))))
        in_both = sorted(ips1 & ips2, key=lambda x: tuple(map(int, x.split("."))))

        lines = []
        lines.append("=" * 60)
        lines.append("  Scan Comparison Report")
        lines.append("=" * 60)
        lines.append("")
        lines.append(f"  Scan 1: {f1}")
        lines.append(f"    Time  : {scan1.get('scan_time', '?')}")
        lines.append(f"    Subnet: {scan1.get('subnet', '?')}")
        lines.append(f"    Online: {scan1.get('online_count', '?')}")
        lines.append("")
        lines.append(f"  Scan 2: {f2}")
        lines.append(f"    Time  : {scan2.get('scan_time', '?')}")
        lines.append(f"    Subnet: {scan2.get('subnet', '?')}")
        lines.append(f"    Online: {scan2.get('online_count', '?')}")
        lines.append("")

        # Disappeared IPs (target)
        lines.append("=" * 60)
        lines.append(f"  [TARGET] Online in Scan1 but OFFLINE in Scan2: {len(only_in_1)}")
        lines.append(f"  (These are likely the target IPs - disappeared after unplugging)")
        lines.append("=" * 60)
        for ip in only_in_1:
            lines.append(f"  >>> {ip}")
        lines.append("")

        # Newly appeared
        lines.append("=" * 60)
        lines.append(f"  New in Scan2 (not in Scan1): {len(only_in_2)}")
        lines.append("=" * 60)
        for ip in only_in_2:
            lines.append(f"  --- {ip}")
        lines.append("")

        # Unchanged
        lines.append(f"  Both scans (unchanged): {len(in_both)}")
        lines.append("")

        # Target summary
        if only_in_1:
            lines.append("=" * 60)
            lines.append("  TARGET IP(s) that went offline:")
            for ip in only_in_1:
                lines.append(f"    => {ip}")
            lines.append("=" * 60)

        self.result_text.configure(state=tk.NORMAL)
        self.result_text.delete("1.0", tk.END)
        self.result_text.insert("1.0", "\n".join(lines))
        self.result_text.configure(state=tk.DISABLED)


# ---- Entry point ----

def main():
    root = tk.Tk()
    ScannerApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
