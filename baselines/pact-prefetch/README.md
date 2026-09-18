# PACT-Prefetch (ASPLOS '26 + DaMoN '25 Optimization)

PACT: A Criticality-First Design for Tiered Memory with Throttled NTA Software Prefetching.

This baseline extends PACT on Linux `v6.3` with the hardware-conscious software prefetching principles evaluated in DaMoN '25 (*"Fetch Me If You Can: Evaluating CPU Cache Prefetching and Its Reliability on High Latency Memory"*):
- **Pipelined Stride Lookahead**: Maintains a small, bounded lookahead window (default 6 cachelines = 384B) strictly below Intel Xeon's 10–12 Line Fill Buffer (FB) capacity, preventing core stalls from strong prefetch reliability (`L1D_PEND_MISS.FB_FULL`).
- **NTA Locality (`__builtin_prefetch(ptr, 0, 0)`)**: Issues non-temporal prefetch hints (`PREFETCHNTA`) during folio/page migration copying, hiding remote memory/CXL access latency without polluting L2 and L3 caches.
- **Runtime Sysfs Control**: Dynamic runtime toggling and lookahead tuning via `/sys/kernel/mm/pact_prefetch/` (`enabled`, `lookahead_lines`).

## Contents
- `pact-prefetch.patch` - kernel unified patch targeting `folio_migrate_copy` in `mm/migrate.c`.
- `compile.sh` - checks out clean vanilla Linux `v6.3` in `./linux`, applies `pact-prefetch.patch`, applies Ubuntu compatibility overrides, builds kernel, modules, and PACT runtime.
- `tierinit/` - tier-initialization kernel module that registers the slow tier (node 1) and demotion targets.
- `kswapdrst/` - kswapd reset kernel module preventing `kswapd` demotion stalls.
- `src/` - userspace PACT daemon runtime (`pact`), attaching to target workload processes by PID.

## Build & Management

Manage via the LowTier master kernel management script:

```bash
# Full build: auto-clones Linux v6.3, applies patch, compiles kernel & modules, installs to /boot, updates GRUB
sudo ./baselines/scripts/manage_kernels.sh pact-prefetch

# Compile only (no installation or GRUB change):
sudo ./baselines/scripts/manage_kernels.sh pact-prefetch compile_only

# Switch default boot kernel in GRUB:
sudo ./baselines/scripts/manage_kernels.sh pact-prefetch update_grub
```

Or manually using `compile.sh`:

```bash
cd baselines/pact-prefetch
git clone --depth=1 --branch v6.3 https://github.com/torvalds/linux.git linux
sudo ./compile.sh
```

## Runtime Sysfs Controls

After booting into `6.3.0-PACT-prefetch`:

```bash
# Check status
cat /sys/kernel/mm/pact_prefetch/enabled          # 1 = enabled, 0 = disabled
cat /sys/kernel/mm/pact_prefetch/lookahead_lines   # default 6 cache lines

# Enable / Disable for A/B testing:
echo 1 > /sys/kernel/mm/pact_prefetch/enabled
echo 0 > /sys/kernel/mm/pact_prefetch/enabled

# Tune lookahead distance (1 to 16 lines):
echo 8 > /sys/kernel/mm/pact_prefetch/lookahead_lines
```
