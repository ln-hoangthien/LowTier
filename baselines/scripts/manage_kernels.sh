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
PACT_DIR="${BASELINES_DIR}/pact"
PACT_PREFETCH_DIR="${BASELINES_DIR}/pact-prefetch"
HYBRIDTIER_DIR="${BASELINES_DIR}/hybridtier"

# Formatting color definitions for terminal output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export NC='\033[0m' # No Color

# Baseline kernel target list
BASELINE_TARGETS=(memtis nomad nomad-noinline nomad-alto nomad-alto-noinline tpp colloid-tpp colloid-tpp-alto pact pact-prefetch hybridtier)

# Target metadata resolver: returns "kdir|fallback_release|display_name"
get_kernel_meta() {
    local target="$1"
    case "$target" in
        memtis)              echo "${MEMTIS_DIR}/linux|5.15.19-Memtis|Memtis" ;;
        nomad)               echo "${NOMAD_DIR}/linux|5.13.0-rc6-Nomad|Nomad" ;;
        nomad-noinline)      echo "${NOMAD_NOINLINE_DIR}/linux|5.13.0-rc6-Nomad-Noinline|Nomad-Noinline" ;;
        nomad-alto)          echo "${NOMAD_ALTO_DIR}/linux|5.13.0-rc6-Nomad-Alto|Nomad-Alto" ;;
        nomad-alto-noinline) echo "${NOMAD_ALTO_NOINLINE_DIR}/linux|5.13.0-rc6-Nomad-Alto-Noinline|Nomad-Alto-Noinline" ;;
        tpp)                 echo "${TPP_DIR}/linux|5.15.0-TPP|TPP" ;;
        colloid|colloid-tpp) echo "${COLLOID_TPP_DIR}/linux|6.3.0-Colloid-TPP|Colloid-tpp" ;;
        colloid-tpp-alto)    echo "${COLLOID_TPP_ALTO_DIR}/linux|6.3.0-Colloid-TPP-Alto|Colloid-tpp-alto" ;;
        pact)                echo "${PACT_DIR}/linux|6.3.0-PACT|PACT" ;;
        pact-prefetch)       echo "${PACT_PREFETCH_DIR}/linux|6.3.0-PACT-prefetch|PACT-prefetch" ;;
        hybridtier)          echo "${HYBRIDTIER_DIR}/linux|6.2.0-hybridtier+|HybridTier" ;;
        generic)             echo "/boot|generic|Generic" ;;
        *)                   echo "" ;;
    esac
}
export -f get_kernel_meta

