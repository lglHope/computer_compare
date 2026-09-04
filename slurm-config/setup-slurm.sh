#!/bin/bash
# Slurm 快速部署脚本（CentOS 7/8/9）
# 在管理节点和计算节点各执行一次
# 用法：bash setup-slurm.sh [master|worker] [master-hostname]
#
# 可选环境变量：
#   CONFIG_DIR   配置目录（默认 /data/ws01/slurm-config）
#   SLURM_USER   Slurm 用户（默认 slurm）
#   MUNGE_USER   Munge 用户（默认 munge）

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

ROLE="${1:-worker}"
MASTER_HOST="${2:-${MASTER_HOST:-}}"
CONFIG_DIR="${CONFIG_DIR:-/data/ws01/slurm-config}"
SLURM_ETC="/etc/slurm"
MUNGE_ETC="/etc/munge"
LOG_DIR="/var/log/slurm"
SLURMCTLD_SPOOL="/var/spool/slurmctld"
SLURMD_SPOOL="/var/spool/slurmd"
SLURM_USER="${SLURM_USER:-slurm}"
MUNGE_USER="${MUNGE_USER:-munge}"

trap 'echo "[ERROR] line ${LINENO}: command failed" >&2' ERR

log()   { echo "[INFO] $*"; }
warn()  { echo "[WARN] $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    cat <<EOF
用法: $0 [master|worker] [master-hostname]

示例:
  bash $0 master
  bash $0 worker iv-yet48a2xhcnic5cfr78c

环境变量:
  CONFIG_DIR   配置目录（默认 /data/ws01/slurm-config）
  SLURM_USER   Slurm 用户（默认 slurm）
  MUNGE_USER   Munge 用户（默认 munge）
EOF
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "请使用 root 运行此脚本"
    fi
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "缺少命令: $1"
}

ensure_dir() {
    local dir="$1"
    local mode="${2:-755}"
    local owner="${3:-root:root}"

    install -d -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$dir"
}

copy_if_exists() {
    local src="$1"
    local dst="$2"
    local mode="${3:-644}"
    local owner="${4:-root:root}"

    if [ -f "$src" ]; then
        install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dst"
    fi
}

service_restart() {
    local svc="$1"
    if systemctl list-unit-files | grep -q "^${svc}\.service"; then
        systemctl enable "$svc" >/dev/null 2>&1 || true
        systemctl restart "$svc"
    else
        error "未找到服务: $svc"
    fi
}

get_master_host_from_conf() {
    local conf="$1"
    if [ -f "$conf" ]; then
        awk -F= '/^SlurmctldHost=/{print $2; exit}' "$conf" | awk '{print $1}'
    fi
}

validate_munge() {
    if munge -n | unmunge >/dev/null 2>&1; then
        log "munge 正常"
    else
        error "munge 验证失败"
    fi
}

setup_munge_key() {
    ensure_dir "$MUNGE_ETC" 700 "$MUNGE_USER:$MUNGE_USER"

    if [ ! -f "$MUNGE_ETC/munge.key" ] || [ ! -s "$MUNGE_ETC/munge.key" ]; then
        if [ "$ROLE" = "master" ]; then
            log "生成 munge key"
            if command -v create-munge-key >/dev/null 2>&1; then
                create-munge-key -f
            else
                dd if=/dev/urandom of="$MUNGE_ETC/munge.key" bs=1024 count=1 status=none
            fi
        elif [ -f "$CONFIG_DIR/munge.key" ] && [ -s "$CONFIG_DIR/munge.key" ]; then
            log "从配置目录复制 munge.key"
            copy_if_exists "$CONFIG_DIR/munge.key" "$MUNGE_ETC/munge.key" 400 "$MUNGE_USER:$MUNGE_USER"
        else
            error "未找到 munge.key，请先在 master 节点生成并同步到 ${CONFIG_DIR}"
        fi
    fi

    chown "$MUNGE_USER:$MUNGE_USER" "$MUNGE_ETC/munge.key"
    chmod 400 "$MUNGE_ETC/munge.key"
}

