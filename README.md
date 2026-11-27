# LowTier: Adaptive Page-Migration Prefetching for Tiered Memory

> **Naming Note:** *LowTier* is a legacy working name (to be renamed). The project now focuses exclusively on **adaptive software prefetching for page migration** (`page_prefetch`), evaluated uniformly across state-of-the-art Linux tiered-memory baselines.

## Overview

In tiered-memory systems (local fast DRAM + remote/CXL slow memory), physical page copying during promotion and demotion stalls on remote read latency and pollutes CPU caches. This repository provides a unified **in-kernel page-migration prefetching mechanism** paired with an **adaptive userspace pacing daemon**, along with automated kernel management, workload benchmarking, and multi-kernel regression tooling.

### Core Components

1. **Unified Kernel Page-Migration Prefetching (`baselines/*/*-prefetch.patch`)**
   - Instruments the page-migration copy path across all 9 tiered-memory Linux baselines.
   - Controlled dynamically at runtime via `/sys/kernel/mm/page_prefetch/`:
     - `enabled` (`0` / `1`): enable or disable migration prefetching.
     - `naive` (`0` = **Deep-tune** two-wave pipelined copy with cross-folio lookahead; `1` = **Naive** fixed-ahead prefetch).
     - `adaptive` (`0` = static lookahead distance; `1` = dynamic pacing by `tier-prefetch-mon` / PACT).
     - `hint` (`0` = `NTA`, `1` = `L3`, `2` = `L2`, `3` = `L1`).
     - `promote_distance`, `demote_distance`, `min_distance`, `max_distance`: lookahead distances in cache lines.
   - Paired with `*-mig-stats.patch` across all baselines to expose migration stall and copy-time counters (`MIG_WAIT_COUNT`, `MIG_WAIT_US`, `MIG_WAIT_HUGE_COUNT`, `MIG_WAIT_HUGE_US`, `MIG_COPY_NS`) in `/proc/vmstat`.

