#!/usr/bin/env bash
# 小白入口：安装 / 试跑 / 正式跑 / 看结果 / 对比。
# 用法见：bash scripts/start.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

usage() {
  cat <<'EOF'

========== 机型评测：按顺序做这 4 步 ==========

第 1 步  安装软件（每台机器做一次，需要管理员）
         sudo bash scripts/start.sh install

第 2 步  先试跑（几分钟，确认能出结果；虚机建议先做这步）
         bash scripts/start.sh smoke

第 3 步  正式测试
         旧机型上：  bash scripts/start.sh run baseline
         新机型上：  bash scripts/start.sh run candidate

第 4 步  把两台机器 results/ 目录拷到一起后对比
         bash scripts/start.sh compare \
           results/旧机那次目录/summary.json \
           results/新机那次目录/summary.json

其它：
         bash scripts/start.sh list              列出已有结果
         bash scripts/start.sh show <目录>       用中文打印一次结果摘要
         bash scripts/start.sh help              显示本说明

详细说明（每步会看到什么）：docs/HANDBOOK.md
结果长什么样：              docs/RESULT_DEMO.md

EOF
}

need_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "找不到 python3。请先执行： sudo bash scripts/start.sh install" >&2
    exit 1
  fi
}

cmd="${1:-help}"
case "${cmd}" in
  help|-h|--help)
    usage
    ;;
  install)
    echo ">>> 开始安装依赖（CentOS 7 可能要几分钟，yum 会刷很多包名，属正常）"
    echo ">>> 成功结尾应看到：bootstrap 完成，且 python3/gcc/sysbench/fio 为 OK"
    echo
    bash "${ROOT}/scripts/bootstrap.sh"
    echo
    echo ">>> 安装结束。下一步："
    echo "    bash scripts/start.sh smoke"
    ;;
  smoke)
    need_python
    echo ">>> 试跑模式：缩小 CPU/内存/磁盘/Mask 文件，几分钟内应跑完"
    echo ">>> 角色记为 smoke，结果在 results/smoke-主机名-时间/"
    echo
    export SMOKE=1
    export ROLE="${ROLE:-smoke}"
    export INSTANCE_ID="${INSTANCE_ID:-$(hostname)}"
    bash "${ROOT}/scripts/run_suite.sh"
    echo
    echo ">>> 试跑结束。用下面命令看中文摘要（把路径换成上面打印的目录）："
    echo "    bash scripts/start.sh list"
    echo "    bash scripts/start.sh show results/最新那个目录"
    echo ">>> 确认没报错后，再在旧机/新机上分别："
    echo "    bash scripts/start.sh run baseline"
    echo "    bash scripts/start.sh run candidate"
    ;;
  run)
    need_python
    ROLE_ARG="${2:-}"
    if [[ -z "${ROLE_ARG}" ]]; then
      echo "请指定角色：baseline（旧机）或 candidate（新机）" >&2
      echo "例如： bash scripts/start.sh run baseline" >&2
      exit 1
    fi
    if [[ "${ROLE_ARG}" != "baseline" && "${ROLE_ARG}" != "candidate" ]]; then
      echo "角色只能是 baseline 或 candidate，你输入的是：${ROLE_ARG}" >&2
      exit 1
    fi
    export ROLE="${ROLE_ARG}"
    export INSTANCE_ID="${INSTANCE_ID:-$(hostname)}"
    echo ">>> 正式测试  ROLE=${ROLE}  INSTANCE_ID=${INSTANCE_ID}"
    echo ">>> 全程可能几十分钟到数小时（Mask 默认写约 16GB 文件）。不要中途 Ctrl+C。"
    echo ">>> 屏幕上会按 [1/7]…[7/7] 往下走，最后一行是「本机测试完成」。"
    echo
    bash "${ROOT}/scripts/run_suite.sh"
    echo
    echo ">>> 本机测完。请保存上面的结果目录，拷到做对比的那台 Linux 上。"
    echo "    bash scripts/start.sh list"
    echo "    bash scripts/start.sh show results/刚才那个目录"
    ;;
  list)
    echo ">>> results/ 下已有的测试目录："
    if [[ ! -d "${ROOT}/results" ]] || [[ -z "$(ls -A "${ROOT}/results" 2>/dev/null || true)" ]]; then
      echo "    （还没有。请先 smoke 或 run）"
      exit 0
    fi
    ls -1dt "${ROOT}/results"/*/ 2>/dev/null | while read -r d; do
      sum="${d}summary.json"
      mark="缺 summary.json"
      [[ -f "${sum}" ]] && mark="有 summary.json"
      echo "    ${d}   [${mark}]"
    done
    echo
    echo ">>> 看摘要： bash scripts/start.sh show <上面某一目录>"
    ;;
  show)
    need_python
    DIR="${2:-}"
    if [[ -z "${DIR}" ]]; then
      echo "请带上结果目录。先执行： bash scripts/start.sh list" >&2
      exit 1
    fi
    if [[ -f "${DIR}" && "${DIR}" == *summary.json ]]; then
      SUM="${DIR}"
    else
      SUM="${DIR%/}/summary.json"
    fi
    if [[ ! -f "${SUM}" ]]; then
      echo "找不到 ${SUM}" >&2
      exit 1
    fi
    python3 "${ROOT}/scripts/print_summary.py" "${SUM}"
    ;;
  compare)
    need_python
    BASE="${2:-}"
    CAND="${3:-}"
    if [[ -z "${BASE}" || -z "${CAND}" ]]; then
      echo "需要两个 summary.json 路径（旧机、新机各一份）。" >&2
      echo "先 bash scripts/start.sh list 查看目录。" >&2
      exit 1
    fi
    mkdir -p "${ROOT}/results"
    OUT="${ROOT}/results/compare_report.md"
    echo ">>> 对比旧机 vs 新机，报告写到 ${OUT}"
    python3 "${ROOT}/scripts/compare_report.py" \
      --baseline "${BASE}" \
      --candidate "${CAND}" \
      --config "${ROOT}/config/eval.yaml" \
      --gates "${ROOT}/config/gates.yaml" \
      --out "${OUT}"
    echo
    echo ">>> 用 less 或 cat 打开报告："
    echo "    less ${OUT}"
    echo "样例说明见 docs/RESULT_DEMO.md"
    ;;
  *)
    echo "不认识的命令：${cmd}" >&2
    usage
    exit 1
    ;;
esac
