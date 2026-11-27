# Workload Evaluation Suite

This directory contains the benchmark workloads, datasets, hardware/kernel configuration scripts, and zero-overhead telemetry tooling used to evaluate **adaptive page-migration prefetching** across all 9 tiered-memory baselines (**AutoNUMA**, **Memtis**, **Nomad**, **Nomad-Alto**, **TPP**, **Colloid-TPP**, **Colloid-TPP-Alto**, **PACT**, and **HybridTier**) and their `-prefetch` variants.

---

## Table of Contents

1. [Overview & Hardware Emulation](#1-overview--hardware-emulation)
2. [CPU Topology & Core Allocation](#2-cpu-topology--core-allocation)
3. [Workload Classification: Open-Source vs Proprietary](#3-workload-classification-open-source-vs-proprietary)
4. [Open-Source Workloads](#4-open-source-workloads)
5. [Proprietary & Licensed Workloads](#5-proprietary--licensed-workloads)
6. [Automated Setup & Build Guide](#6-automated-setup--build-guide)
7. [Workload Execution & Telemetry Scripts](#7-workload-execution--telemetry-scripts)
8. [Memory Footprint (RSS) & Tier Ratios](#8-memory-footprint-rss--tier-ratios)
9. [Directory Structure](#9-directory-structure)

---

## 1. Overview & Hardware Emulation

The workloads cover diverse memory access behaviors under tiered memory:
- **Streaming & Bandwidth-Bound**: Sequential sweeps with high memory bandwidth demand (`stream`, `stream_copy`).
- **Pointer-Chasing & Latency-Bound**: Irregular graph/scientific accesses with low locality (`gapbs_*`, `xsbench`).
- **Write-Intensive & Lock-Contended**: High mutation rates and concurrency (`silo_tpcc`, `silo_ycsb`, `redis`).
- **Heterogeneous Real-World Compute**: Large scientific & engineering working sets (`spec2026_*`).

Workloads run across a 2-node emulated tiered-memory topology configured by [`setup_machine.sh`](scripts/setup_machine.sh) and GRUB `memmap=`:
- **Node 0 (Fast Tier / Local DRAM)**: Capacity constrained via `memmap=<reserved>G!<fast>G`, Pkg 0 uncore locked to **2.5 GHz**, Socket 0 cores clamped to **3.0 GHz** (`performance` governor, `min=max`).
- **Node 1 (Slow Tier / Emulated CXL)**: Pkg 1 uncore locked to **1.3 GHz** (before Socket 1 CPUs `32..63` are offlined) to emulate CXL-class remote latency (~185–200 ns).

---

## 2. CPU Topology & Core Allocation

Centralized in [`scripts/cpu_config.sh`](scripts/cpu_config.sh) (Socket 0 = 32 physical cores; Socket 1 / hyperthreads `32..63` offlined):

| Core(s) | Assignment |
| :--- | :--- |
| **Core 0** | OS interrupts & Socket 0 `uncore_cha_*` PMUs |
| **Cores 1–24** | Benchmark workload threads (`WORKLOAD_CORES=24`, `numactl --physcpubind=1..24`) |
| **Cores 25–27** | Kernel headroom (`kswapd0`, `kcompactd0`, `kworker`) |
| **Core 28** | 1-second time-series & uncore DRAM telemetry (`tier_ts_mon`, memory bound to Node 1) |
| **Core 29** | PACT migration thread (`--migration-cpu`) |
| **Core 30** | PACT monitor / PEBS coroutine loop (`--monitor-cpu`) |
| **Core 31** | Standalone `tier-prefetch-mon` adaptive pacing daemon |
| **Cores 32–63** | Offlined Socket 1 CPUs (kept offline across same-boot regression steps via `KEEP_MACHINE_CONFIG=1`) |

---

## 3. Workload Classification: Open-Source vs Proprietary

> [!IMPORTANT]
> All workloads are open source and automatically cloned/built by `setup_workloads.sh`, except **`spec2026`** and **`mlc`**, which are proprietary and must be supplied locally.

| Workload | Category | License / Type | Source Repository | Configured RSS |
| :--- | :--- | :--- | :--- | :--- |
| **GAPBS** | Graph Analytics | Open Source (BSD-3-Clause) | [github.com/sbeamer/gapbs](https://github.com/sbeamer/gapbs) | 12 – 38 GiB |
| **Silo** | In-Memory OLTP DB | Open Source (MIT) | [github.com/stephentu/silo](https://github.com/stephentu/silo) | 15 – 40 GiB |
| **Redis** | Key-Value Store | Open Source (BSD-3-Clause) | [github.com/redis/redis](https://github.com/redis/redis) | ~26 GiB |
| **STREAM** | Memory Bandwidth | Open Source (Custom) | [github.com/jeffhammond/STREAM](https://github.com/jeffhammond/STREAM) | ~18 GiB |
| **XSBench** | Monte Carlo Transport | Open Source (MIT) | [github.com/ANL-CESAR/XSBench](https://github.com/ANL-CESAR/XSBench) | ~18 GiB |
| **SPEC CPU 2026** | Standard Benchmark Suite | **Proprietary Commercial** | Licensed from SPEC | 22 – 49 GiB |
| **Intel MLC** | Memory Diagnostic Tool | **Proprietary Intel** | Intel Developer Zone | Configurable |

---

## 4. Open-Source Workloads

### GAPBS (`gapbs_<algo>_<dataset>`)
- **Algorithms**: `pr` (PageRank), `bc` (Betweenness Centrality), `cc` (Connected Components), `bfs` (Breadth-First Search), `sssp` (Single-Source Shortest Paths), `tc` (Triangle Counting).
- **Datasets**: `kron` ($2^{27}$ vertices), `urand` ($2^{27}$ vertices), `twitter`, `web`, `road`.
- **Graph Cache Reuse**: `run_workloads.sh` preloads graph files into Node 1 via `vmtouch` and reuses resident Node 1 pagecache across back-to-back GAPBS runs sharing the same graph.

### Silo (`silo_tpcc`, `silo_ycsb`, `silo_queue`, `silo_bid`, `silo_encstress`)
- Built from upstream `stephentu/silo` + Masstree submodule (`NMAXCORES=512`).
- `silo_tpcc` runs with `--num-threads 24 --scale-factor 150 --parallel-loading --runtime 180` (453 loader threads + 24 aligned workers ≤ 512 core IDs).
- `silo_ycsb` runs with `--num-threads 24 --scale-factor 240000 --parallel-loading --runtime 600`.

### Redis (`redis`)
- Runs `redis-server` paired with `redis-benchmark` (`4.3M` keys × `8 KB` payload ≈ 26 GiB RSS, `set,get`). Note: `redis` + `THP=always` is skipped automatically because Redis disables THP via `prctl`.

### STREAM (`stream`, `stream_copy`)
- Classic `stream` and pure copy-kernel `stream_copy` compiled with `STREAM_ARRAY_SIZE=800000000` (~18 GiB footprint).

### XSBench (`xsbench`)
- OpenMP continuous-energy Monte Carlo neutron transport mini-app (`-g 37000 -p 5000000`, ~18 GiB).

---

## 5. Proprietary & Licensed Workloads

> [!WARNING]
> Due to licensing restrictions, `spec2026` and `mlc` cannot be redistributed in this repository.

- **SPEC CPU 2026 (`spec2026_<bench>`)**: Install from `cpu2026-1.0.1.iso` into `workloads/spec2026/`. Compiled and executed via [`scripts/gcc-linux-x86.cfg`](scripts/gcc-linux-x86.cfg) (`ignore_errors = 0`, 24 OpenMP threads / copies). Primary SPECspeed targets: `spec2026_820.cloverleaf_s`, `spec2026_865.roms_s`, `spec2026_849.fotonik3d_s`, `spec2026_881.neutron_s`.
- **Intel MLC (`mlc`)**: Used for hardware latency/bandwidth validation of the Node 0 / Node 1 uncore setup.

---

## 6. Automated Setup & Build Guide

[`scripts/setup_workloads.sh`](scripts/setup_workloads.sh) clones, patches (GCC 12+ compatibility), and compiles open-source workloads and pre-builds configured benchmarks:

```bash
sudo ./workloads/scripts/setup_workloads.sh --help
sudo ./workloads/scripts/setup_workloads.sh gapbs
sudo ./workloads/scripts/setup_workloads.sh silo
sudo ./workloads/scripts/setup_workloads.sh redis
sudo ./workloads/scripts/setup_workloads.sh xsbench
sudo ./workloads/scripts/setup_workloads.sh stream
sudo ./workloads/scripts/setup_workloads.sh all

# Pre-build only the benchmarks listed for a regression run
sudo ./workloads/scripts/setup_workloads.sh prebuild gapbs_pr_kron silo_tpcc spec2026_820.cloverleaf_s
```

---

## 7. Workload Execution & Telemetry Scripts

Located in [`workloads/scripts/`](scripts/):

| File | Purpose |
| :--- | :--- |
| [`run_workloads.sh`](scripts/run_workloads.sh) | **Master benchmark runner**. Configures machine hardware, cleans caches, preloads GAPBS graphs to Node 1, configures kernel tiering & `/sys/kernel/mm/page_prefetch/`, starts telemetry, runs the workload with timeout guard, compiles reports, and restores hardware (unless `KEEP_MACHINE_CONFIG=1`). Supports `--get-log-path` for side-effect-free log lookup. |
| [`exec_workload.sh`](scripts/exec_workload.sh) | **Execution dispatcher**. Resolves `numactl --physcpubind=1..24` commands, GAPBS preload commands, and target binary names (`--get-cmd`, `--get-preload-cmd`, `--get-target-exe`). |
| [`setup_machine.sh`](scripts/setup_machine.sh) | **Hardware configurator**. Locks CPU clocks (3.0 GHz), Pkg 0/1 uncore (2.5 / 1.3 GHz), and offlines CPUs `32..63` (skips hotplug if already offline; `--restore` re-enables all CPUs and defaults). |
| [`setup_kernel.sh`](scripts/setup_kernel.sh) | **Kernel tiering & prefetch configurator**. Configures THP, watermarks, `/sys/kernel/mm/page_prefetch/`, kernel modules (`tierinit`, `kswapdrst`, `async_promote`), baseline daemons (`pact`, `colloid-mon`, `tier-prefetch-mon`, Memtis cgroup/ksamplingd), and safe teardown. |
| [`monitor_performance.sh`](scripts/monitor_performance.sh) | **Telemetry orchestrator**. Collects `/proc/vmstat` deltas (`MIG_WAIT_*`, `MIG_COPY_NS`, faults, migrations), migration daemon CPU time, uncore DRAM traffic, and AutoNUMA PMU stats. |
| [`tier_ts_mon.c`](scripts/tier_ts_mon.c) | **Zero-overhead C telemetry sampler** (Core 28 / Node 1). Samples IMC/UPI DRAM traffic, `/proc/vmstat`, `/proc/perfnomad`, and optional AutoNUMA core PMUs into per-second CSVs with zero forks or heap allocations. |
| [`cpu_config.sh`](scripts/cpu_config.sh) | Centralized CPU core allocation map (`WORKLOAD_CORES=24`, daemon cores `28–31`, offline CPUs `32–64`). |
| [`common.sh`](scripts/common.sh) | Shared `log_echo` and `read_sysfs` shell helpers. |
| [`calc_overhead.py`](scripts/calc_overhead.py) | Parses `workloads/output/<kernel>/regress_*.log` into summary tables and Excel-ready CSV/TSV reports. |
| [`gcc-linux-x86.cfg`](scripts/gcc-linux-x86.cfg) | SPEC CPU 2026 GCC configuration file. |

### Running Workloads Manually

```bash
# Single standalone run (offlines CPUs 32..63 for the run and restores them on exit)
sudo ./workloads/scripts/run_workloads.sh gapbs_pr_kron
sudo ./workloads/scripts/run_workloads.sh silo_tpcc
sudo ./workloads/scripts/run_workloads.sh spec2026_820.cloverleaf_s

# Run with explicit tier ratio, THP mode, and prefetch parameters
sudo TIER_RATIO=1:8 THP_MODE=always PREFETCH_ADAPTIVE=1 PREFETCH_NAIVE=1 \
     PREFETCH_MIN_DISTANCE=min0_max6 PREFETCH_HINT=0 \
     ./workloads/scripts/run_workloads.sh gapbs_bc_kron
```

---

## 8. Memory Footprint (RSS) & Tier Ratios

Fast-tier Node 0 size is computed in [`baselines/scripts/manage_kernels.sh`](../baselines/scripts/manage_kernels.sh) from calibrated RSS (`get_rss`) and ratio `F:S`:

$$\text{FastTier (GiB)} = \text{round}\left(\frac{\text{RSS} \times F}{F + S} + \text{OS\_HEADROOM}\right), \quad \text{OS\_HEADROOM} = 3\text{ GiB}$$

Within-1 GiB peers are snapped in `get_rss()` (preserving original measured values in comments) to share identical `memmap` boots across ratios:

| Workload Target | Configured RSS (Measured) | `1:16` `memmap` | `1:8` `memmap` | `1:4` `memmap` |
| :--- | :--- | :--- | :--- | :--- |
| `gapbs_{pr,bfs,cc}_{kron,urand}` | 18 GiB | `44G!4G` | `43G!5G` | `41G!7G` |
| `gapbs_bc_kron` | 18 GiB (19 GiB) | `44G!4G` | `43G!5G` | `41G!7G` |
| `gapbs_bc_urand`, `silo_tpcc` | 20 GiB | `44G!4G` | `43G!5G` | `41G!7G` |
| `spec2026_820.cloverleaf_s` | 22 GiB | `44G!4G` | `43G!5G` | `41G!7G` |
| `spec2026_865.roms_s` | 22 GiB (23 GiB) | `44G!4G` | `43G!5G` | `41G!7G` |
| `redis` | 26 GiB | `43G!5G` | `42G!6G` | `40G!8G` |
| `gapbs_sssp_kron` / `gapbs_sssp_urand` | 34 / 36 GiB | `43G!5G` | `41G!7G` | `38G!10G` |
| `gapbs_tc_kron` / `silo_ycsb` | 38 / 40 GiB | `43G!5G` | `41G!7G` | `37G!11G` |
| `spec2026_849.fotonik3d_s` / `881.neutron_s` | 49 GiB (48 / 49 GiB) | `42G!6G` | `40G!8G` | `35G!13G` |

---

## 9. Directory Structure

```text
workloads/
├── README.md
├── scripts/
│   ├── common.sh
│   ├── cpu_config.sh
│   ├── setup_workloads.sh
│   ├── setup_machine.sh
│   ├── setup_kernel.sh
│   ├── exec_workload.sh
│   ├── run_workloads.sh
│   ├── monitor_performance.sh
│   ├── tier_ts_mon.c
│   ├── calc_overhead.py
│   ├── run_redis.sh
│   └── gcc-linux-x86.cfg
├── stream/
└── output/                  # Per-kernel regress_*.log and timeseries_*.csv outputs
```