sync_config_files() {
    ensure_dir "$SLURM_ETC" 755 root:root
    ensure_dir "$LOG_DIR" 755 "$SLURM_USER:$SLURM_USER"
    ensure_dir "$SLURMCTLD_SPOOL" 700 "$SLURM_USER:$SLURM_USER"
    ensure_dir "$SLURMD_SPOOL" 755 "$SLURM_USER:$SLURM_USER"

    copy_if_exists "$CONFIG_DIR/slurm.conf" "$SLURM_ETC/slurm.conf" 644 root:root
    copy_if_exists "$CONFIG_DIR/cgroup.conf" "$SLURM_ETC/cgroup.conf" 644 root:root
    copy_if_exists "$CONFIG_DIR/gres.conf" "$SLURM_ETC/gres.conf" 644 root:root

    if [ "$ROLE" = "master" ] && [ -f "$CONFIG_DIR/slurmdbd.conf" ]; then
        copy_if_exists "$CONFIG_DIR/slurmdbd.conf" "$SLURM_ETC/slurmdbd.conf" 600 "$SLURM_USER:$SLURM_USER"
    fi

    if [ ! -f "$SLURM_ETC/slurm.conf" ]; then
        error "未找到 slurm.conf：${CONFIG_DIR}/slurm.conf"
    fi

    if grep -q "MASTER_HOST_PLACEHOLDER" "$SLURM_ETC/slurm.conf"; then
        [ -n "$MASTER_HOST" ] || MASTER_HOST="$(hostname -s)"
        sed -i "s/MASTER_HOST_PLACEHOLDER/${MASTER_HOST}/g" "$SLURM_ETC/slurm.conf"
    fi

    if [ -z "$MASTER_HOST" ]; then
        MASTER_HOST="$(get_master_host_from_conf "$SLURM_ETC/slurm.conf" || true)"
    fi

    [ -n "$MASTER_HOST" ] || error "无法确定管理节点主机名，请通过第二个参数传入"

    if [ "$ROLE" = "worker" ] && ! grep -qE "^[[:space:]]*${MASTER_HOST}[[:space:]]*$|^SlurmctldHost=${MASTER_HOST}$" "$SLURM_ETC/slurm.conf"; then
        warn "slurm.conf 中未显式包含管理节点名：${MASTER_HOST}"
    fi

    if [ "$ROLE" = "worker" ] && [ -n "$MASTER_HOST" ] && ! grep -q "[[:space:]]${MASTER_HOST}[[:space:]]" /etc/hosts 2>/dev/null; then
        warn "建议将 ${MASTER_HOST} 解析到管理节点 IP，必要时手动配置 /etc/hosts"
    fi

    if [ "$ROLE" = "master" ] && [ ! -f "$CONFIG_DIR/munge.key" ] && [ -f "$MUNGE_ETC/munge.key" ]; then
        cp "$MUNGE_ETC/munge.key" "$CONFIG_DIR/munge.key" 2>/dev/null || true
        chmod 644 "$CONFIG_DIR/munge.key" 2>/dev/null || true
    fi

    if [ -f "$SLURM_ETC/slurmdbd.conf" ]; then
        chmod 600 "$SLURM_ETC/slurmdbd.conf"
        chown "$SLURM_USER:$SLURM_USER" "$SLURM_ETC/slurmdbd.conf"
    fi
}

stop_old_processes() {
    log "清理旧进程"
    systemctl stop slurmctld slurmd slurmdbd munge >/dev/null 2>&1 || true
    pkill -9 munged >/dev/null 2>&1 || true
    pkill -9 slurmdbd >/dev/null 2>&1 || true
    pkill -9 slurmctld >/dev/null 2>&1 || true
    pkill -9 slurmd >/dev/null 2>&1 || true
    rm -f /var/run/munge/munge.socket.* /var/run/munge/munged.pid
    rm -f /var/run/slurmctld.pid /var/run/slurmd.pid /var/run/slurmdbd.pid
    rm -f /var/spool/slurmctld/slurmctld.pid /var/spool/slurmd/slurmd.pid
}

start_services() {
    log "启动 munge"
    service_restart munge
    sleep 2
    validate_munge

    if [ "$ROLE" = "master" ]; then
        log "启动 slurmctld"
        service_restart slurmctld
        sleep 2
    fi

    log "启动 slurmd"
    service_restart slurmd
    sleep 2

    if [ "$ROLE" = "master" ] && [ -f "$SLURM_ETC/slurmdbd.conf" ]; then
        log "启动 slurmdbd"
        service_restart slurmdbd
        sleep 2
    fi
}

show_status() {
    echo "========================================"
    echo "服务状态"
    echo "========================================"
    for svc in munge slurmdbd slurmctld slurmd; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo "RUNNING  $svc"
        else
            echo "STOPPED  $svc"
        fi
    done

    echo ""
    if [ "$ROLE" = "master" ]; then
        echo "节点状态："
        sinfo 2>/dev/null || echo "slurmctld 尚未就绪"
    fi
}

main() {
    case "$ROLE" in
        master|worker)
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac

    require_root
    require_cmd systemctl
    require_cmd munge
    require_cmd unmunge
    require_cmd sinfo

    log "角色: ${ROLE}"
    log "管理节点: ${MASTER_HOST:-未指定}"
    log "配置目录: ${CONFIG_DIR}"

    sync_config_files
    setup_munge_key
    stop_old_processes
    start_services

    if [ "$ROLE" = "master" ]; then
        systemctl enable munge slurmctld slurmd >/dev/null 2>&1 || true
        [ -f "$SLURM_ETC/slurmdbd.conf" ] && systemctl enable slurmdbd >/dev/null 2>&1 || true
    else
        systemctl enable munge slurmd >/dev/null 2>&1 || true
    fi

    show_status

    echo ""
    echo "========================================"
    echo "部署完成"
    echo "========================================"
    if [ "$ROLE" = "master" ]; then
        echo "建议检查：sinfo / squeue / srun -N1 hostname"
    else
        echo "如节点未加入，请在 master 上执行: scontrol reconfigure"
    fi
}

main "$@"
