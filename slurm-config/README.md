# Slurm 25.11.0 配置参考

适用于EDA/OPC/Mask计算集群的Slurm配置模板。

## 文件清单

| 文件 | 说明 | 部署位置 |
|------|------|----------|
| `slurm.conf` | Slurm主配置文件，定义集群、节点、分区、调度器 | `/etc/slurm/slurm.conf`（所有节点） |
| `cgroup.conf` | cgroup资源限制配置 | `/etc/slurm/cgroup.conf`（所有节点） |
| `slurmdbd.conf` | 数据库记账服务配置（可选） | `/etc/slurm/slurmdbd.conf`（仅slurmdbd节点，权限600） |
| `gres.conf` | GPU/Generic资源配置（如有GPU） | `/etc/slurm/gres.conf`（GPU节点） |
| `init-slurm.sh` | 全功能一键部署/自检脚本（推荐，v3） | 任意位置 |
| `setup-slurm.sh` | 轻量配置同步脚本（包已装好时用） | 任意位置 |

## 快速部署步骤

### 0. 使用 init-slurm.sh 一键部署（推荐）

`init-slurm.sh` 支持 5 种模式：`master` / `login` / `restart` / `status` / `check`，适合从零部署新节点。它会自动完成：

- 安装 Slurm RPM（优先本地 RPM 目录，否则走网络 yum 源）
- 创建 munge/slurm 用户与目录权限
- 生成/共享 `munge.key`、同步 `slurm.conf` 等配置（支持 NFS 共享配置目录）
- master 上安装并初始化 MariaDB + slurmdbd 记账
- 启动服务、写入 `/etc/rc.d/rc.local` 开机自启
- 部署后自检：munge 认证、集群身份一致性、配置语法、端口、时钟、防火墙、节点注册等待、测试作业、日志扫描等（PASS/WARN/FAIL 汇总）

**部署顺序：先 master，后逐台 login/计算节点。**

```bash
# 1) master 节点（自动装包、建库、生成并共享 munge.key）
bash init-slurm.sh master

# 2) 每台 login/计算节点（自动拉取 munge.key 并注册进集群）
MASTER_IP=<master节点IP> bash init-slurm.sh login

# 3) 日常运维
bash init-slurm.sh status    # 查看角色、进程、节点、记账状态
bash init-slurm.sh restart   # 按本机角色重启全部服务
bash init-slurm.sh check     # 只读自检，不修改任何配置
```

可选环境变量：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `MASTER_IP` | 空 | 管理节点 IP，login 节点建议填写 |
| `CONFIG_SRC` | `/data/ws01/slurm-config` | 共享配置目录 |
| `SLURM_RPM_SRC` | `/data/ws01/slurm-rpms` | RPM 包目录（不存在则走网络源） |
| `SETUP_DB` | master=1，login=0 | 是否初始化 MariaDB/slurmdbd |
| `DB_PASS` | `slurmpass_2026` | slurmdbd 数据库密码 |
| `NODE_REG_WAIT` | `120` | 等待节点注册超时（秒） |
| `TEST_TIMEOUT` | `90` | 测试作业超时（秒） |

> `setup-slurm.sh` 是轻量备选：不装包、不建用户、不碰数据库，只把 `CONFIG_DIR`（默认 `/data/ws01/slurm-config`）下的配置复制到本地并通过 systemd 拉起服务。适合包已装好、只改配置重发的场景。两种脚本不要在同一节点混用。

### 1. 准备工作（手动方式，不使用脚本时）

在所有节点上通过yum安装Slurm包（本地yum源已配置）：
```bash
# 管理节点
yum install -y slurm slurm-slurmctld slurm-slurmd slurm-pam_slurm

# 计算节点
yum install -y slurm slurm-slurmd slurm-pam_slurm
```

### 2. 修改slurm.conf

编辑`slurm.conf`，修改以下字段匹配你的环境：

- `ClusterName`：集群名称
- `SlurmctldHost`：管理节点主机名（用`hostname -s`查看）
- `NodeName`行：根据实际服务器配置填写
  - `CPUs`：逻辑核数（超线程算2倍）
  - `RealMemory`：节点实际可用内存（MB，建议比物理内存少5-10GB给系统）
  - `Sockets/CoresPerSocket/ThreadsPerCore`：CPU拓扑
  - `Feature`：节点特性标签（opc/mask/bigmem等）
