#!/bin/bash
# ==============================================================================
# Kernel Compile, Management & GRUB Setup Script
# Location: ~/thienle/LowTier/baselines/scripts/manage_kernels.sh
# ==============================================================================
# Description:
#   Clones kernel source repositories automatically if missing, compiles baseline
#   kernels (Memtis using setup_memtis.sh or Nomad using compile.sh), installs
#   modules and kernel images, updates GRUB, and sets default boot entry in GRUB.
#
# Usage:
#   sudo ./manage_kernels.sh [memtis|nomad|all] [update_grub] [--reboot]
# ==============================================================================

# Enable strict mode:
# -e : Exit immediately if a command exits with a non-zero status.
# -u : Treat unset variables as an error when expanding.
# -o pipefail : Return status of the last command to fail in a pipeline.
set -euo pipefail

# Directory paths initialization
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
BASELINES_DIR="${ROOT_DIR}/baselines"
MEMTIS_DIR="${BASELINES_DIR}/memtis"
NOMAD_DIR="${BASELINES_DIR}/nomad"
NOMAD_NOINLINE_DIR="${BASELINES_DIR}/nomad-noinline"
NOMAD_ALTO_DIR="${BASELINES_DIR}/nomad-alto"
NOMAD_ALTO_NOINLINE_DIR="${BASELINES_DIR}/nomad-alto-noinline"
TPP_DIR="${BASELINES_DIR}/tpp"
COLLOID_TPP_DIR="${BASELINES_DIR}/colloid-tpp"
COLLOID_TPP_ALTO_DIR="${BASELINES_DIR}/colloid-tpp-alto"

# Formatting color definitions for terminal output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# Function: show_help
# Description: Displays command line usage information, available actions,
#              supported targets, optional flags, and usage examples.
# ------------------------------------------------------------------------------
show_help() {
    echo "Usage: sudo $0 [memtis|nomad|nomad-noinline|nomad-alto|tpp|colloid-tpp|colloid-tpp-alto|all] [build|compile_only|update_grub|clean|purge] [--reboot|-r] [--help|-h]"
    echo "       sudo $0 clean_grub"
    echo ""
    echo "Actions:"
    echo "  build (default) Full build: auto-clone repo, compile, install kernel/modules, update GRUB & set default"
    echo "  compile_only    Compile kernel & modules ONLY (no installation to /boot or /lib/modules, no GRUB changes)"
    echo "  update_grub     Only set GRUB default boot entry (without compiling or installing)"
    echo "  clean_grub      Clean all duplicate .old backup kernel images from /boot and update GRUB"
    echo "  clean / purge   Uninstall specified kernel target (or all) from /boot & /lib/modules, delete <dir>/linux source tree, and update GRUB"
    echo ""
    echo "Targets:"
    echo "  memtis            Memtis kernel baseline (Linux 5.15.19-Memtis)"
    echo "  nomad             Nomad kernel baseline (Linux 5.13.0-rc6-Nomad)"
    echo "  nomad-noinline    Nomad kernel baseline with noinline (Linux 5.13.0-rc6-Nomad-Noinline)"
    echo "  nomad-alto        Nomad kernel baseline with alto (Linux 5.13.0-rc6-Nomad-Alto)"
    echo "  tpp               TPP kernel baseline (Linux 5.15.0-TPP)"
    echo "  colloid-tpp       Colloid-tpp kernel baseline (Linux 6.3.0-Colloid-TPP)"
    echo "  colloid-tpp-alto  Colloid-tpp kernel baseline with alto (Linux 6.3.0-Colloid-TPP-Alto)"
    echo "  all               All baseline kernels"
    echo ""
    echo "Options:"
    echo "  -r, --reboot    Automatically reboot system after completing task"
    echo "  -h, --help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  sudo $0 clean_grub          # Remove all duplicate .old kernel entries and clean GRUB"
    echo "  sudo $0 colloid-tpp clean   # Uninstall Colloid-tpp kernel and update GRUB"
    echo "  sudo $0 all clean           # Purge all custom baseline kernels and restore distro GRUB"
    echo "  sudo $0 memtis              # Full build & install Memtis kernel & set GRUB default"
    echo "  sudo $0 nomad compile_only  # Compile Nomad kernel ONLY (without installing or changing GRUB)"
    echo "  sudo $0 tpp update_grub     # Only set GRUB default to TPP"
    echo "  sudo $0 colloid-tpp         # Full build & install Colloid-tpp kernel & set GRUB default"
}

# Allow help to be displayed without root
for arg in "$@"; do
    if [[ "$arg" == "--help" || "$arg" == "-h" || "$arg" == "help" ]]; then
        show_help
        exit 0
    fi
done

if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}Notice: Root privileges are required to install kernels and update GRUB.${NC}"
    echo -e "${YELLOW}Re-running script with sudo...${NC}"
    exec sudo bash "$0" "$@"
fi

# ------------------------------------------------------------------------------
# Function: clone_memtis
# Description: Checks if the Memtis kernel source directory exists.
#              If missing, shallow-clones Linux v5.15.19 repository into place.
# ------------------------------------------------------------------------------
clone_memtis() {
    local kdir="${MEMTIS_DIR}/linux"
    if [ ! -d "$kdir" ]; then
        echo -e "${CYAN}Linux folder missing at ${kdir}. Auto-cloning Memtis kernel tree (Linux v5.15.19)...${NC}"
        # Shallow clone specific branch to minimize download size
        git clone --depth=1 --branch v5.15.19 \
            https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$kdir"
    fi
}

# ------------------------------------------------------------------------------
# Function: clone_nomad
# Description: Checks if the Nomad kernel source directory exists.
#              If missing, shallow-clones Linux v5.13-rc6 repository into place.
# ------------------------------------------------------------------------------
clone_nomad() {
    local kdir="${NOMAD_DIR}/linux"
    if [ ! -d "$kdir" ]; then
        echo -e "${CYAN}Linux folder missing at ${kdir}. Auto-cloning Nomad kernel tree (Linux v5.13-rc6)...${NC}"
        # Shallow clone specific release candidate tag
        git clone --depth=1 --branch v5.13-rc6 \
            https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$kdir"
    fi
}

