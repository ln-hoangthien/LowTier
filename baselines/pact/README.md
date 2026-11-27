# PACT (ASPLOS '26 — Linux v6.3)

PACT (Criticality-First Tiered Memory) on Linux `v6.3`, evaluated in both baseline (`pact`) and page-migration prefetching (`pact-prefetch`) configurations.

PACT measures Performance Degradation and Criticality (PAC) via PEBS and CHA uncore occupancy counters in its userspace daemon (`src/pact`) and drives migrations via `move_pages`. In `pact-prefetch`, the daemon embeds adaptive lookahead pacing (sharing `mig_cha_mon.c` / `mig_telemetry.c` from `baselines/tier-prefetch-mon/`) and passes prefetch flags directly into `move_pages`.

## Contents

- `compile.sh` — Checks out `v6.3` in `./linux`, applies `pact-mig-stats.patch`, disables BTF, merges `ubuntu_fixes.config`, sets `CONFIG_LOCALVERSION="-PACT"`, and builds the kernel, modules, and `src/pact`.
- `compile-prefetch.sh` — Applies `pact-prefetch.patch` + `pact-mig-stats.patch` to the kernel and `pact-daemon-prefetch.patch` to `src/`, sets `CONFIG_LOCALVERSION="-PACT-Prefetch"`, and builds the prefetch-enabled kernel and daemon.
- `pact-mig-stats.patch` — Adds migration wait/copy latency vmstat counters (`MIG_WAIT_*`, `MIG_COPY_NS`).
- `pact-prefetch.patch` — Adds `/sys/kernel/mm/page_prefetch/` and `move_pages` prefetch support.
- `pact-daemon-prefetch.patch` — Integrates adaptive CHA/telemetry prefetch pacing into `src/pact`.
- `tierinit/`, `kswapdrst/` — Kernel helper modules for Node 1 slow-tier initialization and kswapd reset.
- `src/` — Userspace `pact` daemon (pinned to Core 29 migration / Core 30 monitor by `setup_kernel.sh`).

## Build & Usage

```bash
# Recommended: build via manage_kernels.sh (auto-clones v6.3 if missing)
sudo ./baselines/scripts/manage_kernels.sh pact build
sudo ./baselines/scripts/manage_kernels.sh pact-prefetch build

# Compile only (no /boot or GRUB modification)
sudo ./baselines/scripts/manage_kernels.sh pact-prefetch compile_only

# Switch GRUB default with target memmap
sudo ./baselines/scripts/manage_kernels.sh pact-prefetch update_grub --memmap "memmap=43G!5G" --reboot
```

Expected `uname -r`: `6.3.0-PACT` or `6.3.0-PACT-Prefetch`. Module loading (`tierinit.ko`, `kswapdrst.ko`) and launching `src/pact` against the target workload PID are handled automatically by `workloads/scripts/setup_kernel.sh`.
