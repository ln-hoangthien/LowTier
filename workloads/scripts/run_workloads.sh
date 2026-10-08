#!/bin/bash
# -------------------------------------------------------------------
# Script to run bpftrace latency measurement on NUMA page fault functions
# while executing workloads via run_workloads.sh
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
    echo " bpftrace Latency Profiler for NUMA Page Faults"
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

# ------------------------------------------------------------------------------------------
# Parameter Normalization & Validation
# ------------------------------------------------------------------------------------------
PREFETCH_ENABLED_EXPLICIT=0
if [ -n "${PREFETCH_ENABLED:-}" ] || [ -n "${PREFETCH_ENABLE:-}" ] || [ -n "${prefetch_enabled:-}" ] || [ -n "${prefetch_enable:-}" ]; then
    PREFETCH_ENABLED_EXPLICIT=1
fi

PREFETCH_ENABLED="${PREFETCH_ENABLED:-${PREFETCH_ENABLE:-${prefetch_enabled:-${prefetch_enable:-1}}}}"
PREFETCH_ADAPTIVE="${PREFETCH_ADAPTIVE:-${prefetch_adaptive:-1}}"
PREFETCH_HINT="${PREFETCH_HINT:-${prefetch_hint:-0}}"
PREFETCH_PROMOTE_DISTANCE="${PREFETCH_PROMOTE_DISTANCE:-${prefetch_promote_distance:-4}}"
PREFETCH_DEMOTE_DISTANCE="${PREFETCH_DEMOTE_DISTANCE:-${prefetch_demote_distance:-1}}"
PREFETCH_MIN_DISTANCE="${PREFETCH_MIN_DISTANCE:-${prefetch_min_distance:-1}}"
PREFETCH_MAX_DISTANCE="${PREFETCH_MAX_DISTANCE:-${prefetch_max_distance:-12}}"

# Shorthand format parsers:
# 1) Distance: p<prom>_d<dem> or <prom>:<dem>
if [[ "${PREFETCH_PROMOTE_DISTANCE}" =~ ^p([0-9]+)_d([0-9]+)$ || "${PREFETCH_PROMOTE_DISTANCE}" =~ ^([0-9]+):([0-9]+)$ ]]; then
    PREFETCH_DEMOTE_DISTANCE="${BASH_REMATCH[2]}"
    PREFETCH_PROMOTE_DISTANCE="${BASH_REMATCH[1]}"
fi

# 2) Clamp distance: min<min>_max<max> or <min>:<max>
if [[ "${PREFETCH_MIN_DISTANCE}" =~ ^min([0-9]+)_max([0-9]+)$ || "${PREFETCH_MIN_DISTANCE}" =~ ^([0-9]+):([0-9]+)$ ]]; then
    PREFETCH_MAX_DISTANCE="${BASH_REMATCH[2]}"
    PREFETCH_MIN_DISTANCE="${BASH_REMATCH[1]}"
fi

# Strict Validation: Distance 0 vs PREFETCH_ADAPTIVE and PREFETCH_ENABLED=1
if [ "${PREFETCH_PROMOTE_DISTANCE}" == "0" ] || [ "${PREFETCH_DEMOTE_DISTANCE}" == "0" ]; then
    if [ "${PREFETCH_ADAPTIVE}" == "1" ]; then
        echo -e "\033[1;31m[ERROR] PREFETCH_ADAPTIVE=1 cannot be used with distance 0 (promote=${PREFETCH_PROMOTE_DISTANCE}, demote=${PREFETCH_DEMOTE_DISTANCE})!\033[0m" >&2
        echo -e "\033[1;31m[ERROR] Adaptive prefetch dynamically calculates distance (>= 1). To run without prefetching, set PREFETCH_ENABLED=0 and PREFETCH_ADAPTIVE=0.\033[0m" >&2
        exit 1
    fi
    if [ "${PREFETCH_ENABLED_EXPLICIT}" == "1" ] && [ "${PREFETCH_ENABLED}" == "1" ]; then
        echo -e "\033[1;31m[ERROR] PREFETCH_ENABLED=1 cannot be used with distance 0 (promote=${PREFETCH_PROMOTE_DISTANCE}, demote=${PREFETCH_DEMOTE_DISTANCE})!\033[0m" >&2
        echo -e "\033[1;31m[ERROR] The kernel prefetcher requires distances between 1 and 64 when prefetch is enabled. To disable prefetching, set PREFETCH_ENABLED=0.\033[0m" >&2
        exit 1
    fi
    PREFETCH_ENABLED=0
fi

