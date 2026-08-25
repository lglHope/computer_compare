#!/bin/bash
# =============================================================================
# Slurm 一键初始化部署脚本 v2
# 适用于：CentOS 7/8/9，Slurm 25.x
# 支持共享NFS配置模式（master和login共用同一份slurm.conf）
#
# 用法：
#   bash init-slurm.sh master   # 管理节点：slurmctld + slurmdbd + slurmd
#   bash init-slurm.sh login    # 登录/计算节点：slurmd
#   bash init-slurm.sh restart  # 重启所有服务
#   bash init-slurm.sh status   # 查看服务状态
#
# 环境变量（可选）：
#   MASTER_IP       管理节点IP（login节点必填，如 192.168.0.198）
#   CONFIG_SRC      配置文件源目录（默认 /data/ws01/slurm-config，NFS共享）
#   SLURM_RPM_SRC   RPM包源目录（默认 /data/ws01/slurm-rpms，NFS共享）
#   SETUP_DB        是否配置mariadb（master默认1，login默认0）
#   SHARED_CONFIG   是否使用共享配置（默认自动检测，NFS目录存在则为1）
# =============================================================================

set -e

ROLE="${1:-login}"
MASTER_IP="${MASTER_IP:-}"
CONFIG_SRC="${CONFIG_SRC:-/data/ws01/slurm-config}"
SLURM_RPM_SRC="${SLURM_RPM_SRC:-/data/ws01/slurm-rpms}"
SETUP_DB="${SETUP_DB:-0}"

# 自动检测是否使用共享配置
if [ -d "${CONFIG_SRC}" ] && [ -w "${CONFIG_SRC}" ]; then
    SHARED_CONFIG=1
else
    SHARED_CONFIG=0
fi

if [ "${ROLE}" == "master" ]; then
    SETUP_DB=1
fi

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

CURRENT_HOST=$(hostname -s)
info "角色: ${ROLE}  主机名: ${CURRENT_HOST}  共享配置: ${SHARED_CONFIG}"

# =============================================================================
# 步骤0：安装Slurm RPM包
# =============================================================================
install_slurm() {
    step "检查并安装Slurm包"

    if rpm -q slurm >/dev/null 2>&1; then
        info "Slurm已安装，跳过"
        rpm -qa | grep -E 'slurm|munge' | sort
        return 0
    fi

    # 配置本地yum源（如果RPM目录存在）
    if [ -d "${SLURM_RPM_SRC}" ] && ls "${SLURM_RPM_SRC}"/slurm-25.11*.rpm >/dev/null 2>&1; then
        info "使用本地yum源: ${SLURM_RPM_SRC}"
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
        YUM_OPTS="--disablerepo=epel --enablerepo=slurm-local"
    else
        warn "未找到本地RPM包，尝试从网络安装"
        YUM_OPTS=""
    fi

    info "安装Slurm包..."
    if [ "${ROLE}" == "master" ]; then
        yum install -y $YUM_OPTS slurm slurm-slurmctld slurm-slurmd slurm-slurmdbd slurm-pam_slurm munge munge-devel
    else
        yum install -y $YUM_OPTS slurm slurm-slurmd munge
    fi
    info "Slurm安装完成"
    rpm -qa | grep -E 'slurm|munge' | sort
}

