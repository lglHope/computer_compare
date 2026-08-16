# 配置参考：第一次跑测试要填什么

这份文件给“刚开始跑测试的人”看。目标很简单：告诉你 `config/eval.yaml` 里哪些项要填、填什么、什么时候可以先用默认值。

---

## 先说结论

如果你只是先试跑，通常只需要确认这几类信息：

- `environment.shared_fs`：如果业务是在 NFS / 并行文件系统上跑，就填共享挂载点
- `environment.scratch`：本地临时目录，作为兜底
- `baseline` / `candidate`：两台机型的实际规格和价格
- `environment.license_server`：如果有 EDA 许可证就填，没有就留空

其它参数大多数都可以先用默认值。

---

## 哪些字段必须填

### 1) `project` / `region` / `az`

这是你在云上实际使用的项目和地域信息。

- `project`：云项目名、资源组名或你们内部用于隔离资源的标识
- `region`：实例所在地域，例如 `cn-shanghai`
- `az`：可用区，例如 `cn-shanghai-b`

如果你不知道怎么写，就按你要创建测试机的控制台信息填写。

---

### 2) `environment.shared_fs`

这是最关键的一项。

如果你的真实业务环境是挂载 NFS / 并行文件系统来做计算，就把它填成那个挂载点，比如：

```yaml
environment:
  shared_fs: "/eda/projects"
```

填写规则：

- 这个路径必须在待测机器上已经挂载好
- 必须可读写
- 建议空间足够大，至少能容纳 Mask 代理默认的 16GB 文件以及临时文件

如果你的环境没有共享文件系统，就留空：

```yaml
environment:
  shared_fs: ""
```

当前脚本会优先使用 `shared_fs`；如果为空，再退回到 `scratch` 或 `/tmp`。

---

### 3) `environment.scratch`

这是本地临时目录，不是业务主工作目录。

推荐这样理解：

- 有共享文件系统时，`scratch` 只是兜底
- 没有共享文件系统时，`scratch` 才会更重要

常见填写方式：

```yaml
environment:
  scratch: "/scratch"
```

如果你的机器没有单独的本地盘，或者 `/scratch` 不存在，可以填：

```yaml
environment:
  scratch: "/tmp"
```

实操建议：

- 生产/HPC 场景优先填共享挂载点
- 机器上没有明确的本地临时盘时，直接用 `/tmp`

---

### 4) `environment.license_server`

如果你们有 EDA 许可证服务器，就填它；没有就留空。

示例：

```yaml
environment:
  license_server: "27000@license.eda.internal"
```

没有许可证时：

```yaml
environment:
  license_server: ""
```

留空后，网络探测步骤会跳过许可证检查。

---

### 5) `environment.scheduler`

按你的实际调度环境填写：

- `none`：裸机/普通虚机直接跑
- `slurm`：Slurm 集群
- `lsf`：LSF 集群
- `k8s`：Kubernetes 环境

如果你只是本地节点测试，通常填 `none`。

---

## `baseline` 和 `candidate` 要填什么

这两段是在做“旧机 vs 新机”对比时最重要的部分。

你需要分别填两台机器的真实信息。

### 必填项

- `name`：给这台机器起个好认的名字
- `instance_type`：云上实例规格名
- `vcpu`：vCPU 数
- `memory_gb`：内存大小，单位 GB
- `local_disk`：本地盘标识；没有就写 `none`
- `network_gbps`：网络带宽，按实例规格或实际测得值填写
- `hourly_price_cny`：每小时价格，单位人民币
- `notes`：备注，可写“现网主力”“候选新机型”等

### 示例

```yaml
baseline:
  name: baseline-c7-16xl
  instance_type: ecs.c7.16xlarge
  vcpu: 64
  memory_gb: 128
  local_disk: nvme-0
  network_gbps: 32
  hourly_price_cny: 12.80
  notes: "现网主力"
```

```yaml
candidate:
  name: candidate-c8i-16xl
  instance_type: ecs.c8i.16xlarge
  vcpu: 64
  memory_gb: 128
  local_disk: nvme-0
  network_gbps: 32
  hourly_price_cny: 13.50
  notes: "候选新机型"
```

