# Memtis (SOSP '23 — Linux v5.15.19)

Memtis PEBS-driven tiered-memory baseline on Linux `v5.15.19`, evaluated in both baseline (`memtis`) and page-migration prefetching (`memtis-prefetch`) configurations.

## Contents

- `setup_memtis.sh` — Checks out `v5.15.19` in `./linux`, applies `memtis.patch` + `memtis-mig-stats.patch`, sets `CONFIG_LOCALVERSION="-Memtis"`, and compiles the kernel.
- `setup_memtis-prefetch.sh` — Applies `memtis.patch`, `memtis-prefetch.patch`, and `memtis-mig-stats.patch`, sets `CONFIG_LOCALVERSION="-Memtis-Prefetch"`, and compiles the prefetch-enabled kernel.
- `memtis.patch` — Upstream Memtis (HTMM) kernel patch (`EXTRAVERSION = -htmm`).
- `memtis-mig-stats.patch` — Adds migration wait/copy latency vmstat counters (`MIG_WAIT_*`, `MIG_COPY_NS`).
- `memtis-prefetch.patch` — Adds `/sys/kernel/mm/page_prefetch/` migration prefetching.
- `config` — Base kernel `.config`.

## Build & Usage

```bash
# Recommended: build via manage_kernels.sh (auto-clones linux-stable v5.15.19 & uses Docker on GCC >= 12)
sudo ./baselines/scripts/manage_kernels.sh memtis build
sudo ./baselines/scripts/manage_kernels.sh memtis-prefetch build

# Compile only (no /boot or GRUB modification)
sudo ./baselines/scripts/manage_kernels.sh memtis-prefetch compile_only

# Switch GRUB default with target memmap
sudo ./baselines/scripts/manage_kernels.sh memtis-prefetch update_grub --memmap "memmap=44G!4G" --reboot
```

Expected `uname -r`: `5.15.19-htmm-Memtis+` or `5.15.19-htmm-Memtis-Prefetch+`. Cgroup quota (`memory.max_at_node0`), `htmm_mode`, `ksamplingd`, `tier-prefetch-mon`, and safe teardown are managed automatically by `workloads/scripts/setup_kernel.sh`.
