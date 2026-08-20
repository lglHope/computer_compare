#!/usr/bin/env bash
# 单机完整套件：系统信息 + CPU/内存/存储/网络 + OPC/Mask 代理。
# 用法：
#   ROLE=baseline INSTANCE_ID=ecs.c7.16xlarge bash scripts/run_suite.sh
#   ROLE=candidate INSTANCE_ID=ecs.c8i.16xlarge bash scripts/run_suite.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

ROLE="${ROLE:-unknown}"
INSTANCE_ID="${INSTANCE_ID:-$(hostname)}"
STAMP="$(date +%Y%m%dT%H%M%S)"
export EVAL_RUN_DIR="${EVAL_RUN_DIR:-${ROOT}/results/${ROLE}-${INSTANCE_ID}-${STAMP}}"
mkdir -p "${EVAL_RUN_DIR}"

# 从 eval.yaml 读代理参数（无 PyYAML 时使用默认值）
eval "$(python3 - <<PY
import os
p = os.path.join(r"${ROOT}", "config", "eval.yaml")
try:
    import yaml
    d = yaml.safe_load(open(p, encoding="utf-8"))
    mb = d.get("microbench") or {}
    px = (d.get("proxy") or {})
    opc = px.get("opc") or {}
    mask = px.get("mask") or {}
    env = d.get("environment") or {}
    print(f"export CPU_MAX_PRIME={mb.get('cpu_max_prime', 20000)}")
    print(f"export STREAM_ARRAY_N={mb.get('stream_array_n', 80000000)}")
    print(f"export FIO_SIZE={mb.get('fio_size', '32G')}")
    print(f"export FIO_RUNTIME_SEC={mb.get('fio_runtime_sec', 60)}")
    print(f"export IPERF_SEC={mb.get('iperf_sec', 30)}")
    print(f"export REPEATS={mb.get('repeats', 3)}")
    print(f"export OPC_GRID={opc.get('grid', 2048)}")
    print(f"export OPC_ITERS={opc.get('iterations', 20)}")
    print(f"export OPC_PROCS={opc.get('processes', 0)}")
    print(f"export MASK_FILE_GB={mask.get('file_gb', 8)}")
    print(f"export MASK_BLOCK_MB={mask.get('block_mb', 64)}")
    print(f"export MASK_ROUNDS={mask.get('checksum_rounds', 2)}")
    print(f"export LOAD_SAMPLE_SEC={px.get('load_sample_sec', 1)}")
    print(f"export SCRATCH_DIR={env.get('scratch', '/tmp')}")
    print(f"export SHARED_FS={env.get('shared_fs', '')}")
    lic = env.get('license_server', '')
    print(f"export LICENSE_PROBE={lic}")
except Exception:
    print("export CPU_MAX_PRIME=20000")
    print("export STREAM_ARRAY_N=80000000")
    print("export FIO_SIZE=32G")
    print("export FIO_RUNTIME_SEC=60")
    print("export IPERF_SEC=30")
    print("export REPEATS=3")
    print("export OPC_GRID=1536")
    print("export OPC_ITERS=15")
    print("export OPC_PROCS=0")
    print("export MASK_FILE_GB=8")
    print("export MASK_BLOCK_MB=64")
    print("export MASK_ROUNDS=2")
    print("export LOAD_SAMPLE_SEC=1")
    print("export SCRATCH_DIR=/tmp")
    print("export SHARED_FS=")
    print("export LICENSE_PROBE=")
PY
)"

export ROLE INSTANCE_ID
export CPU_MAX_PRIME STREAM_ARRAY_N FIO_SIZE FIO_RUNTIME_SEC IPERF_SEC REPEATS
export OPC_GRID OPC_ITERS OPC_PROCS MASK_FILE_GB MASK_BLOCK_MB MASK_ROUNDS
export SCRATCH_DIR SHARED_FS LICENSE_PROBE LOAD_SAMPLE_SEC

# 若已配置共享存储（NFS/并行文件系统），则优先用它作为业务工作目录；否则退回 scratch 或 /tmp
if [[ -n "${SHARED_FS}" && -d "${SHARED_FS}" ]]; then
  export WORK_DIR="${SHARED_FS}"
else
  export WORK_DIR="${SCRATCH_DIR:-/tmp}"
fi

