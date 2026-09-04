#!/bin/bash
# =============================================================================
# Slurm 一键初始化部署脚本 v3
# 适用于：CentOS 7/8/9，Slurm 25.x
# 支持共享NFS配置模式（master和login共用同一份slurm.conf）
#
# 用法：
#   bash init-slurm.sh master   # 管理节点：slurmctld + slurmdbd + slurmd
#   bash init-slurm.sh login    # 登录/计算节点：slurmd
#   bash init-slurm.sh restart  # 重启所有服务
#   bash init-slurm.sh status   # 查看服务状态
#   bash init-slurm.sh check    # 仅执行部署自检（不修改任何配置）
#
# 环境变量（可选）：
#   MASTER_IP      管理节点IP（login节点建议提供，如 192.168.0.198）
#   CONFIG_SRC     配置文件源目录（默认 /data/ws01/slurm-config，NFS共享）
#   SLURM_RPM_SRC  RPM包源目录（默认 /data/ws01/slurm-rpms，NFS共享）
#   SETUP_DB       是否配置mariadb（master默认1，login默认0）
#   DB_PASS        slurmdbd 数据库密码（默认 slurmpass_2026）
#   NODE_REG_WAIT  等待节点注册的最长时间（秒，默认 120）
#   TEST_TIMEOUT   测试作业超时（秒，默认 90）
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 基础变量与工具函数
# ---------------------------------------------------------------------------
CMD="${1:-help}"
MASTER_IP="${MASTER_IP:-}"
CONFIG_SRC="${CONFIG_SRC:-/data/ws01/slurm-config}"
SLURM_RPM_SRC="${SLURM_RPM_SRC:-/data/ws01/slurm-rpms}"
DB_PASS="${DB_PASS:-slurmpass_2026}"
NODE_REG_WAIT="${NODE_REG_WAIT:-120}"
TEST_TIMEOUT="${TEST_TIMEOUT:-90}"
ROLE_FILE="/etc/slurm/.init-role"        # 记录本机角色，供 restart/status/check 使用
SETUP_DB="${SETUP_DB:-0}"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BLUE}==== $* ====${NC}"; }

# 自动检测是否使用共享配置
SHARED_CONFIG=0
if [ -d "${CONFIG_SRC}" ] && [ -w "${CONFIG_SRC}" ]; then
    SHARED_CONFIG=1
fi

CURRENT_HOST=$(hostname -s)

# ---------------------------------------------------------------------------
# 通用函数
# ---------------------------------------------------------------------------
have_unit() {  # have_unit <unit.service>
    systemctl list-unit-files "$1" >/dev/null 2>&1
}

proc_running() {  # proc_running <进程名>
    pgrep -x "$1" >/dev/null 2>&1
}

wait_for_proc() {  # wait_for_proc <进程名> [超时秒]
    local proc="$1" timeout="${2:-20}" t=0
    while [ "$t" -lt "$timeout" ]; do
        proc_running "$proc" && return 0
        sleep 2
        t=$((t + 2))
    done
    proc_running "$proc"
}

logtail() {  # logtail <日志文件> [行数]
    tail -n "${2:-20}" "$1" 2>/dev/null || true
}

conf_value() {  # conf_value <Key>，读取 /etc/slurm/slurm.conf 中某键的值（去掉括号地址与注释）
    awk -F= -v k="$1" '$1==k {print $2; exit}' /etc/slurm/slurm.conf 2>/dev/null \
        | sed 's/(.*//' | awk '{print $1}'
}

detect_role() {  # 从角色文件/进程/配置推断本机角色
    if [ -f "$ROLE_FILE" ]; then
        cat "$ROLE_FILE"
        return 0
    fi
    if proc_running slurmctld || [ -f /etc/slurm/slurmdbd.conf ]; then
        echo "master"
    else
        echo "login"
    fi
}

# 把 "<ip> <hostname>" 幂等写入 /etc/hosts（已存在则修正IP，避免重复行）
update_hosts_entry() {
    local ip="$1" name="$2"
    awk -v ip="$ip" -v name="$name" '
        BEGIN { present = 0 }
        { for (i = 2; i <= NF; i++) if ($i == name) { present = 1; if ($1 != ip) { $1 = ip } } print }
        END { if (!present) print ip, name }
    ' /etc/hosts > /tmp/hosts.$$ && mv /tmp/hosts.$$ /etc/hosts
}

usage() {
    cat <<EOF
Slurm 初始化脚本 v3

用法: $0 {master|login|restart|status|check}
  master  - 管理节点（slurmctld + slurmdbd + slurmd + 数据库）
  login   - 登录/计算节点（slurmd）
  restart - 重启所有服务
  status  - 查看服务状态
  check   - 仅执行部署自检（不修改任何配置）

环境变量:
  MASTER_IP      管理节点IP（login节点建议提供）
  CONFIG_SRC     配置目录（默认 /data/ws01/slurm-config）
  SLURM_RPM_SRC  RPM包目录（默认 /data/ws01/slurm-rpms）
  SETUP_DB       是否配置mariadb（master默认1）
  DB_PASS        slurmdbd 数据库密码（默认 slurmpass_2026）
  NODE_REG_WAIT  等待节点注册最长时间（秒，默认120）
  TEST_TIMEOUT   测试作业超时（秒，默认90）

示例:
  bash $0 master
  MASTER_IP=192.168.0.198 bash $0 login
  bash $0 check
EOF
    exit 1
}

