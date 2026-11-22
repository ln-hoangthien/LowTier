# AutoNUMA (Upstream Linux v7.3)

Upstream Linux AutoNUMA with tiered memory balancing, serving as the modernized kernel baseline (replacing distro generic kernel).

## Background
In Linux v7.3, upstream AutoNUMA integrates tiered memory placement and demotion natively (including TPP semantics). It compiles directly from the upstream kernel tree without requiring out-of-tree feature patches.

- **Repository**: `https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git`
- **Branch / Tag**: `v7.3`
- **Kernel Localversion**: `-AutoNUMA`

## Contents
- `compile.sh` - Checks out `v7.3` in `./linux`, applies system configurations (`CONFIG_LOCALVERSION="-AutoNUMA"`, cert fixes, single-socket NUMA emulation), and compiles the kernel and modules.

## Build
```bash
# Automated via manage_kernels:
./baselines/scripts/manage_kernels.sh autonuma compile_only

# Or manually:
cd baselines/autonuma
git clone https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git linux
./compile.sh
```
