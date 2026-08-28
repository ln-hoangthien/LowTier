#!/bin/bash
# Build the TPP baseline kernel: Linux v5.15 + tpp.patch.
# Expects a Linux git checkout at ./linux (clone it there first; not bundled).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
TPP_DIR="${ROOT_DIR}/baselines/tpp"
KERNEL_DIR="${TPP_DIR}/linux"
PATCH="${TPP_DIR}/tpp.patch"
LOGF="${TPP_DIR}/log"

[[ -d "$KERNEL_DIR" ]] || { echo "ERROR: kernel tree not found at $KERNEL_DIR"; exit 1; }

[[ -e "$PATCH" ]] || { echo "ERROR: patch not found: $PATCH"; exit 1; }

cd "$KERNEL_DIR"

echo "==> Discard all uncommitted local changes..."
git reset --hard HEAD
git clean -fd

echo "==> Checking out v5.15..."
git checkout v5.15
make clean

# Remove host-built fixdep binary to avoid glibc compatibility issues
rm -f tools/objtool/fixdep scripts/basic/fixdep

echo "Applying $(basename "$PATCH") ..."
if git apply --reverse --check "$PATCH" >/dev/null 2>&1; then
    echo "  (already applied, skipping)"
else
    git apply "$PATCH"
fi

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
# Kernel Configuration Adjustments (scripts/config)
# ------------------------------------------------------------------------------
# 1. Kernel Naming & Certificate Key Fixes
scripts/config --set-str CONFIG_LOCALVERSION "-TPP"
scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""
scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS ""
scripts/config --disable CONFIG_DEBUG_INFO_BTF

# 2. Single-Socket NUMA Emulation Configs (managed in manage_kernels.sh; will remove in real 2-socket NUMA in the future)
if type configure_single_socket_numa >/dev/null 2>&1; then
    configure_single_socket_numa "$KERNEL_DIR"
fi

# ------------------------------------------------------------------------------
# Compile Kernel
# ------------------------------------------------------------------------------
make olddefconfig CC=gcc-11 HOSTCC=gcc-11 > "$LOGF" 2>&1
echo "make ..."
make -j "$(nproc)" CC=gcc-11 HOSTCC=gcc-11 > "$LOGF" 2>&1

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