# ---------------------------------------------------------------------------
# 部署检查引擎（编号 + PASS/WARN/FAIL + 汇总）
# ---------------------------------------------------------------------------
CHK_NO=0
CHK_PASS=0
CHK_WARN=0
CHK_FAIL=0
CHK_SKIP=0

ck_result() {  # ck_result <PASS|WARN|FAIL|SKIP> <名称> [说明]
    CHK_NO=$((CHK_NO + 1))
    local color
    case "$1" in
        PASS) CHK_PASS=$((CHK_PASS + 1)); color="$GREEN" ;;
        WARN) CHK_WARN=$((CHK_WARN + 1)); color="$YELLOW" ;;
        FAIL) CHK_FAIL=$((CHK_FAIL + 1)); color="$RED" ;;
        SKIP) CHK_SKIP=$((CHK_SKIP + 1)); color="$BLUE" ;;
    esac
    printf "  [%2d] ${color}%-5s${NC} %s %s\n" "$CHK_NO" "$1" "$2" "${3:+-> $3}"
    return 0
}

ck_pass() { ck_result PASS "$1" "${2:-}"; }
ck_warn() { ck_result WARN "$1" "${2:-}"; }
ck_fail() { ck_result FAIL "$1" "${2:-}"; }
ck_skip() { ck_result SKIP "$1" "${2:-}"; }

node_state() {  # 查询本节点在控制器中的状态
    scontrol show node "$CURRENT_HOST" 2>/dev/null \
        | sed -n 's/.*NodeState=\([^ ,]*\).*/\1/p' | head -1
}

# 1) munge 本地认证
check_munge_local() {
    local out
    out=$(munge -n 2>/dev/null | unmunge 2>/dev/null | grep -o 'STATUS: Success' || true)
    if [ -n "$out" ]; then
        ck_pass "munge 本地认证" "munge -n | unmunge 成功"
    else
        ck_fail "munge 本地认证" "执行 'munge -n | unmunge' 查看详细错误"
    fi
}

# 2) 集群身份一致性（munge/slurm 的 UID/GID 与 slurm 版本必须全集群一致）
write_identity() {
    [ "${SHARED_CONFIG}" = "1" ] || return 0
    [ -w "${CONFIG_SRC}" ] || return 0
    {
        echo "munge_uid=$(id -u munge 2>/dev/null)"
        echo "munge_gid=$(id -g munge 2>/dev/null)"
        echo "slurm_uid=$(id -u slurm 2>/dev/null)"
        echo "slurm_gid=$(id -g slurm 2>/dev/null)"
        echo "slurm_ver=$(rpm -q slurm 2>/dev/null | head -1)"
    } > "${CONFIG_SRC}/.cluster-identity"
}

check_identity() {
    local idf="${CONFIG_SRC}/.cluster-identity"
    if [ "$ROLE" = "master" ]; then
        write_identity
        if [ -f "$idf" ]; then
            ck_pass "集群身份基准" "$idf 已写入（login节点将据此自检）"
        else
            ck_warn "集群身份基准" "共享目录不可写，login 节点无法自动比对 UID/版本"
        fi
        return 0
    fi

    if [ ! -f "$idf" ]; then
        ck_warn "集群身份一致性" "未找到 ${idf}，请先在 master 节点执行一次本脚本"
        return 0
    fi

    local problems="" ver_diff=""
    # shellcheck disable=SC1090
    . "$idf"

    if [ "$(id -u munge)" != "${munge_uid:-}" ] || [ "$(id -g munge)" != "${munge_gid:-}" ]; then
        problems="$problems munge uid/gid 不一致(${munge_uid:-?}/${munge_gid:-?} vs 本机 $(id -u munge)/$(id -g munge))"
    fi
    if [ "$(id -u slurm)" != "${slurm_uid:-}" ] || [ "$(id -g slurm)" != "${slurm_gid:-}" ]; then
        problems="$problems slurm uid/gid 不一致(${slurm_uid:-?}/${slurm_gid:-?} vs 本机 $(id -u slurm)/$(id -g slurm))"
    fi

    local my_ver=""
    my_ver=$(rpm -q slurm 2>/dev/null | head -1)
    if [ -n "$my_ver" ] && [ -n "${slurm_ver:-}" ]; then
        local a b
        a=$(echo "$my_ver" | grep -oE '[0-9]+\.[0-9]+' | head -1)
        b=$(echo "${slurm_ver}" | grep -oE '[0-9]+\.[0-9]+' | head -1)
        if [ -n "$a" ] && [ "$a" != "$b" ]; then
            ver_diff="slurm 版本不一致(${slurm_ver} vs 本机 ${my_ver})"
        fi
    fi

    if [ -n "$problems" ]; then
        ck_fail "集群身份一致性" "${problems:1}（UID 不一致会导致认证/授权失败，请统一 /etc/passwd）"
    else
        ck_pass "集群身份一致性" "munge/slurm UID、GID 与 master 一致${ver_diff:+；}${ver_diff}"
    fi
}

# 3) 配置/二进制语法检查
check_config_syntax() {
    if [ "$ROLE" = "master" ] && [ -x /usr/sbin/slurmctld ]; then
        if /usr/sbin/slurmctld -t >/dev/null 2>&1; then
            ck_pass "slurm.conf 语法" "slurmctld -t 通过"
        else
            ck_fail "slurm.conf 语法" "slurmctld -t 失败，请检查 /etc/slurm/slurm.conf"
        fi
    elif [ -x /usr/sbin/slurmd ]; then
        if /usr/sbin/slurmd -C >/dev/null 2>&1; then
            ck_pass "slurmd 硬件探测" "slurmd -C 正常"
        else
            ck_fail "slurmd 硬件探测" "slurmd -C 失败，查看 /var/log/slurm/slurmd.log"
        fi
    else
        ck_skip "配置语法检查" "未找到 slurmctld/slurmd 二进制"
    fi
}

