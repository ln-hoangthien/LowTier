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

# Configurable SPEC CPU 2026 execution parameters
export SPEC2026_DIR="${SPEC2026_DIR:-${WORKLOAD_DIR}/spec2026}"
export SPEC="${SPEC:-${SPEC2026_DIR}}"
export SPECPERLLIB="${SPECPERLLIB:-${SPEC2026_DIR}/bin/common:${SPEC2026_DIR}/bin/lib:${SPEC2026_DIR}/bin}"
export SPEC_CONFIG="${SPEC_CONFIG:-${WORKLOAD_DIR}/scripts/gcc-linux-x86.cfg}"
export SPEC_COPIES="${SPEC_COPIES:-${WORKLOAD_CORES}}"
export SPEC_THREADS="${SPEC_THREADS:-${WORKLOAD_CORES}}"
export SPEC_EXTRA_ARGS="${SPEC_EXTRA_ARGS:-}"

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
    echo "Environment Variable Overrides (SPEC CPU 2026):"
    echo "  SPEC2026_DIR            SPEC installation directory (default: <ROOT_DIR>/workloads/spec2026)"
    echo "  SPEC_CONFIG             Config file path (default: <ROOT_DIR>/workloads/scripts/gcc-linux-x86.cfg)"
    echo "  SPEC_COPIES             Number of rate copies (default: WORKLOAD_CORES)"
    echo "  SPEC_THREADS            Number of threads per copy (default: WORKLOAD_CORES)"
    echo "  SPEC_EXTRA_ARGS         Additional arguments passed to runcpu (e.g. --fake)"
    echo ""
    echo "Available Targets:"
    echo "  stream, stream_hot, stream_phase,"
    echo "  gapbs_pr, gapbs_tc, gapbs_bfs, gapbs_bc, gapbs_cc, gapbs_sssp,"
    echo "  (supports composite aliases: gapbs_<algo>_<dataset>, e.g., gapbs_bc_kron),"
    echo "  silo_tpcc, silo_ycsb, silo_queue, silo_bid, silo_encstress,"
    echo "  redis, xsbench,"
    echo "  SPECrate®2026 benchmarks:"
    echo "    spec2026_706.stockfish_r, spec2026_707.ntest_r, spec2026_708.sqlite_r,"
    echo "    spec2026_709.cactus_r, spec2026_710.omnetpp_r, spec2026_714.cpython_r,"
    echo "    spec2026_721.gcc_r, spec2026_722.palm_r, spec2026_723.llvm_r,"
    echo "    spec2026_727.cppcheck_r, spec2026_729.abc_r, spec2026_731.astcenc_r,"
    echo "    spec2026_734.vpr_r, spec2026_735.gem5_r, spec2026_736.ocio_r,"
    echo "    spec2026_737.gmsh_r, spec2026_748.flightdm_r, spec2026_749.fotonik3d_r,"
    echo "    spec2026_750.sealcrypto_r, spec2026_753.ns3_r, spec2026_765.roms_r,"
    echo "    spec2026_766.femflow_r, spec2026_767.nest_r, spec2026_772.marian_r,"
    echo "    spec2026_777.zstd_r, spec2026_782.lbm_r, spec2026_999.specrand_r,"
    echo "  SPECspeed®2026 benchmarks:"
    echo "    spec2026_800.pot3d_s, spec2026_801.xz_s, spec2026_803.sph_exa_s,"
    echo "    spec2026_807.ntest_s, spec2026_809.cactus_s, spec2026_811.tealeaf_s,"
    echo "    spec2026_816.nab_s, spec2026_817.flac_s, spec2026_820.cloverleaf_s,"
    echo "    spec2026_821.gcc_s, spec2026_822.palm_s, spec2026_823.llvm_s,"
    echo "    spec2026_827.cppcheck_s, spec2026_829.abc_s, spec2026_834.vpr_s,"
    echo "    spec2026_835.gem5_s, spec2026_838.diamond_s, spec2026_846.minizinc_s,"
    echo "    spec2026_849.fotonik3d_s, spec2026_853.ns3_s, spec2026_854.graph500_s,"
    echo "    spec2026_857.namd_s, spec2026_865.roms_s, spec2026_867.nest_s,"
    echo "    spec2026_872.marian_s, spec2026_881.neutron_s, spec2026_998.specrand_s"
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
        spec2026_*)     echo "runcpu" ;;
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

