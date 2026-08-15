#!/usr/bin/env python3
"""代理作业期间采样整机负载：CPU、内存、磁盘、网络。读 /proc，无需额外软件包。"""
import argparse
import json
import os
import re
import signal
import sys
import time

PHYS_DISK = re.compile(r"^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme[0-9]+n[0-9]+)$")
SKIP_NIC = re.compile(r"^(lo|docker|veth|br-|virbr|tun|tap|flannel|cni|cali|kube)")


def cpu_times():
    with open("/proc/stat") as f:
        parts = f.readline().split()
    nums = [int(x) for x in parts[1:]]
    idle = nums[3]
    iowait = nums[4] if len(nums) > 4 else 0
    return sum(nums), idle, iowait


def mem_used():
    info = {}
    with open("/proc/meminfo") as f:
        for line in f:
            bits = line.split()
            info[bits[0].rstrip(":")] = int(bits[1])
    total = info["MemTotal"]
    avail = info.get("MemAvailable")
    if avail is None:
        avail = info.get("MemFree", 0) + info.get("Buffers", 0) + info.get("Cached", 0)
    used = max(0, total - avail)
    return total / 1024.0 / 1024.0, used / 1024.0 / 1024.0


def disk_sectors():
    rows = []
    with open("/proc/diskstats") as f:
        for line in f:
            p = line.split()
            if len(p) < 10:
                continue
            name = p[2]
            if name.startswith(("loop", "ram", "sr")):
                continue
            rows.append((name, int(p[5]), int(p[9]), bool(PHYS_DISK.match(name))))
    use = [r for r in rows if r[3]] or rows
    return sum(r[1] for r in use), sum(r[2] for r in use)


def net_bytes():
    rx = tx = 0
    with open("/proc/net/dev") as f:
        for line in f:
            if ":" not in line:
                continue
            name, rest = line.split(":", 1)
            name = name.strip()
            if SKIP_NIC.match(name):
                continue
            nums = rest.split()
            rx += int(nums[0])
            tx += int(nums[8])
    return rx, tx


def loadavg():
    with open("/proc/loadavg") as f:
        a, b, c = f.read().split()[:3]
    return float(a), float(b), float(c)


def snapshot():
    total, idle, iowait = cpu_times()
    mem_total_gb, mem_used_gb = mem_used()
    rsect, wsect = disk_sectors()
    rx, tx = net_bytes()
    l1, l5, l15 = loadavg()
    return {
        "t": time.time(),
        "cpu_total": total,
        "cpu_idle": idle,
        "cpu_iowait": iowait,
        "mem_total_gb": mem_total_gb,
        "mem_used_gb": mem_used_gb,
        "disk_rsect": rsect,
        "disk_wsect": wsect,
        "net_rx": rx,
        "net_tx": tx,
        "loadavg_1m": l1,
        "loadavg_5m": l5,
        "loadavg_15m": l15,
    }


def rates(prev, cur):
    dt = cur["t"] - prev["t"]
    if dt <= 0:
        dt = 1e-6
    ctot = cur["cpu_total"] - prev["cpu_total"]
    cidl = cur["cpu_idle"] - prev["cpu_idle"]
    ciow = cur["cpu_iowait"] - prev["cpu_iowait"]
    cpu_pct = 100.0 * (1.0 - (cidl / ctot)) if ctot > 0 else 0.0
    iowait_pct = 100.0 * (ciow / ctot) if ctot > 0 else 0.0
    mem_pct = 100.0 * cur["mem_used_gb"] / cur["mem_total_gb"] if cur["mem_total_gb"] else 0.0
    return {
        "ts": cur["t"],
        "cpu_pct": round(max(0.0, min(100.0, cpu_pct)), 2),
        "iowait_pct": round(max(0.0, iowait_pct), 2),
        "mem_used_gb": round(cur["mem_used_gb"], 3),
        "mem_used_pct": round(mem_pct, 2),
        "disk_read_MBps": round(max(0.0, cur["disk_rsect"] - prev["disk_rsect"]) * 512 / dt / 1e6, 3),
        "disk_write_MBps": round(max(0.0, cur["disk_wsect"] - prev["disk_wsect"]) * 512 / dt / 1e6, 3),
        "net_rx_MBps": round(max(0.0, cur["net_rx"] - prev["net_rx"]) / dt / 1e6, 3),
        "net_tx_MBps": round(max(0.0, cur["net_tx"] - prev["net_tx"]) / dt / 1e6, 3),
        "loadavg_1m": cur["loadavg_1m"],
    }


