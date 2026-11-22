# Tier Prefetch Monitor Daemon (`tier-prefetch-mon`)

A lightweight, non-intrusive userspace PMU daemon that monitors tier memory access latency via Little's Law ($W = \frac{\Delta\text{TOR\_OCCUPANCY}}{\Delta\text{TOR\_INSERTS}}$) and dynamically computes optimal lookahead prefetch distances for all prefetch-based kernel baselines (PACT, Nomad, Nomad-Alto, Colloid, Memtis, TPP, HybridTier).

---

## Key Features

1. **Uncore PMU Discovery via `perf_event_open`**:
   - Discovers Intel Caching and Home Agent (CHA) devices (`/sys/bus/event_source/devices/uncore_cha_*`).
   - Automatically programs Table of Requests (TOR) hardware performance counters for fast tier (local DRAM) and slow tier (remote CXL / far memory).
   - Zero kernel drivers or rootkit-style MSR hacks required.

2. **Little's Law Latency & Adaptive Distance Pacing**:
   - Calculates real-time memory access latency ($L_{\text{slow}}$, $L_{\text{fast}}$) from TOR occupancy dwell times.
   - Paces lookahead distance: $\text{dist} = \text{clamp}\left(\frac{\text{latency}}{\text{interval}} + 0.5, \text{min}, \text{max}\right)$.
   - Dual-alpha exponential moving average (EMA) smoothing for stability and fast saturation response.

3. **Direct Kernel Sysfs Integration**:
   - Writes computed distances directly to `/sys/kernel/mm/page_prefetch/promote_distance` and `/sys/kernel/mm/page_prefetch/demote_distance`.
   - Dynamic compatibility: respects `enabled`, `adaptive`, `min_distance`, `max_distance` sysfs toggles in real-time.

---

## Building & Usage

```bash
# Build binary
make

# Run in foreground with verbose output
sudo ./tier-prefetch-mon -v

# Run as background daemon
sudo ./tier-prefetch-mon -d

# Stop daemon
sudo killall tier-prefetch-mon
```
