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
#   sudo ./manage_kernels.sh [target] [build|compile_only|update_grub|clean|purge] [--reboot]
# ==============================================================================

# Enable strict mode:
# -e : Exit immediately if a command exits with a non-zero status.
# -u : Treat unset variables as an error when expanding.
# -o pipefail : Return status of the last command to fail in a pipeline.
set -euo pipefail

# Turn-off the swap if possible.
swapoff -a 2>/dev/null || true

# Directory paths initialization
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
BASELINES_DIR="${ROOT_DIR}/baselines"

# Baseline kernel target list
BASELINE_TARGETS=(
    autonuma autonuma-prefetch
    memtis memtis-prefetch
    nomad nomad-prefetch nomad-noinline nomad-alto nomad-alto-prefetch nomad-alto-noinline
    tpp tpp-prefetch colloid-tpp colloid-tpp-alto colloid-tpp-prefetch colloid-tpp-alto-prefetch
    pact pact-prefetch pact-prefetch-batch
    hybridtier hybridtier-prefetch
)

# Standard baseline directory paths
AUTONUMA_DIR="${BASELINES_DIR}/autonuma"
AUTONUMA_PREFETCH_DIR="${BASELINES_DIR}/autonuma"
MEMTIS_DIR="${BASELINES_DIR}/memtis"
MEMTIS_PREFETCH_DIR="${BASELINES_DIR}/memtis"
NOMAD_DIR="${BASELINES_DIR}/nomad"
NOMAD_PREFETCH_DIR="${BASELINES_DIR}/nomad"
NOMAD_NOINLINE_DIR="${BASELINES_DIR}/nomad-noinline"
NOMAD_ALTO_DIR="${BASELINES_DIR}/nomad-alto"
NOMAD_ALTO_PREFETCH_DIR="${BASELINES_DIR}/nomad-alto"
NOMAD_ALTO_NOINLINE_DIR="${BASELINES_DIR}/nomad-alto-noinline"
TPP_DIR="${BASELINES_DIR}/tpp"
TPP_PREFETCH_DIR="${BASELINES_DIR}/tpp"
COLLOID_TPP_DIR="${BASELINES_DIR}/colloid-tpp"
COLLOID_TPP_PREFETCH_DIR="${BASELINES_DIR}/colloid-tpp"
COLLOID_TPP_ALTO_DIR="${BASELINES_DIR}/colloid-tpp-alto"
COLLOID_TPP_ALTO_PREFETCH_DIR="${BASELINES_DIR}/colloid-tpp-alto"
PACT_DIR="${BASELINES_DIR}/pact"
PACT_PREFETCH_DIR="${BASELINES_DIR}/pact"
PACT_PREFETCH_BATCH_DIR="${BASELINES_DIR}/pact"
HYBRIDTIER_DIR="${BASELINES_DIR}/hybridtier"
HYBRIDTIER_PREFETCH_DIR="${BASELINES_DIR}/hybridtier"

# Formatting color definitions for terminal output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# Target Metadata & Kernel Matching Resolver
# ------------------------------------------------------------------------------
# Target metadata resolver: returns "kdir|fallback_release|display_name"
get_kernel_meta() {
    local target="$1"
    case "$target" in
        autonuma)                  echo "${BASELINES_DIR}/autonuma/linux|7.3.0-AutoNUMA|AutoNUMA" ;;
        autonuma-prefetch)         echo "${BASELINES_DIR}/autonuma/linux|7.3.0-AutoNUMA-prefetch|AutoNUMA-prefetch" ;;
        memtis)                    echo "${BASELINES_DIR}/memtis/linux|5.15.19-htmm-Memtis+|Memtis" ;;
        memtis-prefetch)           echo "${BASELINES_DIR}/memtis/linux|5.15.19-htmm-Memtis-Prefetch+|Memtis-Prefetch" ;;
        nomad)                     echo "${BASELINES_DIR}/nomad/linux|5.13.0-rc6-Nomad|Nomad" ;;
        nomad-prefetch)            echo "${BASELINES_DIR}/nomad/linux|5.13.0-rc6-Nomad-Prefetch|Nomad-Prefetch" ;;
        nomad-noinline)            echo "${BASELINES_DIR}/nomad-noinline/linux|5.13.0-rc6-Nomad-Noinline|Nomad-Noinline" ;;
        nomad-alto)                echo "${BASELINES_DIR}/nomad-alto/linux|5.13.0-rc6-Nomad-Alto|Nomad-Alto" ;;
        nomad-alto-prefetch)       echo "${BASELINES_DIR}/nomad-alto/linux|5.13.0-rc6-Nomad-Alto-Prefetch|Nomad-Alto-Prefetch" ;;
        nomad-alto-noinline)       echo "${BASELINES_DIR}/nomad-alto-noinline/linux|5.13.0-rc6-Nomad-Alto-Noinline|Nomad-Alto-Noinline" ;;
        tpp)                       echo "${BASELINES_DIR}/tpp/linux|5.15.0-TPP|TPP" ;;
        tpp-prefetch)              echo "${BASELINES_DIR}/tpp/linux|5.15.0-TPP-Prefetch|TPP-Prefetch" ;;
        colloid|colloid-tpp)       echo "${BASELINES_DIR}/colloid-tpp/linux|6.3.0-Colloid-TPP|Colloid-tpp" ;;
        colloid-tpp-alto)          echo "${BASELINES_DIR}/colloid-tpp-alto/linux|6.3.0-Colloid-TPP-Alto|Colloid-tpp-alto" ;;
        colloid-tpp-prefetch)      echo "${BASELINES_DIR}/colloid-tpp/linux|6.3.0-Colloid-TPP-prefetch|Colloid-tpp-prefetch" ;;
        colloid-tpp-alto-prefetch) echo "${BASELINES_DIR}/colloid-tpp-alto/linux|6.3.0-Colloid-TPP-Alto-prefetch|Colloid-tpp-alto-prefetch" ;;
        pact)                      echo "${BASELINES_DIR}/pact/linux|6.3.0-PACT|PACT" ;;
        pact-prefetch)             echo "${BASELINES_DIR}/pact/linux|6.3.0-PACT-prefetch|PACT-prefetch" ;;
        pact-prefetch-batch)       echo "${BASELINES_DIR}/pact/linux|6.3.0-PACT-prefetch-Batch|PACT-prefetch-Batch" ;;
        hybridtier)                echo "${BASELINES_DIR}/hybridtier/linux|6.2.0-hybridtier+|HybridTier" ;;
        hybridtier-prefetch)       echo "${BASELINES_DIR}/hybridtier/linux|6.2.0-hybridtier-prefetch|HybridTier-prefetch" ;;
        generic|distro|default)    echo "/boot|generic|Generic" ;;
        *)                         echo "" ;;
    esac
}
export -f get_kernel_meta

