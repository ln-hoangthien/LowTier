#!/bin/bash
# -------------------------------------------------------------------
# Parameterized Workload Evaluation Script
# Usage: ./run_workloads.sh [--help] [TARGET_ALIAS | all] [DATASET: kron | urand | twitter]
# -------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
WORKLOAD_DIR="${ROOT_DIR}/workloads"
MODULE_DIR="${MODULE_DIR:-${ROOT_DIR}/baselines/nomad/nomad_module}"

# Resolve Twitter graph binary (.sg) or raw edgelist (.el)
TWITTER_GRAPH="${WORKLOAD_DIR}/gapbs/twitter.sg"
[ ! -f "$TWITTER_GRAPH" ] && TWITTER_GRAPH="${WORKLOAD_DIR}/gapbs/benchmark/graphs/raw/twitter.el"

KRON_GRAPH="${WORKLOAD_DIR}/gapbs/kron25.sg"

show_help() {
    echo "=========================================================================================="
    echo " Tiered Memory & Workload Automated Evaluation Script (${KERNEL_VER:-$(uname -r)})"
    echo "=========================================================================================="
    echo "Usage:"
    echo "  sudo $0 [OPTION | TARGET_ALIAS] [DATASET: kron | urand | twitter]"
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message and exit"
    echo "  all            Run ALL workloads sequentially into ONE log file"
    echo ""
    echo "Datasets Available (GAPBS only):"
    echo "  kron           Kronecker Synthetic Graph (-g 25 / kron25.sg ~5.5 - 9.5 GB RAM) [Default]"
    echo "  urand          Uniform Random Synthetic Graph (-u 25 ~5.5 - 9.5 GB RAM)"
    echo "  twitter        Twitter Real-World Graph (~12.5 - 13.8 GB RAM)"
    echo ""
    echo "Available Target Aliases:"
    echo "  stream_hot     STREAM Hot-Block Tiering Benchmark               [Est. Footprint: 11.18 GB]"
    echo "  stream_phases  STREAM Multi-Phase Rotation Benchmark            [Est. Footprint: 11.18 GB]"
    echo "  gapbs_pr       GAPBS PageRank Benchmark"
    echo "  gapbs_tc       GAPBS Triangle Counting Benchmark"
    echo "  gapbs_bfs      GAPBS Breadth-First Search Benchmark"
    echo "  gapbs_bc       GAPBS Betweenness Centrality Benchmark"
    echo "  gapbs_cc       GAPBS Connected Components Benchmark"
    echo "  gapbs_sssp     GAPBS Single-Source Shortest Paths Benchmark"
    echo "  silo           Silo OLTP Database Benchmark (TPC-C)"
    echo "  redis          Redis In-Memory Database Benchmark"
    echo "  xsbench        XSBench Nuclear Reactor Simulation Benchmark"
    echo "  spec_mcf       SPEC CPU MCF Memory Intensive Benchmark"
    echo ""
    echo "Examples:"
    echo "  sudo $0 gapbs_pr          # Uses default Kronecker graph"
    echo "  sudo $0 gapbs_pr urand    # Uses Uniform Random synthetic graph (-u 25)"
    echo "  sudo $0 gapbs_pr twitter  # Uses Twitter real-world graph"
    echo "  sudo $0 silo              # Runs Silo TPC-C benchmark"
    echo "  sudo $0 redis             # Runs Redis in-memory benchmark"
    echo "  sudo $0 xsbench           # Runs XSBench simulation benchmark"
    echo "  sudo $0 spec_mcf         # Runs SPEC CPU MCF benchmark"
    echo "  sudo $0 all               # Runs all workloads"
    echo "=========================================================================================="
    exit 0
}

YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}Notice: Root/sudo privileges are required for workload evaluation.${NC}"
        echo -e "${YELLOW}Re-running script with sudo...${NC}"
        exec sudo bash "$0" "$@"
    fi
}

# Check for help flag
if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    show_help
fi

# Ensure root permissions before executing workloads
check_root

