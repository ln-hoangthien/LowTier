#!/bin/bash
# ===================================================================
# Multi-Kernel NUMA & Tiered Memory Application-Wide Monitor
# Measures VMSTAT faults, kernel-specific tiering counters, and bandwidth
# for the ENTIRE workload run ($@)
# ===================================================================

if [ $# -eq 0 ]; then
    echo "Usage: $0 <command>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

# Function to dynamically calculate Node 1 (slow memory) used memory in MB
get_node1_used_mb() {
    if [ -f /sys/devices/system/node/node1/meminfo ]; then
        local used_kb=$(awk '/MemUsed:/ {print $4; exit}' /sys/devices/system/node/node1/meminfo 2>/dev/null)
        [ -n "$used_kb" ] && { echo $(( used_kb / 1024 )); return; }
    fi
    local n1_size n1_free
    n1_size=$(numactl -H 2>/dev/null | awk '/node 1 size:/ {print $4; exit}')
    n1_free=$(numactl -H 2>/dev/null | awk '/node 1 free:/ {print $4; exit}')
    [ -n "$n1_size" ] && [ -n "$n1_free" ] && echo $(( n1_size - n1_free )) || echo 0
}

SETTLE_SLEEP="${SETTLE_SLEEP:-5}"

# 1. Settling sleep before capturing baseline counters
if [ "$SETTLE_SLEEP" -gt 0 ]; then
    sleep "${SETTLE_SLEEP}"
fi

# Helpers to read /proc/vmstat and /proc/perfnomad in a single in-memory pass
read_vmstat() {
    local -n _arr=$1
    if [ -f /proc/vmstat ]; then
        while read -r k v; do
            _arr["$k"]="$v"
        done < /proc/vmstat
    fi
}

read_perfnomad() {
    local -n _arr=$1
    if [ -f /proc/perfnomad ]; then
        while read -r k v; do
            _arr["$k"]="$v"
        done < /proc/perfnomad
    fi
}

get_pmi_count() {
    awk '/^[[:space:]]*PMI:/ {s=0; for(i=2;i<=NF;i++) s+=$i; print s; exit}' /proc/interrupts 2>/dev/null || echo 0
}

# 2. Read baseline counters BEFORE workload execution
declare -A VMS_B PN_B
read_vmstat VMS_B
read_perfnomad PN_B
PMI_BEFORE=$(get_pmi_count)
NODE1_BEFORE=$(get_node1_used_mb)

# 3. Execute the workload command with GNU time to capture runtime & Peak RSS
if [ -f /sys/fs/cgroup/memtis_workload/cgroup.procs ]; then
    echo $$ > /sys/fs/cgroup/memtis_workload/cgroup.procs 2>/dev/null || true
fi

KERNEL_VER="$(uname -r)"

# Extract binary name for profiler target matching
if [ -z "${TARGET_EXE_NAME:-}" ]; then
    for arg in "$@"; do
        if [ -f "$arg" ] && [ -x "$arg" ]; then
            TARGET_EXE_NAME="$(basename "$arg")"
            break
        fi
    done
fi
TARGET_EXE_NAME="${TARGET_EXE_NAME:-*}"

START_TIME=$(date +%s)

# PACT autotie: Launch workload in background, record target PID, and attach PACT daemon
if echo "${KERNEL_VER}" | grep -iq "pact"; then
    PACT_BIN="${ROOT_DIR}/baselines/pact/src/pact"
    TARGET_PID_FILE=$(mktemp /tmp/pact_pid_XXXXXX)

    /usr/bin/time -v bash -c "echo \$\$ > '${TARGET_PID_FILE}'; exec $*" &
    TIME_PID=$!

    TARGET_PID=""
    for i in $(seq 1 100); do
        if [ -s "${TARGET_PID_FILE}" ]; then
            TARGET_PID=$(cat "${TARGET_PID_FILE}" | tr -d ' \t\n\r')
            [ -n "${TARGET_PID}" ] && break
        fi
        sleep 0.02
    done
    rm -f "${TARGET_PID_FILE}"

    PACT_PID=""
    if [ -n "${TARGET_PID}" ] && [ -x "${PACT_BIN}" ] && kill -0 "${TARGET_PID}" 2>/dev/null; then
        PACT_LOG_FILE="${TARGET_DIR:-/tmp}/pact_${FILENAME_SUFFIX:-run}.log"
        # Workload-aware warmup delay (allows manual override if PACT_WARMUP_SEC is set)
        if [ -z "${PACT_WARMUP_SEC:-}" ]; then
            if echo "$*" | grep -qE "sssp.*(kron|urand|web)|(kron|urand|web)\.wsg"; then
                PACT_WARMUP_SEC=15   # Large weighted graphs take ~12s
            elif echo "$*" | grep -qiE "xsbench"; then
                PACT_WARMUP_SEC=15   # In-memory grid initialization takes ~12.5s
            elif echo "$*" | grep -qE "gapbs|/pr|/bc|/bfs|/cc|/tc|/sssp"; then
                PACT_WARMUP_SEC=7   # Standard graphs take ~6s
            else
                PACT_WARMUP_SEC=2
            fi
        fi
        PACT_BATCH_SIZE="${PACT_BATCH_SIZE:-4096}"
        (
            if [ "${PACT_WARMUP_SEC}" -gt 0 ]; then
                echo "[+] Waiting ${PACT_WARMUP_SEC}s (workload ingestion delay) before activating PACT daemon..."
                sleep "${PACT_WARMUP_SEC}"
            fi
            if [ "${TARGET_EXE_NAME}" != "*" ]; then
                MATCHED_PID=$(pgrep -n -x "${TARGET_EXE_NAME}" 2>/dev/null || true)
                [ -n "${MATCHED_PID}" ] && TARGET_PID="${MATCHED_PID}"
            fi
            if kill -0 "${TARGET_PID}" 2>/dev/null; then
                echo "[+] PACT autotie active: Attaching PACT daemon (PID ${TARGET_PID}, batch size ${PACT_BATCH_SIZE})..."
                exec "${PACT_BIN}" --workload "${TARGET_PID}" --max-migrations-per-cycle "${PACT_BATCH_SIZE}" > "${PACT_LOG_FILE}" 2>&1
            fi
        ) &
        PACT_PID=$!
        echo "[+] PACT monitor task active (PID ${PACT_PID})."
    fi

    wait "${TIME_PID}"
    STATUS=$?

    if [ -n "${PACT_PID}" ] && kill -0 "${PACT_PID}" 2>/dev/null; then
        echo "[*] Waiting for PACT daemon (PID ${PACT_PID}) to finalize..."
        for i in {1..20}; do
            if ! kill -0 "${PACT_PID}" 2>/dev/null; then break; fi
            sleep 0.1
        done
        if kill -0 "${PACT_PID}" 2>/dev/null; then
            kill -INT "${PACT_PID}" 2>/dev/null || true
            sleep 0.5
        fi
        if kill -0 "${PACT_PID}" 2>/dev/null; then
            kill -9 "${PACT_PID}" 2>/dev/null || true
        fi
    fi
elif echo "${KERNEL_VER}" | grep -iq "hybridtier"; then
    # HybridTier autotie: In-process PEBS monitoring thread via LD_PRELOAD hook.so
    # Disable kernel dynamic sample rate throttling and lock max_sample_rate to 150000
    sysctl -w kernel.perf_event_max_sample_rate=150000 >/dev/null 2>&1 || true
    sysctl -w kernel.perf_cpu_time_max_percent=0 >/dev/null 2>&1 || true
    sysctl -w kernel.perf_event_paranoid=-1 >/dev/null 2>&1 || true

    HYBRID_HOOK="${HYBRIDTIER_HOOK:-${ROOT_DIR}/baselines/hybridtier/hook/hook.so}"
    echo "[+] HybridTier autotie active: LD_PRELOAD=${HYBRID_HOOK}, TARGET_EXE_NAME=${TARGET_EXE_NAME}"

    if [ -f "${HYBRID_HOOK}" ]; then
        /usr/bin/time -v env LD_PRELOAD="${HYBRID_HOOK}${LD_PRELOAD:+:$LD_PRELOAD}" TARGET_EXE_NAME="${TARGET_EXE_NAME}" bash -c "$*"
    else
        /usr/bin/time -v bash -c "$*"
    fi
    STATUS=$?

    # Terminate orphan background perf stat process spawned by HybridTier's hook.so
    pkill -f "perf stat -I 60000" 2>/dev/null || true
else
    # Standard In-Kernel Baselines (TPP, Colloid, Nomad, Memtis, Generic)
    /usr/bin/time -v bash -c "$*"
    STATUS=$?
fi

END_TIME=$(date +%s)

WORKLOAD_RUNTIME=$((END_TIME - START_TIME))
[ $WORKLOAD_RUNTIME -le 0 ] && WORKLOAD_RUNTIME=1

# 4. Settle sleep after workload execution to allow any async worker threads to finish
if [ "$SETTLE_SLEEP" -gt 0 ]; then
    sleep "${SETTLE_SLEEP}"
fi

# 5. Read final counters AFTER execution
declare -A VMS_A PN_A
read_vmstat VMS_A
read_perfnomad PN_A
PMI_AFTER=$(get_pmi_count)
NODE1_AFTER=$(get_node1_used_mb)

vm_delta() {
    local a="${VMS_A[$1]:-0}" b="${VMS_B[$1]:-0}"
    [ "$a" -ge "$b" ] 2>/dev/null && echo $(( a - b )) || echo 0
}

pn_delta() {
    local a="${PN_A[$1]:-0}" b="${PN_B[$1]:-0}"
    [ "$a" -ge "$b" ] 2>/dev/null && echo $(( a - b )) || echo 0
}

pages_to_gb() { awk "BEGIN {printf \"%.2f\", (${1:-0} * 4096) / 1073741824}"; }
pages_to_mb() { awk "BEGIN {printf \"%.2f\", (${1:-0} * 4096) / 1048576}"; }
pages_to_bw() { awk "BEGIN {printf \"%.2f MB/s\", (${1:-0} * 4096) / (1048576 * ${WORKLOAD_RUNTIME})}"; }

# 6. Calculate VMSTAT Deltas
DELTA_PGF=$(vm_delta "pgfault")
DELTA_NUMA=$(vm_delta "numa_hint_faults")
DELTA_NUMA_PAGES_MIG=$(vm_delta "numa_pages_migrated")
DELTA_PGALLOC=$(( $(vm_delta "pgalloc_normal") + $(vm_delta "pgalloc_dma32") ))
DELTA_NUMA_HIT=$(vm_delta "numa_hit")
DELTA_NUMA_MISS=$(vm_delta "numa_miss")
DELTA_NUMA_FOREIGN=$(vm_delta "numa_foreign")
DELTA_ALLOCSTALL=$(vm_delta "allocstall_normal")
DELTA_PROM_CAND=$(vm_delta "pgpromote_candidate")
DELTA_PROM_TRIED=$(vm_delta "pgpromote_tried")
DELTA_PROM_PAGE=$(vm_delta "pgpromote_anon")
DELTA_DEM_PAGE_ANON=$(vm_delta "pgdemote_anon")
DELTA_DEM_PAGE_FILE=$(vm_delta "pgdemote_file")
DELTA_DEM_KSWAPD=$(vm_delta "pgdemote_kswapd")
DELTA_DEM_DIRECT=$(vm_delta "pgdemote_direct")
DELTA_MIG_SUCC=$(vm_delta "pgmigrate_success")
DELTA_MIG_FAIL=$(vm_delta "pgmigrate_fail")
DELTA_MIG_DST_FULL=$(vm_delta "pgmigrate_fail_dst_node_full")

# Memtis Deltas
DELTA_MEMTIS_PROM=$(vm_delta "htmm_nr_promoted")
DELTA_MEMTIS_DEM=$(vm_delta "htmm_nr_demoted")
DELTA_MEMTIS_ALLOC_DRAM=$(vm_delta "htmm_alloc_dram")
DELTA_MEMTIS_ALLOC_NVM=$(vm_delta "htmm_alloc_nvm")

# Node 1 & PMI Deltas
DELTA_PMI=$(( PMI_AFTER > PMI_BEFORE ? PMI_AFTER - PMI_BEFORE : 0 ))
DELTA_NODE1=$(( NODE1_AFTER > NODE1_BEFORE ? NODE1_AFTER - NODE1_BEFORE : 0 ))

DEM_BW=$(awk "BEGIN {printf \"%.2f MB/s\", $DELTA_NODE1 / $WORKLOAD_RUNTIME}")
ALLOC_GB=$(pages_to_gb "$DELTA_PGALLOC")
ALLOC_BW=$(pages_to_bw "$DELTA_PGALLOC")
HIT_GB=$(pages_to_gb "$DELTA_NUMA_HIT")
MISS_GB=$(pages_to_gb "$DELTA_NUMA_MISS")

# 7. Print Standard VMSTAT Fault & Allocation Report (Shortened)
echo ""
echo "=========================================================="
echo "          WORKLOAD VMSTAT FAULT & ALLOCATION REPORT       "
echo "=========================================================="
echo " Kernel Release                         : $(uname -r)"
echo " Workload Execution Runtime             : ${WORKLOAD_RUNTIME} seconds"
echo " Total Page Faults Delta (pgfault)      : ${DELTA_PGF}"
echo " NUMA Hint Faults Delta (numa_hint)     : ${DELTA_NUMA}"
echo " NUMA Pages Migrated (numa_pages_mig)   : ${DELTA_NUMA_PAGES_MIG}"
if [ "${DELTA_PMI:-0}" -gt 0 ]; then
    echo " PMI Interrupts Delta (interrupts)      : ${DELTA_PMI}"
fi
echo "----------------------------------------------------------"
echo " Total Allocated Pages (pgalloc)        : ${DELTA_PGALLOC} (${ALLOC_GB} GB, ${ALLOC_BW})"
echo " NUMA Local Alloc Hits (numa_hit)       : ${DELTA_NUMA_HIT} (${HIT_GB} GB)"
echo " NUMA Remote Alloc Misses (numa_miss)   : ${DELTA_NUMA_MISS} (${MISS_GB} GB spillover)"
if [ $DELTA_ALLOCSTALL -gt 0 ]; then
    echo " Direct Allocation Stalls (allocstall)  : ${DELTA_ALLOCSTALL}"
fi
echo " Total Migrated Pages Delta (pgmigrate) : ${DELTA_MIG_SUCC}"
if [ $DELTA_MIG_FAIL -gt 0 ]; then
    echo " Migration Failures (pgmigrate_fail)    : ${DELTA_MIG_FAIL}"
fi
echo "=========================================================="

# 8. Print Kernel-Specific Tiering & Migration Performance Report
if [ -f /proc/perfnomad ] || echo "$(uname -r)" | grep -iq "nomad"; then
    DELTA_TRY=$(pn_delta "try_to_promote_nr")
    DELTA_SUCCESS=$(pn_delta "success_nr")
    DELTA_RETRY=$(pn_delta "retry_nr")
    DELTA_TX_SUCC=$(pn_delta "transactional_success_nr")
    DELTA_TX_FAIL=$(pn_delta "transactional_fail_nr")
    DELTA_RETREAT=$(pn_delta "retreated_page_nr")

    DELTA_TOTAL=$((DELTA_SUCCESS + DELTA_RETRY))
    PROM_MB=$(pages_to_mb "$DELTA_SUCCESS")
    PROM_BW=$(pages_to_bw "$DELTA_SUCCESS")

    if [ $DELTA_TOTAL -gt 0 ]; then
        ABORT_RATE=$(awk "BEGIN {printf \"%.2f%%\", ($DELTA_RETRY / $DELTA_TOTAL) * 100}")
    else
        ABORT_RATE="0.00%"
    fi

    echo ""
    echo "=========================================================================================="
    echo "                   NOMAD APPLICATION-WIDE PERFORMANCE REPORT                              "
    echo "=========================================================================================="
    echo " Executed Command          : $@"
    echo " Application Runtime       : ${WORKLOAD_RUNTIME} seconds"
    echo " Timestamp                 : $(date +%H:%M:%S)"
    echo "------------------------------------------------------------------------------------------"
    echo " Total Promotion Candidates (try_nr)      : ${DELTA_TRY}"
    echo " Successful Async Promotions (success_nr) : ${DELTA_SUCCESS} (${PROM_MB} MB Promoted)"
    echo " Retried/Aborted Promotions (retry_nr)    : ${DELTA_RETRY}"
    echo " Transactional Promotions Succeeded       : ${DELTA_TX_SUCC}"
    echo " Transactional Promotions Failed          : ${DELTA_TX_FAIL}"
    echo " Retreated Inactive Pages                 : ${DELTA_RETREAT}"
    echo " Average Promotion Bandwidth              : ${PROM_BW}"
    echo " Average Demotion Bandwidth               : ${DEM_BW}"
    echo " Overall Application Abortion Rate        : ${ABORT_RATE}"
    echo " Slow Tier Node 1 Used Memory             : ${NODE1_AFTER} MB (Growth: +${DELTA_NODE1} MB)"
    echo "=========================================================================================="
elif [ $DELTA_MEMTIS_PROM -gt 0 ] || [ $DELTA_MEMTIS_DEM -gt 0 ] || echo "$(uname -r)" | grep -iqE "memtis|htmm"; then
    # Memtis / HTMM Performance Report
    MEMTIS_PROM_MB=$(pages_to_mb "$DELTA_MEMTIS_PROM")
    MEMTIS_PROM_BW=$(pages_to_bw "$DELTA_MEMTIS_PROM")
    MEMTIS_DEM_MB=$(pages_to_mb "$DELTA_MEMTIS_DEM")
    MEMTIS_DEM_BW=$(pages_to_bw "$DELTA_MEMTIS_DEM")

    echo ""
    echo "=========================================================================================="
    echo "                   MEMTIS (HTMM) APPLICATION-WIDE PERFORMANCE REPORT                     "
    echo "=========================================================================================="
    echo " Executed Command          : $@"
    echo " Application Runtime       : ${WORKLOAD_RUNTIME} seconds"
    echo " Timestamp                 : $(date +%H:%M:%S)"
    echo "------------------------------------------------------------------------------------------"
    echo " Promoted Pages (htmm_nr_promoted)   : ${DELTA_MEMTIS_PROM} (${MEMTIS_PROM_MB} MB Promoted)"
    echo " Demoted Pages (htmm_nr_demoted)     : ${DELTA_MEMTIS_DEM} (${MEMTIS_DEM_MB} MB Demoted)"
    echo " Direct DRAM Allocations             : ${DELTA_MEMTIS_ALLOC_DRAM}"
    echo " Direct NVM / Slow Allocations       : ${DELTA_MEMTIS_ALLOC_NVM}"
    echo " Average Promotion Bandwidth         : ${MEMTIS_PROM_BW}"
    echo " Average Demotion Bandwidth          : ${MEMTIS_DEM_BW}"
    echo " Slow Tier Node 1 Used Memory        : ${NODE1_AFTER} MB (Growth: +${DELTA_NODE1} MB)"
    echo "=========================================================================================="
elif [ $DELTA_PROM_PAGE -gt 0 ] || [ $DELTA_MIG_SUCC -gt 0 ]; then
    # Upstream TPP / Generic Tiering Summary
    PROM_PAGES=$(( DELTA_PROM_PAGE > 0 ? DELTA_PROM_PAGE : DELTA_MIG_SUCC ))
    PROM_MB=$(pages_to_mb "$PROM_PAGES")
    PROM_BW=$(pages_to_bw "$PROM_PAGES")

    echo ""
    echo "=========================================================================================="
    echo "                 TIERED MEMORY MIGRATION & BANDWIDTH SUMMARY                              "
    echo "=========================================================================================="
    echo " Executed Command          : $@"
    echo " Application Runtime       : ${WORKLOAD_RUNTIME} seconds"
    echo " Timestamp                 : $(date +%H:%M:%S)"
    echo "------------------------------------------------------------------------------------------"
    if [ $DELTA_PROM_CAND -gt 0 ]; then
        echo " Promotion Candidates (pgpromote_cand)    : ${DELTA_PROM_CAND}"
    fi
    echo " Promoted Memory Volume                   : ${PROM_MB} MB (${PROM_PAGES} pages)"
    if [ $DELTA_DEM_PAGE_ANON -gt 0 ] || [ $DELTA_DEM_PAGE_FILE -gt 0 ]; then
        echo " Demoted Pages (anon / file)              : ${DELTA_DEM_PAGE_ANON} anon / ${DELTA_DEM_PAGE_FILE} file"
    fi
    if [ $DELTA_DEM_KSWAPD -gt 0 ] || [ $DELTA_DEM_DIRECT -gt 0 ]; then
        echo " Demoted By (kswapd / direct)             : ${DELTA_DEM_KSWAPD} kswapd / ${DELTA_DEM_DIRECT} direct"
    fi
    echo " Average Promotion Bandwidth              : ${PROM_BW}"
    echo " Average Demotion Bandwidth               : ${DEM_BW}"
    echo " Slow Tier Node 1 Used Memory             : ${NODE1_AFTER} MB (Growth: +${DELTA_NODE1} MB)"
    echo "=========================================================================================="
fi
echo ""

exit "${STATUS:-0}"