matches_kernel_target() {
    local target="$1"
    local k_str="${2,,}"
    case "$target" in
        generic|distro|default)
            [[ "$k_str" =~ generic ]]
            ;;
        autonuma-prefetch)
            [[ "$k_str" =~ autonuma && "$k_str" =~ prefetch ]]
            ;;
        autonuma)
            [[ "$k_str" =~ autonuma && ! "$k_str" =~ prefetch ]]
            ;;
        memtis-prefetch)
            [[ "$k_str" =~ memtis && "$k_str" =~ prefetch ]]
            ;;
        memtis)
            [[ "$k_str" =~ memtis && ! "$k_str" =~ prefetch ]]
            ;;
        nomad-alto-prefetch)
            [[ "$k_str" =~ nomad && "$k_str" =~ alto && "$k_str" =~ prefetch ]]
            ;;
        nomad-prefetch)
            [[ "$k_str" =~ nomad && ! "$k_str" =~ alto && "$k_str" =~ prefetch ]]
            ;;
        nomad-alto-noinline)
            [[ "$k_str" =~ nomad && "$k_str" =~ alto && "$k_str" =~ noinline ]]
            ;;
        nomad-noinline)
            [[ "$k_str" =~ nomad && ! "$k_str" =~ alto && "$k_str" =~ noinline ]]
            ;;
        nomad-alto)
            [[ "$k_str" =~ nomad && "$k_str" =~ alto && ! "$k_str" =~ noinline && ! "$k_str" =~ prefetch ]]
            ;;
        nomad)
            [[ "$k_str" =~ nomad && ! "$k_str" =~ alto && ! "$k_str" =~ noinline && ! "$k_str" =~ prefetch ]]
            ;;
        colloid-tpp-alto-prefetch)
            [[ "$k_str" =~ colloid && "$k_str" =~ alto && "$k_str" =~ prefetch ]]
            ;;
        colloid-tpp-prefetch)
            [[ "$k_str" =~ colloid && ! "$k_str" =~ alto && "$k_str" =~ prefetch ]]
            ;;
        colloid-tpp-alto|colloid-alto)
            [[ "$k_str" =~ colloid && "$k_str" =~ alto && ! "$k_str" =~ prefetch ]]
            ;;
        colloid-tpp|colloid)
            [[ "$k_str" =~ colloid && ! "$k_str" =~ alto && ! "$k_str" =~ prefetch ]]
            ;;
        pact-prefetch-batch)
            [[ "$k_str" =~ prefetch-batch || "$k_str" =~ prefetch.*batch ]]
            ;;
        pact-prefetch)
            [[ "$k_str" =~ pact && "$k_str" =~ prefetch && ! "$k_str" =~ batch ]]
            ;;
        pact)
            [[ "$k_str" =~ pact && ! "$k_str" =~ prefetch ]]
            ;;
        tpp-prefetch)
            [[ "$k_str" =~ tpp && ! "$k_str" =~ colloid && "$k_str" =~ prefetch ]]
            ;;
        tpp)
            [[ "$k_str" =~ tpp && ! "$k_str" =~ colloid && ! "$k_str" =~ prefetch ]]
            ;;
        hybridtier-prefetch)
            [[ "$k_str" =~ hybridtier && "$k_str" =~ prefetch ]]
            ;;
        hybridtier)
            [[ "$k_str" =~ hybridtier && ! "$k_str" =~ prefetch ]]
            ;;
        *)
            [[ "$k_str" =~ $(echo "$target" | tr '[:upper:]' '[:lower:]') ]]
            ;;
    esac
}
export -f matches_kernel_target

# ------------------------------------------------------------------------------
# Helpers: Benchmark RSS and Fast-Tier Memmap Resolution
# ------------------------------------------------------------------------------
get_rss() {
    case "$1" in
        # --- GAPBS Graph Workloads (within-1GiB peers snapped to share memmap) ---
        gapbs_pr_kron|gapbs_pr_urand)         echo 18 ;;
        gapbs_pr_twitter)                     echo 12 ;;
        gapbs_tc_kron)                        echo 38 ;;
        gapbs_tc_urand)                       echo 18 ;;
        gapbs_tc_twitter)                     echo 20 ;; # Actually 21
        gapbs_bfs_kron|gapbs_bfs_urand)       echo 18 ;;
        gapbs_bfs_twitter)                    echo 12 ;;
        gapbs_bc_kron)                        echo 18 ;; # Actually 19
        gapbs_bc_urand)                       echo 20 ;;
        gapbs_bc_twitter)                     echo 12 ;; # Actually 13
        gapbs_cc_kron|gapbs_cc_urand)         echo 18 ;;
        gapbs_cc_twitter)                     echo 12 ;;
        gapbs_sssp_kron)                      echo 34 ;;
        gapbs_sssp_urand)                     echo 36 ;;
        gapbs_sssp_twitter)                   echo 22 ;; # Actually 23

        # --- In-Memory Databases & Microbenchmarks ---
        silo_tpcc)                            echo 20 ;;
        silo_ycsb)                            echo 40 ;;
        redis)                                echo 26 ;;
        xsbench)                              echo 18 ;;
        stream|stream_hot|stream_phase*)      echo 18 ;;

        # --- SPEC CPU Benchmarks ---
        spec2026_708.sqlite_r)                echo 28 ;;
        spec2026_820.cloverleaf_s)            echo 22 ;;
        spec2026_849.fotonik3d_s)             echo 49 ;; # Actually 48
        spec2026_865.roms_s)                  echo 22 ;; # Actually 23
        spec2026_881.neutron_s)               echo 49 ;;

        # --- Fallback Default ---
        *)                                    echo 20 ;;
    esac
}