# Function to run a single workload target
run_target() {
    local TARGET="$1"
    local DATASET="$2"
    local LOG_FILE="$3"
    local WORKLOAD_CMD=""
    local GRAPH_ARG=""
    local DATASET_INFO=""

    # Resolve dataset argument for GAPBS targets only
    if [[ "$TARGET" == gapbs_* ]]; then
        if [ "$DATASET" == "twitter" ]; then
            GRAPH_ARG="-f ${TWITTER_GRAPH}"
        elif [ "$DATASET" == "urand" ]; then
            GRAPH_ARG="-u 25"
        else
            if [ -f "$KRON_GRAPH" ]; then
                GRAPH_ARG="-f ${KRON_GRAPH}"
            else
                GRAPH_ARG="-g 25"
            fi
            DATASET="kron"
        fi
        DATASET_INFO=" (Dataset: ${DATASET})"
    else
        DATASET_INFO=""
    fi

    # Resolve Silo binary path
    local SILO_BIN="${WORKLOAD_DIR}/silo/out-perf.masstree/benchmarks/dbtest"
    [ ! -f "$SILO_BIN" ] && SILO_BIN="${WORKLOAD_DIR}/silo/out-perf/benchmarks/dbtest"

    # Resolve Redis runner script path
    local REDIS_RUN_SCRIPT="${WORKLOAD_DIR}/scripts/run_redis.sh"
    
    # Resolve SPEC CPU binary path
    local SPEC_BIN="${WORKLOAD_DIR}/spec/mcf"
    [ ! -f "$SPEC_BIN" ] && SPEC_BIN="${WORKLOAD_DIR}/spec_cpu/mcf"
    [ ! -f "$SPEC_BIN" ] && SPEC_BIN="${WORKLOAD_DIR}/spec/505.mcf_r/mcf_r_base"

    case "$TARGET" in
        stream_hot)
            WORKLOAD_CMD="numactl --preferred=0 ${WORKLOAD_DIR}/stream/stream_hot"
            ;;
        stream_phases)
            WORKLOAD_CMD="numactl --preferred=0 ${WORKLOAD_DIR}/stream/stream_phases"
            ;;
        gapbs_pr)
            WORKLOAD_CMD="numactl --preferred=0 ${WORKLOAD_DIR}/gapbs/pr ${GRAPH_ARG} -n 10"
            ;;
        gapbs_tc)
            WORKLOAD_CMD="numactl --preferred=0 ${WORKLOAD_DIR}/gapbs/tc ${GRAPH_ARG} -n 10"
            ;;
        gapbs_bfs)
            WORKLOAD_CMD="numactl --preferred=0 ${WORKLOAD_DIR}/gapbs/bfs ${GRAPH_ARG} -n 10"
            ;;
        gapbs_bc)
            WORKLOAD_CMD="numactl --preferred=0 ${WORKLOAD_DIR}/gapbs/bc ${GRAPH_ARG} -n 10"
            ;;
        gapbs_cc)
            WORKLOAD_CMD="numactl --preferred=0 ${WORKLOAD_DIR}/gapbs/cc ${GRAPH_ARG} -n 10"
            ;;
        gapbs_sssp)
            WORKLOAD_CMD="numactl --preferred=0 ${WORKLOAD_DIR}/gapbs/sssp ${GRAPH_ARG} -n 10"
            ;;
        silo)
            WORKLOAD_CMD="numactl --preferred=0 ${SILO_BIN} --verbose --bench tpcc --num-threads 20 --scale-factor 20 --runtime 30"
            ;;
        redis)
            WORKLOAD_CMD="numactl --preferred=0 ${REDIS_RUN_SCRIPT}"
            ;;
        xsbench)
            WORKLOAD_CMD="numactl --preferred=0 ${WORKLOAD_DIR}/xsbench/openmp-threading/XSBench -g 15000 -p 50000000"
            ;;
        spec_mcf|spec_cpu)
            WORKLOAD_CMD="numactl --preferred=0 ${SPEC_BIN} ${WORKLOAD_DIR}/spec/inp.in"
            ;;
        *)
            echo "Error: Unknown target alias '$TARGET'"
            echo "Run '$0 --help' for available target aliases."
            exit 1
            ;;
    esac

    echo ""
    echo "=========================================================="
    echo " EXECUTING TARGET: ${TARGET}${DATASET_INFO}"
    echo " Workload Command : ${WORKLOAD_CMD}"
    echo " Log File         : ${LOG_FILE}"
    echo "=========================================================="

    # Sleep 10s to settle before turn-on
    sleep 10

    # --------------------------------------------
    # 1. TURN-ON NUMA RUN
    # --------------------------------------------
    swapoff -a 2>/dev/null || true

    # Temporarily disable NUMA balancing before loading module
    sysctl -w kernel.numa_balancing=0 2>/dev/null || true
    sleep 10

    # Load async promotion module safely if present
    if [ -n "${MODULE_DIR}" ] && [ -d "${MODULE_DIR}" ] && [ -f "${MODULE_DIR}/async_promote.ko" ]; then
        (cd "${MODULE_DIR}" && { lsmod | grep -q async_promote || insmod async_promote.ko 2>/dev/null || true; })
    fi

    # Enable Tiered Memory NUMA balancing & demotion
    sysctl -w kernel.numa_balancing=2 2>/dev/null || sysctl -w kernel.numa_balancing=1 2>/dev/null || true
    echo true | tee /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    sleep 30
    echo 3 | sudo tee /proc/sys/vm/drop_caches
    sleep 30

    # Write NUMA Header to Log
    {
        echo "==================================================================="
        echo " 1. NUMA MODE - WORKLOAD: ${TARGET}${DATASET_INFO}"
        echo "==================================================================="
        echo " Command Executed: ${WORKLOAD_CMD}"
        echo " Execution Time  : $(date)"
        echo " Kernel Version  : $(uname -r)"
        echo " numa_balancing  : $(cat /proc/sys/kernel/numa_balancing 2>/dev/null || echo N/A)"
        echo " demotion_enabled: $(cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || echo false)"
        echo " async_promote   : $(lsmod | grep async_promote || echo 'Not Loaded')"
        echo "==================================================================="
        echo ""
    } >> "${LOG_FILE}"

    # Execute workload run in NUMA mode and append output to log
    ${WORKLOAD_DIR}/scripts/run_with_stats.sh ${WORKLOAD_CMD} >> "${LOG_FILE}" 2>&1

    sleep 30s

    # --------------------------------------------
    # 2. TURN-OFF NUMA (noNUMA RUN)
    # --------------------------------------------
    sysctl -w kernel.numa_balancing=0 2>/dev/null || true
    echo false | tee /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # Sleep 30 seconds to drain in-flight ring queue
    sleep 30
    echo 3 | sudo tee /proc/sys/vm/drop_caches
    sleep 30

    # Write noNUMA Header to Log
    {
        echo ""
        echo "==================================================================="
        echo " 2. noNUMA MODE - WORKLOAD: ${TARGET}${DATASET_INFO}"
        echo "==================================================================="
        echo " Command Executed: ${WORKLOAD_CMD}"
        echo " Execution Time  : $(date)"
        echo " Kernel Version  : $(uname -r)"
        echo " numa_balancing  : $(cat /proc/sys/kernel/numa_balancing 2>/dev/null || echo N/A)"
        echo " demotion_enabled: $(cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || echo false)"
        echo " async_promote   : $(lsmod | grep async_promote || echo 'Not Loaded')"
        echo "==================================================================="
        echo ""
    } >> "${LOG_FILE}"

    # Execute noNUMA workload run and append output to log
    ${WORKLOAD_DIR}/scripts/run_with_stats.sh ${WORKLOAD_CMD} >> "${LOG_FILE}" 2>&1

    echo "Target ${TARGET}${DATASET_INFO} Finished! Results appended to: ${LOG_FILE}"
}

