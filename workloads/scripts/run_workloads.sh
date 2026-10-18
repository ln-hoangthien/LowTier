#!/bin/bash
# -------------------------------------------------------------------
# Tiered Memory Workload Runner & Orchestrator
# Usage: sudo ./run_workloads.sh [TARGET_ALIAS] [DATASET]
# -------------------------------------------------------------------

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
OUTPUT_DIR="${ROOT_DIR}/workloads/output"
mkdir -p "${OUTPUT_DIR}"

# ------------------------------------------------------------------------------------------
# Help / Usage Banner & Early Option Parsing
# ------------------------------------------------------------------------------------------
show_help() {
    echo "=========================================================================================="
    echo " Tiered Memory Workload Runner & Orchestrator"
    echo "=========================================================================================="
    echo "Usage (Normal / Manual Runs):"
    echo "  sudo $0 [TARGET_ALIAS] [DATASET: kron | urand | twitter | ...] [OPTIONS]"
    echo ""
    echo "Usage (Automated Regression Only):"
    echo "  sudo $0 [TARGET_ALIAS] [DATASET] [TIER_RATIO: 1:1 | 1:2 | ...] [OPTIONS]"
    echo ""
    echo "Arguments & Options:"
    echo "  TARGET_ALIAS   Workload target (e.g. stream_copy, gapbs_pr, silo_tpcc, redis, xsbench, spec2026_<bench>)"
    echo "  DATASET        Graph dataset for GAPBS (kron, urand, twitter, web, road)"
    echo "  TIER_RATIO     [REGRESSION ONLY] Fast:Slow ratio tag passed by automated orchestrators"
    echo "                 (e.g., regression/run_auto_regression.sh) to label logs after reboot."
    echo "  THP / THP_MODE Transparent Huge Pages mode: always, madvise, never"
    echo "                 e.g. echo always|madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled"
    echo "  sudo $0 stream_copy"
    echo "  sudo $0 gapbs_pr urand"
    echo "  sudo $0 gapbs_bc kron"
    echo "  sudo $0 silo_tpcc"
    echo "  sudo $0 redis"
    echo "  sudo $0 spec2026_820.cloverleaf_s"
    echo "  sudo $0 spec2026_709.cactus_r"
    echo "=========================================================================================="
    exit 0
}