2. **Adaptive Pacing Daemon ([`baselines/tier-prefetch-mon/`](baselines/tier-prefetch-mon/README.md))**
   - Lightweight userspace PMU daemon (pinned to Core 31) that reads Intel CHA uncore TOR occupancy/inserts via `perf_event_open` (Little's Law) to measure real-time fast/slow tier latency and dynamically pace `promote_distance` and `demote_distance`.

3. **Zero-Overhead Telemetry & Automated Regression Suite**
   - **Telemetry ([`workloads/scripts/tier_ts_mon.c`](workloads/scripts/tier_ts_mon.c), [`monitor_performance.sh`](workloads/scripts/monitor_performance.sh))**: Samples `/proc/vmstat`, `/proc/perfnomad`, uncore IMC/UPI DRAM traffic, and AutoNUMA core PMUs from a dedicated spare core (Core 28) on Node 1 with zero workload interference.
   - **Multi-Kernel Orchestrator ([`regression/run_auto_regression.sh`](regression/run_auto_regression.sh))**: Automates kernel/GRUB switching, dynamic RSS-to-`memmap` fast-tier sizing, systemd post-reboot resumption, same-boot CPU offline retention (`KEEP_MACHINE_CONFIG=1`), and kernel hang/crash recovery.

---

## Evaluated Hardware Platform

All experiments are evaluated on a dual-socket **HP Z8 G5 Workstation** configured as a 2-tier NUMA system (Node 0 = Fast Local DRAM, Node 1 = CPU-less Emulated CXL Slow Memory; NUMA distance `10` local / `21` remote):

| Component | Node 0 (Socket 0 — Fast Tier) | Node 1 (Socket 1 — Emulated CXL Slow Tier) |
| :--- | :--- | :--- |
| **CPU Model** | Intel® Xeon® Gold 6448Y (Sapphire Rapids, 32 physical cores, SMT off) | Intel® Xeon® Gold 6448Y (32 physical cores, SMT off) |
| **CPU State** | **Online** (CPUs `0–31`: Cores `1–24` workload, `0`/`25–27` OS/kernel, `28–31` telemetry & tiering daemons) | **Offlined** (`CPUs 32–63` offline during evaluation; acts as CPU-less memory node) |
| **Core Frequency** | **Clamped to `3.0 GHz`** (`performance` governor, `min=max=3.0 GHz`, `no_turbo=0`; HW range `0.8–4.1 GHz`) | N/A (all CPUs offline) |
| **Uncore Frequency** | **Locked to `2.5 GHz`** (`2500000 kHz`; HW range `0.8–2.5 GHz`) | **Locked to `1.3 GHz`** (`1300000 kHz`, configured before offlining CPUs `32–63` so the MSR persists; emulates ~185–200 ns CXL latency) |
| **Caches** | `1.5 MiB` L1d (`32×48 KiB`), `1 MiB` L1i (`32×32 KiB`), `64 MiB` L2 (`32×2 MiB`), `60 MiB` L3 | **Offlined** |
| **Physical DRAM** | **`48 GiB`** DDR5 (`3 × 16 GiB` DIMMs across Socket 0 `IMC#0`, `IMC#1`, `IMC#3`) | **`256 GiB`** DDR5 (`4 × 64 GiB` DIMMs across Socket 1 `IMC#0–IMC#3`, ~`254 GiB` usable) |
| **Effective Capacity** | Dynamically capped per workload/ratio via GRUB `memmap=` (`4–40 GiB`) | Full `256 GiB` slow-tier capacity |

Hardware frequency locking and CPU offlining are automated by [`workloads/scripts/setup_machine.sh`](workloads/scripts/setup_machine.sh) (and restored via `--restore`).

### Dynamic `memmap` Sizing Based on Workload RSS

Because Node 0 has **`48 GiB`** of physical DRAM, fast-tier capacity is constrained at boot using the Linux `memmap=<reserved>G!<fast>G` kernel parameter, which reserves `reserved = 48 - fast` GiB starting at physical address `fast` GiB so only `fast` GiB remains usable on Node 0.

[`baselines/scripts/manage_kernels.sh`](baselines/scripts/manage_kernels.sh) computes `memmap` automatically from each workload's calibrated Resident Set Size (`get_rss()`) and the requested Fast:Slow tier ratio (`F:S`):

$$\text{Fast}_{\text{GiB}} = \text{clamp}\!\left(\left\lfloor \frac{\text{RSS} \times F}{F + S} + \text{OS\_HEADROOM} + 0.5 \right\rfloor,\ 1,\ 40\right)$$

$$\text{memmap} = \texttt{memmap=}(48 - \text{Fast}_{\text{GiB}})\texttt{G!}\text{Fast}_{\text{GiB}}\texttt{G}$$

- **`OS_HEADROOM = 3 GiB`** (default): reserves headroom on Node 0 for the kernel image, page tables, and slab so the workload receives approximately its target `F/(F+S)` fast-tier share.
- **Within-1 GiB RSS snapping**: benchmarks within 1 GiB of a peer tier are snapped in `get_rss()` (preserving original measured values in comments) so they share identical `memmap` boots.

**Examples:**

| Benchmark | Calibrated RSS | Ratio (`F:S`) | Workload Fast Share | `+ 3 GiB` OS Headroom (`Fast`) | Resulting GRUB `memmap` |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `gapbs_pr_kron` | `18 GiB` | `1:16` | `1.06 GiB` | `4 GiB` | `memmap=44G!4G` |
| `gapbs_pr_kron` | `18 GiB` | `1:8` | `2.00 GiB` | `5 GiB` | `memmap=43G!5G` |
| `gapbs_sssp_kron` | `34 GiB` | `1:4` | `6.80 GiB` | `10 GiB` | `memmap=38G!10G` |
| `spec2026_849.fotonik3d_s` | `49 GiB` (48 actual) | `1:4` | `9.80 GiB` | `13 GiB` | `memmap=35G!13G` |

**Applying `memmap` via `manage_kernels.sh`:**

```bash
# Preview the computed memmap parameter for any (benchmark, ratio)
./baselines/scripts/manage_kernels.sh resolve_memmap gapbs_pr_kron 1:8
# -> memmap=43G!5G

# Update GRUB automatically from benchmark + ratio (strips old memmap params, updates GRUB, reboots)
sudo ./baselines/scripts/manage_kernels.sh memtis-prefetch update_grub --benchmark gapbs_pr_kron --ratio 1:8 --reboot

# Or pass an explicit memmap string directly
sudo ./baselines/scripts/manage_kernels.sh memtis-prefetch update_grub --memmap "memmap=43G!5G" --reboot
```

During automated regressions, [`regression/run_auto_regression.sh`](regression/run_auto_regression.sh) calls `resolve_memmap` for every step and only updates GRUB and reboots when the target kernel or `memmap` changes.

---

## Repository Layout

```text
LowTier/
├── bootenv                          # Environment setup (adds script dirs to $PATH)
├── baselines/                       # 9 tiered-memory kernels (baseline + -prefetch) & manage_kernels.sh
│   ├── README.md                    # Kernel matrix, build & GRUB management guide
│   ├── scripts/manage_kernels.sh    # Automated clone, patch, build, install, GRUB & RSS/memmap tool
│   ├── tier-prefetch-mon/           # Adaptive uncore-PMU prefetch distance pacing daemon
│   ├── autonuma/                    # Upstream Linux v7.3 AutoNUMA (+ tierinit)
│   ├── memtis/                      # Memtis (Linux v5.15.19)
│   ├── nomad/                       # Nomad (Linux v5.13-rc6)
│   ├── nomad-alto/                  # Nomad-Alto (Linux v5.13-rc6)
│   ├── tpp/                         # TPP (Linux v5.15)
│   ├── colloid-tpp/                 # Colloid-TPP (Linux v6.3)
│   ├── colloid-tpp-alto/            # Colloid-TPP-Alto (Linux v6.3)
│   ├── pact/                        # PACT (Linux v6.3 + userspace daemon)
│   └── hybridtier/                  # HybridTier (Linux v6.2 + userspace runtime)
├── workloads/                       # Benchmarks, datasets & evaluation scripts
│   ├── README.md                    # Workload suite, CPU topology, telemetry & RSS reference
│   └── scripts/                     # setup_workloads.sh, run_workloads.sh, exec_workload.sh, etc.
└── regression/                      # Multi-kernel / multi-ratio regression automation
    ├── regression_list              # Target kernels, ratios, THP/prefetch sweeps & benchmark order
    ├── run_auto_regression.sh       # Systemd-backed cross-reboot regression orchestrator
    └── run_regression.sh            # Single-kernel regression helper
```

---

## Getting Started

### 1. Initialize the Environment

```bash
git clone <repository_url> LowTier
cd LowTier

# Add baselines/scripts, workloads/scripts, and regression to $PATH
source bootenv
```

`source bootenv` updates `$PATH` cleanly (deduplicating entries), preserves `$PATH` across `sudo`, and prints the running kernel (`uname -r`) and NUMA topology (`numactl --hardware`).

---

### 2. Build & Manage Baseline and Prefetch Kernels

All 9 baselines ship both a vanilla baseline target and a `-prefetch` target. You do not need to clone Linux kernel trees manually; `manage_kernels.sh` automatically shallow-clones the required tag and invokes an `ubuntu:22.04` Docker container when older kernels (e.g., 5.13 / 5.15) are compiled on hosts with `gcc >= 12`.

```bash
# Compile only (no /boot or GRUB modification)
sudo manage_kernels.sh memtis compile_only
sudo manage_kernels.sh memtis-prefetch compile_only
sudo manage_kernels.sh autonuma-prefetch compile_only

# Full build, install, and set GRUB default with dynamic RSS-based memmap
sudo manage_kernels.sh pact-prefetch build --benchmark gapbs_pr_kron --ratio 1:8 --reboot

# Switch an already-installed kernel and memmap in GRUB
sudo manage_kernels.sh autonuma-prefetch update_grub --memmap "memmap=43G!5G" --reboot

# Clean custom kernel entries and strip memmap/mem/numa/idle params from GRUB
sudo manage_kernels.sh clean_grub
```

See [`baselines/README.md`](baselines/README.md) for the complete target table and options.

---

### 3. Build Workloads

Open-source workloads (**GAPBS**, **Silo**, **Redis**, **XSBench**, **STREAM**) are automatically cloned and compiled via `setup_workloads.sh`. Proprietary benchmarks (**SPEC CPU 2026**, **Intel MLC**) must be placed locally under `workloads/` due to licensing.

```bash
# Build individual open-source workloads
sudo setup_workloads.sh gapbs
sudo setup_workloads.sh silo
sudo setup_workloads.sh redis
sudo setup_workloads.sh xsbench
sudo setup_workloads.sh stream

# Clean & pre-build all configured benchmarks
sudo setup_workloads.sh all
```

See [`workloads/README.md`](workloads/README.md) for workload parameters, CPU core allocation (`cpu_config.sh`), and RSS sizing.

---

### 4. Run a Single Workload

`run_workloads.sh` handles machine setup (locking CPU/uncore clocks and offlining Socket 1 CPUs `32..63`), cache cleaning, GAPBS Node 1 graph preloading, kernel/prefetch setup, zero-overhead telemetry, and hardware restoration on exit:

```bash
# Run a single benchmark with default settings
sudo run_workloads.sh gapbs_pr_kron
sudo run_workloads.sh silo_tpcc
sudo run_workloads.sh spec2026_820.cloverleaf_s

# Run with explicit tier ratio, THP mode, and prefetch parameters
sudo TIER_RATIO=1:8 THP_MODE=madvise PREFETCH_ADAPTIVE=1 PREFETCH_NAIVE=1 \
     PREFETCH_MIN_DISTANCE=min0_max6 PREFETCH_HINT=0 \
     run_workloads.sh gapbs_bc_kron
```

Results and 1-second time-series CSVs are saved under `workloads/output/<uname -r>/`.

---

### 5. Automated Multi-Kernel Regression

Edit [`regression/regression_list`](regression/regression_list) to configure `KERNELS`, `TIER_RATIOS`, `THP_MODES`, `PREFETCH_*` sweeps, and `BENCHMARKS`, then run:

```bash
# Start a fresh regression (pre-builds benchmarks, installs systemd resume service)
sudo run_auto_regression.sh start

# Check live progress, active kernel/memmap, and current step
run_auto_regression.sh status

# Resume from saved state, stop safely (restores CPUs), or reset state/logs
sudo run_auto_regression.sh resume
sudo run_auto_regression.sh stop
sudo run_auto_regression.sh reset
```

Benchmarks in `regression_list` are grouped by RSS tier and ratio-bridging `memmap` order (7 boots/kernel for the default 13-benchmark × 3-ratio matrix), and CPUs `32..63` remain offline across consecutive steps within the same boot to eliminate redundant hotplug overhead.

---

## Citation

Coming Soon.

## Contact

[Thien Le](mailto:lnhthien@stu.jejunu.ac.kr)