if [[ "${SMOKE:-0}" == "1" ]]; then
  echo ">>> 试跑 SMOKE=1：缩小规模，只验证流程能出数"
  export CPU_MAX_PRIME=5000
  export STREAM_ARRAY_N=2000000
  export FIO_SIZE=256M
  export FIO_RUNTIME_SEC=8
  export REPEATS=1
  export OPC_GRID=256
  export OPC_ITERS=4
  export MASK_FILE_GB=1
  export MASK_ROUNDS=1
  export WORK_DIR="${WORK_DIR:-/tmp}"
fi

check_disk_space() {
  local dir="$1"
  local need_gb="$2"
  local label="$3"
  [[ -d "${dir}" ]] || { echo ">>> 警告: ${label} 目录 ${dir} 不存在，跳过空间检查" >&2; return 0; }
  local avail_kb
  avail_kb=$(df -Pk "${dir}" 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ -z "${avail_kb}" ]]; then
    echo ">>> 警告: 无法获取 ${dir} 的可用空间，跳过检查" >&2
    return 0
  fi
  local avail_gb=$(( avail_kb / 1024 / 1024 ))
  if [[ "${avail_gb}" -lt "${need_gb}" ]]; then
    echo ">>> 错误: ${label} (${dir}) 可用空间约 ${avail_gb}GB，至少需要 ${need_gb}GB" >&2
    echo ">>> 请在 config/eval.yaml 中改 shared_fs/scratch，或清理磁盘后重试" >&2
    exit 1
  fi
  echo ">>> ${label} (${dir}) 可用空间约 ${avail_gb}GB，需要约 ${need_gb}GB，OK"
}

# === 测试开关 ===
# SKIP_STORAGE=1 跳过存储fio测试（默认跳过，设置0恢复）
# SKIP_PROXY=0   运行OPC/Mask代理（默认运行，设置1跳过代理只跑真实金标）
# 说明：如果workloads/golden_cases.yaml中有enabled=true的用例，会自动运行真实金标
SKIP_STORAGE="${SKIP_STORAGE:-1}"
SKIP_PROXY="${SKIP_PROXY:-0}"

# 自动检测是否有启用的金标用例
HAS_GOLDEN=0
if python3 -c "
import yaml
doc = yaml.safe_load(open('${ROOT}/workloads/golden_cases.yaml', encoding='utf-8'))
for c in doc.get('cases') or []:
    if c.get('enabled'):
        exit(0)
exit(1)
" 2>/dev/null; then
  HAS_GOLDEN=1
fi

fio_gb=1
case "${FIO_SIZE}" in
  *G) fio_gb="${FIO_SIZE%G}" ;;
  *M) fio_gb=1 ;;
  *) fio_gb=1 ;;
esac

# 空间需求计算
need_work_gb=5
need_run_gb=2
space_parts=""
if [[ "${SKIP_STORAGE}" == "0" ]]; then
  fio_peak_gb=$(( fio_gb * 8 ))
  need_work_gb=$(( need_work_gb + fio_peak_gb ))
  space_parts="${space_parts}fio峰值 ${fio_peak_gb}GB, "
fi
if [[ "${SKIP_PROXY}" == "0" ]]; then
  mask_peak_gb=$(( MASK_FILE_GB * 2 ))
  if [[ ${mask_peak_gb} -gt ${need_work_gb} || ${need_work_gb} -eq 5 ]]; then
    need_work_gb=$(( mask_peak_gb + 5 ))
  fi
  space_parts="${space_parts}Mask峰值 ${mask_peak_gb}GB, "
fi
echo ">>> 空间需求估算: ${space_parts}工作目录需要 ${need_work_gb}GB"
if [[ "${HAS_GOLDEN}" == "1" ]]; then
  echo ">>> 检测到已启用的真实EDA金标用例，将在微基准后自动运行"
fi
check_disk_space "${WORK_DIR}" "${need_work_gb}" "工作目录"
check_disk_space "${EVAL_RUN_DIR}" "${need_run_gb}" "结果目录"

echo "EVAL_RUN_DIR=${EVAL_RUN_DIR}"
echo "ROLE=${ROLE} INSTANCE_ID=${INSTANCE_ID}"
echo

echo "======== [1/7] 采集机器规格（CPU/内存/磁盘/网卡） ========"
bash "${ROOT}/scripts/collect_sysinfo.sh"
echo

echo "======== [2/7] CPU：单核 + 多核 ========"
bash "${ROOT}/scripts/bench_cpu.sh" "${CPU_MAX_PRIME}" "${REPEATS}"
echo

