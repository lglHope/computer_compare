#!/usr/bin/env python3
"""把 summary.json 打成几行中文，方便看「这次测出了什么」。"""
import json
import sys


def g(d, *keys):
    cur = d
    for k in keys:
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur


def num(x, unit=""):
    if x is None:
        return "（无数据）"
    if isinstance(x, float):
        return "%.3f%s" % (x, unit)
    return "%s%s" % (x, unit)


def main():
    if len(sys.argv) < 2:
        raise SystemExit("用法: python3 scripts/print_summary.py <summary.json>")
    path = sys.argv[1]
    d = json.load(open(path, encoding="utf-8"))
    print("")
    print("======== 本次测试摘要 ========")
    print("角色（旧机 baseline / 新机 candidate）：%s" % d.get("role"))
    print("机型标记 INSTANCE_ID：%s" % d.get("instance_id"))
    print("结果目录：%s" % d.get("run_dir"))
    print("")
    print("[CPU]")
    print("  单核 events/s : %s" % num(g(d, "cpu", "single_core_eps_median") or g(d, "cpu", "single_thread_eps_median")))
    print("  多核 events/s : %s" % num(g(d, "cpu", "multicore_eps_median") or g(d, "cpu", "full_thread_eps_median")))
    print("  并行效率      : %s" % num(g(d, "cpu", "parallel_efficiency")))
    print("[内存带宽 STREAM]")
    print("  单核 Triad    : %s" % num(g(d, "memory", "single_core_triad_gbps"), " GB/s"))
    print("  整机 Triad    : %s" % num(g(d, "memory", "machine_triad_gbps") or g(d, "memory", "triad_gbps"), " GB/s"))
    print("[OPC 代理]  （近似光学邻近校正：算得多、吃内存带宽）")
    print("  墙钟          : %s" % num(g(d, "opc_proxy", "wall_sec"), " 秒"))
    print("  期间 CPU 平均 : %s" % num(g(d, "opc_proxy", "hostload", "cpu_pct", "avg"), " %"))
    print("  期间 内存平均 : %s" % num(g(d, "opc_proxy", "hostload", "mem_used_gb", "avg"), " GB"))
    print("[Mask 代理]  （近似掩模数据准备：大文件读写）")
    print("  墙钟          : %s" % num(g(d, "mask_proxy", "wall_sec"), " 秒"))
    print("  期间 CPU 平均 : %s" % num(g(d, "mask_proxy", "hostload", "cpu_pct", "avg"), " %"))
    print("  期间 磁盘读   : %s" % num(g(d, "mask_proxy", "hostload", "disk_read_MBps", "avg"), " MB/s"))
    print("  期间 磁盘写   : %s" % num(g(d, "mask_proxy", "hostload", "disk_write_MBps", "avg"), " MB/s"))
    print("")
    print("完整 JSON：%s" % path)
    print("对比两台机器：bash scripts/start.sh compare <旧机summary.json> <新机summary.json>")
    print("================================")


if __name__ == "__main__":
    main()
