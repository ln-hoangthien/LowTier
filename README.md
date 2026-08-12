# LowTier: A Low-Overhead CXL-Based Tiered Memorsy System

## A. Introduction:
**LowTier is a low-overhead, CXL-based tiered memory system designed as a pure OS kernel optimization to address the high profiling overheads and physical copying bottlenecks of conventional tiered memory.**

Unlike traditional frameworks that stall application execution using hardware Performance Monitoring Interrupts (PMIs), LowTier achieves non-interrupt sampling by reading on-chip uncore hardware counters via lightweight high-resolution kernel timers, draining the Processor Event-Based Sampling (PEBS) buffer only during latency-insensitive phases. Furthermore, it re-architects physical page data movement into a direct migration pipeline that utilizes non-temporal prefetching instructions (such as `prefetchNTA`) to pull data into Line Fill Buffers before locking the Page Table Entry, which drastically reduces page lock durations, prevents CPU cache pollution, and eliminates transactional migration aborts under write-heavy workloads. Finally, LowTier incorporates an interconnect-contention-aware policy that dynamically tracks Memory-Level Parallelism (MLP) and loaded latencies to actively suppress unnecessary page promotions during latency-tolerated states or completely halt migrations under severe system-wide bandwidth contention.

## B. Getting started:

An integrated suite for compiling baseline tiered-memory Linux kernels (LowTier, Memtis, Nomad, TPP, Colloid-tpp), setting up open-source workloads, managing GRUB boot configurations, and executing automated performance evaluations.

---

### Table of Contents
1. [Cloning the Environment](#1-cloning-the-environment)
2. [Cloning & Building Related Works (Baseline Kernels)](#2-cloning--building-related-works-baseline-kernels)
3. [Cloning & Building Workloads](#3-cloning--building-workloads)
4. [Updating GRUB & Rebooting into Baseline Kernels](#4-updating-grub--rebooting-into-baseline-kernels)
5. [Running Workloads](#5-running-workloads)

---

### 1. Cloning the Environment

Clone the repository and initialize the environment script:

```bash
# Clone the repository
git clone <repository_url> LowTier
cd LowTier

# Source the environment script to add tool binaries to your $PATH
source bootenv
```

> **Note**: Running `source bootenv` initializes `$PATH`, cleans duplicate paths, and prints current kernel version (`uname -r`) and NUMA hardware topology (`numactl --hardware`).

---

### 2. Cloning & Building Related Works (Baseline Kernels)

The baseline kernels include **Memtis**, **Nomad**, **TPP**, and **Colloid-tpp**. 
> **Notice**: You do *not* need to manually clone Linux kernel repositories prior to building. The build script automatically shallow-clones the appropriate Linux kernel source trees (`v5.15.19`, `v5.13-rc6`, `v5.15`, `v6.3`) into their respective baseline subdirectories if missing.
>
> **Docker Compilation Notice**: When the host system's `gcc` version is 12 or newer (`gcc >= 12`), the compilation scripts automatically invoke Docker (`ubuntu:22.04` container) to build the kernels and workloads. This ensures toolchain compatibility and prevents build errors associated with newer GCC compiler flags or glibc header mismatches.

To compile kernels without modifying system `/boot` or GRUB configuration:

```bash
# Build a specific baseline kernel (compile only)
manage_kernels.sh memtis compile_only
manage_kernels.sh nomad compile_only
manage_kernels.sh tpp compile_only
manage_kernels.sh colloid-tpp compile_only

# Build ALL baseline kernels sequentially
manage_kernels.sh all compile_only
```

---

### 3. Cloning & Building Workloads

The environment includes open-source and free workload benchmarks:
- **STREAM** (Hot & Multi-Phase Tiering)
- **GAPBS** (Graph Analytics Suite: PageRank, TC, BFS, BC, CC, SSSP)
- **Twitter Graph Dataset** (Real-World Graph)
- **Silo** (Transactional OLTP Database)
- **Redis** (In-Memory Key-Value Store)
- **XSBench** (Nuclear Reactor Monte Carlo Simulation)

The setup script automatically clones, extracts, and compiles all open-source workload repositories and binaries.

```bash
# Build a specific open-source workload target
setup_workloads.sh stream
setup_workloads.sh gapbs
setup_workloads.sh twitter
setup_workloads.sh silo
setup_workloads.sh redis
setup_workloads.sh xsbench

# Clone & compile ALL workloads at once
setup_workloads.sh all
```

---

### 4. Updating GRUB & Rebooting into Baseline Kernels

Once a baseline kernel is compiled, update the system GRUB bootloader configuration to set it as the default boot entry.

```bash
# Install modules/kernel, generate initramfs, and set GRUB default entry (e.g. Memtis)
manage_kernels.sh memtis update_grub

# Update GRUB default entry and automatically reboot the system immediately
manage_kernels.sh memtis update_grub --reboot

# Switch default kernel to Nomad or TPP
manage_kernels.sh nomad update_grub --reboot
manage_kernels.sh tpp update_grub --reboot
manage_kernels.sh colloid-tpp update_grub --reboot
```

---

### 5. Running Workloads

Ensure `source bootenv` has been run in your active terminal session. The workload runner automatically handles root privileges via `sudo`.

```bash
# Sourcing environment
source bootenv

# Run a specific benchmark target
run_workloads.sh stream_hot
run_workloads.sh stream_phases
run_workloads.sh gapbs_pr
run_workloads.sh silo
run_workloads.sh redis
run_workloads.sh xsbench

# Run ALL workloads sequentially (saves combined results in output/<kernel-version>/all.log)
run_workloads.sh all

# Run evaluation suite silently in the background using nohup
nohup run_workloads.sh all > run_workload.log 2>&1 &
```

#### Checking Workload Execution Progress
```bash
# Tail evaluation log in real-time
tail -f run_workload.log
```

## C. Citation:
Coming Soon

## D. Contact:
[Thien Le](lnhthien@stu.jejunu.ac.kr)