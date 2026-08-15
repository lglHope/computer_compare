#!/usr/bin/env bash
# 稳定性：循环跑 OPC/Mask 代理，记录墙钟漂移与 dmesg 新增错误。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOURS="${1:-48}"
END=$(( $(date +%s) + HOURS * 3600 ))
LOG_DIR="${ROOT}/results/soak-$(date +%Y%m%dT%H%M%S)"
mkdir -p "${LOG_DIR}"
DMESG_BASE="$(dmesg 2>/dev/null | wc -l || echo 0)"
i=0
declare -a walls=()

while [[ "$(date +%s)" -lt "${END}" ]]; do
  i=$((i + 1))
  export EVAL_RUN_DIR="${LOG_DIR}/iter-${i}"
  export ROLE="${ROLE:-soak}"
  export INSTANCE_ID="${INSTANCE_ID:-soak}"
  mkdir -p "${EVAL_RUN_DIR}/proxy"
  bash "${ROOT}/scripts/run_with_hostload.sh" opc "${EVAL_RUN_DIR}/proxy/opc.json" -- \
    python3 "${ROOT}/scripts/bench_opc_proxy.py" --out "${EVAL_RUN_DIR}/proxy/opc.json"
  bash "${ROOT}/scripts/run_with_hostload.sh" mask "${EVAL_RUN_DIR}/proxy/mask.json" -- \
    python3 "${ROOT}/scripts/bench_mask_proxy.py" --out "${EVAL_RUN_DIR}/proxy/mask.json" --scratch "${SCRATCH_DIR:-/tmp}"
  wall=$(python3 -c "import json; d=json.load(open('${EVAL_RUN_DIR}/proxy/opc.json')); print(d['wall_sec'])")
  walls+=("${wall}")
  err=$(dmesg 2>/dev/null | grep -Eic 'mce|hardware error|i/o error|nvme error' || true)
  echo "$(date -Iseconds 2>/dev/null || date --iso-8601=seconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ) iter=${i} opc_wall=${wall} dmesg_hits=${err}" | tee -a "${LOG_DIR}/soak.csv"
done

python3 - <<PY "${LOG_DIR}"
import json, os, statistics, sys
log_dir = sys.argv[1]
vals = []
for line in open(os.path.join(log_dir, "soak.csv")):
    for part in line.split():
        if part.startswith("opc_wall="):
            vals.append(float(part.split("=",1)[1]))
if not vals:
    raise SystemExit("无样本")
med = statistics.median(vals)
last = statistics.median(vals[-max(1,len(vals)//5):])
drift = (last - med) / med * 100 if med else 0
out = {"samples": len(vals), "median_wall": med, "late_median_wall": last, "drift_pct": drift}
json.dump(out, open(os.path.join(log_dir, "soak_summary.json"), "w"), indent=2)
print(out)
if abs(drift) > 8:
    raise SystemExit(2)
PY
