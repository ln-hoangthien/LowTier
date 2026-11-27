# TPP (ASPLOS '23 — Linux v5.15)

Transparent Page Placement (TPP) tiered-memory baseline on Linux `v5.15`, evaluated in both baseline (`tpp`) and page-migration prefetching (`tpp-prefetch`) configurations.

## Contents

- `compile.sh` — Checks out `v5.15` in `./linux`, applies `tpp.patch` + `tpp-mig-stats.patch`, sets `CONFIG_LOCALVERSION="-TPP"`, and compiles the kernel and modules.
- `compile-prefetch.sh` — Applies `tpp.patch`, `tpp-prefetch.patch`, and `tpp-mig-stats.patch`, sets `CONFIG_LOCALVERSION="-TPP-Prefetch"`, and compiles the prefetch-enabled kernel.
- `tpp.patch` — Upstream TPP kernel patch.
- `tpp-mig-stats.patch` — Adds migration wait/copy latency vmstat counters (`MIG_WAIT_*`, `MIG_COPY_NS`).
- `tpp-prefetch.patch` — Adds `/sys/kernel/mm/page_prefetch/` migration prefetching.

## Build & Usage

```bash
# Recommended: build via manage_kernels.sh (auto-clones v5.15 & uses Docker on GCC >= 12)
sudo ./baselines/scripts/manage_kernels.sh tpp build
sudo ./baselines/scripts/manage_kernels.sh tpp-prefetch build

# Compile only (no /boot or GRUB modification)
sudo ./baselines/scripts/manage_kernels.sh tpp-prefetch compile_only

# Switch GRUB default with target memmap
sudo ./baselines/scripts/manage_kernels.sh tpp-prefetch update_grub --memmap "memmap=43G!5G" --reboot
```

Expected `uname -r`: `5.15.0-TPP` or `5.15.0-TPP-Prefetch`. Demotion/NUMA-balancing sysctls and `tier-prefetch-mon` are managed automatically by `workloads/scripts/setup_kernel.sh`.
