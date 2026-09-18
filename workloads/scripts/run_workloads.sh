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

if [ -z "$1" ] || [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    echo "=========================================================================================="
    echo " bpftrace Latency Profiler for NUMA Page Faults"
    echo "=========================================================================================="
    echo "Usage (Normal / Manual Runs):"
    echo "  sudo $0 [TARGET_ALIAS] [DATASET: kron | urand | twitter | ...]"
    echo ""
    echo "Usage (Automated Regression Only):"
    echo "  sudo $0 [TARGET_ALIAS] [DATASET] [TIER_RATIO: 1:1 | 1:2 | ...]"
    echo ""
    echo "Arguments:"
    echo "  TARGET_ALIAS   Workload target (e.g. stream_hot, gapbs_pr, silo_tpcc, redis, xsbench, spec2026_<bench>)"
    echo "  DATASET        Graph dataset for GAPBS (kron, urand, twitter, web, road)"
    echo "  TIER_RATIO     [REGRESSION ONLY] Fast:Slow ratio tag passed by automated orchestrators"
    echo "                 (e.g., regression/run_auto_regression.sh) to label logs after reboot."
    echo "                 NOTE: For normal/manual benchmark runs, DO NOT add TIER_RATIO."
    echo ""
    echo "Examples:"
    echo "  sudo $0 stream_hot"
    echo "  sudo $0 gapbs_pr urand"
    echo "  sudo $0 silo_tpcc"
    echo "  sudo $0 redis"
    echo "  sudo $0 spec2026_820.cloverleaf_s"
    echo "  sudo $0 spec2026_709.cactus_r"
    echo "=========================================================================================="
    exit 0
fi

# Ensure running with root / sudo privileges
if [ "$EUID" -ne 0 ]; then
    echo "[!] This script requires root privileges for bpftrace. Elevating via sudo..."
    exec sudo env PATH="$PATH" ROOT_DIR="$ROOT_DIR" TIER_RATIO="${TIER_RATIO:-}" RATIO="${RATIO:-}" RATIO_TAG="${RATIO_TAG:-}" TARGET_DIR="${TARGET_DIR:-}" \
        WORKLOAD_CORES="${WORKLOAD_CORES:-}" SELECTED_CPUS="${SELECTED_CPUS:-}" "$0" "$@"
fi

# Check if bpftrace is installed
if ! command -v bpftrace &>/dev/null; then
    echo "[ERROR] bpftrace is not installed. Please install it (e.g., sudo apt install bpftrace)."
    exit 1
fi

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

# Format ratio for filenames: replace colon ':' with '_' (e.g. 1:1 -> 1_1)
RATIO_TAG=""
if [ -n "$RATIO" ]; then
    RATIO_TAG="${RATIO//:/_}"
    RATIO_TAG="${RATIO_TAG#ratio_}"
fi
export RATIO
export RATIO_TAG

KERNEL_VER="$(uname -r)"
TARGET_DIR="${TARGET_DIR:-${OUTPUT_DIR}/${KERNEL_VER}}"
mkdir -p "${TARGET_DIR}"
export TARGET_DIR

FILENAME_SUFFIX="${TARGET}${DATASET:+_${DATASET}}${RATIO_TAG:+_${RATIO_TAG}}"
export FILENAME_SUFFIX

LOG_FILE="${TARGET_DIR}/bpftrace_numa_page_${FILENAME_SUFFIX}.log"
PERF_LOG_FILE="${TARGET_DIR}/perf_bandwidth_${FILENAME_SUFFIX}.log"
REGRESS_LOG_FILE="${TARGET_DIR}/regress_${FILENAME_SUFFIX}.log"
export REGRESS_LOG_FILE

# Remove any stale output files for this specific workload before running
rm -f "${LOG_FILE}" "${PERF_LOG_FILE}" "${REGRESS_LOG_FILE}"

# Export target executable name for baselines requiring process hooking/attachment (HybridTier / PACT)
if [ -z "${TARGET_EXE_NAME:-}" ]; then
    TARGET_EXE_NAME=$("${SCRIPT_DIR}/exec_workload.sh" --get-target-exe "$TARGET" 2>/dev/null || true)
    export TARGET_EXE_NAME
fi

# Workload CPU allocation: 8 cores for workload (0..7), 8 cores for background profilers/kswapd (8..15)
export WORKLOAD_CORES="${WORKLOAD_CORES:-8}"
export SELECTED_CPUS="${SELECTED_CPUS:-$(seq -s, 0 $(( WORKLOAD_CORES - 1 )))}"

OFFLINE_CPUS=($(seq 16 63))

set_cpus_online() {
    local state="$1"
    for cpu in "${OFFLINE_CPUS[@]}"; do
        [ -f "/sys/devices/system/cpu/cpu${cpu}/online" ] && echo "$state" > "/sys/devices/system/cpu/cpu${cpu}/online" 2>/dev/null || true
    done
}

# ------------------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------------------

# Helper to check if a symbol is traceable in /proc/kallsyms
is_traceable() {
    local sym="$1"
    grep -E "[[:space:]][tT][[:space:]]${sym}$" /proc/kallsyms &>/dev/null
}

# Helper to add the first traceable symbol matching candidates
add_probe_first_matching() {
    local desc="$1"
    shift
    for sym in "$@"; do
        if is_traceable "$sym"; then
            PROBES_LIST+=("$sym")
            PROBE_DESCS+=("${sym} (${desc})")
            return 0
        fi
    done
    return 1
}

# Helper to build and load out-of-tree kernel modules safely
ensure_module_loaded() {
    local mod_name="$1"
    local base_dir="$2"
    local sub_dir="$3"
    local label="$4"

    if lsmod | grep -q "^${mod_name//-/_}\b"; then
        return 0
    fi

    local mod_file="${base_dir}/${sub_dir}/${mod_name}.ko"
    if [ ! -f "${mod_file}" ]; then
        mod_file=$(ls ${ROOT_DIR}/baselines/*/${sub_dir}/${mod_name}.ko 2>/dev/null | head -n 1 || true)
    fi

    if [ ! -f "${mod_file}" ] && [ -d "${base_dir}/${sub_dir}" ] && [ -d "${base_dir}/linux" ]; then
        echo "[*] Compiling ${label} ${mod_name}.ko..."
        make -C "${base_dir}/linux" M="${base_dir}/${sub_dir}" modules >/dev/null 2>&1 || true
        mod_file="${base_dir}/${sub_dir}/${mod_name}.ko"
    fi

    if [ -f "${mod_file}" ]; then
        echo "[*] Loading ${label} ${mod_name} module (${mod_file})..."
        insmod "${mod_file}" 2>/dev/null || true
    fi

    if lsmod | grep -q "^${mod_name//-/_}\b"; then
        echo "[+] ${label} ${mod_name} module loaded."
        return 0
    else
        echo -e "\033[1;33m[WARNING] ${label} kernel detected but ${mod_name}.ko is not loaded!\033[0m"
        return 1
    fi
}

# Thoroughly clean caches, reclaim memory, and quiesce the system
clean_memory_caches() {
    echo "[*] Cleaning memory caches, dropping buffers, compacting memory & quiescing..."

    # 1. Terminate any lingering background profilers or stale benchmark processes
    killall -9 bpftrace perf redis-server dbtest XSBench pr bc bfs cc sssp tc specperl runcpu specmake 2>/dev/null || true

    # 2. Reclaim stale SysV IPC shared memory segments
    ipcs -m 2>/dev/null | awk '$2 ~ /^[0-9]+$/ {print $2}' | xargs -r ipcrm -m 2>/dev/null || true

    # 3. Ensure swap is disabled before dropping caches and compacting
    swapoff -a 2>/dev/null || true

    # 4. Flush dirty filesystem buffers to disk synchronously
    sync

    # 5. Flush clean pagecache, dentries, and inodes via sysctl
    sysctl -w vm.drop_caches=3 >/dev/null 2>&1 || echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    # 6. Compact memory across all NUMA nodes to defragment for THP and drain Per-CPU freelists
    sysctl -w vm.compact_memory=1 >/dev/null 2>&1 || echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true

    # 7. Short settling time for background kernel threads (kcompactd, khugepaged)
    sleep 3
}

# Clean up and restore system configuration (CPUs, background daemons, ownership)
cleanup() {
    trap - INT TERM EXIT
    kill -INT "${BPF_PID:-}" 2>/dev/null || true
    killall -9 bpftrace 2>/dev/null || true
    pkill -f "perf stat -I 60000" 2>/dev/null || true
    perf probe -q -d 'probe:*' 2>/dev/null || true
    
    # 1. Clean up Memtis state first: Stop ksamplingd BEFORE restoring CPUs.
    # Otherwise, bringing CPU 16 online while ksamplingd is sampling triggers an out-of-bounds array dereference crash.
    if echo "${KERNEL_VER}" | grep -iqE "memtis|htmm"; then
        if pgrep -x ksamplingd >/dev/null 2>&1; then
            python3 -c "import ctypes; ctypes.CDLL(None).syscall(450, -1)" 2>/dev/null || true
        fi
        if [ -f /sys/fs/cgroup/memtis_workload/memory.htmm_enabled ]; then
            echo "disabled" > /sys/fs/cgroup/memtis_workload/memory.htmm_enabled 2>/dev/null || true
        fi
    fi

    # Unload kswapdrst if active
    rmmod kswapdrst 2>/dev/null || true

    # 2. Restore CPUs 16..63 in all cases
    set_cpus_online 1

    # 3. Ensure all generated output files and directories have correct user ownership
    if [ -n "${SUDO_USER:-}" ]; then
        chown -R "${SUDO_USER}:${SUDO_USER}" "${TARGET_DIR}" 2>/dev/null || true
    fi
}
trap cleanup INT TERM EXIT

# Function to configure tiered NUMA balancing, CPU offlining & kernel migration parameters
configure_tiered_numa_kernel() {
    # 1. Take CPUs 16..63 offline in all cases (Node 1 + Node 0 hyperthreads)
    echo "[*] Configuring tiered CPU topology: Offlining CPUs 16..63 (leaving physical cores 0..15 online)..."
    set_cpus_online 0

    # 2. Unload kswapdrst daemon across all baselines if present
    # Resetting kswapd_failures to 0 causes throttle_direct_reclaim() in mm/vmscan.c to block allocating processes indefinitely.
    if lsmod | grep -q "^kswapdrst\b"; then
        echo "[*] Unloading kswapdrst module to allow direct allocation fallback to Node 1..."
        rmmod kswapdrst 2>/dev/null || true
    fi

    # ------------------
    # NOMAD Setup
    # ------------------
    # 3. Adaptive NUMA balancing, module loading, and demotion setup based on active kernel
    if echo "${KERNEL_VER}" | grep -iq "nomad"; then
        # Nomad: load async_promote.ko, activate mode 2 (Tiered NUMA Balancing)
        local nomad_dir="${ROOT_DIR}/baselines/nomad"
        echo "${KERNEL_VER}" | grep -iq "alto" && nomad_dir="${ROOT_DIR}/baselines/nomad-alto"
        [ ! -d "${nomad_dir}" ] && nomad_dir=$(ls -d ${ROOT_DIR}/baselines/nomad* 2>/dev/null | head -n 1 || true)
        ensure_module_loaded "async_promote" "${nomad_dir}" "nomad_module" "Nomad"

        echo "[*] Activating Nomad Tiered NUMA Balancing (mode 2)..."
        sysctl -w kernel.numa_balancing=2 2>/dev/null || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # ------------------
    # Memtis Setup
    # ------------------
    elif echo "${KERNEL_VER}" | grep -iqE "memtis|htmm"; then
        # Memtis: dedicated migration daemons and cgroup memory limits
        sysctl -w kernel.numa_balancing=0 2>/dev/null || true
        echo false > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

        [ -f /sys/kernel/mm/htmm/htmm_mode ] && echo 2 > /sys/kernel/mm/htmm/htmm_mode 2>/dev/null || true
        [ -f /sys/kernel/mm/htmm/htmm_cxl_mode ] && echo "enabled" > /sys/kernel/mm/htmm/htmm_cxl_mode 2>/dev/null || true

        echo "always" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
        echo "always" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

        # Set up Memtis cgroup v2 subtree and enable htmm
        echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
        echo "+cpuset" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
        local memtis_cgroup="/sys/fs/cgroup/memtis_workload"
        mkdir -p "${memtis_cgroup}" 2>/dev/null || true
        [ -f "${memtis_cgroup}/memory.htmm_enabled" ] && echo "enabled" > "${memtis_cgroup}/memory.htmm_enabled" 2>/dev/null || true
        [ -f "${memtis_cgroup}/cgroup.procs" ] && echo $$ > "${memtis_cgroup}/cgroup.procs" 2>/dev/null || true

        # Configure fast-tier (Node 0) budget
        local node0_total_kb=$(awk '/MemTotal:/ {print $4}' /sys/devices/system/node/node0/meminfo 2>/dev/null || echo 0)
        local reserved_kb=2097152  # 2.0 GB reserve
        local node0_usable_bytes=$(( (node0_total_kb - reserved_kb) * 1024 ))

        if [ -f "${memtis_cgroup}/memory.max_at_node0" ]; then
            echo "${node0_usable_bytes}" > "${memtis_cgroup}/memory.max_at_node0" 2>/dev/null || true
            echo "[*] Memtis Node 0 Memory Quota set to: $(cat "${memtis_cgroup}/memory.max_at_node0" 2>/dev/null || echo "${node0_usable_bytes}")"
        fi

        # Start Memtis PEBS sampling daemon via syscall 449 if not running
        if ! pgrep -x ksamplingd >/dev/null 2>&1; then
            python3 -c "import ctypes; ctypes.CDLL(None).syscall(449, -1, 0)" 2>/dev/null || true
            sleep 1
        fi
        if pgrep -x ksamplingd >/dev/null 2>&1; then
            echo "[+] Memtis ksamplingd daemon is active (PID $(pgrep -x ksamplingd))."
        else
            echo "[!] Note: Memtis ksamplingd is not running."
        fi

    # ------------------
    # Colloid Setup
    # ------------------
    elif echo "${KERNEL_VER}" | grep -iq "colloid"; then
        # Colloid: tierinit.ko + colloid-mon.ko + mode 6 (TIERING | COLLOID)
        local colloid_dir=""
        if echo "${KERNEL_VER}" | grep -iq "alto"; then
            colloid_dir="${ROOT_DIR}/baselines/colloid-tpp-alto"
        else
            colloid_dir="${ROOT_DIR}/baselines/colloid-tpp"
        fi
        [ ! -d "${colloid_dir}" ] && colloid_dir=$(ls -d ${ROOT_DIR}/baselines/colloid* 2>/dev/null | head -n 1 || true)

        ensure_module_loaded "tierinit" "${colloid_dir}" "tierinit" "Colloid"
        ensure_module_loaded "colloid-mon" "${colloid_dir}" "colloid-mon" "Colloid"

        echo "[*] Activating Colloid Tiered NUMA Balancing (mode 6: TIERING | COLLOID)..."
        sysctl -w kernel.numa_balancing=6 2>/dev/null || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # ------------------
    # PACT Setup
    # ------------------
    elif echo "${KERNEL_VER}" | grep -iq "pact"; then
        # PACT / PACT-prefetch: tierinit.ko + userspace PAC daemon for proactive promotions + kernel demotion
        local pact_dir=""
        if echo "${KERNEL_VER}" | grep -iq "prefetch"; then
            pact_dir="${ROOT_DIR}/baselines/pact-prefetch"
        else
            pact_dir="${ROOT_DIR}/baselines/pact"
        fi
        [ ! -d "${pact_dir}" ] && pact_dir=$(ls -d ${ROOT_DIR}/baselines/pact* 2>/dev/null | head -n 1 || true)

        ensure_module_loaded "tierinit" "${pact_dir}" "tierinit" "PACT"
        ensure_module_loaded "kswapdrst" "${pact_dir}" "kswapdrst" "PACT"

        echo "[*] Activating PACT kernel tiering environment..."
        sysctl -w kernel.numa_balancing=0 2>/dev/null || true
        sysctl -w kernel.perf_event_paranoid=-1 2>/dev/null || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # ------------------
    # HybridTier Setup
    # ------------------
    elif echo "${KERNEL_VER}" | grep -iq "hybridtier"; then
        # HybridTier: in-process PEBS monitoring thread (hook.so) and userspace move_pages()
        local hybridtier_dir="${ROOT_DIR}/baselines/hybridtier"
        [ ! -d "${hybridtier_dir}" ] && hybridtier_dir=$(ls -d ${ROOT_DIR}/baselines/hybridtier* 2>/dev/null | head -n 1 || true)

        # Compile hook runtime for the target workload using upstream unmodified code
        if [ -d "${hybridtier_dir}/hook" ]; then
            make -C "${hybridtier_dir}/hook" TARGET_EXE_NAME="${TARGET_EXE_NAME:-pr}" >/dev/null 2>&1 || true
        fi

        local hook_so="${hybridtier_dir}/hook/hook.so"
        if [ -f "${hook_so}" ]; then
            echo "[+] HybridTier hook library detected: ${hook_so}"
            export HYBRIDTIER_HOOK="${hook_so}"
        fi

        echo "[*] Activating HybridTier kernel environment..."
        sysctl -w vm.zone_reclaim_mode=0 >/dev/null 2>&1 || true
        sysctl -w kernel.numa_balancing=0 >/dev/null 2>&1 || true
        sysctl -w vm.watermark_scale_factor=10 >/dev/null 2>&1 || true
        echo false > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true
        echo 0x0000 > /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true
        sysctl -w kernel.perf_event_max_sample_rate=150000 >/dev/null 2>&1 || true
        sysctl -w kernel.perf_cpu_time_max_percent=0 >/dev/null 2>&1 || true
        sysctl -w kernel.perf_event_paranoid=-1 >/dev/null 2>&1 || true

        # Ensure author's hardcoded perf binary path resolves to system perf without modifying .cpp files
        if [ ! -e "/ssd1/songxin8/thesis/autonuma/linux-6.1-rc6/tools/perf/perf" ]; then
            mkdir -p /ssd1/songxin8/thesis/autonuma/linux-6.1-rc6/tools/perf 2>/dev/null || true
            ln -sf "$(command -v perf || echo /usr/bin/perf)" /ssd1/songxin8/thesis/autonuma/linux-6.1-rc6/tools/perf/perf 2>/dev/null || true
        fi

    # ------------------------------------
    # AutoNUMA (Generic) Setup
    # ------------------------------------
    elif echo "${KERNEL_VER}" | grep -iq "generic"; then
        # Generic kernel: activate mode 3 (0x1 NORMAL AutoNUMA | 0x2 TIERED MEMORY)
        echo "[*] Activating AutoNUMA + Tiered Balancing for generic kernel (mode 3)..."
        sysctl -w kernel.numa_balancing=3 2>/dev/null || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # ------------------------------------
    # Others
    # ------------------------------------
    else
        # Upstream TPP / generic memory tiering: mode 2 (Tiered Memory Promotion only) or fallback to 1
        echo "[*] Activating Tiered NUMA Balancing (mode 2)..."
        sysctl -w kernel.numa_balancing=2 2>/dev/null || sysctl -w kernel.numa_balancing=1 2>/dev/null || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true
    fi

    # 4. Log active demotion target and watermark state
    local demote_en=$(cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true)
    local numa_bal=$(sysctl -n kernel.numa_balancing 2>/dev/null || true)
    local tiers=$(ls -d /sys/devices/virtual/memory_tiering/memory_tier* 2>/dev/null | xargs -n 1 basename 2>/dev/null | tr '\n' ' ' || true)
    echo "[*] Node 0 Tiering Status: demotion_enabled=${demote_en:-false}, numa_balancing=${numa_bal}${tiers:+, tiers=[${tiers% }]}"
    echo "[*] Node 0 Watermark Buffer: min_free_kbytes=$(sysctl -n vm.min_free_kbytes 2>/dev/null), watermark_scale_factor=$(sysctl -n vm.watermark_scale_factor 2>/dev/null)"
}

# ------------------------------------------------------------------------------------------
# Setup Topology, Baseline Environment & Profiler Probes
# ------------------------------------------------------------------------------------------

# Configure and activate kernel tiering parameters FIRST
configure_tiered_numa_kernel

# Configure perf events: Check for Uncore IMC support, or core PMU DRAM events for current CPU
if [ -z "${PERF_EVENTS:-}" ]; then
    UNCORE_EVENTS=()
    if ls /sys/bus/event_source/devices/uncore_imc* &>/dev/null; then
        for imc in /sys/bus/event_source/devices/uncore_imc*; do
            dev_name="$(basename "$imc")"
            if [ -f "$imc/events/data_reads" ]; then
                UNCORE_EVENTS+=("${dev_name}/data_reads/")
            fi
            if [ -f "$imc/events/data_writes" ]; then
                UNCORE_EVENTS+=("${dev_name}/data_writes/")
            fi
        done
    fi

    if [ ${#UNCORE_EVENTS[@]} -gt 0 ]; then
        PERF_EVENTS=$(IFS=","; echo "${UNCORE_EVENTS[*]}")
    elif perf stat -e "cpu/mem_load_l3_miss_retired.local_dram/" true &>/dev/null; then
        # Hardware named events for Intel core PMU (auto-adapts across Sapphire Rapids, Emerald Rapids, Ice Lake, Skylake, etc.)
        PERF_EVENTS="cpu/mem_load_l3_miss_retired.local_dram,name=local_dram/,cpu/mem_load_l3_miss_retired.remote_dram,name=remote_dram/"
    else
        # Fallback based on CPU family/model
        CPU_FAMILY=$(awk '/cpu family/{print $4; exit}' /proc/cpuinfo 2>/dev/null || echo 6)
        CPU_MODEL=$(awk '/model\t/{print $3; exit}' /proc/cpuinfo 2>/dev/null || echo 0)
        if [ "$CPU_FAMILY" -eq 6 ] && [ "$CPU_MODEL" -ge 140 ]; then
            # Golden Cove / Raptor Cove (Sapphire Rapids model 143, Emerald Rapids model 207, etc.): event 0xd3
            PERF_EVENTS="cpu/event=0xd3,umask=0x01,name=local_dram/,cpu/event=0xd3,umask=0x02,name=remote_dram/"
        else
            # Skylake / Cascade Lake (model 85), Ice Lake (model 106), Broadwell: event 0xd1
            PERF_EVENTS="cpu/event=0xd1,umask=0x01,name=local_dram/,cpu/event=0xd1,umask=0x02,name=remote_dram/"
        fi
    fi
fi

# Dynamically select all available traceable symbols (with exact symbol verification)
PROBES_LIST=()
PROBE_DESCS=()

# TODO: Review the probes:
add_probe_first_matching "Nomad Async Queue" "decide_queue_page" || true
add_probe_first_matching "Sync Migration" "migrate_misplaced_page" "migrate_misplaced_folio" || true
add_probe_first_matching "Colloid Congestion Demote" "numa_migrate_memory_away_target" || true

# Only measure migration entry collision waits for non-TPP methods (e.g., Nomad async migration).
# In TPP, migration is synchronous and probing sleeping collision waits causes severe
# kretprobe lock contention and benchmark stalls.
if ! echo "${KERNEL_VER}" | grep -iq "tpp"; then
    add_probe_first_matching "Async Migration Collision Wait" "migration_entry_wait" "__migration_entry_wait" || true
    add_probe_first_matching "HugePage Migration Wait" "migration_entry_wait_huge" "pmd_migration_entry_wait" || true
fi

add_probe_first_matching "PMI Interrupt Handler" "intel_pmu_handle_irq" || true

if [ ${#PROBES_LIST[@]} -eq 0 ]; then
    echo "[ERROR] No NUMA fault handling symbols found in /proc/kallsyms."
    exit 1
fi

TARGET_DESC=$(IFS=", "; echo "${PROBE_DESCS[*]}")

# Automatically register perf dynamic probes for traceable NUMA handlers and append to PERF_EVENTS
for p in "${PROBES_LIST[@]}"; do
    if perf probe -q -a "${p}" 2>/dev/null; then
        PERF_EVENTS="${PERF_EVENTS},probe:${p}"
    fi
done

echo "=========================================================================================="
echo " Starting bpftrace & perf latency/bandwidth profiler on NUMA handlers:"
echo " Kernel Version : ${KERNEL_VER}"
echo " Probing        : ${TARGET_DESC}"
echo " bpftrace Log   : ${LOG_FILE}"
echo " perf stat Log  : ${PERF_LOG_FILE}"
echo " perf Events    : ${PERF_EVENTS}"
echo " Workload       : ${TARGET} ${DATASET:-}"
if [ -n "$RATIO" ]; then
    echo " Tier Ratio     : ${RATIO}"
fi
echo " Current Memmap : $(grep -oE 'memmap=[^ ]+' /proc/cmdline 2>/dev/null || echo 'none')"
echo "=========================================================================================="

# Create inline bpftrace script with multi-probe support
BPF_SCRIPT=""
for p in "${PROBES_LIST[@]}"; do
    BPF_SCRIPT+=$(cat <<EOF
kprobe:${p} {
    @start[tid, "${p}"] = nsecs;
    @numa_faults["${p}"] = count();
}

kretprobe:${p} /@start[tid, "${p}"]/ {
    \$now = nsecs;
    \$s = @start[tid, "${p}"];
    delete(@start[tid, "${p}"]);
    if (\$now > \$s) {
        \$us = (\$now - \$s) / 1000;
        if (\$us < 10000000) {
            @numa_page_latency_us["${p}"] = hist(\$us);
            @total_time_us["${p}"] = sum(\$us);
        }
    }
}

EOF
)
done

BPF_SCRIPT+=$(cat <<EOF
END {
    clear(@start);
}
EOF
)

# Clean caches AFTER kernel is configured so Node 0 is fresh in the correct state
clean_memory_caches

# Preload dataset into slow tier (Node 1) before attaching profilers and capturing baseline stats
PRELOAD_CMD=$("${SCRIPT_DIR}/exec_workload.sh" --get-preload-cmd "$TARGET" ${DATASET:+"$DATASET"})
if [ -n "${PRELOAD_CMD}" ]; then
    echo "[+] Preloading dataset onto Slow Tier (Node 1): ${PRELOAD_CMD}"
    eval "${PRELOAD_CMD}"
    sync
    sleep 2
fi

# Start bpftrace in the background with reset signal traps
BPF_PID=""
( trap - INT TERM; exec bpftrace --no-warnings -e "${BPF_SCRIPT}" > "${LOG_FILE}" 2>&1 ) &
BPF_PID=$!

# Allow bpftrace a moment to attach kprobes safely
sleep 2

# Verify bpftrace process is running
if ! kill -0 $BPF_PID 2>/dev/null; then
    echo "[ERROR] bpftrace failed to start. Check ${LOG_FILE} for details."
    cat "${LOG_FILE}"
    exit 1
fi

echo "[+] bpftrace attached successfully (PID ${BPF_PID}). Running workload..."
echo "------------------------------------------------------------------------------------------"

# Resolve and execute workload command wrapped with perf stat and run_with_stats.sh
WORKLOAD_CMD=$("${SCRIPT_DIR}/exec_workload.sh" --get-cmd "$TARGET" ${DATASET:+"$DATASET"})
if [ -z "$WORKLOAD_CMD" ]; then
    echo "[ERROR] Failed to resolve executable command for target '$*'. Check exec_workload.sh --help."
    exit 1
fi
echo "[run_workloads] Running stats-monitored workload with perf stat: $WORKLOAD_CMD"
perf stat -a -I 1000 -e "${PERF_EVENTS}" -o "${PERF_LOG_FILE}" "${SCRIPT_DIR}/run_with_stats.sh" ${WORKLOAD_CMD} 2>&1 | tee "${REGRESS_LOG_FILE}"

echo "------------------------------------------------------------------------------------------"
echo "[+] Workload completed. Stopping bpftrace and compiling latency statistics..."

# Send SIGINT to bpftrace so it flushes its stats & triggers END block
if [ -n "${BPF_PID}" ] && kill -0 "${BPF_PID}" 2>/dev/null; then
    kill -INT "${BPF_PID}" 2>/dev/null || true
    for i in {1..30}; do
        if ! kill -0 "${BPF_PID}" 2>/dev/null; then break; fi
        sleep 0.1
    done
    kill -9 "${BPF_PID}" 2>/dev/null || true
fi

# Append bpftrace stats to regress log as well
if [ -f "${LOG_FILE}" ]; then
    cat "${LOG_FILE}" >> "${REGRESS_LOG_FILE}" 2>/dev/null || true
fi

# Clean up and restore system configuration (CPUs, background daemons, ownership) immediately after running the workload
cleanup

echo "=========================================================================================="
echo " bpftrace Latency Results for NUMA Page Fault Handling (${TARGET}):"
echo " Saved to: ${LOG_FILE}"
echo "=========================================================================================="
cat "${LOG_FILE}"
echo "=========================================================================================="
echo " perf Bandwidth / DRAM Access Stats saved to: ${PERF_LOG_FILE}"
echo "=========================================================================================="
