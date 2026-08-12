#!/bin/bash
# ===================================================================
# Master Workload Setup & Build Script
# Usage: ./setup_workloads.sh [--help] [TARGET | all]
# Targets: stream | gapbs | twitter | silo | redis | xsbench | all
# ===================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
WORKLOAD_DIR="${ROOT_DIR}/workloads"
NPROC=$(nproc)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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
    echo "  stream         Build STREAM Hot & Multi-Phase Benchmarks"
    echo "  gapbs          Clone & Build GAPBS Benchmark Suite (pr, tc, bfs, bc, cc, sssp)"
    echo "  twitter        Decompress & Prepare Twitter Real-World Graph Dataset"
    echo "  silo           Clone & Build Silo OLTP Database (TPC-C)"
    echo "  redis          Clone & Build Redis In-Memory Key-Value Server"
    echo "  xsbench        Clone & Build XSBench Nuclear Reactor Simulation Benchmark"
    echo ""
    echo "Examples:"
    echo "  sudo ./setup_workloads.sh               # Builds all workloads"
    echo "  sudo ./setup_workloads.sh gapbs         # Builds only GAPBS suite"
    echo "  sudo ./setup_workloads.sh twitter       # Prepares only Twitter dataset"
    echo "=========================================================================================="
    exit 0
}

# Check for help flag
if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    show_help
fi

# Ensure root permissions before executing setup
check_root

# Detecting GCC Version
GCC_MAJOR=$(gcc -dumpversion | cut -d. -f1)

setup_stream() {
    echo ""
    echo "-------------------------------------------------------------------"
    echo " Building STREAM Workloads..."
    echo "-------------------------------------------------------------------"
    cd "${WORKLOAD_DIR}/stream"

    EXTRA_FLAGS=""
    [ "$GCC_MAJOR" -ge 12 ] && EXTRA_FLAGS="-Wno-error"

    if [ -f "stream_hot.c" ]; then
        echo "Compiling stream_hot.c..."
        gcc -O3 -fopenmp -mcmodel=medium $EXTRA_FLAGS stream_hot.c -o stream_hot
    fi
    if [ -f "stream_phases.c" ]; then
        echo "Compiling stream_phases.c..."
        gcc -O3 -fopenmp -mcmodel=medium $EXTRA_FLAGS stream_phases.c -o stream_phases
    fi
    echo -e "${GREEN}STREAM binaries compiled successfully!${NC}"
}

setup_gapbs() {
    echo ""
    echo "-------------------------------------------------------------------"
    echo " Building GAPBS Workloads..."
    echo "-------------------------------------------------------------------"
    if [ ! -d "${WORKLOAD_DIR}/gapbs" ]; then
        echo "Cloning GAPBS repository..."
        git clone https://github.com/sbeamer/gapbs.git "${WORKLOAD_DIR}/gapbs"
    fi
    cd "${WORKLOAD_DIR}/gapbs"

    # Applying the changes for the new GCC version
    if [ "$GCC_MAJOR" -ge 12 ]; then
        sed -i 's/-Werror//g' Makefile 2>/dev/null || true
    fi

    make clean
    make -j${NPROC}
    echo -e "${GREEN}GAPBS binaries compiled successfully!${NC}"
}

setup_twitter() {
    echo ""
    echo "-------------------------------------------------------------------"
    echo " Setting up Twitter Dataset & Binary Graph Conversion..."
    echo "-------------------------------------------------------------------"
    RAW_DIR="${WORKLOAD_DIR}/gapbs/benchmark/graphs/raw"
    mkdir -p "${RAW_DIR}"

    if [ ! -f "${RAW_DIR}/twitter_rv.net" ] && [ ! -f "${RAW_DIR}/twitter.el" ]; then
        echo "Decompressing Twitter graph files in ${RAW_DIR}..."
        if ls ${RAW_DIR}/twitter_rv.net.*.gz 1>/dev/null 2>&1; then
            cat ${RAW_DIR}/twitter_rv.net.*.gz | gzip -d > "${RAW_DIR}/twitter_rv.net"
            ln -sf twitter_rv.net "${RAW_DIR}/twitter.el"
        fi
    fi

    if [ -f "${RAW_DIR}/twitter_rv.net" ] && [ ! -f "${RAW_DIR}/twitter.el" ]; then
        ln -sf twitter_rv.net "${RAW_DIR}/twitter.el"
    fi

    cd "${WORKLOAD_DIR}/gapbs"
    if [ -f "${RAW_DIR}/twitter.el" ] && [ ! -f "twitter.sg" ]; then
        echo "Converting Twitter edgelist (twitter.el) -> Serialized binary graph (twitter.sg)..."
        if ./converter -f "${RAW_DIR}/twitter.el" -m -b twitter.sg 2>/dev/null; then
            echo "Twitter binary graph created: ${WORKLOAD_DIR}/gapbs/twitter.sg"
        else
            echo "Note: Twitter binary graph (.sg) conversion skipped due to system RAM limit."
            echo "GAPBS benchmarks will read raw ${RAW_DIR}/twitter.el directly."
        fi
    fi
    echo -e "${GREEN}Twitter dataset prepared successfully!${NC}"
}

