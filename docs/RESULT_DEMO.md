# 结果长什么样（样张）

下面是**示意数字**，方便对照你机器上的文件。真实数值会不同。

## 单机跑完后的目录

```text
results/baseline-ecs.c7.16xlarge-20260815T134800/
  summary.json              ← 对比时只要这个（总入口）
  sysinfo.json
  cpu/cpu.json
  memory/memory.json
  storage/storage.json
  network/network.json
  proxy/opc.json            ← 含 hostload（跑 OPC 时代码在采的负载）
  proxy/mask.json
  proxy/load_opc/samples.jsonl
  proxy/load_opc/summary.json
  proxy/load_mask/...
```

用中文看一次（把路径换成你的）：

```bash
bash scripts/start.sh show results/baseline-ecs.c7.16xlarge-20260815T134800
```

屏幕上会类似：

```text
======== 本次测试摘要 ========
角色（旧机 baseline / 新机 candidate）：baseline
机型标记 INSTANCE_ID：ecs.c7.16xlarge
结果目录：.../results/baseline-ecs.c7.16xlarge-20260815T134800
[CPU]
  单核 events/s : 1850.200
  多核 events/s : 92100.000
  并行效率      : 0.779
[内存带宽 STREAM]
  单核 Triad    : 18.400 GB/s
  整机 Triad    : 186.200 GB/s
[OPC 代理]  （近似光学邻近校正：算得多、吃内存带宽）
  墙钟          : 412.500 秒
  期间 CPU 平均 : 97.200 %
  期间 内存平均 : 38.600 GB
[Mask 代理]  （近似掩模数据准备：大文件读写）
  墙钟          : 188.300 秒
  期间 CPU 平均 : 42.000 %
  期间 磁盘读   : 1850.000 MB/s
  期间 磁盘写   : 1620.000 MB/s
```

读法：OPC 那一段 CPU 接近 100% 很常见；Mask 那一段磁盘 MB/s 很高、CPU 不一定满，也常见。

## 对比报告 `results/compare_report.md`

两台机器的 `summary.json` 做完 `start.sh compare` 后：

```markdown
# 新机型引入对比报告

- Baseline：`ecs.c7.16xlarge` (baseline)
- Candidate：`ecs.c8i.16xlarge` (candidate)
- **建议结论：GO（待金标补齐）**

| 指标 | Baseline | Candidate | 比值(C/B) | 门禁 | 说明 |
|------|----------|-----------|-----------|------|------|
| CPU 单核 events/s | 1850.200 | 1920.100 | 1.038 | PASS | 绑核 1 线程，越高越好 |
| CPU 多核 events/s | 92100.000 | 98000.000 | 1.064 | PASS | 满逻辑核，越高越好 |
| 内存带宽 单核 Triad GB/s | 18.400 | 19.100 | 1.038 | PASS | 1 线程 STREAM |
| 内存带宽 整机 Triad GB/s | 186.200 | 211.000 | 1.133 | PASS | 满核 STREAM，OPC 强相关 |
| OPC 代理墙钟 s | 412.500 | 371.000 | 0.899 | PASS | 越低越好 |
| Mask 代理墙钟 s | 188.300 | 179.000 | 0.951 | PASS | 越低越好 |
| OPC 期间 CPU% avg | 97.200 | 96.800 | 0.996 | INFO | 代理期间整机 CPU |
| Mask 期间 磁盘读 MB/s avg | 1850.000 | 2010.000 | 1.086 | INFO | 物理盘合计 |
| OPC 金标平均墙钟 s | - | - | - | SKIP |  |
| Mask 金标正确性 | None | None | - | SKIP |  |
```

- 墙钟比值 **小于 1**：新机更快。  
- CPU/带宽比值 **大于 1**：新机吞吐更高。  
- 金标为 SKIP：还没跑厂里真实 OPC/Mask 工具，结论带「待金标补齐」是正常的。
