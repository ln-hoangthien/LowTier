# PACT-Prefetch (Decoupled Latency-Adaptive ERMS Lookahead Prefetching)

**Kernel Release**: `6.3.0-PACT-prefetch`  
**Location**: `baselines/pact-prefetch`

---

## Overview

PACT-Prefetch integrates **decoupled cacheline lookahead prefetching** with Intel Enhanced REP MOVSB (ERMS) hardware memory copying during tiered page migration (`folio_migrate_copy`).

```
Cache Line Index (64B):  [ 0 ][ 1 ][ 2 ][ 3 ][ 4 ][ 5 ][ 6 ][ 7 ] ... [ 63 ]
                         ▲                             ▲
                         │◄────── Distance D ─────────►│
```

1. **Pipeline Priming**:
   Before bulk transfer, primes $D$ cache lines (`distance`) into the CPU cache hierarchy using non-temporal (NTA) or cache hints.
2. **Bulk ERMS Transfer**:
   Executes hardware-accelerated memory copy (`copy_page` / native `rep movsb`). Because the source window is pre-staged in the LFB/cache, remote UPI/CXL memory stall latency is avoided.
3. **Low-Overhead Timeliness Sampling**:
   Periodically samples line 0 access latency via 1-in-64 stride subsampling (`rdtsc_ordered`), tracking timely hits vs late prefetch rates without pipeline serialization overhead.

---

## Adaptation Modes: Static vs Dynamic Little's Law

The prefetch distance can operate in two modes:

### 1. Static Mode (`adaptive=0`)
- Ignores runtime PMU fluctuations and uses fixed, deterministic prefetch lookahead distances:
  - **Promotion** (Remote slow tier $\to$ Local fast tier): `PREFETCH_DEFAULT_PROMOTE_DISTANCE` (default: **5**)
  - **Demotion** (Local fast tier $\to$ Remote slow tier): `PREFETCH_DEFAULT_DEMOTE_DISTANCE` (default: **2**)
- The user-space PACT daemon automatically detects `adaptive=0` and does **not** update or clobber sysfs.

### 2. Dynamic Little's Law Mode (`adaptive=1`)
- The user-space PACT daemon (`src/pact`) samples Intel CHA Table of Requests (TOR) PMU uncore counters at ~25Hz cadence:
  - $\text{Uncore Latency} = \frac{\sum \text{TOR\_OCCUPANCY}}{\sum \text{TOR\_INSERTS}}$ (converted to ns via calibrated 2.5 GHz fast uncore and 1.3 GHz throttled slow uncore clocks)
  - Core Latency $L_{\text{core}}$ derived from offcore response counters and TSC core frequency
  - Injection delay $T_{\text{inject}} = L_{\text{core}} - L_{\text{uncore, aggregate}}$
  - Little's Law Lookahead Distance:
    $$D = \frac{L_{\text{uncore}}}{T_{\text{inject}}}$$
- Distances are bounded to $[1, 16]$, smoothed via Exponential Moving Average (EMA, $\alpha = 0.5$), and written to sysfs (`promote_distance`, `demote_distance`) via fast integer `pwrite()`.
- The kernel dynamically clamps the distances to `[min_distance, max_distance]`.

---

## Runtime Sysfs Controls (`/sys/kernel/mm/page_prefetch/`)

Configurable via sysfs (with backwards-compatibility symlink `/sys/kernel/mm/pact_prefetch/`):

