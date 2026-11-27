# Baseline & Prefetch Kernels

Source build scripts, kernel patches, helper modules, and automated GRUB/kernel management for all tiered-memory baselines and their **`-prefetch`** counterparts.

Every baseline includes:
- **`*-mig-stats.patch`**: Adds migration wait/copy latency counters (`MIG_WAIT_COUNT`, `MIG_WAIT_US`, `MIG_WAIT_HUGE_COUNT`, `MIG_WAIT_HUGE_US`, `MIG_COPY_NS`) to `/proc/vmstat`.
- **`*-prefetch.patch`**: Adds in-kernel page-migration software prefetching controlled via `/sys/kernel/mm/page_prefetch/` (`enabled`, `adaptive`, `naive`, `hint`, `promote_distance`, `demote_distance`, `min_distance`, `max_distance`).

---

## Supported Kernel Matrix

| Baseline | Base Kernel | Baseline Target (`uname -r`) | Prefetch Target (`uname -r`) | Directory | Aux Modules / Daemons |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **AutoNUMA** | Linux 7.3 | `autonuma` (`7.3.0-AutoNUMA`) | `autonuma-prefetch` (`7.3.0-AutoNUMA-Prefetch`) | [`autonuma/`](autonuma/) | `tierinit/`, `tier-prefetch-mon` |
| **Memtis** | Linux 5.15.19 | `memtis` (`5.15.19-htmm-Memtis+`) | `memtis-prefetch` (`5.15.19-htmm-Memtis-Prefetch+`) | [`memtis/`](memtis/) | `tier-prefetch-mon` |
| **Nomad** | Linux 5.13-rc6 | `nomad` (`5.13.0-rc6-Nomad`) | `nomad-prefetch` (`5.13.0-rc6-Nomad-Prefetch`) | [`nomad/`](nomad/) | `nomad_module/`, `tier-prefetch-mon` |
| **Nomad-Alto** | Linux 5.13-rc6 | `nomad-alto` (`5.13.0-rc6-Nomad-Alto`) | `nomad-alto-prefetch` (`5.13.0-rc6-Nomad-Alto-Prefetch`) | [`nomad-alto/`](nomad-alto/) | `nomad_module/`, `tier-prefetch-mon` |
| **TPP** | Linux 5.15 | `tpp` (`5.15.0-TPP`) | `tpp-prefetch` (`5.15.0-TPP-Prefetch`) | [`tpp/`](tpp/) | `tier-prefetch-mon` |
| **Colloid-TPP** | Linux 6.3 | `colloid-tpp` (`6.3.0-Colloid-TPP`) | `colloid-tpp-prefetch` (`6.3.0-Colloid-TPP-Prefetch`) | [`colloid-tpp/`](colloid-tpp/) | `colloid-mon/`, `tierinit/`, `kswapdrst/`, `tier-prefetch-mon` |
| **Colloid-TPP-Alto** | Linux 6.3 | `colloid-tpp-alto` (`6.3.0-Colloid-TPP-Alto`) | `colloid-tpp-alto-prefetch` (`6.3.0-Colloid-TPP-Alto-Prefetch`) | [`colloid-tpp-alto/`](colloid-tpp-alto/) | `colloid-mon/`, `tierinit/`, `kswapdrst/`, `tier-prefetch-mon` |
| **PACT** | Linux 6.3 | `pact` (`6.3.0-PACT`) | `pact-prefetch` (`6.3.0-PACT-Prefetch`) | [`pact/`](pact/) | `tierinit/`, `kswapdrst/`, `src/` (`pact` daemon) |
| **HybridTier** | Linux 6.2 | `hybridtier` (`6.2.0-hybridtier+`) | `hybridtier-prefetch` (`6.2.0-Hybridtier-Prefetch`) | [`hybridtier/`](hybridtier/) | `tiering_runtime/`, `hook/`, `tier-prefetch-mon` |

Additional components:
- [`tier-prefetch-mon/`](tier-prefetch-mon/README.md): Standalone adaptive uncore-CHA latency monitor & prefetch distance pacing daemon.
- [`scripts/manage_kernels.sh`](scripts/manage_kernels.sh): Unified build, install, GRUB switching, cleanup, and RSS-to-`memmap` resolution tool.

---

## Kernel Management (`scripts/manage_kernels.sh`)

Automates shallow-cloning upstream kernel trees, applying patches, building inside Docker when required, installing to `/boot` & `/lib/modules`, configuring GRUB `memmap=` fast-tier limits, and cleaning up kernels/GRUB.

```bash
# Full build (clone if missing, compile, install, update GRUB)
sudo ./scripts/manage_kernels.sh autonuma-prefetch build
sudo ./scripts/manage_kernels.sh memtis-prefetch build --reboot

# Compile only (do not modify /boot or GRUB)
sudo ./scripts/manage_kernels.sh pact-prefetch compile_only

# Install from an already-compiled source tree and switch GRUB
sudo ./scripts/manage_kernels.sh nomad-prefetch install --benchmark gapbs_pr_kron --ratio 1:8 --reboot

# Switch GRUB default to an already-installed kernel with explicit or RSS-derived memmap
sudo ./scripts/manage_kernels.sh memtis update_grub --memmap "memmap=44G!4G" --reboot
sudo ./scripts/manage_kernels.sh tpp-prefetch update_grub --benchmark spec2026_820.cloverleaf_s --ratio 1:8 --reboot

# Inspect the computed memmap parameter for a (benchmark, ratio) pair
./scripts/manage_kernels.sh resolve_memmap spec2026_865.roms_s 1:8

# Clean kernel build/install artifacts and strip custom memmap/mem/numa/idle params from GRUB
sudo ./scripts/manage_kernels.sh memtis clean
sudo ./scripts/manage_kernels.sh clean_grub
```

---

## Prefetch Sysfs Interface (`/sys/kernel/mm/page_prefetch/`)

All `*-prefetch` kernels expose the same runtime control interface (configured automatically by `workloads/scripts/setup_kernel.sh`):

| File | Values | Description |
| :--- | :--- | :--- |
| `enabled` | `0` / `1` | Master enable toggle for migration prefetching |
| `naive` | `0` / `1` | `0` = Deep-tune (two-wave pipelined copy + cross-folio lookahead); `1` = Naive fixed-ahead prefetch |
| `adaptive` | `0` / `1` | `0` = Static lookahead distance; `1` = Dynamic distance updated by `tier-prefetch-mon` / PACT |
| `hint` | `0..3` | Prefetch hint instruction: `0` = NTA, `1` = L3 (`T2`), `2` = L2 (`T1`), `3` = L1 (`T0`) |
| `promote_distance` | `0..64` | Cache-line lookahead distance for promotions (Slow → Fast) |
| `demote_distance` | `0..64` | Cache-line lookahead distance for demotions (Fast → Slow) |
| `min_distance` / `max_distance` | `0..64` | Clamp bounds used in adaptive mode |

---

## Docker Compilation & Verification

When compiling older baseline kernels (e.g., Linux 5.13 / 5.15) on hosts with `GCC >= 12`, build scripts automatically compile inside an `ubuntu:22.04` Docker container to avoid compiler/glibc incompatibilities.

```bash
uname -r                                            # Verify active kernel
cat /proc/cmdline                                   # Verify active memmap= parameter
ls /sys/kernel/mm/page_prefetch/                    # Verify prefetch sysfs (on *-prefetch kernels)
grep -E "GRUB_DEFAULT|GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub
```
