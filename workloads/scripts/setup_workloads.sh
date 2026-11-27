#!/bin/bash
# ===================================================================
# Master Workload Setup & Build Script
# Usage: sudo ./setup_workloads.sh [--help] [TARGET [ARGS...]]
# Targets: stream | gapbs | silo | redis | xsbench | spec2026 | prebuild | all
# ===================================================================

set -e

# Base directories and build concurrency
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
WORKLOAD_DIR="${ROOT_DIR}/workloads"
REGRESSION_LIST="${REGRESSION_LIST:-${ROOT_DIR}/regression/regression_list}"
SPEC2026_DIR="${SPEC2026_DIR:-${WORKLOAD_DIR}/spec2026}"
SPEC_CONFIG="${SPEC_CONFIG:-${WORKLOAD_DIR}/scripts/gcc-linux-x86.cfg}"
NUM_JOBS="$(nproc)"
BUILT_DIRS=()

# Output color formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Require root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}ERROR: This script must be run with root/sudo privileges.${NC}"
        echo "Usage: sudo ./setup_workloads.sh [TARGET [ARGS...]]"
        exit 1
    fi
}

show_help() {
    echo "=========================================================================================="
    echo " Workload Cloning, Setup & Compilation Script"
    echo "=========================================================================================="
    echo "Usage:"
    echo "  sudo ./setup_workloads.sh [TARGET [ARGS...]]"
    echo ""
    echo "Available Targets:"
    echo "  stream         Build STREAM benchmarks (stream, stream_copy)"
    echo "  gapbs          Clone & Build GAPBS binaries + graph datasets if missing"
    echo "  silo           Clone & Build Silo OLTP Database (dbtest)"
    echo "  redis          Clone & Build Redis In-Memory Key-Value Server"
    echo "  xsbench        Clone & Build XSBench Nuclear Reactor Simulation Benchmark"
    echo "  spec2026       Clean & pre-build SPEC CPU 2026 targets (args or regression_list)"
    echo "  prebuild       Clean & pre-build benchmarks listed as args (or regression_list)"
    echo "  all            Setup and compile ALL workloads [Default]"
    echo "=========================================================================================="
    exit 0
}

if [ "${1:-}" == "-h" ] || [ "${1:-}" == "--help" ]; then
    show_help
fi

# Ensure root permissions before executing setup
check_root

# Allow git operations across mismatched users under sudo
git config --global safe.directory '*' 2>/dev/null || true

# Detect host GCC major version
GCC_MAJOR=$(gcc -dumpversion | cut -d. -f1)

# Reset repo to clean state
clean_repo() {
    if [ -d ".git" ]; then
        git reset --hard HEAD 2>/dev/null || true
        git clean -fd 2>/dev/null || true
    fi
}

# -------------------------------------------------------------------
# STREAM: Memory bandwidth benchmark (Classic, Hot, Phases)
# -------------------------------------------------------------------
setup_stream() {
    echo ""
    echo "-------------------------------------------------------------------"
    echo " Building STREAM Workloads..."
    echo "-------------------------------------------------------------------"
    if [ ! -d "${WORKLOAD_DIR}/stream" ]; then
        echo "Cloning STREAM repository..."
        git clone https://github.com/jeffhammond/STREAM.git "${WORKLOAD_DIR}/stream"
    fi
    cd "${WORKLOAD_DIR}/stream"
    if [ -f "Makefile" ]; then
        make clean
        make -j${NUM_JOBS}
    else
        EXTRA_FLAGS=""
        [ "$GCC_MAJOR" -ge 12 ] && EXTRA_FLAGS="-Wno-error"
        STREAM_FLAGS="-O3 -fopenmp -mcmodel=medium -DSTREAM_ARRAY_SIZE=800000000ULL -DNTIMES=40 ${EXTRA_FLAGS}"
        [ -f "stream.c" ] && gcc ${STREAM_FLAGS} stream.c -o stream
        [ -f "stream_copy.c" ] && gcc ${STREAM_FLAGS} -DTUNED stream_copy.c -o stream_copy
    fi
    BUILT_DIRS+=("${WORKLOAD_DIR}/stream")
    echo -e "${GREEN}STREAM binaries compiled successfully!${NC}"
}

