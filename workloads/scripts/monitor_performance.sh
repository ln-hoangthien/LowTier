#!/bin/bash
# ===================================================================
# Multi-Kernel NUMA & Tiered Memory Performance Monitor
# Measures VMSTAT faults, kernel-specific tiering counters, and bandwidth
# Calculates before/after deltas and outputs performance summary reports
#
# Usage:
#   $0 --start                    # 1. Capture baseline counters before execution
#   $0 --stop [COMMAND...]        # 2. Capture final counters, calculate deltas & report
#   $0 <command>                  # 3. Standalone wrapper execution mode
# ===================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

# Session-based state files to decouple start, execution, and stop
PERF_STATE_DIR="${PERF_STATE_DIR:-/tmp}"
PERF_SESSION_ID="${PERF_SESSION_ID:-${PPID}}"
STATE_META="${PERF_STATE_DIR}/perf_monitor_${PERF_SESSION_ID}.meta"
STATE_VMSTAT="${PERF_STATE_DIR}/perf_monitor_${PERF_SESSION_ID}.vmstat"
STATE_PERFNOMAD="${PERF_STATE_DIR}/perf_monitor_${PERF_SESSION_ID}.perfnomad"

SETTLE_SLEEP="${SETTLE_SLEEP:-5}"
KERNEL_VER="$(uname -r)"

# ------------------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------------------

