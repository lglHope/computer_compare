# 真实EDA金标用例配置指南

当有真实OPC/Mask工具和许可证时，可以跳过代理测试，直接运行真实EDA金标用例。

## 配置步骤

### 1. 修改 `workloads/golden_cases.yaml`

将 `enabled: false` 改为 `enabled: true`，填入真实命令。

示例配置：

```yaml
cases:
  - id: P4-01
    name: opc-small
    domain: opc                    # opc 或 mask
    enabled: true                  # 改为true启用
    timeout_sec: 14400             # 超时时间（秒），4小时
    workdir: /data/ws01/opc/small  # 用例工作目录（建议在NFS上）
    command: |
      # 环境初始化
      source /opt/mentor/calibre/env.sh
      export CALIBRE_LICENSE_FILE=27000@license-server
      # 运行OPC，线程数使用 $NPROC（自动获取机器核数）
      calibre -drc -hier -turbo ${NPROC} opc_runset.rsf \
        -input design.gds \
        -output opc_result.gds
    verify: |
      # 结果校验：和金标比较，返回0表示通过
      # OPC通常使用容差比较
      calibre -compare -golden /eda/golden/opc/small/opc_result.gds \
        -current opc_result.gds \
        -tol 0.001

  - id: P4-04
    name: mask-mdp
    domain: mask
    enabled: true
    timeout_sec: 28800             # 8小时
    workdir: /data/ws01/mask/mdp
    command: |
      source /opt/mentor/calibre/env.sh
      calibremdp -threads ${NPROC} \
        -input opc_result.gds \
        -output fracture_result.oas \
        -fracture 10nm
    verify: |
      # Mask要求bit-exact，直接比较SHA256
      sha256sum fracture_result.oas | grep -q "$(cat /eda/golden/mask/mdp/fracture.sha256)"
```

### 2. 跳过代理测试（使用真实金标时）

运行测试时设置环境变量：
```bash
SKIP_PROXY=1 bash scripts/start.sh run baseline
SKIP_PROXY=1 bash scripts/start.sh run candidate
```

- `SKIP_PROXY=1`：跳过OPC和Mask代理测试，只跑微基准(CPU/内存/网络)+真实金标
- `SKIP_STORAGE=1`（默认已设置）：跳过存储fio测试
- 存储/网络测试开关保持不变

### 3. 运行测试

```bash
# 旧机
SKIP_PROXY=1 bash scripts/start.sh run baseline

# 新机
SKIP_PROXY=1 bash scripts/start.sh run candidate
```

测试流程：
1. 系统信息采集
2. CPU测试（sysbench）
3. 内存带宽测试（STREAM）
4. ~~存储fio测试~~（已跳过）
5. 网络连通性检查（iperf3无对端则跳过）
6. ~~OPC代理~~（已跳过）
7. ~~Mask代理~~（已跳过）
8. **自动运行所有enabled=true的金标用例**

## 金标用例输出

金标运行后，结果在 `results/<run_dir>/eda/` 目录下：
- `eda.json`：所有用例的汇总（墙钟、退出码、校验结果）
- `<case-id>/command.stdout/stderr`：命令的标准输出/错误
- `<case-id>/verify.stdout/stderr`：校验脚本的输出

## 对比报告

金标数据会自动参与对比报告：
- 墙钟时间：新机/旧机比值，按`gates.yaml`中的阈值判定
- 正确性：必须两台都`correctness_pass=true`才算通过
- 最终结论：GO / GO(待金标补齐) / NO-GO

## 注意事项

1. **金标数据一致性**：两台机器必须使用完全相同的输入文件、工具版本、环境配置
2. **许可证**：确保两台机器都能访问许可证服务器，测试期间没有其他作业抢占license
3. **独占机器**：测试期间不要在机器上跑其他任务，避免性能干扰
4. **工作目录**：建议用NFS共享存储（`/data/ws01`），输入金标文件只读，输出写到结果目录
5. **$NPROC变量**：命令中可以使用`$NPROC`，脚本会自动设置为机器逻辑核数
6. **校验脚本**：`verify`段返回0表示结果正确，非0表示失败
