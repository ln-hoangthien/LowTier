#!/bin/bash
# ===================================================================
# Master Workload Setup & Build Script
# Usage: ./setup_workloads.sh [--help] [TARGET | all]
# Targets: stream | gapbs | silo | redis | xsbench | all
# ===================================================================

set -e

# Base directories and build concurrency
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
WORKLOAD_DIR="${ROOT_DIR}/workloads"
NUM_JOBS="$(nproc)"

# Output color formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Require root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}ERROR: This script must be run with root/sudo privileges.${NC}"
        echo "Usage: sudo ./setup_workloads.sh [OPTION | TARGET_NAME]"
        exit 1
    fi
}

show_help() {
    echo "=========================================================================================="
    echo " Workload Cloning, Setup & Compilation Script"
    echo "=========================================================================================="
    echo "Usage:"
    echo "  sudo ./setup_workloads.sh [OPTION | TARGET_NAME]"
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message and exit"
    echo "  all            Setup and compile ALL workloads [Default]"
    echo ""
    echo "Available Targets:"
    echo "  stream         Build STREAM Classic, Hot & Multi-Phase Benchmarks"
    echo "  gapbs          Clone & Build GAPBS Suite + all graphs (unweighted & weighted: kron27, urand27, twitter)"
    echo "  silo           Clone & Build Silo OLTP Database (TPC-C)"
    echo "  redis          Clone & Build Redis In-Memory Key-Value Server"
    echo "  xsbench        Clone & Build XSBench Nuclear Reactor Simulation Benchmark"
    echo ""
    echo "Examples:"
    echo "  sudo ./setup_workloads.sh               # Builds all workloads and datasets"
    echo "  sudo ./setup_workloads.sh gapbs         # Builds GAPBS suite & all graphs"
    echo "=========================================================================================="
    exit 0
}

# Check for help flag
if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
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
    clean_repo

    EXTRA_FLAGS=""
    [ "$GCC_MAJOR" -ge 12 ] && EXTRA_FLAGS="-Wno-error"

    # High memory footprint: 800M elements * 8 bytes * 3 arrays = 19.2 GB memory footprint
    STREAM_FLAGS="-O3 -fopenmp -mcmodel=medium -DSTREAM_ARRAY_SIZE=800000000ULL -DNTIMES=40 ${EXTRA_FLAGS}"

    # Compile classic STREAM
    if [ -f "stream.c" ]; then
        echo "Compiling stream.c (19.2 GB footprint, -DSTREAM_ARRAY_SIZE=800000000ULL -DNTIMES=40)..."
        gcc ${STREAM_FLAGS} stream.c -o stream
    fi
    # Compile hot-working-set variant
    if [ -f "stream_hot.c" ]; then
        echo "Compiling stream_hot.c (18.0 GB worsened-latency)..."
        gcc -O3 -fopenmp -mcmodel=medium $EXTRA_FLAGS stream_hot.c -o stream_hot
    fi
    # Compile multi-phase memory footprint variant
    if [ -f "stream_phase.c" ]; then
        echo "Compiling stream_phase.c (18.0 GB worsened-latency)..."
        gcc -O3 -fopenmp -mcmodel=medium $EXTRA_FLAGS stream_phase.c -o stream_phase
    fi
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

    # Build binaries and default graph datasets
    echo "Building all GAPBS benchmark graphs into default directory (benchmark/graphs) via bench.mk..."
    make -j${NUM_JOBS} bench-graphs || true

    echo -e "${GREEN}GAPBS workloads and all datasets setup successfully in default directory (benchmark/graphs)!${NC}"
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
        echo -e "${GREEN}XSBench binary compiled successfully!${NC}"
    fi
}

# -------------------------------------------------------------------
# Target Dispatcher
# -------------------------------------------------------------------
TARGET_INPUT="${1:-all}"

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
    all)
        echo "=== Setting up ALL workloads in: ${WORKLOAD_DIR} ==="
        setup_stream
        setup_gapbs
        setup_silo
        setup_redis
        setup_xsbench
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
# Restore file ownership to invoking user if executed via sudo
# -------------------------------------------------------------------
if [ -n "${SUDO_USER:-}" ]; then
    chown -R "${SUDO_USER}:${SUDO_USER}" "${WORKLOAD_DIR}" 2>/dev/null || true
fi
