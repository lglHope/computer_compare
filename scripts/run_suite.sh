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

echo "EVAL_RUN_DIR=${EVAL_RUN_DIR}"
echo "ROLE=${ROLE} INSTANCE_ID=${INSTANCE_ID}"
echo "结果将全部写入该目录。下面 7 步按顺序执行。"
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

echo "======== [4/7] 存储：本地盘或共享盘 顺序读/随机读 ========"
bash "${ROOT}/scripts/bench_storage.sh"
echo

echo "======== [5/7] 网络：未设置 IPERF_SERVER 时只做连通性并跳过 iperf3 ========"
bash "${ROOT}/scripts/bench_network.sh"
echo

mkdir -p "${EVAL_RUN_DIR}/proxy"

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

if [[ "${RUN_EDA_GOLDEN:-0}" == "1" ]]; then
  bash "${ROOT}/scripts/run_eda_golden.sh" || true
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
