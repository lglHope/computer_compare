#!/bin/bash
# Slurm 快速部署脚本（CentOS 7）
# 在管理节点和计算节点都执行一次
# 用法：bash setup-slurm.sh [master|worker]

set -e

ROLE="${1:-worker}"
MASTER_HOST="${2:-iv-yet48a2xhcnic5cfr78c}"  # 修改为管理节点主机名
CONFIG_DIR="/data/ws01/slurm-config"

echo "========================================"
echo "部署Slurm角色: ${ROLE}"
echo "管理节点: ${MASTER_HOST}"
echo "========================================"

# 创建目录
mkdir -p /etc/slurm /var/log/slurm /var/spool/slurmctld /var/spool/slurmd
chmod 755 /etc/slurm /var/log/slurm

# 从NFS复制配置文件（如果配置目录存在）
if [ -d "${CONFIG_DIR}" ]; then
    echo "从NFS复制配置文件..."
    cp ${CONFIG_DIR}/slurm.conf /etc/slurm/
    cp ${CONFIG_DIR}/cgroup.conf /etc/slurm/
    [ -f ${CONFIG_DIR}/slurmdbd.conf ] && cp ${CONFIG_DIR}/slurmdbd.conf /etc/slurm/ && chmod 600 /etc/slurm/slurmdbd.conf
    [ -f ${CONFIG_DIR}/gres.conf ] && cp ${CONFIG_DIR}/gres.conf /etc/slurm/
fi

# ========================================
# 配置munge（所有节点必须共用同一个key）
# ========================================
if [ ! -f /etc/munge/munge.key ]; then
    echo "生成munge key..."
    if [ "${ROLE}" == "master" ]; then
        /usr/sbin/create-munge-key -f
        chown munge:munge /etc/munge/munge.key
        chmod 400 /etc/munge/munge.key
        echo "管理节点munge key已生成，需要复制到其他节点:"
        echo "scp /etc/munge/munge.key root@worker:/etc/munge/"
    else
        echo "警告：计算节点请先从管理节点复制munge.key！"
    fi
fi

echo "启动munge服务..."
systemctl enable munge
systemctl restart munge
sleep 2

# 验证munge
munge -n | unmunge | grep -q "STATUS" && echo "munge正常" || { echo "munge异常"; exit 1; }

# ========================================
# 管理节点: slurmctld
# ========================================
if [ "${ROLE}" == "master" ]; then
    echo "配置管理节点..."
    chown slurm:slurm /var/spool/slurmctld /var/log/slurm

    # 如果需要数据库记账
    # systemctl enable mariadb
    # systemctl start mariadb
    # echo "CREATE DATABASE IF NOT EXISTS slurm_acct_db; CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY 'slurm_db_password_here'; GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost'; FLUSH PRIVILEGES;" | mysql
    # systemctl enable slurmdbd
    # systemctl restart slurmdbd
    # sleep 3

    systemctl enable slurmctld
    systemctl restart slurmctld
    sleep 3
    systemctl status slurmctld --no-pager | head -20
fi

# ========================================
# 计算节点: slurmd
# ========================================
echo "配置计算节点..."
chown slurm:slurm /var/spool/slurmd /var/log/slurm

systemctl enable slurmd
systemctl restart slurmd
sleep 2
systemctl status slurmd --no-pager | head -20

echo ""
echo "========================================"
echo "部署完成！"
echo "========================================"
if [ "${ROLE}" == "master" ]; then
    echo "验证命令："
    echo "  sinfo       - 查看节点状态"
    echo "  srun -N1 hostname  - 测试作业"
    echo "  squeue      - 查看作业队列"
    echo ""
    echo "如节点显示down，用下面命令置上："
    echo "  scontrol update nodename=<节点名> state=resume"
fi
