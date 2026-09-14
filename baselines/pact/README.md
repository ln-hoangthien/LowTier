# PACT (ASPLOS '26)

PACT: A Criticality-First Design for Tiered Memory.

PACT evaluates tiered memory placement by measuring Performance Degradation and Criticality (PAC) using hardware performance counters (PEBS and CHA uncore occupancy counters) and steering migrations to keep critical data in fast tier memory.

## Contents
- `compile.sh` - checks out clean vanilla Linux `v6.3` in `./linux`, applies Ubuntu compatibility overrides (`ubuntu_fixes.config`) and PACT config options (`CONFIG_INTEL_UNCORE_FREQ_CONTROL`, `CONFIG_KPROBES`, `CONFIG_KALLSYMS_ALL`), builds kernel, builds modules, and compiles the PACT runtime.
- `tierinit/` - tier-initialization kernel module that registers the slow tier (node 1) and configures demotion targets via kprobes without needing kernel patches.
- `kswapdrst/` - kswapd reset kernel module that prevents `kswapd` demotion stalls during sustained memory pressure.
- `src/` - userspace PACT daemon runtime (`pact`), which attaches to target workload processes by PID.

## Build & Management

Manage via the LowTier master kernel management script:

```bash
# Full build: auto-clones Linux v6.3, compiles kernel & modules, installs to /boot, updates GRUB
sudo ./baselines/scripts/manage_kernels.sh pact

# Compile only (no installation or GRUB change):
sudo ./baselines/scripts/manage_kernels.sh pact compile_only

# Switch default boot kernel in GRUB:
sudo ./baselines/scripts/manage_kernels.sh pact update_grub
```

Or manually using `compile.sh`:

```bash
cd baselines/pact
# clone linux v6.3 if not already present
git clone --depth=1 --branch v6.3 https://github.com/torvalds/linux.git linux
sudo ./compile.sh
```

## Running Workloads

After booting into `6.3.0-PACT`, load the required modules and run PACT:

```bash
sudo insmod baselines/pact/tierinit/tierinit.ko
sudo insmod baselines/pact/kswapdrst/kswapdrst.ko

# Run workload and attach PACT daemon
sudo ./baselines/pact/src/pact --workload <PID>
```
