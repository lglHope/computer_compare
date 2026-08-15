#!/usr/bin/env bash
# CPU：单核（1 线程绑核）+ 多核（满逻辑核）+ 扩展比。
set -euo pipefail

RUN_DIR="${EVAL_RUN_DIR:?请先由 run_suite.sh 设置 EVAL_RUN_DIR}"
MAX_PRIME="${1:-20000}"
REPEATS="${2:-3}"
NPROC="$(nproc)"
OUT_DIR="${RUN_DIR}/cpu"
mkdir -p "${OUT_DIR}"

python3 - <<'PY' "${OUT_DIR}" "${NPROC}" "${MAX_PRIME}" "${REPEATS}"
import json, os, re, shutil, subprocess, sys

out_dir, nproc, max_prime, repeats = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
has_taskset = shutil.which("taskset") is not None
threads_list = sorted(set([1, max(1, nproc // 4), max(1, nproc // 2), nproc]))
results = []


def run_sysbench(threads):
    cmd = ["sysbench", "cpu", "--cpu-max-prime=%s" % max_prime, "--threads=%d" % threads, "run"]
    # 单核：绑到 CPU0，避免调度器来回迁移抬高/压低成绩
    if threads == 1 and has_taskset:
        cmd = ["taskset", "-c", "0"] + cmd
    p = subprocess.run(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, check=False)
    return p.stdout + p.stderr, p.returncode


for t in threads_list:
    for i in range(1, repeats + 1):
        text, rc = run_sysbench(t)
        open(os.path.join(out_dir, "sysbench_t%d_r%d.txt" % (t, i)), "w").write(text)
        m = re.search(r"events per second:\s*([0-9.]+)", text)
        eps = float(m.group(1)) if m else None
        results.append({"threads": t, "repeat": i, "events_per_sec": eps, "rc": rc})


def median(vals):
    vals = sorted(v for v in vals if v is not None)
    if not vals:
        return None
    return vals[len(vals) // 2]


full = [r["events_per_sec"] for r in results if r["threads"] == nproc]
one = [r["events_per_sec"] for r in results if r["threads"] == 1]
single = median(one)
multi = median(full)
summary = {
    "nproc": nproc,
    "max_prime": int(max_prime),
    "single_core_pinned": bool(has_taskset),
    "runs": results,
    "single_core_eps_median": single,
    "multicore_eps_median": multi,
    "single_thread_eps_median": single,
    "full_thread_eps_median": multi,
}
if single and multi and nproc:
    summary["parallel_efficiency"] = multi / (single * nproc)
open(os.path.join(out_dir, "cpu.json"), "w").write(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
PY