calc_fast_gb() {
    local rss="$1" ratio="${2:-1:1}"
    local f="${ratio%%:*}" s="${ratio##*:}"
    local os_headroom="${OS_HEADROOM:-3}"
    local min_fast="${MIN_FAST:-1}"
    awk -v rss="$rss" -v f="$f" -v s="$s" -v os="$os_headroom" -v min_f="$min_fast" 'BEGIN {
        wl_fast = (rss * f) / (f + s);
        fast = int(wl_fast + os + 0.5);
        if (fast < min_f) fast = min_f;
        if (fast > 40) fast = 40;
        print fast;
    }'
}

resolve_memmap() {
    local bench="$1" ratio="${2:-1:1}"
    local rss fast_gb
    rss=$(get_rss "$bench")
    fast_gb=$(calc_fast_gb "$rss" "$ratio")
    echo "memmap=$((48 - fast_gb))G!${fast_gb}G"
}
export -f get_rss calc_fast_gb resolve_memmap

# ------------------------------------------------------------------------------
# Help Documentation
# ------------------------------------------------------------------------------
show_help() {
    echo "Usage: sudo $0 [target] [build|install|compile_only|update_grub|clean|purge] [--benchmark|-b <name>] [--ratio|-R <ratio>] [--memmap <param>] [--reboot|-r]"
    echo "       sudo $0 clean_grub"
    echo "       sudo $0 resolve_memmap <benchmark> <ratio>"
    echo ""
    echo "Actions:"
    echo "  build (default) Full build: auto-clone repo, compile, install kernel/modules, update GRUB & set default"
    echo "  install         Install kernel & modules from compiled source tree, update GRUB & set default (skip compile)"
    echo "  compile_only    Compile kernel & modules ONLY (no installation to /boot or /lib/modules, no GRUB changes)"
    echo "  update_grub     Only set GRUB default boot entry (without compiling or installing)"
    echo "  clean_grub      Clean all duplicate .old backup kernel images and links from /boot and update GRUB"
    echo "  clean / purge   Uninstall specified kernel target (or all) from /boot & /lib/modules, delete <dir>/linux source tree, and update GRUB"
    echo ""
    echo "Targets:"
    echo "  autonuma          AutoNUMA upstream kernel baseline (Linux 7.3.0-AutoNUMA)"
    echo "  autonuma-prefetch AutoNUMA with Pipelined Lookahead Prefetching (Linux 7.3.0-AutoNUMA-prefetch)"
    echo "  memtis            Memtis kernel baseline (Linux 5.15.19-Memtis)"
    echo "  memtis-prefetch   Memtis with Pipelined Lookahead Prefetching (Linux 5.15.19-Memtis-Prefetch)"
    echo "  nomad             Nomad kernel baseline (Linux 5.13.0-rc6-Nomad)"
    echo "  nomad-prefetch    Nomad with Pipelined Lookahead Prefetching (Linux 5.13.0-rc6-Nomad-Prefetch)"
    echo "  nomad-noinline    Nomad kernel baseline with noinline (Linux 5.13.0-rc6-Nomad-Noinline)"
    echo "  nomad-alto        Nomad kernel baseline with alto (Linux 5.13.0-rc6-Nomad-Alto)"
    echo "  nomad-alto-prefetch Nomad-alto with Pipelined Lookahead Prefetching (Linux 5.13.0-rc6-Nomad-Alto-Prefetch)"
    echo "  nomad-alto-noinline Nomad-alto with noinline (Linux 5.13.0-rc6-Nomad-Alto-Noinline)"
    echo "  tpp               TPP kernel baseline (Linux 5.15.0-TPP)"
    echo "  colloid-tpp       Colloid-tpp kernel baseline (Linux 6.3.0-Colloid-TPP)"
    echo "  colloid-tpp-alto  Colloid-tpp kernel baseline with alto (Linux 6.3.0-Colloid-TPP-Alto)"
    echo "  colloid-tpp-prefetch       Colloid-tpp with Pipelined Lookahead Prefetching (Linux 6.3.0-Colloid-TPP-prefetch)"
    echo "  colloid-tpp-alto-prefetch  Colloid-tpp-alto with Pipelined Lookahead Prefetching (Linux 6.3.0-Colloid-TPP-Alto-prefetch)"
    echo "  pact              PACT kernel baseline (Linux 6.3.0-PACT)"
    echo "  pact-prefetch     PACT with Pipelined Lookahead Prefetching (Linux 6.3.0-PACT-prefetch)"
    echo "  pact-prefetch-batch PACT with 512-Page Micro-Batch Prefetching (Linux 6.3.0-PACT-prefetch-Batch)"
    echo "  hybridtier        HybridTier kernel baseline (Linux 6.2.0-hybridtier+)"
    echo "  generic           Distro generic kernel"
    echo "  all               All baseline kernels"
    echo ""
    echo "Options:"
    echo "  -b, --benchmark <name>   Target benchmark (e.g. gapbs_bc_kron, xsbench, spec2026_*) for RSS calculation"
    echo "  -R, --ratio <ratio>      Tier ratio Fast:Slow relative to RSS (e.g. 1:1, 1:2, 1:4, 1:8, 4:1)"
    echo "  --memmap <param>         Explicit Linux memmap parameter (e.g. memmap=38G!10G)"
    echo "  -r, --reboot             Automatically reboot system after completing task"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  sudo $0 generic update_grub --benchmark gapbs_bc_kron --ratio 1:1 --reboot"
    echo "  sudo $0 colloid-tpp update_grub -b xsbench -R 1:2 --reboot"
    echo "  sudo $0 tpp update_grub --memmap memmap=32G!16G"
    echo "  sudo $0 clean_grub"
}

