#!/usr/bin/env python3
"""Mask 代理负载：大文件顺序扫描、分块变换写回、校验和（近似 MDP/fracture I/O 形态）。

写后 fsync + posix_fadvise(POSIX_FADV_DONTNEED) 丢弃页缓存，确保读回走真实磁盘。
临时文件用 tempfile 创建，避免共享 /tmp 下的符号链接攻击。
"""
import argparse
import hashlib
import json
import os
import tempfile
import time

POSIX_FADV_DONTNEED = 4
POSIX_FADV_SEQUENTIAL = 2


def fadvise(fd, advice, offset=0, length=0):
    try:
        os.posix_fadvise(fd, offset, length, advice)
    except (OSError, AttributeError):
        pass


def evict_cache(path):
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        fadvise(fd, POSIX_FADV_DONTNEED)
    finally:
        os.close(fd)


def write_large_file(path, total, block, pattern):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        fadvise(fd, POSIX_FADV_SEQUENTIAL)
        remain = total
        while remain > 0:
            n = min(block, remain)
            buf = pattern if n == len(pattern) else pattern[:n]
            written = os.write(fd, buf)
            remain -= written
        os.fsync(fd)
    finally:
        os.close(fd)
    evict_cache(path)


def scan_transform(path_in, path_out, total, block, rounds):
    fd_in = os.open(path_in, os.O_RDONLY)
    try:
        fadvise(fd_in, POSIX_FADV_SEQUENTIAL)
        h = hashlib.sha256()
        for _ in range(rounds):
            h = hashlib.sha256()
            fd_out = os.open(path_out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            try:
                fadvise(fd_out, POSIX_FADV_SEQUENTIAL)
                os.lseek(fd_in, 0, os.SEEK_SET)
                remain = total
                while remain > 0:
                    rbuf = os.read(fd_in, min(block, remain))
                    if not rbuf:
                        break
                    mv = bytearray(rbuf)
                    for i in range(0, len(mv), 64):
                        mv[i] ^= 0xA5
                    os.write(fd_out, mv)
                    h.update(mv)
                    remain -= len(rbuf)
                os.fsync(fd_out)
            finally:
                os.close(fd_out)
            evict_cache(path_in)
            evict_cache(path_out)
    finally:
        os.close(fd_in)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--file-gb", type=float, default=float(os.environ.get("MASK_FILE_GB", "8")))
    p.add_argument("--block-mb", type=int, default=int(os.environ.get("MASK_BLOCK_MB", "64")))
    p.add_argument("--rounds", type=int, default=int(os.environ.get("MASK_ROUNDS", "2")))
    p.add_argument("--scratch", default=os.environ.get("WORK_DIR", os.environ.get("SCRATCH_DIR", "/tmp")))
    p.add_argument("--out", required=True)
    args = p.parse_args()

    os.makedirs(args.scratch, exist_ok=True)
    total = int(args.file_gb * (1024 ** 3))
    block = args.block_mb * 1024 * 1024
    pattern = bytes(i % 256 for i in range(256)) * (block // 256)

    fd_in, path_in = tempfile.mkstemp(
        dir=args.scratch, prefix="mask_proxy_in_", suffix=".bin")
    os.close(fd_in)
    fd_out, path_out = tempfile.mkstemp(
        dir=args.scratch, prefix="mask_proxy_out_", suffix=".bin")
    os.close(fd_out)

    try:
        t0 = time.perf_counter()
        write_large_file(path_in, total, block, pattern)
        write_sec = time.perf_counter() - t0

        t1 = time.perf_counter()
        checksum = scan_transform(path_in, path_out, total, block, args.rounds)
        scan_sec = time.perf_counter() - t1
    finally:
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
        "sha256": checksum,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
