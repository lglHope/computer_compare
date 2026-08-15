#!/bin/bash
# Slurm 提交：在独占节点上跑套件。按集群分区名修改。
#   sbatch scripts/submit_slurm.sh baseline
#   sbatch scripts/submit_slurm.sh candidate

#SBATCH -J inst-eval
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH -t 06:00:00
#SBATCH -o logs/%x-%j.out
#SBATCH -e logs/%x-%j.err

set -euo pipefail
ROLE="${1:-${ROLE:-candidate}}"
ROOT="${EVAL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
mkdir -p "${ROOT}/logs" "${ROOT}/results"
export ROLE
export INSTANCE_ID="${INSTANCE_ID:-${SLURM_JOB_PARTITION:-slurm}-${SLURM_JOB_ID:-manual}}"
export SCRATCH_DIR="${SCRATCH_DIR:-${SLURM_TMPDIR:-/scratch}}"
cd "${ROOT}"
bash scripts/run_suite.sh