# ------------------------------------------------------------------------------
# Function: clone_nomad_noinline
# ------------------------------------------------------------------------------
clone_nomad_noinline() {
    local kdir="${NOMAD_NOINLINE_DIR}/linux"
    if [ ! -d "$kdir" ]; then
        echo -e "${CYAN}Linux folder missing at ${kdir}. Auto-cloning Nomad-Noinline kernel tree (Linux v5.13-rc6)...${NC}"
        git clone --depth=1 --branch v5.13-rc6 \
            https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$kdir"
    fi
}

# ------------------------------------------------------------------------------
# Function: clone_nomad_alto
# ------------------------------------------------------------------------------
clone_nomad_alto() {
    local kdir="${NOMAD_ALTO_DIR}/linux"
    if [ ! -d "$kdir" ]; then
        echo -e "${CYAN}Linux folder missing at ${kdir}. Auto-cloning Nomad-Alto kernel tree (Linux v5.13-rc6)...${NC}"
        git clone --depth=1 --branch v5.13-rc6 \
            https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$kdir"
    fi
}

# ------------------------------------------------------------------------------
# Function: clone_nomad_alto_noinline
# ------------------------------------------------------------------------------
clone_nomad_alto_noinline() {
    local kdir="${NOMAD_ALTO_NOINLINE_DIR}/linux"
    if [ ! -d "$kdir" ]; then
        echo -e "${CYAN}Linux folder missing at ${kdir}. Auto-cloning Nomad-Alto-Noinline kernel tree (Linux v5.13-rc6)...${NC}"
        git clone --depth=1 --branch v5.13-rc6 \
            https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$kdir"
    fi
}

# ------------------------------------------------------------------------------
# Function: clone_tpp
# Description: Checks if the TPP kernel source directory exists.
#              If missing, shallow-clones Linux v5.15 repository into place.
# ------------------------------------------------------------------------------
clone_tpp() {
    local kdir="${TPP_DIR}/linux"
    if [ ! -d "$kdir" ]; then
        echo -e "${CYAN}Linux folder missing at ${kdir}. Auto-cloning TPP kernel tree (Linux v5.15)...${NC}"
        git clone --depth=1 --branch v5.15 \
            https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$kdir"
    fi
}

# ------------------------------------------------------------------------------
# Function: clone_colloid_tpp
# Description: Checks if the Colloid-tpp kernel source directory exists.
#              If missing, shallow-clones Linux v6.3 repository into place.
# ------------------------------------------------------------------------------
clone_colloid_tpp() {
    local kdir="${COLLOID_TPP_DIR}/linux"
    if [ ! -d "$kdir" ]; then
        echo -e "${CYAN}Linux folder missing at ${kdir}. Auto-cloning Colloid-tpp kernel tree (Linux v6.3)...${NC}"
        git clone --depth=1 --branch v6.3 \
            https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$kdir"
    fi
}

# ------------------------------------------------------------------------------
# Function: clone_colloid_tpp_alto
# Description: Checks if the Colloid-tpp-alto kernel source directory exists.
#              If missing, shallow-clones Linux v6.3 repository into place.
# ------------------------------------------------------------------------------
clone_colloid_tpp_alto() {
    local kdir="${COLLOID_TPP_ALTO_DIR}/linux"
    if [ ! -d "$kdir" ]; then
        echo -e "${CYAN}Linux folder missing at ${kdir}. Auto-cloning Colloid-tpp-alto kernel tree (Linux v6.3)...${NC}"
        git clone --depth=1 --branch v6.3 \
            https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$kdir"
    fi
}

# ------------------------------------------------------------------------------
# Function: resolve_kernel_release
# Arguments:
#   $1 - target_name : Target identifier (e.g. memtis, nomad, tpp, colloid)
#   $2 - kdir        : Kernel source directory path
#   $3 - fallback    : Default kernel release string fallback
# Description: Resolves the exact kernel release string by inspecting source config,
#              searching /boot/vmlinuz-* for installed target kernels, or
#              falling back to default string.
# ------------------------------------------------------------------------------
resolve_kernel_release() {
    local target="$1"
    local kdir="$2"
    local fallback="$3"
    local krelease=""

    if [ -d "$kdir" ] && [ -f "$kdir/.config" ]; then
        krelease=$(make -s -C "$kdir" kernelrelease 2>/dev/null || true)
    fi

    # Normalize -dirty if /lib/modules exists without -dirty
    if [ -n "$krelease" ] && [ ! -d "/lib/modules/${krelease}" ] && [ -d "/lib/modules/${krelease%-dirty}" ]; then
        krelease="${krelease%-dirty}"
    fi

    if [ -z "$krelease" ] || [ ! -f "/boot/vmlinuz-${krelease}" ]; then
        local installed=""
        case "$target" in
            nomad)
                installed=$(ls /boot/vmlinuz-* 2>/dev/null | grep -i "nomad" | grep -iv "noinline" | grep -iv "alto" | head -n 1 | sed 's|/boot/vmlinuz-||' || true)
                ;;
            nomad-noinline)
                installed=$(ls /boot/vmlinuz-* 2>/dev/null | grep -i "noinline" | grep -iv "alto" | head -n 1 | sed 's|/boot/vmlinuz-||' || true)
                ;;
            nomad-alto)
                installed=$(ls /boot/vmlinuz-* 2>/dev/null | grep -i "nomad" | grep -i "alto" | grep -iv "noinline" | head -n 1 | sed 's|/boot/vmlinuz-||' || true)
                ;;
            nomad-alto-noinline)
                installed=$(ls /boot/vmlinuz-* 2>/dev/null | grep -i "nomad" | grep -i "alto" | grep -i "noinline" | head -n 1 | sed 's|/boot/vmlinuz-||' || true)
                ;;
            tpp)
                installed=$(ls /boot/vmlinuz-* 2>/dev/null | grep -i "tpp" | grep -iv "colloid" | head -n 1 | sed 's|/boot/vmlinuz-||' || true)
                ;;
            colloid|colloid-tpp)
                installed=$(ls /boot/vmlinuz-* 2>/dev/null | grep -i "colloid" | grep -iv "alto" | head -n 1 | sed 's|/boot/vmlinuz-||' || true)
                ;;
            colloid-tpp-alto|colloid-alto)
                installed=$(ls /boot/vmlinuz-* 2>/dev/null | grep -i "colloid" | grep -i "alto" | head -n 1 | sed 's|/boot/vmlinuz-||' || true)
                ;;
            generic|distro|default)
                installed=$(ls /boot/vmlinuz-*-generic 2>/dev/null | sort -V | tail -n 1 | sed 's|/boot/vmlinuz-||' || true)
                ;;
            *)
                installed=$(ls /boot/vmlinuz-* 2>/dev/null | grep -i "${target}" | head -n 1 | sed 's|/boot/vmlinuz-||' || true)
                ;;
        esac

        if [ -n "$installed" ]; then
            krelease="$installed"
        fi
    fi

    if [ -z "$krelease" ]; then
        krelease="$fallback"
    fi

    echo "$krelease"
}

