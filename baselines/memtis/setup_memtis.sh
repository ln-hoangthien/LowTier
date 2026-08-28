#!/bin/bash
# Build the Memtis baseline kernel: Linux v5.15.19 + memtis.patch.
# Expects a Linux git checkout at ./linux (clone it there first; not bundled).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
MEMTIS_DIR="${ROOT_DIR}/baselines/memtis"
PATCH_FILE="${MEMTIS_DIR}/memtis.patch"
BASE_CONFIG="${MEMTIS_DIR}/config"
KERNEL_DIR="${MEMTIS_DIR}/linux"
LOGF="${MEMTIS_DIR}/log"

[[ -d "$KERNEL_DIR" ]] || { echo "ERROR: kernel tree not found at $KERNEL_DIR"; exit 1; }

[[ -e "$PATCH_FILE" ]] || { echo "ERROR: patch not found: $PATCH_FILE"; exit 1; }

[[ -e "$BASE_CONFIG" ]] || { echo "ERROR: base config not found: $BASE_CONFIG"; exit 1; }

cd "$KERNEL_DIR"

echo "==> Discard all uncommitted local changes..."
git reset --hard HEAD
git clean -fd

echo "==> Checking out v5.15.19..."
git checkout v5.15.19
make clean

# Remove host-built fixdep binary to avoid glibc compatibility issues
rm -f tools/objtool/fixdep scripts/basic/fixdep

echo "Applying $(basename "$PATCH_FILE") ..."
if patch -p1 --dry-run < "$PATCH_FILE" >/dev/null 2>&1; then
    patch -p1 < "$PATCH_FILE"
else
    echo "  (already applied or failed dry-run, skipping)"
fi

# Copy base configuration to .config
echo "configuring (olddefconfig) ..."
cp "$BASE_CONFIG" .config

# ------------------------------------------------------------------------------
# Kernel Configuration Adjustments (scripts/config)
# ------------------------------------------------------------------------------
# 1. Kernel Naming & Certificate Key Fixes
scripts/config --set-str CONFIG_LOCALVERSION "-Memtis"
scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""
scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS ""

# 2. Core Memtis Configuration
scripts/config --enable CONFIG_INTEL_UNCORE_FREQ_CONTROL

# 3. Single-Socket NUMA Emulation Configs (managed in manage_kernels.sh; will remove in real 2-socket NUMA in the future)
if type configure_single_socket_numa >/dev/null 2>&1; then
    configure_single_socket_numa "$KERNEL_DIR"
fi

# ------------------------------------------------------------------------------
# Compile Kernel
# ------------------------------------------------------------------------------
make olddefconfig CC=gcc-11 HOSTCC=gcc-11 > "$LOGF" 2>&1
echo "make ..."
make -j "$(nproc)" CC=gcc-11 HOSTCC=gcc-11 > "$LOGF" 2>&1

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
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
