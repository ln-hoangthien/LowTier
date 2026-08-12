# Baseline Kernels

Source setup scripts, patches, and automated kernel management for baseline tiered memory systems in **LowTier** (Memtis and Nomad).

## Directory Structure & Baselines

| Baseline | Kernel Base | Target `uname -r` | Directory | Description |
| :--- | :--- | :--- | :--- | :--- |
| **Memtis** | Linux 5.15.19 | `5.15.19-Memtis` | [`memtis/`](memtis/) | PEBS-driven tiering (SOSP'23) |
| **Nomad** | Linux 5.13-rc6 | `5.13.0-rc6-Nomad` | [`nomad/`](nomad/) | Non-exclusive memory tiering (OSDI'24) |
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
