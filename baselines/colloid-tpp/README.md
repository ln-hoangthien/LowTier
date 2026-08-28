# Colloid (SOSP '24)

Colloid tiering baseline. As noted in the parent
[README](../README.md), "Colloid" in this work refers to **Colloid-tpp**
(Colloid built on the TPP path), though the Colloid paper itself uses NBT
(NUMA-Balancing-Tiering) in Linux v6.3.

## Contents
- `colloid-skx.patch`, `colloid-skx-alto.patch` - kernel patches applied on
  top of Linux `v6.3` (Skylake-X target).
- `compile.sh` - checks out `v6.3` in a sibling `linux/` git tree, applies
  both patches, builds, installs modules, runs `make install` and
  `update-grub`.
- `colloid-mon/` - Colloid monitoring daemon.
- `tierinit/` - tier-initialization helper (CPU on/offline).
- `kswapdrst/` - kswapd reset helper.

## Build
`compile.sh` expects a Linux git checkout in `./linux` (not bundled). Clone it
first, then build (kernel install + `update-grub` need root):

```bash
cd colloid-tpp
git clone https://github.com/torvalds/linux.git linux   # v6.3 is a mainline tag
sudo ./compile.sh
```

The script runs: `git checkout v6.3` → `git apply colloid-skx.patch` →
`git apply colloid-skx-alto.patch` → `make olddefconfig` → `make -j` →
`make modules_install` → `make install` → `update-grub`.

Build the helper tools (`colloid-mon/`, `tierinit/`, `kswapdrst/`) with the
`make` target in each subdirectory; see their own READMEs.

## Running a workload
Kernel + helpers only; no Colloid-specific top-level run wrapper is shipped.
Boot into the patched kernel, start the monitor/helpers, and drive a workload
with your own launcher.