export PREFETCH_ENABLED PREFETCH_ADAPTIVE PREFETCH_HINT PREFETCH_PROMOTE_DISTANCE PREFETCH_DEMOTE_DISTANCE \
       PREFETCH_MIN_DISTANCE PREFETCH_MAX_DISTANCE

# ------------------------------------------------------------------------------------------
# Target, Dataset, Ratio, and Membind Resolution
# ------------------------------------------------------------------------------------------
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

# Validate workload target command early before making system changes
WORKLOAD_CMD=$("${SCRIPT_DIR}/exec_workload.sh" --get-cmd "$TARGET" ${DATASET:+"$DATASET"} 2>/dev/null || true)
if [ -z "$WORKLOAD_CMD" ]; then
    echo -e "\033[1;31m[ERROR] Failed to resolve executable command for target '$*'. Check exec_workload.sh --help.\033[0m" >&2
    exit 1
fi

# Format ratio for filenames: replace colon ':' with '_' (e.g. 1:1 -> 1_1)
RATIO_TAG=""
if [ -n "$RATIO" ]; then
    RATIO_TAG="${RATIO//:/_}"
    RATIO_TAG="${RATIO_TAG#ratio_}"
fi
export RATIO RATIO_TAG

KERNEL_VER="$(uname -r)"
TARGET_DIR="${TARGET_DIR:-${OUTPUT_DIR}/${KERNEL_VER}}"
mkdir -p "${TARGET_DIR}"
export TARGET_DIR

FILENAME_SUFFIX="${TARGET}${DATASET:+_${DATASET}}${RATIO_TAG:+_${RATIO_TAG}}"
if [[ "${KERNEL_VER,,}" =~ prefetch ]]; then
    ADAPT_TAG=""
    if [ "${PREFETCH_ADAPTIVE:-}" == "1" ]; then
        ADAPT_TAG="_min${PREFETCH_MIN_DISTANCE}_max${PREFETCH_MAX_DISTANCE}_adapt"
    elif [ "${PREFETCH_ADAPTIVE:-}" == "0" ]; then
        ADAPT_TAG="_static"
    fi

    if [ "${PREFETCH_ENABLED:-1}" == "0" ] || ([ "${PREFETCH_PROMOTE_DISTANCE:-0}" == "0" ] && [ "${PREFETCH_DEMOTE_DISTANCE:-0}" == "0" ]); then
        FILENAME_SUFFIX+="_0"
    else
        FILENAME_SUFFIX+="_p${PREFETCH_PROMOTE_DISTANCE}_d${PREFETCH_DEMOTE_DISTANCE}${ADAPT_TAG}"
    fi
fi
FILENAME_SUFFIX+="_${THP_MODE}"
export FILENAME_SUFFIX

LOG_FILE="${TARGET_DIR}/bpftrace_numa_page_${FILENAME_SUFFIX}.log"
PERF_LOG_FILE="${TARGET_DIR}/perf_bandwidth_${FILENAME_SUFFIX}.log"
REGRESS_LOG_FILE="${TARGET_DIR}/regress_${FILENAME_SUFFIX}.log"
DMESG_LOG_FILE="${TARGET_DIR}/dmesg_${FILENAME_SUFFIX}.log"
export REGRESS_LOG_FILE DMESG_LOG_FILE

# Remove any stale output files for this specific workload before running
rm -f "${LOG_FILE}" "${PERF_LOG_FILE}" "${REGRESS_LOG_FILE}" "${DMESG_LOG_FILE}"

# Export target executable name for baselines requiring process hooking/attachment (HybridTier / PACT)
if [ -z "${TARGET_EXE_NAME:-}" ]; then
    TARGET_EXE_NAME=$("${SCRIPT_DIR}/exec_workload.sh" --get-target-exe "$TARGET" 2>/dev/null || true)
    export TARGET_EXE_NAME
fi

# Workload CPU allocation: 24 cores for workload (0..23), 8 cores for background profilers/kswapd (24..31)
export WORKLOAD_CORES="${WORKLOAD_CORES:-24}"
export SELECTED_CPUS="${SELECTED_CPUS:-$(seq -s, 0 $(( WORKLOAD_CORES - 1 )))}"

