# AutoNUMA (Upstream Linux v7.3)

Upstream Linux v7.3 AutoNUMA with native tiered-memory balancing and demotion, evaluated in both baseline (`autonuma`) and page-migration prefetching (`autonuma-prefetch`) configurations.

## Contents

- `compile.sh` — Checks out `v7.3` in `./linux`, applies `autonuma-mig-stats.patch`, configures `CONFIG_LOCALVERSION="-AutoNUMA"`, and compiles the kernel and modules.
- `compile-prefetch.sh` — Applies `autonuma-prefetch.patch` and `autonuma-mig-stats.patch`, configures `CONFIG_LOCALVERSION="-AutoNUMA-Prefetch"`, and compiles the prefetch-enabled kernel.
- `autonuma-mig-stats.patch` — Adds migration wait/copy latency vmstat counters (`MIG_WAIT_*`, `MIG_COPY_NS`).
- `autonuma-prefetch.patch` — Adds `/sys/kernel/mm/page_prefetch/` migration prefetching.
- `tierinit/` — Out-of-tree kernel module that places Node 1 into a slower emulated memory tier (`FARMEM_ADISTANCE`) and rebuilds demotion targets via kprobes-resolved `mm/memory-tiers.c` symbols.

## Build & Usage

```bash
# Recommended: build via manage_kernels.sh (auto-clones v7.3 if missing)
sudo ./baselines/scripts/manage_kernels.sh autonuma build
sudo ./baselines/scripts/manage_kernels.sh autonuma-prefetch build

# Compile only (no /boot or GRUB modification)
sudo ./baselines/scripts/manage_kernels.sh autonuma-prefetch compile_only

# Switch GRUB default with target memmap
sudo ./baselines/scripts/manage_kernels.sh autonuma-prefetch update_grub --memmap "memmap=43G!5G" --reboot
```

Expected `uname -r`: `7.3.0-AutoNUMA` or `7.3.0-AutoNUMA-Prefetch`. Runtime module loading (`tierinit.ko`) and `tier-prefetch-mon` are managed automatically by `workloads/scripts/setup_kernel.sh`.