# -------------------------------------------------------------------
# GAPBS: Graph benchmark suite and graph dataset generation
# -------------------------------------------------------------------
setup_gapbs() {
    echo ""
    echo "-------------------------------------------------------------------"
    echo " Building GAPBS Workloads & Datasets via benchmark/bench.mk..."
    echo "-------------------------------------------------------------------"
    if [ ! -d "${WORKLOAD_DIR}/gapbs" ]; then
        echo "Cloning GAPBS repository..."
        git clone https://github.com/sbeamer/gapbs.git "${WORKLOAD_DIR}/gapbs"
    fi
    cd "${WORKLOAD_DIR}/gapbs"
    clean_repo

    # Strip -Werror on GCC 12+
    if [ "$GCC_MAJOR" -ge 12 ]; then
        sed -i 's/-Werror//g' Makefile 2>/dev/null || true
    fi

    mkdir -p benchmark/out benchmark/graphs 2>/dev/null || true

    # Clean & rebuild binaries (preserves pre-generated benchmark/graphs/*.sg & *.wsg)
    make clean
    make -j${NUM_JOBS} all

    # Build graph datasets if missing (or when explicitly requested)
    if [ ! -f "benchmark/graphs/kron.sg" ] || [ ! -f "benchmark/graphs/urand.sg" ] || [ "${GAPBS_BUILD_GRAPHS:-0}" = "1" ]; then
        echo "Building GAPBS benchmark graphs into benchmark/graphs via bench.mk..."
        make -j${NUM_JOBS} bench-graphs || true
    fi

    BUILT_DIRS+=("${WORKLOAD_DIR}/gapbs")
    echo -e "${GREEN}GAPBS workloads and datasets ready in ${WORKLOAD_DIR}/gapbs!${NC}"
}

# -------------------------------------------------------------------
# Silo: In-memory OLTP database benchmark (TPC-C / YCSB)
# -------------------------------------------------------------------
setup_silo() {
    echo ""
    echo "-------------------------------------------------------------------"
    echo " Building Silo Database Workload..."
    echo "-------------------------------------------------------------------"

    # Rewrite git:// to https:// to prevent protocol timeouts
    git config --global url."https://github.com/".insteadOf "git://github.com/" 2>/dev/null || true

    # Install required build packages if missing
    if [ ! -f "/usr/include/db_cxx.h" ] || [ ! -f "/usr/include/numa.h" ] || [ ! -f "/usr/include/libaio.h" ] || [ ! -f "/usr/include/zlib.h" ] || [ ! -f "/usr/include/openssl/ssl.h" ] || ! command -v autoreconf >/dev/null 2>&1; then
        echo "Installing Silo dependencies (libdb++-dev, libnuma-dev, libjemalloc-dev, libaio-dev, zlib1g-dev, libssl-dev, autoconf, automake)..."
        apt-get update -qq 2>/dev/null || true
        apt-get install -y libdb++-dev libdb5.3++-dev libnuma-dev libjemalloc-dev libaio-dev zlib1g-dev libssl-dev autoconf automake libtool 2>/dev/null || true
    fi

    if [ ! -d "${WORKLOAD_DIR}/silo" ]; then
        echo "Cloning Silo repository..."
        git clone https://github.com/stephentu/silo.git "${WORKLOAD_DIR}/silo"
    fi
    cd "${WORKLOAD_DIR}/silo"
    clean_repo

    # Sync and update Masstree submodule
    if [ -d ".git" ]; then
        sed -i 's|git://github.com/|https://github.com/|g' .gitmodules 2>/dev/null || true
        git config submodule.masstree.url https://github.com/kohler/masstree-beta.git 2>/dev/null || true
        git submodule sync 2>/dev/null || true
        git submodule update --init --recursive 2>/dev/null || true
    fi

    # Strip -Werror from Makefile
    sed -i 's/-Werror//g' Makefile 2>/dev/null || true

    # Clean leftover build artifacts and autoconf cache
    make clean
    rm -rf out-* masstree/config.h masstree/config.status

    # Define std::pair operator<< in namespace std for GCC 12+ ADL in util.h
    mkdir -p config
    cat << 'EOF' > config/pair_stream.h
#ifndef PAIR_STREAM_H
#define PAIR_STREAM_H
#include <iostream>
#include <utility>
namespace std {
template <typename Stream, typename A, typename B>
inline Stream& operator<<(Stream& os, const std::pair<A, B>& p) {
  os << "[" << p.first << ", " << p.second << "]";
  return os;
}
}
#endif
EOF

    # Ensure Makefile includes pair_stream.h in CXXFLAGS
    if ! grep -q "config/pair_stream.h" Makefile; then
        sed -i 's|CXXFLAGS :=|CXXFLAGS := -include config/pair_stream.h |g' Makefile 2>/dev/null || true
    fi

    # Use host GCC to match system libdb_cxx and libstdc++ symbols
    CC_BIN="gcc"
    CXX_BIN="g++"
    echo "Using system GCC (${CC_BIN} / ${CXX_BIN}) for Silo compilation..."

    MODE=perf make -j${NUM_JOBS} CC="${CC_BIN}" CXX="${CXX_BIN}" dbtest

    BUILT_DIRS+=("${WORKLOAD_DIR}/silo")
    echo -e "${GREEN}Silo DB binary compiled successfully!${NC}"
}

