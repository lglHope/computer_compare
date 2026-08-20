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


def bw_mbps(x):
    """把 bytes/s 转成 MB/s 显示"""
    if x is None:
        return "（无数据）"
    return "%.1f MB/s" % (float(x) / 1024 / 1024)


def bw_gbps(x):
    """把 bits/s 转成 Gbps 显示"""
    if x is None:
        return "（无数据）"
    return "%.2f Gbps" % (float(x) / 1000 / 1000 / 1000)


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
    print("[存储 fio]")
    storage = d.get("storage") or {}
    if storage.get("skipped"):
        print("  跳过：%s" % storage.get("reason", "未执行存储测试"))
    else:
        sr = storage.get("workdir_seqread") or {}
        rr = storage.get("workdir_randread") or {}
        sh = storage.get("shared_seqread") or {}
        rh = storage.get("shared_randread") or {}
        if not storage:
            print("  （无数据）")
        else:
            if sr:
                print("  工作目录顺序读 : %s  (IOPS: %s)" % (bw_mbps(sr.get("bw_bytes")), num(sr.get("iops"))))
            if rr:
                print("  工作目录随机读 : %s  (IOPS: %s, P99延迟: %s ns)" % (
                    bw_mbps(rr.get("bw_bytes")), num(rr.get("iops")), num(rr.get("lat_ns_p99"))))
            if sh:
                print("  共享目录顺序读 : %s  (IOPS: %s)" % (bw_mbps(sh.get("bw_bytes")), num(sh.get("iops"))))
            if rh:
                print("  共享目录随机读 : %s  (IOPS: %s, P99延迟: %s ns)" % (
                    bw_mbps(rh.get("bw_bytes")), num(rh.get("iops")), num(rh.get("lat_ns_p99"))))
    print("[网络 iperf3]")
    net = d.get("network") or {}
    if net.get("skipped"):
        print("  跳过：%s" % net.get("reason", "未设置对端服务器"))
    else:
        print("  带宽          : %s" % bw_gbps(net.get("bits_per_second")))
        print("  重传数        : %s" % num(net.get("retransmits")))
    opc = d.get("opc_proxy") or {}
    print("[OPC 代理]  （近似光学邻近校正：算得多、吃内存带宽）")
    if opc.get("skipped"):
        print("  跳过：%s" % opc.get("reason", "代理测试已跳过"))
    else:
        print("  墙钟          : %s" % num(g(d, "opc_proxy", "wall_sec"), " 秒"))
        print("  期间 CPU 平均 : %s" % num(g(d, "opc_proxy", "hostload", "cpu_pct", "avg"), " %"))
        print("  期间 内存平均 : %s" % num(g(d, "opc_proxy", "hostload", "mem_used_gb", "avg"), " GB"))
        if g(d, "opc_proxy", "hostload", "disk_read_MBps", "avg") is not None:
            print("  期间 磁盘读   : %s" % num(g(d, "opc_proxy", "hostload", "disk_read_MBps", "avg"), " MB/s"))
            print("  期间 磁盘写   : %s" % num(g(d, "opc_proxy", "hostload", "disk_write_MBps", "avg"), " MB/s"))
    mask = d.get("mask_proxy") or {}
    print("[Mask 代理]  （近似掩模数据准备：大文件读写）")
    if mask.get("skipped"):
        print("  跳过：%s" % mask.get("reason", "代理测试已跳过"))
    else:
        print("  墙钟          : %s" % num(g(d, "mask_proxy", "wall_sec"), " 秒"))
        print("  期间 CPU 平均 : %s" % num(g(d, "mask_proxy", "hostload", "cpu_pct", "avg"), " %"))
        print("  期间 内存平均 : %s" % num(g(d, "mask_proxy", "hostload", "mem_used_gb", "avg"), " GB"))
        print("  期间 磁盘读   : %s" % num(g(d, "mask_proxy", "hostload", "disk_read_MBps", "avg"), " MB/s"))
        print("  期间 磁盘写   : %s" % num(g(d, "mask_proxy", "hostload", "disk_write_MBps", "avg"), " MB/s"))
    eda = d.get("eda")
    if eda:
        print("[EDA 金标]")
        cases = eda.get("cases") or []
        if cases:
            for c in cases:
                status = "PASS" if c.get("correctness_pass") else ("SKIP" if c.get("skipped") else "FAIL")
                print("  %s %s: 墙钟 %s 秒 [%s]" % (c.get("domain", ""), c.get("name", ""), num(c.get("wall_sec")), status))
        else:
            print("  （未配置金标用例）")
    print("")
    print("完整 JSON：%s" % path)
    print("对比两台机器：bash scripts/start.sh compare <旧机summary.json> <新机summary.json>")
    print("================================")


if __name__ == "__main__":
    main()