# ------------------------------------------------------------------------------
# Helpers: Benchmark RSS and Fast-Tier Memmap Resolution
# ------------------------------------------------------------------------------
get_rss() {
    case "$1" in
        # --- GAPBS PageRank (PR) ---
        gapbs_pr_kron)        echo 18 ;;  # Measured: 17.75 GB
        gapbs_pr_urand)       echo 18 ;;  # Measured: 18.02 GB
        gapbs_pr_twitter)     echo 12 ;;  # Measured: 12.34 GB
        gapbs_pr_web)         echo 16 ;;  # Measured: 15.53 GB
        gapbs_pr_road)        echo 1  ;;  # Measured:  0.97 GB

        # --- GAPBS Triangle Counting (TC) ---
        gapbs_tc_kron)        echo 37 ;;  # Measured: 37.49 GB
        gapbs_tc_urand)       echo 18 ;;  # Measured: 18.00 GB
        gapbs_tc_twitter)     echo 21 ;;  # Measured: 20.72 GB
        gapbs_tc_web)         echo 29 ;;  # Measured: 29.28 GB
        gapbs_tc_road)        echo 1  ;;  # Measured:  0.58 GB

        # --- GAPBS Breadth-First Search (BFS) ---
        gapbs_bfs_kron)       echo 18 ;;  # Measured: 17.74 GB
        gapbs_bfs_urand)      echo 18 ;;  # Measured: 18.00 GB
        gapbs_bfs_twitter)    echo 12 ;;  # Measured: 12.32 GB
        gapbs_bfs_web)        echo 16 ;;  # Measured: 15.52 GB
        gapbs_bfs_road)       echo 1  ;;  # Measured:  0.98 GB

        # --- GAPBS Betweenness Centrality (BC) ---
        gapbs_bc_kron)        echo 19 ;;  # Measured: 19.46 GB
        gapbs_bc_urand)       echo 20 ;;  # Measured: 20.00 GB
        gapbs_bc_twitter)     echo 13 ;;  # Measured: 13.08 GB
        gapbs_bc_web)         echo 16 ;;  # Measured: 16.31 GB
        gapbs_bc_road)        echo 1  ;;  # Measured:  1.24 GB

        # --- GAPBS Connected Components (CC) ---
        gapbs_cc_kron)        echo 18 ;;  # Measured: 17.74 GB
        gapbs_cc_urand)       echo 18 ;;  # Measured: 18.00 GB
        gapbs_cc_twitter)     echo 12 ;;  # Measured: 12.32 GB
        gapbs_cc_web)         echo 16 ;;  # Measured: 15.52 GB
        gapbs_cc_road)        echo 1  ;;  # Measured:  0.97 GB

        # --- GAPBS Single-Source Shortest Paths (SSSP) ---
        gapbs_sssp_kron)      echo 34 ;;  # Measured: 33.77 GB
        gapbs_sssp_urand)     echo 36 ;;  # Measured: 35.63 GB
        gapbs_sssp_twitter)   echo 23 ;;  # Measured: 23.45 GB
        gapbs_sssp_web)       echo 30 ;;  # Measured: 30.13 GB
        gapbs_sssp_road)      echo 1  ;;  # Measured:  1.40 GB

        # --- Silo In-Memory OLTP Database ---
        silo_tpcc)            echo 18 ;;  # Measured: 17.9 GB
        silo_queue)           echo 57 ;;  # Measured: 57.13 GB
        silo_bid)             echo 50 ;;  # Measured: 49.43 GB (range: 48.84 - 52.44 GB)
        silo_ycsb)            echo 40 ;;  # Measured: 18.00 GB (multi-ratio: 17.29 - 18.92 GB)
        silo_encstress)       echo 12 ;;  # Measured: 12.25 GB

        # --- Microbenchmarks & Other Workloads ---
        redis)                echo 26 ;;  # Measured: 26.34 GB (4.3M keys @ 8KB payload)
        xsbench)              echo 18 ;;  # Measured: 18.06 GB
        stream|stream_hot|stream_phase*) echo 18 ;; # Measured: 17.88 GB

        # --- SPEC CPU 2026 Rate (r) Benchmarks ---
        spec2026_706.stockfish_r) echo 20 ;;  # Measured: 19.59 GB
        spec2026_707.ntest_r)     echo 3  ;;  # Measured:  2.62 GB
        spec2026_708.sqlite_r)    echo 14 ;;  # Measured: 13.90 GB
        spec2026_709.cactus_r)    echo 19 ;;  # Measured: 19.41 GB
        spec2026_710.omnetpp_r)   echo 9  ;;  # Measured:  8.84 GB
        spec2026_714.cpython_r)   echo 13 ;;  # Measured: 13.25 GB
        spec2026_721.gcc_r)       echo 15 ;;  # Measured: 14.63 GB
        spec2026_722.palm_r)      echo 21 ;;  # Measured: 20.65 GB
        spec2026_723.llvm_r)      echo 26 ;;  # Measured: 26.13 GB
        spec2026_727.cppcheck_r)  echo 9  ;;  # Measured:  8.99 GB
        spec2026_729.abc_r)       echo 17 ;;  # Measured: 17.00 GB
        spec2026_731.astcenc_r)   echo 4  ;;  # Measured:  3.68 GB
        spec2026_734.vpr_r)       echo 19 ;;  # Measured: 18.82 GB
        spec2026_735.gem5_r)      echo 14 ;;  # Measured: 14.48 GB
        spec2026_736.ocio_r)      echo 18 ;;  # Measured: 17.92 GB
        spec2026_737.gmsh_r)      echo 30 ;;  # Measured: 30.36 GB
        spec2026_748.flightdm_r)  echo 4  ;;  # Measured:  4.05 GB
        spec2026_749.fotonik3d_r) echo 20 ;;  # Measured: 20.22 GB
        spec2026_750.sealcrypto_r) echo 6 ;;  # Measured:  6.03 GB
        spec2026_753.ns3_r)       echo 10 ;;  # Measured:  9.50 GB
        spec2026_765.roms_r)      echo 14 ;;  # Measured: 13.63 GB
        spec2026_766.femflow_r)   echo 4  ;;  # Measured:  3.51 GB
        spec2026_767.nest_r)      echo 34 ;;  # Measured: 33.88 GB
        spec2026_772.marian_r)    echo 18 ;;  # Measured: 18.14 GB
        spec2026_777.zstd_r)      echo 5  ;;  # Measured:  5.24 GB
        spec2026_782.lbm_r)       echo 19 ;;  # Measured: 19.19 GB

        # --- SPEC CPU 2026 Speed (s) Benchmarks ---
        spec2026_800.pot3d_s)     echo 3  ;;  # Measured:  2.81 GB
        spec2026_801.xz_s)        echo 31 ;;  # Measured: 31.49 GB
        spec2026_803.sph_exa_s)   echo 25 ;;  # Measured: 25.17 GB
        spec2026_807.ntest_s)     echo 1  ;;  # Measured:  0.10 GB
        spec2026_809.cactus_s)    echo 5  ;;  # Measured:  5.44 GB
        spec2026_811.tealeaf_s)   echo 1  ;;  # Measured:  1.13 GB
        spec2026_816.nab_s)       echo 1  ;;  # Measured:  0.56 GB
        spec2026_817.flac_s)      echo 1  ;;  # Measured:  0.01 GB
        spec2026_820.cloverleaf_s) echo 22 ;; # Measured: 22.00 GB
        spec2026_821.gcc_s)       echo 1  ;;  # Measured:  1.45 GB
        spec2026_822.palm_s)      echo 23 ;;  # Measured: 22.63 GB
        spec2026_823.llvm_s)      echo 6  ;;  # Measured:  6.27 GB
        spec2026_827.cppcheck_s)  echo 1  ;;  # Measured:  1.05 GB
        spec2026_829.abc_s)       echo 13 ;;  # Measured: 12.71 GB
        spec2026_834.vpr_s)       echo 3  ;;  # Measured:  3.21 GB
        spec2026_835.gem5_s)      echo 1  ;;  # Measured:  0.59 GB
        spec2026_838.diamond_s)   echo 7  ;;  # Measured:  6.54 GB
        spec2026_846.minizinc_s)  echo 18 ;;  # Measured: 18.00 GB
        spec2026_849.fotonik3d_s) echo 48 ;;  # Measured: 47.53 GB
        spec2026_853.ns3_s)       echo 1  ;;  # Measured:  0.31 GB
        spec2026_854.graph500_s)  echo 35 ;;  # Measured: 35.13 GB
        spec2026_857.namd_s)      echo 2  ;;  # Measured:  2.40 GB
        spec2026_865.roms_s)      echo 23 ;;  # Measured: 22.62 GB
        spec2026_867.nest_s)      echo 23 ;;  # Measured: 22.65 GB
        spec2026_872.marian_s)    echo 8  ;;  # Measured:  8.24 GB
        spec2026_881.neutron_s)   echo 49 ;;  # Measured: 49.20 GB
        spec_mcf|spec_cpu)        echo 18 ;;  # Default SPEC CPU fallback

        # --- Fallback Default ---
        *)                    echo 20 ;;  # Default: 20 GB
    esac
}

