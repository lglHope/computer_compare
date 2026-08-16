#!/usr/bin/env bash
# 采集硬件/OS/NUMA/磁盘/网卡快照，输出 sysinfo.json
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${EVAL_RUN_DIR:-${ROOT}/results/$(hostname)-$(date +%Y%m%dT%H%M%S)}"
mkdir -p "${RUN_DIR}/raw"
OUT="${RUN_DIR}/sysinfo.json"

python3 - <<'PY' "${OUT}" "${RUN_DIR}" "${INSTANCE_ID:-unknown}" "${ROLE:-unknown}"
import json, os, re, socket, subprocess, sys, time

out_path, run_dir, instance_id, role = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]


def run(cmd):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           universal_newlines=True, timeout=30)
        return p.stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def read_file(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


meminfo_raw = read_file("/proc/meminfo")
meminfo_filt = "\n".join(
    line for line in meminfo_raw.splitlines()
    if re.search(r"MemTotal|MemFree|MemAvailable|HugePages", line)
)

nics = []
try:
    for name in sorted(os.listdir("/sys/class/net")):
        if name == "lo":
            continue
        nics.append(name)
except OSError:
    pass

ethtool_parts = []
for n in nics:
    out = run(["ethtool", n])
    if out:
        ethtool_parts.append(f"=== {n} ===\n" + "\n".join(out.splitlines()[:20]))
ethtool_text = "\n".join(ethtool_parts)

dmesg_text = run(["dmesg", "-T"])
dmesg_hw = "\n".join(
    line for line in dmesg_text.splitlines()
    if re.search(r"error|mce|ecc|i/o error|nvme", line, re.IGNORECASE)
)[-5000:]

try:
    with open("/etc/os-release", encoding="utf-8") as f:
        os_release = f.read()
except OSError:
    os_release = ""

info = {
    "hostname": socket.gethostname(),
    "instance_id": instance_id,
    "role": role,
    "collected_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "uname": run(["uname", "-a"]).strip(),
    "os_release": os_release.strip(),
    "lscpu": run(["lscpu"]),
    "cpuinfo_flags": "",
    "meminfo": meminfo_filt,
    "numa": run(["numactl", "-H"]) or "numactl missing",
    "lsblk": run(["lsblk", "-o", "NAME,SIZE,TYPE,ROTA,MODEL,TRAN"]),
    "df": run(["df", "-hT"]),
    "nics": run(["ip", "-o", "-4", "addr", "show"]),
    "ethtool": ethtool_text,
    "dmesg_hw_errors": dmesg_hw,
}

cpuinfo = read_file("/proc/cpuinfo")
for line in cpuinfo.splitlines():
    if line.startswith("flags"):
        info["cpuinfo_flags"] = line
        break

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(info, f, indent=2, ensure_ascii=False)

raw_copy = os.path.join(run_dir, "raw", "sysinfo.json")
try:
    import shutil
    shutil.copy2(out_path, raw_copy)
except OSError:
    pass

print(f"已写入 {out_path}")
PY