# ------------------------------------------------------------------------------------------
# Root Privilege Elevation
# ------------------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "[!] This script requires root privileges for bpftrace. Elevating via sudo..."
    exec sudo env PATH="$PATH" ROOT_DIR="$ROOT_DIR" TIER_RATIO="${TIER_RATIO:-}" RATIO="${RATIO:-}" \
        THP_MODE="${THP_MODE:-madvise}" \
        PREFETCH_ENABLED="${PREFETCH_ENABLED}" PREFETCH_ADAPTIVE="${PREFETCH_ADAPTIVE}" \
        PREFETCH_PROMOTE_DISTANCE="${PREFETCH_PROMOTE_DISTANCE}" \
        PREFETCH_DEMOTE_DISTANCE="${PREFETCH_DEMOTE_DISTANCE}" \
        PREFETCH_MIN_DISTANCE="${PREFETCH_MIN_DISTANCE}" \
        PREFETCH_MAX_DISTANCE="${PREFETCH_MAX_DISTANCE}" \
        PREFETCH_HINT="${PREFETCH_HINT}" WORKLOAD_CORES="${WORKLOAD_CORES:-}" \
        CPU_GOVERNOR="${CPU_GOVERNOR:-}" CPU_MIN_FREQ="${CPU_MIN_FREQ:-}" CPU_MAX_FREQ="${CPU_MAX_FREQ:-}" \
        UNCORE_PKG0_MIN="${UNCORE_PKG0_MIN:-}" UNCORE_PKG0_MAX="${UNCORE_PKG0_MAX:-}" \
        UNCORE_PKG1_MIN="${UNCORE_PKG1_MIN:-}" UNCORE_PKG1_MAX="${UNCORE_PKG1_MAX:-}" "$0" "$@"
fi

# ------------------------------------------------------------------------------------------
# CPU & Uncore Frequency Locking (Deterministic Academic Benchmarking)
# ------------------------------------------------------------------------------------------
# 1. Uncore Frequency: Lock Fast Tier (Pkg 0) to 2.5 GHz, degrade Slow Tier (Pkg 1) to 1.3 GHz
[ -w /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/min_freq_khz ] && echo "${UNCORE_PKG0_MIN:-2500000}" > /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/min_freq_khz 2>/dev/null || true
[ -w /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/max_freq_khz ] && echo "${UNCORE_PKG0_MAX:-2500000}" > /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/max_freq_khz 2>/dev/null || true
[ -w /sys/devices/system/cpu/intel_uncore_frequency/package_01_die_00/min_freq_khz ] && echo "${UNCORE_PKG1_MIN:-1300000}" > /sys/devices/system/cpu/intel_uncore_frequency/package_01_die_00/min_freq_khz 2>/dev/null || true
[ -w /sys/devices/system/cpu/intel_uncore_frequency/package_01_die_00/max_freq_khz ] && echo "${UNCORE_PKG1_MAX:-1300000}" > /sys/devices/system/cpu/intel_uncore_frequency/package_01_die_00/max_freq_khz 2>/dev/null || true

# 2. CPU Governor: Lock all online cores to 'performance' (prevents scheduler downclocking)
CPU_GOVERNOR="${CPU_GOVERNOR:-performance}"
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "$g" ] && echo "${CPU_GOVERNOR}" > "$g" 2>/dev/null || true
done

# 3. CPU Minimum Frequency: Prevent cores from dropping below base clock (2.1 GHz)
CPU_MIN_FREQ="${CPU_MIN_FREQ:-2100000}"
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq; do
    [ -w "$f" ] && echo "${CPU_MIN_FREQ}" > "$f" 2>/dev/null || true
done

# 4. CPU Maximum Frequency: Optional ceiling (if specified by user, e.g. for fixed-frequency runs)
if [ -n "${CPU_MAX_FREQ:-}" ]; then
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
        [ -w "$f" ] && echo "${CPU_MAX_FREQ}" > "$f" 2>/dev/null || true
    done
fi

# Check if bpftrace is installed
if ! command -v bpftrace &>/dev/null; then
    echo "[ERROR] bpftrace is not installed. Please install it (e.g., sudo apt install bpftrace)."
    exit 1
fi

# ------------------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------------------

# Log message to both stdout and REGRESS_LOG_FILE
log_echo() {
    echo "$@"
    if [ -n "${REGRESS_LOG_FILE:-}" ]; then
        echo "$@" >> "${REGRESS_LOG_FILE}"
    fi
}

# Safely read sysfs attribute file
read_sysfs() {
    local file="$1"
    [ -f "$file" ] && cat "$file" 2>/dev/null || echo ""
}

