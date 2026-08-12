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
TPP_DIR="${BASELINES_DIR}/tpp"
COLLOID_TPP_DIR="${BASELINES_DIR}/colloid-tpp"

# Formatting color definitions for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# Function: show_help
# Description: Displays command line usage information, available actions,
#              supported targets, optional flags, and usage examples.
# ------------------------------------------------------------------------------
show_help() {
    echo "Usage: sudo $0 [memtis|nomad|tpp|colloid-tpp|all] [build|compile_only|update_grub] [--reboot|-r] [--help|-h]"
    echo ""
    echo "Actions:"
    echo "  build (default) Full build: auto-clone repo, compile, install kernel/modules, update GRUB & set default"
    echo "  compile_only    Compile kernel & modules ONLY (no installation to /boot or /lib/modules, no GRUB changes)"
    echo "  update_grub     Only set GRUB default boot entry (without compiling or installing)"
    echo ""
    echo "Targets:"
    echo "  memtis          Memtis kernel baseline (Linux 5.15.19-Memtis)"
    echo "  nomad           Nomad kernel baseline (Linux 5.13.0-rc6-Nomad)"
    echo "  tpp             TPP kernel baseline (Linux 5.15.0 TPP)"
    echo "  colloid-tpp     Colloid-tpp kernel baseline (Linux 6.3.0 Colloid-tpp)"
    echo "  all             All baseline kernels (Memtis, Nomad, TPP, Colloid-tpp)"
    echo ""
    echo "Options:"
    echo "  -r, --reboot    Automatically reboot system after completing task"
    echo "  -h, --help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  sudo $0 memtis              # Full build & install Memtis kernel & set GRUB default"
    echo "  sudo $0 nomad compile_only  # Compile Nomad kernel ONLY (without installing or changing GRUB)"
    echo "  sudo $0 tpp update_grub     # Only set GRUB default to TPP"
    echo "  sudo $0 colloid-tpp         # Full build & install Colloid-tpp kernel & set GRUB default"
}

# ------------------------------------------------------------------------------
# Root Privilege Check
# Kernel installation and GRUB updating require administrative privileges.
# If not running as root, re-run the script using sudo.
# ------------------------------------------------------------------------------
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

    if [ -z "$krelease" ] || [ ! -f "/boot/vmlinuz-${krelease}" ]; then
        local installed
        installed=$(ls /boot/vmlinuz-* 2>/dev/null | grep -i "${target}" | head -n 1 | sed 's|/boot/vmlinuz-||' || true)
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

    echo -e "\n${CYAN}==> Updating GRUB configuration for ${name} (${krelease})...${NC}"

    # Backup original /etc/default/grub file if a backup does not already exist
    if [ ! -f /etc/default/grub.bak ]; then
        cp /etc/default/grub /etc/default/grub.bak
    fi

    # Temporary: Ensure numa=fake=2 parameter is set in GRUB_CMDLINE_LINUX_DEFAULT for single-socket NUMA emulation.
    # Note: Remove this setting when running on a physical 2-socket machine.
    if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub; then
        if ! grep "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub | grep -q "numa=fake=2"; then
            sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"|GRUB_CMDLINE_LINUX_DEFAULT="\1 numa=fake=2"|' /etc/default/grub
        fi
    else
        echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash numa=fake=2"' >> /etc/default/grub
    fi

    # First run update-grub to ensure /boot/grub/grub.cfg contains all installed kernels
    update-grub

    # Inspect /boot/grub/grub.cfg to find the exact submenu and menuentry titles
    local grub_cfg="/boot/grub/grub.cfg"
    local submenu_title="Advanced options for Ubuntu"
    local menu_title=""
    local grub_entry=""

    if [ -f "$grub_cfg" ]; then
        local found_sub
        found_sub=$(grep -E "submenu ['\"]" "$grub_cfg" | head -n 1 | sed -E "s/.*submenu ['\"]([^'\"]+)['\"].*/\1/" || true)
        if [ -n "$found_sub" ]; then
            submenu_title="$found_sub"
        fi

        # Search for menuentry matching exact release string
        menu_title=$(grep -E "menuentry ['\"]" "$grub_cfg" | grep -v -i "recovery" | grep -i "${krelease}" | head -n 1 | sed -E "s/.*menuentry ['\"]([^'\"]+)['\"].*/\1/" || true)

        # Fallback search matching target name (e.g. Memtis)
        if [ -z "$menu_title" ]; then
            menu_title=$(grep -E "menuentry ['\"]" "$grub_cfg" | grep -v -i "recovery" | grep -i "${name}" | head -n 1 | sed -E "s/.*menuentry ['\"]([^'\"]+)['\"].*/\1/" || true)
        fi
    fi

    if [ -n "$menu_title" ]; then
        grub_entry="${submenu_title}>${menu_title}"
    else
        grub_entry="${submenu_title}>Ubuntu, with Linux ${krelease}"
    fi

    # Update GRUB_DEFAULT in /etc/default/grub with the verified GRUB entry
    if grep -q "^GRUB_DEFAULT=" /etc/default/grub; then
        sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${grub_entry}\"|" /etc/default/grub
    else
        echo "GRUB_DEFAULT=\"${grub_entry}\"" >> /etc/default/grub
    fi

    # Regenerate GRUB config with updated GRUB_DEFAULT and set default entry in grubenv
    grub-set-default "${grub_entry}" 2>/dev/null || grub-set-default "${krelease}" 2>/dev/null || true
    update-grub

    echo -e "${GREEN}==> Successfully set default GRUB boot entry to:${NC} ${grub_entry}"
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
        make -C "$kdir" INSTALL_MOD_STRIP=1 modules_install
        make -C "$kdir" install
        krelease=$(make -s -C "$kdir" kernelrelease 2>/dev/null || echo "$krelease")
        echo -e "${CYAN}Updating initramfs for ${krelease}...${NC}"
        update-initramfs -c -k "${krelease}" 2>/dev/null || update-initramfs -u -k "${krelease}" 2>/dev/null || true
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
        make -C "$kdir" INSTALL_MOD_STRIP=1 modules_install
        make -C "$kdir" install
        krelease=$(make -s -C "$kdir" kernelrelease 2>/dev/null || echo "$krelease")
        echo -e "${CYAN}Updating initramfs for ${krelease}...${NC}"
        update-initramfs -c -k "${krelease}" 2>/dev/null || update-initramfs -u -k "${krelease}" 2>/dev/null || true
    fi
    set_grub_default "$krelease" "Nomad"
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
    krelease=$(resolve_kernel_release "tpp" "$kdir" "5.15.0")

    if [ -d "$kdir" ] && [ -f "$kdir/.config" ]; then
        echo -e "${CYAN}Installing TPP modules and kernel...${NC}"
        make -C "$kdir" INSTALL_MOD_STRIP=1 modules_install
        make -C "$kdir" install
        krelease=$(make -s -C "$kdir" kernelrelease 2>/dev/null || echo "$krelease")
        echo -e "${CYAN}Updating initramfs for ${krelease}...${NC}"
        update-initramfs -c -k "${krelease}" 2>/dev/null || update-initramfs -u -k "${krelease}" 2>/dev/null || true
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
    krelease=$(resolve_kernel_release "colloid" "$kdir" "6.3.0")

    if [ -d "$kdir" ] && [ -f "$kdir/.config" ]; then
        echo -e "${CYAN}Installing Colloid-tpp modules and kernel...${NC}"
        make -C "$kdir" INSTALL_MOD_STRIP=1 modules_install
        make -C "$kdir" install
        krelease=$(make -s -C "$kdir" kernelrelease 2>/dev/null || echo "$krelease")
        echo -e "${CYAN}Updating initramfs for ${krelease}...${NC}"
        update-initramfs -c -k "${krelease}" 2>/dev/null || update-initramfs -u -k "${krelease}" 2>/dev/null || true
    fi
    set_grub_default "$krelease" "Colloid-tpp"
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