setup_silo() {
    echo ""
    echo "-------------------------------------------------------------------"
    echo " Building Silo Database Workload..."
    echo "-------------------------------------------------------------------"

    # Automatically rewrite git://github.com/ -> https://github.com/ to prevent protocol timeouts
    git config --global url."https://github.com/".insteadOf "git://github.com/" 2>/dev/null || true

    # Install Berkeley DB C++ development package (db_cxx.h), NUMA, jemalloc, libaio, zlib, libssl, and autoconf tools if missing
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

    if [ -d ".git" ]; then
        sed -i 's|git://github.com/|https://github.com/|g' .gitmodules 2>/dev/null || true
        git config submodule.masstree.url https://github.com/kohler/masstree-beta.git 2>/dev/null || true
        git submodule sync 2>/dev/null || true
        git submodule update --init --recursive 2>/dev/null || true
    fi

    # Strip -Werror from Makefile to prevent GCC warning errors (unused-variable, etc.)
    sed -i 's/-Werror//g' Makefile 2>/dev/null || true

    # Generate config/pair_stream.h for GCC 12+ / GCC 15 std::pair operator<< requirement
    cat << 'EOF' > config/pair_stream.h
#ifndef PAIR_STREAM_H
#define PAIR_STREAM_H
#include <iostream>
#include <utility>
namespace std {
template <typename Stream, typename A, typename B>
inline Stream& operator<<(Stream& os, const std::pair<A, B>& p) {
  os << "(" << p.first << ", " << p.second << ")";
  return os;
}
}
#endif
EOF

    # Ensure Makefile natively includes config/pair_stream.h in CXXFLAGS (idempotently)
    if ! grep -q "config/pair_stream.h" Makefile; then
        sed -i 's|CXXFLAGS :=|CXXFLAGS := -include config/pair_stream.h |g' Makefile 2>/dev/null || true
    fi

    make clean

    # Clean leftover build artifacts and masstree autoconf cache
    rm -rf out-* masstree/config.h masstree/config.status

    if [ "$GCC_MAJOR" -ge 12 ] || [ "$GCC_MAJOR" -eq 0 ]; then
        echo "Using Docker for Silo compilation (Host GCC: '${GCC_MAJOR}')...."
        DOCKER_CMD="
            DEBIAN_FRONTEND=noninteractive apt-get update && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                build-essential g++ make autoconf automake libtool \
                libdb++-dev libdb5.3++-dev libnuma-dev libjemalloc-dev libaio-dev zlib1g-dev libssl-dev || true && \
            sed -i 's/-Werror//g' Makefile 2>/dev/null || true && \
            MODE=perf make -j${NPROC} dbtest
        "
        docker run --rm -v "${WORKLOAD_DIR}/silo":/usr/src/silo -w /usr/src/silo ubuntu:20.04 bash -c "$DOCKER_CMD"
    else
        MODE=perf make -j${NPROC} dbtest
    fi
    echo -e "${GREEN}Silo DB binary compiled successfully!${NC}"
}

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

    # Avoid dubious ownership errors if the repo was cloned by a different user but script is run via sudo
    git config --global --add safe.directory "${WORKLOAD_DIR}/redis_src" 2>/dev/null || true

    # Restore clean src/Makefile and remove cached Makefile.dep from prior build attempts
    if [ -d ".git" ]; then
        git checkout -- src/Makefile 2>/dev/null || true
    fi
    rm -f src/Makefile.dep 2>/dev/null || true

    # Clean cached build options and dependencies per README.md instructions
    make distclean 2>/dev/null || true

    # Pre-build dependencies to prevent parallel build race conditions
    make -C deps -j${NPROC} 2>/dev/null || true

    # Build just the core Redis data structures (avoids complex module dependencies like Rust/LLVM)
    make build redis -j${NPROC} C_EXTRA_FLAGS="-Wno-error"
    echo -e "${GREEN}Redis binaries compiled successfully!${NC}"
}

setup_xsbench() {
    echo ""
    echo "-------------------------------------------------------------------"
    echo " Building XSBench Workload..."
    echo "-------------------------------------------------------------------"
    if [ ! -d "${WORKLOAD_DIR}/xsbench" ]; then
        echo "Cloning XSBench repository..."
        git clone https://github.com/ANL-CESAR/XSBench.git "${WORKLOAD_DIR}/xsbench"
    fi

    if [ -d "${WORKLOAD_DIR}/xsbench/openmp-threading" ]; then
        cd "${WORKLOAD_DIR}/xsbench/openmp-threading"

        # Applying the changes for the new GCC version
        if [ "$GCC_MAJOR" -ge 12 ]; then
            sed -i 's/-Werror//g' Makefile 2>/dev/null || true
        fi

        make clean
        make -j${NPROC}
        echo -e "${GREEN}XSBench binary compiled successfully!${NC}"
    fi
}

# Target selection
TARGET_INPUT="${1:-all}"

case "$TARGET_INPUT" in
    stream)
        setup_stream
        ;;
    gapbs)
        setup_gapbs
        ;;
    twitter)
        setup_twitter
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
        setup_twitter
        setup_silo
        setup_redis
        setup_xsbench
        echo ""
        echo "==================================================================="
        echo -e " ${GREEN}ALL WORKLOADS SETUP & COMPILED SUCCESSFULLY!${NC}"
        echo " Ready for evaluation with: sudo ./run_nomad.sh all"
        echo "==================================================================="
        ;;
    *)
        echo "Error: Unknown target '$TARGET_INPUT'"
        echo "Run './setup_workloads.sh --help' for available targets."
        exit 1
        ;;
esac