# 4) 服务进程检查
check_processes() {
    local procs="munged slurmd"
    [ "$ROLE" = "master" ] && procs="munged slurmd slurmctld slurmdbd"
    local missing=""
    for p in $procs; do
        proc_running "$p" || missing="$missing $p"
    done
    if [ -n "$missing" ]; then
        ck_fail "服务进程" "未运行:${missing}（master 上执行 bash $0 restart）"
    else
        ck_pass "服务进程" "运行中:${procs}"
    fi
}

# 5) 端口监听检查
port_listening() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE "[:.]${port}$"
    else
        netstat -lnt 2>/dev/null | awk 'NR>2 {print $4}' | grep -qE "[:.]${port}$"
    fi
}

check_ports_listen() {
    local ctl_port slurmd_port
    ctl_port=$(conf_value SlurmctldPort) || true
    slurmd_port=$(conf_value SlurmdPort) || true
    ctl_port="${ctl_port:-6817}"
    slurmd_port="${slurmd_port:-6818}"

    if port_listening "$slurmd_port"; then
        ck_pass "slurmd 监听端口" ":${slurmd_port} 已监听"
    else
        ck_fail "slurmd 监听端口" ":${slurmd_port} 未监听"
    fi
    if [ "$ROLE" = "master" ] && ! port_listening "$ctl_port"; then
        ck_fail "slurmctld 监听端口" ":${ctl_port} 未监听"
    fi
}

# 6) 控制器可达/响应
check_controller() {
    if ! command -v scontrol >/dev/null 2>&1; then
        ck_skip "控制器响应" "未安装 scontrol"
        return 0
    fi
    if scontrol ping 2>/dev/null | grep -qi 'is UP'; then
        ck_pass "控制器响应" "scontrol ping 返回 UP"
    else
        ck_fail "控制器响应" "slurmctld 不可达，检查 munge 与 SlurmctldHost 配置"
    fi
}

# 7) master 主机名解析（login 节点）
check_master_resolve() {
    if getent hosts "${MASTER_HOST}" >/dev/null 2>&1; then
        ck_pass "master 主机名解析" "${MASTER_HOST} -> $(getent hosts ${MASTER_HOST} | awk 'NR==1{print $1}')"
    else
        ck_fail "master 主机名解析" "${MASTER_HOST} 无法解析；请设置 MASTER_IP 或在 /etc/hosts 添加映射"
    fi
}

# 8) master 控制器端口可达（login 节点）
check_master_port() {
    local ctl_port master_addr
    ctl_port=$(conf_value SlurmctldPort) || true
    ctl_port="${ctl_port:-6817}"
    master_addr="${MASTER_IP:-$MASTER_HOST}"
    if [ -z "$master_addr" ]; then
        ck_skip "master 端口可达" "未提供 MASTER_IP 且主机名无法解析"
        return 0
    fi
    if timeout 5 bash -c "exec 3<>/dev/tcp/${master_addr}/${ctl_port}" >/dev/null 2>&1; then
        ck_pass "master 端口可达" "${master_addr}:${ctl_port} 可连接"
    else
        ck_fail "master 端口可达" "${master_addr}:${ctl_port} 连接失败（防火墙/网络）"
    fi
}

# 9) 时钟同步（munge 对时钟偏差敏感）
check_time_sync() {
    local ok=""
    if command -v chronyc >/dev/null 2>&1 && chronyc tracking >/dev/null 2>&1; then
        ok="chrony"
    elif proc_running ntpd; then
        ok="ntpd"
    elif command -v timedatectl >/dev/null 2>&1 \
        && [ "$(timedatectl show -p NTPSynchronized | cut -d= -f2)" = "yes" ]; then
        ok="systemd-timesync"
    fi
    if [ -n "$ok" ]; then
        ck_pass "时钟同步" "$ok 运行中"
    else
        ck_warn "时钟同步" "未检测到 chrony/ntpd，munge 认证对时钟偏差敏感"
    fi
}

# 10) 防火墙 / SELinux（仅提醒）
check_firewall_selinux() {
    local warns=""
    if systemctl is-active firewalld >/dev/null 2>&1; then
        warns="${warns}firewalld 运行中，需放行 Slurm 端口与 munge 通信;"
    fi
    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ]; then
        warns="${warns}SELinux=Enforcing 可能拦截服务启动;"
    fi
    if [ -n "$warns" ]; then
        ck_warn "防火墙/SELinux" "${warns%?}"
    else
        ck_pass "防火墙/SELinux" "firewalld 未启用 / SELinux 非强制"
    fi
}

# 11) 记账检查（master）
check_accounting() {
    if grep -q '^AccountingStorageType=.*accounting_storage/none' /etc/slurm/slurm.conf 2>/dev/null; then
        ck_skip "slurmdbd 记账" "AccountingStorageType=none，未启用记账"
        return 0
    fi
    if ! command -v sacctmgr >/dev/null 2>&1; then
        ck_warn "slurmdbd 记账" "未安装 sacctmgr"
        return 0
    fi
    local out
    out=$(sacctmgr -n list cluster format=Cluster 2>/dev/null || true)
    if [ -n "$out" ]; then
        ck_pass "slurmdbd 记账" "集群: $(echo "$out" | tr '\n' ' ')"
    else
        ck_warn "slurmdbd 记账" "sacctmgr 查询无结果（slurmdbd/MariaDB 未就绪）"
    fi
}