# -------------------------------------------------------------------
# Redis: In-memory key-value database
# -------------------------------------------------------------------
setup_redis() {
    echo ""
    echo "-------------------------------------------------------------------"
    echo " Building Redis Database Workload..."
    echo "-------------------------------------------------------------------"
    if [ ! -d "${WORKLOAD_DIR}/redis_src" ]; then
        echo "Cloning Redis repository..."
        git clone https://github.com/redis/redis.git "${WORKLOAD_DIR}/redis_src"
    fi
    cd "${WORKLOAD_DIR}/redis_src"
    clean_repo
    rm -f src/Makefile.dep 2>/dev/null || true

    # Clean cached build options
    make distclean 2>/dev/null || true

    # Pre-build dependencies to prevent parallel build race
    make -C deps -j${NUM_JOBS} 2>/dev/null || true

    # Build core Redis server and benchmark binaries
    make build redis -j${NUM_JOBS} C_EXTRA_FLAGS="-Wno-error"
    BUILT_DIRS+=("${WORKLOAD_DIR}/redis_src")
    echo -e "${GREEN}Redis binaries compiled successfully!${NC}"
}

# -------------------------------------------------------------------
# XSBench: Monte Carlo neutron transport cross-section lookup
# -------------------------------------------------------------------
setup_xsbench() {
    echo ""
    echo "-------------------------------------------------------------------"
    echo " Building XSBench Workload..."
    echo "-------------------------------------------------------------------"
    if [ ! -d "${WORKLOAD_DIR}/xsbench" ]; then
        echo "Cloning XSBench repository..."
        git clone https://github.com/ANL-CESAR/XSBench.git "${WORKLOAD_DIR}/xsbench"
    fi
    cd "${WORKLOAD_DIR}/xsbench"
    clean_repo

    if [ -d "${WORKLOAD_DIR}/xsbench/openmp-threading" ]; then
        cd "${WORKLOAD_DIR}/xsbench/openmp-threading"

        # Strip -Werror on GCC 12+
        if [ "$GCC_MAJOR" -ge 12 ]; then
            sed -i 's/-Werror//g' Makefile 2>/dev/null || true
        fi

        make clean
        make -j${NUM_JOBS}
        BUILT_DIRS+=("${WORKLOAD_DIR}/xsbench")
        echo -e "${GREEN}XSBench binary compiled successfully!${NC}"
    fi
}

