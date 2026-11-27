# Colloid-TPP-Alto (SOSP '24 — Linux v6.3)

Colloid-TPP with Alto extensions (`colloid-skx.patch` + `colloid-skx-alto.patch`) on Linux `v6.3`, evaluated in both baseline (`colloid-tpp-alto`) and page-migration prefetching (`colloid-tpp-alto-prefetch`) configurations.

## Contents

- `compile.sh` — Checks out `v6.3` in `./linux`, applies `colloid-skx.patch`, `colloid-skx-alto.patch`, and `colloid-tpp-alto-mig-stats.patch`, sets `CONFIG_LOCALVERSION="-Colloid-TPP-Alto"`, and builds the kernel and helpers.
- `compile-prefetch.sh` — Adds `colloid-tpp-alto-prefetch.patch`, sets `CONFIG_LOCALVERSION="-Colloid-TPP-Alto-Prefetch"`, and builds the prefetch-enabled kernel.
- `colloid-skx.patch`, `colloid-skx-alto.patch` — Colloid + Alto kernel patches on Linux `v6.3`.
- `colloid-tpp-alto-mig-stats.patch` — Adds migration wait/copy latency vmstat counters (`MIG_WAIT_*`, `MIG_COPY_NS`).
- `colloid-tpp-alto-prefetch.patch` — Adds `/sys/kernel/mm/page_prefetch/` migration prefetching.
- `colloid-mon/`, `tierinit/`, `kswapdrst/` — Colloid monitoring module and tiering helpers.

## Build & Usage

```bash
# Recommended: build via manage_kernels.sh (auto-clones v6.3 if missing)
sudo ./baselines/scripts/manage_kernels.sh colloid-tpp-alto build
sudo ./baselines/scripts/manage_kernels.sh colloid-tpp-alto-prefetch build

# Compile only (no /boot or GRUB modification)
sudo ./baselines/scripts/manage_kernels.sh colloid-tpp-alto-prefetch compile_only

# Switch GRUB default with target memmap
sudo ./baselines/scripts/manage_kernels.sh colloid-tpp-alto-prefetch update_grub --memmap "memmap=43G!5G" --reboot
```

Expected `uname -r`: `6.3.0-Colloid-TPP-Alto` or `6.3.0-Colloid-TPP-Alto-Prefetch`. Helper module loading and `tier-prefetch-mon` are managed automatically by `workloads/scripts/setup_kernel.sh`.
