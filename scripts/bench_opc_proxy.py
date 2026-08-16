#!/usr/bin/env python3
"""OPC 代理负载：大网格上的反复 2D 平滑（带宽 + 计算混合，近似 OPC stencil）。

使用 numpy 向量化内层循环，使瓶颈落在内存带宽而非 Python 解释器上。
多进程按 NUMA 节点分配并通过 sched_setaffinity 绑核，减少远程内存访问。
若 numpy 不可用则回退到纯 Python（仅用于环境自检，不建议正式评测）。
"""
import argparse
import json
import os
import time
from concurrent.futures import ProcessPoolExecutor
from multiprocessing import cpu_count

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False


def numa_topology():
    nodes = {}
    base = "/sys/devices/system/node"
    if not os.path.isdir(base):
        return []
    for name in sorted(os.listdir(base)):
        if not name.startswith("node") or not name[4:].isdigit():
            continue
        node_id = int(name[4:])
        cpulist_path = os.path.join(base, name, "cpulist")
        try:
            with open(cpulist_path) as f:
                spec = f.read().strip()
        except OSError:
            continue
        cpus = []
        for part in spec.split(","):
            if "-" in part:
                lo, hi = part.split("-", 1)
                cpus.extend(range(int(lo), int(hi) + 1))
            elif part:
                cpus.append(int(part))
        if cpus:
            nodes[node_id] = sorted(cpus)
    return [nodes[k] for k in sorted(nodes)]


def assign_cpus(total_procs, numa_nodes):
    if not numa_nodes:
        return [None] * total_procs
    assignments = []
    for i in range(total_procs):
        node = numa_nodes[i % len(numa_nodes)]
        within = i // len(numa_nodes)
        if node:
            assignments.append({node[within % len(node)]})
        else:
            assignments.append(None)
    return assignments


def pin_to_cpus(cpu_set):
    if not cpu_set:
        return
    try:
        os.sched_setaffinity(0, cpu_set)
    except (OSError, AttributeError):
        pass


def worker_numpy(args):
    grid, iterations, seed, cpu_set = args
    pin_to_cpus(cpu_set)
    n = grid
    idx = np.arange(n * n, dtype=np.int64)
    a = ((idx * 17 + seed) % 251).astype(np.float64).reshape(n, n)
    del idx
    b = np.empty_like(a)
    t0 = time.perf_counter()
    for _ in range(iterations):
        b[1:-1, 1:-1] = (
            a[1:-1, 1:-1] * 0.5
            + a[1:-1, :-2] * 0.125
            + a[1:-1, 2:] * 0.125
            + a[:-2, 1:-1] * 0.125
            + a[2:, 1:-1] * 0.125
        )
        a, b = b, a
    elapsed = time.perf_counter() - t0
    step = max(1, n // 32)
    checksum = float(a[::step, ::step].sum())
    cells = (n - 2) * (n - 2) * iterations
    return {"elapsed_sec": elapsed, "checksum": checksum, "cells": cells}


def worker_pure(args):
    from array import array
    grid, iterations, seed, cpu_set = args
    pin_to_cpus(cpu_set)
    n = grid
    size = n * n
    a = array("d", [0.0]) * size
    b = array("d", [0.0]) * size
    for i in range(size):
        a[i] = float((i * 17 + seed) % 251)
    t0 = time.perf_counter()
    for _ in range(iterations):
        for y in range(1, n - 1):
            row = y * n
            for x in range(1, n - 1):
                i = row + x
                b[i] = (
                    a[i] * 0.5
                    + a[i - 1] * 0.125
                    + a[i + 1] * 0.125
                    + a[i - n] * 0.125
                    + a[i + n] * 0.125
                )
        a, b = b, a
    elapsed = time.perf_counter() - t0
    checksum = 0.0
    step = max(1, n)
    for i in range(0, size, step):
        checksum += a[i]
    cells = (n - 2) * (n - 2) * iterations
    return {"elapsed_sec": elapsed, "checksum": checksum, "cells": cells}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--grid", type=int, default=int(os.environ.get("OPC_GRID", "1536")))
    p.add_argument("--iterations", type=int, default=int(os.environ.get("OPC_ITERS", "15")))
    p.add_argument("--processes", type=int, default=int(os.environ.get("OPC_PROCS", "0")))
    p.add_argument("--out", required=True)
    args = p.parse_args()
    procs = args.processes or cpu_count()

    numa_nodes = numa_topology()
    cpu_assignments = assign_cpus(procs, numa_nodes)
    payloads = [
        (args.grid, args.iterations, i, cpu_assignments[i])
        for i in range(procs)
    ]

    worker = worker_numpy if HAS_NUMPY else worker_pure
    t0 = time.perf_counter()
    with ProcessPoolExecutor(max_workers=procs) as ex:
        parts = list(ex.map(worker, payloads))
    wall = time.perf_counter() - t0

    cells = sum(x["cells"] for x in parts)
    summary = {
        "name": "opc_proxy",
        "grid": args.grid,
        "iterations": args.iterations,
        "processes": procs,
        "wall_sec": wall,
        "cells_per_sec": cells / wall if wall else None,
        "checksum": sum(x["checksum"] for x in parts),
        "numpy": HAS_NUMPY,
        "numa_nodes": len(numa_nodes),
        "pinned": any(c is not None for c in cpu_assignments),
        "per_process": parts,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    slim = {k: summary[k] for k in summary if k != "per_process"}
    print(json.dumps(slim, indent=2))


if __name__ == "__main__":
    main()