# 12) 节点注册等待（关键检查：轮询直到节点可用或超时）
check_registration() {
    local deadline state="" attempts=0
    deadline=$(( $(date +%s) + NODE_REG_WAIT ))

    if [ "$ROLE" = "master" ]; then
        scontrol update nodename=ALL state=resume reason="init_$(date +%s)" >/dev/null 2>&1 || true
    fi
    scontrol update nodename="${CURRENT_HOST}" state=resume reason=auto >/dev/null 2>&1 || true

    while true; do
        state=$(node_state || true)
        case "$state" in
            IDLE*|MIXED*|ALLOCATED*|COMPLETING*)
                ck_pass "节点 ${CURRENT_HOST} 注册" "NodeState=${state}"
                return 0
                ;;
            DOWN*|DRAIN*|INVALID*|FAIL*)
                # 已注册但状态异常，尝试恢复
                scontrol update nodename="${CURRENT_HOST}" state=resume reason=auto >/dev/null 2>&1 || true
                ;;
        esac
        if [ "$(date +%s)" -ge "$deadline" ]; then
            break
        fi
        attempts=$((attempts + 1))
        if [ "$ROLE" = "login" ] && [ $((attempts % 6)) -eq 0 ]; then
            # 控制器不识别新节点时，周期性触发配置重载
            scontrol reconfigure >/dev/null 2>&1 || true
        fi
        sleep 5
    done

    ck_fail "节点 ${CURRENT_HOST} 注册" "${NODE_REG_WAIT}s 内未就绪，state=${state:-空}; 查看 slurmd 日志，master 上执行 scontrol reconfigure"
}

# 13) 测试作业
check_test_job() {
    if ! command -v srun >/dev/null 2>&1; then
        ck_skip "测试作业" "未安装 srun"
        return 0
    fi
    local out rc
    if out=$(timeout "${TEST_TIMEOUT}" srun -N1 --immediate=30 hostname 2>&1); then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        ck_pass "测试作业 srun" "返回: $(echo "$out" | tr '\n' ' ')"
    else
        ck_warn "测试作业 srun" "$(echo "$out" | tr '\n' ' ')（可能因其他节点未就绪，稍后重试）"
    fi
}

# 14) 日志错误扫描
check_logs() {
    local hits=""
    hits=$(grep -ihE 'error|fatal' /var/log/slurm/slurmctld.log /var/log/slurm/slurmd.log \
           /var/log/slurm/slurmdbd.log /var/log/munge/munged.log 2>/dev/null | tail -3) || true
    if [ -n "$hits" ]; then
        ck_warn "日志错误扫描" "最近日志含 error/fatal:"
        echo "$hits" | sed 's/^/           /'
    else
        ck_pass "日志错误扫描" "未发现 error/fatal 记录"
    fi
}

