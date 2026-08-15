#!/usr/bin/env python3
"""Mask 代理负载：大文件顺序扫描、分块变换写回、校验和（近似 MDP/fracture I/O 形态）。"""
import argparse
import hashlib
import json
import os
import time


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--file-gb", type=float, default=float(os.environ.get("MASK_FILE_GB", "8")))
    p.add_argument("--block-mb", type=int, default=int(os.environ.get("MASK_BLOCK_MB", "64")))
    p.add_argument("--rounds", type=int, default=int(os.environ.get("MASK_ROUNDS", "2")))
    p.add_argument("--scratch", default=os.environ.get("SCRATCH_DIR", "/tmp"))
    p.add_argument("--out", required=True)
    args = p.parse_args()

    os.makedirs(args.scratch, exist_ok=True)
    path_in = os.path.join(args.scratch, f"mask_proxy_in_{os.getpid()}.bin")
    path_out = os.path.join(args.scratch, f"mask_proxy_out_{os.getpid()}.bin")
    total = int(args.file_gb * (1024 ** 3))
    block = args.block_mb * 1024 * 1024
    pattern = bytes([i % 256 for i in range(256)]) * (block // 256)

    t_write = time.perf_counter()
    with open(path_in, "wb") as f:
        remain = total
        while remain > 0:
            chunk = pattern if remain >= block else pattern[:remain]
            f.write(chunk)
            remain -= len(chunk)
        f.flush()
        os.fsync(f.fileno())
    write_sec = time.perf_counter() - t_write

    h = hashlib.sha256()
    t_scan = time.perf_counter()
    for _ in range(args.rounds):
        h = hashlib.sha256()
        with open(path_in, "rb") as src, open(path_out, "wb") as dst:
            while True:
                buf = src.read(block)
                if not buf:
                    break
                # 轻量变换：模拟 fracture 分块处理
                mv = bytearray(buf)
                for i in range(0, len(mv), 64):
                    mv[i] ^= 0xA5
                dst.write(mv)
                h.update(mv)
            dst.flush()
            os.fsync(dst.fileno())
    scan_sec = time.perf_counter() - t_scan

    for pth in (path_in, path_out):
        try:
            os.remove(pth)
        except OSError:
            pass

    summary = {
        "name": "mask_proxy",
        "file_bytes": total,
        "block_bytes": block,
        "rounds": args.rounds,
        "write_sec": write_sec,
        "scan_transform_sec": scan_sec,
        "wall_sec": write_sec + scan_sec,
        "write_gbps": (total / (1024 ** 3)) / write_sec if write_sec else None,
        "scan_gbps": (total * args.rounds / (1024 ** 3)) / scan_sec if scan_sec else None,
        "sha256": h.hexdigest(),
    }
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
