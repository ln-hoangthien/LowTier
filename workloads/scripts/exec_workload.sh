#!/bin/bash
# -------------------------------------------------------------------
# Pure Workload Execution Dispatcher
# Resolves and executes the numactl --preferred=0 ... command for a
# given workload target alias directly without benchmark setup delays.
# Usage: ./exec_workload.sh [TARGET_ALIAS] [DATASET: kron | urand | twitter]
# -------------------------------------------------------------------

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
WORKLOAD_DIR="${ROOT_DIR}/workloads"

# Dynamically determine host CPU core count and reserve 2 cores for background workers (kswapd, bpftrace, perf)
NUM_CORES="$(nproc)"
RESERVED_CORES="${RESERVED_CORES:-2}"
WORKLOAD_CORES=$(( NUM_CORES > RESERVED_CORES ? NUM_CORES - RESERVED_CORES : NUM_CORES ))

# Export OMP_NUM_THREADS for OpenMP workloads (e.g., STREAM, GAPBS, XSBench)
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-${WORKLOAD_CORES}}"

# Silo runtime in seconds (default 30s)
export SILO_RUNTIME="${SILO_RUNTIME:-30}"

# Workload Intensity Tunables (Override via environment variables if desired)
export GAPBS_PR_ITERS="${GAPBS_PR_ITERS:-1000}"
export GAPBS_PR_TOLERANCE="${GAPBS_PR_TOLERANCE:-1e-6}"
export GAPBS_BC_ITERS="${GAPBS_BC_ITERS:-4}"
export GAPBS_SSSP_DELTA="${GAPBS_SSSP_DELTA:-2}"
export GAPBS_BFS_ROOT="${GAPBS_BFS_ROOT:-0}"
export GAPBS_BFS_TRIALS="${GAPBS_BFS_TRIALS:-500}"
export GAPBS_TRIALS="${GAPBS_TRIALS:-25}"


# Graph Datasets (.sg / .wsg pre-serialized binary graphs)
TWITTER_GRAPH="${WORKLOAD_DIR}/gapbs/twitter.sg"
[ ! -f "$TWITTER_GRAPH" ] && TWITTER_GRAPH="${WORKLOAD_DIR}/gapbs/twitter_reduced.sg"
[ ! -f "$TWITTER_GRAPH" ] && TWITTER_GRAPH="${WORKLOAD_DIR}/gapbs/benchmark/graphs/raw/twitter.el"

TWITTER_SSSP_GRAPH="${WORKLOAD_DIR}/gapbs/twitter_reduced.wsg"
[ ! -f "$TWITTER_SSSP_GRAPH" ] && TWITTER_SSSP_GRAPH="${WORKLOAD_DIR}/gapbs/twitter.wsg"
[ ! -f "$TWITTER_SSSP_GRAPH" ] && TWITTER_SSSP_GRAPH="${WORKLOAD_DIR}/gapbs/twitter_reduced.el"
[ ! -f "$TWITTER_SSSP_GRAPH" ] && TWITTER_SSSP_GRAPH="${WORKLOAD_DIR}/gapbs/benchmark/graphs/raw/twitter_reduced.el"

KRON_GRAPH="${WORKLOAD_DIR}/gapbs/kron26.sg"
URAND_GRAPH="${WORKLOAD_DIR}/gapbs/urand26.sg"

KRON25_GRAPH="${WORKLOAD_DIR}/gapbs/kron25.wsg"
URAND25_GRAPH="${WORKLOAD_DIR}/gapbs/urand25.wsg"

show_help() {
    echo "=========================================================================================="
    echo " Pure Workload Execution Dispatcher"
    echo "=========================================================================================="
    echo "Usage:"
    echo "  $0 [TARGET_ALIAS] [DATASET: kron | urand | twitter]"
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message and exit"
    echo "  --get-cmd      Print the command string instead of executing"
    echo ""
    echo "Available Targets:"
    echo "  stream, stream_hot, stream_phases,"
    echo "  gapbs_pr, gapbs_tc, gapbs_bfs, gapbs_bc, gapbs_cc, gapbs_sssp,"
    echo "  silo_tpcc, silo_ycsb, silo_queue, silo_bid, silo_encstress (or silo [bench]),"
    echo "  redis, xsbench, spec_mcf"
    echo "=========================================================================================="
    exit 0
}

GET_CMD_ONLY=0
if [ "$1" == "--get-cmd" ]; then
    GET_CMD_ONLY=1
    shift
fi