check_summary() {
    echo ""
    echo "  --------------------------------------------------------------"
    printf "  ${BLUE}自检汇总:${NC} PASS=${GREEN}%d${NC}  WARN=${YELLOW}%d${NC}  FAIL=${RED}%d${NC}  SKIP=%d\n" \
        "$CHK_PASS" "$CHK_WARN" "$CHK_FAIL" "$CHK_SKIP"
    echo "  --------------------------------------------------------------"
    if [ "$CHK_FAIL" -gt 0 ]; then
        echo ""
        error "存在 FAIL 项，请先按提示排查后再投入使用"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 步骤0：安装Slurm RPM包
# ---------------------------------------------------------------------------
install_slurm() {
    step "步骤0: 检查并安装 Slurm 包"

    if rpm -q slurm >/dev/null 2>&1; then
        info "Slurm 已安装，跳过"
        rpm -qa | grep -E 'slurm|munge' | sort
        return 0
    fi

    local yum_opts=""
    if [ -d "${SLURM_RPM_SRC}" ] && ls "${SLURM_RPM_SRC}"/slurm-*.rpm >/dev/null 2>&1; then
        info "使用本地 yum 源: ${SLURM_RPM_SRC}"
        yum install -y createrepo >/dev/null 2>&1 || true
        if [ ! -d "${SLURM_RPM_SRC}/repodata" ]; then
            createrepo "${SLURM_RPM_SRC}" >/dev/null 2>&1
        fi
        cat > /etc/yum.repos.d/slurm-local.repo << EOF
[slurm-local]
name=Slurm Local RPMs
baseurl=file://${SLURM_RPM_SRC}
enabled=1
gpgcheck=0
EOF
        yum clean all >/dev/null 2>&1
        yum_opts="--disablerepo=epel --enablerepo=slurm-local"
    else
        warn "未找到本地 RPM 包，尝试从网络安装"
    fi

    info "安装 Slurm 包..."
    if [ "$ROLE" = "master" ]; then
        yum install -y $yum_opts slurm slurm-slurmctld slurm-slurmd slurm-slurmdbd slurm-pam_slurm munge munge-devel
    else
        yum install -y $yum_opts slurm slurm-slurmd munge
    fi
    info "Slurm 安装完成"
    rpm -qa | grep -E 'slurm|munge' | sort
}

# ---------------------------------------------------------------------------
# 步骤1：创建用户和组
# ---------------------------------------------------------------------------
create_users() {
    step "步骤1: 创建用户和组"

    if ! getent group munge >/dev/null 2>&1; then
        groupadd -r munge
    fi
    if ! id munge >/dev/null 2>&1; then
        useradd -r -g munge -d /var/run/munge -s /sbin/nologin munge
    fi

    if ! getent group slurm >/dev/null 2>&1; then
        groupadd -r slurm
    fi
    if ! id slurm >/dev/null 2>&1; then
        useradd -r -g slurm -d /var/spool/slurm -s /sbin/nologin slurm
    fi

    info "用户: munge($(id -u munge)), slurm($(id -u slurm))"
}

# ---------------------------------------------------------------------------
# 步骤2：创建目录并设置权限
# ---------------------------------------------------------------------------
create_dirs() {
    step "步骤2: 创建目录并设置权限"

    # munge
    mkdir -p /etc/munge /var/run/munge /var/log/munge
    chown -R munge:munge /etc/munge /var/run/munge /var/log/munge
    chmod 700 /etc/munge
    chmod 755 /var/run/munge
    chmod 700 /var/log/munge

    # slurm
    mkdir -p /etc/slurm /var/log/slurm /var/spool/slurmctld /var/spool/slurmd /var/run/slurm
    chown -R slurm:slurm /var/log/slurm /var/spool/slurmctld /var/spool/slurmd
    chmod 700 /var/spool/slurmctld
    chmod 755 /var/log/slurm /var/spool/slurmd /etc/slurm

    # slurmdbd（master 且启用记账时）
    if [ "$ROLE" = "master" ]; then
        mkdir -p /var/spool/slurmdbd
        chown slurm:slurm /var/spool/slurmdbd
        chmod 700 /var/spool/slurmdbd
        touch /var/log/slurm/slurmdbd.log
        chown slurm:slurm /var/log/slurm/slurmdbd.log
    fi

    # 日志文件
    for f in slurmctld.log slurmd.log; do
        touch /var/log/slurm/$f
        chown slurm:slurm /var/log/slurm/$f
        chmod 644 /var/log/slurm/$f
    done

    info "目录权限已设置"
}

# ---------------------------------------------------------------------------
# 步骤3：配置文件
# ---------------------------------------------------------------------------
setup_config() {
    step "步骤3: 配置文件"
    local SLURM_CONF=""
    local MASTER_HOST=""

    # ---------- 准备配置源 ----------
    if [ "${SHARED_CONFIG}" = "1" ]; then
        info "使用共享配置模式 (NFS: ${CONFIG_SRC})"
        SLURM_CONF="${CONFIG_SRC}/slurm.conf"

        # 共享目录中没有 slurm.conf 时，从本地模板初始化
        if [ ! -s "${SLURM_CONF}" ]; then
            if [ -f "${CONFIG_SRC}/slurm.conf.template" ]; then
                cp "${CONFIG_SRC}/slurm.conf.template" "${SLURM_CONF}"
            elif [ -f /etc/slurm/slurm.conf ] && [ ! -L /etc/slurm/slurm.conf ]; then
                cp /etc/slurm/slurm.conf "${SLURM_CONF}"
            else
                error "未找到 slurm.conf 模板，请确保 ${CONFIG_SRC}/slurm.conf(.template) 存在"
            fi
        fi

        # cgroup.conf 默认模板
        if [ ! -s "${CONFIG_SRC}/cgroup.conf" ]; then
            cat > "${CONFIG_SRC}/cgroup.conf" << 'EOF'
# cgroup.conf
CgroupAutomount=yes
ConstrainCores=yes
ConstrainDevices=yes
ConstrainRAMSpace=yes
ConstrainSwapSpace=yes
MaxRAMPercent=98
MaxSwapPercent=98
EOF
        fi

        # 符号链接 /etc/slurm/* -> 共享文件
        ln -sf "${SLURM_CONF}" /etc/slurm/slurm.conf
        ln -sf "${CONFIG_SRC}/cgroup.conf" /etc/slurm/cgroup.conf
        info "  /etc/slurm/slurm.conf -> ${SLURM_CONF}"
    else
        info "使用本地配置模式"
        SLURM_CONF="/etc/slurm/slurm.conf"
        cp_if_exists() { [ -f "$1" ] && cp "$1" /etc/slurm/; }
        cp_if_exists "${CONFIG_SRC}/slurm.conf"
        cp_if_exists "${CONFIG_SRC}/cgroup.conf"
        cp_if_exists "${CONFIG_SRC}/gres.conf"
        unset -f cp_if_exists 2>/dev/null || true
    fi

    # ---------- 确定 MASTER_HOST ----------
    if [ "$ROLE" = "master" ]; then
        MASTER_HOST="${CURRENT_HOST}"
    else
        # 从配置读取 SlurmctldHost，兼容 "host(ip)" 写法
        MASTER_HOST=$(awk -F= '/^SlurmctldHost=/{print $2; exit}' "${SLURM_CONF}" 2>/dev/null \
                      | sed 's/(.*//' | awk '{print $1}') || true
        if [ -z "$MASTER_HOST" ] || [ "$MASTER_HOST" = "MASTER_HOST_PLACEHOLDER" ]; then
            error "无法确定 master 主机名，请先在 master 节点运行本脚本"
        fi
    fi
    info "Master 主机名: ${MASTER_HOST}"

    # ---------- 替换占位符 ----------
    if grep -q "MASTER_HOST_PLACEHOLDER" "${SLURM_CONF}" 2>/dev/null; then
        sed -i "s/MASTER_HOST_PLACEHOLDER/${MASTER_HOST}/g" "${SLURM_CONF}"
        info "  已设置 SlurmctldHost=${MASTER_HOST}"
    fi

    # ---------- slurmdbd.conf（仅 master，本地副本） ----------
    if [ "$ROLE" = "master" ] && [ -f "${CONFIG_SRC}/slurmdbd.conf" ]; then
        install -o slurm -g slurm -m 600 "${CONFIG_SRC}/slurmdbd.conf" /etc/slurm/slurmdbd.conf
        info "  已配置 slurmdbd.conf"
    fi

    # ---------- munge.key ----------
    if [ "$ROLE" = "master" ]; then
        if [ ! -s /etc/munge/munge.key ]; then
            info "  生成 munge.key..."
            if command -v create-munge-key >/dev/null 2>&1; then
                create-munge-key -f
            else
                dd if=/dev/urandom of=/etc/munge/munge.key bs=1024 count=1 status=none
            fi
        fi
        if [ "${SHARED_CONFIG}" = "1" ]; then
            cp /etc/munge/munge.key "${CONFIG_SRC}/munge.key"
            chmod 644 "${CONFIG_SRC}/munge.key"
            info "  munge.key 已共享到 ${CONFIG_SRC}/munge.key"
        fi
    else
        if [ ! -s /etc/munge/munge.key ]; then
            if [ -s "${CONFIG_SRC}/munge.key" ]; then
                info "  从共享目录复制 munge.key"
                cp "${CONFIG_SRC}/munge.key" /etc/munge/munge.key
            else
                error "未找到 munge.key！请先在 master 节点运行本脚本"
            fi
        fi
    fi
    chown munge:munge /etc/munge/munge.key
    chmod 400 /etc/munge/munge.key

    # ---------- /etc/hosts 解析 ----------
    if [ "$ROLE" = "login" ] && [ -n "${MASTER_IP}" ]; then
        update_hosts_entry "${MASTER_IP}" "${MASTER_HOST}"
        info "  hosts 映射已就绪: ${MASTER_IP} ${MASTER_HOST}"
    elif [ "$ROLE" = "master" ] && [ -z "${MASTER_IP}" ]; then
        MASTER_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}') || true
        [ -z "${MASTER_IP}" ] && MASTER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        info "Master IP: ${MASTER_IP}"
    fi

    # ---------- 添加当前节点到 NodeName（如不存在） ----------
    if [ -x /usr/sbin/slurmd ]; then
        if ! grep -q "^NodeName=${CURRENT_HOST}[ ,]" "${SLURM_CONF}"; then
            local hw_info
            hw_info=$(/usr/sbin/slurmd -C 2>/dev/null | head -1 | sed 's/UpTime=.*//')
            if [ -n "$hw_info" ]; then
                local feature="login"
                [ "$ROLE" = "master" ] && feature="master"
                info "  自动添加节点: ${hw_info} Feature=${feature}"
                echo "${hw_info} State=UNKNOWN Feature=${feature}" >> "${SLURM_CONF}"
            fi
        else
            info "  节点 ${CURRENT_HOST} 已在配置中"
        fi
    else
        warn "  未找到 slurmd，跳过节点自动注册"
    fi

    # ---------- 确保 AccountingStorageType 有值 ----------
    if ! grep -q "^AccountingStorageType=" "${SLURM_CONF}"; then
        echo "AccountingStorageType=accounting_storage/none" >> "${SLURM_CONF}"
    fi

    info "配置文件清单:"
    ls -la /etc/slurm/ /etc/munge/munge.key 2>/dev/null
    echo ""
    info "=== slurm.conf 节点配置 ==="
    grep "^NodeName\|^SlurmctldHost\|^PartitionName\|^ClusterName" "${SLURM_CONF}"
}

