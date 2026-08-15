# 芯片 OPC / Mask 新机型评测套件

给「旧机型不够用、要试新机型」用。在 Linux 上安装一次，旧机和新机各跑一遍，再出对比报告。

**请从这里开始（逐步命令 + 每步会看到什么）：**  
**[docs/HANDBOOK.md](docs/HANDBOOK.md)**

结果文件长什么样：[docs/RESULT_DEMO.md](docs/RESULT_DEMO.md)

## 只要记这一条

```bash
cd /opt/instance-type-eval          # 改成你的目录
bash scripts/start.sh               # 打印 4 步说明
```

然后按提示：

```bash
sudo bash scripts/start.sh install  # 1. 安装（每台一次）
bash scripts/start.sh smoke         # 2. 试跑
bash scripts/start.sh run baseline  # 3. 旧机正式测
bash scripts/start.sh run candidate # 3. 新机正式测
bash scripts/start.sh compare 旧机/summary.json 新机/summary.json
```

## 这套东西测什么

| 步骤 | 测什么 | 白话 |
|------|--------|------|
| CPU | 单核 / 多核 | 一核有多快、64 核一起有多快 |
| 内存 | 单核 / 整机 STREAM | 一条通道和整机内存带宽 |
| 存储 / 网络 | fio、iperf（可选） | 盘和网 |
| OPC 代理 | 网格计算 + 采负载 | 近似光学邻近校正（吃 CPU/内存带宽） |
| Mask 代理 | 大文件扫写 + 采负载 | 近似掩模数据准备（吃磁盘） |

代理 **不能** 代替厂里真实 OPC/Mask 金标。方案细节见 [docs/TEST_PLAN.md](docs/TEST_PLAN.md)。
