#!/bin/bash
# -------------------------------------------------------------------
# Pure Workload Execution Dispatcher
# Resolves and executes the numactl --physcpubind=... command for a
# given workload target alias directly without benchmark setup delays.
# Usage: ./exec_workload.sh [TARGET_ALIAS] [DATASET: kron | urand | twitter | web | road]
# -------------------------------------------------------------------
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
WORKLOAD_DIR="${ROOT_DIR}/workloads"

# Workload cores (default 12: cores 0..11; cores 12..15 reserved for kswapd/bpftrace/perf)
export WORKLOAD_CORES="${WORKLOAD_CORES:-12}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-${WORKLOAD_CORES}}"
SELECTED_CPUS="${SELECTED_CPUS:-$(seq -s, 0 $(( WORKLOAD_CORES - 1 )))}"

# Silo runtime in seconds (default 100s)
export SILO_RUNTIME="${SILO_RUNTIME:-100}"

# Graph Datasets Directory
GAPBS_DIR="${WORKLOAD_DIR}/gapbs"
GAPBS_GRAPH_DIR="${GAPBS_DIR}/benchmark/graphs"

# Configurable GAPBS execution parameters
GAPBS_DEFAULT_TRIALS="${GAPBS_NUM_TRIALS:-5}"
export GAPBS_BC_NUM_TRIALS="${GAPBS_BC_NUM_TRIALS:-${GAPBS_DEFAULT_TRIALS:-2}}"
export GAPBS_TC_NUM_TRIALS="${GAPBS_TC_NUM_TRIALS:-${GAPBS_DEFAULT_TRIALS:-1}}"
export GAPBS_PR_NUM_TRIALS="${GAPBS_PR_NUM_TRIALS:-${GAPBS_DEFAULT_TRIALS:-2}}"
export GAPBS_BFS_NUM_TRIALS="${GAPBS_BFS_NUM_TRIALS:-${GAPBS_DEFAULT_TRIALS:-16}}"
export GAPBS_SSSP_NUM_TRIALS="${GAPBS_SSSP_NUM_TRIALS:-${GAPBS_DEFAULT_TRIALS:-16}}"
export GAPBS_CC_NUM_TRIALS="${GAPBS_CC_NUM_TRIALS:-${GAPBS_DEFAULT_TRIALS:-16}}"

export GAPBS_PR_ITERS="${GAPBS_PR_ITERS:-100}"
export GAPBS_PR_TOL="${GAPBS_PR_TOL:-1e-4}"
export GAPBS_BC_ITERS="${GAPBS_BC_ITERS:-4}"
export GAPBS_EXTRA_ARGS="${GAPBS_EXTRA_ARGS:-}"

# Configurable Redis execution parameters
export REDIS_KEYS="${REDIS_KEYS:-4300000}"
export REDIS_REQUESTS="${REDIS_REQUESTS:-4300000}"
export REDIS_DATA_SIZE="${REDIS_DATA_SIZE:-8192}"
export REDIS_CLIENTS="${REDIS_CLIENTS:-50}"
export REDIS_THREADS="${REDIS_THREADS:-4}"
export REDIS_TESTS="${REDIS_TESTS:-set,get}"
export REDIS_EXTRA_ARGS="${REDIS_EXTRA_ARGS:-}"

show_help() {
    echo "=========================================================================================="
    echo " Pure Workload Execution Dispatcher"
    echo "=========================================================================================="
    echo "Usage:"
    echo "  $0 [TARGET_ALIAS] [DATASET: kron | urand | twitter | web | road]"
    echo ""
    echo "Options:"
    echo "  -h, --help           Show this help message and exit"
    echo "  --get-cmd            [Review Only] Print the benchmark execution command string only"
    echo "  --get-preload-cmd    [Review Only] Print the dataset preload command string only"
    echo "  --get-target-exe     [Review Only] Print the target executable name for tracing/hooking"
    echo ""
    echo "Environment Variable Overrides (GAPBS):"
    echo "  GAPBS_NUM_TRIALS        Default trial count for all GAPBS algorithms"
    echo "  GAPBS_<ALGO>_NUM_TRIALS Per-algorithm trials (BC, TC, PR, BFS, SSSP, CC)"
    echo "  GAPBS_PR_ITERS          PageRank max iterations (default: 100)"
    echo "  GAPBS_PR_TOL            PageRank tolerance (default: 1e-4)"
    echo "  GAPBS_BC_ITERS          Betweenness Centrality iterations (default: 4)"
    echo "  GAPBS_SSSP_DELTA        SSSP delta step (default: 50000 for road, 2 for others)"
    echo "  GAPBS_EXTRA_ARGS        Additional arguments passed to GAPBS binaries"
    echo ""
    echo "Environment Variable Overrides (Silo):"
    echo "  SILO_RUNTIME            Benchmark runtime in seconds (default: 100)"
    echo "  SILO_BID_RUNTIME        Benchmark runtime for silo_bid in seconds (default: 20)"
    echo ""
    echo "Environment Variable Overrides (Redis):"
    echo "  REDIS_KEYS              Keyspace length (default: 4300000)"
    echo "  REDIS_REQUESTS          Total request count (default: 4300000)"
    echo "  REDIS_DATA_SIZE         Payload size in bytes (default: 8192 -> ~22GB RSS)"
    echo "  REDIS_CLIENTS           Parallel client connections (default: 50)"
    echo "  REDIS_THREADS           Benchmark worker threads (default: 4)"
    echo "  REDIS_TESTS             Benchmark tests to execute (default: set,get)"
    echo "  REDIS_EXTRA_ARGS        Additional arguments passed to redis-benchmark"
    echo ""
    echo "Available Targets:"
    echo "  stream, stream_hot, stream_phase,"
    echo "  gapbs_pr, gapbs_tc, gapbs_bfs, gapbs_bc, gapbs_cc, gapbs_sssp,"
    echo "  (supports composite aliases: gapbs_<algo>_<dataset>, e.g., gapbs_bc_kron),"
    echo "  silo_tpcc, silo_ycsb, silo_queue, silo_bid, silo_encstress,"
    echo "  redis, xsbench"
    echo "=========================================================================================="
    exit 0
}