# ---------------------------------------------------------------------------
# 步骤4：配置数据库（master 且启用记账时）
# ---------------------------------------------------------------------------
setup_database() {
    # 若未启用记账（无 slurmdbd.conf 且 AccountingStorageType=none），跳过
    if [ -f /etc/slurm/slurmdbd.conf ]; then
        [ "$SETUP_DB" = "1" ] || { warn "检测到 slurmdbd.conf 但 SETUP_DB=0，跳过数据库配置"; }
    fi
    if [ "$ROLE" != "master" ] || [ "$SETUP_DB" != "1" ]; then
        return 0
    fi
    if [ ! -f /etc/slurm/slurmdbd.conf ] \
        && grep -q '^AccountingStorageType=.*accounting_storage/none' /etc/slurm/slurm.conf 2>/dev/null; then
        info "未启用记账（AccountingStorageType=none 且无 slurmdbd.conf），跳过数据库配置"
        return 0
    fi

    step "步骤4: 配置 MariaDB (slurmdbd)"

    if ! rpm -q mariadb-server >/dev/null 2>&1; then
        info "安装 mariadb-server..."
        yum install -y mariadb mariadb-server >/dev/null 2>&1
    fi

    systemctl enable mariadb >/dev/null 2>&1 || true
    systemctl restart mariadb
    sleep 3

    info "初始化 slurm_acct_db 数据库..."
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS slurm_acct_db CHARACTER SET utf8 COLLATE utf8_general_ci;" 2>/dev/null || true
    mysql -u root -e "DROP USER 'slurm'@'localhost';" 2>/dev/null || true
    mysql -u root -e "CREATE USER 'slurm'@'localhost' IDENTIFIED BY '${DB_PASS}';" 2>/dev/null || true
    mysql -u root -e "GRANT ALL PRIVILEGES ON slurm_acct_db.* TO 'slurm'@'localhost'; FLUSH PRIVILEGES;"

    if mysql -u slurm -p"${DB_PASS}" -e "USE slurm_acct_db; SELECT 1;" >/dev/null 2>&1; then
        info "数据库初始化完成"
    else
        warn "数据库验证失败，slurmdbd 可能无法启动（不影响基本调度）"
    fi

    # 同步共享 slurmdbd.conf 中的存储参数
    if [ -f "${CONFIG_SRC}/slurmdbd.conf" ]; then
        sed -i "s/^StoragePass=.*/StoragePass=${DB_PASS}/" "${CONFIG_SRC}/slurmdbd.conf"
        sed -i 's/^StorageLoc=.*/StorageLoc=slurm_acct_db/' "${CONFIG_SRC}/slurmdbd.conf"
        sed -i 's/^StorageUser=.*/StorageUser=slurm/' "${CONFIG_SRC}/slurmdbd.conf"
    fi
}