calc_fast_gb() {
    local rss="$1" ratio="${2:-1:1}"
    local f="${ratio%%:*}" s="${ratio##*:}"
    local os_headroom="${OS_HEADROOM:-6}"
    local min_fast="${MIN_FAST:-1}"
    awk -v rss="$rss" -v f="$f" -v s="$s" -v os="$os_headroom" -v min_f="$min_fast" 'BEGIN {
        wl_fast = (rss * f) / (f + s);
        fast = int(wl_fast + os + 0.5);
        if (fast < min_f) fast = min_f;
        if (fast > 120) fast = 120;
        print fast;
    }'
}

resolve_memmap() {
    local bench="$1" ratio="${2:-1:1}"
    local rss fast_gb
    rss=$(get_rss "$bench")
    fast_gb=$(calc_fast_gb "$rss" "$ratio")
    echo "memmap=$((128 - fast_gb))G!${fast_gb}G"
}
export -f get_rss calc_fast_gb resolve_memmap

# ------------------------------------------------------------------------------
# Function: show_help
# Description: Displays command line usage information, available actions,
#              supported targets, optional flags, and usage examples.
# ------------------------------------------------------------------------------
show_help() {
    echo "Usage: sudo $0 [target] [build|compile_only|update_grub|clean|purge] [--benchmark|-b <name>] [--ratio|-R <ratio>] [--memmap <param>] [--reboot|-r]"
    echo "       sudo $0 clean_grub"
    echo "       sudo $0 resolve_memmap <benchmark> <ratio>"
    echo ""
    echo "Actions:"
    echo "  build (default) Full build: auto-clone repo, compile, install kernel/modules, update GRUB & set default"
    echo "  compile_only    Compile kernel & modules ONLY (no installation to /boot or /lib/modules, no GRUB changes)"
    echo "  update_grub     Only set GRUB default boot entry (without compiling or installing)"
    echo "  clean_grub      Clean all duplicate .old backup kernel images and links from /boot and update GRUB"
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
    echo "  pact              PACT kernel baseline (Linux 6.3.0-PACT)"
    echo "  pact-prefetch     PACT with Throttled NTA Prefetch (Linux 6.3.0-PACT-prefetch)"
    echo "  hybridtier        HybridTier kernel baseline (Linux 6.2.0-hybridtier+)"
    echo "  generic           Distro generic kernel"
    echo "  all               All baseline kernels"
    echo ""
    echo "Options:"
    echo "  -b, --benchmark <name>   Target benchmark (e.g. gapbs_bc_kron, xsbench, spec2026_*) for RSS calculation"
    echo "  -R, --ratio <ratio>      Tier ratio Fast:Slow relative to RSS (e.g. 1:1, 1:2, 1:4, 1:8, 4:1)"
    echo "  --memmap <param>         Explicit Linux memmap parameter (e.g. memmap=118G!10G)"
    echo "  -r, --reboot             Automatically reboot system after completing task"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  sudo $0 generic update_grub --benchmark gapbs_bc_kron --ratio 1:1 --reboot"
    echo "  sudo $0 colloid-tpp update_grub -b xsbench -R 1:2 --reboot"
    echo "  sudo $0 tpp update_grub --memmap memmap=112G!16G"
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

clone_memtis() { clone_git_repo "${MEMTIS_DIR}/linux" "Memtis" "v5.15.19" "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"; }
clone_nomad() { clone_git_repo "${NOMAD_DIR}/linux" "Nomad" "v5.13-rc6" "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"; }
clone_nomad_noinline() { clone_git_repo "${NOMAD_NOINLINE_DIR}/linux" "Nomad-Noinline" "v5.13-rc6" "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"; }
clone_nomad_alto() { clone_git_repo "${NOMAD_ALTO_DIR}/linux" "Nomad-Alto" "v5.13-rc6" "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"; }
clone_nomad_alto_noinline() { clone_git_repo "${NOMAD_ALTO_NOINLINE_DIR}/linux" "Nomad-Alto-Noinline" "v5.13-rc6" "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"; }
clone_tpp() { clone_git_repo "${TPP_DIR}/linux" "TPP" "v5.15" "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"; }
clone_colloid_tpp() { clone_git_repo "${COLLOID_TPP_DIR}/linux" "Colloid-tpp" "v6.3" "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"; }
clone_colloid_tpp_alto() { clone_git_repo "${COLLOID_TPP_ALTO_DIR}/linux" "Colloid-tpp-alto" "v6.3" "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"; }
clone_pact() { clone_git_repo "${PACT_DIR}/linux" "PACT" "v6.3" "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git" "${COLLOID_TPP_DIR}/linux"; }
clone_pact_prefetch() { clone_git_repo "${PACT_PREFETCH_DIR}/linux" "PACT-prefetch" "v6.3" "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git" "${PACT_DIR}/linux"; }
clone_hybridtier() { clone_git_repo "${HYBRIDTIER_DIR}/linux" "HybridTier" "v6.2" "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git" "${COLLOID_TPP_DIR}/linux"; }


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
            pact)
                installed=$(ls /boot/vmlinuz-* 2>/dev/null | grep -i "pact" | grep -iv "prefetch" | head -n 1 | sed 's|/boot/vmlinuz-||' || true)
                ;;
            pact-prefetch)
                installed=$(ls /boot/vmlinuz-* 2>/dev/null | grep -i "pact" | grep -i "prefetch" | head -n 1 | sed 's|/boot/vmlinuz-||' || true)
                ;;
            hybridtier)
                installed=$(ls /boot/vmlinuz-* 2>/dev/null | grep -i "hybridtier" | head -n 1 | sed 's|/boot/vmlinuz-||' || true)
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
# Function: clean_boot_backups
# Description: Removes backup (.old/.bak) kernel images and broken symlinks from /boot.
# ------------------------------------------------------------------------------
clean_boot_backups() {
    rm -f /boot/vmlinuz*.old /boot/initrd.img*.old /boot/System.map*.old /boot/config*.old /boot/*.old /boot/*.bak 2>/dev/null || true
    find /boot -maxdepth 1 -xtype l -delete 2>/dev/null || true
}
export -f clean_boot_backups

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

    # Dynamic or custom memmap resolution for Node 0 fast tier
    local memmap_param="${CUSTOM_MEMMAP:-memmap=112G!16G}"
    if [ -n "${BENCHMARK:-}" ] && [ -n "${RATIO:-}" ]; then
        memmap_param="$(resolve_memmap "$BENCHMARK" "$RATIO")"
    fi
    echo -e "${CYAN}Applying Node 0 fast-tier limit: ${memmap_param}${NC}"

    if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub; then
        # Atomic clean pass: strip mem=, numa=fake=, and memmap= parameters, normalize spacing, and append target memmap
        sed -i -E \
            -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\bmem=[0-9]+[kKmMgGtT]?[bB]?\b//g' \
            -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\bnuma=fake=[^ "]*//g' \
            -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\bmemmap=[^ "]*//g' \
            -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/[[:space:]]+/ /g' \
            -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/"[[:space:]]*/"/' \
            -e '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/[[:space:]]*"[[:space:]]*$/"/' \
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
            local kver
            kver=$(basename "$vmlinuz" | sed 's/^vmlinuz-//')

            # 1. Always preserve official Ubuntu generic kernels
            if [[ "$kver" == *generic* ]]; then
                continue
            fi

            # 2. Preserve the target kernel being switched to
            if [ -n "$krelease" ] && [ "$krelease" != "generic" ]; then
                if [[ "$kver" == "$krelease" || "$kver" == *"$krelease"* || "$krelease" == *"$kver"* ]]; then
                    continue
                fi
            fi

            # 3. Remove inactive custom kernel from /boot & /lib/modules
            echo -e "${YELLOW}Removing inactive custom kernel '${kver}' from /boot & /lib/modules...${NC}"
            rm -f "/boot/vmlinuz-${kver}"* "/boot/initrd.img-${kver}"* "/boot/System.map-${kver}"* "/boot/config-${kver}"* 2>/dev/null || true
            rm -rf "/lib/modules/${kver}" 2>/dev/null || true
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
            # Find the exact menuentry matching krelease without regex operator issues (e.g. trailing +)
            menu_title=$(grep -E "^[[:space:]]*menuentry ['\"]" "$grub_cfg" | grep -v -i "recovery" | grep -F "${krelease}" | head -n 1 | sed -E "s/^[[:space:]]*menuentry ['\"]([^'\"]+)['\"].*/\1/" || true)
            if [ -z "$menu_title" ]; then
                local base_krelease="${krelease%+}"
                menu_title=$(grep -E "^[[:space:]]*menuentry ['\"]" "$grub_cfg" | grep -v -i "recovery" | grep -F "${base_krelease}" | head -n 1 | sed -E "s/^[[:space:]]*menuentry ['\"]([^'\"]+)['\"].*/\1/" || true)
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
# Kernel Installation & GRUB Default Helpers
# ------------------------------------------------------------------------------
install_and_set_default() {
    local target="$1"
    local extra_hook="${2:-}"
    local meta IFS='|'
    meta=$(get_kernel_meta "$target")
    read -r kdir fallback name <<< "$meta"

    local krelease
    krelease=$(resolve_kernel_release "$target" "$kdir" "$fallback")

    if [ -d "$kdir" ] && [ -f "$kdir/.config" ]; then
        echo -e "${CYAN}Installing ${name} modules and kernel...${NC}"
        make -C "$kdir" modules_install
        make -C "$kdir" install
        krelease=$(resolve_kernel_release "$target" "$kdir" "$krelease")
        generate_initramfs "${krelease}"

        if [ -n "$extra_hook" ]; then
            "$extra_hook" "$kdir"
        fi
    fi
    set_grub_default "$krelease" "$name"
}

_pact_post_install() {
    local kdir="$1"
    if [ -d "${PACT_DIR}/tierinit" ]; then
        echo -e "${CYAN}Building PACT tierinit.ko...${NC}"
        make -C "$kdir" M="${PACT_DIR}/tierinit" modules || true
    fi
    if [ -d "${PACT_DIR}/kswapdrst" ]; then
        echo -e "${CYAN}Building PACT kswapdrst.ko...${NC}"
        make -C "$kdir" M="${PACT_DIR}/kswapdrst" modules || true
    fi
    if [ -d "${PACT_DIR}/src" ]; then
        echo -e "${CYAN}Building PACT user-space runtime daemon...${NC}"
        make -C "${PACT_DIR}/src" || true
    fi
}

_pact_prefetch_post_install() {
    local kdir="$1"
    if [ -d "${PACT_PREFETCH_DIR}/tierinit" ]; then
        echo -e "${CYAN}Building PACT-prefetch tierinit.ko...${NC}"
        make -C "$kdir" M="${PACT_PREFETCH_DIR}/tierinit" modules || true
    fi
    if [ -d "${PACT_PREFETCH_DIR}/kswapdrst" ]; then
        echo -e "${CYAN}Building PACT-prefetch kswapdrst.ko...${NC}"
        make -C "$kdir" M="${PACT_PREFETCH_DIR}/kswapdrst" modules || true
    fi
    if [ -d "${PACT_PREFETCH_DIR}/src" ]; then
        echo -e "${CYAN}Building PACT-prefetch user-space runtime daemon...${NC}"
        make -C "${PACT_PREFETCH_DIR}/src" || true
    fi
}

_hybridtier_post_install() {
    local kdir="$1"
    if [ -d "${HYBRIDTIER_DIR}/hook" ]; then
        echo -e "${CYAN}Building HybridTier hook runtime libraries...${NC}"
        make -C "${HYBRIDTIER_DIR}/hook" || true
    fi
}

set_memtis_default() { install_and_set_default "memtis"; }
set_nomad_default() { install_and_set_default "nomad"; }
set_nomad_noinline_default() { install_and_set_default "nomad-noinline"; }
set_nomad_alto_default() { install_and_set_default "nomad-alto"; }
set_nomad_alto_noinline_default() { install_and_set_default "nomad-alto-noinline"; }
set_tpp_default() { install_and_set_default "tpp"; }
set_colloid_tpp_default() { install_and_set_default "colloid-tpp"; }
set_colloid_tpp_alto_default() { install_and_set_default "colloid-tpp-alto"; }
set_pact_default() { install_and_set_default "pact" _pact_post_install; }
set_pact_prefetch_default() { install_and_set_default "pact-prefetch" _pact_prefetch_post_install; }
set_hybridtier_default() { install_and_set_default "hybridtier" _hybridtier_post_install; }

set_generic_default() {
    local krelease
    krelease=$(ls /boot/vmlinuz-*-generic 2>/dev/null | sort -V | tail -n 1 | sed 's|/boot/vmlinuz-||')
    [ -z "$krelease" ] && krelease="generic"
    set_grub_default "$krelease" "Generic"
}


# ------------------------------------------------------------------------------
# Compile Pipeline Functions
# ------------------------------------------------------------------------------
compile_baseline_kernel() {
    local name="$1"
    local dir="$2"
    local script_name="${3:-compile.sh}"
    local clone_fn="$4"

    echo -e "\n${BLUE}====================================================${NC}"
    echo -e "${BLUE} Compiling ${name} Kernel ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    if [ ! -f "${dir}/${script_name}" ]; then
        echo -e "${RED}Error: ${dir}/${script_name} not found.${NC}"
        exit 1
    fi
    "$clone_fn"
    echo -e "${CYAN}Running ${script_name}...${NC}"
    (cd "${dir}" && bash "${script_name}")
}

compile_memtis() { compile_baseline_kernel "Memtis" "${MEMTIS_DIR}" "setup_memtis.sh" clone_memtis; }
compile_nomad() { compile_baseline_kernel "Nomad" "${NOMAD_DIR}" "compile.sh" clone_nomad; }
compile_nomad_noinline() { compile_baseline_kernel "Nomad-Noinline" "${NOMAD_NOINLINE_DIR}" "compile.sh" clone_nomad_noinline; }
compile_nomad_alto() { compile_baseline_kernel "Nomad-Alto" "${NOMAD_ALTO_DIR}" "compile.sh" clone_nomad_alto; }
compile_nomad_alto_noinline() { compile_baseline_kernel "Nomad-Alto-Noinline" "${NOMAD_ALTO_NOINLINE_DIR}" "compile.sh" clone_nomad_alto_noinline; }
compile_tpp() { compile_baseline_kernel "TPP" "${TPP_DIR}" "compile.sh" clone_tpp; }
compile_colloid_tpp() { compile_baseline_kernel "Colloid-tpp" "${COLLOID_TPP_DIR}" "compile.sh" clone_colloid_tpp; }
compile_colloid_tpp_alto() { compile_baseline_kernel "Colloid-tpp-alto" "${COLLOID_TPP_ALTO_DIR}" "compile.sh" clone_colloid_tpp_alto; }
compile_pact() { compile_baseline_kernel "PACT" "${PACT_DIR}" "compile.sh" clone_pact; }
compile_pact_prefetch() { compile_baseline_kernel "PACT-prefetch" "${PACT_PREFETCH_DIR}" "compile.sh" clone_pact_prefetch; }
compile_hybridtier() { compile_baseline_kernel "HybridTier" "${HYBRIDTIER_DIR}" "compile.sh" clone_hybridtier; }

# ------------------------------------------------------------------------------
# Full Build Pipeline Functions (Compile + Install + GRUB Default)
# ------------------------------------------------------------------------------
build_memtis() { compile_memtis && set_memtis_default; }
build_nomad() { compile_nomad && set_nomad_default; }
build_nomad_noinline() { compile_nomad_noinline && set_nomad_noinline_default; }
build_nomad_alto() { compile_nomad_alto && set_nomad_alto_default; }
build_nomad_alto_noinline() { compile_nomad_alto_noinline && set_nomad_alto_noinline_default; }
build_tpp() { compile_tpp && set_tpp_default; }
build_colloid_tpp() { compile_colloid_tpp && set_colloid_tpp_default; }
build_colloid_tpp_alto() { compile_colloid_tpp_alto && set_colloid_tpp_alto_default; }
build_pact() { compile_pact && set_pact_default; }
build_pact_prefetch() { compile_pact_prefetch && set_pact_prefetch_default; }
build_hybridtier() { compile_hybridtier && set_hybridtier_default; }

# ------------------------------------------------------------------------------
# Function: update_target_grub
# Description: Directly sets GRUB default if the kernel image already exists
#              in /boot, otherwise triggers full module/kernel installation.
# ------------------------------------------------------------------------------
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
        "set_${target//-/_}_default"
    fi
}