# ------------------------------------------------------------------------------
# Git Shallow Clone Helper & Kernel Repositories
# ------------------------------------------------------------------------------
clone_git_repo() {
    local kdir="$1"
    local name="$2"
    local branch="$3"
    local url="$4"
    local ref_dir="${5:-}"

    if [ ! -d "$kdir" ]; then
        echo -e "${CYAN}Linux folder missing at ${kdir}. Auto-cloning ${name} kernel tree (${branch})...${NC}"
        if [ -n "$ref_dir" ] && [ -d "${ref_dir}/.git" ] && git -C "${ref_dir}" rev-parse --verify "${branch}" >/dev/null 2>&1; then
            echo -e "${CYAN}Fast-cloning from local repository reference (${ref_dir})...${NC}"
            git clone --depth=1 --branch "${branch}" "${ref_dir}" "$kdir"
        else
            git clone --depth=1 --branch "${branch}" "${url}" "$kdir"
        fi
    fi
}

get_v513_ref() {
    for d in "${BASELINES_DIR}/nomad/linux" "${BASELINES_DIR}/nomad-alto/linux"; do
        [ -d "$d/.git" ] && echo "$d" && return
    done
}

get_v515_ref() {
    for d in "${BASELINES_DIR}/memtis/linux" "${BASELINES_DIR}/memtis-prefetch/linux"; do
        [ -d "$d/.git" ] && echo "$d" && return
    done
}

get_v63_ref() {
    for d in "${BASELINES_DIR}/colloid-tpp/linux" "${BASELINES_DIR}/colloid-tpp-prefetch/linux" "${BASELINES_DIR}/pact/linux" "${BASELINES_DIR}/pact-prefetch/linux"; do
        [ -d "$d/.git" ] && echo "$d" && return
    done
}

get_v73_ref() {
    for d in "${BASELINES_DIR}/autonuma/linux" "${BASELINES_DIR}/autonuma-prefetch/linux" "${BASELINES_DIR}/colloid-tpp/linux"; do
        [ -d "$d/.git" ] && echo "$d" && return
    done
}

clone_target() {
    local target="$1"
    local meta IFS='|'
    meta=$(get_kernel_meta "$target")
    read -r kdir fallback name <<< "$meta"

    [ -d "$kdir" ] && return 0

    local branch url ref_dir=""
    case "$target" in
        autonuma*)
            branch="v7.3"
            url="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
            ref_dir="$(get_v73_ref)"
            ;;
        memtis*)
            branch="v5.15.19"
            url="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
            ref_dir="$(get_v515_ref)"
            ;;
        nomad*)
            branch="v5.13-rc6"
            url="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
            ref_dir="$(get_v513_ref)"
            ;;
        tpp*)
            branch="v5.15"
            url="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
            ;;
        hybridtier*)
            branch="v6.2"
            url="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
            ref_dir="${BASELINES_DIR}/colloid-tpp/linux"
            ;;
        colloid*|pact*)
            branch="v6.3"
            url="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
            ref_dir="$(get_v63_ref)"
            ;;
        *)
            return 0
            ;;
    esac

    clone_git_repo "$kdir" "$name" "$branch" "$url" "$ref_dir"
}

# ------------------------------------------------------------------------------
# Release String Resolver
# ------------------------------------------------------------------------------
resolve_kernel_release() {
    local target="$1"
    local kdir="$2"
    local fallback="$3"
    local krelease=""

    if [ -d "$kdir" ] && [ -f "$kdir/.config" ]; then
        local tree_release
        tree_release=$(make -s -C "$kdir" kernelrelease 2>/dev/null || true)
        if [ -n "$tree_release" ] && matches_kernel_target "$target" "$tree_release"; then
            krelease="$tree_release"
        fi
    fi

    # Normalize -dirty if /lib/modules exists without -dirty
    if [ -n "$krelease" ] && [ ! -d "/lib/modules/${krelease}" ] && [ -d "/lib/modules/${krelease%-dirty}" ]; then
        krelease="${krelease%-dirty}"
    fi

    if [ -z "$krelease" ] || [ ! -f "/boot/vmlinuz-${krelease}" ]; then
        if [ "$target" == "generic" ]; then
            krelease=$(ls /boot/vmlinuz-*-generic 2>/dev/null | sort -V | tail -n 1 | sed 's|/boot/vmlinuz-||' || true)
        else
            for v in /boot/vmlinuz-*; do
                [ -f "$v" ] || continue
                local v_rel="${v#/boot/vmlinuz-}"
                if matches_kernel_target "$target" "$v_rel"; then
                    krelease="$v_rel"
                    break
                fi
            done
        fi
    fi

    [ -z "$krelease" ] && krelease="$fallback"
    echo "$krelease"
}

# ------------------------------------------------------------------------------
# Kernel Configuration & Boot Utility Functions
# ------------------------------------------------------------------------------
configure_single_socket_numa() {
    local kdir="$1"
    if [ -d "$kdir" ] && [ -f "$kdir/scripts/config" ]; then
        echo -e "${CYAN:-}Applying single-socket NUMA kernel configurations...${NC:-}"
        (
            cd "$kdir"
            scripts/config --enable SMP
            scripts/config --enable NUMA
            scripts/config --enable NUMA_BALANCING
            scripts/config --enable MEMCG
            scripts/config --enable NUMA_EMU
        )
    fi
}
export -f configure_single_socket_numa

generate_initramfs() {
    local krelease="$1"
    echo -e "${CYAN}Updating initramfs for ${krelease}...${NC}"
    update-initramfs -u -k "${krelease}" || update-initramfs -c -k "${krelease}" || true
}