# =============================================================================
# 步骤1：创建用户和组
# =============================================================================
create_users() {
    step "创建用户和组"

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

# =============================================================================
# 步骤2：创建目录并设置权限
# =============================================================================
create_dirs() {
    step "创建目录并设置权限"

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

    # slurmdbd
    if [ "${SETUP_DB}" == "1" ]; then
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

# =============================================================================
# 步骤3：配置数据库（master节点）
# =============================================================================
setup_database() {
    if [ "${SETUP_DB}" != "1" ]; then
        return 0
    fi

    step "配置MariaDB (slurmdbd)"

    if ! rpm -q mariadb-server >/dev/null 2>&1; then
        info "安装mariadb-server..."
        yum install -y mariadb mariadb-server >/dev/null 2>&1
    fi

    systemctl enable mariadb >/dev/null 2>&1
    systemctl restart mariadb
    sleep 3

    info "初始化slurm_acct_db数据库..."
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS slurm_acct_db CHARACTER SET utf8 COLLATE utf8_general_ci;" 2>/dev/null || true
    mysql -u root -e "DROP USER 'slurm'@'localhost';" 2>/dev/null || true
    mysql -u root -e "CREATE USER 'slurm'@'localhost' IDENTIFIED BY 'slurmpass_2026';" 2>/dev/null || true
    mysql -u root -e "GRANT ALL PRIVILEGES ON slurm_acct_db.* TO 'slurm'@'localhost'; FLUSH PRIVILEGES;"

    if mysql -u slurm -pslurmpass_2026 -e "USE slurm_acct_db; SELECT 1;" >/dev/null 2>&1; then
        info "数据库初始化完成"
    else
        warn "数据库验证失败，slurmdbd可能无法启动（不影响基本调度）"
    fi

    if [ -f "${CONFIG_SRC}/slurmdbd.conf" ]; then
        sed -i 's/^StoragePass=.*/StoragePass=slurmpass_2026/' "${CONFIG_SRC}/slurmdbd.conf"
        sed -i 's/^StorageLoc=.*/StorageLoc=slurm_acct_db/' "${CONFIG_SRC}/slurmdbd.conf"
        sed -i 's/^StorageUser=.*/StorageUser=slurm/' "${CONFIG_SRC}/slurmdbd.conf"
    fi
}

# =============================================================================
# 步骤4：配置文件
# =============================================================================
setup_config() {
    step "配置文件"

    local SLURM_CONF=""

    # ---------- 准备配置源 ----------
    if [ "${SHARED_CONFIG}" == "1" ]; then
        info "使用共享配置模式 (NFS: ${CONFIG_SRC})"
        SLURM_CONF="${CONFIG_SRC}/slurm.conf"

        # 如果共享目录中没有slurm.conf或是空的，从本地模板初始化
        if [ ! -f "${SLURM_CONF}" ] || [ ! -s "${SLURM_CONF}" ]; then
            # 从本地/etc/slurm或CONFIG_SRC查找模板
            if [ -f "${CONFIG_SRC}/slurm.conf.template" ]; then
                cp "${CONFIG_SRC}/slurm.conf.template" "${SLURM_CONF}"
            elif [ -f /etc/slurm/slurm.conf ] && [ ! -L /etc/slurm/slurm.conf ]; then
                cp /etc/slurm/slurm.conf "${SLURM_CONF}"
            else
                error "未找到slurm.conf模板，请确保${CONFIG_SRC}/slurm.conf存在"
            fi
        fi

        # cgroup.conf
        if [ ! -f "${CONFIG_SRC}/cgroup.conf" ] || [ ! -s "${CONFIG_SRC}/cgroup.conf" ]; then
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

        # 创建符号链接 /etc/slurm/slurm.conf -> 共享文件
        rm -f /etc/slurm/slurm.conf /etc/slurm/cgroup.conf
        ln -sf "${SLURM_CONF}" /etc/slurm/slurm.conf
        ln -sf "${CONFIG_SRC}/cgroup.conf" /etc/slurm/cgroup.conf
        info "  /etc/slurm/slurm.conf -> ${SLURM_CONF}"
    else
        info "使用本地配置模式"
        SLURM_CONF="/etc/slurm/slurm.conf"
        if [ -f "${CONFIG_SRC}/slurm.conf" ]; then
            cp "${CONFIG_SRC}/slurm.conf" /etc/slurm/
        fi
        if [ -f "${CONFIG_SRC}/cgroup.conf" ]; then
            cp "${CONFIG_SRC}/cgroup.conf" /etc/slurm/
        fi
    fi

    # ---------- slurmdbd.conf（仅master，本地副本） ----------
    if [ "${ROLE}" == "master" ]; then
        if [ -f "${CONFIG_SRC}/slurmdbd.conf" ]; then
            cp "${CONFIG_SRC}/slurmdbd.conf" /etc/slurm/slurmdbd.conf
            chown slurm:slurm /etc/slurm/slurmdbd.conf
            chmod 600 /etc/slurm/slurmdbd.conf
            info "  已配置 slurmdbd.conf"
        fi
    fi

    # ---------- 确定MASTER_HOST ----------
    local MASTER_HOST=""
    if [ "${ROLE}" == "master" ]; then
        MASTER_HOST="${CURRENT_HOST}"
    else
        # login节点：从共享配置读取SlurmctldHost
        if [ -f "${SLURM_CONF}" ]; then
            MASTER_HOST=$(grep "^SlurmctldHost=" "${SLURM_CONF}" | head -1 | cut -d= -f2 | awk '{print $1}')
        fi
        if [ -z "${MASTER_HOST}" ] || [ "${MASTER_HOST}" == "MASTER_HOST_PLACEHOLDER" ]; then
            error "无法确定Master主机名，请先在master节点运行此脚本"
        fi
    fi
    info "Master主机名: ${MASTER_HOST}"

    # ---------- 替换占位符 ----------
    if grep -q "MASTER_HOST_PLACEHOLDER" "${SLURM_CONF}" 2>/dev/null; then
        sed -i "s/MASTER_HOST_PLACEHOLDER/${MASTER_HOST}/g" "${SLURM_CONF}"
        info "  已设置SlurmctldHost=${MASTER_HOST}"
    fi

    # ---------- munge.key ----------
    if [ "${ROLE}" == "master" ]; then
        if [ ! -f /etc/munge/munge.key ] || [ ! -s /etc/munge/munge.key ]; then
            info "  生成munge.key..."
            if command -v create-munge-key >/dev/null 2>&1; then
                create-munge-key -f
            else
                dd if=/dev/urandom of=/etc/munge/munge.key bs=1024 count=1 2>/dev/null
            fi
        fi
        # 共享munge.key
        if [ "${SHARED_CONFIG}" == "1" ]; then
            cp /etc/munge/munge.key "${CONFIG_SRC}/munge.key"
            chmod 644 "${CONFIG_SRC}/munge.key"
            info "  munge.key已共享到 ${CONFIG_SRC}/munge.key"
        fi
    else
        if [ ! -f /etc/munge/munge.key ] || [ ! -s /etc/munge/munge.key ]; then
            if [ -f "${CONFIG_SRC}/munge.key" ] && [ -s "${CONFIG_SRC}/munge.key" ]; then
                info "  从共享目录复制munge.key"
                cp "${CONFIG_SRC}/munge.key" /etc/munge/munge.key
            else
                error "未找到munge.key！请先在master节点运行此脚本"
            fi
        fi
    fi
    chown munge:munge /etc/munge/munge.key
    chmod 400 /etc/munge/munge.key

    # ---------- /etc/hosts 解析 ----------
    if [ "${ROLE}" == "login" ] && [ -n "${MASTER_IP}" ]; then
        # 确保master主机名能解析到MASTER_IP
        if ! grep -q "[[:space:]]${MASTER_HOST}[[:space:]]" /etc/hosts; then
            info "  添加hosts映射: ${MASTER_IP} ${MASTER_HOST}"
            echo "${MASTER_IP} ${MASTER_HOST}" >> /etc/hosts
        else
            info "  hosts映射已存在: $(grep "[[:space:]]${MASTER_HOST}[[:space:]]" /etc/hosts)"
        fi
    elif [ "${ROLE}" == "master" ] && [ -z "${MASTER_IP}" ]; then
        # master节点获取自己的IP（用于提示）
        MASTER_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
        info "Master IP: ${MASTER_IP}"
    fi

    # ---------- 添加当前节点到NodeName列表（如果不存在） ----------
    if ! grep -q "^NodeName=${CURRENT_HOST} " "${SLURM_CONF}"; then
        HW_INFO=$(/usr/sbin/slurmd -C 2>/dev/null | head -1 | sed 's/UpTime=.*//')
        if [ -n "${HW_INFO}" ]; then
            local FEATURE="login"
            [ "${ROLE}" == "master" ] && FEATURE="master"
            info "  自动添加节点: ${HW_INFO} Feature=${FEATURE}"
            echo "${HW_INFO} State=UNKNOWN Feature=${FEATURE}" >> "${SLURM_CONF}"
        fi
    else
        info "  节点 ${CURRENT_HOST} 已在配置中"
    fi

    # ---------- 确保AccountingStorageType设置 ----------
    if ! grep -q "^AccountingStorageType=" "${SLURM_CONF}"; then
        echo "AccountingStorageType=accounting_storage/none" >> "${SLURM_CONF}"
    fi

    info "配置文件清单:"
    ls -la /etc/slurm/ /etc/munge/munge.key 2>/dev/null
    echo ""
    info "=== slurm.conf 节点配置 ==="
    grep "^NodeName\|^SlurmctldHost\|^PartitionName\|^ClusterName" "${SLURM_CONF}"
}

# =============================================================================
# 步骤5：停止旧进程
# =============================================================================
stop_services() {
    step "停止旧进程"
    pkill -9 munged 2>/dev/null || true
    pkill -9 slurmdbd 2>/dev/null || true
    pkill -9 slurmctld 2>/dev/null || true
    pkill -9 slurmd 2>/dev/null || true
    sleep 2
    rm -f /var/run/munge/munge.socket.* /var/run/munge/munged.pid
    rm -f /var/run/slurmctld.pid /var/run/slurmd.pid /var/run/slurmdbd.pid
    rm -f /var/spool/slurmctld/slurmctld.pid /var/spool/slurmd/slurmd.pid
    info "旧进程已清理"
}

# =============================================================================
# 步骤6：启动服务
# =============================================================================
start_munge() {
    step "启动munge"
    runuser -u munge -- munged
    sleep 2
    if [ -S /var/run/munge/munge.socket.2 ]; then
        info "munged启动成功"
        munge -n | unmunge 2>&1 | grep -q "Success" && info "munge认证测试通过"
    else
        cat /var/log/munge/munged.log 2>/dev/null | tail -20
        error "munged启动失败"
    fi
}

start_slurmdbd() {
    if [ "${ROLE}" != "master" ]; then return 0; fi
    step "启动slurmdbd"
    rm -rf /var/spool/slurmdbd/* 2>/dev/null || true
    chown slurm:slurm /var/spool/slurmdbd
    > /var/log/slurm/slurmdbd.log
    /usr/sbin/slurmdbd
    sleep 3
    if pgrep -x slurmdbd >/dev/null; then
        info "slurmdbd启动成功"
    else
        cat /var/log/slurm/slurmdbd.log
        warn "slurmdbd启动失败（可能MariaDB版本不兼容，不影响基本调度）"
    fi
}

start_slurmctld() {
    if [ "${ROLE}" != "master" ]; then return 0; fi
    step "启动slurmctld"
    rm -rf /var/spool/slurmctld/*
    chown slurm:slurm /var/spool/slurmctld
    > /var/log/slurm/slurmctld.log
    /usr/sbin/slurmctld -c
    sleep 4
    if pgrep -x slurmctld >/dev/null; then
        info "slurmctld启动成功"
    else
        cat /var/log/slurm/slurmctld.log
        error "slurmctld启动失败"
    fi
}

start_slurmd() {
    step "启动slurmd"
    rm -rf /var/spool/slurmd/*
    chown slurm:slurm /var/spool/slurmd
    > /var/log/slurm/slurmd.log
    /usr/sbin/slurmd
    sleep 4
    if pgrep -x slurmd >/dev/null; then
        info "slurmd启动成功"
    else
        cat /var/log/slurm/slurmd.log
        error "slurmd启动失败"
    fi
}

# =============================================================================
# 步骤7：设置开机自启
# =============================================================================
setup_autostart() {
    step "设置开机自启"
    local rc_local="/etc/rc.d/rc.local"
    touch $rc_local
    chmod +x $rc_local

    # 移除旧的slurm启动项
    sed -i '/# Slurm autostart/,+15d' $rc_local 2>/dev/null || true

    cat >> $rc_local << EOF

# Slurm autostart - $(date)
sleep 10
mkdir -p /var/run/munge /var/log/munge /var/spool/slurmctld /var/spool/slurmd
chown munge:munge /var/run/munge /var/log/munge
chown slurm:slurm /var/spool/slurmctld /var/spool/slurmd
chmod 755 /var/run/munge
runuser -u munge -- munged
sleep 2
EOF
    if [ "${ROLE}" == "master" ]; then
        echo "/usr/sbin/slurmdbd 2>/dev/null" >> $rc_local
        echo "sleep 1" >> $rc_local
        echo "/usr/sbin/slurmctld -c 2>/dev/null" >> $rc_local
        echo "sleep 1" >> $rc_local
    fi
    echo "/usr/sbin/slurmd" >> $rc_local
    info "已添加到 $rc_local"
}

# =============================================================================
# 步骤8：验证
# =============================================================================
verify() {
    step "验证"
    sleep 4

    if [ "${ROLE}" == "master" ]; then
        # 激活所有节点
        info "激活所有节点..."
        scontrol update nodename=ALL state=resume reason=ready 2>/dev/null || true
        sleep 3

        info "节点状态:"
        sinfo || warn "sinfo失败"

        echo ""
        info "进程列表:"
        ps aux | grep -E 'munged|slurmctld|slurmdbd|slurmd' | grep -v grep

        echo ""
        info "测试作业: srun hostname"
        srun --wait=10 hostname 2>&1 || warn "作业提交失败"

        echo ""
        info "============================================"
        info "  Master节点部署完成！"
        info "============================================"
        info "  管理节点: ${MASTER_HOST} (${MASTER_IP})"
        info ""
        info "  在login/计算节点执行以下命令加入集群:"
        info "  MASTER_IP=${MASTER_IP} bash ${CONFIG_SRC}/init-slurm.sh login"
    else
        info "Login节点进程:"
        ps aux | grep -E 'munged|slurmd' | grep -v grep

        echo ""
        # 尝试通知master重新加载配置
        if [ -n "${MASTER_IP}" ] && command -v sshpass >/dev/null 2>&1; then
            info "通知master(${MASTER_IP})重新加载配置..."
            sshpass -p '1234@QAZxswidfuht' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@${MASTER_IP} \
                "scontrol reconfigure 2>&1; scontrol update nodename=ALL state=resume reason=newnode 2>&1; sinfo" 2>&1 || \
                warn "无法通知master，请在master上手动执行: scontrol reconfigure"
        elif [ -n "${MASTER_IP}" ]; then
            warn "未安装sshpass，无法自动通知master。请在master上执行: scontrol reconfigure"
        fi

        echo ""
        info "============================================"
        info "  Login/计算节点部署完成！"
        info "============================================"
        info "  请在master节点执行 sinfo 确认节点已加入"
    fi
}

# =============================================================================
# 状态查看
# =============================================================================
show_status() {
    echo "=== 服务状态 ==="
    for svc in munged slurmdbd slurmctld slurmd; do
        if pgrep -x $svc >/dev/null; then
            echo -e "${GREEN}RUNNING${NC}  $svc (pid $(pgrep -x $svc))"
        else
            echo -e "${RED}STOPPED${NC}  $svc"
        fi
    done
    echo ""
    if [ "${ROLE}" == "master" ]; then
        echo "=== 节点状态 ==="
        sinfo 2>/dev/null || echo "slurmctld未就绪"
    fi
}

# =============================================================================
# 主流程
# =============================================================================
case "$ROLE" in
    master|login)
        install_slurm
        create_users
        create_dirs
        setup_database
        setup_config
        stop_services
        start_munge
        start_slurmdbd
        start_slurmctld
        start_slurmd
        setup_autostart
        verify
        ;;
    restart)
        stop_services
        start_munge
        if [ "${ROLE}" == "master" ] || grep -q slurmctld /etc/rc.d/rc.local 2>/dev/null; then
            /usr/sbin/slurmdbd 2>/dev/null && sleep 1
            /usr/sbin/slurmctld -c 2>/dev/null && sleep 1
        fi
        /usr/sbin/slurmd 2>/dev/null
        sleep 2
        show_status
        ;;
    status)
        show_status
        ;;
    *)
        echo "Slurm 初始化脚本 v2"
        echo ""
        echo "用法: $0 {master|login|restart|status}"
        echo "  master  - 管理节点（slurmctld + slurmdbd + slurmd + 数据库）"
        echo "  login   - 登录/计算节点（slurmd）"
        echo "  restart - 重启所有服务"
        echo "  status  - 查看状态"
        echo ""
        echo "环境变量:"
        echo "  MASTER_IP   管理节点IP（login节点必填）"
        echo "  CONFIG_SRC  配置目录（默认 /data/ws01/slurm-config）"
        exit 1
        ;;
esac