# Main Execution Flow
TARGET_INPUT="${1:-stream_hot}"
DATASET_INPUT="${2:-kron}" # Options: kron | urand | twitter

KERNEL_VER=$(uname -r)
LOG_DIR="${WORKLOAD_DIR}/output/${KERNEL_VER}"
mkdir -p "${LOG_DIR}"

if [ "$TARGET_INPUT" == "all" ]; then
    SINGLE_LOG="${LOG_DIR}/all.log"
    rm -f "${SINGLE_LOG}"
    echo "=== RUNNING ALL WORKLOAD TARGETS SEQUENTIALLY ==="
    echo "Log File: ${SINGLE_LOG}"

    run_target "stream_hot" "" "${SINGLE_LOG}"
    run_target "stream_phases" "" "${SINGLE_LOG}"
    run_target "gapbs_pr" "${DATASET_INPUT}" "${SINGLE_LOG}"
    run_target "gapbs_tc" "${DATASET_INPUT}" "${SINGLE_LOG}"
    run_target "gapbs_bfs" "${DATASET_INPUT}" "${SINGLE_LOG}"
    run_target "gapbs_bc" "${DATASET_INPUT}" "${SINGLE_LOG}"
    run_target "gapbs_cc" "${DATASET_INPUT}" "${SINGLE_LOG}"
    run_target "gapbs_sssp" "${DATASET_INPUT}" "${SINGLE_LOG}"
    run_target "silo" "" "${SINGLE_LOG}"
    run_target "redis" "" "${SINGLE_LOG}"
    run_target "xsbench" "" "${SINGLE_LOG}"
    
    echo "=== ALL WORKLOAD TARGETS COMPLETED! SINGLE LOG SAVED TO: ${SINGLE_LOG} ==="
else
    if [[ "$TARGET_INPUT" == gapbs_* ]]; then
        SINGLE_LOG="${LOG_DIR}/${TARGET_INPUT}_${DATASET_INPUT}.log"
    else
        SINGLE_LOG="${LOG_DIR}/${TARGET_INPUT}.log"
    fi
    rm -f "${SINGLE_LOG}"
    run_target "$TARGET_INPUT" "$DATASET_INPUT" "${SINGLE_LOG}"
fi