# Dynamically calculate Node 1 (slow memory) used memory in MB
get_node1_used_mb() {
    local meminfo="/sys/devices/system/node/node1/meminfo"
    if [ -f "$meminfo" ]; then
        local used_mb
        used_mb=$(awk '
            /MemUsed:/  {u=$4; exit}
            /MemTotal:/ {t=$4}
            /MemFree:/  {f=$4}
            END {if (u) print int(u/1024); else if (t && f) print int((t-f)/1024); else print 0}
        ' "$meminfo" 2>/dev/null)
        [ -n "$used_mb" ] && [ "$used_mb" -gt 0 ] && { echo "$used_mb"; return; }
    fi
    local n1_size n1_free
    n1_size=$(numactl -H 2>/dev/null | awk '/node 1 size:/ {print $4; exit}')
    n1_free=$(numactl -H 2>/dev/null | awk '/node 1 free:/ {print $4; exit}')
    [ -n "$n1_size" ] && [ -n "$n1_free" ] && echo $(( n1_size - n1_free )) || echo 0
}

# Helpers: read /proc/vmstat in a single in-memory pass from specified source file
read_vmstat() {
    local -n _arr=$1
    local src="${2:-/proc/vmstat}"
    if [ -f "$src" ]; then
        while read -r k v; do
            _arr["$k"]="$v"
        done < "$src"
    fi
}

# Helpers: read /proc/perfnomad in a single in-memory pass from specified source file
read_perfnomad() {
    local -n _arr=$1
    local src="${2:-/proc/perfnomad}"
    if [ -f "$src" ]; then
        while read -r k v; do
            _arr["$k"]="$v"
        done < "$src"
    fi
}

# Helpers: read PMI
get_pmi_count() {
    awk '/^[[:space:]]*PMI:/ {s=0; for(i=2;i<=NF;i++) s+=$i; print s; exit}' /proc/interrupts 2>/dev/null || echo 0
}

# Unit conversion helpers
pages_to_gb() { awk "BEGIN {printf \"%.2f\", (${1:-0} * 4096) / 1073741824}"; }
pages_to_mb() { awk "BEGIN {printf \"%.2f\", (${1:-0} * 4096) / 1048576}"; }
pages_to_bw() { awk "BEGIN {printf \"%.2f MB/s\", (${1:-0} * 4096) / (1048576 * ${WORKLOAD_RUNTIME:-1})}"; }

# ------------------------------------------------------------------------------------------
# 1. Start Telemetry Baseline
# ------------------------------------------------------------------------------------------
start_monitor() {
    if [ "$SETTLE_SLEEP" -gt 0 ]; then
        sleep "${SETTLE_SLEEP}"
    fi

    local pmi_before node1_before start_time
    pmi_before=$(get_pmi_count)
    node1_before=$(get_node1_used_mb)
    start_time=$(date +%s)

    cat <<EOF > "${STATE_META}"
START_TIME=${start_time}
PMI_BEFORE=${pmi_before}
NODE1_BEFORE=${node1_before}
EOF

    [ -f /proc/vmstat ] && cp /proc/vmstat "${STATE_VMSTAT}" 2>/dev/null || true
    [ -f /proc/perfnomad ] && cp /proc/perfnomad "${STATE_PERFNOMAD}" 2>/dev/null || true
}

# ------------------------------------------------------------------------------------------
# 2. Stop Telemetry, Compute Deltas, and Print Summary Reports
# ------------------------------------------------------------------------------------------
stop_monitor() {
    local cmd="$*"
    local end_time=$(date +%s)

    local start_time=$(( end_time - 1 ))
    local pmi_before=0
    local node1_before=0

    if [ -f "${STATE_META}" ]; then
        # shellcheck disable=SC1090
        source "${STATE_META}"
    fi

    WORKLOAD_RUNTIME=$((end_time - start_time))
    [ $WORKLOAD_RUNTIME -le 0 ] && WORKLOAD_RUNTIME=1

    # Settling sleep after workload execution to allow any async worker threads to finish
    if [ "$SETTLE_SLEEP" -gt 0 ]; then
        sleep "${SETTLE_SLEEP}"
    fi

    # Read baseline and final counters
    declare -A VMS_B PN_B VMS_A PN_A
    read_vmstat VMS_B "${STATE_VMSTAT}"
    read_perfnomad PN_B "${STATE_PERFNOMAD}"
    read_vmstat VMS_A "/proc/vmstat"
    read_perfnomad PN_A "/proc/perfnomad"
    local pmi_after=$(get_pmi_count)
    local node1_after=$(get_node1_used_mb)

    # Clean up session state files
    rm -f "${STATE_META}" "${STATE_VMSTAT}" "${STATE_PERFNOMAD}" 2>/dev/null || true

    vm_delta() {
        local a="${VMS_A[$1]:-0}" b="${VMS_B[$1]:-0}"
        [ "$a" -ge "$b" ] 2>/dev/null && echo $(( a - b )) || echo 0
    }

    pn_delta() {
        local a="${PN_A[$1]:-0}" b="${PN_B[$1]:-0}"
        [ "$a" -ge "$b" ] 2>/dev/null && echo $(( a - b )) || echo 0
    }

    # Calculate VMSTAT Deltas
    local delta_pgf=$(vm_delta "pgfault")
    local delta_numa=$(vm_delta "numa_hint_faults")
    local delta_numa_pages_mig=$(vm_delta "numa_pages_migrated")
    local delta_pgalloc=$(( $(vm_delta "pgalloc_normal") + $(vm_delta "pgalloc_dma32") ))
    local delta_numa_hit=$(vm_delta "numa_hit")
    local delta_numa_miss=$(vm_delta "numa_miss")
    local delta_allocstall=$(vm_delta "allocstall_normal")
    local delta_prom_cand=$(vm_delta "pgpromote_candidate")
    local delta_prom_page=$(vm_delta "pgpromote_anon")
    local delta_dem_page_anon=$(vm_delta "pgdemote_anon")
    local delta_dem_page_file=$(vm_delta "pgdemote_file")
    local delta_dem_kswapd=$(vm_delta "pgdemote_kswapd")
    local delta_dem_direct=$(vm_delta "pgdemote_direct")
    local delta_mig_succ=$(vm_delta "pgmigrate_success")
    local delta_mig_fail=$(vm_delta "pgmigrate_fail")

    # Memtis Deltas
    local delta_memtis_prom=$(vm_delta "htmm_nr_promoted")
    local delta_memtis_dem=$(vm_delta "htmm_nr_demoted")
    local delta_memtis_alloc_dram=$(vm_delta "htmm_alloc_dram")
    local delta_memtis_alloc_nvm=$(vm_delta "htmm_alloc_nvm")

    # Node 1 & PMI Deltas
    local delta_pmi=$(( pmi_after > pmi_before ? pmi_after - pmi_before : 0 ))
    local delta_node1=$(( node1_after > node1_before ? node1_after - node1_before : 0 ))

    local total_dem_pages=$(( delta_dem_kswapd + delta_dem_direct ))
    [ "$total_dem_pages" -eq 0 ] && total_dem_pages=$(( delta_dem_page_anon + delta_dem_page_file ))
    local dem_bw=$(pages_to_bw "$total_dem_pages")
    local alloc_gb=$(pages_to_gb "$delta_pgalloc")
    local alloc_bw=$(pages_to_bw "$delta_pgalloc")
    local hit_gb=$(pages_to_gb "$delta_numa_hit")
    local miss_gb=$(pages_to_gb "$delta_numa_miss")

    # Print Standard VMSTAT Fault & Allocation Report
    echo ""
    echo "=========================================================="
    echo "          WORKLOAD VMSTAT FAULT & ALLOCATION REPORT       "
    echo "=========================================================="
    echo " Kernel Release                         : ${KERNEL_VER}"
    echo " Workload Execution Runtime             : ${WORKLOAD_RUNTIME} seconds"
    echo " Total Page Faults Delta (pgfault)      : ${delta_pgf}"
    echo " NUMA Hint Faults Delta (numa_hint)     : ${delta_numa}"
    echo " NUMA Pages Migrated (numa_pages_mig)   : ${delta_numa_pages_mig}"
    if [ "${delta_pmi:-0}" -gt 0 ]; then
        echo " PMI Interrupts Delta (interrupts)      : ${delta_pmi}"
    fi
    echo "----------------------------------------------------------"
    echo " Total Allocated Pages (pgalloc)        : ${delta_pgalloc} (${alloc_gb} GB, ${alloc_bw})"
    echo " NUMA Local Alloc Hits (numa_hit)       : ${delta_numa_hit} (${hit_gb} GB)"
    echo " NUMA Remote Alloc Misses (numa_miss)   : ${delta_numa_miss} (${miss_gb} GB spillover)"
    if [ "$delta_allocstall" -gt 0 ]; then
        echo " Direct Allocation Stalls (allocstall)  : ${delta_allocstall}"
    fi
    echo " Total Migrated Pages Delta (pgmigrate) : ${delta_mig_succ}"
    if [ "$delta_mig_fail" -gt 0 ]; then
        echo " Migration Failures (pgmigrate_fail)    : ${delta_mig_fail}"
    fi
    echo "=========================================================="

    # Nomad Performance Summary
    if [ -f /proc/perfnomad ] || [[ "${KERNEL_VER,,}" =~ nomad ]]; then
        local delta_try delta_success delta_retry delta_tx_succ delta_tx_fail delta_retreat delta_total
        delta_try=$(pn_delta "try_to_promote_nr")
        delta_success=$(pn_delta "success_nr")
        delta_retry=$(pn_delta "retry_nr")
        delta_tx_succ=$(pn_delta "transactional_success_nr")
        delta_tx_fail=$(pn_delta "transactional_fail_nr")
        delta_retreat=$(pn_delta "retreated_page_nr")
        delta_total=$((delta_success + delta_retry))

        local prom_mb prom_bw abort_rate
        prom_mb=$(pages_to_mb "$delta_success")
        prom_bw=$(pages_to_bw "$delta_success")

        if [ "$delta_total" -gt 0 ]; then
            abort_rate=$(awk "BEGIN {printf \"%.2f%%\", ($delta_retry / $delta_total) * 100}")
        else
            abort_rate="0.00%"
        fi

        echo ""
        echo "=========================================================================================="
        echo "                   NOMAD APPLICATION-WIDE PERFORMANCE REPORT                              "
        echo "=========================================================================================="
        echo " Executed Command          : ${cmd}"
        echo " Application Runtime       : ${WORKLOAD_RUNTIME} seconds"
        echo " Timestamp                 : $(date +%H:%M:%S)"
        echo "------------------------------------------------------------------------------------------"
        echo " Total Promotion Candidates (try_nr)      : ${delta_try}"
        echo " Successful Async Promotions (success_nr) : ${delta_success} (${prom_mb} MB Promoted)"
        echo " Retried/Aborted Promotions (retry_nr)    : ${delta_retry}"
        echo " Transactional Promotions Succeeded       : ${delta_tx_succ}"
        echo " Transactional Promotions Failed          : ${delta_tx_fail}"
        echo " Retreated Inactive Pages                 : ${delta_retreat}"
        echo " Average Promotion Bandwidth              : ${prom_bw}"
        echo " Average Demotion Bandwidth               : ${dem_bw}"
        echo " Overall Application Abortion Rate        : ${abort_rate}"
        echo " Slow Tier Node 1 Used Memory             : ${node1_after} MB (Growth: +${delta_node1} MB)"
        echo "=========================================================================================="

    # Memtis (HTMM) Performance Summary
    elif [ "$delta_memtis_prom" -gt 0 ] || [ "$delta_memtis_dem" -gt 0 ] || [[ "${KERNEL_VER,,}" =~ memtis|htmm ]]; then
        local prom_mb prom_bw dem_mb dem_bw_m
        prom_mb=$(pages_to_mb "$delta_memtis_prom")
        prom_bw=$(pages_to_bw "$delta_memtis_prom")
        dem_mb=$(pages_to_mb "$delta_memtis_dem")
        dem_bw_m=$(pages_to_bw "$delta_memtis_dem")

        echo ""
        echo "=========================================================================================="
        echo "                   MEMTIS (HTMM) APPLICATION-WIDE PERFORMANCE REPORT                     "
        echo "=========================================================================================="
        echo " Executed Command          : ${cmd}"
        echo " Application Runtime       : ${WORKLOAD_RUNTIME} seconds"
        echo " Timestamp                 : $(date +%H:%M:%S)"
        echo "------------------------------------------------------------------------------------------"
        echo " Promoted Pages (htmm_nr_promoted)   : ${delta_memtis_prom} (${prom_mb} MB Promoted)"
        echo " Demoted Pages (htmm_nr_demoted)     : ${delta_memtis_dem} (${dem_mb} MB Demoted)"
        echo " Direct DRAM Allocations             : ${delta_memtis_alloc_dram}"
        echo " Direct NVM / Slow Allocations       : ${delta_memtis_alloc_nvm}"
        echo " Average Promotion Bandwidth         : ${prom_bw}"
        echo " Average Demotion Bandwidth          : ${dem_bw_m}"
        echo " Slow Tier Node 1 Used Memory        : ${node1_after} MB (Growth: +${delta_node1} MB)"
        echo "=========================================================================================="

    # Tiered Migration Performance Summary
    elif [ "$delta_prom_page" -gt 0 ] || [ "$delta_mig_succ" -gt 0 ]; then
        local prom_pages=$(( delta_prom_page > 0 ? delta_prom_page : delta_mig_succ ))
        local prom_mb prom_bw
        prom_mb=$(pages_to_mb "$prom_pages")
        prom_bw=$(pages_to_bw "$prom_pages")

        echo ""
        echo "=========================================================================================="
        echo "                 TIERED MEMORY MIGRATION & BANDWIDTH SUMMARY                              "
        echo "=========================================================================================="
        echo " Executed Command          : ${cmd}"
        echo " Application Runtime       : ${WORKLOAD_RUNTIME} seconds"
        echo " Timestamp                 : $(date +%H:%M:%S)"
        echo "------------------------------------------------------------------------------------------"
        if [ "$delta_prom_cand" -gt 0 ]; then
            echo " Promotion Candidates (pgpromote_cand)    : ${delta_prom_cand}"
        fi
        echo " Promoted Memory Volume                   : ${prom_mb} MB (${prom_pages} pages)"
        if [ "${total_dem_pages:-0}" -gt 0 ]; then
            echo " Demoted Memory Volume                    : $(pages_to_mb "$total_dem_pages") MB (${total_dem_pages} pages)"
        fi
        if [ "$delta_dem_page_anon" -gt 0 ] || [ "$delta_dem_page_file" -gt 0 ]; then
            echo " Demoted Pages (anon / file)              : ${delta_dem_page_anon} anon / ${delta_dem_page_file} file"
        fi
        if [ "$delta_dem_kswapd" -gt 0 ] || [ "$delta_dem_direct" -gt 0 ]; then
            echo " Demoted By (kswapd / direct)             : ${delta_dem_kswapd} kswapd / ${delta_dem_direct} direct"
        fi
        echo " Average Promotion Bandwidth              : ${prom_bw}"
        echo " Average Demotion Bandwidth               : ${dem_bw}"
        echo " Slow Tier Node 1 Used Memory             : ${node1_after} MB (Growth: +${delta_node1} MB)"
        echo "=========================================================================================="
    fi
    echo ""
}

# ------------------------------------------------------------------------------------------
# Main Dispatcher
# ------------------------------------------------------------------------------------------
case "${1:-}" in
    --start|-s)
        start_monitor
        ;;
    --stop)
        shift
        stop_monitor "$@"
        ;;
    --cleanup|-c)
        rm -f "${STATE_META}" "${STATE_VMSTAT}" "${STATE_PERFNOMAD}" 2>/dev/null || true
        ;;
    --help|-h)
        echo "Usage:"
        echo "  $0 --start                    # Capture baseline counters before execution"
        echo "  $0 --stop [WORKLOAD_COMMAND]  # Capture final counters, calculate deltas and print report"
        echo "  $0 <command>                  # Standalone execution wrapped under GNU time"
        exit 0
        ;;
    *)
        if [ $# -eq 0 ]; then
            echo "Usage: $0 [--start | --stop <cmd> | --cleanup | <command>]"
            exit 1
        fi
        # Standalone wrapped execution mode
        start_monitor
        /usr/bin/time -v bash -c "exec $*"
        _status=$?
        stop_monitor "$@"
        exit "$_status"
        ;;
esac
