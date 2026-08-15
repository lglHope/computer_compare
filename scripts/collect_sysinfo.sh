#!/usr/bin/env bash
# 采集硬件/OS/NUMA/磁盘/网卡快照，输出 sysinfo.json
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${EVAL_RUN_DIR:-${ROOT}/results/$(hostname)-$(date +%Y%m%dT%H%M%S)}"
mkdir -p "${RUN_DIR}/raw"
OUT="${RUN_DIR}/sysinfo.json"

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

{
  echo "{"
  echo "  \"hostname\": $(hostname | json_escape),"
  echo "  \"instance_id\": $(printf '%s' "${INSTANCE_ID:-unknown}" | json_escape),"
  echo "  \"role\": $(printf '%s' "${ROLE:-unknown}" | json_escape),"
  echo "  \"collected_at\": $( (date -Iseconds 2>/dev/null || date --iso-8601=seconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ) | json_escape),"
  echo "  \"uname\": $(uname -a | json_escape),"
  echo "  \"os_release\": $( (cat /etc/os-release 2>/dev/null || true) | json_escape),"
  echo "  \"lscpu\": $(lscpu 2>/dev/null | json_escape),"
  echo "  \"cpuinfo_flags\": $( (grep -m1 '^flags' /proc/cpuinfo || true) | json_escape),"
  echo "  \"meminfo\": $( (awk '/MemTotal|MemFree|MemAvailable|HugePages/ {print}' /proc/meminfo) | json_escape),"
  echo "  \"numa\": $( (numactl -H 2>/dev/null || echo 'numactl missing') | json_escape),"
  echo "  \"lsblk\": $( (lsblk -o NAME,SIZE,TYPE,ROTA,MODEL,TRAN 2>/dev/null || true) | json_escape),"
  echo "  \"df\": $( (df -hT 2>/dev/null || true) | json_escape),"
  echo "  \"nics\": $( (ip -o -4 addr show 2>/dev/null || true) | json_escape),"
  echo "  \"ethtool\": $( (for n in $(ls /sys/class/net | grep -v lo); do echo \"=== $n ===\"; ethtool "$n" 2>/dev/null | head -n 20; done) | json_escape),"
  echo "  \"dmesg_hw_errors\": $( (dmesg -T 2>/dev/null | grep -Ei 'error|mce|ecc|i/o error|nvme' | tail -n 50 || true) | json_escape)"
  echo "}"
} > "${OUT}"

cp "${OUT}" "${RUN_DIR}/raw/" 2>/dev/null || true
echo "已写入 ${OUT}"