# ------------------------------------------------------------------------------
# Function: clean_kernel
# Description: Removes .old backup files, and optionally uninstalls specific
#              or all custom baseline kernels from /boot and /lib/modules,
#              then updates GRUB.
# ------------------------------------------------------------------------------
_uninstall_target_files() {
    local target="$1"
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
        colloid|colloid-tpp)
            echo -e "${YELLOW}Uninstalling Colloid-tpp kernel from /boot, /lib/modules, and removing source tree...${NC}"
            rm -rf /boot/*Colloid-TPP* /boot/*6.3.0 /boot/*6.3.0.* /lib/modules/*Colloid-TPP* /lib/modules/*6.3.0 "${COLLOID_TPP_DIR}/linux" "${COLLOID_TPP_DIR}/log" 2>/dev/null || true
            ;;
        colloid-tpp-alto)
            echo -e "${YELLOW}Uninstalling Colloid-tpp-alto kernel from /boot, /lib/modules, and removing source tree...${NC}"
            rm -rf /boot/*Colloid-TPP-Alto* /lib/modules/*Colloid-TPP-Alto* "${COLLOID_TPP_ALTO_DIR}/linux" "${COLLOID_TPP_ALTO_DIR}/log" 2>/dev/null || true
            ;;
        pact)
            echo -e "${YELLOW}Uninstalling PACT kernel from /boot, /lib/modules, and removing source tree...${NC}"
            rm -rf /boot/*PACT* /boot/*pact* /lib/modules/*PACT* /lib/modules/*pact* "${PACT_DIR}/linux" "${PACT_DIR}/log" "${PACT_DIR}/tierinit"/*.ko "${PACT_DIR}/kswapdrst"/*.ko "${PACT_DIR}/src/pact" 2>/dev/null || true
            ;;
        pact-prefetch)
            echo -e "${YELLOW}Uninstalling PACT-prefetch kernel from /boot, /lib/modules, and removing source tree...${NC}"
            rm -rf /boot/*PACT-prefetch* /boot/*pact-prefetch* /lib/modules/*PACT-prefetch* /lib/modules/*pact-prefetch* "${PACT_PREFETCH_DIR}/linux" "${PACT_PREFETCH_DIR}/log" "${PACT_PREFETCH_DIR}/tierinit"/*.ko "${PACT_PREFETCH_DIR}/kswapdrst"/*.ko "${PACT_PREFETCH_DIR}/src/pact" 2>/dev/null || true
            ;;
        hybridtier)
            echo -e "${YELLOW}Uninstalling HybridTier kernel from /boot, /lib/modules, and removing source tree...${NC}"
            rm -rf /boot/*hybridtier* /boot/*HybridTier* /lib/modules/*hybridtier* /lib/modules/*HybridTier* "${HYBRIDTIER_DIR}/linux" "${HYBRIDTIER_DIR}/log" "${HYBRIDTIER_DIR}/hook"/*.so 2>/dev/null || true
            ;;
    esac
}

clean_kernel() {
    local target="$1"
    echo -e "\n${BLUE}====================================================${NC}"
    echo -e "${BLUE} Cleaning GRUB & Kernel: '${target}' ${NC}"
    echo -e "${BLUE}====================================================${NC}"

    clean_boot_backups

    if [ "$target" == "all" ]; then
        echo -e "${YELLOW}Purging all custom baseline kernels from /boot, /lib/modules, and removing all source trees...${NC}"
        for t in "${BASELINE_TARGETS[@]}"; do
            _uninstall_target_files "$t"
        done
        [ -L /boot/vmlinuz ] && rm -f /boot/vmlinuz
        [ -L /boot/initrd.img ] && rm -f /boot/initrd.img
        sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=0|" /etc/default/grub 2>/dev/null || true
    elif [[ "$target" =~ ^(grub|clean_grub|old)$ ]]; then
        echo -e "${GREEN}Cleaned all duplicate .old entries and links from /boot.${NC}"
    else
        _uninstall_target_files "$target"
    fi

    clean_boot_backups

    echo -e "${CYAN}Updating GRUB configuration...${NC}"
    update-grub
    echo -e "${GREEN}==> GRUB cleaned successfully.${NC}"
}


# ------------------------------------------------------------------------------
# Command Line Argument Parsing
# Defaults: ACTION="build", TARGET="", AUTO_REBOOT=false
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
            --help|-h|help)
                show_help
                exit 0
                ;;
            resolve_memmap)
                resolve_memmap "${2:-gapbs_bc_kron}" "${3:-1:1}"
                exit 0
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
            memtis|nomad|nomad-noinline|nomad-alto|nomad_alto|nomad-alto-noinline|nomad_alto_noinline|nomad-noinline-alto|nomad_noinline_alto|tpp|colloid-tpp|colloid_tpp|colloid|colloid-tpp-alto|colloid_tpp_alto|colloid-alto|colloid_alto|pact|pact-prefetch|pact_prefetch|hybridtier|generic|distro|default|all)
                TARGET="${1,,}" # Convert target name to lowercase
                if [[ "$TARGET" == "colloid_tpp" || "$TARGET" == "colloid" ]]; then
                    TARGET="colloid-tpp"
                elif [[ "$TARGET" == "colloid_tpp_alto" || "$TARGET" == "colloid-alto" || "$TARGET" == "colloid_alto" ]]; then
                    TARGET="colloid-tpp-alto"
                elif [[ "$TARGET" == "nomad_alto" ]]; then
                    TARGET="nomad-alto"
                elif [[ "$TARGET" == "nomad-alto-noinline" || "$TARGET" == "nomad_alto_noinline" || "$TARGET" == "nomad-noinline-alto" || "$TARGET" == "nomad_noinline_alto" ]]; then
                    TARGET="nomad-alto-noinline"
                elif [[ "$TARGET" == "pact_prefetch" ]]; then
                    TARGET="pact-prefetch"
                elif [[ "$TARGET" == "distro" || "$TARGET" == "default" ]]; then
                    TARGET="generic"
                fi
                shift
                ;;
            *)
                echo -e "${RED}Error: Unknown argument '$1'.${NC}\n"
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
            echo -e "${RED}Error: No kernel target specified (memtis, nomad, nomad-noinline, nomad-alto, nomad-alto-noinline, tpp, colloid-tpp, colloid-tpp-alto, pact, hybridtier, generic, or all).${NC}\n"
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
        if [ "$TARGET" == "all" ]; then
            for t in "${BASELINE_TARGETS[@]}"; do
                update_target_grub "$t"
            done
        else
            update_target_grub "$TARGET"
        fi
    elif [ "$ACTION" == "compile_only" ]; then
        if [ "$TARGET" == "all" ]; then
            for t in "${BASELINE_TARGETS[@]}"; do
                "compile_${t//-/_}"
            done
        elif [ "$TARGET" == "generic" ]; then
            echo -e "${GREEN}==> Target 'generic' uses the pre-installed Ubuntu distribution kernel (no compilation required).${NC}"
        else
            "compile_${TARGET//-/_}"
        fi
        echo -e "\n${GREEN}==> Kernel compilation completed successfully for target '${TARGET}' (no system installation or GRUB modification performed).${NC}"
    else
        if [ "$TARGET" == "all" ]; then
            for t in "${BASELINE_TARGETS[@]}"; do
                "build_${t//-/_}"
            done
        elif [ "$TARGET" == "generic" ]; then
            set_generic_default
        else
            "build_${TARGET//-/_}"
        fi
    fi

    # ------------------------------------------------------------------------------
    # Reboot Prompt & Handling
    # Handles automatic reboot if --reboot was passed, or prompts interactively.
    # ------------------------------------------------------------------------------
    if [ "$ACTION" != "compile_only" ]; then
        # Ensure all CPUs are online before rebooting to prevent Intel PCU warm-reset hangs
        ensure_cpus_online() {
            for cpu_online in /sys/devices/system/cpu/cpu[0-9]*/online; do
                [ -f "$cpu_online" ] && echo 1 > "$cpu_online" 2>/dev/null || true
            done
        }

        if [ "$AUTO_REBOOT" = true ]; then
            echo -e "\n${GREEN}Auto-reboot requested. Rebooting system in 3 seconds...${NC}"
            ensure_cpus_online
            sleep 3
            reboot
        else
            # Check if standard input is attached to an interactive terminal
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