echo "======== [3/7] 内存带宽：单核 STREAM + 整机 STREAM ========"
bash "${ROOT}/scripts/bench_memory.sh" "${STREAM_ARRAY_N}"
echo

if [[ "${SKIP_STORAGE}" == "0" ]]; then
echo "======== [4/7] 存储：本地盘或共享盘 顺序读/随机读 ========"
bash "${ROOT}/scripts/bench_storage.sh"
echo
else
mkdir -p "${EVAL_RUN_DIR}/storage"
echo '{"skipped": true, "reason": "存储测试已跳过，设置 SKIP_STORAGE=0 可恢复"}' > "${EVAL_RUN_DIR}/storage/storage.json"
fi

echo "======== [5/7] 网络：未设置 IPERF_SERVER 时只做连通性并跳过 iperf3 ========"
bash "${ROOT}/scripts/bench_network.sh"
echo

mkdir -p "${EVAL_RUN_DIR}/proxy"
if [[ "${SKIP_PROXY}" == "0" ]]; then
echo "======== [6/7] OPC 代理（计算+内存带宽形态），同时采样整机负载 ========"
bash "${ROOT}/scripts/run_with_hostload.sh" opc "${EVAL_RUN_DIR}/proxy/opc.json" -- \
  python3 "${ROOT}/scripts/bench_opc_proxy.py" \
    --grid "${OPC_GRID}" --iterations "${OPC_ITERS}" --processes "${OPC_PROCS}" \
    --out "${EVAL_RUN_DIR}/proxy/opc.json"
echo

echo "======== [7/7] Mask 代理（大文件读写形态），同时采样整机负载 ========"
bash "${ROOT}/scripts/run_with_hostload.sh" mask "${EVAL_RUN_DIR}/proxy/mask.json" -- \
  python3 "${ROOT}/scripts/bench_mask_proxy.py" \
    --file-gb "${MASK_FILE_GB}" --block-mb "${MASK_BLOCK_MB}" --rounds "${MASK_ROUNDS}" \
    --scratch "${WORK_DIR}" \
    --out "${EVAL_RUN_DIR}/proxy/mask.json"
echo
else
echo '{"skipped": true, "reason": "代理测试已跳过（使用真实EDA金标），设置 SKIP_PROXY=0 可恢复"}' > "${EVAL_RUN_DIR}/proxy/opc.json"
echo '{"skipped": true, "reason": "代理测试已跳过（使用真实EDA金标），设置 SKIP_PROXY=0 可恢复"}' > "${EVAL_RUN_DIR}/proxy/mask.json"
echo "======== [6/7][7/7] OPC/Mask代理已跳过，将使用真实金标 ========"
echo
fi

if [[ "${HAS_GOLDEN}" == "1" || "${RUN_EDA_GOLDEN:-0}" == "1" ]]; then
  echo "======== 运行真实 EDA 金标用例 ========"
  bash "${ROOT}/scripts/run_eda_golden.sh" || true
  echo
fi

python3 - <<PY
import json, os, glob
run = os.environ["EVAL_RUN_DIR"]
summary = {
    "role": os.environ.get("ROLE"),
    "instance_id": os.environ.get("INSTANCE_ID"),
    "run_dir": run,
}
def load(rel):
    p = os.path.join(run, rel)
    if os.path.isfile(p):
        return json.load(open(p, encoding="utf-8"))
    return None
summary["sysinfo_present"] = load("sysinfo.json") is not None
summary["cpu"] = load("cpu/cpu.json")
summary["memory"] = load("memory/memory.json")
summary["storage"] = load("storage/storage.json")
summary["network"] = load("network/network.json")
summary["opc_proxy"] = load("proxy/opc.json")
summary["mask_proxy"] = load("proxy/mask.json")
summary["eda"] = load("eda/eda.json")
path = os.path.join(run, "summary.json")
json.dump(summary, open(path, "w", encoding="utf-8"), indent=2)
print("汇总已写入", path)
PY

if [[ -f "${ROOT}/scripts/print_summary.py" ]]; then
  python3 "${ROOT}/scripts/print_summary.py" "${EVAL_RUN_DIR}/summary.json" || true
fi

echo "本机测试完成: ${EVAL_RUN_DIR}/summary.json"
echo "用中文再看一遍： bash scripts/start.sh show ${EVAL_RUN_DIR}"