clean_boot_backups() {
    rm -f /boot/vmlinuz*.old /boot/initrd.img*.old /boot/System.map*.old /boot/config*.old /boot/*.old /boot/*.bak 2>/dev/null || true
    find /boot -maxdepth 1 -xtype l -delete 2>/dev/null || true
}
export -f clean_boot_backups

strip_grub_custom_params() {
    local grub_file="${1:-/etc/default/grub}"
    [ -f "$grub_file" ] || return 0
    sed -i -E \
        -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\bmem=[0-9]+[kKmMgGtT]?[bB]?\b//g' \
        -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\bnuma=fake=[^ "]*/ /g' \
        -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\bmemmap=[^ "]*/ /g' \
        -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\bintel_idle\.max_cstate=[^ "]*/ /g' \
        -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\bprocessor\.max_cstate=[^ "]*/ /g' \
        -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\bidle=[^ "]*/ /g' \
        -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/[[:space:]]+/ /g' \
        -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/"[[:space:]]*/"/' \
        -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/[[:space:]]*"[[:space:]]*$/"/' \
        "$grub_file"
}

ensure_cpus_online() {
    for cpu_online in /sys/devices/system/cpu/cpu[0-9]*/online; do
        [ -f "$cpu_online" ] && echo 1 > "$cpu_online" 2>/dev/null || true
    done
}
export -f ensure_cpus_online

