# Tier Prefetch Monitor Daemon (`tier-prefetch-mon`)

A lightweight, non-intrusive userspace PMU daemon (pinned to Core 31 by `setup_kernel.sh`) that monitors fast/slow tier memory access latency via Little's Law ($W = \frac{\Delta\text{TOR\_OCCUPANCY}}{\Delta\text{TOR\_INSERTS}}$) and dynamically paces lookahead prefetch distances across all `*-prefetch` kernel baselines (**AutoNUMA**, **Memtis**, **Nomad**, **Nomad-Alto**, **TPP**, **Colloid-TPP**, **Colloid-TPP-Alto**, **HybridTier**; **PACT-prefetch** links `mig_cha_mon.c` and `mig_telemetry.c` directly into the PACT daemon).

---

## Key Features

1. **Uncore PMU Discovery via `perf_event_open` (`mig_cha_mon.c`)**:
   - Discovers Intel Caching and Home Agent (CHA) devices (`/sys/bus/event_source/devices/uncore_cha_*`).
   - Programs Table of Requests (TOR) hardware counters for local DRAM (fast tier) and remote/CXL memory (slow tier) without MSR hacks or kernel modules.

2. **Little's Law Latency & Adaptive Distance Pacing (`mig_telemetry.c`)**:
   - Computes real-time tier latencies ($L_{\text{slow}}$, $L_{\text{fast}}$) and migration worker copy interval ($T_{\text{int}}$) by tracking the active migration kthread (`async_promote`, `kmigraterd`, `kswapd*`, `knuma_migrated`) against `/proc/vmstat` and `/proc/perfnomad`.
   - Computes lookahead distance: $\text{dist} = \text{clamp}\left(\frac{\text{latency}}{T_{\text{int}}} + 0.5,\ \text{min},\ \text{max}\right)$ with dual-alpha EMA smoothing.

3. **Direct Kernel Sysfs Integration**:
   - Writes updated distances to `/sys/kernel/mm/page_prefetch/promote_distance` and `/sys/kernel/mm/page_prefetch/demote_distance`.
   - Respects `/sys/kernel/mm/page_prefetch/{enabled,adaptive,min_distance,max_distance}` dynamically at runtime.

---

## Building & Usage

```bash
# Build binary
make

# Run in foreground with verbose output
sudo ./tier-prefetch-mon -v

# Run as a background daemon pinned to Core 31 (as launched by setup_kernel.sh)
sudo taskset -c 31 ./tier-prefetch-mon -d -c 0x1fffffe

# Stop daemon
sudo killall tier-prefetch-mon
```

### CLI Options

| Flag | Description |
| :--- | :--- |
| `-m, --mig-tid TID` | Explicit migration worker TID to monitor (`default`: auto-detect; `-1` disables) |
| `-c, --cpu-mask MASK` | CPU mask (hex/dec) for active workload cores (`default`: `0xffffff`; `0` disables CHA PMUs) |
| `-d, --daemon` | Run in background as a daemon |
| `-i, --interval-ms MS` | Sampling interval in milliseconds (`default`: `50`) |
| `-t, --t-copy-ns NS` | Fallback migration copy interval per cache line in ns (`default`: `18.0`) |
| `-H, --thp` | Force 2 MB THP latency thresholds |
| `-v, --verbose` | Enable verbose telemetry logging |
| `-h, --help` | Print usage help |
