#!/bin/bash
# Build the Nomad-Noinline baseline kernel: Linux v5.13-rc6 + nomad.patch + nomad-noinline.patch.
# Expects a Linux git checkout at ./linux (clone it there first; not bundled).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
NOMAD_DIR="${ROOT_DIR}/baselines/nomad-noinline"
KERNEL_DIR="${NOMAD_DIR}/linux"
LOGF="${NOMAD_DIR}/log"
PATCHES=("${NOMAD_DIR}/nomad.patch" "${NOMAD_DIR}/nomad-noinline.patch")

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

# Remove host-built fixdep binary to avoid glibc compatibility issues
rm -f tools/objtool/fixdep scripts/basic/fixdep

for p in "${PATCHES[@]}"; do
    echo "Applying $(basename "$p") ..."
    if git apply --reverse --check "$p" >/dev/null 2>&1; then
        echo "  (already applied, skipping)"
    else
        git apply "$p"
    fi
done

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
scripts/config --set-str CONFIG_LOCALVERSION "-Nomad-Noinline"
scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""
scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS ""
scripts/config --disable CONFIG_DEBUG_INFO_BTF

# 2. Core Architecture Configuration
# - CONFIG_X86_5LEVEL (disabled): Enforces standard 4-level paging expected by Nomad patch
scripts/config --disable CONFIG_X86_5LEVEL

# 3. Single-Socket NUMA Emulation Configs (managed in manage_kernels.sh; will remove in real 2-socket NUMA in the future)
if type configure_single_socket_numa >/dev/null 2>&1; then
    configure_single_socket_numa "$KERNEL_DIR"
fi

# ------------------------------------------------------------------------------
# Compile Kernel and Nomad Module
# ------------------------------------------------------------------------------
make olddefconfig CC=gcc-11 HOSTCC=gcc-11 > "$LOGF" 2>&1
echo "make ..."
make -j "$(nproc)" CC=gcc-11 HOSTCC=gcc-11 > "$LOGF" 2>&1
make -C "$SCRIPT_DIR/nomad_module" KERNEL_SRC="$KERNEL_DIR" CC=gcc-11 HOSTCC=gcc-11 > "$LOGF" 2>&1

# ---------------------------------------------------------------------------
# Done
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