# ------------------------------------------------------------------------------
# Function: configure_single_socket_numa
# Description: Applies kernel configuration parameters for single-socket NUMA emulation.
# Note: These options are enabled for single-socket NUMA emulation testing.
#       Will remove these settings when running on physical 2-socket NUMA hardware in the future.
# ------------------------------------------------------------------------------
configure_single_socket_numa() {
    local kdir="$1"
    if [ -d "$kdir" ] && [ -f "$kdir/scripts/config" ]; then
        echo -e "${CYAN:-}Applying single-socket NUMA kernel configurations...${NC:-}"
        (
            cd "$kdir"
            scripts/config --enable SMP             # Will remove it in real NUMA with 2-socket.
            scripts/config --enable NUMA            # Will remove it in real NUMA with 2-socket.
            scripts/config --enable NUMA_BALANCING  # Will remove it in real NUMA with 2-socket.
            scripts/config --enable MEMCG           # Will remove it in real NUMA with 2-socket.
            scripts/config --enable NUMA_EMU        # Will remove it in real NUMA with 2-socket.
        )
    fi
}
export -f configure_single_socket_numa

# ------------------------------------------------------------------------------
# Function: generate_initramfs
# Arguments:
#   $1 - krelease : Target kernel release string (e.g. 6.3.0-Colloid-TPP)
# Description: Generates an initramfs for the target kernel using standard
#              Ubuntu update-initramfs.
# ------------------------------------------------------------------------------
generate_initramfs() {
    local krelease="$1"
    echo -e "${CYAN}Updating initramfs for ${krelease}...${NC}"
    update-initramfs -u -k "${krelease}" || update-initramfs -c -k "${krelease}" || true
}

