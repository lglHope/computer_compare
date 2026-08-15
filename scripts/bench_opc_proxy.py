#!/usr/bin/env python3
"""OPC 代理负载：大网格上的反复 2D 平滑（带宽 + 计算混合，近似 OPC stencil）。"""
import argparse
import json
import os
import time
from array import array
from concurrent.futures import ProcessPoolExecutor
from multiprocessing import cpu_count


def worker(args):
    grid, iterations, seed = args
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
    payloads = [(args.grid, args.iterations, i) for i in range(procs)]
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
        "per_process": parts,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    slim = {k: summary[k] for k in summary if k != "per_process"}
    print(json.dumps(slim, indent=2))


if __name__ == "__main__":
    main()
