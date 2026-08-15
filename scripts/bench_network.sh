#!/usr/bin/env bash
# 网络：本机回环仅作连通性；对端 IPERF_SERVER 存在时测真实带宽。
set -euo pipefail

RUN_DIR="${EVAL_RUN_DIR:?请先由 run_suite.sh 设置 EVAL_RUN_DIR}"
SERVER="${IPERF_SERVER:-}"
SEC="${IPERF_SEC:-30}"
OUT_DIR="${RUN_DIR}/network"
mkdir -p "${OUT_DIR}"

python3 - <<PY "${OUT_DIR}" "${SERVER}" "${SEC}"
import json, os, socket, subprocess, sys, time
out_dir, server, sec = sys.argv[1], sys.argv[2], int(sys.argv[3])
summary = {"server": server or None}

# 许可证/DNS 探测可选
lic = os.environ.get("LICENSE_PROBE", "")
if lic:
    host = lic.split("@")[-1] if "@" in lic else lic.split(":")[0]
    port = 27000
    if ":" in host:
        host, port_s = host.rsplit(":", 1)
        port = int(port_s)
    t0 = time.perf_counter()
    ok = False
    try:
        s = socket.create_connection((host, port), timeout=3)
        s.close()
        ok = True
    except OSError as e:
        summary["license_error"] = str(e)
    summary["license_probe_ms"] = round((time.perf_counter() - t0) * 1000, 2)
    summary["license_ok"] = ok

if not server:
    summary["skipped"] = True
    summary["reason"] = "未设置 IPERF_SERVER，跳过 iperf3"
else:
    r = subprocess.run(
        ["iperf3", "-c", server, "-t", str(sec), "-J"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    open(os.path.join(out_dir, "iperf3.json"), "w").write(r.stdout)
    if r.returncode == 0:
        data = json.loads(r.stdout)
        end = data.get("end", {})
        sender = (end.get("sum_sent") or end.get("sum") or {})
        summary["bits_per_second"] = sender.get("bits_per_second")
        summary["retransmits"] = sender.get("retransmits")
    else:
        summary["iperf_error"] = r.stderr[-500:]

json.dump(summary, open(os.path.join(out_dir, "network.json"), "w"), indent=2)
print(json.dumps(summary, indent=2))
PY
