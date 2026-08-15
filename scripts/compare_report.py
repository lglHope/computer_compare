#!/usr/bin/env python3
"""对比 baseline 与 candidate 的 summary.json，按 gates.yaml 输出 Markdown 报告。"""
import argparse
import json
import os
from datetime import datetime, timezone


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def load_yaml(path):
    try:
        import yaml
    except ImportError as e:
        raise SystemExit("请安装 PyYAML: pip install pyyaml") from e
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def get(d, *keys, default=None):
    cur = d
    for k in keys:
        if not isinstance(cur, dict) or k not in cur:
            return default
        cur = cur[k]
    return cur


def ratio(cand, base):
    if cand is None or base in (None, 0):
        return None
    return cand / base


def gate_max(r, limit, invert=False):
    if r is None or limit is None:
        return "SKIP"
    ok = (r <= limit) if not invert else (r >= limit)
    return "PASS" if ok else "FAIL"


def fmt(x, digits=3):
    if x is None:
        return "-"
    if isinstance(x, float):
        return f"{x:.{digits}f}"
    return str(x)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--config", default="config/eval.yaml")
    ap.add_argument("--gates", default="config/gates.yaml")
    ap.add_argument("--out", default="results/compare_report.md")
    args = ap.parse_args()

    base = load_json(args.baseline)
    cand = load_json(args.candidate)
    cfg = load_yaml(args.config) if os.path.isfile(args.config) else {}
    gates = load_yaml(args.gates) if os.path.isfile(args.gates) else {}
    perf = gates.get("performance") or {}
    costg = gates.get("cost") or {}

    b_price = get(cfg, "baseline", "hourly_price_cny")
    c_price = get(cfg, "candidate", "hourly_price_cny")

    rows = []

    def add(name, b, c, r, status, note=""):
        rows.append((name, b, c, r, status, note))

    b_cpu1 = get(base, "cpu", "single_core_eps_median") or get(base, "cpu", "single_thread_eps_median")
    c_cpu1 = get(cand, "cpu", "single_core_eps_median") or get(cand, "cpu", "single_thread_eps_median")
    r_cpu1 = ratio(c_cpu1, b_cpu1)
    add("CPU 单核 events/s", b_cpu1, c_cpu1, r_cpu1,
        gate_max(r_cpu1, perf.get("cpu_single_events_ratio_min"), invert=True), "绑核 1 线程，越高越好")

    b_cpu = get(base, "cpu", "multicore_eps_median") or get(base, "cpu", "full_thread_eps_median")
    c_cpu = get(cand, "cpu", "multicore_eps_median") or get(cand, "cpu", "full_thread_eps_median")
    r_cpu = ratio(c_cpu, b_cpu)
    add("CPU 多核 events/s", b_cpu, c_cpu, r_cpu,
        gate_max(r_cpu, perf.get("cpu_events_ratio_min"), invert=True), "满逻辑核，越高越好")

    b_st1 = get(base, "memory", "single_core_triad_gbps")
    c_st1 = get(cand, "memory", "single_core_triad_gbps")
    r_st1 = ratio(c_st1, b_st1)
    add("内存带宽 单核 Triad GB/s", b_st1, c_st1, r_st1,
        gate_max(r_st1, perf.get("stream_single_triad_ratio_min"), invert=True), "1 线程 STREAM")

    b_st = get(base, "memory", "machine_triad_gbps") or get(base, "memory", "triad_gbps")
    c_st = get(cand, "memory", "machine_triad_gbps") or get(cand, "memory", "triad_gbps")
    r_st = ratio(c_st, b_st)
    add("内存带宽 整机 Triad GB/s", b_st, c_st, r_st,
        gate_max(r_st, perf.get("stream_triad_ratio_min"), invert=True), "满核 STREAM，OPC 强相关")

    b_opc = get(base, "opc_proxy", "wall_sec")
    c_opc = get(cand, "opc_proxy", "wall_sec")
    r_opc = ratio(c_opc, b_opc)
    add("OPC 代理墙钟 s", b_opc, c_opc, r_opc,
        gate_max(r_opc, perf.get("opc_proxy_ratio_max")), "越低越好")

    b_mask = get(base, "mask_proxy", "wall_sec")
    c_mask = get(cand, "mask_proxy", "wall_sec")
    r_mask = ratio(c_mask, b_mask)
    add("Mask 代理墙钟 s", b_mask, c_mask, r_mask,
        gate_max(r_mask, perf.get("mask_proxy_ratio_max")), "越低越好")

    def hostload_avg(summary, proxy_key, metric):
        h = get(summary, proxy_key, "hostload") or {}
        m = h.get(metric) or {}
        return m.get("avg") if isinstance(m, dict) else None

    def add_load(title, proxy_key, metric, note):
        b = hostload_avg(base, proxy_key, metric)
        c = hostload_avg(cand, proxy_key, metric)
        add(title, b, c, ratio(c, b), "INFO", note)

    add_load("OPC 期间 CPU% avg", "opc_proxy", "cpu_pct", "代理期间整机 CPU")
    add_load("OPC 期间 内存GB avg", "opc_proxy", "mem_used_gb", "已用内存")
    add_load("OPC 期间 磁盘读 MB/s avg", "opc_proxy", "disk_read_MBps", "物理盘合计")
    add_load("OPC 期间 磁盘写 MB/s avg", "opc_proxy", "disk_write_MBps", "物理盘合计")
    add_load("OPC 期间 网收 MB/s avg", "opc_proxy", "net_rx_MBps", "不含 lo")
    add_load("OPC 期间 网发 MB/s avg", "opc_proxy", "net_tx_MBps", "不含 lo")
    add_load("Mask 期间 CPU% avg", "mask_proxy", "cpu_pct", "代理期间整机 CPU")
    add_load("Mask 期间 内存GB avg", "mask_proxy", "mem_used_gb", "已用内存")
    add_load("Mask 期间 磁盘读 MB/s avg", "mask_proxy", "disk_read_MBps", "物理盘合计")
    add_load("Mask 期间 磁盘写 MB/s avg", "mask_proxy", "disk_write_MBps", "物理盘合计")
    add_load("Mask 期间 网收 MB/s avg", "mask_proxy", "net_rx_MBps", "不含 lo")
    add_load("Mask 期间 网发 MB/s avg", "mask_proxy", "net_tx_MBps", "不含 lo")

    def eda_wall(summary, domain):
        cases = get(summary, "eda", "cases") or []
        vals = [x.get("wall_sec") for x in cases if x.get("domain") == domain and not x.get("skipped") and x.get("wall_sec")]
        return sum(vals) / len(vals) if vals else None

    def eda_ok(summary, domain):
        cases = [x for x in (get(summary, "eda", "cases") or []) if x.get("domain") == domain and not x.get("skipped")]
        if not cases:
            return None
        return all(x.get("correctness_pass") for x in cases)

    b_eda_opc, c_eda_opc = eda_wall(base, "opc"), eda_wall(cand, "opc")
    r_eda_opc = ratio(c_eda_opc, b_eda_opc)
    add("OPC 金标平均墙钟 s", b_eda_opc, c_eda_opc, r_eda_opc,
        gate_max(r_eda_opc, perf.get("opc_wall_ratio_max")) if r_eda_opc else "SKIP")

    b_eda_mask, c_eda_mask = eda_wall(base, "mask"), eda_wall(cand, "mask")
    r_eda_mask = ratio(c_eda_mask, b_eda_mask)
    add("Mask 金标平均墙钟 s", b_eda_mask, c_eda_mask, r_eda_mask,
        gate_max(r_eda_mask, perf.get("mask_wall_ratio_max")) if r_eda_mask else "SKIP")

    add("OPC 金标正确性", eda_ok(base, "opc"), eda_ok(cand, "opc"), None,
        "PASS" if eda_ok(cand, "opc") else ("SKIP" if eda_ok(cand, "opc") is None else "FAIL"))
    add("Mask 金标正确性", eda_ok(base, "mask"), eda_ok(cand, "mask"), None,
        "PASS" if eda_ok(cand, "mask") else ("SKIP" if eda_ok(cand, "mask") is None else "FAIL"))

    def cost_ratio(wall_r, bp, cp):
        if wall_r is None or not bp or not cp:
            return None
        return wall_r * (cp / bp)

    r_cost_opc = cost_ratio(r_eda_opc or r_opc, b_price, c_price)
    add("OPC 有效成本比（墙钟×单价）", b_price, c_price, r_cost_opc,
        gate_max(r_cost_opc, costg.get("opc_cost_ratio_max")), "含代理回退")

    r_cost_mask = cost_ratio(r_eda_mask or r_mask, b_price, c_price)
    add("Mask 有效成本比", b_price, c_price, r_cost_mask,
        gate_max(r_cost_mask, costg.get("mask_cost_ratio_max")))

    fails = [r for r in rows if r[4] == "FAIL"]
    decision = "NO-GO" if fails else ("GO（待金标补齐）" if any(r[4] == "SKIP" for r in rows) else "GO")

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    lines = [
        "# 新机型引入对比报告",
        "",
        f"- 生成时间：{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}",
        f"- Baseline：`{base.get('instance_id')}` ({base.get('role')})",
        f"- Candidate：`{cand.get('instance_id')}` ({cand.get('role')})",
        f"- 基线单价：{b_price} 元/小时；候选单价：{c_price} 元/小时",
        f"- **建议结论：{decision}**",
        "",
        "| 指标 | Baseline | Candidate | 比值(C/B) | 门禁 | 说明 |",
        "|------|----------|-----------|-----------|------|------|",
    ]
    for name, b, c, r, st, *rest in rows:
        note = rest[0] if rest else ""
        lines.append(f"| {name} | {fmt(b)} | {fmt(c)} | {fmt(r)} | {st} | {note} |")

    lines += [
        "",
        "## 解读",
        "",
        "- 比值对墙钟/成本：< 1 表示候选更好；对吞吐：> 1 表示候选更好。",
        "- 代理负载仅用于筛型；量产引入必须以 P4 金标正确性为准。",
        "- OPC/Mask 期间的 CPU/内存/磁盘/网络为 INFO，用于判断瓶颈，不单独作为 Go/No-Go。",
        "- 若 STREAM 明显落后而 CPU events 领先，OPC 作业仍可能变慢，优先不要只看核数。",
        "",
        "## 失败项",
        "",
    ]
    if fails:
        for f in fails:
            lines.append(f"- {f[0]}：状态 {f[4]}，比值 {fmt(f[3])}")
    else:
        lines.append("- 无 FAIL。")

    lines += [
        "",
        "## 建议动作",
        "",
        "- GO：冻结镜像与调度队列，进入小流量影子作业，观察 2 周 P50/P90。",
        "- GO（待金标补齐）：先不要接量产，打开 `golden_cases.yaml` 后重跑 `run_eda_golden.sh`。",
        "- NO-GO：保留本报告与 raw 日志，评估下一档机型或调优 NUMA/存储后再测。",
        "",
    ]
    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    payload = {
        "decision": decision,
        "fail_count": len(fails),
        "rows": [
            {"name": n, "baseline": b, "candidate": c, "ratio": r, "status": s}
            for n, b, c, r, s, *_ in rows
        ],
    }
    json_out = os.path.splitext(args.out)[0] + ".json"
    with open(json_out, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)
    print(f"报告: {args.out}")
    print(f"JSON: {json_out}")
    print(f"结论: {decision}")
    raise SystemExit(1 if fails else 0)


if __name__ == "__main__":
    main()
