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
    echo "Usage:"
    echo "  sudo $0 [TARGET_ALIAS] [DATASET: kron | urand | twitter]"
    echo ""
    echo "Example:"
    echo "  sudo $0 stream_hot"
    echo "  sudo $0 gapbs_pr urand"
    echo "  sudo $0 silo_tpcc"
    echo "=========================================================================================="
    exit 0
fi

# Ensure running with root / sudo privileges
if [ "$EUID" -ne 0 ]; then
    echo "[!] This script requires root privileges for bpftrace. Elevating via sudo..."
    exec sudo env PATH="$PATH" ROOT_DIR="$ROOT_DIR" "$0" "$@"
fi

# Check if bpftrace is installed
if ! command -v bpftrace &>/dev/null; then
    echo "[ERROR] bpftrace is not installed. Please install it (e.g., sudo apt install bpftrace)."
    exit 1
fi

TARGET="$1"
DATASET="$2"
KERNEL_VER="$(uname -r)"
TARGET_DIR="${OUTPUT_DIR}/${KERNEL_VER}"
mkdir -p "${TARGET_DIR}"

if [ -n "$DATASET" ]; then
    FILENAME_SUFFIX="${TARGET}_${DATASET}"
else
    FILENAME_SUFFIX="${TARGET}"
fi

LOG_FILE="${TARGET_DIR}/bpftrace_numa_page_${FILENAME_SUFFIX}.log"
PERF_LOG_FILE="${TARGET_DIR}/perf_bandwidth_${FILENAME_SUFFIX}.log"
REGRESS_LOG_FILE="${TARGET_DIR}/regress_${FILENAME_SUFFIX}.log"

# Remove any stale output files for this specific workload before running
rm -f "${LOG_FILE}" "${PERF_LOG_FILE}" "${REGRESS_LOG_FILE}"