# ------------------------------------------------------------------------------
# Function: set_grub_default
# Description: Updates /etc/default/grub with the specified kernel boot entry,
#              applies NUMA memmap parameter, strips inactive kernels, and syncs GRUB.
# ------------------------------------------------------------------------------
set_grub_default() {
    local krelease="$1"
    local name="$2"

    echo -e "\n${CYAN}==> Updating GRUB configuration for ${name} (${krelease})...${NC}"

    # Backup original /etc/default/grub file if a backup does not already exist
    if [ ! -f /etc/default/grub.bak ]; then
        cp /etc/default/grub /etc/default/grub.bak
    fi

    # Dynamic or custom memmap resolution for Node 0 fast tier
    local memmap_param="${CUSTOM_MEMMAP:-memmap=32G!16G}"
    if [ -n "${BENCHMARK:-}" ] && [ -n "${RATIO:-}" ]; then
        memmap_param="$(resolve_memmap "$BENCHMARK" "$RATIO")"
    fi
    echo -e "${CYAN}Applying Node 0 fast-tier limit: ${memmap_param}${NC}"

    if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub; then
        strip_grub_custom_params /etc/default/grub
        sed -i -E \
            -e "/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\"$/ ${memmap_param}\"/" \
            -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/"[[:space:]]+/"/' \
            /etc/default/grub
    else
        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash ${memmap_param}\"" >> /etc/default/grub
    fi

    # Remove stale backup (.old) kernels and links so GRUB menu does not have duplicate entries
    clean_boot_backups

    # Remove all other custom kernels from /boot and /lib/modules excluding generic and the target kernel (skip during update_grub)
    if [ "$ACTION" != "update_grub" ]; then
        for vmlinuz in /boot/vmlinuz-*; do
            [ ! -f "$vmlinuz" ] && continue
            local kver="${vmlinuz#/boot/vmlinuz-}"

            # 1. Always preserve official Ubuntu generic kernels
            if [[ "$kver" == *generic* ]]; then
                continue
            fi

            # 2. Preserve the target kernel being switched to
            if [ -n "$krelease" ] && [ "$krelease" != "generic" ]; then
                local norm_kver="${kver%+}"
                norm_kver="${norm_kver%-dirty}"
                local norm_krel="${krelease%+}"
                norm_krel="${norm_krel%-dirty}"
                if [[ "$norm_kver" == "$norm_krel" || "$kver" == "$krelease" ]]; then
                    continue
                fi
            fi

            # 3. Remove inactive custom kernel from /boot & /lib/modules
            echo -e "${YELLOW}Removing inactive custom kernel '${kver}' from /boot & /lib/modules...${NC}"
            rm -f "/boot/vmlinuz-${kver}" "/boot/initrd.img-${kver}" "/boot/System.map-${kver}" "/boot/config-${kver}" \
                  "/boot/vmlinuz-${kver}.old" "/boot/initrd.img-${kver}.old" "/boot/System.map-${kver}.old" "/boot/config-${kver}.old" \
                  "/boot/vmlinuz-${kver}.bak" "/boot/initrd.img-${kver}.bak" "/boot/System.map-${kver}.bak" "/boot/config-${kver}.bak" 2>/dev/null || true
            rm -rf "/lib/modules/${kver}" "/lib/modules/${kver}+" "/lib/modules/${kver}-dirty" 2>/dev/null || true
        done
    fi

    # Clean any dangling links or backups left behind
    clean_boot_backups
    if [[ "$krelease" == "generic" || "$name" == "Generic" ]]; then
        [ -L /boot/vmlinuz ] && rm -f /boot/vmlinuz
        [ -L /boot/initrd.img ] && rm -f /boot/initrd.img
    fi

    # 1. First run update-grub to ensure /boot/grub/grub.cfg contains all installed kernels
    echo -e "${CYAN}Updating GRUB to discover installed kernels...${NC}"
    update-grub

    # Inspect /boot/grub/grub.cfg to find the exact submenu and menuentry titles
    local grub_cfg="/boot/grub/grub.cfg"
    local submenu_title=""
    local menu_title=""
    local grub_entry=""

    if [[ "$krelease" == "generic" || "$name" == "Generic" ]]; then
        grub_entry="0"
    else
        if [ -f "$grub_cfg" ]; then
            submenu_title=$(grep -E "^[[:space:]]*submenu ['\"]" "$grub_cfg" | head -n 1 | sed -E "s/^[[:space:]]*submenu ['\"]([^'\"]+)['\"].*/\1/" || true)

            # Extract all candidate menuentry titles (excluding recovery mode)
            local raw_titles=()
            while IFS= read -r title_line; do
                [ -n "$title_line" ] && raw_titles+=("$title_line")
            done < <(grep -E "^[[:space:]]*menuentry ['\"]" "$grub_cfg" | grep -v -i "recovery" | sed -E "s/^[[:space:]]*menuentry ['\"]([^'\"]+)['\"].*/\1/" || true)

            # Pass 1: Exact match where title ends with " $krelease" or is followed by space / parenthesis
            for t in "${raw_titles[@]}"; do
                if [[ "$t" == *" "*"${krelease}" || "$t" == *" "*"${krelease}"\ * || "$t" == *" "*"${krelease}"\(* ]]; then
                    menu_title="$t"
                    break
                fi
            done

            # Pass 2: Exact match handling '+' or '-dirty' suffix differences
            if [ -z "$menu_title" ]; then
                local base_krelease="${krelease%+}"
                base_krelease="${base_krelease%-dirty}"
                for t in "${raw_titles[@]}"; do
                    if [[ "$t" == *" "*"${base_krelease}" || "$t" == *" "*"${base_krelease}"\ * || "$t" == *" "*"${base_krelease}"\(* || \
                          "$t" == *" "*"${base_krelease}+"* || "$t" == *" "*"${base_krelease}-dirty"* ]]; then
                        menu_title="$t"
                        break
                    fi
                done
            fi

            # Pass 3: Fallback substring match only if exact match was not found
            if [ -z "$menu_title" ]; then
                for t in "${raw_titles[@]}"; do
                    if [[ "$t" == *"${krelease}"* ]]; then
                        # If target is non-prefetch, don't match a prefetch title
                        if [[ ! "$krelease" =~ prefetch && "$t" =~ prefetch ]]; then
                            continue
                        fi
                        menu_title="$t"
                        break
                    fi
                done
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
    fi

    echo -e "${CYAN}Setting GRUB default entry: '${grub_entry}'${NC}"
    sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${grub_entry}\"|" /etc/default/grub

    # 2. RUN update-grub AFTER modifying /etc/default/grub so the new default is compiled into /boot/grub/grub.cfg
    echo -e "${CYAN}Applying default entry into /boot/grub/grub.cfg...${NC}"
    update-grub

    # Execute grub-set-default to update grubenv
    grub-set-default "${grub_entry}" 2>/dev/null || grub-set-default "${krelease}" 2>/dev/null || true

    echo -e "${GREEN}==> Successfully set default boot kernel to ${name} (${krelease}) [GRUB_DEFAULT='${grub_entry}'].${NC}"
}

# ------------------------------------------------------------------------------
# Unified Post-Install Hook (Tier Modules, Daemons & Runtime Libs)
# ------------------------------------------------------------------------------
run_post_install_hook() {
    local target="$1"
    local kdir="$2"
    local base_target="${target%-prefetch}"
    base_target="${base_target%-batch}"
    local cdir="${BASELINES_DIR}/${base_target}"

    if [ -d "${cdir}/tierinit" ]; then
        echo -e "${CYAN}Building tierinit.ko for ${target}...${NC}"
        make -C "$kdir" M="${cdir}/tierinit" modules || true
    fi
    if [ -d "${cdir}/kswapdrst" ]; then
        echo -e "${CYAN}Building kswapdrst.ko for ${target}...${NC}"
        make -C "$kdir" M="${cdir}/kswapdrst" modules || true
    fi
    if [ -d "${cdir}/colloid-mon" ]; then
        echo -e "${CYAN}Building colloid-mon.ko for ${target}...${NC}"
        make -C "$kdir" M="${cdir}/colloid-mon" modules || true
    fi
    if [ -d "${cdir}/src" ]; then
        echo -e "${CYAN}Building runtime daemon for ${target}...${NC}"
        make -C "${cdir}/src" || true
    fi
    if [ -d "${cdir}/hook" ]; then
        echo -e "${CYAN}Building hook runtime libraries for ${target}...${NC}"
        make -C "${cdir}/hook" || true
    fi
}

# ------------------------------------------------------------------------------
# Kernel Installation & GRUB Set Default Pipeline
# ------------------------------------------------------------------------------
install_and_set_default() {
    local target="$1"
    local meta IFS='|'
    meta=$(get_kernel_meta "$target")
    read -r kdir fallback name <<< "$meta"

    # Ensure source tree is compiled for the exact requested target
    local tree_rel=""
    if [ -d "$kdir" ] && [ -f "$kdir/.config" ]; then
        tree_rel=$(make -s -C "$kdir" kernelrelease 2>/dev/null || true)
    fi
    if [ -z "$tree_rel" ] || ! matches_kernel_target "$target" "$tree_rel" || { [ ! -f "$kdir/arch/x86/boot/bzImage" ] && [ ! -f "$kdir/vmlinux" ]; }; then
        echo -e "${YELLOW}Source tree at ${kdir} holds '${tree_rel:-none}', which does not match '${target}'. Compiling '${target}' first...${NC}"
        compile_target "$target"
    fi

    local krelease
    krelease=$(resolve_kernel_release "$target" "$kdir" "$fallback")

    if [ -d "$kdir" ] && [ -f "$kdir/.config" ]; then
        echo -e "${CYAN}Installing ${name} modules and kernel...${NC}"
        make -C "$kdir" modules_install
        make -C "$kdir" install
        krelease=$(resolve_kernel_release "$target" "$kdir" "$krelease")
        generate_initramfs "${krelease}"
        run_post_install_hook "$target" "$kdir"
    fi
    set_grub_default "$krelease" "$name"
}

set_generic_default() {
    local krelease
    krelease=$(ls /boot/vmlinuz-*-generic 2>/dev/null | sort -V | tail -n 1 | sed 's|/boot/vmlinuz-||')
    [ -z "$krelease" ] && krelease="generic"
    set_grub_default "$krelease" "Generic"
}

set_target_default() {
    local target="$1"
    if [ "$target" == "generic" ]; then
        set_generic_default
    else
        install_and_set_default "$target"
    fi
}

# ------------------------------------------------------------------------------
# Unified Compile & Build Pipeline
# ------------------------------------------------------------------------------
compile_target() {
    local target="$1"
    if [ "$target" == "generic" ]; then
        echo -e "${GREEN}==> Target 'generic' uses the pre-installed Ubuntu distribution kernel (no compilation required).${NC}"
        return 0
    fi

    local meta IFS='|'
    meta=$(get_kernel_meta "$target")
    read -r kdir fallback name <<< "$meta"

    # Resolve unified baseline directory (e.g. tpp-prefetch -> tpp)
    local base_target="${target%-prefetch}"
    base_target="${base_target%-batch}"
    local dir="${BASELINES_DIR}/${base_target}"

    local script_name="compile.sh"
    if [[ "$target" =~ ^memtis ]]; then
        if [[ "$target" =~ prefetch ]]; then
            script_name="setup_memtis-prefetch.sh"
        else
            script_name="setup_memtis.sh"
        fi
    else
        if [[ "$target" =~ prefetch ]]; then
            script_name="compile-prefetch.sh"
        else
            script_name="compile.sh"
        fi
    fi

    echo -e "\n${BLUE}====================================================${NC}"
    echo -e "${BLUE} Compiling ${name} Kernel ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    if [ ! -f "${dir}/${script_name}" ]; then
        echo -e "${RED}Error: ${dir}/${script_name} not found.${NC}"
        exit 1
    fi
    clone_target "$target"
    echo -e "${CYAN}Running ${script_name}...${NC}"
    (cd "${dir}" && bash "${script_name}")
}

build_target() {
    local target="$1"
    if [ "$target" == "generic" ]; then
        set_generic_default
    else
        compile_target "$target" && set_target_default "$target"
    fi
}

update_target_grub() {
    local target="$1"
    if [ "$target" == "generic" ]; then
        set_generic_default
        return
    fi
    local meta IFS='|'
    meta=$(get_kernel_meta "$target")
    read -r kdir fallback name <<< "$meta"

    local krelease
    krelease=$(resolve_kernel_release "$target" "$kdir" "$fallback")

    # If the kernel image is already installed in /boot, update GRUB only (skip make install)
    if [ -f "/boot/vmlinuz-${krelease}" ]; then
        echo -e "${GREEN}Kernel '${krelease}' already installed in /boot. Skipping make install & updating GRUB only...${NC}"
        set_grub_default "$krelease" "$name"
    else
        echo -e "${YELLOW}Kernel '${krelease}' not found in /boot. Installing modules and kernel...${NC}"
        set_target_default "$target"
    fi
}

# Compatibility function aliases for terminal commands or external scripts
for _t in "${BASELINE_TARGETS[@]}"; do
    eval "set_${_t//-/_}_default() { set_target_default '$_t'; }"
    eval "compile_${_t//-/_}() { compile_target '$_t'; }"
    eval "install_${_t//-/_}() { set_target_default '$_t'; }"
    eval "build_${_t//-/_}() { build_target '$_t'; }"
    eval "clone_${_t//-/_}() { clone_target '$_t'; }"
done
unset _t

# ------------------------------------------------------------------------------
# Unified Kernel Uninstallation & GRUB Cleaning
# ------------------------------------------------------------------------------
_uninstall_target_files() {
    local target="$1"
    if [[ "$target" =~ ^(generic|distro|default)$ ]]; then
        echo -e "${YELLOW}Notice: 'generic' is the official Ubuntu distribution kernel and will never be removed.${NC}"
        return 0
    fi

    local meta IFS='|'
    meta=$(get_kernel_meta "$target")
    read -r kdir fallback name <<< "$meta"

    echo -e "${YELLOW}Uninstalling ${name} kernel from /boot, /lib/modules, and removing source tree...${NC}"

    for v in /boot/vmlinuz-*; do
        [ -f "$v" ] || continue
        local kver="${v#/boot/vmlinuz-}"
        [[ "$kver" == *generic* ]] && continue
        if matches_kernel_target "$target" "$kver"; then
            rm -f "/boot/vmlinuz-${kver}" "/boot/initrd.img-${kver}" "/boot/System.map-${kver}" "/boot/config-${kver}" \
                  "/boot/vmlinuz-${kver}.old" "/boot/initrd.img-${kver}.old" "/boot/System.map-${kver}.old" "/boot/config-${kver}.old" \
                  "/boot/vmlinuz-${kver}.bak" "/boot/initrd.img-${kver}.bak" "/boot/System.map-${kver}.bak" "/boot/config-${kver}.bak" 2>/dev/null || true
            rm -rf "/lib/modules/${kver}" "/lib/modules/${kver}+" "/lib/modules/${kver}-dirty" 2>/dev/null || true
        fi
    done

    local base_target="${target%-prefetch}"
    base_target="${base_target%-batch}"
    local target_dir="${BASELINES_DIR}/${base_target}"
    if [ "$target" == "$base_target" ] || [ "$target" == "all" ]; then
        rm -rf "${target_dir}/linux" "${target_dir}/log" 2>/dev/null || true
    fi
    rm -f "${target_dir}"/tierinit/*.ko "${target_dir}"/kswapdrst/*.ko "${target_dir}"/colloid-mon/*.ko "${target_dir}"/nomad_module/*.ko "${target_dir}"/hook/*.so 2>/dev/null || true
    [ -f "${target_dir}/src/pact" ] && rm -f "${target_dir}/src/pact" 2>/dev/null || true
}

clean_kernel() {
    local target="$1"
    echo -e "\n${BLUE}====================================================${NC}"
    echo -e "${BLUE} Cleaning GRUB & Kernel: '${target}' ${NC}"
    echo -e "${BLUE}====================================================${NC}"

    if [ "$target" == "all" ]; then
        echo -e "${YELLOW}Purging all custom baseline kernels from /boot, /lib/modules, and removing all source trees...${NC}"
        for t in "${BASELINE_TARGETS[@]}"; do
            _uninstall_target_files "$t"
        done
        [ -L /boot/vmlinuz ] && rm -f /boot/vmlinuz
        [ -L /boot/initrd.img ] && rm -f /boot/initrd.img
    elif [[ ! "$target" =~ ^(grub|clean_grub|old)$ ]]; then
        _uninstall_target_files "$target"
    fi

    clean_boot_backups

    echo -e "${CYAN}Resetting GRUB defaults and stripping custom kernel parameters from /etc/default/grub...${NC}"
    strip_grub_custom_params /etc/default/grub
    sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=0|" /etc/default/grub 2>/dev/null || true
    grub-set-default 0 2>/dev/null || true

    echo -e "${CYAN}Updating GRUB configuration...${NC}"
    update-grub
    echo -e "${GREEN}==> GRUB cleaned successfully.${NC}"
}

# ------------------------------------------------------------------------------
# Command Line Argument Parsing & Execution
# ------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Allow help and resolve_memmap to be displayed without root
    for arg in "$@"; do
        if [[ "$arg" == "--help" || "$arg" == "-h" || "$arg" == "help" ]]; then
            show_help
            exit 0
        fi
    done

    if [ "${1:-}" == "resolve_memmap" ]; then
        resolve_memmap "${2:-gapbs_bc_kron}" "${3:-1:1}"
        exit 0
    fi

    # Enforce root privileges for kernel management operations
    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}Notice: Root privileges are required to install kernels and update GRUB.${NC}"
        echo -e "${YELLOW}Re-running script with sudo...${NC}"
        exec sudo bash "$0" "$@"
    fi

    TARGET=""
    ACTION="build"
    AUTO_REBOOT=false
    BENCHMARK=""
    RATIO=""
    CUSTOM_MEMMAP=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --reboot|-r)
                AUTO_REBOOT=true
                shift
                ;;
            --benchmark|-b)
                BENCHMARK="$2"
                shift 2
                ;;
            --benchmark=*)
                BENCHMARK="${1#*=}"
                shift
                ;;
            --ratio|-R)
                RATIO="$2"
                shift 2
                ;;
            --ratio=*)
                RATIO="${1#*=}"
                shift
                ;;
            --memmap)
                CUSTOM_MEMMAP="$2"
                shift 2
                ;;
            --memmap=*)
                CUSTOM_MEMMAP="${1#*=}"
                shift
                ;;
            compile_only|compile-only|compile|build_only|build-only|--compile-only|-c)
                ACTION="compile_only"
                shift
                ;;
            install|install_only|install-only)
                ACTION="install"
                shift
                ;;
            build)
                ACTION="build"
                shift
                ;;
            update_grub|update-grub|set_default|set_grub|set_grub_default|select)
                ACTION="update_grub"
                shift
                ;;
            clean_grub|clean-grub|clean_old|clean-old)
                ACTION="clean"
                [ -z "$TARGET" ] && TARGET="grub"
                shift
                ;;
            clean|purge|uninstall|remove)
                ACTION="clean"
                shift
                ;;
            *)
                norm="${1,,}"
                norm="${norm//_/-}"
                case "$norm" in
                    colloid|colloid-tpp)           TARGET="colloid-tpp" ;;
                    colloid-alto|colloid-tpp-alto) TARGET="colloid-tpp-alto" ;;
                    nomad-noinline-alto)           TARGET="nomad-alto-noinline" ;;
                    distro|default|generic)        TARGET="generic" ;;
                    all)                           TARGET="all" ;;
                    *)
                        matched=false
                        for b in "${BASELINE_TARGETS[@]}"; do
                            if [ "$norm" == "$b" ]; then
                                TARGET="$b"
                                matched=true
                                break
                            fi
                        done
                        if [ "$matched" = false ]; then
                            echo -e "${RED}Error: Unknown argument '$1'.${NC}\n"
                            show_help
                            exit 1
                        fi
                        ;;
                esac
                shift
                ;;
        esac
    done

    # Validate that a target was specified (or default to grub for clean action)
    if [ -z "$TARGET" ]; then
        if [ "$ACTION" == "clean" ]; then
            TARGET="grub"
        else
            echo -e "${RED}Error: No kernel target specified (autonuma, autonuma-prefetch, memtis, nomad, nomad-noinline, nomad-alto, nomad-alto-noinline, tpp, colloid-tpp, colloid-tpp-alto, pact, hybridtier, generic, or all).${NC}\n"
            show_help
            exit 1
        fi
    fi

    # ------------------------------------------------------------------------------
    # Action Dispatcher
    # ------------------------------------------------------------------------------
    if [ "$ACTION" == "clean" ]; then
        clean_kernel "$TARGET"
    elif [ "$ACTION" == "update_grub" ]; then
        if [ "$TARGET" == "all" ]; then
            for t in "${BASELINE_TARGETS[@]}"; do
                update_target_grub "$t"
            done
        else
            update_target_grub "$TARGET"
        fi
    elif [ "$ACTION" == "install" ]; then
        if [ "$TARGET" == "all" ]; then
            for t in "${BASELINE_TARGETS[@]}"; do
                set_target_default "$t"
            done
        else
            set_target_default "$TARGET"
        fi
    elif [ "$ACTION" == "compile_only" ]; then
        if [ "$TARGET" == "all" ]; then
            for t in "${BASELINE_TARGETS[@]}"; do
                compile_target "$t"
            done
        else
            compile_target "$TARGET"
        fi
        echo -e "\n${GREEN}==> Kernel compilation completed successfully for target '${TARGET}' (no system installation or GRUB modification performed).${NC}"
    else
        if [ "$TARGET" == "all" ]; then
            for t in "${BASELINE_TARGETS[@]}"; do
                build_target "$t"
            done
        else
            build_target "$TARGET"
        fi
    fi

    # ------------------------------------------------------------------------------
    # Reboot Handling
    # ------------------------------------------------------------------------------
    if [ "$ACTION" != "compile_only" ]; then
        if [ "$AUTO_REBOOT" = true ]; then
            echo -e "\n${GREEN}Auto-reboot requested. Rebooting system in 3 seconds...${NC}"
            ensure_cpus_online
            sleep 3
            reboot
        else
            if [ -t 0 ]; then
                echo ""
                read -rp "Kernel task completed. Reboot into default kernel now? (y/N): " answer
                if [[ "$answer" =~ ^[Yy]$ ]]; then
                    echo -e "${GREEN}Rebooting system...${NC}"
                    ensure_cpus_online
                    reboot
                fi
            fi
        fi
    fi
fi