check_spec2026() {
    if [ ! -d "${SPEC2026_DIR}" ]; then
        echo "==========================================================================================" >&2
        echo " [WARNING] SPEC CPU 2026 directory not found: ${SPEC2026_DIR}" >&2
        echo " SPEC CPU 2026 is a proprietary licensed benchmark suite and cannot be distributed" >&2
        echo " or installed automatically with this repository." >&2
        echo "" >&2
        echo " You must obtain SPEC CPU 2026 manually from https://www.spec.org/cpu2026/" >&2
        echo " and install/place it into:" >&2
        echo "   ${SPEC2026_DIR}" >&2
        echo "==========================================================================================" >&2
        exit 1
    fi
    if [ ! -f "${SPEC2026_DIR}/shrc" ] || [ ! -f "${SPEC2026_DIR}/bin/harness/runcpu" ]; then
        echo "==========================================================================================" >&2
        echo " [WARNING] SPEC CPU 2026 installation incomplete in: ${SPEC2026_DIR}" >&2
        echo " Please run './install.sh' inside ${SPEC2026_DIR} to build and install SPEC tools." >&2
        echo "==========================================================================================" >&2
        exit 1
    fi
    if [ ! -f "${SPEC_CONFIG}" ]; then
        echo "==========================================================================================" >&2
        echo " [WARNING] SPEC CPU 2026 configuration file not found: ${SPEC_CONFIG}" >&2
        echo " Default configuration is located at: ${WORKLOAD_DIR}/scripts/gcc-linux-x86.cfg" >&2
        echo "==========================================================================================" >&2
        exit 1
    fi
}

resolve_cmd() {
    local t="$1"
    local ds="$2"
    local graph_file=""
    local cmd=""
    local RUN_PREFIX="env OMP_NUM_THREADS=${OMP_NUM_THREADS} numactl --physcpubind=${SELECTED_CPUS}"
    local r_tag="${RATIO_TAG:-default}"
    local spec_kernel="${KERNEL_VER:-$(uname -r)}"
    local SPEC_OUT_ROOT="${TARGET_DIR:-${WORKLOAD_DIR}/output/${spec_kernel}}/spec2026"
    mkdir -p "${SPEC_OUT_ROOT}"

    local spec_out_args=""
    if [[ "${SPEC_EXTRA_ARGS:-}" != *"--output_root"* ]]; then
        spec_out_args+=" --output_root=${SPEC_OUT_ROOT}"
    fi
    if [[ "${SPEC_EXTRA_ARGS:-}" != *"--expid"* ]]; then
        spec_out_args+=" --expid=${r_tag}"
    fi

    local SPEC_BASE_CMD="${RUN_PREFIX} ${SPEC2026_DIR}/bin/runcpu --config=${SPEC_CONFIG} --copies=${SPEC_COPIES} --threads=${SPEC_THREADS} --size=ref${spec_out_args}"

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
        spec2026_*)
            check_spec2026
            local bname="${t#spec2026_}"
            if [ ! -d "${SPEC2026_DIR}/benchspec/CPU/${bname}" ]; then
                echo "Error: Unknown SPEC CPU 2026 benchmark '$bname'" >&2
                exit 1
            fi
            cmd="${SPEC_BASE_CMD} ${bname}${SPEC_EXTRA_ARGS:+ $SPEC_EXTRA_ARGS}"
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
