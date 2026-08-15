#!/usr/bin/env bash
# 内存带宽：STREAM Copy/Scale/Add/Triad。
# 分别测单核（OMP_NUM_THREADS=1 + 绑核）与整机（全部逻辑核）。
set -euo pipefail

RUN_DIR="${EVAL_RUN_DIR:?请先由 run_suite.sh 设置 EVAL_RUN_DIR}"
N="${1:-80000000}"
OUT_DIR="${RUN_DIR}/memory"
mkdir -p "${OUT_DIR}"
STREAM_SRC="${OUT_DIR}/stream.c"
STREAM_BIN="${OUT_DIR}/stream"
NPROC="$(nproc)"

cat > "${STREAM_SRC}" <<'EOF'
/* STREAM：大数组扫内存，测可持续带宽（GB/s 按 1e9 字节）。 */
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#ifdef _OPENMP
#include <omp.h>
#endif

#ifndef NTIMES
#define NTIMES 10
#endif

static double now(void) {
  struct timeval t;
  gettimeofday(&t, 0);
  return t.tv_sec + t.tv_usec * 1e-6;
}

int main(int argc, char **argv) {
  long n = (argc > 1) ? atol(argv[1]) : 80000000L;
  int ntimes = (argc > 2) ? atoi(argv[2]) : NTIMES;
  double *a, *b, *c;
  long i, k;
  double t, best_copy = 1e9, best_scale = 1e9, best_add = 1e9, best_triad = 1e9;
  int threads = 1;

  if (n < 1000) {
    fprintf(stderr, "N too small\n");
    return 1;
  }
  a = (double *)malloc((size_t)n * sizeof(double));
  b = (double *)malloc((size_t)n * sizeof(double));
  c = (double *)malloc((size_t)n * sizeof(double));
  if (!a || !b || !c) {
    fprintf(stderr, "oom allocating 3 * %ld doubles\n", n);
    return 2;
  }

#ifdef _OPENMP
#pragma omp parallel
  {
#pragma omp master
    threads = omp_get_num_threads();
  }
#endif

#pragma omp parallel for
  for (i = 0; i < n; i++) {
    a[i] = 1.0;
    b[i] = 2.0;
    c[i] = 0.0;
  }

  for (k = 0; k < ntimes; k++) {
    t = now();
#pragma omp parallel for
    for (i = 0; i < n; i++) c[i] = a[i];
    t = now() - t;
    if (k > 0 && t < best_copy) best_copy = t;

    t = now();
#pragma omp parallel for
    for (i = 0; i < n; i++) b[i] = 3.0 * c[i];
    t = now() - t;
    if (k > 0 && t < best_scale) best_scale = t;

    t = now();
#pragma omp parallel for
    for (i = 0; i < n; i++) c[i] = a[i] + b[i];
    t = now() - t;
    if (k > 0 && t < best_add) best_add = t;

    t = now();
#pragma omp parallel for
    for (i = 0; i < n; i++) a[i] = b[i] + 3.0 * c[i];
    t = now() - t;
    if (k > 0 && t < best_triad) best_triad = t;
  }

  printf("threads %d\n", threads);
  printf("array_n %ld\n", n);
  printf("copy_gbps %.3f\n", (n * 2.0 * 8.0 / 1e9) / best_copy);
  printf("scale_gbps %.3f\n", (n * 2.0 * 8.0 / 1e9) / best_scale);
  printf("add_gbps %.3f\n", (n * 3.0 * 8.0 / 1e9) / best_add);
  printf("triad_gbps %.3f\n", (n * 3.0 * 8.0 / 1e9) / best_triad);
  free(a);
  free(b);
  free(c);
  return 0;
}
EOF

python3 - <<PY "${OUT_DIR}" "${N}" "${STREAM_SRC}" "${STREAM_BIN}" "${NPROC}"
import json, os, re, shutil, subprocess, sys

out_dir, n, src, binary, nproc = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
compile_log = os.path.join(out_dir, "compile.log")
has_taskset = shutil.which("taskset") is not None


def parse_out(text):
    def grab(key):
        m = re.search(r"%s\s+([0-9.]+)" % key, text)
        return float(m.group(1)) if m else None
    return {
        "threads": int(grab("threads") or 0) or None,
        "array_n": int(float(grab("array_n") or 0)) or None,
        "copy_gbps": grab("copy_gbps"),
        "scale_gbps": grab("scale_gbps"),
        "add_gbps": grab("add_gbps"),
        "triad_gbps": grab("triad_gbps"),
    }


def run_stream(threads, pin_single):
    env = os.environ.copy()
    env["OMP_NUM_THREADS"] = str(threads)
    env["OMP_PROC_BIND"] = "true"
    env["OMP_PLACES"] = "cores"
    cmd = [binary, n]
    if pin_single and has_taskset:
        cmd = ["taskset", "-c", "0"] + cmd
    p = subprocess.run(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        universal_newlines=True, env=env)
    return p


summary = {
    "array_n": int(n),
    "nproc": nproc,
    "method": None,
    "single_core": None,
    "machine": None,
}

r = subprocess.run(
    ["gcc", "-O3", "-fopenmp", src, "-o", binary],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
open(compile_log, "w").write(r.stdout + r.stderr)

if r.returncode != 0:
    r = subprocess.run(
        ["gcc", "-O3", src, "-o", binary],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    open(compile_log, "a").write("\n--- retry without OpenMP ---\n" + r.stdout + r.stderr)

if r.returncode == 0:
    summary["method"] = "stream_c"
    p1 = run_stream(1, True)
    open(os.path.join(out_dir, "stream_single.out"), "w").write(p1.stdout + p1.stderr)
    if p1.returncode == 0:
        summary["single_core"] = parse_out(p1.stdout)
    pN = run_stream(nproc, False)
    open(os.path.join(out_dir, "stream_machine.out"), "w").write(pN.stdout + pN.stderr)
    if pN.returncode == 0:
        summary["machine"] = parse_out(pN.stdout)
else:
    summary["method"] = "python_copy"
    code = (
        "import time, array\n"
        "n = %s\n"
        "a = array.array('d', [1.0]) * n\n"
        "b = array.array('d', [2.0]) * n\n"
        "t0 = time.perf_counter()\n"
        "for i in range(n):\n"
        "    a[i] = b[i]\n"
        "dt = time.perf_counter() - t0\n"
        "gb = n * 16 / 1e9\n"
        "print('threads 1')\n"
        "print('array_n %%d' %% n)\n"
        "print('copy_gbps %%.3f' %% (gb / dt))\n"
        "print('scale_gbps 0')\n"
        "print('add_gbps 0')\n"
        "print('triad_gbps %%.3f' %% (gb / dt))\n"
    ) % n
    run = subprocess.run(
        ["python3", "-c", code],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    open(os.path.join(out_dir, "python_copy.out"), "w").write(run.stdout + run.stderr)
    parsed = parse_out(run.stdout)
    summary["single_core"] = parsed

sc = summary.get("single_core") or {}
mc = summary.get("machine") or {}
summary["single_core_triad_gbps"] = sc.get("triad_gbps")
summary["machine_triad_gbps"] = mc.get("triad_gbps")
# 兼容旧报告字段：triad_gbps 表示整机；没有整机时回退单核
summary["triad_gbps"] = summary["machine_triad_gbps"] or summary["single_core_triad_gbps"]

open(os.path.join(out_dir, "memory.json"), "w").write(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
PY
