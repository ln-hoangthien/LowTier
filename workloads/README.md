# LowTier Workload Evaluation Suite

This directory contains the benchmark workloads, datasets, and automation scripts used to evaluate the **LowTier** tiered memory system and comparison baselines (**Nomad**, **Nomad-Alto**, **Memtis**, **TPP**, **Colloid-tpp**, **PACT**, and **HybridTier**).

---

## Table of Contents

1. [Overview & Architecture](#1-overview--architecture)
2. [Workload Classification: Open-Source vs Proprietary](#2-workload-classification-open-source-vs-proprietary)
3. [Open-Source Workloads (GitHub Sync)](#3-open-source-workloads-github-sync)
   - [GAPBS (Graph Algorithm Platform Benchmark Suite)](#gapbs-graph-algorithm-platform-benchmark-suite)
   - [Silo (In-Memory Transactional OLTP Database)](#silo-in-memory-transactional-oltp-database)
   - [Redis (In-Memory Key-Value Store)](#redis-in-memory-key-value-store)
   - [STREAM (Memory Bandwidth & Tiering Variants)](#stream-memory-bandwidth--tiering-variants)
   - [XSBench (Monte Carlo Transport Simulation)](#xsbench-monte-carlo-transport-simulation)
4. [Proprietary & Licensed Workloads](#4-proprietary--licensed-workloads)
   - [SPEC CPU 2026 (`spec2026`)](#spec-cpu-2026-spec2026)
   - [Intel Memory Latency Checker (`mlc`)](#intel-memory-latency-checker-mlc)
5. [Automated Setup & Build Guide](#5-automated-setup--build-guide)
6. [Workload Execution & Profiling Tools](#6-workload-execution--profiling-tools)
7. [Memory Footprint (RSS) & Tier Ratios](#7-memory-footprint-rss--tier-ratios)
8. [Directory Structure](#8-directory-structure)

---

## 1. Overview & Architecture

The workloads in this suite are curated to cover diverse memory access behaviors under tiered memory architectures:
- **Streaming & Bandwidth-Bound**: Sequential access with high throughput demands (STREAM).
- **Pointer-Chasing & Memory Latency-Bound**: Irregular memory accesses and low spatial/temporal locality (GAPBS, XSBench).
- **Cache-Pollution & Write-Intensive**: High mutation rates and lock contention (Silo TPC-C/YCSB, Redis).
- **Heterogeneous Real-World Computation**: Complex instruction and data working sets (SPEC CPU 2026).

Workloads are run across simulated NUMA tiers:
- **Node 0 (Fast Tier / Local DRAM)**: Constrained via `memmap` (e.g. `memmap=35G!13G`) to force tiering pressure.
- **Node 1 (Slow Tier / CXL Emulation)**: Degraded uncore frequency (~1.3 GHz) to simulate typical CXL memory latencies (~185ns to 200ns).

---

## 2. Workload Classification: Open-Source vs Proprietary

> [!IMPORTANT]
> **All workloads in this repository are open source and can be automatically cloned or synced from public GitHub repositories, with the exception of `spec2026` and `mlc`.**

| Workload | Category | License / Type | Source / Sync Repository | Footprint (RSS) |
|---|---|---|---|---|
| **GAPBS** | Graph Analytics | Open Source (BSD-3-Clause) | [github.com/sbeamer/gapbs](https://github.com/sbeamer/gapbs) | 12 – 38 GB |
| **Silo** | In-Memory Database | Open Source (MIT) | [github.com/stephentu/silo](https://github.com/stephentu/silo) | 18 – 57 GB |
| **Redis** | Key-Value Database | Open Source (BSD-3-Clause) | [github.com/redis/redis](https://github.com/redis/redis) | ~26 GB |
| **STREAM** | Bandwidth / Microbench | Open Source (Custom) | [github.com/jeffhammond/STREAM](https://github.com/jeffhammond/STREAM) | ~18 – 19 GB |
| **XSBench** | Scientific Simulation | Open Source (MIT) | [github.com/ANL-CESAR/XSBench](https://github.com/ANL-CESAR/XSBench) | ~18 GB |
| **SPEC CPU 2026** | Standard Benchmark Suite | **Proprietary Commercial** | Licensed from SPEC | 1 – 49 GB |
| **Intel MLC** | Memory Diagnostic Tool | **Proprietary Intel** | Intel Developer Zone | Configurable |

---

## 3. Open-Source Workloads (GitHub Sync)

### GAPBS (Graph Algorithm Platform Benchmark Suite)
- **Repository**: [https://github.com/sbeamer/gapbs.git](https://github.com/sbeamer/gapbs.git)
- **Target Algorithms**:
  - `gapbs_bc`: Betweenness Centrality
  - `gapbs_tc`: Triangle Counting
  - `gapbs_pr`: PageRank
  - `gapbs_bfs`: Breadth-First Search
  - `gapbs_cc`: Connected Components
  - `gapbs_sssp`: Single-Source Shortest Paths
- **Graph Datasets Supported**:
  - `kron`: Kronecker Synthetic Graph ($2^{27}$ vertices, scale 27)
  - `urand`: Uniform Random Graph ($2^{27}$ vertices, scale 27)
  - `twitter`: Real-world Twitter follower network dataset
  - `web` & `road`: Web crawl and road network topologies
- **Compilation**: Built via `make bench-graphs` inside `workloads/gapbs`.

### Silo (In-Memory Transactional OLTP Database)
- **Repository**: [https://github.com/stephentu/silo.git](https://github.com/stephentu/silo.git)
- **Submodule**: [https://github.com/kohler/masstree-beta.git](https://github.com/kohler/masstree-beta.git) (Masstree indexing backend)
- **Target Benchmarks**:
  - `silo_tpcc`: TPC-C Online Transaction Processing (high-concurrency write/read transactions)
  - `silo_ycsb`: Yahoo! Cloud Serving Benchmark
  - `silo_queue`, `silo_bid`, `silo_encstress`
- **Build Notes**: Automatically pulls dependencies (`libdb++-dev`, `libnuma-dev`, `libjemalloc-dev`, `libaio-dev`, `libssl-dev`) and synchronizes the Masstree submodule over HTTPS.

### Redis (In-Memory Key-Value Store)
- **Repository**: [https://github.com/redis/redis.git](https://github.com/redis/redis.git) (cloned to `workloads/redis_src`)
- **Execution**: Runs `redis-server` paired with `redis-benchmark` across multiple worker threads.
- **Parameters**: 4.3M keys with 8 KB payloads (~26.3 GB memory footprint), testing interleaved `set` and `get` operations.

### STREAM (Memory Bandwidth & Tiering Variants)
- **Repository**: [https://github.com/jeffhammond/STREAM.git](https://github.com/jeffhammond/STREAM.git)
- **Variants Included**:
  - `stream`: Classic STREAM benchmark compiled with large array sizes ($800\text{M elements} \times 8\text{B} \times 3 \approx 19.2\text{ GB}$).
  - `stream_hot`: Hot-working-set variant causing rapid page migration pressure.
  - `stream_phase`: Multi-phase execution cycling between high-intensity computation and memory sweep phases.

### XSBench (Monte Carlo Transport Simulation)
- **Repository**: [https://github.com/ANL-CESAR/XSBench.git](https://github.com/ANL-CESAR/XSBench.git)
- **Details**: Mini-app representing the computational kernel of the OpenMC Monte Carlo neutron transport code. Heavily exercises continuous-energy microscopic cross-section lookups with irregular memory access patterns.

---

## 4. Proprietary & Licensed Workloads

> [!WARNING]
> Due to licensing and copyright agreements, the following benchmarks **cannot** be hosted on public repositories or synced from GitHub.

### SPEC CPU 2026 (`spec2026`)
- **Provider**: Standard Performance Evaluation Corporation (SPEC)
- **Distribution Format**: ISO installer image (`cpu2026-1.0.1.iso`) located in `workloads/`.
- **License**: Proprietary commercial software. Redistribution is prohibited under SPEC license agreements.
- **Supported Benchmarks in Suite**:
  - **SPECrate®2026**: `spec2026_706.stockfish_r`, `spec2026_708.sqlite_r`, `spec2026_709.cactus_r`, `spec2026_721.gcc_r`, `spec2026_723.llvm_r`, `spec2026_765.roms_r`, `spec2026_782.lbm_r`, etc.
  - **SPECspeed®2026**: `spec2026_801.xz_s`, `spec2026_820.cloverleaf_s`, `spec2026_865.roms_s`, `spec2026_881.neutron_s`, etc.
- **Configuration**: Uses `workloads/scripts/gcc-linux-x86.cfg` for optimized GCC compilation.

### Intel Memory Latency Checker (`mlc`)
- **Provider**: Intel Corporation
- **Distribution Format**: Distributed under the *Intel Memory Latency Tools Outbound License Agreement* (`workloads/mlc/mlc_v3.13.tgz`).
- **License**: Proprietary freeware. Must be obtained directly from Intel Developer Zone.
- **Use Case**: Hardware validation, measuring baseline memory bandwidth, loaded latency, and cross-socket NUMA / CXL latency curves.

---

## 5. Automated Setup & Build Guide

The master setup script [`setup_workloads.sh`](file:///home/c425-xeon/thienle/LowTier/workloads/scripts/setup_workloads.sh) automates cloning, patching, submodule checkout, and building of all open-source workloads.

### Usage

```bash
# View all available targets and options
sudo ./workloads/scripts/setup_workloads.sh --help

# Build a single open-source workload
sudo ./workloads/scripts/setup_workloads.sh stream
sudo ./workloads/scripts/setup_workloads.sh gapbs
sudo ./workloads/scripts/setup_workloads.sh silo
sudo ./workloads/scripts/setup_workloads.sh redis
sudo ./workloads/scripts/setup_workloads.sh xsbench

# Clone & compile ALL open-source workloads at once
sudo ./workloads/scripts/setup_workloads.sh all
```

### Build Features
- **Automatic Shallow Clones**: Clones official repositories from GitHub if the directory is missing.
- **Compiler Compatibility**: Automatically handles GCC 12+ flag adjustments (`-Wno-error`) and injects C++ header compatibility for standard library ADL streaming (`config/pair_stream.h` in Silo).
- **Graph Dataset Generation**: Automatically generates synthetic benchmark graphs (`kron`, `urand`) via GAPBS `bench.mk`.

---

## 6. Workload Execution & Profiling Tools

Located in [`workloads/scripts/`](file:///home/c425-xeon/thienle/LowTier/workloads/scripts):

| Script | Purpose |
|---|---|
| [`run_workloads.sh`](file:///home/c425-xeon/thienle/LowTier/workloads/scripts/run_workloads.sh) | **Master evaluation runner**. Configures tiered CPU topology (offlines CPUs 32..64), clears memory caches, preloads datasets to Node 1, runs `bpftrace` NUMA latency probes, starts `perf stat`, tunes online migration prefetching parameters, and logs results. |
| [`exec_workload.sh`](file:///home/c425-xeon/thienle/LowTier/workloads/scripts/exec_workload.sh) | **Execution dispatcher**. Pure command builder that resolves and formats `numactl --physcpubind=...` execution lines without profiling overhead. |
| [`run_with_stats.sh`](file:///home/c425-xeon/thienle/LowTier/workloads/scripts/run_with_stats.sh) | **Runtime telemetry monitor**. Wraps the workload execution and samples memory migration rates, page faults, CPU utilization, and latency metrics at 1-second intervals. |

### Running a Workload Manually

```bash
# Run STREAM Hot variant
sudo ./workloads/scripts/run_workloads.sh stream_hot

# Run GAPBS Betweenness Centrality on Kron graph
sudo ./workloads/scripts/run_workloads.sh gapbs_bc kron

# Run Silo TPC-C benchmark
sudo ./workloads/scripts/run_workloads.sh silo_tpcc

# Run Redis in-memory benchmark
sudo ./workloads/scripts/run_workloads.sh redis

# Run SPEC CPU 2026 Cloverleaf benchmark
sudo ./workloads/scripts/run_workloads.sh spec2026_820.cloverleaf_s
```

---

## 7. Memory Footprint (RSS) & Tier Ratios

The memory footprint (Resident Set Size) of each benchmark is calibrated in `manage_kernels.sh` to determine fast-tier (Node 0) and slow-tier (Node 1) sizing:

$$\text{FastTier}(\text{GB}) = \frac{\text{RSS} \times \text{FastRatio}}{\text{FastRatio} + \text{SlowRatio}} + \text{OS Headroom}$$

### Measured RSS Reference

| Workload Target | Measured RSS | Default Node 0 Allocation (1:1 Ratio) |
|---|---|---|
| `gapbs_bc_kron` | ~19.5 GB | 13 GB (Fast) : 35 GB (Slow) |
| `gapbs_tc_kron` | ~37.5 GB | 22 GB (Fast) : 26 GB (Slow) |
| `gapbs_sssp_kron` | ~33.8 GB | 20 GB (Fast) : 28 GB (Slow) |
| `gapbs_pr_kron` | ~17.8 GB | 12 GB (Fast) : 36 GB (Slow) |
| `silo_tpcc` | ~17.9 GB | 12 GB (Fast) : 36 GB (Slow) |
| `silo_ycsb` | ~40.0 GB | 23 GB (Fast) : 25 GB (Slow) |
| `redis` | ~26.3 GB | 16 GB (Fast) : 32 GB (Slow) |
| `xsbench` | ~18.1 GB | 12 GB (Fast) : 36 GB (Slow) |
| `stream_hot` | ~18.0 GB | 12 GB (Fast) : 36 GB (Slow) |
| `spec2026_820.cloverleaf_s` | ~22.0 GB | 14 GB (Fast) : 34 GB (Slow) |
| `spec2026_865.roms_s` | ~22.6 GB | 14 GB (Fast) : 34 GB (Slow) |

---

## 8. Directory Structure

```
workloads/
├── README.md               # This documentation
├── scripts/
│   ├── setup_workloads.sh  # Automated workload clone & build script
│   ├── run_workloads.sh    # Evaluation runner with bpftrace & perf
│   ├── exec_workload.sh    # Pure execution dispatcher
│   └── run_with_stats.sh   # Per-second telemetry monitor
└── output/                 # Output evaluation logs & latency statistics
```
