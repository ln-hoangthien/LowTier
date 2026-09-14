#!/bin/bash
# ==============================================================================
# Build script for PACT baseline kernel: Linux v6.3 + modules & runtime
# Location: ~/thienle/LowTier/baselines/pact/compile.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
PACT_DIR="${ROOT_DIR}/baselines/pact"
KERNEL_DIR="${PACT_DIR}/linux"
LOGF="${PACT_DIR}/log"
UBUNTU_FIXES_CONFIG="${UBUNTU_FIXES_CONFIG:-${ROOT_DIR}/baselines/scripts/ubuntu_fixes.config}"

[[ -d "$KERNEL_DIR" ]] || { echo "ERROR: kernel tree not found at $KERNEL_DIR"; exit 1; }
[[ -f "$UBUNTU_FIXES_CONFIG" ]] || { echo "ERROR: ubuntu_fixes.config not found at $UBUNTU_FIXES_CONFIG"; exit 1; }

cd "$KERNEL_DIR"

echo "==> Discard all uncommitted local changes..."
git reset --hard HEAD
git clean -fd

echo "==> Ensuring clean Linux v6.3 is checked out..."
git checkout v6.3
make clean

# Remove host-built fixdep binary to avoid glibc compatibility issues
rm -f tools/objtool/fixdep scripts/basic/fixdep

# Copy configuration from generic kernel to .config
echo "configuring (olddefconfig) ..."
GENERIC_CONFIG=$(ls /boot/config-*-generic 2>/dev/null | sort -V | tail -n 1)
if [[ -n "$GENERIC_CONFIG" && -f "$GENERIC_CONFIG" ]]; then
    echo "Using official distro generic config: $GENERIC_CONFIG"
    cp "$GENERIC_CONFIG" .config
else
    echo "Error: No official distro generic config (/boot/config-*-generic) found."
    exit 1
fi

# ------------------------------------------------------------------------------
# Kernel Configuration Adjustments (scripts/config & merge_config.sh)
# ------------------------------------------------------------------------------
# 1. Kernel Naming & Certificate Key Fixes
scripts/config --set-str CONFIG_LOCALVERSION "-PACT"
scripts/config --disable CONFIG_LOCALVERSION_AUTO
scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""
scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS ""

# 2. Apply Ubuntu Boot Fixes & Safety Nets
echo "Applying Ubuntu fixes configuration: $UBUNTU_FIXES_CONFIG"
./scripts/kconfig/merge_config.sh -m .config "$UBUNTU_FIXES_CONFIG"

# 3. Enable PACT specific requirements:
#    - CONFIG_INTEL_UNCORE_FREQ_CONTROL: uncore freq sysfs
#    - CONFIG_KPROBES, CONFIG_KALLSYMS_ALL: required by tierinit to resolve mm/memory-tiers symbols
#    - CONFIG_MODULES, CONFIG_MODULE_UNLOAD: load/unload tierinit & kswapdrst modules
scripts/config --enable CONFIG_INTEL_UNCORE_FREQ_CONTROL
scripts/config --enable CONFIG_KPROBES
scripts/config --enable CONFIG_KALLSYMS_ALL
scripts/config --enable CONFIG_MODULES
scripts/config --enable CONFIG_MODULE_UNLOAD

# 4. Single-Socket NUMA Emulation Configs (managed in manage_kernels.sh)
if type configure_single_socket_numa >/dev/null 2>&1; then
    configure_single_socket_numa "$KERNEL_DIR"
fi

# ------------------------------------------------------------------------------
# Compile Kernel
# ------------------------------------------------------------------------------
make olddefconfig CC=gcc-11 HOSTCC=gcc-11 > "$LOGF" 2>&1
echo "make kernel and modules..."
make -j "$(nproc)" CC=gcc-11 HOSTCC=gcc-11 >> "$LOGF" 2>&1

# ------------------------------------------------------------------------------
# Build Out-of-Tree Modules & Userspace Runtime
# ------------------------------------------------------------------------------
echo "Building PACT out-of-tree modules (tierinit.ko, kswapdrst.ko)..."
make -C "$KERNEL_DIR" M="${PACT_DIR}/tierinit" modules >> "$LOGF" 2>&1 || true
make -C "$KERNEL_DIR" M="${PACT_DIR}/kswapdrst" modules >> "$LOGF" 2>&1 || true

if [ -d "${PACT_DIR}/src" ]; then
    echo "Building PACT runtime (src/pact)..."
    make -C "${PACT_DIR}/src" >> "$LOGF" 2>&1 || true
fi

# ------------------------------------------------------------------------------
# Done
# ------------------------------------------------------------------------------
echo ""
echo "==> Build complete."
echo "    Build log     : $LOGF"
echo "    Kernel image  : $KERNEL_DIR/arch/x86/boot/bzImage"
echo "    Kernel version: $(make kernelrelease 2>/dev/null)"
echo ""
echo "    To install (requires root):"
echo "      sudo make -C $KERNEL_DIR modules_install"
echo "      sudo make -C $KERNEL_DIR install"
echo "      sudo update-grub"
