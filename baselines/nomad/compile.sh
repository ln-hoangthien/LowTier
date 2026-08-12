#!/bin/bash
# Build the Nomad baseline kernel: Linux 5.13-rc6 + nomad.patch + nomad-alto.patch.
# Expects a Linux git checkout at ./linux (clone it there first; not bundled).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
NOMAD_DIR="${ROOT_DIR}/baselines/nomad"
KERNEL_DIR="${NOMAD_DIR}/linux"
LOGF="${NOMAD_DIR}/log"
PATCHES=("${NOMAD_DIR}/nomad.patch")

[[ -d "$KERNEL_DIR" ]] || { echo "ERROR: kernel tree not found at $KERNEL_DIR"; exit 1; }

for p in "${PATCHES[@]}"; do
    [[ -e "$p" ]] || { echo "ERROR: patch not found: $p"; exit 1; }
done

cd "$KERNEL_DIR"

echo "==> Discard all uncommitted local changes..."
git reset --hard HEAD
git clean -fd

echo "==> Checking out v5.13-rc6..."
git checkout v5.13-rc6
make clean

# When you run make inside Docker, the container has an older glibc that doesn't support GLIBC_2.34, so the host-built fixdep binary fails to execute.
rm -f tools/objtool/fixdep scripts/basic/fixdep

for p in "${PATCHES[@]}"; do
    echo "Applying $(basename "$p") ..."
    git apply "$p"
done

# Base the config on the running kernel, then resolve new symbols
# non-interactively. (Do NOT pipe `yes` into `make oldconfig`: under
# `set -o pipefail`, `yes` dies with SIGPIPE and aborts the build.)
echo "configuring (olddefconfig) ... "
if [[ -f "/boot/config-$(uname -r)" ]]; then
    cp "/boot/config-$(uname -r)" .config
elif [[ -f "../host.config" ]]; then
    echo "Using host config from ../host.config"
    cp "../host.config" .config
fi

# ------------------------------------------------------------------------------
# Kernel Configuration Adjustments (scripts/config)
# Adjust kernel configuration parameters for build compatibility, booting,
# and core Nomad NUMA-based tiered memory functionality.
# ------------------------------------------------------------------------------

# 1. Kernel Naming & Certificate Key Fixes
# - CONFIG_LOCALVERSION: Appends '-Nomad' suffix to kernel version (e.g. 5.13.0-rc6-Nomad)
# - CONFIG_SYSTEM_*_KEYS: Empties distro build certificate paths copied from Ubuntu /boot config
#   to prevent compilation failures caused by missing Canonical/Ubuntu signing keys
scripts/config --set-str CONFIG_LOCALVERSION "-Nomad"
scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""
scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS ""

# 2. Core Nomad Tiered Memory & Architecture Requirements
# - CONFIG_SMP: Enables Symmetric Multiprocessing across CPU cores
# - CONFIG_NUMA: Enables Non-Uniform Memory Access architecture support for multi-tier memory
# - CONFIG_NUMA_BALANCING: Enables kernel NUMA page balancing and migration mechanisms
# - CONFIG_MEMCG: Enables Memory Control Groups accounting for cgroup-level page tracking
# - CONFIG_X86_5LEVEL (disabled): Enforces standard 4-level paging expected by Nomad patch
scripts/config --enable SMP             # Will remove it in real NUMA with 2-socket.
scripts/config --enable NUMA            # Will remove it in real NUMA with 2-socket.
scripts/config --enable NUMA_BALANCING  # Will remove it in real NUMA with 2-socket.
scripts/config --enable MEMCG           # Will remove it in real NUMA with 2-socket.
scripts/config --disable CONFIG_X86_5LEVEL

# 3. Bootloader & Driver Support
# - CONFIG_MODULES: Enables loadable kernel module support for device drivers
# - CONFIG_BLK_DEV_INITRD & CONFIG_RD_GZIP: Enables Initial RAM Disk (initrd) support for Ubuntu bootloader
# scripts/config --enable MODULES # Is turned my default
# scripts/config --enable BLK_DEV_INITRD
# scripts/config --enable RD_GZIP

# 4. Toolchain Build Compatibility
# - CONFIG_DEBUG_INFO_BTF (disabled): Bypasses BPF Type Format debug generation to prevent
#   'pahole' toolchain version mismatch build failures during vmlinux linking
scripts/config --disable DEBUG_INFO_BTF

# 5. Hardware Emulation for Single-Socket Testing
# - CONFIG_NUMA_EMU (enabled): Enables fake NUMA node emulation ('numa=fake=X') for testing
#   tiered memory policies on single-socket test machines without physical NUMA hardware
scripts/config --enable NUMA_EMU # Will remove it in real NUMA with 2-socket.

GCC_MAJOR=$(gcc -dumpversion | cut -d. -f1)
eval make olddefconfig > "$LOGF" 2>&1
echo "make ..."
if [ "$GCC_MAJOR" -ge 12 ]; then
    echo "Using Docker for compilation (GCC $GCC_MAJOR >= 12)..."
    DOCKER_CMD="
        DEBIAN_FRONTEND=noninteractive apt-get update && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            build-essential bc bison flex libelf-dev libssl-dev libncurses-dev \
            libcap-dev zlib1g-dev pkg-config dwarves openssl xz-utils cpio zstd || true && \
        make olddefconfig && \
        make -j\$(nproc) && \
        make -C /usr/src/nomad/nomad_module KERNEL_SRC=/usr/src/nomad/linux
    "
    docker run --rm -v "$SCRIPT_DIR":/usr/src/nomad -w /usr/src/nomad/linux ubuntu:22.04 bash -c "$DOCKER_CMD" >> "$LOGF" 2>&1
else
    eval make -j "$(nproc)" >> "$LOGF" 2>&1
    make -C "$SCRIPT_DIR/nomad_module" KERNEL_SRC="$KERNEL_DIR" >> "$LOGF" 2>&1
fi

# ---------------------------------------------------------------------------
# 5. Done
# ---------------------------------------------------------------------------
echo ""
echo "==> Build complete."
echo "    Build log     : $LOGF"
echo "    Kernel image  : $KERNEL_DIR/arch/x86/boot/bzImage"
echo "    Nomad module  : $SCRIPT_DIR/nomad_module/async_promote.ko"
echo "    Kernel version: $(make kernelrelease 2>/dev/null)"
echo ""
echo "    To install (requires root):"
echo "      sudo make -C $KERNEL_DIR modules_install"
echo "      sudo make -C $KERNEL_DIR install"
echo "      sudo update-grub"
