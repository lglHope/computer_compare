# 操作手册（按步骤抄命令）

对象：Linux 计算节点（含 CentOS 7.9）。不需要懂 Python。  
记住一个入口即可：`bash scripts/start.sh`

OPC = 光学邻近校正（偏计算、吃内存带宽）  
Mask = 掩模数据准备 / Fracture 等（偏超大文件读写）  
本套件用「代理程序」模仿这两种形态，**不是**厂里的真实 EDA 工具。

---

## 开始前准备

1. 用 `root` 或能 `sudo` 的账号登录待测机器。
2. 把本目录放到例如 `/opt/instance-type-eval`。
3. 确认磁盘：试跑大约几 GB；正式跑 Mask 默认约 16GB 文件，scratch 建议空闲 **40GB 以上**。

```bash
cd /opt/instance-type-eval    # 改成你实际放置的路径
ls scripts/start.sh           # 能列出这个文件就对了
df -h /scratch /tmp           # 看空闲空间
```

**你会看到：** `scripts/start.sh` 被列出；`df` 有一列 `Avail`（可用空间）。

---

## 第 1 步：安装依赖（每台机器一次）

```bash
cd /opt/instance-type-eval
sudo bash scripts/start.sh install
```

**过程中正常现象：** yum/dnf 刷很长一串包名；CentOS 7 可能提示已切换到 `vault.centos.org`。

**成功时结尾类似：**

```text
======== [安装 3/3] 检查命令是否都在 ========
Python 3.6.8
  OK  python3
  OK  gcc
  OK  sysbench
  OK  fio
  OK  iperf3
  OK  jq
  OK  numactl
  OK  ethtool
  OK  PyYAML
bootstrap 完成。
下一步（普通用户即可）： bash scripts/start.sh smoke
```

若某行是 `MISSING`：把整段终端保存下来，先解决缺包再继续。  
若提示「请使用 root 或 sudo」：你漏了 `sudo`。

---

## 第 2 步：试跑（强烈建议先做）

缩小数据量，只验证「能跑通、能出文件」。

```bash
cd /opt/instance-type-eval
bash scripts/start.sh smoke
```

**过程中正常现象：** 屏幕出现 `[1/7]` … `[7/7]`；中间有 JSON 数字。不要 Ctrl+C。

**成功时结尾类似：**

```text
======== 本次测试摘要 ========
角色（旧机 baseline / 新机 candidate）：smoke
机型标记 INSTANCE_ID：your-hostname
结果目录：/opt/instance-type-eval/results/smoke-your-hostname-20260815T180000
[CPU]
  单核 events/s : 1800.000
  多核 events/s : 90000.000
...
本机测试完成: .../summary.json
```

再看目录：

```bash
bash scripts/start.sh list
bash scripts/start.sh show results/smoke-你的主机名-时间/
```

**你会看到：** `list` 打出带 `[有 summary.json]` 的目录；`show` 再打印一遍中文摘要。

---

## 第 3 步：正式测试（旧机、新机各做一遍）

在**旧机型**上：

```bash
cd /opt/instance-type-eval
bash scripts/start.sh run baseline
```

在**新机型**上（同样的代码目录）：

```bash
bash scripts/start.sh run candidate
```

时间可能很长（Mask 要写大文件）。成功标志与试跑相同，角色变成 `baseline` 或 `candidate`。

把整份 `results/某次目录/` 拷到同一台 Linux（U 盘、scp 均可）。只要里面有 `summary.json` 就能对比。

```bash
# 示例：从旧机拷到当前机
scp -r user@旧机IP:/opt/instance-type-eval/results/baseline-* ./results/
scp -r user@新机IP:/opt/instance-type-eval/results/candidate-* ./results/
bash scripts/start.sh list
```

---

## 第 4 步：出对比报告

把 `list` 里的两条路径填进去（先旧机，后新机）：

```bash
bash scripts/start.sh compare \
  results/baseline-主机名-时间/summary.json \
  results/candidate-主机名-时间/summary.json
```

**成功时类似：**

```text
报告: /opt/instance-type-eval/results/compare_report.md
JSON: /opt/instance-type-eval/results/compare_report.json
结论: GO（待金标补齐）
```

打开报告：

```bash
less results/compare_report.md
```

表里的状态：

| 字 | 意思 |
|----|------|
| PASS | 这项新机相对旧机达到门禁 |
| FAIL | 这项没过，结论会变成 NO-GO |
| INFO | 代理跑的时候机器忙不忙，只帮助你看瓶颈 |
| SKIP | 没测（常见：还没跑真实 OPC/Mask 金标） |

结论三种：`GO` / `GO（待金标补齐）` / `NO-GO`。  
没跑厂里真实工具时，出现「待金标补齐」是正常的。

报告样张见 [RESULT_DEMO.md](RESULT_DEMO.md)。

---

## 常见问题

**Q：试跑就磁盘满？**  
`df -h` 看 `/scratch` 和 `/tmp`。可把 `config/eval.yaml` 里 `environment.scratch` 改到空闲盘，或先只用 `start.sh smoke`（Mask 只用 1GB）。

**Q：网络那步一闪而过？**  
没设对端 iperf 服务器会跳过，JSON 里 `skipped: true`。单机对比可以不管。

**Q：CPU/内存数字是 0 或空？**  
看该步是否报错。`sysbench`/`gcc` 若 MISSING，回到第 1 步重装。

**Q：还要不要改 yaml？**  
试跑不用改。正式对比前，把 `config/eval.yaml` 里两台机的机型名、单价改成真实值，报告里的成本才有意义。

更细的测试计划（给架构师）：[TEST_PLAN.md](TEST_PLAN.md)