# ---------------------------------------------------------------------------
# 步骤5：停止旧进程
# ---------------------------------------------------------------------------
stop_services() {
    step "步骤5: 停止旧进程"
    systemctl stop slurmctld slurmd slurmdbd munge >/dev/null 2>&1 || true
    for p in munged slurmdbd slurmctld slurmd; do
        pkill -9 "$p" >/dev/null 2>&1 || true
    done
    sleep 2
    rm -f /var/run/munge/munge.socket.* /var/run/munge/munged.pid
    rm -f /var/run/slurmctld.pid /var/run/slurmd.pid /var/run/slurmdbd.pid
    rm -f /var/spool/slurmctld/slurmctld.pid /var/spool/slurmd/slurmd.pid
    info "旧进程已清理"
}

# ---------------------------------------------------------------------------
# 步骤6：启动服务（优先 systemd 单元，否则手动拉起）
# ---------------------------------------------------------------------------
start_daemon() {  # start_daemon <进程名> <unit名> <手动启动命令函数>
    local proc="$1" unit="$2" manual="$3"
    if have_unit "$unit"; then
        systemctl enable "$unit" >/dev/null 2>&1 || true
        systemctl restart "$unit"
    else
        "$manual"
    fi
    wait_for_proc "$proc" 20
}

run_munged()   { runuser -u munge -- munged; }
run_slurmdbd() { /usr/sbin/slurmdbd; }
run_slurmctld(){ /usr/sbin/slurmctld -c; }
run_slurmd()   { /usr/sbin/slurmd; }

start_munge() {
    step "启动 munge"
    if start_daemon munged munge.service run_munged; then
        info "munged 启动成功"
    else
        logtail /var/log/munge/munged.log
        error "munged 启动失败"
    fi
}