resolve_target_exe() {
    local t="$1"
    if [[ "$t" =~ ^(gapbs_[a-z]+)_(kron|urand|twitter|web|road)$ ]]; then
        t="${BASH_REMATCH[1]}"
    fi
    case "$t" in
        stream)         echo "stream" ;;
        stream_hot)     echo "stream_hot" ;;
        stream_phase)   echo "stream_phase" ;;
        gapbs_pr)       echo "pr" ;;
        gapbs_tc)       echo "tc" ;;
        gapbs_bfs)      echo "bfs" ;;
        gapbs_bc)       echo "bc" ;;
        gapbs_cc)       echo "cc" ;;
        gapbs_sssp)     echo "sssp" ;;
        silo_*)         echo "dbtest" ;;
        redis)          echo "redis-server" ;;
        xsbench)        echo "XSBench" ;;
        *)              echo "" ;;
    esac
}

MODE="RUN"
if [ "$1" == "--get-cmd" ]; then
    MODE="GET_CMD"
    shift
elif [ "$1" == "--get-preload-cmd" ]; then
    MODE="GET_PRELOAD"
    shift
elif [ "$1" == "--get-target-exe" ]; then
    shift
    resolve_target_exe "$1"
    exit 0
fi

if [ -z "$1" ] || [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    show_help
fi

TARGET="$1"
DATASET_INPUT="${2:-kron}"

# Decompose composite GAPBS benchmark alias if present (e.g. gapbs_bc_kron -> gapbs_bc kron)
if [[ "$TARGET" =~ ^(gapbs_[a-z]+)_(kron|urand|twitter|web|road)$ ]]; then
    [ -z "$2" ] && DATASET_INPUT="${BASH_REMATCH[2]}"
    TARGET="${BASH_REMATCH[1]}"
fi

resolve_graph_file() {
    local t="$1"
    local ds="$2"
    local gname="${ds}.sg"
    if [ "$t" == "gapbs_sssp" ]; then
        gname="${ds}.wsg"
    elif [ "$t" == "gapbs_tc" ]; then
        gname="${ds}U.sg"
    fi

    local target_path="${GAPBS_GRAPH_DIR}/${gname}"
    if [ ! -e "${target_path}" ] && [ -e "${GAPBS_DIR}/${gname}" ]; then
        target_path="${GAPBS_DIR}/${gname}"
    fi

    # Follow symbolic links so vmtouch and GAPBS get the canonical path
    if [ -e "${target_path}" ]; then
        realpath "${target_path}" 2>/dev/null || echo "${target_path}"
    else
        echo "${target_path}"
    fi
}

resolve_preload_cmd() {
    local t="$1"
    local ds="$2"
    local pcmd=""

    if [[ "$t" == gapbs_* ]]; then
        local gfile=$(resolve_graph_file "$t" "$ds")
        pcmd="numactl --membind 1 vmtouch -f -t -m 64G ${gfile}"
    fi

    echo "$pcmd"
}

resolve_cmd() {
    local t="$1"
    local ds="$2"
    local graph_file=""
    local cmd=""
    local RUN_PREFIX="env OMP_NUM_THREADS=${OMP_NUM_THREADS} numactl --physcpubind=${SELECTED_CPUS}"

    if [[ "$t" == gapbs_* ]]; then
        graph_file=$(resolve_graph_file "$t" "$ds")
    fi

    local SILO_BIN="${WORKLOAD_DIR}/silo/out-perf.masstree/benchmarks/dbtest"
    [ ! -f "$SILO_BIN" ] && SILO_BIN="${WORKLOAD_DIR}/silo/out-perf/benchmarks/dbtest"

    local REDIS_RUN_SCRIPT="${WORKLOAD_DIR}/scripts/run_redis.sh"

    case "$t" in
        stream)
            cmd="${RUN_PREFIX} ${WORKLOAD_DIR}/stream/stream"
            ;;
        stream_hot)
            cmd="${RUN_PREFIX} ${WORKLOAD_DIR}/stream/stream_hot"
            ;;
        stream_phase)
            cmd="${RUN_PREFIX} ${WORKLOAD_DIR}/stream/stream_phase"
            ;;
        gapbs_pr)
            cmd="${RUN_PREFIX} ${GAPBS_DIR}/pr -f ${graph_file} -i ${GAPBS_PR_ITERS} -t ${GAPBS_PR_TOL} -n ${GAPBS_PR_NUM_TRIALS} ${GAPBS_EXTRA_ARGS}"
            ;;
        gapbs_tc)
            cmd="${RUN_PREFIX} ${GAPBS_DIR}/tc -f ${graph_file} -n ${GAPBS_TC_NUM_TRIALS} ${GAPBS_EXTRA_ARGS}"
            ;;
        gapbs_bfs)
            cmd="${RUN_PREFIX} ${GAPBS_DIR}/bfs -f ${graph_file} -n ${GAPBS_BFS_NUM_TRIALS} ${GAPBS_EXTRA_ARGS}"
            ;;
        gapbs_bc)
            cmd="${RUN_PREFIX} ${GAPBS_DIR}/bc -f ${graph_file} -i ${GAPBS_BC_ITERS} -n ${GAPBS_BC_NUM_TRIALS} ${GAPBS_EXTRA_ARGS}"
            ;;
        gapbs_cc)
            cmd="${RUN_PREFIX} ${GAPBS_DIR}/cc -f ${graph_file} -n ${GAPBS_CC_NUM_TRIALS} ${GAPBS_EXTRA_ARGS}"
            ;;
        gapbs_sssp)
            local delta="${GAPBS_SSSP_DELTA:-}"
            if [ -z "$delta" ]; then
                if [ "$ds" == "road" ]; then
                    delta=50000
                else
                    delta=2
                fi
            fi
            cmd="${RUN_PREFIX} ${GAPBS_DIR}/sssp -f ${graph_file} -n ${GAPBS_SSSP_NUM_TRIALS} -d ${delta} ${GAPBS_EXTRA_ARGS}"
            ;;
        silo_tpcc)
            cmd="${RUN_PREFIX} ${SILO_BIN} --verbose --bench tpcc --num-threads ${WORKLOAD_CORES} --scale-factor 180 --parallel-loading --runtime ${SILO_RUNTIME}"
            ;;
        silo_ycsb)
            cmd="${RUN_PREFIX} ${SILO_BIN} --verbose --bench ycsb --num-threads ${WORKLOAD_CORES} --scale-factor 95000 --parallel-loading --runtime ${SILO_RUNTIME}"
            ;;
        silo_queue)
            cmd="${RUN_PREFIX} ${SILO_BIN} --verbose --bench queue --num-threads 1 --scale-factor 1 --runtime ${SILO_RUNTIME}"
            ;;
        silo_bid)
            local bid_runtime="${SILO_BID_RUNTIME:-20}"
            cmd="${RUN_PREFIX} ${SILO_BIN} --verbose --bench bid --num-threads ${WORKLOAD_CORES} --scale-factor 55000 --parallel-loading --runtime ${bid_runtime}"
            ;;
        silo_encstress)
            cmd="${RUN_PREFIX} ${SILO_BIN} --verbose --bench encstress --num-threads ${WORKLOAD_CORES} --scale-factor 95000 --parallel-loading --runtime ${SILO_RUNTIME}"
            ;;
        redis)
            cmd="${RUN_PREFIX} ${REDIS_RUN_SCRIPT} -t ${REDIS_TESTS} -n ${REDIS_REQUESTS} -r ${REDIS_KEYS} -d ${REDIS_DATA_SIZE} -c ${REDIS_CLIENTS} --threads ${REDIS_THREADS} ${REDIS_EXTRA_ARGS}"
            ;;
        xsbench)
            cmd="${RUN_PREFIX} ${WORKLOAD_DIR}/xsbench/openmp-threading/XSBench -g 37000 -p 5000000"
            ;;
        *)
            echo "Error: Unknown target '$t'" >&2
            exit 1
            ;;
    esac

    echo "$cmd"
}

if [ "$MODE" == "GET_CMD" ]; then
    resolve_cmd "$TARGET" "$DATASET_INPUT"
elif [ "$MODE" == "GET_PRELOAD" ]; then
    resolve_preload_cmd "$TARGET" "$DATASET_INPUT"
else
    CMD=$(resolve_cmd "$TARGET" "$DATASET_INPUT")
    echo "[exec_workload] Running: $TARGET -> $CMD"
    eval "$CMD"
fi