### 这些值从哪里来

- `instance_type`：云控制台或实例创建页面
- `vcpu` / `memory_gb`：实例规格说明
- `network_gbps`：实例规格说明或你的实测结果
- `hourly_price_cny`：计费页、采购表、内部价格表
- `local_disk`：如果有本地 NVMe 盘，就填它的标识；如果没有明显本地盘，就填 `none`

### 不确定时怎么填

如果你一时查不到某个值：

- `name` 可以先随便起，便于区分
- `notes` 可以写“待确认”
- 但 `instance_type`、`vcpu`、`memory_gb`、`hourly_price_cny` 最好尽量填真实值

因为后面的对比报告会用这些字段做结论和成本判断。

---

## `microbench` 要不要改

一般不用。

这部分是微基准，默认值已经适合首次测试：

- `cpu_max_prime`：CPU 单核测试规模
- `stream_array_n`：内存带宽测试规模
- `fio_runtime_sec`：存储测试时长
- `fio_size`：fio 文件大小
- `iperf_sec`：网络测试时长
- `repeats`：重复次数

如果你只是第一次跑，建议先不要改这些值。

---

## `proxy` 要不要改

一般也不用。

这部分是代理负载，默认值已经可以先验证流程。

### 常见可调项

- `proxy.opc.grid`：OPC 代理规模
- `proxy.opc.iterations`：迭代次数
- `proxy.opc.processes`：进程数，`0` 表示自动使用全部逻辑核
- `proxy.mask.file_gb`：Mask 代理文件大小
- `proxy.mask.block_mb`：读写块大小
- `proxy.mask.checksum_rounds`：校验轮数

### 首次测试建议

直接用默认值。

如果只是想先确认整套流程能跑通，使用：

```bash
bash scripts/start.sh smoke
```

不要先改 `proxy` 参数。

---

## HPC / NFS 场景推荐怎么填

如果你的真实场景是“业务跑在共享文件系统上”，建议按下面思路配置：

```yaml
environment:
  shared_fs: "/eda/projects"
  scratch: "/tmp"
  license_server: ""
  scheduler: none
```

说明：

- `shared_fs` 指向业务真实使用的 NFS / 并行文件系统
- `scratch` 只作为兜底
- 如果没有许可证就留空
- 独立节点直接跑就填 `none`

---

## 最小可用示例

下面这个配置可以作为第一次测试的参考：

```yaml
project: your-project
region: cn-shanghai
az: cn-shanghai-b

environment:
  os_image: "centos7.9"
  shared_fs: "/eda/projects"
  scratch: "/tmp"
  license_server: ""
  scheduler: none

baseline:
  name: baseline
  instance_type: ecs.xxx
  vcpu: 64
  memory_gb: 128
  local_disk: none
  network_gbps: 32
  hourly_price_cny: 0.0
  notes: "待确认"

candidate:
  name: candidate
  instance_type: ecs.yyy
  vcpu: 64
  memory_gb: 128
  local_disk: none
  network_gbps: 32
  hourly_price_cny: 0.0
  notes: "待确认"
```

> 注意：上面的 `0.0` 和 `ecs.xxx` 只是占位，不适合最终正式对比。正式对比前请改成真实值。

---

## 推荐填写顺序

1. 先确认业务真实挂载点，把 `environment.shared_fs` 填好
2. 再确认两台机器的 `instance_type`、`vcpu`、`memory_gb`
3. 再补 `hourly_price_cny`
4. 如果有许可证，再填 `license_server`
5. `microbench` 和 `proxy` 先保持默认

---

## 运行前你只需要记住

如果你只想先开始：

- 有共享存储，就填 `shared_fs`
- 没共享存储，就留空，走 `scratch` / `/tmp`
- 先跑 `bash scripts/start.sh smoke`
- 确认没问题后，再跑 `baseline` / `candidate`

如果你还不确定填什么，先看 `config/eval.yaml` 的注释，再按这份参考补齐。