# ------------------------------------------------------------------------------
# Function: clean_current_kernel_state
# Description: Cleans runtime kernel state, unloads custom kernel modules,
#              terminates stale background profilers, resets memory caches,
#              and clears backup/stale GRUB entries without deleting any installed
#              kernel images (/boot/vmlinuz-*, /boot/initrd.img-*, /lib/modules/*).
# ------------------------------------------------------------------------------
clean_current_kernel_state() {
    echo -e "${CYAN}==> Cleaning current kernel runtime state and stale artifacts (preserving all kernel images)...${NC}"
    
    # 1. Unload any custom dynamically loaded kernel modules (e.g. Nomad async_promote)
    if lsmod 2>/dev/null | grep -q "async_promote"; then
        echo -e "${YELLOW}Unloading async_promote kernel module...${NC}"
        rmmod async_promote 2>/dev/null || true
    fi

    # 2. Terminate any lingering background profilers or monitors
    killall -9 perf bpftrace 2>/dev/null || true
    perf probe -q -d 'probe:*' 2>/dev/null || true

    # 3. Clean backup .old and .bak files from /boot (preserves all installed vmlinuz-* and initrd.img-*)
    rm -f /boot/vmlinuz-*.old /boot/initrd.img-*.old /boot/System.map-*.old /boot/config-*.old /boot/*.bak 2>/dev/null || true

    # 4. Flush dirty caches, dentries/inodes, and compact memory
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
    swapoff -a 2>/dev/null && swapon -a 2>/dev/null || true

    # 5. Reset NUMA balancing sysctls to clean defaults
    sysctl -w kernel.numa_balancing=1 2>/dev/null || true
    sysctl -w kernel.perf_event_max_sample_rate=100000 2>/dev/null || true
    echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    echo -e "${GREEN}==> Kernel runtime state cleaned successfully.${NC}"
}
export -f clean_current_kernel_state

# ------------------------------------------------------------------------------
# Function: set_grub_default
# Arguments:
#   $1 - krelease : Kernel release string (e.g. 5.15.19-htmm-Memtis)
#   $2 - name     : Human-readable target name (e.g. Memtis or Nomad)
# Description: Updates /etc/default/grub with the specified kernel boot entry,
#              creates a configuration backup, regenerates GRUB, verifies entry
#              against /boot/grub/grub.cfg, and sets default boot entry.
# ------------------------------------------------------------------------------
set_grub_default() {
    local krelease="$1"
    local name="$2"

    # Clean current kernel runtime state and stale artifacts before switching
    # clean_current_kernel_state

    echo -e "\n${CYAN}==> Updating GRUB configuration for ${name} (${krelease})...${NC}"

    # Backup original /etc/default/grub file if a backup does not already exist
    if [ ! -f /etc/default/grub.bak ]; then
        cp /etc/default/grub /etc/default/grub.bak
    fi

    # Temporary: Ensure mem limit (default: 20G, overridable via MEM_LIMIT) and numa=fake=2 parameters
    # Note: Remove this setting when running on a physical 2-socket machine.
    if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub; then
        # Strip any existing mem=... and numa=fake=... parameters to prevent duplicates/overlaps
        sed -i -E 's/\bmem=[0-9]+[kKmMgGtT]?[bB]?\b//g' /etc/default/grub
        sed -i -E 's/\bnuma=fake=[^ "]*//g' /etc/default/grub
        sed -i -E 's/([[:space:]]+)/ /g' /etc/default/grub
        sed -i -E 's/GRUB_CMDLINE_LINUX_DEFAULT="[[:space:]]*/GRUB_CMDLINE_LINUX_DEFAULT="/' /etc/default/grub
        sed -i -E 's/[[:space:]]*"$/"/' /etc/default/grub
        # Append target mem and numa=fake parameters cleanly
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 numa=fake=2\"|" /etc/default/grub
        sed -i -E 's/GRUB_CMDLINE_LINUX_DEFAULT="[[:space:]]+/GRUB_CMDLINE_LINUX_DEFAULT="/' /etc/default/grub
    else
        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash numa=fake=2\"" >> /etc/default/grub
    fi

    # Remove stale backup (.old) kernels so GRUB menu does not have duplicate entries
    rm -f /boot/vmlinuz-*.old /boot/initrd.img-*.old /boot/System.map-*.old /boot/config-*.old /boot/*.bak 2>/dev/null || true

    # Remove all other custom kernels from /boot and /lib/modules excluding generic and the target kernel
    for vmlinuz in /boot/vmlinuz-*; do
        [ ! -f "$vmlinuz" ] && continue
        local kver
        kver=$(basename "$vmlinuz" | sed 's/^vmlinuz-//')

        # 1. Always preserve official Ubuntu generic kernels
        if [[ "$kver" =~ generic ]]; then
            continue
        fi

        # 2. Preserve the target kernel being switched to
        if [ -n "$krelease" ] && [ "$krelease" != "generic" ]; then
            if [[ "$kver" == "$krelease" || "$kver" =~ $krelease || "$krelease" =~ $kver ]]; then
                continue
            fi
        fi

        # 3. Remove inactive custom kernel from /boot & /lib/modules
        echo -e "${YELLOW}Removing inactive custom kernel '${kver}' from /boot & /lib/modules...${NC}"
        rm -f "/boot/vmlinuz-${kver}"* "/boot/initrd.img-${kver}"* "/boot/System.map-${kver}"* "/boot/config-${kver}"* 2>/dev/null || true
        rm -rf "/lib/modules/${kver}" 2>/dev/null || true
    done

    # First run update-grub to ensure /boot/grub/grub.cfg contains all installed kernels
    update-grub

    # Inspect /boot/grub/grub.cfg to find the exact submenu and menuentry titles
    local grub_cfg="/boot/grub/grub.cfg"
    local submenu_title=""
    local menu_title=""
    local grub_entry=""

    if [ -f "$grub_cfg" ]; then
        submenu_title=$(grep -E "submenu ['\"]" "$grub_cfg" | head -n 1 | sed -E "s/.*submenu ['\"]([^'\"]+)['\"].*/\1/" || true)
        menu_title=$(grep -E "menuentry ['\"]" "$grub_cfg" | grep -v -i "recovery" | grep -E "Linux ${krelease}('|\"| |\$)" | head -n 1 | sed -E "s/.*menuentry ['\"]([^'\"]+)['\"].*/\1/" || true)
        if [ -z "$menu_title" ]; then
            menu_title=$(grep -E "menuentry ['\"]" "$grub_cfg" | grep -v -i "recovery" | grep -F "${krelease}" | head -n 1 | sed -E "s/.*menuentry ['\"]([^'\"]+)['\"].*/\1/" || true)
        fi
    fi

    if [ -n "$submenu_title" ] && [ -n "$menu_title" ]; then
        grub_entry="${submenu_title}>${menu_title}"
    elif [ -n "$menu_title" ]; then
        grub_entry="${menu_title}"
    elif [ -n "$submenu_title" ]; then
        grub_entry="${submenu_title}>Ubuntu, with Linux ${krelease}"
    else
        grub_entry="Advanced options for Ubuntu>Ubuntu, with Linux ${krelease}"
    fi

    echo -e "${CYAN}Setting GRUB default entry: '${grub_entry}'${NC}"
    sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${grub_entry}\"|" /etc/default/grub

    # Execute grub-set-default to update grubenv
    grub-set-default "${grub_entry}" 2>/dev/null || grub-set-default "${krelease}" 2>/dev/null || true

    echo -e "${GREEN}==> Successfully set default boot kernel to ${name} (${krelease}).${NC}"
}

# ------------------------------------------------------------------------------
# Function: set_memtis_default
# Description: Determines the exact kernel release string for Memtis from its
#              source directory or /boot, installs modules/kernel if required,
#              generates initramfs, and triggers GRUB setup.
# ------------------------------------------------------------------------------
set_memtis_default() {
    local kdir="${MEMTIS_DIR}/linux"
    local krelease
    krelease=$(resolve_kernel_release "memtis" "$kdir" "5.15.19-Memtis")

    if [ -d "$kdir" ] && [ -f "$kdir/.config" ]; then
        echo -e "${CYAN}Installing Memtis modules and kernel...${NC}"
        make -C "$kdir" modules_install
        make -C "$kdir" install
        krelease=$(resolve_kernel_release "memtis" "$kdir" "$krelease")
        generate_initramfs "${krelease}"
    fi
    set_grub_default "$krelease" "Memtis"
}

# ------------------------------------------------------------------------------
# Function: set_nomad_default
# Description: Determines the exact kernel release string for Nomad from its
#              source directory or /boot, installs modules/kernel if required,
#              generates initramfs, and triggers GRUB setup.
# ------------------------------------------------------------------------------
set_nomad_default() {
    local kdir="${NOMAD_DIR}/linux"
    local krelease
    krelease=$(resolve_kernel_release "nomad" "$kdir" "5.13.0-rc6-Nomad")

    if [ -d "$kdir" ] && [ -f "$kdir/.config" ]; then
        echo -e "${CYAN}Installing Nomad modules and kernel...${NC}"
        make -C "$kdir" modules_install
        make -C "$kdir" install
        krelease=$(resolve_kernel_release "nomad" "$kdir" "$krelease")
        generate_initramfs "${krelease}"
    fi
    set_grub_default "$krelease" "Nomad"
}

# ------------------------------------------------------------------------------
# Function: set_nomad_noinline_default
# ------------------------------------------------------------------------------
set_nomad_noinline_default() {
    local kdir="${NOMAD_NOINLINE_DIR}/linux"
    local krelease
    krelease=$(resolve_kernel_release "nomad-noinline" "$kdir" "5.13.0-rc6-Nomad-Noinline")

    if [ -d "$kdir" ] && [ -f "$kdir/.config" ]; then
        echo -e "${CYAN}Installing Nomad-Noinline modules and kernel...${NC}"
        make -C "$kdir" modules_install
        make -C "$kdir" install
        krelease=$(resolve_kernel_release "nomad-noinline" "$kdir" "$krelease")
        generate_initramfs "${krelease}"
    fi
    set_grub_default "$krelease" "Nomad-Noinline"
}

