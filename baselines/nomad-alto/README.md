# Nomad-Alto (OSDI '24 — Linux v5.13-rc6)

Nomad-Alto tiered-memory baseline on Linux `v5.13-rc6` (`nomad.patch` + `nomad-alto.patch`) with the `async_promote` kernel module, evaluated in both baseline (`nomad-alto`) and page-migration prefetching (`nomad-alto-prefetch`) configurations.

## Contents

- `compile.sh` — Checks out `v5.13-rc6` in `./linux`, applies `nomad.patch`, `nomad-alto.patch`, and `nomad-alto-mig-stats.patch`, sets `CONFIG_LOCALVERSION="-Nomad-Alto"`, and compiles the kernel and `nomad_module`.
- `compile-prefetch.sh` — Adds `nomad-alto-prefetch.patch`, sets `CONFIG_LOCALVERSION="-Nomad-Alto-Prefetch"`, and compiles the prefetch-enabled kernel and module.
- `nomad.patch`, `nomad-alto.patch` — Nomad + Alto kernel patches.
- `nomad-alto-mig-stats.patch` — Adds migration wait/copy latency vmstat counters (`MIG_WAIT_*`, `MIG_COPY_NS`).
- `nomad-alto-prefetch.patch` — Adds `/sys/kernel/mm/page_prefetch/` migration prefetching.
- `nomad_module/` — Out-of-tree `async_promote` kernel module.

## Build & Usage

```bash
# Recommended: build via manage_kernels.sh (auto-clones v5.13-rc6 & uses Docker on GCC >= 12)
sudo ./baselines/scripts/manage_kernels.sh nomad-alto build
sudo ./baselines/scripts/manage_kernels.sh nomad-alto-prefetch build

# Compile only (no /boot or GRUB modification)
sudo ./baselines/scripts/manage_kernels.sh nomad-alto-prefetch compile_only

# Switch GRUB default with target memmap
sudo ./baselines/scripts/manage_kernels.sh nomad-alto-prefetch update_grub --memmap "memmap=43G!5G" --reboot
```

Expected `uname -r`: `5.13.0-rc6-Nomad-Alto` or `5.13.0-rc6-Nomad-Alto-Prefetch`. Runtime module loading and `tier-prefetch-mon` are managed automatically by `workloads/scripts/setup_kernel.sh`.