if [ -z "$1" ] || [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    show_help
fi

TARGET="$1"
DATASET_INPUT="${2:-kron}"

resolve_cmd() {
    local t="$1"
    local ds="$2"
    local graph_arg=""
    local cmd=""
    local RUN_PREFIX="numactl --preferred=0"

    if [[ "$t" == gapbs_* ]]; then
        if [ "$ds" == "twitter" ]; then
            if [ "$t" == "gapbs_sssp" ]; then
                graph_arg="-f ${TWITTER_SSSP_GRAPH}"
            else
                graph_arg="-f ${TWITTER_GRAPH} -s"
            fi
        elif [ "$ds" == "urand" ]; then
            if [ "$t" == "gapbs_sssp" ]; then
                graph_arg="-f ${URAND25_GRAPH}"
            else
                graph_arg="-f ${URAND_GRAPH}"
            fi
        else
            # Default to Kronecker (kron)
            if [ "$t" == "gapbs_sssp" ]; then
                graph_arg="-f ${KRON25_GRAPH}"
            else
                graph_arg="-f ${KRON_GRAPH}"
            fi
        fi
    fi

    local SILO_BIN="${WORKLOAD_DIR}/silo/out-perf.masstree/benchmarks/dbtest"
    [ ! -f "$SILO_BIN" ] && SILO_BIN="${WORKLOAD_DIR}/silo/out-perf/benchmarks/dbtest"
    local SILO_LIB="${WORKLOAD_DIR}/silo/lib"

    local REDIS_RUN_SCRIPT="${WORKLOAD_DIR}/scripts/run_redis.sh"

    local SPEC_BIN="${WORKLOAD_DIR}/spec/mcf"
    [ ! -f "$SPEC_BIN" ] && SPEC_BIN="${WORKLOAD_DIR}/spec_cpu/mcf"
    [ ! -f "$SPEC_BIN" ] && SPEC_BIN="${WORKLOAD_DIR}/spec/505.mcf_r/mcf_r_base"

    case "$t" in
        stream|stream_classic|stream_c)
            cmd="${RUN_PREFIX} ${WORKLOAD_DIR}/stream/stream"
            ;;
        stream_hot)
            cmd="${RUN_PREFIX} ${WORKLOAD_DIR}/stream/stream_hot"
            ;;
        stream_phases|stream_phase)
            cmd="${RUN_PREFIX} ${WORKLOAD_DIR}/stream/stream_phases"
            ;;
        gapbs_pr)
            cmd="${RUN_PREFIX} ${WORKLOAD_DIR}/gapbs/pr     ${graph_arg} -i ${GAPBS_PR_ITERS} -t ${GAPBS_PR_TOLERANCE}   -n ${GAPBS_TRIALS}"
            ;;
        gapbs_tc)
            cmd="${RUN_PREFIX} ${WORKLOAD_DIR}/gapbs/tc     ${graph_arg}                        -n ${GAPBS_TRIALS}"
            ;;
        gapbs_bfs)
            cmd="${RUN_PREFIX} ${WORKLOAD_DIR}/gapbs/bfs    ${graph_arg} -r ${GAPBS_BFS_ROOT}   -n ${GAPBS_BFS_TRIALS}"
            ;;
        gapbs_bc)
            cmd="${RUN_PREFIX} ${WORKLOAD_DIR}/gapbs/bc     ${graph_arg} -i ${GAPBS_BC_ITERS}   -n ${GAPBS_TRIALS}"
            ;;
        gapbs_cc)
            cmd="${RUN_PREFIX} ${WORKLOAD_DIR}/gapbs/cc     ${graph_arg}                        -n ${GAPBS_TRIALS}"
            ;;
        gapbs_sssp)
            cmd="${RUN_PREFIX} ${WORKLOAD_DIR}/gapbs/sssp   ${graph_arg} -d ${GAPBS_SSSP_DELTA} -n ${GAPBS_TRIALS}"
            ;;
        silo|silo_tpcc)
            cmd="env LD_LIBRARY_PATH=${SILO_LIB}:${LD_LIBRARY_PATH:-} ${RUN_PREFIX} ${SILO_BIN} --verbose --bench tpcc --num-threads ${WORKLOAD_CORES} --scale-factor 180 --runtime ${SILO_RUNTIME}"
            ;;
        silo_ycsb)
            cmd="env LD_LIBRARY_PATH=${SILO_LIB}:${LD_LIBRARY_PATH:-} ${RUN_PREFIX} ${SILO_BIN} --verbose --bench ycsb --num-threads ${WORKLOAD_CORES} --scale-factor 95000 --runtime ${SILO_RUNTIME}"
            ;;
        silo_queue)
            cmd="env LD_LIBRARY_PATH=${SILO_LIB}:${LD_LIBRARY_PATH:-} ${RUN_PREFIX} ${SILO_BIN} --verbose --bench queue --num-threads 1 --scale-factor 1 --runtime ${SILO_RUNTIME}"
            ;;
        silo_bid)
            cmd="env LD_LIBRARY_PATH=${SILO_LIB}:${LD_LIBRARY_PATH:-} ${RUN_PREFIX} ${SILO_BIN} --verbose --bench bid --num-threads ${WORKLOAD_CORES} --scale-factor 55000 --runtime ${SILO_RUNTIME}"
            ;;
        silo_encstress)
            cmd="env LD_LIBRARY_PATH=${SILO_LIB}:${LD_LIBRARY_PATH:-} ${RUN_PREFIX} ${SILO_BIN} --verbose --bench encstress --num-threads ${WORKLOAD_CORES} --scale-factor 95000 --runtime ${SILO_RUNTIME}"
            ;;
        redis)
            cmd="env REDIS_KEYS=\${REDIS_KEYS:-4300000} REDIS_REQUESTS=\${REDIS_REQUESTS:-4300000} ${RUN_PREFIX} ${REDIS_RUN_SCRIPT}"
            ;;
        xsbench)
            cmd="${RUN_PREFIX} ${WORKLOAD_DIR}/xsbench/openmp-threading/XSBench -g 37000 -p 5000000"
            ;;
        spec_mcf|spec_cpu)
            cmd="${RUN_PREFIX} ${SPEC_BIN} ${WORKLOAD_DIR}/spec/inp.in"
            ;;
        *)
            echo "Error: Unknown target '$t'" >&2
            exit 1
            ;;
    esac

    echo "$cmd"
}

CMD=$(resolve_cmd "$TARGET" "$DATASET_INPUT")
if [ "$GET_CMD_ONLY" -eq 1 ]; then
    echo "$CMD"
else
    echo "[exec_workload] Running: $TARGET -> $CMD"
    eval "$CMD"
fi