# ------------------------------------------------------------------------------
# Function: set_nomad_alto_default
# ------------------------------------------------------------------------------
set_nomad_alto_default() {
    local kdir="${NOMAD_ALTO_DIR}/linux"
    local krelease
    krelease=$(resolve_kernel_release "nomad-alto" "$kdir" "5.13.0-rc6-Nomad-Alto")

    if [ -d "$kdir" ] && [ -f "$kdir/.config" ]; then
        echo -e "${CYAN}Installing Nomad-Alto modules and kernel...${NC}"
        make -C "$kdir" modules_install
        make -C "$kdir" install
        krelease=$(resolve_kernel_release "nomad-alto" "$kdir" "$krelease")
        generate_initramfs "${krelease}"
    fi
    set_grub_default "$krelease" "Nomad-Alto"
}

# ------------------------------------------------------------------------------
# Function: set_nomad_alto_noinline_default
# ------------------------------------------------------------------------------
set_nomad_alto_noinline_default() {
    local kdir="${NOMAD_ALTO_NOINLINE_DIR}/linux"
    local krelease
    krelease=$(resolve_kernel_release "nomad-alto-noinline" "$kdir" "5.13.0-rc6-Nomad-Alto-Noinline")

    if [ -d "$kdir" ] && [ -f "$kdir/.config" ]; then
        echo -e "${CYAN}Installing Nomad-Alto-Noinline modules and kernel...${NC}"
        make -C "$kdir" modules_install
        make -C "$kdir" install
        krelease=$(resolve_kernel_release "nomad-alto-noinline" "$kdir" "$krelease")
        generate_initramfs "${krelease}"
    fi
    set_grub_default "$krelease" "Nomad-Alto-Noinline"
}

# ------------------------------------------------------------------------------
# Function: set_tpp_default
# Description: Determines the exact kernel release string for TPP from its
#              source directory or /boot, installs modules/kernel if required,
#              generates initramfs, and triggers GRUB setup.
# ------------------------------------------------------------------------------
set_tpp_default() {
    local kdir="${TPP_DIR}/linux"
    local krelease
    krelease=$(resolve_kernel_release "tpp" "$kdir" "5.15.0-TPP")

    if [ -d "$kdir" ] && [ -f "$kdir/.config" ]; then
        echo -e "${CYAN}Installing TPP modules and kernel...${NC}"
        make -C "$kdir" modules_install
        make -C "$kdir" install
        krelease=$(resolve_kernel_release "tpp" "$kdir" "$krelease")
        generate_initramfs "${krelease}"
    fi
    set_grub_default "$krelease" "TPP"
}

# ------------------------------------------------------------------------------
# Function: set_colloid_tpp_default
# Description: Determines the exact kernel release string for Colloid-tpp from its
#              source directory or /boot, installs modules/kernel if required,
#              generates initramfs, and triggers GRUB setup.
# ------------------------------------------------------------------------------
set_colloid_tpp_default() {
    local kdir="${COLLOID_TPP_DIR}/linux"
    local krelease
    krelease=$(resolve_kernel_release "colloid" "$kdir" "6.3.0-Colloid-TPP")

    if [ -d "$kdir" ] && [ -f "$kdir/.config" ]; then
        echo -e "${CYAN}Installing Colloid-tpp modules and kernel...${NC}"
        make -C "$kdir" modules_install
        make -C "$kdir" install
        krelease=$(resolve_kernel_release "colloid" "$kdir" "$krelease")
        generate_initramfs "${krelease}"
    fi
    set_grub_default "$krelease" "Colloid-tpp"
}

# ------------------------------------------------------------------------------
# Function: set_colloid_tpp_alto_default
# Description: Determines the exact kernel release string for Colloid-tpp-alto from its
#              source directory or /boot, installs modules/kernel if required,
#              generates initramfs, and triggers GRUB setup.
# ------------------------------------------------------------------------------
set_colloid_tpp_alto_default() {
    local kdir="${COLLOID_TPP_ALTO_DIR}/linux"
    local krelease
    krelease=$(resolve_kernel_release "colloid-tpp-alto" "$kdir" "6.3.0-Colloid-TPP-Alto")

    if [ -d "$kdir" ] && [ -f "$kdir/.config" ]; then
        echo -e "${CYAN}Installing Colloid-tpp-alto modules and kernel...${NC}"
        make -C "$kdir" modules_install
        make -C "$kdir" install
        krelease=$(resolve_kernel_release "colloid-tpp-alto" "$kdir" "$krelease")
        generate_initramfs "${krelease}"
    fi
    set_grub_default "$krelease" "Colloid-tpp-alto"
}

# ------------------------------------------------------------------------------
# Function: set_generic_default
# Description: Finds the latest official distro generic kernel in /boot
#              (e.g., 7.0.0-30-generic) and sets it as the GRUB default.
# ------------------------------------------------------------------------------
set_generic_default() {
    local krelease
    krelease=$(ls /boot/vmlinuz-*-generic 2>/dev/null | sort -V | tail -n 1 | sed 's|/boot/vmlinuz-||')
    if [ -z "$krelease" ]; then
        krelease="generic"
    fi
    set_grub_default "$krelease" "Generic"
}

# ------------------------------------------------------------------------------
# Function: build_memtis
# Compile Pipeline Functions
# ------------------------------------------------------------------------------
compile_memtis() {
    echo -e "\n${BLUE}====================================================${NC}"
    echo -e "${BLUE} Compiling Memtis Kernel ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    [ ! -f "${MEMTIS_DIR}/setup_memtis.sh" ] && { echo -e "${RED}Error: ${MEMTIS_DIR}/setup_memtis.sh not found.${NC}"; exit 1; }
    clone_memtis
    echo -e "${CYAN}Running setup_memtis.sh...${NC}"
    (cd "${MEMTIS_DIR}" && bash setup_memtis.sh)
}