# Write and verify kernel sysfs attribute
write_sysfs_verified() {
    local file="$1" val="$2" label="${3:-$(basename "$1")}"
    [ -f "$file" ] || return 1

    if ! echo "$val" > "$file" 2>/dev/null; then
        echo -e "\033[1;33m[WARNING] Failed to write '$val' to sysfs attribute '$label' ($file)!\033[0m" >&2
        return 1
    fi
    local readback
    read -r readback < "$file" 2>/dev/null || true
    if [ "$readback" != "$val" ]; then
        echo -e "\033[1;33m[WARNING] Sysfs mismatch for '$label': requested '$val', but kernel read back '$readback'!\033[0m" >&2
        return 1
    fi
    return 0
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

# Online or offline hyperthreads (CPUs 32..64)
set_cpus_online() {
    local state="$1"
    for cpu in /sys/devices/system/cpu/cpu{32..64}/online; do
        [ -f "$cpu" ] && echo "$state" > "$cpu" 2>/dev/null || true
    done
}

ensure_module_loaded() {
    local mod_name="$1" base_dir="$2" sub_dir="$3" label="$4"
    local mod_id="${mod_name//-/_}"

    grep -q "^${mod_id}[[:space:]]" /proc/modules 2>/dev/null && return 0

    local target_dir="${base_dir}${sub_dir:+/${sub_dir}}"
    local mod_file="${target_dir}/${mod_name}.ko"
    if [ ! -f "${mod_file}" ]; then
        mod_file=$(ls "${ROOT_DIR}"/baselines/*/${sub_dir:+${sub_dir}/}${mod_name}.ko 2>/dev/null | head -n 1 || true)
    fi

    if [ ! -f "${mod_file}" ] && [ -d "${target_dir}" ]; then
        log_echo "[*] Compiling ${label} ${mod_name}.ko..."
        if [ -d "${base_dir}/linux" ]; then
            make -C "${base_dir}/linux" M="${target_dir}" modules >/dev/null 2>&1 || true
        else
            make -C "${target_dir}" >/dev/null 2>&1 || true
        fi
        mod_file="${target_dir}/${mod_name}.ko"
    fi

    if [ -f "${mod_file}" ]; then
        log_echo "[*] Loading ${label} ${mod_name} module (${mod_file})..."
        insmod "${mod_file}" 2>/dev/null || true
    fi

    if grep -q "^${mod_id}[[:space:]]" /proc/modules 2>/dev/null; then
        log_echo "[+] ${label} ${mod_name} module loaded."
        return 0
    else
        echo -e "\033[1;33m[WARNING] ${label} kernel detected but ${mod_name}.ko is not loaded!\033[0m" >&2
        return 1
    fi
}

# Evict all background user processes from Node 0 to Node 1
evict_background_to_node1() {
    local target_user="${SUDO_USER:-}"
    if [ -n "$target_user" ] && [ "$target_user" != "root" ] && command -v migratepages >/dev/null 2>&1; then
        for pid in $(pgrep -u "$target_user"); do
            [ "$pid" -eq "$$" ] && continue
            migratepages "$pid" 0 1 2>/dev/null || true
        done
    fi
}

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

    # Quiesce and drop caches across multiple iterations
    local max_attempts=2
    for attempt in $(seq 1 $max_attempts); do
        sync
        sysctl -w vm.drop_caches="${drop_mode}" >/dev/null 2>&1 || echo "${drop_mode}" > /proc/sys/vm/drop_caches 2>/dev/null || true
        sleep 2
        log_echo "[+] Headroom at Attempt=${attempt}: Node 0=$(get_node0_free_mb) MB | Node 1=$(get_node1_free_mb) MB free"
    done

    # Compact memory to reduce external fragmentation
    sysctl -w vm.compact_memory=1 >/dev/null 2>&1 || echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
    sleep 3

    # Re-sweep background processes and drop residual slab at T=0 to guarantee fresh headroom
    evict_background_to_node1
    sysctl -w vm.drop_caches="${drop_mode}" >/dev/null 2>&1 || echo "${drop_mode}" > /proc/sys/vm/drop_caches 2>/dev/null || true
    sleep 1

    local free0_mb=$(get_node0_free_mb)
    local free1_mb=$(get_node1_free_mb)
    log_echo "[+] Clean Headroom at T=0: Node 0 = ${free0_mb} MB free | Node 1 = ${free1_mb} MB free"
}

cleanup() {
    trap - INT TERM EXIT
    kill -INT "${BPF_PID:-}" 2>/dev/null || true
    killall -9 bpftrace 2>/dev/null || true
    pkill -f "perf stat -I 60000" 2>/dev/null || true
    perf probe -q -d 'probe:*' 2>/dev/null || true
    
    # Clean up Memtis state first: Stop ksamplingd BEFORE restoring CPUs.
    if [[ "${KERNEL_VER,,}" =~ memtis|htmm ]]; then
        if pgrep -x ksamplingd >/dev/null 2>&1; then
            python3 -c "import ctypes; ctypes.CDLL(None).syscall(450, -1)" 2>/dev/null || true
        fi
        if [ -f /sys/fs/cgroup/memtis_workload/memory.htmm_enabled ]; then
            echo "disabled" > /sys/fs/cgroup/memtis_workload/memory.htmm_enabled 2>/dev/null || true
        fi
    fi

    # Unload tier-latency-mon, colloid-mon, and kswapdrst if active
    rmmod tier_latency_mon 2>/dev/null || true
    rmmod colloid-mon 2>/dev/null || true
    rmmod kswapdrst 2>/dev/null || true

    # Restore CPUs in all cases
    set_cpus_online 1

    # Ensure all generated output files and directories have correct user ownership
    if [ -n "${SUDO_USER:-}" ]; then
        chown -R "${SUDO_USER}:${SUDO_USER}" "${TARGET_DIR}" 2>/dev/null || true
    fi
}
trap cleanup INT TERM EXIT

# ------------------------------------------------------------------------------------------
# Kernel-Specific Tiering & Migration Setup
# ------------------------------------------------------------------------------------------
configure_tiered_numa_kernel() {
    log_echo "[*] Configuring tiered CPU topology: Offlining CPUs 32..64 (leaving physical cores 0..31 online)..."
    set_cpus_online 0

    if grep -q "^kswapdrst[[:space:]]" /proc/modules 2>/dev/null; then
        log_echo "[*] Unloading kswapdrst module to allow direct allocation fallback to Node 1..."
        rmmod kswapdrst 2>/dev/null || true
    fi

    # Unified Little's Law Memory Latency Monitor
    # - Only loaded for *prefetch kernels requiring Little's Law latency feedback
    # - Colloid: uses its native colloid-mon.ko (do NOT use tier_latency_mon)
    # - PACT: uses its native daemon (src/pact) via perf_event_open (do NOT use tier_latency_mon to avoid physical MSR conflicts)
    # - Nomad, Nomad-Alto, Memtis, TPP, HybridTier, Generic (*prefetch): load and use tier_latency_mon
    if [[ "${KERNEL_VER,,}" =~ prefetch ]] && [[ ! "${KERNEL_VER,,}" =~ colloid|pact ]]; then
        ensure_module_loaded "tier_latency_mon" "${ROOT_DIR}/baselines/tier-latency-mon" "" "Tier Latency Monitor"
    fi

    # ------------------
    # NOMAD Setup
    # ------------------
    if [[ "${KERNEL_VER,,}" =~ nomad ]]; then
        local nomad_dir="${ROOT_DIR}/baselines/nomad"
        [[ "${KERNEL_VER,,}" =~ alto ]] && nomad_dir+="-alto"
        [[ "${KERNEL_VER,,}" =~ prefetch ]] && nomad_dir+="-prefetch"
        [ ! -d "${nomad_dir}" ] && nomad_dir=$(ls -d ${ROOT_DIR}/baselines/nomad* 2>/dev/null | head -n 1 || true)
        ensure_module_loaded "async_promote" "${nomad_dir}" "nomad_module" "Nomad"

        log_echo "[*] Activating Nomad Tiered NUMA Balancing (mode 2)..."
        sysctl -w kernel.numa_balancing=2 2>/dev/null || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # ------------------
    # Memtis Setup
    # ------------------
    elif [[ "${KERNEL_VER,,}" =~ memtis|htmm ]]; then
        sysctl -w kernel.numa_balancing=0 2>/dev/null || true
        echo false > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

        [ -f /sys/kernel/mm/htmm/htmm_mode ] && echo 2 > /sys/kernel/mm/htmm/htmm_mode 2>/dev/null || true
        [ -f /sys/kernel/mm/htmm/htmm_cxl_mode ] && echo "enabled" > /sys/kernel/mm/htmm/htmm_cxl_mode 2>/dev/null || true

        echo "${THP_MODE}" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
        [ "${THP_MODE}" == "always" ] && echo "always" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

        echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
        echo "+cpuset" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
        local memtis_cgroup="/sys/fs/cgroup/memtis_workload"
        mkdir -p "${memtis_cgroup}" 2>/dev/null || true
        [ -f "${memtis_cgroup}/memory.htmm_enabled" ] && echo "enabled" > "${memtis_cgroup}/memory.htmm_enabled" 2>/dev/null || true
        [ -f "${memtis_cgroup}/cgroup.procs" ] && echo $$ > "${memtis_cgroup}/cgroup.procs" 2>/dev/null || true

        local node0_total_kb=$(awk '/MemTotal:/ {print $4}' /sys/devices/system/node/node0/meminfo 2>/dev/null || echo 0)
        local reserved_kb=2097152  # 2.0 GB reserve
        local node0_usable_bytes=$(( (node0_total_kb - reserved_kb) * 1024 ))

        if [ -f "${memtis_cgroup}/memory.max_at_node0" ]; then
            echo "${node0_usable_bytes}" > "${memtis_cgroup}/memory.max_at_node0" 2>/dev/null || true
            log_echo "[*] Memtis Node 0 Memory Quota set to: $(cat "${memtis_cgroup}/memory.max_at_node0" 2>/dev/null || echo "${node0_usable_bytes}")"
        fi

        if ! pgrep -x ksamplingd >/dev/null 2>&1; then
            python3 -c "import ctypes; ctypes.CDLL(None).syscall(449, -1, 0)" 2>/dev/null || true
            sleep 1
        fi
        if pgrep -x ksamplingd >/dev/null 2>&1; then
            log_echo "[+] Memtis ksamplingd daemon is active (PID $(pgrep -x ksamplingd))."
        else
            log_echo "[!] Note: Memtis ksamplingd is not running."
        fi

    # ------------------
    # Colloid Setup
    # ------------------
    elif [[ "${KERNEL_VER,,}" =~ colloid ]]; then
        local colloid_dir="${ROOT_DIR}/baselines/colloid-tpp"
        [[ "${KERNEL_VER,,}" =~ alto ]] && colloid_dir+="-alto"
        [[ "${KERNEL_VER,,}" =~ prefetch ]] && colloid_dir+="-prefetch"
        [ ! -d "${colloid_dir}" ] && colloid_dir=$(ls -d ${ROOT_DIR}/baselines/colloid* 2>/dev/null | head -n 1 || true)

        ensure_module_loaded "tierinit" "${colloid_dir}" "tierinit" "Colloid"
        ensure_module_loaded "colloid-mon" "${colloid_dir}" "colloid-mon" "Colloid"

        log_echo "[*] Activating Colloid Tiered NUMA Balancing (mode 6: TIERING | COLLOID)..."
        sysctl -w kernel.numa_balancing=6 2>/dev/null || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # ------------------
    # PACT Setup
    # ------------------
    elif [[ "${KERNEL_VER,,}" =~ pact ]]; then
        local pact_dir="${ROOT_DIR}/baselines/pact"
        if [[ "${KERNEL_VER,,}" =~ prefetch.*batch ]]; then
            pact_dir+="-prefetch-batch"
        elif [[ "${KERNEL_VER,,}" =~ prefetch ]]; then
            pact_dir+="-prefetch"
        fi
        [ ! -d "${pact_dir}" ] && pact_dir=$(ls -d ${ROOT_DIR}/baselines/pact* 2>/dev/null | head -n 1 || true)

        ensure_module_loaded "tierinit" "${pact_dir}" "tierinit" "PACT"
        ensure_module_loaded "kswapdrst" "${pact_dir}" "kswapdrst" "PACT"

        log_echo "[*] Activating PACT kernel tiering environment..."
        sysctl -w kernel.numa_balancing=0 2>/dev/null || true
        sysctl -w kernel.perf_event_paranoid=-1 2>/dev/null || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # ------------------
    # HybridTier Setup
    # ------------------
    elif [[ "${KERNEL_VER,,}" =~ hybridtier ]]; then
        local hybridtier_dir="${ROOT_DIR}/baselines/hybridtier"
        [ ! -d "${hybridtier_dir}" ] && hybridtier_dir=$(ls -d ${ROOT_DIR}/baselines/hybridtier* 2>/dev/null | head -n 1 || true)

        if [ -d "${hybridtier_dir}/hook" ]; then
            make -C "${hybridtier_dir}/hook" TARGET_EXE_NAME="${TARGET_EXE_NAME:-pr}" >/dev/null 2>&1 || true
        fi

        local hook_so="${hybridtier_dir}/hook/hook.so"
        if [ -f "${hook_so}" ]; then
            log_echo "[+] HybridTier hook library detected: ${hook_so}"
            export HYBRIDTIER_HOOK="${hook_so}"
        fi

        log_echo "[*] Activating HybridTier kernel environment..."
        sysctl -w vm.zone_reclaim_mode=0 >/dev/null 2>&1 || true
        sysctl -w kernel.numa_balancing=0 >/dev/null 2>&1 || true
        sysctl -w vm.watermark_scale_factor=10 >/dev/null 2>&1 || true
        echo false > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true
        echo 0x0000 > /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true
        sysctl -w kernel.perf_event_max_sample_rate=150000 >/dev/null 2>&1 || true
        sysctl -w kernel.perf_cpu_time_max_percent=0 >/dev/null 2>&1 || true
        sysctl -w kernel.perf_event_paranoid=-1 >/dev/null 2>&1 || true

        if [ ! -e "/ssd1/songxin8/thesis/autonuma/linux-6.1-rc6/tools/perf/perf" ]; then
            mkdir -p /ssd1/songxin8/thesis/autonuma/linux-6.1-rc6/tools/perf 2>/dev/null || true
            ln -sf "$(command -v perf || echo /usr/bin/perf)" /ssd1/songxin8/thesis/autonuma/linux-6.1-rc6/tools/perf/perf 2>/dev/null || true
        fi

    # ------------------------------------
    # AutoNUMA (Generic) Setup
    # ------------------------------------
    elif [[ "${KERNEL_VER,,}" =~ generic ]]; then
        log_echo "[*] Activating AutoNUMA + Tiered Balancing for generic kernel (mode 3)..."
        sysctl -w kernel.numa_balancing=3 2>/dev/null || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # ------------------------------------
    # Upstream TPP / Generic Fallback
    # ------------------------------------
    else
        log_echo "[*] Activating Tiered NUMA Balancing (mode 2)..."
        sysctl -w kernel.numa_balancing=2 2>/dev/null || sysctl -w kernel.numa_balancing=1 2>/dev/null || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true
    fi

    # ------------------------------------------------------------------------------------------
    # Migration Prefetch Online Configuration
    # ------------------------------------------------------------------------------------------
    local prefetch_sysfs=""
    [ -d "/sys/kernel/mm/page_prefetch" ] && prefetch_sysfs="/sys/kernel/mm/page_prefetch"
    [ -d "/sys/kernel/mm/pact_prefetch" ] && prefetch_sysfs="/sys/kernel/mm/pact_prefetch"

    if [ -n "$prefetch_sysfs" ]; then
        write_sysfs_verified "${prefetch_sysfs}/enabled" "${PREFETCH_ENABLED}" "enabled"
        write_sysfs_verified "${prefetch_sysfs}/adaptive" "${PREFETCH_ADAPTIVE}" "adaptive"
        write_sysfs_verified "${prefetch_sysfs}/hint" "${PREFETCH_HINT}" "hint"

        # Clamp distance limits
        write_sysfs_verified "${prefetch_sysfs}/min_distance" "${PREFETCH_MIN_DISTANCE}" "min_distance" || true
        write_sysfs_verified "${prefetch_sysfs}/max_distance" "${PREFETCH_MAX_DISTANCE}" "max_distance" || true

        if [ -f "${prefetch_sysfs}/promote_distance" ]; then
            if [ "${PREFETCH_ENABLED}" != "0" ]; then
                write_sysfs_verified "${prefetch_sysfs}/promote_distance" "${PREFETCH_PROMOTE_DISTANCE}" "promote_distance"
                write_sysfs_verified "${prefetch_sysfs}/demote_distance"  "${PREFETCH_DEMOTE_DISTANCE}"  "demote_distance"
            fi
        fi

        # Read back verified parameters for logging
        local cur_en cur_hint cur_adap cur_prom cur_dem cur_min cur_max
        cur_en="$(read_sysfs "${prefetch_sysfs}/enabled")"
        cur_hint="$(read_sysfs "${prefetch_sysfs}/hint")"
        cur_adap="$(read_sysfs "${prefetch_sysfs}/adaptive")"
        cur_prom="$(read_sysfs "${prefetch_sysfs}/promote_distance")"
        cur_dem="$(read_sysfs "${prefetch_sysfs}/demote_distance")"
        cur_min="$(read_sysfs "${prefetch_sysfs}/min_distance")"
        cur_max="$(read_sysfs "${prefetch_sysfs}/max_distance")"

        if [ "$cur_en" == "0" ]; then
            log_echo "[*] Migration Prefetch Online Parameters (${prefetch_sysfs}): enabled=0 (disabled), hint=${cur_hint:-0}"
        elif [ -f "${prefetch_sysfs}/promote_distance" ]; then
            local extra_info=""
            [ -n "$cur_min" ] && extra_info+=", min_dist=${cur_min}"
            [ -n "$cur_max" ] && extra_info+=", max_dist=${cur_max}"
            local mode_str="$([ "$cur_adap" == "1" ] && echo "adaptive" || echo "static")"
            local tier_info=" (promote=${cur_prom:-$PREFETCH_PROMOTE_DISTANCE}, demote=${cur_dem:-$PREFETCH_DEMOTE_DISTANCE}, mode=${mode_str}${extra_info})"
            log_echo "[*] Migration Prefetch Online Parameters (${prefetch_sysfs}): enabled=${cur_en}${tier_info}, hint=${cur_hint:-0}"
        else
            log_echo "[*] Migration Prefetch Online Parameters (${prefetch_sysfs}): enabled=${cur_en}, hint=${cur_hint:-0}"
        fi
    fi

    # ------------------------------------------------------------------------------------------
    # Transparent Huge Pages (THP) Online Configuration
    # ------------------------------------------------------------------------------------------
    echo "${THP_MODE}" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    [ "${THP_MODE}" == "always" ] && echo "always" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    cur_thp="$(read_sysfs /sys/kernel/mm/transparent_hugepage/enabled)"
    log_echo "[*] Transparent Huge Pages (THP): enabled=${cur_thp:-N/A} (target=${THP_MODE})"

    # Log active demotion target and watermark state
    local demote_en="$(read_sysfs /sys/kernel/mm/numa/demotion_enabled)"
    local numa_bal="$(sysctl -n kernel.numa_balancing 2>/dev/null || true)"
    local tiers="$(ls -d /sys/devices/virtual/memory_tiering/memory_tier* 2>/dev/null | xargs -n 1 basename 2>/dev/null | tr '\n' ' ' || true)"
    local cpu_gov="$(read_sysfs /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    local cpu_epp="$(read_sysfs /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)"
    local cpu0_cur="$(read_sysfs /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)"
    local no_turbo="$(read_sysfs /sys/devices/system/cpu/intel_pstate/no_turbo)"
    local cur_freq_summary=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null | awk '{sum+=$1; count++; if (min=="" || $1<min) min=$1; if ($1>max) max=$1} END {if (count>0) printf "avg=%.0fkHz (min=%dkHz, max=%dkHz)", sum/count, min, max; else printf "N/A"}')
    local u0_min="$(read_sysfs /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/min_freq_khz)"
    local u0_max="$(read_sysfs /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/max_freq_khz)"
    local u1_cur="$(read_sysfs /sys/devices/system/cpu/intel_uncore_frequency/package_01_die_00/max_freq_khz)"
    local c6_dis="$(read_sysfs /sys/devices/system/cpu/cpu0/cpuidle/state3/disable)"
    log_echo "[*] CPU Power & Frequency Profile: gov=${cpu_gov:-N/A} (epp=${cpu_epp:-N/A}), cur_freq=${cur_freq_summary} (cpu0=${cpu0_cur:-N/A}kHz), turbo=$([ "${no_turbo}" == "1" ] && echo "DISABLED(no_turbo=1)" || echo "active(no_turbo=0)"), uncore_pkg0=${u0_min}-${u0_max}kHz, uncore_pkg1=${u1_cur}kHz, c6_disabled=${c6_dis:-0}"
    log_echo "[*] Node 0 Tiering Status: demotion_enabled=${demote_en:-false}, numa_balancing=${numa_bal}${tiers:+, tiers=[${tiers% }]}"
    log_echo "[*] Node 0 Watermark Buffer: min_free_kbytes=$(sysctl -n vm.min_free_kbytes 2>/dev/null), watermark_scale_factor=$(sysctl -n vm.watermark_scale_factor 2>/dev/null)"
}

# Configure and activate kernel tiering parameters FIRST
configure_tiered_numa_kernel

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
    echo " dmesg Log      : ${DMESG_LOG_FILE}"
    echo "=========================================================================================="
} | tee -a "${REGRESS_LOG_FILE:-/dev/null}"

# ------------------------------------------------------------------------------------------
# Workload Execution Workflow
# ------------------------------------------------------------------------------------------

# Step 1: Clean all caches & wipe stale state BEFORE preloading dataset
clean_memory_caches 3

# Step 2: Preload dataset into target tier (Node 1 or Node 0)
PRELOAD_CMD=$("${SCRIPT_DIR}/exec_workload.sh" --get-preload-cmd "$TARGET" ${DATASET:+"$DATASET"})
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

# Step 5: Execute workload command wrapped with run_with_stats.sh
evict_background_to_node1
log_echo "[run_workloads] Running stats-monitored workload: $WORKLOAD_CMD"
"${SCRIPT_DIR}/run_with_stats.sh" ${WORKLOAD_CMD} 2>&1 | tee -a "${REGRESS_LOG_FILE}"

log_echo "------------------------------------------------------------------------------------------"
log_echo "[+] Workload completed. Compiling final statistics..."

# Step 6: Capture kernel dmesg ring buffer (including prefetch and migration logs)
dmesg -T > "${DMESG_LOG_FILE}" 2>/dev/null || dmesg > "${DMESG_LOG_FILE}" 2>/dev/null || true

# Append prefetch hardware stats to PACT and regression log files if available
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

# Step 7: Clean up and restore system configuration (CPUs, background daemons, ownership)
cleanup

echo "=========================================================================================="
echo " Workload Execution Completed."
echo " Regression Summary saved to : ${REGRESS_LOG_FILE}"
echo " dmesg Kernel Log saved to   : ${DMESG_LOG_FILE}"
echo "=========================================================================================="