start_slurmdbd() {
    [ "$ROLE" = "master" ] || return 0
    [ -f /etc/slurm/slurmdbd.conf ] || { info "无 slurmdbd.conf，跳过 slurmdbd"; return 0; }
    step "启动 slurmdbd"
    rm -rf /var/spool/slurmdbd/* 2>/dev/null || true
    chown slurm:slurm /var/spool/slurmdbd
    if start_daemon slurmdbd slurmdbd.service run_slurmdbd; then
        info "slurmdbd 启动成功"
    else
        logtail /var/log/slurm/slurmdbd.log
        warn "slurmdbd 启动失败（可能 MariaDB 版本不兼容，不影响基本调度）"
    fi
}

start_slurmctld() {
    [ "$ROLE" = "master" ] || return 0
    step "启动 slurmctld"
    rm -rf /var/spool/slurmctld/*
    chown slurm:slurm /var/spool/slurmctld
    > /var/log/slurm/slurmctld.log
    if start_daemon slurmctld slurmctld.service run_slurmctld; then
        info "slurmctld 启动成功"
    else
        logtail /var/log/slurm/slurmctld.log
        error "slurmctld 启动失败"
    fi
}

start_slurmd() {
    step "启动 slurmd"
    rm -rf /var/spool/slurmd/*
    chown slurm:slurm /var/spool/slurmd
    > /var/log/slurm/slurmd.log
    if start_daemon slurmd slurmd.service run_slurmd; then
        info "slurmd 启动成功"
    else
        logtail /var/log/slurm/slurmd.log
        error "slurmd 启动失败"
    fi
}

# ---------------------------------------------------------------------------
# 步骤7：设置开机自启
# ---------------------------------------------------------------------------
setup_autostart() {
    step "步骤7: 设置开机自启"
    local rc_local="/etc/rc.d/rc.local"
    local need_units="munge slurmd"
    local all_have=1

    if have_unit munge.service && have_unit slurmd.service; then
        if [ "$ROLE" = "master" ]; then
            if have_unit slurmctld.service; then
                [ -f /etc/slurm/slurmdbd.conf ] && have_unit slurmdbd.service || true
            else
                all_have=0
            fi
        fi
    else
        all_have=0
    fi

    if [ "$all_have" = "1" ]; then
        systemctl enable munge slurmd >/dev/null 2>&1 || true
        if [ "$ROLE" = "master" ]; then
            systemctl enable slurmctld >/dev/null 2>&1 || true
            [ -f /etc/slurm/slurmdbd.conf ] && systemctl enable slurmdbd >/dev/null 2>&1 || true
        fi
        info "检测到 systemd 单元，已通过 systemctl enable 设置自启"
        return 0
    fi

    # 无 systemd 单元时退回 rc.local（带起止标记，可安全重复执行）
    touch "$rc_local"
    chmod +x "$rc_local"
    sed -i '/^# BEGIN SLURM AUTOSTART/,/^# END SLURM AUTOSTART/d' "$rc_local" 2>/dev/null || true

    cat >> "$rc_local" << EOF

# BEGIN SLURM AUTOSTART - $(date '+%F %T')
sleep 10
mkdir -p /var/run/munge /var/log/munge /var/spool/slurmctld /var/spool/slurmd
chown munge:munge /var/run/munge /var/log/munge
chown slurm:slurm /var/spool/slurmctld /var/spool/slurmd
chmod 755 /var/run/munge
runuser -u munge -- munged
sleep 2
EOF
    if [ "$ROLE" = "master" ] && [ -f /etc/slurm/slurmdbd.conf ]; then
        echo "/usr/sbin/slurmdbd" >> "$rc_local"
        echo "sleep 1" >> "$rc_local"
    fi
    if [ "$ROLE" = "master" ]; then
        echo "/usr/sbin/slurmctld -c" >> "$rc_local"
        echo "sleep 1" >> "$rc_local"
    fi
    echo "/usr/sbin/slurmd" >> "$rc_local"
    echo "# END SLURM AUTOSTART" >> "$rc_local"
    info "已写入 $rc_local（BEGIN/END 标记内）"
}

# ---------------------------------------------------------------------------
# 步骤8：部署后自检
# ---------------------------------------------------------------------------
run_role_checks() {
    case "$ROLE" in
        master)
            check_munge_local
            check_identity
            check_config_syntax
            check_processes
            check_ports_listen
            check_controller
            check_accounting
            check_time_sync
            check_firewall_selinux
            check_registration
            check_test_job
            check_logs
            ;;
        login)
            check_munge_local
            check_identity
            check_master_resolve
            check_master_port
            check_config_syntax
            check_processes
            check_ports_listen
            check_controller
            check_time_sync
            check_firewall_selinux
            check_registration
            check_test_job
            check_logs
            ;;
    esac
}

verify() {
    step "步骤8: 部署后自检"
    sleep 3
    run_role_checks
    check_summary
}

# ---------------------------------------------------------------------------
# 状态查看
# ---------------------------------------------------------------------------
show_status() {
    local role_now
    role_now=$(detect_role)
    echo "=== 本机角色: ${role_now} ==="
    echo "Slurm 版本: $(rpm -q slurm 2>/dev/null | head -1 || echo 未知)  munge: $(rpm -q munge 2>/dev/null | head -1 || echo 未知)"
    echo ""
    echo "=== 服务状态 ==="
    for svc in munged slurmdbd slurmctld slurmd; do
        if proc_running "$svc"; then
            echo -e "${GREEN}RUNNING${NC}  $svc (pid $(pgrep -x $svc | tr '\n' ' '))"
        else
            echo -e "${RED}STOPPED${NC}  $svc"
        fi
    done

    if [ "$role_now" = "master" ] && command -v sinfo >/dev/null 2>&1; then
        echo ""
        echo "=== 节点状态 ==="
        sinfo 2>/dev/null || echo "slurmctld 未就绪"
        echo ""
        echo "=== 集群记账 ==="
        sacctmgr -n list cluster format=Cluster 2>/dev/null || echo "slurmdbd 未就绪或未启用记账"
    fi
}

restart_all() {
    step "重启服务"
    ROLE=$(detect_role)
    info "检测到本机角色: ${ROLE}"
    stop_services
    start_munge
    if [ "$ROLE" = "master" ]; then
        start_slurmdbd
        start_slurmctld
    fi
    start_slurmd
    show_status
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
case "$CMD" in
    master|login)
        ROLE="$CMD"
        [ "$ROLE" = "master" ] && SETUP_DB=1
        info "角色: ${ROLE}  主机名: ${CURRENT_HOST}  共享配置: ${SHARED_CONFIG}"

        install_slurm
        create_users
        create_dirs
        setup_config
        setup_database
        stop_services
        start_munge
        start_slurmdbd
        start_slurmctld
        start_slurmd
        setup_autostart
        echo "$ROLE" > "$ROLE_FILE"
        chmod 644 "$ROLE_FILE"
        verify

        echo ""
        echo "=============================================="
        echo "  ${ROLE} 节点部署完成！"
        echo "=============================================="
        if [ "$ROLE" = "master" ]; then
            echo "  管理节点: ${CURRENT_HOST} (${MASTER_IP:-IP未探测})"
            echo ""
            echo "  在 login/计算节点执行:"
            echo "  MASTER_IP=${MASTER_IP:-<master_ip>} bash ${CONFIG_SRC}/init-slurm.sh login"
        else
            echo "  本机已尝试通过 scontrol reconfigure 通知 master"
            echo "  若节点未加入，请在 master 上执行: scontrol reconfigure && sinfo"
        fi
        echo "  随时可用 'bash $0 check' 重新执行自检"
        ;;
    restart)
        restart_all
        ;;
    status)
        show_status
        ;;
    check)
        ROLE=$(detect_role)
        info "自检模式，本机角色: ${ROLE}（只读检查，不修改任何配置）"
        verify
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage
        ;;
esac