compile_nomad() {
    echo -e "\n${BLUE}====================================================${NC}"
    echo -e "${BLUE} Compiling Nomad Kernel ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    [ ! -f "${NOMAD_DIR}/compile.sh" ] && { echo -e "${RED}Error: ${NOMAD_DIR}/compile.sh not found.${NC}"; exit 1; }
    clone_nomad
    echo -e "${CYAN}Running compile.sh...${NC}"
    (cd "${NOMAD_DIR}" && bash compile.sh)
}

compile_nomad_noinline() {
    echo -e "\n${BLUE}====================================================${NC}"
    echo -e "${BLUE} Compiling Nomad-Noinline Kernel ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    [ ! -f "${NOMAD_NOINLINE_DIR}/compile.sh" ] && { echo -e "${RED}Error: ${NOMAD_NOINLINE_DIR}/compile.sh not found.${NC}"; exit 1; }
    clone_nomad_noinline
    echo -e "${CYAN}Running compile.sh...${NC}"
    (cd "${NOMAD_NOINLINE_DIR}" && bash compile.sh)
}

compile_nomad_alto() {
    echo -e "\n${BLUE}====================================================${NC}"
    echo -e "${BLUE} Compiling Nomad-Alto Kernel ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    [ ! -f "${NOMAD_ALTO_DIR}/compile.sh" ] && { echo -e "${RED}Error: ${NOMAD_ALTO_DIR}/compile.sh not found.${NC}"; exit 1; }
    clone_nomad_alto
    echo -e "${CYAN}Running compile.sh...${NC}"
    (cd "${NOMAD_ALTO_DIR}" && bash compile.sh)
}

compile_nomad_alto_noinline() {
    echo -e "\n${BLUE}====================================================${NC}"
    echo -e "${BLUE} Compiling Nomad-Alto-Noinline Kernel ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    [ ! -f "${NOMAD_ALTO_NOINLINE_DIR}/compile.sh" ] && { echo -e "${RED}Error: ${NOMAD_ALTO_NOINLINE_DIR}/compile.sh not found.${NC}"; exit 1; }
    clone_nomad_alto_noinline
    echo -e "${CYAN}Running compile.sh...${NC}"
    (cd "${NOMAD_ALTO_NOINLINE_DIR}" && bash compile.sh)
}

compile_tpp() {
    echo -e "\n${BLUE}====================================================${NC}"
    echo -e "${BLUE} Compiling TPP Kernel ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    [ ! -f "${TPP_DIR}/compile.sh" ] && { echo -e "${RED}Error: ${TPP_DIR}/compile.sh not found.${NC}"; exit 1; }
    clone_tpp
    echo -e "${CYAN}Running compile.sh...${NC}"
    (cd "${TPP_DIR}" && bash compile.sh)
}

compile_colloid_tpp() {
    echo -e "\n${BLUE}====================================================${NC}"
    echo -e "${BLUE} Compiling Colloid-tpp Kernel ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    [ ! -f "${COLLOID_TPP_DIR}/compile.sh" ] && { echo -e "${RED}Error: ${COLLOID_TPP_DIR}/compile.sh not found.${NC}"; exit 1; }
    clone_colloid_tpp
    echo -e "${CYAN}Running compile.sh...${NC}"
    (cd "${COLLOID_TPP_DIR}" && bash compile.sh)
}

compile_colloid_tpp_alto() {
    echo -e "\n${BLUE}====================================================${NC}"
    echo -e "${BLUE} Compiling Colloid-tpp-alto Kernel ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    [ ! -f "${COLLOID_TPP_ALTO_DIR}/compile.sh" ] && { echo -e "${RED}Error: ${COLLOID_TPP_ALTO_DIR}/compile.sh not found.${NC}"; exit 1; }
    clone_colloid_tpp_alto
    echo -e "${CYAN}Running compile.sh...${NC}"
    (cd "${COLLOID_TPP_ALTO_DIR}" && bash compile.sh)
}

# ------------------------------------------------------------------------------
# Full Build Pipeline Functions (Compile + Install + GRUB Default)
# ------------------------------------------------------------------------------
build_memtis() {
    compile_memtis
    set_memtis_default
}

build_nomad() {
    compile_nomad
    set_nomad_default
}

build_nomad_noinline() {
    compile_nomad_noinline
    set_nomad_noinline_default
}

build_nomad_alto() {
    compile_nomad_alto
    set_nomad_alto_default
}

build_nomad_alto_noinline() {
    compile_nomad_alto_noinline
    set_nomad_alto_noinline_default
}

build_tpp() {
    compile_tpp
    set_tpp_default
}

build_colloid_tpp() {
    compile_colloid_tpp
    set_colloid_tpp_default
}

build_colloid_tpp_alto() {
    compile_colloid_tpp_alto
    set_colloid_tpp_alto_default
}

