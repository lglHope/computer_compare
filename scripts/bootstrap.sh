#!/usr/bin/env bash
# 在待测 Linux 节点安装评测依赖。
# 支持 CentOS/RHEL 7（yum + vault）、Rocky/RHEL 8+（dnf）、Ubuntu/Debian（apt）。
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行" >&2
  exit 1
fi

PKGS_COMMON=(
  sysstat numactl pciutils dmidecode lshw ethtool iproute
  fio iperf3 sysbench stress-ng
  python3 python3-pip
  gcc make
  jq tar gzip which
)

SCRATCH_DIR="${SCRATCH_DIR:-/tmp}"

os_id() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${ID:-unknown}"
  else
    printf 'unknown'
  fi
}

os_major() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${VERSION_ID%%.*}"
  else
    printf ''
  fi
}

centos7_use_vault() {
  local repo changed=0
  shopt -s nullglob
  for repo in /etc/yum.repos.d/CentOS-*.repo; do
    if grep -qE '^mirrorlist=|^#baseurl=http://mirror.centos.org' "${repo}" 2>/dev/null; then
      sed -i.bak-instance-eval \
        -e 's|^mirrorlist=|#mirrorlist=|g' \
        -e 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' \
        "${repo}"
      changed=1
    fi
  done
  shopt -u nullglob
  if [[ "${changed}" -eq 1 ]]; then
    echo "已将 CentOS 7 仓库切换到 vault.centos.org（官方源已下线）"
    yum clean all || true
  fi
}

install_epel7() {
  yum install -y epel-release && return 0
  yum install -y \
    https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/e/epel-release-7-14.noarch.rpm \
    && return 0
  echo "警告: EPEL 安装失败，fio/iperf3/sysbench 可能缺失" >&2
  return 0
}

install_el7() {
  centos7_use_vault
  install_epel7
  yum install -y \
    "${PKGS_COMMON[@]}" \
    python3-devel gcc-c++ libgomp
}

install_el8() {
  dnf install -y epel-release || true
  dnf install -y \
    "${PKGS_COMMON[@]}" \
    python3-devel gcc-c++ libgomp
}

install_deb() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    sysstat numactl pciutils dmidecode lshw ethtool iproute2 \
    fio iperf3 sysbench stress-ng \
    python3 python3-pip python3-dev \
    gcc g++ make libgomp1 \
    jq tar gzip
}

ID_OS="$(os_id)"
MAJOR="$(os_major)"
echo "检测到系统: ${ID_OS} ${MAJOR:-?}"
echo
echo "======== [安装 1/3] 用系统包管理器安装评测软件 ========"
echo "（yum/dnf/apt 会打印很多包名，只要最后没有报错即可）"
echo

if [[ "${ID_OS}" =~ ^(centos|rhel|ol|scientific)$ && "${MAJOR}" == "7" ]]; then
  install_el7
elif command -v dnf >/dev/null 2>&1; then
  install_el8
elif command -v yum >/dev/null 2>&1; then
  install_el7
elif command -v apt-get >/dev/null 2>&1; then
  install_deb
else
  echo "未识别的发行版，请手工安装: fio iperf3 sysbench python3 jq numactl gcc ethtool" >&2
  exit 1
fi

mkdir -p "${SCRATCH_DIR}"
chmod 1777 "${SCRATCH_DIR}" 2>/dev/null || chmod a+rwx "${SCRATCH_DIR}" || true
echo
echo "======== [安装 2/3] 准备临时目录 ========"
echo "临时目录: ${SCRATCH_DIR}"
echo

if python3 -m pip install --quiet pyyaml numpy 2>/dev/null; then
  :
elif pip3 install --quiet pyyaml numpy 2>/dev/null; then
  :
elif command -v yum >/dev/null 2>&1; then
  yum install -y python36-PyYAML python3-pyyaml 2>/dev/null || true
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y python3-pyyaml 2>/dev/null || true
else
  echo "警告: PyYAML 未安装，run_suite.sh 将使用内置默认参数" >&2
fi

echo "======== [安装 3/3] 检查命令是否都在 ========"
echo "下面每一行都应该是 OK。若出现 MISSING，把本段输出留下来排查。"
python3 --version || true
for c in python3 gcc sysbench fio iperf3 jq numactl ethtool; do
  if command -v "${c}" >/dev/null 2>&1; then
    echo "  OK  ${c}"
  else
    echo "  MISSING  ${c}" >&2
  fi
done
python3 -c "import yaml; print('  OK  PyYAML')" 2>/dev/null || echo "  MISSING  PyYAML" >&2
echo
echo "bootstrap 完成。"
echo "下一步（普通用户即可）： bash scripts/start.sh smoke"
