# Nomad (OSDI '24 — Linux v5.13-rc6)

Nomad non-exclusive tiered-memory baseline on Linux `v5.13-rc6` with its `async_promote` kernel module, evaluated in both baseline (`nomad`) and page-migration prefetching (`nomad-prefetch`) configurations.

## Contents

- `compile.sh` — Checks out `v5.13-rc6` in `./linux`, applies `nomad.patch` + `nomad-mig-stats.patch`, sets `CONFIG_LOCALVERSION="-Nomad"`, and compiles the kernel and `nomad_module`.
- `compile-prefetch.sh` — Applies `nomad.patch`, `nomad-prefetch.patch`, and `nomad-mig-stats.patch`, sets `CONFIG_LOCALVERSION="-Nomad-Prefetch"`, and compiles the prefetch-enabled kernel and module.
- `nomad.patch` — Upstream Nomad kernel patch.
- `nomad-mig-stats.patch` — Adds migration wait/copy latency vmstat counters (`MIG_WAIT_*`, `MIG_COPY_NS`).
- `nomad-prefetch.patch` — Adds `/sys/kernel/mm/page_prefetch/` migration prefetching.
- `nomad_module/` — Out-of-tree `async_promote` kernel module (built against `./linux`).

## Build & Usage

```bash
# Recommended: build via manage_kernels.sh (auto-clones v5.13-rc6 & uses Docker on GCC >= 12)
sudo ./baselines/scripts/manage_kernels.sh nomad build
sudo ./baselines/scripts/manage_kernels.sh nomad-prefetch build

# Compile only (no /boot or GRUB modification)
sudo ./baselines/scripts/manage_kernels.sh nomad-prefetch compile_only

# Switch GRUB default with target memmap
sudo ./baselines/scripts/manage_kernels.sh nomad-prefetch update_grub --memmap "memmap=43G!5G" --reboot
```

Expected `uname -r`: `5.13.0-rc6-Nomad` or `5.13.0-rc6-Nomad-Prefetch`. Loading `async_promote.ko`, CPU hotplug demotion-target workaround (`setup_machine.sh`), and `tier-prefetch-mon` are managed automatically by `workloads/scripts/setup_kernel.sh`.
