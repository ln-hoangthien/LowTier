# Baseline Kernels

Source setup scripts, patches, and automated kernel management for baseline tiered memory systems in **LowTier** (Memtis and Nomad).

## Directory Structure & Baselines

| Baseline | Kernel Base | Target `uname -r` | Directory | Description |
| :--- | :--- | :--- | :--- | :--- |
| **Memtis** | Linux 5.15.19 | `5.15.19-Memtis` | [`memtis/`](memtis/) | PEBS-driven tiering (SOSP'23) |
| **Nomad** | Linux 5.13-rc6 | `5.13.0-rc6-Nomad` | [`nomad/`](nomad/) | Non-exclusive memory tiering (OSDI'24) |
| **TPP** | Linux 5.15.0 | `5.15.0-TPP` | [`tpp/`](tpp/) | Transparent Page Placement (ASPLOS'23) |
| **Colloid-tpp** | Linux 6.3.0 | `6.3.0-Colloid-TPP` | [`colloid-tpp/`](colloid-tpp/) | Colloid on TPP path (SOSP'24) |
| **PACT** | Linux 6.3.0 | `6.3.0-PACT` | [`pact/`](pact/) | Criticality-first tiered memory (ASPLOS'26) |
| **HybridTier** | Linux 6.2.0 | `6.2.0-hybridtier+` | [`hybridtier/`](hybridtier/) | Adaptive CXL tiering system (ASPLOS'25) |
| **Scripts** | — | — | [`scripts/`](scripts/) | Master management script `manage_kernels.sh` |

## Usage (`scripts/manage_kernels.sh`)

Automates cloning kernel sources, applying patches, compiling, installing, and updating GRUB default boot entries. Requires `sudo`.

```bash
# Compile, install kernel & set GRUB default
sudo ./scripts/manage_kernels.sh memtis
sudo ./scripts/manage_kernels.sh nomad
sudo ./scripts/manage_kernels.sh all

# Switch GRUB default boot entry without compiling
sudo ./scripts/manage_kernels.sh memtis update_grub
sudo ./scripts/manage_kernels.sh nomad update_grub

# Auto-reboot after task completion
sudo ./scripts/manage_kernels.sh memtis --reboot
```

## Docker Compilation

If host `GCC >= 12`, build scripts (`setup_memtis.sh` and `compile.sh`) automatically compile kernels inside an `ubuntu:22.04` Docker container (`docker run ...`). This prevents toolchain and `glibc` incompatibilities when compiling older kernels (Linux 5.13 / 5.15) on modern host Linux distributions. Ensure Docker daemon is running and accessible to `sudo`.

## Verification

```bash
uname -r                              # Verify active kernel (5.15.19-Memtis or 5.13.0-rc6-Nomad)
grep GRUB_DEFAULT /etc/default/grub   # Verify default GRUB boot target
```
