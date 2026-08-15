#!/usr/bin/env bash
# 在命令执行期间采样整机负载，结束后写入结果 JSON 的 hostload 字段。
# 用法: bash run_with_hostload.sh <tag> <result.json> -- <command...>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:?需要 tag}"
JSON="${2:?需要结果 JSON 路径}"
shift 2
if [[ "${1:-}" == "--" ]]; then
  shift
fi
if [[ "$#" -lt 1 ]]; then
  echo "需要要执行的命令" >&2
  exit 1
fi

INTERVAL="${LOAD_SAMPLE_SEC:-1}"
RUN_DIR="${EVAL_RUN_DIR:-$(dirname "${JSON}")}"
LOAD_DIR="${RUN_DIR}/proxy/load_${TAG}"
mkdir -p "$(dirname "${JSON}")" "${LOAD_DIR}"

python3 "${ROOT}/scripts/sample_hostload.py" \
  --out "${LOAD_DIR}" \
  --interval "${INTERVAL}" \
  --parent-pid $$ &
SPID=$!

rc=0
"$@" || rc=$?

kill -TERM "${SPID}" 2>/dev/null || true
wait "${SPID}" 2>/dev/null || true

if [[ -f "${JSON}" && -f "${LOAD_DIR}/summary.json" ]]; then
  python3 "${ROOT}/scripts/sample_hostload.py" \
    --merge-into "${JSON}" \
    --from "${LOAD_DIR}/summary.json" || true
fi

exit "${rc}"