if [ -z "${1:-}" ] || [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    show_help
fi

# Log message to both stdout and REGRESS_LOG_FILE
log_echo() {
    echo -e "$@"
    if [ -n "${REGRESS_LOG_FILE:-}" ]; then
        echo -e "$@" >> "${REGRESS_LOG_FILE}"
    fi
}

# ------------------------------------------------------------------------------------------
# Parameter Normalization & Validation
# ------------------------------------------------------------------------------------------
normalize_params() {
    PREFETCH_ENABLED="${PREFETCH_ENABLED:-1}"
    PREFETCH_ADAPTIVE="${PREFETCH_ADAPTIVE:-1}"
    PREFETCH_HINT="${PREFETCH_HINT:-0}"
    PREFETCH_PROMOTE_DISTANCE="${PREFETCH_PROMOTE_DISTANCE:-5}"
    PREFETCH_DEMOTE_DISTANCE="${PREFETCH_DEMOTE_DISTANCE:-2}"
    PREFETCH_MIN_DISTANCE="${PREFETCH_MIN_DISTANCE:-0}"
    PREFETCH_MAX_DISTANCE="${PREFETCH_MAX_DISTANCE:-12}"
    THP_MODE="${THP_MODE:-${THP:-madvise}}"

    # Shorthand format: p<prom>_d<dem> or <prom>:<dem> (optional _h<hint> or _hint<hint>)
    if [[ "${PREFETCH_PROMOTE_DISTANCE}" =~ ^p([0-9]+)_d([0-9]+)(_h([0-9]+)|_hint([0-9]+))?$ || "${PREFETCH_PROMOTE_DISTANCE}" =~ ^([0-9]+):([0-9]+)$ ]]; then
        PREFETCH_DEMOTE_DISTANCE="${BASH_REMATCH[2]}"
        PREFETCH_PROMOTE_DISTANCE="${BASH_REMATCH[1]}"
        [ -n "${BASH_REMATCH[4]:-}" ] && PREFETCH_HINT="${BASH_REMATCH[4]}"
        [ -n "${BASH_REMATCH[5]:-}" ] && PREFETCH_HINT="${BASH_REMATCH[5]}"
    fi

    # Shorthand format: min<min>_max<max> or <min>:<max>
    if [[ "${PREFETCH_MIN_DISTANCE}" =~ ^min([0-9]+)_max([0-9]+)$ || "${PREFETCH_MIN_DISTANCE}" =~ ^([0-9]+):([0-9]+)$ ]]; then
        PREFETCH_MAX_DISTANCE="${BASH_REMATCH[2]}"
        PREFETCH_MIN_DISTANCE="${BASH_REMATCH[1]}"
    fi

    # Distance 0 validation
    if [ "${PREFETCH_PROMOTE_DISTANCE}" == "0" ] || [ "${PREFETCH_DEMOTE_DISTANCE}" == "0" ]; then
        if [ "${PREFETCH_ADAPTIVE}" == "1" ]; then
            log_echo "\033[1;31m[ERROR] PREFETCH_ADAPTIVE=1 cannot be used with distance 0!\033[0m" >&2
            exit 1
        fi
        PREFETCH_ENABLED=0
    fi
}

# ------------------------------------------------------------------------------------------
# Target, Dataset, and Ratio Resolution
# ------------------------------------------------------------------------------------------
resolve_workload_target() {
    TARGET="$1"
    DATASET="${2:-}"
    RATIO="${3:-${TIER_RATIO:-}}"

    # If $2 matches ratio format (e.g. 1:1, 1:2, 1_1, ratio_1_1) and RATIO was not set
    if [[ "$DATASET" =~ ^[0-9]+[:_][0-9]+$ || "$DATASET" =~ ^ratio_[0-9]+[:_][0-9]+$ ]] && [ -z "${3:-}" ]; then
        RATIO="$DATASET"
        DATASET=""
    fi

    # Decompose composite GAPBS benchmark alias (e.g. gapbs_bc_kron -> gapbs_bc kron)
    if [[ "$TARGET" =~ ^(gapbs_[a-z]+)_(kron|urand|twitter|web|road)$ ]]; then
        [ -z "$DATASET" ] && DATASET="${BASH_REMATCH[2]}"
        TARGET="${BASH_REMATCH[1]}"
    fi

    # Format ratio tag for filenames (e.g. 1:1 -> 1_1)
    RATIO_TAG=""
    if [ -n "$RATIO" ]; then
        RATIO_TAG="${RATIO//:/_}"
        RATIO_TAG="${RATIO_TAG#ratio_}"
    fi

    # Validate workload target command early before making system changes
    WORKLOAD_CMD=$(RATIO_TAG="${RATIO_TAG}" "${SCRIPT_DIR}/exec_workload.sh" --get-cmd "$TARGET" ${DATASET:+"$DATASET"} 2>/dev/null || true)
    if [ -z "$WORKLOAD_CMD" ]; then
        log_echo "\033[1;31m[ERROR] Failed to resolve executable command for target '$*'. Check exec_workload.sh --help.\033[0m" >&2
        exit 1
    fi

    # Target executable name for baselines requiring process hooking/attachment
    TARGET_EXE_NAME=$("${SCRIPT_DIR}/exec_workload.sh" --get-target-exe "$TARGET" 2>/dev/null || true)
}

# ------------------------------------------------------------------------------------------
# Output Directory and Log Path Resolution
# ------------------------------------------------------------------------------------------
resolve_output_paths() {
    KERNEL_VER="$(uname -r)"
    TARGET_DIR="${TARGET_DIR:-${OUTPUT_DIR}/${KERNEL_VER}}"
    mkdir -p "${TARGET_DIR}"

    FILENAME_SUFFIX="${TARGET}${DATASET:+_${DATASET}}${RATIO_TAG:+_${RATIO_TAG}}"
    if [[ "${KERNEL_VER,,}" =~ prefetch ]]; then
        local adapt_tag=""
        if [ "${PREFETCH_ADAPTIVE:-}" == "1" ]; then
            adapt_tag="_min${PREFETCH_MIN_DISTANCE}_max${PREFETCH_MAX_DISTANCE}_adapt"
        elif [ "${PREFETCH_ADAPTIVE:-}" == "0" ]; then
            adapt_tag="_static"
        fi

        if [ "${PREFETCH_ENABLED:-1}" == "0" ] || ([ "${PREFETCH_PROMOTE_DISTANCE:-0}" == "0" ] && [ "${PREFETCH_DEMOTE_DISTANCE:-0}" == "0" ]); then
            FILENAME_SUFFIX+="_0"
        else
            FILENAME_SUFFIX+="_p${PREFETCH_PROMOTE_DISTANCE}_d${PREFETCH_DEMOTE_DISTANCE}_h${PREFETCH_HINT}${adapt_tag}"
        fi
    fi
    FILENAME_SUFFIX+="_${THP_MODE}"

    REGRESS_LOG_FILE="${TARGET_DIR}/regress_${FILENAME_SUFFIX}.log"
    rm -f "${REGRESS_LOG_FILE}"
}

# Execute early resolution and validation
normalize_params
resolve_workload_target "$@"
resolve_output_paths

# ------------------------------------------------------------------------------------------
# Root Privilege Elevation
# ------------------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "[!] This script requires root privileges. Elevating via sudo..."
    exec sudo env PATH="$PATH" ROOT_DIR="$ROOT_DIR" TIER_RATIO="${TIER_RATIO:-}" RATIO="${RATIO:-}" \
        THP_MODE="${THP_MODE:-madvise}" \
        PREFETCH_ENABLED="${PREFETCH_ENABLED}" PREFETCH_ADAPTIVE="${PREFETCH_ADAPTIVE}" \
        PREFETCH_PROMOTE_DISTANCE="${PREFETCH_PROMOTE_DISTANCE}" \
        PREFETCH_DEMOTE_DISTANCE="${PREFETCH_DEMOTE_DISTANCE}" \
        PREFETCH_MIN_DISTANCE="${PREFETCH_MIN_DISTANCE}" \
        PREFETCH_MAX_DISTANCE="${PREFETCH_MAX_DISTANCE}" \
        PREFETCH_HINT="${PREFETCH_HINT}" "$0" "$@"
fi

# ------------------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------------------

# Safely read sysfs attribute file
read_sysfs() {
    local file="$1"
    [ -f "$file" ] && cat "$file" 2>/dev/null || echo ""
}

# Query current Node 0 free memory in MB
get_node0_free_mb() {
    local kb
    kb=$(awk '/Node 0 MemFree/{print $4}' /sys/devices/system/node/node0/meminfo 2>/dev/null || echo 0)
    echo $(( kb / 1024 ))
}

# Query current Node 1 free memory in MB
get_node1_free_mb() {
    local kb
    kb=$(awk '/Node 1 MemFree/{print $4}' /sys/devices/system/node/node1/meminfo 2>/dev/null || echo 0)
    echo $(( kb / 1024 ))
}

# Evict all background user processes from Node 0 to Node 1
evict_background_to_node1() {
    if command -v migratepages >/dev/null 2>&1; then
        for pid in $(ps -eo pid= | awk '$1 ~ /^[0-9]+$/ && $1 > 1 {print $1}'); do
            if [ "$pid" -eq "$$" ] || [ "$pid" -eq "$PPID" ]; then
                continue
            fi
            migratepages "$pid" 0 1 2>/dev/null || true
        done
    fi
}

# Clean memory caches, drop residual slab, compact memory, and quiesce system
clean_memory_caches() {
    local drop_mode="${1:-3}"
    local label=""
    if [ "$drop_mode" -eq 2 ]; then
        label=" (slab metadata only, preserving file pagecache)"
    elif [ "$drop_mode" -eq 1 ]; then
        label=" (pagecache only)"
    else
        label=" (all caches & buffers)"
    fi

    log_echo "[*] Cleaning memory caches${label}, compacting memory & quiescing..."
    killall -9 pact bpftrace perf redis-server dbtest XSBench pr bc bfs cc sssp tc specperl runcpu specmake 2>/dev/null || true
    ipcs -m 2>/dev/null | awk '$2 ~ /^[0-9]+$/ {print $2}' | xargs -r ipcrm -m 2>/dev/null || true
    swapoff -a 2>/dev/null || true

    # Evict background user processes (IDE, language server, shells) from Node 0 to Node 1
    evict_background_to_node1

    # Quiesce, drop caches, and compact memory across iterations
    local max_attempts=3
    for attempt in $(seq 1 $max_attempts); do
        sync
        echo "${drop_mode}" > /proc/sys/vm/drop_caches 2>/dev/null || true
        sleep 3
        echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
        sleep 3
        log_echo "[+] Headroom at Attempt=${attempt}: Node 0=$(get_node0_free_mb) MB | Node 1=$(get_node1_free_mb) MB free"
    done
    local free0_mb=$(get_node0_free_mb)
    local free1_mb=$(get_node1_free_mb)
    log_echo "[+] Clean Headroom at T=0: Node 0 = ${free0_mb} MB free | Node 1 = ${free1_mb} MB free"

    # Re-sweep background processes and drop residual slab at T=0 to guarantee fresh headroom
    evict_background_to_node1
    sysctl -w vm.drop_caches="${drop_mode}" >/dev/null 2>&1 || echo "${drop_mode}" > /proc/sys/vm/drop_caches 2>/dev/null || true
    sleep 1

    local free0_mb=$(get_node0_free_mb)
    local free1_mb=$(get_node1_free_mb)
    log_echo "[+] Clean Headroom at T=0: Node 0 = ${free0_mb} MB free | Node 1 = ${free1_mb} MB free"
}

# Clean up processes, daemons, restore machine configuration, and set user ownership
cleanup() {
    trap - INT TERM EXIT
    killall -9 perf 2>/dev/null || true

    # Clean up telemetry temporary state
    "${SCRIPT_DIR}/monitor_performance.sh" --cleanup 2>/dev/null || true

    # Stop any active baseline autotie daemons
    "${SCRIPT_DIR}/setup_kernel.sh" --autotie-stop 2>/dev/null || true

    # Clean up kernel tiering state and unload baseline modules
    "${SCRIPT_DIR}/setup_kernel.sh" --cleanup 2>/dev/null || true

    # Restore machine hardware configuration (hyperthreads, turbo, governor)
    "${SCRIPT_DIR}/setup_machine.sh" --restore 2>/dev/null || true

    # Ensure all generated output files and directories have correct user ownership
    if [ -n "${SUDO_USER:-}" ]; then
        chown -R "${SUDO_USER}:${SUDO_USER}" "${TARGET_DIR}" 2>/dev/null || true
    fi
}
trap cleanup INT TERM EXIT

# ------------------------------------------------------------------------------------------
# Step 1: Machine Setup (CPU & Uncore Frequency Locking, Topology Pinning)
# ------------------------------------------------------------------------------------------
log_echo "[*] Step 1: Configuring machine hardware environment..."
REGRESS_LOG_FILE="${REGRESS_LOG_FILE:-}" "${SCRIPT_DIR}/setup_machine.sh"

# ------------------------------------------------------------------------------------------
# Step 2: Kernel & Tiered Memory Setup (Baselines, Prefetch Sysfs, THP)
# ------------------------------------------------------------------------------------------
log_echo "[*] Step 2: Configuring kernel tiering and prefetch parameters..."
THP_MODE="${THP_MODE}" \
PREFETCH_ENABLED="${PREFETCH_ENABLED}" \
PREFETCH_ADAPTIVE="${PREFETCH_ADAPTIVE}" \
PREFETCH_HINT="${PREFETCH_HINT}" \
PREFETCH_PROMOTE_DISTANCE="${PREFETCH_PROMOTE_DISTANCE}" \
PREFETCH_DEMOTE_DISTANCE="${PREFETCH_DEMOTE_DISTANCE}" \
PREFETCH_MIN_DISTANCE="${PREFETCH_MIN_DISTANCE}" \
PREFETCH_MAX_DISTANCE="${PREFETCH_MAX_DISTANCE}" \
TARGET_EXE_NAME="${TARGET_EXE_NAME}" \
REGRESS_LOG_FILE="${REGRESS_LOG_FILE:-}" \
"${SCRIPT_DIR}/setup_kernel.sh"

# Print banner to stdout and append to regression log
{
    echo "=========================================================================================="
    echo " Starting Tiered Memory Workload Execution:"
    echo " Kernel Version : ${KERNEL_VER}"
    echo " Workload       : ${TARGET} ${DATASET:-}"
    [ -n "$RATIO" ] && echo " Tier Ratio     : ${RATIO}"
    echo " THP Mode       : ${THP_MODE} ($(read_sysfs /sys/kernel/mm/transparent_hugepage/enabled))"
    echo " Current Memmap : $(grep -oE 'memmap=[^ ]+' /proc/cmdline 2>/dev/null || echo 'none')"
    echo " Regression Log : ${REGRESS_LOG_FILE}"
    echo "=========================================================================================="
} | tee -a "${REGRESS_LOG_FILE:-/dev/null}"

# ------------------------------------------------------------------------------------------
# Step 3: Workload Execution Workflow
# ------------------------------------------------------------------------------------------

# Step 1: Clean all caches & wipe stale state BEFORE preloading dataset
clean_memory_caches 3

# Step 2: Preload dataset into target tier (Node 1 or Node 0)
PRELOAD_CMD=$(RATIO_TAG="${RATIO_TAG}" "${SCRIPT_DIR}/exec_workload.sh" --get-preload-cmd "$TARGET" ${DATASET:+"$DATASET"})
if [ -n "${PRELOAD_CMD}" ]; then
    log_echo "[+] Preloading dataset onto Slow Tier (Node 1): ${PRELOAD_CMD}"
    eval "${PRELOAD_CMD}" 2>&1 | tee -a "${REGRESS_LOG_FILE:-/dev/null}"
    sync
    sleep 2
fi

# Step 3: Clean caches AFTER preloading: Drop slab metadata only (mode 2, preserving preloaded dataset in RAM),
# defragment Node 0 memory frames, and report headroom before launch.
clean_memory_caches 2

# Step 4: Clear kernel dmesg ring buffer and reset prefetch stats so the log only contains this run's data
dmesg -c >/dev/null 2>&1 || true
[ -f "/sys/kernel/mm/page_prefetch/stats_reset" ] && echo 1 > /sys/kernel/mm/page_prefetch/stats_reset 2>/dev/null || true
log_echo "------------------------------------------------------------------------------------------"

# Step 5: Execute workload workflow:
#   1. Start stats baseline: monitor_performance.sh --start
#   2. Start kernel autotie watcher (PACT daemon attacher)
#   3. Execute workload command under /usr/bin/time -v directly
#   4. Stop kernel autotie daemons
#   5. Calculate delta and print performance report: monitor_performance.sh --stop
evict_background_to_node1

# Wrap workload command if baseline requires in-process hooking (e.g. HybridTier LD_PRELOAD)
WORKLOAD_EXEC_CMD=$("${SCRIPT_DIR}/setup_kernel.sh" --wrap-cmd ${WORKLOAD_CMD})
log_echo "[run_workloads] Running workload: ${WORKLOAD_EXEC_CMD}"

# 1. Start baseline telemetry capture
"${SCRIPT_DIR}/monitor_performance.sh" --start

# 2. Start asynchronous baseline autotie watcher (e.g. PACT daemon attacher)
TARGET_EXE_NAME="${TARGET_EXE_NAME}" \
TARGET_DIR="${TARGET_DIR}" \
FILENAME_SUFFIX="${FILENAME_SUFFIX}" \
REGRESS_LOG_FILE="${REGRESS_LOG_FILE}" \
"${SCRIPT_DIR}/setup_kernel.sh" --autotie-start

# 3. Execute the workload command with GNU time to capture runtime & Peak RSS
log_echo "------------------------------------------------------------------------------------------"
/usr/bin/time -v bash -c "exec ${WORKLOAD_EXEC_CMD}" 2>&1 | tee -a "${REGRESS_LOG_FILE}"
STATUS="${PIPESTATUS[0]}"

# 4. Stop baseline autotie daemons once workload completes
"${SCRIPT_DIR}/setup_kernel.sh" --autotie-stop

# 5. Calculate delta and print performance report
"${SCRIPT_DIR}/monitor_performance.sh" --stop ${WORKLOAD_EXEC_CMD} 2>&1 | tee -a "${REGRESS_LOG_FILE}"

log_echo "------------------------------------------------------------------------------------------"
log_echo "[+] Workload completed. Compiling final statistics..."

# Append prefetch hardware stats to PACT and regression log files if available
prefetch_stats_sysfs=""
[ -f "/sys/kernel/mm/page_prefetch/stats" ] && prefetch_stats_sysfs="/sys/kernel/mm/page_prefetch/stats"
[ -f "/sys/kernel/mm/pact_prefetch/stats" ] && prefetch_stats_sysfs="/sys/kernel/mm/pact_prefetch/stats"

if [ -n "${prefetch_stats_sysfs}" ]; then
    log_echo "[*] Capturing Migration Prefetch Statistics (${prefetch_stats_sysfs})..."
    {
        echo ""
        echo "=========================================================================================="
        echo "                 PACT PREFETCH HARDWARE STATS SUMMARY                                     "
        echo "=========================================================================================="
        cat "${prefetch_stats_sysfs}"
        echo "=========================================================================================="
    } | tee -a "${REGRESS_LOG_FILE}" >/dev/null 2>&1 || true
fi

# Step 6: Clean up and restore system configuration (CPUs, background daemons, ownership)
cleanup

echo "=========================================================================================="
echo " Workload Execution Completed."
echo " Regression Summary saved to : ${REGRESS_LOG_FILE}"
echo "=========================================================================================="