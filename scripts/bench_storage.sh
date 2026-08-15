#!/usr/bin/env bash
# 存储：本地 scratch 顺序/随机；若设置 SHARED_FS 再测共享盘。
set -euo pipefail

RUN_DIR="${EVAL_RUN_DIR:?请先由 run_suite.sh 设置 EVAL_RUN_DIR}"
SCRATCH="${SCRATCH_DIR:-/scratch}"
SHARED="${SHARED_FS:-}"
SIZE="${FIO_SIZE:-32G}"
RUNTIME="${FIO_RUNTIME_SEC:-60}"
OUT_DIR="${RUN_DIR}/storage"
mkdir -p "${OUT_DIR}"

if ! command -v fio >/dev/null 2>&1; then
  echo "未安装 fio，跳过存储测试" >&2
  echo '{"skipped": true}' > "${OUT_DIR}/storage.json"
  exit 0
fi

run_fio() {
  local name="$1"
  local dir="$2"
  mkdir -p "${dir}"
  local prefix="${dir}/fio_${name}"
  fio --name="${name}_seqread" --directory="${dir}" --rw=read --bs=1m --size="${SIZE}" \
      --runtime="${RUNTIME}" --time_based=1 --iodepth=32 --numjobs=4 --direct=1 \
      --group_reporting --output-format=json --output="${OUT_DIR}/${name}_seqread.json"
  fio --name="${name}_randread" --directory="${dir}" --rw=randread --bs=4k --size="${SIZE}" \
      --runtime="${RUNTIME}" --time_based=1 --iodepth=32 --numjobs=8 --direct=1 \
      --group_reporting --output-format=json --output="${OUT_DIR}/${name}_randread.json"
  rm -f "${dir}"/fio_* "${dir}"/"${name}"_* 2>/dev/null || true
}

if [[ -d "${SCRATCH}" ]]; then
  run_fio local "${SCRATCH}/instance-eval.$$"
  rm -rf "${SCRATCH}/instance-eval.$$"
else
  echo "SCRATCH_DIR=${SCRATCH} 不存在，改用 /tmp"
  run_fio local "/tmp/instance-eval.$$"
  rm -rf "/tmp/instance-eval.$$"
fi

if [[ -n "${SHARED}" && -d "${SHARED}" ]]; then
  run_fio shared "${SHARED}/instance-eval.$$"
  rm -rf "${SHARED}/instance-eval.$$"
fi

python3 - <<'PY' "${OUT_DIR}"
import json, glob, os, sys
out_dir = sys.argv[1]
summary = {}
for path in glob.glob(os.path.join(out_dir, "*.json")):
    if os.path.basename(path) == "storage.json":
        continue
    data = json.load(open(path))
    jobs = data.get("jobs") or []
    if not jobs:
        continue
    j = jobs[0]
    read = j.get("read") or {}
    key = os.path.splitext(os.path.basename(path))[0]
    summary[key] = {
        "bw_bytes": read.get("bw_bytes"),
        "iops": read.get("iops"),
        "lat_ns_p99": (read.get("clat_ns") or read.get("lat_ns") or {}).get("percentile", {}).get("99.000000"),
    }
json.dump(summary, open(os.path.join(out_dir, "storage.json"), "w"), indent=2)
print(json.dumps(summary, indent=2))
PY
