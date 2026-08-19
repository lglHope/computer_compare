#!/usr/bin/env bash
# 存储：若已配置共享存储则优先测它；否则测本地临时盘；若设置 SHARED_FS 再额外测共享盘。
set -euo pipefail

RUN_DIR="${EVAL_RUN_DIR:?请先由 run_suite.sh 设置 EVAL_RUN_DIR}"
WORK_DIR="${WORK_DIR:-${SCRATCH_DIR:-/tmp}}"
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

CLEANUP_DIRS=()

cleanup() {
  local d
  for d in "${CLEANUP_DIRS[@]:-}"; do
    [[ -n "${d}" && -d "${d}" ]] && rm -rf -- "${d}" 2>/dev/null || true
  done
}
trap cleanup EXIT

run_fio() {
  local name="$1"
  local dir="$2"
  mkdir -p "${dir}"
  CLEANUP_DIRS+=("${dir}")
  local rc=0
  echo "  - 顺序读 (numjobs=4, bs=1m, size=${SIZE})"
  fio --name="${name}_seqread" --directory="${dir}" --rw=read --bs=1m --size="${SIZE}" \
      --runtime="${RUNTIME}" --time_based=1 --iodepth=32 --numjobs=4 --direct=1 \
      --group_reporting --output-format=json --output="${OUT_DIR}/${name}_seqread.json" || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    echo "  fio ${name}_seqread 失败 (rc=${rc})，可能是磁盘空间不足" >&2
  fi
  # 顺序读完成后先清理文件，避免随机读时空间翻倍
  rm -f "${dir}"/${name}_seqread.* 2>/dev/null || true
  echo "  - 随机读 (numjobs=8, bs=4k, size=${SIZE})"
  fio --name="${name}_randread" --directory="${dir}" --rw=randread --bs=4k --size="${SIZE}" \
      --runtime="${RUNTIME}" --time_based=1 --iodepth=32 --numjobs=8 --direct=1 \
      --group_reporting --output-format=json --output="${OUT_DIR}/${name}_randread.json" || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    echo "  fio ${name}_randread 失败 (rc=${rc})" >&2
  fi
  return "${rc}"
}

overall_rc=0

if [[ -d "${WORK_DIR}" ]]; then
  echo ">>> 测试工作目录 (${WORK_DIR}) 存储性能"
  run_fio workdir "${WORK_DIR}/instance-eval.$$" || overall_rc=$?
else
  echo "WORK_DIR=${WORK_DIR} 不存在，改用 /tmp"
  run_fio workdir "/tmp/instance-eval.$$" || overall_rc=$?
fi

if [[ -n "${SHARED}" && -d "${SHARED}" && "${SHARED}" != "${WORK_DIR}" ]]; then
  echo ">>> 测试共享存储 (${SHARED}) 存储性能"
  run_fio shared "${SHARED}/instance-eval.$$" || overall_rc=$?
fi

cleanup
trap - EXIT

python3 - <<'PY' "${OUT_DIR}"
import json, glob, os, sys
out_dir = sys.argv[1]
summary = {}
errors = []
for path in sorted(glob.glob(os.path.join(out_dir, "*.json"))):
    if os.path.basename(path) == "storage.json":
        continue
    try:
        data = json.load(open(path))
    except Exception as e:
        errors.append(f"{os.path.basename(path)}: JSON解析失败 {e}")
        continue
    jobs = data.get("jobs") or []
    if not jobs:
        errors.append(f"{os.path.basename(path)}: 无jobs数据（fio可能被中断或空间不足）")
        continue
    j = jobs[0]
    read = j.get("read") or {}
    key = os.path.splitext(os.path.basename(path))[0]
    summary[key] = {
        "bw_bytes": read.get("bw_bytes"),
        "iops": read.get("iops"),
        "lat_ns_p99": (read.get("clat_ns") or read.get("lat_ns") or {}).get("percentile", {}).get("99.000000"),
    }
if errors:
    print("fio结果警告:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
json.dump(summary, open(os.path.join(out_dir, "storage.json"), "w"), indent=2)
print(json.dumps(summary, indent=2))
PY

exit "${overall_rc}"