def stats(vals):
    vals = [v for v in vals if v is not None]
    if not vals:
        return None
    srt = sorted(vals)
    p95_i = min(len(srt) - 1, int(round(0.95 * (len(srt) - 1))))
    return {
        "avg": round(sum(vals) / float(len(vals)), 3),
        "max": round(max(vals), 3),
        "min": round(min(vals), 3),
        "p95": round(srt[p95_i], 3),
    }


def write_summary(out_dir, samples, interval):
    keys = [
        "cpu_pct", "iowait_pct", "mem_used_gb", "mem_used_pct",
        "disk_read_MBps", "disk_write_MBps", "net_rx_MBps", "net_tx_MBps", "loadavg_1m",
    ]
    summary = {
        "samples": len(samples),
        "interval_sec": interval,
        "duration_sec": None,
    }
    if samples:
        summary["duration_sec"] = round(samples[-1]["ts"] - samples[0]["ts"], 3)
    for k in keys:
        summary[k] = stats([s.get(k) for s in samples])
    path = os.path.join(out_dir, "summary.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    return summary


def merge_into(json_path, summary_path):
    with open(json_path, encoding="utf-8") as f:
        data = json.load(f)
    with open(summary_path, encoding="utf-8") as f:
        data["hostload"] = json.load(f)
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def sample_loop(out_dir, interval, parent_pid):
    os.makedirs(out_dir, exist_ok=True)
    samples_path = os.path.join(out_dir, "samples.jsonl")
    stop = {"flag": False}

    def handle(signum, frame):
        stop["flag"] = True

    signal.signal(signal.SIGTERM, handle)
    signal.signal(signal.SIGINT, handle)

    prev = snapshot()
    end0 = time.time() + interval
    while time.time() < end0 and not stop["flag"]:
        try:
            time.sleep(min(0.2, max(0.0, end0 - time.time())))
        except (InterruptedError, OSError):
            break
    samples = []
    with open(samples_path, "w", encoding="utf-8") as sf:
        while not stop["flag"]:
            if parent_pid and not os.path.exists("/proc/%d" % parent_pid):
                break
            cur = snapshot()
            rec = rates(prev, cur)
            prev = cur
            samples.append(rec)
            sf.write(json.dumps(rec) + "\n")
            sf.flush()
            deadline = time.time() + interval
            while time.time() < deadline and not stop["flag"]:
                if parent_pid and not os.path.exists("/proc/%d" % parent_pid):
                    stop["flag"] = True
                    break
                remain = deadline - time.time()
                if remain <= 0:
                    break
                try:
                    time.sleep(min(0.2, remain))
                except (InterruptedError, OSError):
                    break
        try:
            cur = snapshot()
            rec = rates(prev, cur)
            samples.append(rec)
            sf.write(json.dumps(rec) + "\n")
        except Exception:
            pass
    write_summary(out_dir, samples, interval)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", help="采样输出目录")
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--parent-pid", type=int, default=0)
    ap.add_argument("--merge-into", help="把 summary 写入已有代理 JSON")
    ap.add_argument("--from", dest="summary_from", help="summary.json 路径")
    args = ap.parse_args()
    if args.merge_into:
        src = args.summary_from or os.path.join(args.out or ".", "summary.json")
        if not os.path.isfile(src) or not os.path.isfile(args.merge_into):
            print("跳过 hostload 合并：文件不存在", file=sys.stderr)
            return
        merge_into(args.merge_into, src)
        return
    if not args.out:
        raise SystemExit("需要 --out 采样目录")
    sample_loop(args.out, max(0.2, args.interval), args.parent_pid)


if __name__ == "__main__":
    main()