# Configure perf events: Check for Uncore IMC support, else fallback to core PMU DRAM events
if [ -z "${PERF_EVENTS:-}" ]; then
    if ls /sys/bus/event_source/devices/uncore_imc* &>/dev/null; then
        UNCORE_EVENTS=()
        for imc in /sys/bus/event_source/devices/uncore_imc*; do
            dev_name="$(basename "$imc")"
            if [ -f "$imc/events/data_reads" ]; then
                UNCORE_EVENTS+=("${dev_name}/data_reads/")
            fi
            if [ -f "$imc/events/data_writes" ]; then
                UNCORE_EVENTS+=("${dev_name}/data_writes/")
            fi
        done
        if [ ${#UNCORE_EVENTS[@]} -gt 0 ]; then
            PERF_EVENTS=$(IFS=","; echo "${UNCORE_EVENTS[*]}")
        else
            PERF_EVENTS="uncore_imc/data_reads/,uncore_imc/data_writes/"
        fi
    else
        # Fallback for platforms/CPUs without uncore_imc PMU driver
        PERF_EVENTS="cpu/event=0xd1,umask=0x01,name=local_dram/,cpu/event=0xd1,umask=0x02,name=remote_dram/"
    fi
fi

# Dynamically select all available traceable symbols
PROBES_LIST=()
PROBE_DESCS=()

if grep -w "do_numa_page" /proc/kallsyms &>/dev/null; then
    PROBES_LIST+=("do_numa_page")
    PROBE_DESCS+=("do_numa_page (Full Fault Handler)")
fi

if grep -w "decide_queue_page" /proc/kallsyms &>/dev/null; then
    PROBES_LIST+=("decide_queue_page")
    PROBE_DESCS+=("decide_queue_page (Nomad Async Queue)")
fi

if grep -w "migrate_misplaced_page" /proc/kallsyms &>/dev/null; then
    PROBES_LIST+=("migrate_misplaced_page")
    PROBE_DESCS+=("migrate_misplaced_page (Sync Migration)")
fi

if grep -w "intel_pmu_handle_irq" /proc/kallsyms &>/dev/null; then
    PROBES_LIST+=("intel_pmu_handle_irq")
    PROBE_DESCS+=("intel_pmu_handle_irq (PMI Interrupt Handler)")
fi

if [ ${#PROBES_LIST[@]} -eq 0 ]; then
    echo "[ERROR] No NUMA fault handling symbols found in /proc/kallsyms."
    exit 1
fi

TARGET_DESC=$(IFS=", "; echo "${PROBE_DESCS[*]}")

# Automatically register perf dynamic probes for traceable NUMA handlers and append to PERF_EVENTS
for p in "${PROBES_LIST[@]}"; do
    perf probe -q -a "${p}" 2>/dev/null || true
    if perf list "probe:${p}" 2>/dev/null | grep -q "probe:${p}"; then
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
echo " Workload       : ${TARGET} ${2:-}"
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

# Function to thoroughly clean caches, reclaim memory, and quiesce the system
clean_memory_caches() {
    echo "[*] Cleaning memory caches, dropping buffers, compacting memory & quiescing..."

    # 1. Terminate any lingering background profilers or stale benchmark processes
    killall -9 bpftrace 2>/dev/null || true
    pkill -9 -f "perf record" 2>/dev/null || true
    pkill -9 -f "redis-server" 2>/dev/null || true
    pkill -9 -f "silo" 2>/dev/null || true

    # 2. Reclaim stale SysV IPC shared memory segments
    ipcs -m 2>/dev/null | awk '$2 ~ /^[0-9]+$/ {print $2}' | xargs -r ipcrm -m 2>/dev/null || true

    # 3. Synchronize filesystem buffers with settling time
    sync
    sleep 1
    sync

    # 4. Flush clean pagecache, dentries, and inodes via sysctl
    sysctl -w vm.drop_caches=3 >/dev/null 2>&1 || echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    # 5. Compact memory across all NUMA nodes to defragment for THP
    sysctl -w vm.compact_memory=1 >/dev/null 2>&1 || echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true

    # 6. Flush and reset Swap only if active
    if [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then
        swapoff -a 2>/dev/null && swapon -a 2>/dev/null || true
    fi

    # 7. Settle kernel threads (kswapd, kcompactd, khugepaged)
    sleep 2
}

# Clean caches and reset memory state prior to profiling
clean_memory_caches

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

echo "[+] bpftrace attached successfully (PID ${BPF_PID}). Enabling NUMA balancing & running workload..."
echo "------------------------------------------------------------------------------------------"

# Adaptive NUMA balancing setup based on active kernel
if echo "${KERNEL_VER}" | grep -iq "nomad"; then
    # Nomad uses mode 2 (Tiered NUMA Balancing) and async_promote.ko
    sysctl -w kernel.numa_balancing=2 2>/dev/null || true
    if [ ! -f /proc/perfnomad ]; then
        echo -e "\033[1;33m[WARNING] Nomad kernel detected but /proc/perfnomad is missing! Make sure async_promote.ko is loaded.\033[0m"
    fi
else
    # Upstream TPP / generic memory tiering: mode 3 (Normal + Tiering) or fallback to 2 / 1
    #sysctl -w kernel.numa_balancing=3 2>/dev/null || sysctl -w kernel.numa_balancing=2 2>/dev/null || sysctl -w kernel.numa_balancing=1 2>/dev/null || true
    sysctl -w kernel.numa_balancing=0 2>/dev/null
fi
echo true | tee /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

# Ensure bpftrace probes and background tasks are cleaned up and permissions restored on exit
cleanup() {
    kill -INT "${BPF_PID:-}" 2>/dev/null || true
    killall -9 bpftrace 2>/dev/null || true
    perf probe -q -d 'probe:*' 2>/dev/null || true
    chmod -R a+rw "${TARGET_DIR}" 2>/dev/null || true
    if [ -n "${SUDO_USER:-}" ]; then
        chown -R "${SUDO_USER}:${SUDO_USER}" "${TARGET_DIR}" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Resolve and execute workload command wrapped with perf stat and run_with_stats.sh
WORKLOAD_CMD=$("${SCRIPT_DIR}/exec_workload.sh" --get-cmd "$@")
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

# Ensure all generated output files are readable and writable by non-root users
chmod -R a+rw "${TARGET_DIR}" 2>/dev/null || true
if [ -n "${SUDO_USER:-}" ]; then
    chown -R "${SUDO_USER}:${SUDO_USER}" "${TARGET_DIR}" 2>/dev/null || true
fi

echo "=========================================================================================="
echo " bpftrace Latency Results for NUMA Page Fault Handling (${TARGET}):"
echo " Saved to: ${LOG_FILE}"
echo "=========================================================================================="
cat "${LOG_FILE}"
echo "=========================================================================================="
echo " perf Bandwidth / DRAM Access Stats saved to: ${PERF_LOG_FILE}"
echo "=========================================================================================="