# ------------------------------------------------------------------------------
# Function: clean_kernel
# Description: Removes .old backup files, and optionally uninstalls specific
#              or all custom baseline kernels from /boot and /lib/modules,
#              then updates GRUB.
# ------------------------------------------------------------------------------
clean_kernel() {
    local target="$1"
    echo -e "\n${BLUE}====================================================${NC}"
    echo -e "${BLUE} Cleaning GRUB & Kernel: '${target}' ${NC}"
    echo -e "${BLUE}====================================================${NC}"

    # Always remove .old backup files from /boot
    echo -e "${CYAN}Removing backup .old kernel and initrd images from /boot...${NC}"
    rm -f /boot/vmlinuz-*.old /boot/initrd.img-*.old /boot/System.map-*.old /boot/config-*.old 2>/dev/null || true

    case "$target" in
        generic|distro|default)
            echo -e "${YELLOW}Notice: 'generic' is the official Ubuntu distribution kernel and will never be removed.${NC}"
            ;;
        memtis)
            echo -e "${YELLOW}Uninstalling Memtis kernel from /boot, /lib/modules, and removing source tree...${NC}"
            rm -rf /boot/*memtis* /boot/*Memtis* /lib/modules/*memtis* /lib/modules/*Memtis* "${MEMTIS_DIR}/linux" "${MEMTIS_DIR}/log" 2>/dev/null || true
            ;;
        nomad)
            echo -e "${YELLOW}Uninstalling Nomad kernel from /boot, /lib/modules, and removing source tree...${NC}"
            rm -rf /boot/*5.13.0-rc6-Nomad /boot/*5.13.0-rc6-Nomad.* /lib/modules/*5.13.0-rc6-Nomad "${NOMAD_DIR}/linux" "${NOMAD_DIR}/log" "${NOMAD_DIR}/nomad_module/async_promote.ko" 2>/dev/null || true
            ;;
        nomad-noinline)
            echo -e "${YELLOW}Uninstalling Nomad-Noinline kernel from /boot, /lib/modules, and removing source tree...${NC}"
            rm -rf /boot/*5.13.0-rc6-Nomad-Noinline* /lib/modules/*5.13.0-rc6-Nomad-Noinline* "${NOMAD_NOINLINE_DIR}/linux" "${NOMAD_NOINLINE_DIR}/log" "${NOMAD_NOINLINE_DIR}/nomad_module/async_promote.ko" 2>/dev/null || true
            ;;
        nomad-alto)
            echo -e "${YELLOW}Uninstalling Nomad-Alto kernel from /boot, /lib/modules, and removing source tree...${NC}"
            rm -rf /boot/*5.13.0-rc6-Nomad-Alto /boot/*5.13.0-rc6-Nomad-Alto.* /lib/modules/*5.13.0-rc6-Nomad-Alto "${NOMAD_ALTO_DIR}/linux" "${NOMAD_ALTO_DIR}/log" "${NOMAD_ALTO_DIR}/nomad_module/async_promote.ko" 2>/dev/null || true
            ;;
        nomad-alto-noinline)
            echo -e "${YELLOW}Uninstalling Nomad-Alto-Noinline kernel from /boot, /lib/modules, and removing source tree...${NC}"
            rm -rf /boot/*5.13.0-rc6-Nomad-Alto-Noinline* /lib/modules/*5.13.0-rc6-Nomad-Alto-Noinline* "${NOMAD_ALTO_NOINLINE_DIR}/linux" "${NOMAD_ALTO_NOINLINE_DIR}/log" "${NOMAD_ALTO_NOINLINE_DIR}/nomad_module/async_promote.ko" 2>/dev/null || true
            ;;
        tpp)
            echo -e "${YELLOW}Uninstalling TPP kernel from /boot, /lib/modules, and removing source tree...${NC}"
            rm -rf /boot/*5.15.0-TPP* /boot/*5.15.0 /boot/*5.15.0.* /lib/modules/*5.15.0-TPP* /lib/modules/*5.15.0 "${TPP_DIR}/linux" "${TPP_DIR}/log" 2>/dev/null || true
            ;;
        colloid-tpp)
            echo -e "${YELLOW}Uninstalling Colloid-tpp kernel from /boot, /lib/modules, and removing source tree...${NC}"
            rm -rf /boot/*Colloid-TPP* /boot/*6.3.0 /boot/*6.3.0.* /lib/modules/*Colloid-TPP* /lib/modules/*6.3.0 "${COLLOID_TPP_DIR}/linux" "${COLLOID_TPP_DIR}/log" 2>/dev/null || true
            ;;
        colloid-tpp-alto)
            echo -e "${YELLOW}Uninstalling Colloid-tpp-alto kernel from /boot, /lib/modules, and removing source tree...${NC}"
            rm -rf /boot/*Colloid-TPP-Alto* /lib/modules/*Colloid-TPP-Alto* "${COLLOID_TPP_ALTO_DIR}/linux" "${COLLOID_TPP_ALTO_DIR}/log" 2>/dev/null || true
            ;;
        all)
            echo -e "${YELLOW}Purging all custom baseline kernels from /boot, /lib/modules, and removing all source trees...${NC}"
            rm -rf /boot/*memtis* /boot/*Memtis* /lib/modules/*memtis* /lib/modules/*Memtis* "${MEMTIS_DIR}/linux" "${MEMTIS_DIR}/log" 2>/dev/null || true
            rm -rf /boot/*Nomad* /lib/modules/*Nomad* "${NOMAD_DIR}/linux" "${NOMAD_DIR}/log" "${NOMAD_DIR}/nomad_module/async_promote.ko" "${NOMAD_NOINLINE_DIR}/linux" "${NOMAD_NOINLINE_DIR}/log" "${NOMAD_ALTO_DIR}/linux" "${NOMAD_ALTO_DIR}/log" "${NOMAD_ALTO_NOINLINE_DIR}/linux" "${NOMAD_ALTO_NOINLINE_DIR}/log" 2>/dev/null || true
            rm -rf /boot/*5.15.0-TPP* /lib/modules/*5.15.0-TPP* "${TPP_DIR}/linux" "${TPP_DIR}/log" 2>/dev/null || true
            rm -rf /boot/*Colloid* /lib/modules/*Colloid* "${COLLOID_TPP_DIR}/linux" "${COLLOID_TPP_DIR}/log" "${COLLOID_TPP_ALTO_DIR}/linux" "${COLLOID_TPP_ALTO_DIR}/log" 2>/dev/null || true
            ;;
        grub|clean_grub|old)
            echo -e "${GREEN}Cleaned all duplicate .old entries from /boot.${NC}"
            ;;
    esac

    echo -e "${CYAN}Updating GRUB configuration...${NC}"
    update-grub
    echo -e "${GREEN}==> GRUB cleaned successfully.${NC}"
}

# ------------------------------------------------------------------------------
# Command Line Argument Parsing
# Defaults: ACTION="build", TARGET="", AUTO_REBOOT=false
# ------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    TARGET=""
    ACTION="build"
    AUTO_REBOOT=false

    for arg in "$@"; do
        case "$arg" in
            --reboot|-r)
                AUTO_REBOOT=true
                ;;
            --help|-h|help)
                show_help
                exit 0
                ;;
            compile_only|compile-only|compile|build_only|build-only|--compile-only|-c)
                ACTION="compile_only"
                ;;
            update_grub|update-grub|set_default|set_grub|set_grub_default|select)
                ACTION="update_grub"
                ;;
            clean_grub|clean-grub|clean_old|clean-old)
                ACTION="clean"
                if [ -z "$TARGET" ]; then
                    TARGET="grub"
                fi
                ;;
            clean|purge|uninstall|remove)
                ACTION="clean"
                ;;
            memtis|nomad|nomad-noinline|nomad-alto|nomad_alto|nomad-alto-noinline|nomad_alto_noinline|nomad-noinline-alto|nomad_noinline_alto|tpp|colloid-tpp|colloid_tpp|colloid|colloid-tpp-alto|colloid_tpp_alto|colloid-alto|colloid_alto|generic|distro|default|all)
                TARGET="${arg,,}" # Convert target name to lowercase
                if [[ "$TARGET" == "colloid_tpp" || "$TARGET" == "colloid" ]]; then
                    TARGET="colloid-tpp"
                elif [[ "$TARGET" == "colloid_tpp_alto" || "$TARGET" == "colloid-alto" || "$TARGET" == "colloid_alto" ]]; then
                    TARGET="colloid-tpp-alto"
                elif [[ "$TARGET" == "nomad_alto" ]]; then
                    TARGET="nomad-alto"
                elif [[ "$TARGET" == "nomad-alto-noinline" || "$TARGET" == "nomad_alto_noinline" || "$TARGET" == "nomad-noinline-alto" || "$TARGET" == "nomad_noinline_alto" ]]; then
                    TARGET="nomad-alto-noinline"
                elif [[ "$TARGET" == "distro" || "$TARGET" == "default" ]]; then
                    TARGET="generic"
                fi
                ;;
            *)
                echo -e "${RED}Error: Unknown argument '${arg}'.${NC}\n"
                show_help
                exit 1
                ;;
        esac
    done

    # Validate that a target was specified (or default to grub for clean action)
    if [ -z "$TARGET" ]; then
        if [ "$ACTION" == "clean" ]; then
            TARGET="grub"
        else
            echo -e "${RED}Error: No kernel target specified (memtis, nomad, nomad-noinline, nomad-alto, nomad-alto-noinline, tpp, colloid-tpp, colloid-tpp-alto, generic, or all).${NC}\n"
            show_help
            exit 1
        fi
    fi

    # ------------------------------------------------------------------------------
    # Action Dispatcher
    # Executes clean, update_grub, compile_only, or full build based on parsed arguments.
    # ------------------------------------------------------------------------------
    if [ "$ACTION" == "clean" ]; then
        clean_kernel "$TARGET"
    elif [ "$ACTION" == "update_grub" ]; then
        case "$TARGET" in
            memtis)
                set_memtis_default
                ;;
            nomad)
                set_nomad_default
                ;;
            nomad-noinline)
                set_nomad_noinline_default
                ;;
            nomad-alto)
                set_nomad_alto_default
                ;;
            nomad-alto-noinline)
                set_nomad_alto_noinline_default
                ;;
            tpp)
                set_tpp_default
                ;;
            colloid-tpp)
                set_colloid_tpp_default
                ;;
            colloid-tpp-alto)
                set_colloid_tpp_alto_default
                ;;
            generic)
                set_generic_default
                ;;
            all)
                set_memtis_default
                set_nomad_default
                set_nomad_noinline_default
                set_nomad_alto_default
                set_nomad_alto_noinline_default
                set_tpp_default
                set_colloid_tpp_default
                set_colloid_tpp_alto_default
                ;;
        esac
    elif [ "$ACTION" == "compile_only" ]; then
        case "$TARGET" in
            memtis)
                compile_memtis
                ;;
            nomad)
                compile_nomad
                ;;
            nomad-noinline)
                compile_nomad_noinline
                ;;
            nomad-alto)
                compile_nomad_alto
                ;;
            nomad-alto-noinline)
                compile_nomad_alto_noinline
                ;;
            tpp)
                compile_tpp
                ;;
            colloid-tpp)
                compile_colloid_tpp
                ;;
            colloid-tpp-alto)
                compile_colloid_tpp_alto
                ;;
            generic)
                echo -e "${GREEN}==> Target 'generic' uses the pre-installed Ubuntu distribution kernel (no compilation required).${NC}"
                ;;
            all)
                compile_memtis
                compile_nomad
                compile_nomad_noinline
                compile_nomad_alto
                compile_nomad_alto_noinline
                compile_tpp
                compile_colloid_tpp
                compile_colloid_tpp_alto
                ;;
        esac
        echo -e "\n${GREEN}==> Kernel compilation completed successfully for target '${TARGET}' (no system installation or GRUB modification performed).${NC}"
    else
        case "$TARGET" in
            memtis)
                build_memtis
                ;;
            nomad)
                build_nomad
                ;;
            nomad-noinline)
                build_nomad_noinline
                ;;
            nomad-alto)
                build_nomad_alto
                ;;
            nomad-alto-noinline)
                build_nomad_alto_noinline
                ;;
            tpp)
                build_tpp
                ;;
            colloid-tpp)
                build_colloid_tpp
                ;;
            colloid-tpp-alto)
                build_colloid_tpp_alto
                ;;
            generic)
                set_generic_default
                ;;
            all)
                build_memtis
                build_nomad
                build_nomad_noinline
                build_nomad_alto
                build_nomad_alto_noinline
                build_tpp
                build_colloid_tpp
                build_colloid_tpp_alto
                ;;
        esac
    fi

    # ------------------------------------------------------------------------------
    # Reboot Prompt & Handling
    # Handles automatic reboot if --reboot was passed, or prompts interactively.
    # ------------------------------------------------------------------------------
    if [ "$ACTION" != "compile_only" ]; then
        if [ "$AUTO_REBOOT" = true ]; then
            echo -e "\n${GREEN}Auto-reboot requested. Rebooting system in 3 seconds...${NC}"
            sleep 3
            reboot
        else
            # Check if standard input is attached to an interactive terminal
            if [ -t 0 ]; then
                echo ""
                read -rp "Kernel task completed. Reboot into default kernel now? (y/N): " answer
                if [[ "$answer" =~ ^[Yy]$ ]]; then
                    echo -e "${GREEN}Rebooting system...${NC}"
                    reboot
                fi
            fi
        fi
    fi
fi