# -------------------------------------------------------------------
# SPEC CPU 2026: Clean and pre-build selected benchmarks
# -------------------------------------------------------------------
setup_spec2026() {
    local targets=("$@")
    echo ""
    echo "-------------------------------------------------------------------"
    echo " Cleaning & Pre-building SPEC CPU 2026 Benchmarks..."
    echo "-------------------------------------------------------------------"

    if [ ! -f "${SPEC2026_DIR}/shrc" ] || [ ! -f "${SPEC2026_DIR}/bin/harness/runcpu" ]; then
        echo -e "${YELLOW}[WARNING] SPEC CPU 2026 not installed in ${SPEC2026_DIR}; skipping.${NC}"
        return 1
    fi
    if [ ! -f "${SPEC_CONFIG}" ]; then
        echo -e "${RED}ERROR: SPEC config not found at ${SPEC_CONFIG}${NC}"
        return 1
    fi

    if [ ${#targets[@]} -eq 0 ] && [ -f "${REGRESSION_LIST}" ]; then
        local b BENCHMARKS=()
        # shellcheck source=/dev/null
        source "${REGRESSION_LIST}"
        for b in "${BENCHMARKS[@]}"; do
            [[ "$b" == spec2026_* ]] && targets+=("$b")
        done
    fi
    if [ ${#targets[@]} -eq 0 ]; then
        targets=(820.cloverleaf_s 849.fotonik3d_s 865.roms_s 881.neutron_s)
    fi

    local spec_benches=() t bname
    for t in "${targets[@]}"; do
        bname="${t#spec2026_}"
        if [ ! -d "${SPEC2026_DIR}/benchspec/CPU/${bname}" ]; then
            echo -e "${RED}ERROR: Unknown SPEC CPU 2026 benchmark '${bname}'${NC}"
            return 1
        fi
        spec_benches+=("${bname}")
    done

    echo "SPEC CPU 2026 targets: ${spec_benches[*]}"
    # Wipe build/ and exe/ directly so leftover dirs from other users (e.g. non-root) are also cleaned
    for bname in "${spec_benches[@]}"; do
        rm -rf "${SPEC2026_DIR}/benchspec/CPU/${bname}/build" "${SPEC2026_DIR}/benchspec/CPU/${bname}/exe"
        BUILT_DIRS+=("${SPEC2026_DIR}/benchspec/CPU/${bname}/build" "${SPEC2026_DIR}/benchspec/CPU/${bname}/exe")
    done
    BUILT_DIRS+=("${SPEC_CONFIG}" "${SPEC2026_DIR}/result")
    (
        cd "${SPEC2026_DIR}"
        # shellcheck source=/dev/null
        source shrc
        runcpu --config="${SPEC_CONFIG}" --action=build "${spec_benches[@]}"
    )
    echo -e "${GREEN}SPEC CPU 2026 benchmarks pre-built successfully!${NC}"
}

# -------------------------------------------------------------------
# Clean & pre-build benchmarks from CLI args or regression_list
# -------------------------------------------------------------------
prebuild_benchmarks() {
    local items=("$@")
    if [ ${#items[@]} -eq 0 ]; then
        local BENCHMARKS=()
        # shellcheck source=/dev/null
        source "${REGRESSION_LIST}"
        items=("${BENCHMARKS[@]}")
    fi

    local need_stream=0 need_gapbs=0 need_silo=0 need_redis=0 need_xsbench=0
    local spec_targets=() item
    for item in "${items[@]}"; do
        case "$item" in
            stream*)     need_stream=1 ;;
            gapbs_*)     need_gapbs=1 ;;
            silo_*)      need_silo=1 ;;
            redis)       need_redis=1 ;;
            xsbench)     need_xsbench=1 ;;
            spec2026_*)  spec_targets+=("$item") ;;
        esac
    done

    [ ${need_stream} -eq 1 ] && setup_stream
    [ ${need_gapbs} -eq 1 ] && setup_gapbs
    [ ${need_silo} -eq 1 ] && setup_silo
    [ ${need_redis} -eq 1 ] && setup_redis
    [ ${need_xsbench} -eq 1 ] && setup_xsbench
    [ ${#spec_targets[@]} -gt 0 ] && setup_spec2026 "${spec_targets[@]}"
    return 0
}

# -------------------------------------------------------------------
# Target Dispatcher
# -------------------------------------------------------------------
TARGET_INPUT="${1:-all}"
[ $# -gt 0 ] && shift

case "$TARGET_INPUT" in
    stream)
        setup_stream
        ;;
    gapbs)
        setup_gapbs
        ;;
    silo)
        setup_silo
        ;;
    redis)
        setup_redis
        ;;
    xsbench)
        setup_xsbench
        ;;
    spec2026)
        setup_spec2026 "$@"
        ;;
    prebuild)
        prebuild_benchmarks "$@"
        ;;
    all)
        echo "=== Setting up ALL workloads in: ${WORKLOAD_DIR} ==="
        setup_stream
        setup_gapbs
        setup_silo
        setup_redis
        setup_xsbench
        if [ -f "${SPEC2026_DIR}/shrc" ]; then
            setup_spec2026 "$@"
        fi
        echo ""
        echo "==================================================================="
        echo -e " ${GREEN}ALL WORKLOADS SETUP & COMPILED SUCCESSFULLY!${NC}"
        echo " Ready for evaluation with: run_workloads.sh all"
        echo "==================================================================="
        ;;
    *)
        echo "Error: Unknown target '$TARGET_INPUT'"
        echo "Run './setup_workloads.sh --help' for available targets."
        exit 1
        ;;
esac

# -------------------------------------------------------------------
# Restore file ownership for rebuilt paths only if executed via sudo
# -------------------------------------------------------------------
if [ -n "${SUDO_USER:-}" ] && [ ${#BUILT_DIRS[@]} -gt 0 ]; then
    chown -R "${SUDO_USER}:${SUDO_USER}" "${BUILT_DIRS[@]}" 2>/dev/null || true
fi