build_tpp() {
    compile_tpp
    set_tpp_default
}

build_colloid_tpp() {
    compile_colloid_tpp
    set_colloid_tpp_default
}

# ------------------------------------------------------------------------------
# Command Line Argument Parsing
# Defaults: ACTION="build", TARGET="", AUTO_REBOOT=false
# ------------------------------------------------------------------------------
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
        memtis|nomad|tpp|colloid-tpp|colloid_tpp|colloid|all)
            TARGET="${arg,,}" # Convert target name to lowercase
            if [[ "$TARGET" == "colloid_tpp" || "$TARGET" == "colloid" ]]; then
                TARGET="colloid-tpp"
            fi
            ;;
        *)
            echo -e "${RED}Error: Unknown argument '${arg}'.${NC}\n"
            show_help
            exit 1
            ;;
    esac
done

# Validate that a target was specified
if [ -z "$TARGET" ]; then
    echo -e "${RED}Error: No kernel target specified (memtis, nomad, tpp, colloid-tpp, or all).${NC}\n"
    show_help
    exit 1
fi

# ------------------------------------------------------------------------------
# Action Dispatcher
# Executes update_grub, compile_only, or full build based on parsed arguments.
# ------------------------------------------------------------------------------
if [ "$ACTION" == "update_grub" ]; then
    case "$TARGET" in
        memtis)
            set_memtis_default
            ;;
        nomad)
            set_nomad_default
            ;;
        tpp)
            set_tpp_default
            ;;
        colloid-tpp)
            set_colloid_tpp_default
            ;;
        all)
            set_memtis_default
            set_nomad_default
            set_tpp_default
            set_colloid_tpp_default
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
        tpp)
            compile_tpp
            ;;
        colloid-tpp)
            compile_colloid_tpp
            ;;
        all)
            compile_memtis
            compile_nomad
            compile_tpp
            compile_colloid_tpp
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
        tpp)
            build_tpp
            ;;
        colloid-tpp)
            build_colloid_tpp
            ;;
        all)
            build_memtis
            build_nomad
            build_tpp
            build_colloid_tpp
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
