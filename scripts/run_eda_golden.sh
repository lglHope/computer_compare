#!/usr/bin/env bash
# 按 workloads/golden_cases.yaml 跑真实 EDA 金标。需本机已安装工具与许可证。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${EVAL_RUN_DIR:?请先由 run_suite.sh 设置 EVAL_RUN_DIR 或 export}"
CASES="${ROOT}/workloads/golden_cases.yaml"
EDA_DIR="${RUN_DIR}/eda"
mkdir -p "${EDA_DIR}"

python3 - <<'PY' "${ROOT}" "${CASES}" "${EDA_DIR}"
import json, os, subprocess, sys, time

root, cases_path, eda_dir = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    import yaml
except ImportError:
    print("需要 PyYAML: pip3 install pyyaml", file=sys.stderr)
    sys.exit(1)

doc = yaml.safe_load(open(cases_path, encoding="utf-8"))
results = []
for case in doc.get("cases") or []:
    if not case.get("enabled"):
        results.append({"id": case.get("id"), "name": case.get("name"), "skipped": True})
        continue
    cid = case["id"]
    log_dir = os.path.join(eda_dir, cid)
    os.makedirs(log_dir, exist_ok=True)
    workdir = case.get("workdir") or log_dir
    timeout = int(case.get("timeout_sec") or 86400)
    env = os.environ.copy()
    env["EVAL_RUN_DIR"] = os.environ.get("EVAL_RUN_DIR", "")
    env["NPROC"] = str(os.cpu_count() or 1)

    def run_block(name, script):
        t0 = time.perf_counter()
        p = subprocess.run(
            ["bash", "-lc", script],
            cwd=workdir,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            timeout=timeout,
        )
        open(os.path.join(log_dir, f"{name}.stdout"), "w").write(p.stdout)
        open(os.path.join(log_dir, f"{name}.stderr"), "w").write(p.stderr)
        return p.returncode, time.perf_counter() - t0

    rec = {"id": cid, "name": case.get("name"), "domain": case.get("domain"), "skipped": False}
    try:
        rc, wall = run_block("command", case["command"])
        rec["command_rc"] = rc
        rec["wall_sec"] = wall
        if rc == 0:
            vrc, _ = run_block("verify", case.get("verify") or "exit 0")
            rec["verify_rc"] = vrc
            rec["correctness_pass"] = vrc == 0
        else:
            rec["correctness_pass"] = False
    except subprocess.TimeoutExpired:
        rec["error"] = "timeout"
        rec["correctness_pass"] = False
    results.append(rec)

out = os.path.join(eda_dir, "eda.json")
json.dump({"cases": results}, open(out, "w"), indent=2)
print(json.dumps({"cases": results}, indent=2))
failed = [r for r in results if not r.get("skipped") and not r.get("correctness_pass")]
sys.exit(1 if failed else 0)
PY