- `PartitionName`：分区配置

### 3. 配置munge（关键！）

所有节点必须使用**同一个munge.key**：
```bash
# 在管理节点上
/usr/sbin/create-munge-key -f
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key

# 复制到所有计算节点
scp /etc/munge/munge.key root@compute01:/etc/munge/
ssh root@compute01 "chown munge:munge /etc/munge/munge.key; chmod 400 /etc/munge/munge.key"
```

### 4. 启动服务

**管理节点（master）：**
```bash
mkdir -p /var/log/slurm /var/spool/slurmctld /var/spool/slurmd
chown slurm:slurm /var/log/slurm /var/spool/slurmctld /var/spool/slurmd

systemctl enable munge slurmctld slurmd
systemctl restart munge
sleep 2
systemctl restart slurmctld slurmd
```

**计算节点（worker）：**
```bash
mkdir -p /var/log/slurm /var/spool/slurmd
chown slurm:slurm /var/log/slurm /var/spool/slurmd

systemctl enable munge slurmd
systemctl restart munge
sleep 2
systemctl restart slurmd
```

或使用脚本（见上文"第 0 节"，推荐 `init-slurm.sh`，它会自动完成本节及前后所有手动步骤）。`setup-slurm.sh` 仅适合包已装好的机器快速重发配置：

```bash
# 管理节点
bash /data/ws01/slurm-config/setup-slurm.sh master

# 计算节点（munge.key 需已存在于配置目录！）
bash /data/ws01/slurm-config/setup-slurm.sh worker
```

### 5. 验证

```bash
sinfo          # 查看节点状态，应该显示idle
srun -N1 hostname  # 运行测试作业
squeue         # 查看队列
scontrol show nodes  # 查看节点详情
```

如果节点状态是`down`：
```bash
scontrol update nodename=<节点名> state=resume reason=reset
```

## EDA作业调度最佳实践

### OPC作业（大内存、CPU密集）

```bash
#!/bin/bash
#SBATCH --job-name=opc_job
#SBATCH --partition=opc
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=64
#SBATCH --mem=500G
#SBATCH --time=3-0
#SBATCH --exclusive

cd $SLURM_SUBMIT_DIR
srun --cpu-bind=cores your_opc_command
```

### Mask作业（大IO、多线程）

```bash
#!/bin/bash
#SBATCH --job-name=mask_job
#SBATCH --partition=mask
#SBATCH --nodes=1
#SBATCH --cpus-per-task=32
#SBATCH --mem=200G
#SBATCH --time=2-0

cd $SLURM_SUBMIT_DIR
your_mask_command -t $SLURM_CPUS_PER_TASK -i $WORKDIR
```

## 常见问题

### 节点启动后状态为*drain*

原因：`RealMemory`配置超过实际可用内存，或配置不匹配。

解决：
1. 用`free -m`查看实际内存
2. 修改`slurm.conf`中`RealMemory`值（建议留5GB余量）
3. `scontrol reconfigure`重新加载配置
4. `scontrol update nodename=<名> state=resume`

### munge认证失败

检查：
- 所有节点`/etc/munge/munge.key`完全相同，权限400，属主munge
- 所有节点时间同步（ntp/chrony），时间差不能超过5分钟
- munge服务在所有节点运行

### 作业被kill显示OutOfMemory

- 检查作业申请的`--mem`是否足够
- cgroup.conf中`AllowedRAMSpace=100`为硬限制，超内存就kill
- 可临时调大到`AllowedRAMSpace=110`允许10%超限，但不推荐

## 参考命令速查

| 命令 | 用途 |
|------|------|
| `sinfo` | 查看节点/分区状态 |
| `squeue` | 查看作业队列 |
| `sbatch script.sh` | 提交批处理作业 |
| `srun <cmd>` | 交互式运行作业 |
| `scancel <jobid>` | 取消作业 |
| `scontrol show job <jobid>` | 查看作业详情 |
| `scontrol show node <nodename>` | 查看节点详情 |
| `scontrol reconfigure` | 重新加载配置 |
| `sacct` | 查看历史作业（需启用slurmdbd） |
| `sreport` | 生成报表（需slurmdbd） |