| Sysfs Attribute | Permissions | Default | Description |
| :--- | :--- | :--- | :--- |
| `enabled` | `rw` | `1` | Master prefetch toggle (`1` = enabled, `0` = disabled) |
| `adaptive` | `rw` | `1` | Mode toggle (`0` = static defaults, `1` = dynamic Little's Law) |
| `promote_distance` | `rw` | `5` | Active lookahead distance for tiered promotion ($1 \dots 64$) |
| `demote_distance` | `rw` | `2` | Active lookahead distance for tiered demotion ($1 \dots 64$) |
| `min_distance` | `rw` | `1` | Minimum clamp distance for adaptive mode |
| `max_distance` | `rw` | `16` | Maximum clamp distance for adaptive mode |
| `hint` | `rw` | `0` | Prefetch cache hint (`0`=NTA, `1`=L3, `2`=L2, `3`=L1) |
| `stats` | `r` | - | Read timeliness probe statistics and hit ratios |
| `stats_reset` | `w` | - | Write `1` to reset per-CPU timeliness counters |

### Example Sysfs Commands

```bash
# Enable / disable prefetching
echo 1 > /sys/kernel/mm/page_prefetch/enabled

# Switch to Static mode
echo 0 > /sys/kernel/mm/page_prefetch/adaptive

# Adjust clamp bounds for adaptive mode
echo 1  > /sys/kernel/mm/page_prefetch/min_distance
echo 12 > /sys/kernel/mm/page_prefetch/max_distance

# Set prefetch cache hint (0=NTA, 1=L3, 2=L2, 3=L1)
echo 0 > /sys/kernel/mm/page_prefetch/hint

# Read hardware timeliness statistics
cat /sys/kernel/mm/page_prefetch/stats

# Reset timeliness statistics
echo 1 > /sys/kernel/mm/page_prefetch/stats_reset
```

---

## Low-Overhead Engineering Optimizations

1. **Lockless Per-CPU Value-Change Logging**:
   `folio_migrate_copy` avoids `pr_info_ratelimited` spinlock contention by logging only when distance or NUMA node changes on that CPU core.
2. **1-in-64 Stride Subsampling**:
   Probes cache timeliness via `rdtsc_ordered()` only once every 64 pages (`& 0x3F == 0`), eliminating >97% of pipeline serialization (`lfence`) overhead while maintaining full statistical confidence.
3. **Zero-Overhead Daemon Bailout in Static Mode**:
   When `PREFETCH_ADAPTIVE=0`, `pact_update_prefetch_distance()` in `pmu.c` exits immediately on the first branch without issuing `snprintf` or `pwrite()` syscalls.

---

## Build and Install

```bash
# Full build and install via manage_kernels.sh:
sudo ./baselines/scripts/manage_kernels.sh pact-prefetch

# Compile only:
sudo ./baselines/scripts/manage_kernels.sh pact-prefetch compile_only

# Switch GRUB default:
sudo ./baselines/scripts/manage_kernels.sh pact-prefetch update_grub
```

---

## Running Benchmarks

### Adaptive Runs (`PREFETCH_ADAPTIVE=1`)
```bash
# Run with dynamic Little's Law adaptation (clamped between 1 and 12)
sudo PREFETCH_ADAPTIVE=1 PREFETCH_MIN_DISTANCE=1 PREFETCH_MAX_DISTANCE=12 \
    ./workloads/scripts/run_workloads.sh gapbs_bc kron 1:4
```

### Static Runs (`PREFETCH_ADAPTIVE=0`)
```bash
# Run with static distances (promote=6, demote=1)
sudo PREFETCH_ADAPTIVE=0 PREFETCH_PROMOTE_DISTANCE=6 PREFETCH_DEMOTE_DISTANCE=1 \
    ./workloads/scripts/run_workloads.sh gapbs_bc kron 1:4

# Or using shorthand notation:
sudo PREFETCH_ADAPTIVE=0 PREFETCH_PROMOTE_DISTANCE=p6_d1 \
    ./workloads/scripts/run_workloads.sh gapbs_bc kron 1:4
```

### Prefetch Disabled (`PREFETCH_ENABLED=0`)
```bash
# Run baseline without prefetching
sudo PREFETCH_ENABLED=0 PREFETCH_ADAPTIVE=0 \
    ./workloads/scripts/run_workloads.sh gapbs_bc kron 1:4
```
