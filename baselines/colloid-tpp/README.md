# Colloid-TPP (SOSP '24 — Linux v6.3)

Colloid built on the TPP path (`colloid-skx.patch`) on Linux `v6.3`, evaluated in both baseline (`colloid-tpp`) and page-migration prefetching (`colloid-tpp-prefetch`) configurations.

## Contents

- `compile.sh` — Checks out `v6.3` in `./linux`, applies `colloid-skx.patch` + `colloid-tpp-mig-stats.patch`, merges `ubuntu_fixes.config`, sets `CONFIG_LOCALVERSION="-Colloid-TPP"`, and builds the kernel and helpers.
- `compile-prefetch.sh` — Adds `colloid-tpp-prefetch.patch`, sets `CONFIG_LOCALVERSION="-Colloid-TPP-Prefetch"`, and builds the prefetch-enabled kernel.
- `colloid-skx.patch` — Colloid kernel patch on Linux `v6.3`.
- `colloid-tpp-mig-stats.patch` — Adds migration wait/copy latency vmstat counters (`MIG_WAIT_*`, `MIG_COPY_NS`).
- `colloid-tpp-prefetch.patch` — Adds `/sys/kernel/mm/page_prefetch/` migration prefetching.
- `colloid-mon/`, `tierinit/`, `kswapdrst/` — Colloid monitoring module and tiering helpers.

## Build & Usage

```bash
# Recommended: build via manage_kernels.sh (auto-clones v6.3 if missing)
sudo ./baselines/scripts/manage_kernels.sh colloid-tpp build
sudo ./baselines/scripts/manage_kernels.sh colloid-tpp-prefetch build

# Compile only (no /boot or GRUB modification)
sudo ./baselines/scripts/manage_kernels.sh colloid-tpp-prefetch compile_only

# Switch GRUB default with target memmap
sudo ./baselines/scripts/manage_kernels.sh colloid-tpp-prefetch update_grub --memmap "memmap=43G!5G" --reboot
```

Expected `uname -r`: `6.3.0-Colloid-TPP` or `6.3.0-Colloid-TPP-Prefetch`. Helper module loading (`tierinit`, `kswapdrst`, `colloid-mon`) and `tier-prefetch-mon` are managed automatically by `workloads/scripts/setup_kernel.sh`.
