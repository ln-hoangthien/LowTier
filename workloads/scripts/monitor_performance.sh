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
source "${SCRIPT_DIR}/cpu_config.sh"

# Session-based state files to decouple start, execution, and stop
PERF_STATE_DIR="${PERF_STATE_DIR:-/tmp}"
PERF_SESSION_ID="${PERF_SESSION_ID:-${PPID}}"
STATE_META="${PERF_STATE_DIR}/perf_monitor_${PERF_SESSION_ID}.meta"
STATE_VMSTAT="${PERF_STATE_DIR}/perf_monitor_${PERF_SESSION_ID}.vmstat"
STATE_PERFNOMAD="${PERF_STATE_DIR}/perf_monitor_${PERF_SESSION_ID}.perfnomad"
STATE_DAEMON_CPU="${PERF_STATE_DIR}/perf_monitor_${PERF_SESSION_ID}.daemon_cpu"
STATE_TS_PID="${PERF_STATE_DIR}/perf_monitor_${PERF_SESSION_ID}.ts_pid"
STATE_UNCORE="${PERF_STATE_DIR}/perf_monitor_${PERF_SESSION_ID}.uncore"

TS_MON_SRC="${SCRIPT_DIR}/tier_ts_mon.c"
TS_MON_BIN="${SCRIPT_DIR}/tier_ts_mon"

ENABLE_TIMESERIES="${ENABLE_TIMESERIES:-1}"
TS_INTERVAL_SEC="${TS_INTERVAL_SEC:-1}"
TS_OUT_FILE="${TS_OUT_FILE:-}"

SETTLE_SLEEP="${SETTLE_SLEEP:-5}"
KERNEL_VER="$(uname -r)"
if [ -z "${ENABLE_AUTONUMA_PMU:-}" ]; then
    [[ "${KERNEL_VER,,}" =~ autonuma ]] && ENABLE_AUTONUMA_PMU=1 || ENABLE_AUTONUMA_PMU=0
fi
CLK_TCK="$(getconf CLK_TCK 2>/dev/null || echo 100)"
[[ "${CLK_TCK}" =~ ^[1-9][0-9]*$ ]] || CLK_TCK=100

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

# Read key-value file (/proc/vmstat, /proc/perfnomad) into an associative array
read_kv_file() {
    local -n _arr=$1
    local src="$2"
    [ -f "$src" ] || return 0
    while read -r k v; do
        [ -n "$k" ] && _arr["$k"]="$v"
    done < "$src"
}

# Helpers: read PMI
get_pmi_count() {
    awk '/^[[:space:]]*PMI:/ {s=0; for(i=2;i<=NF;i++) s+=$i; print s; exit}' /proc/interrupts 2>/dev/null || echo 0
}

# Unit conversion & percentage helpers
pages_to_gb() { awk "BEGIN {printf \"%.2f\", (${1:-0} * 4096) / 1073741824}"; }
pages_to_mb() { awk "BEGIN {printf \"%.2f\", (${1:-0} * 4096) / 1048576}"; }
pages_to_bw() { awk "BEGIN {printf \"%.2f MB/s\", (${1:-0} * 4096) / (1048576 * ${WORKLOAD_RUNTIME:-1})}"; }
calc_pct() {
    awk -v n="${1:-0}" -v d="${2:-0}" 'BEGIN {if (d > 0) printf "%.2f%%", (n * 100.0) / d; else printf "0.00%%"}'
}
ticks_to_sec() {
    awk -v t="${1:-0}" -v hz="${CLK_TCK:-100}" 'BEGIN {printf "%.2f", t / hz}'
}

# Capture CPU ticks (utime + stime from /proc/<pid>/stat) for tiering/migration daemons
# Prints per line: <pid> <comm> <total_ticks>
capture_daemon_cpu() {
    local stat_file line comm pid rest utime stime
    local -a fields
    for stat_file in /proc/[0-9]*/stat; do
        [ -r "${stat_file}" ] || continue
        IFS= read -r line < "${stat_file}" 2>/dev/null || continue
        comm="${line#*(}"
        comm="${comm%)*}"
        case "${comm}" in
            kmigraterd*|kmigrated*|knuma_migrated*|kswapd*|ksamplingd|kcompactd*|khugepaged|pact|hybridtier|tier-prefetch*)
                pid="${line%% *}"
                rest="${line##*) }"
                read -ra fields <<< "${rest}"
                # After ') ': fields[0]=state ... fields[11]=utime(field 14), fields[12]=stime(field 15)
                utime="${fields[11]:-0}"
                stime="${fields[12]:-0}"
                echo "${pid} ${comm} $(( utime + stime ))"
                ;;
        esac
    done
}

# Read captured daemon CPU lines from stdin into associative arrays: pid->ticks and pid->comm
read_daemon_cpu() {
    local -n _ticks_arr=$1
    local -n _comm_arr=$2
    local pid comm ticks
    while read -r pid comm ticks; do
        [ -n "${pid}" ] || continue
        _ticks_arr["${pid}"]="${ticks:-0}"
        _comm_arr["${pid}"]="${comm}"
    done
}

# ------------------------------------------------------------------------------------------
# Lightweight 1s Background Time-Series & Uncore DRAM Sampler (CPU/Node from cpu_config.sh)
# ------------------------------------------------------------------------------------------
ensure_ts_mon_bin() {
    if [ -x "${TS_MON_BIN}" ] && { [ ! -f "${TS_MON_SRC}" ] || [ "${TS_MON_BIN}" -nt "${TS_MON_SRC}" ]; }; then
        return 0
    fi
    if [ -f "${TS_MON_SRC}" ] && command -v gcc >/dev/null 2>&1; then
        gcc -O2 -Wall -Wextra -o "${TS_MON_BIN}" "${TS_MON_SRC}" 2>/dev/null || true
    fi
    [ -x "${TS_MON_BIN}" ]
}

start_timeseries_sampler() {
    local csv_target="${1:-}"
    if [ -n "${csv_target}" ]; then
        mkdir -p "$(dirname "${csv_target}")" 2>/dev/null || true
    else
        csv_target="-"
    fi

    local pin_cmd=()
    if command -v numactl >/dev/null 2>&1 && [ -d "/sys/devices/system/node/node${TIMESERIES_MEMNODE}" ]; then
        pin_cmd=(numactl --physcpubind="${TIMESERIES_CPU}" --membind="${TIMESERIES_MEMNODE}")
    elif command -v taskset >/dev/null 2>&1; then
        pin_cmd=(taskset -c "${TIMESERIES_CPU}")
    fi

    local extra_args=()
    if [ "${ENABLE_AUTONUMA_PMU:-0}" -ne 0 ] && [ -n "${WORKLOAD_CPU_RANGE:-}" ]; then
        extra_args=(--core-cpus "${WORKLOAD_CPU_RANGE}")
    fi

    rm -f "${STATE_UNCORE}" 2>/dev/null || true
    if ensure_ts_mon_bin; then
        "${pin_cmd[@]}" "${TS_MON_BIN}" --interval "${TS_INTERVAL_SEC}" --summary "${STATE_UNCORE}" --csv "${csv_target}" "${extra_args[@]}" </dev/null >/dev/null 2>&1 &
        echo "$!" > "${STATE_TS_PID}"
    fi
}

stop_timeseries_sampler() {
    local ts_pid=""
    if [ -f "${STATE_TS_PID}" ]; then
        ts_pid=$(cat "${STATE_TS_PID}" 2>/dev/null || true)
        rm -f "${STATE_TS_PID}" 2>/dev/null || true
    fi
    if [ -n "${ts_pid}" ] && kill -0 "${ts_pid}" 2>/dev/null; then
        kill -TERM "${ts_pid}" 2>/dev/null || true
        for _ in $(seq 1 20); do
            kill -0 "${ts_pid}" 2>/dev/null || break
            sleep 0.05
        done
        kill -0 "${ts_pid}" 2>/dev/null && kill -KILL "${ts_pid}" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------------------
# 1. Start Telemetry Baseline
# ------------------------------------------------------------------------------------------
start_monitor() {
    if [ "$SETTLE_SLEEP" -gt 0 ]; then
        sleep "${SETTLE_SLEEP}"
    fi

    local pmi_before node1_before start_time ts_csv=""
    pmi_before=$(get_pmi_count)
    node1_before=$(get_node1_used_mb)
    start_time=$(date +%s)
    if [ "${ENABLE_TIMESERIES:-1}" -ne 0 ]; then
        ts_csv="${TS_OUT_FILE:-${PERF_STATE_DIR}/perf_monitor_${PERF_SESSION_ID}.timeseries.csv}"
    fi

    cat <<EOF > "${STATE_META}"
START_TIME=${start_time}
PMI_BEFORE=${pmi_before}
NODE1_BEFORE=${node1_before}
TS_CSV_FILE="${ts_csv}"
EOF

    [ -f /proc/vmstat ] && cp /proc/vmstat "${STATE_VMSTAT}" 2>/dev/null || true
    [ -f /proc/perfnomad ] && cp /proc/perfnomad "${STATE_PERFNOMAD}" 2>/dev/null || true
    capture_daemon_cpu > "${STATE_DAEMON_CPU}" 2>/dev/null || true
    start_timeseries_sampler "${ts_csv}"
}

# ------------------------------------------------------------------------------------------
# 2. Stop Telemetry, Compute Deltas, and Print Summary Reports
# ------------------------------------------------------------------------------------------
stop_monitor() {
    local cmd="$*"
    local end_time=$(date +%s)

    # Resolve state files with fallback to newest session file if exact match is missing
    if [ ! -f "${STATE_META}" ]; then
        local latest_meta
        latest_meta=$(ls -t "${PERF_STATE_DIR}"/perf_monitor_*.meta 2>/dev/null | head -n 1 || true)
        if [ -n "${latest_meta}" ] && [ -f "${latest_meta}" ]; then
            STATE_META="${latest_meta}"
            STATE_VMSTAT="${latest_meta%.meta}.vmstat"
            STATE_PERFNOMAD="${latest_meta%.meta}.perfnomad"
            STATE_DAEMON_CPU="${latest_meta%.meta}.daemon_cpu"
            STATE_TS_PID="${latest_meta%.meta}.ts_pid"
            STATE_UNCORE="${latest_meta%.meta}.uncore"
        fi
    fi

    # Stop background 1s time-series sampler immediately upon workload exit
    stop_timeseries_sampler

    local START_TIME=""
    local PMI_BEFORE=0
    local NODE1_BEFORE=0
    local TS_CSV_FILE=""

    if [ -f "${STATE_META}" ]; then
        # shellcheck disable=SC1090
        source "${STATE_META}"
    fi

    if [ -z "${START_TIME}" ]; then
        echo -e "\033[1;31m[ERROR] Unable to load baseline START_TIME from '${STATE_META}'!\033[0m" >&2
        WORKLOAD_RUNTIME=0
    else
        WORKLOAD_RUNTIME=$(( end_time - START_TIME ))
    fi
    [ "$WORKLOAD_RUNTIME" -le 0 ] && WORKLOAD_RUNTIME=1
    

    # Settling sleep after workload execution to allow any async worker threads to finish
    if [ "$SETTLE_SLEEP" -gt 0 ]; then
        sleep "${SETTLE_SLEEP}"
    fi

    # Read Memtis cgroup hotness before cleanup
    local memtis_hotness_file="/sys/fs/cgroup/memtis_workload/memory.hotness_stat"
    local memtis_hot=0 memtis_warm=0 memtis_cold=0
    if [ -r "${memtis_hotness_file}" ]; then
        read -r _ memtis_hot _ memtis_warm _ memtis_cold < "${memtis_hotness_file}" 2>/dev/null || true
        [[ "${memtis_hot}" =~ ^[0-9]+$ ]] || memtis_hot=0
        [[ "${memtis_warm}" =~ ^[0-9]+$ ]] || memtis_warm=0
        [[ "${memtis_cold}" =~ ^[0-9]+$ ]] || memtis_cold=0
    fi

    # Read baseline and final counters
    declare -A VMS_B PN_B VMS_A PN_A DCPU_B DCOMM_B DCPU_A DCOMM_A
    read_kv_file VMS_B "${STATE_VMSTAT}"
    read_kv_file PN_B "${STATE_PERFNOMAD}"
    read_kv_file VMS_A "/proc/vmstat"
    read_kv_file PN_A "/proc/perfnomad"
    [ -f "${STATE_DAEMON_CPU}" ] && read_daemon_cpu DCPU_B DCOMM_B < "${STATE_DAEMON_CPU}"
    read_daemon_cpu DCPU_A DCOMM_A < <(capture_daemon_cpu)
    local pmi_after=$(get_pmi_count)
    local node1_after=$(get_node1_used_mb)

    # Load uncore DRAM traffic (and optional AutoNUMA core PMU) totals written by tier_ts_mon on stop
    local UNCORE_IMC_CNT=0 UNCORE_UPI_CNT=0 UNCORE_ELAPSED_MS=0
    local NODE0_RD_BYTES=0 NODE0_WR_BYTES=0 NODE1_RD_BYTES=0 NODE1_WR_BYTES=0
    local CORE_PMU_ENABLED=0 CORE_PMU_CPUS="${WORKLOAD_CPU_RANGE:-1-24}" CORE_PMU_OPEN_FDS=0 CORE_PMU_RUN_PCT="0.00"
    local CORE_USER_INST=0 CORE_USER_CYCLES=0 CORE_USER_LLC_MISS=0 CORE_USER_LLC_REF=0
    local CORE_KERN_SWPF_HIT=0 CORE_KERN_SWPF_MISS=0 CORE_KERN_ALL_HWPF=0 CORE_KERN_FB_FULL=0
    if [ -f "${STATE_UNCORE}" ]; then
        # shellcheck disable=SC1090
        source "${STATE_UNCORE}" 2>/dev/null || true
    fi

    # Clean up session state files
    rm -f "${STATE_META}" "${STATE_VMSTAT}" "${STATE_PERFNOMAD}" "${STATE_DAEMON_CPU}" "${STATE_UNCORE}" 2>/dev/null || true

    vm_delta() {
        local a="${VMS_A[$1]:-0}" b="${VMS_B[$1]:-0}"
        [ "$a" -ge "$b" ] 2>/dev/null && echo $(( a - b )) || echo 0
    }

    pn_delta() {
        local a="${PN_A[$1]:-0}" b="${PN_B[$1]:-0}"
        [ "$a" -ge "$b" ] 2>/dev/null && echo $(( a - b )) || echo 0
    }

    # Aggregate Daemon CPU tick deltas by comm name
    declare -A DCPU_BY_COMM
    local total_mig_daemon_ticks=0
    local total_all_daemon_ticks=0
    local pid comm t_after t_before dt
    for pid in "${!DCPU_A[@]}"; do
        comm="${DCOMM_A[$pid]}"
        t_after="${DCPU_A[$pid]:-0}"
        # Only subtract baseline if the same PID existed with the same comm name
        if [ "${DCOMM_B[$pid]:-}" == "${comm}" ]; then
            t_before="${DCPU_B[$pid]:-0}"
        else
            t_before=0
        fi
        dt=$(( t_after >= t_before ? t_after - t_before : t_after ))
        DCPU_BY_COMM["${comm}"]=$(( ${DCPU_BY_COMM[${comm}]:-0} + dt ))
        total_all_daemon_ticks=$(( total_all_daemon_ticks + dt ))
        case "${comm}" in
            kmigraterd*|kmigrated*|knuma_migrated*|kswapd*|pact|hybridtier)
                total_mig_daemon_ticks=$(( total_mig_daemon_ticks + dt ))
                ;;
        esac
    done

    # Calculate VMSTAT Deltas
    local delta_pgf=$(vm_delta "pgfault")
    local delta_numa=$(vm_delta "numa_hint_faults")
    local delta_numa_local=$(vm_delta "numa_hint_faults_local")
    local delta_numa_remote=$(( delta_numa > delta_numa_local ? delta_numa - delta_numa_local : 0 ))
    local delta_numa_pages_mig=$(vm_delta "numa_pages_migrated")
    local delta_pgalloc=$(( $(vm_delta "pgalloc_normal") + $(vm_delta "pgalloc_dma32") ))
    local delta_numa_hit=$(vm_delta "numa_hit")
    local delta_numa_miss=$(vm_delta "numa_miss")
    local delta_allocstall=$(( $(vm_delta "allocstall_normal") + $(vm_delta "allocstall_movable") ))
    local delta_prom_cand=$(vm_delta "pgpromote_candidate")
    local delta_prom_cand_dem=$(vm_delta "pgpromote_candidate_demoted")
    local delta_prom_tried=$(vm_delta "pgpromote_tried")
    local delta_prom_anon=$(vm_delta "pgpromote_anon")
    local delta_prom_file=$(vm_delta "pgpromote_file")
    local delta_prom_page=$(( delta_prom_anon + delta_prom_file ))
    local delta_dem_page_anon=$(vm_delta "pgdemote_anon")
    local delta_dem_page_file=$(vm_delta "pgdemote_file")
    local delta_dem_kswapd=$(vm_delta "pgdemote_kswapd")
    local delta_dem_direct=$(vm_delta "pgdemote_direct")
    local delta_mig_succ=$(vm_delta "pgmigrate_success")
    local delta_mig_fail=$(vm_delta "pgmigrate_fail")
    local delta_mig_dst_full=$(vm_delta "pgmigrate_dst_node_full_fail")
    local delta_mig_isolate_fail=$(vm_delta "pgmigrate_numa_isolate_fail")
    local delta_mig_nomem_fail=$(vm_delta "pgmigrate_nomem_fail")
    local delta_mig_refcnt_fail=$(vm_delta "pgmigrate_refcount_fail")
    local delta_thp_mig_succ=$(vm_delta "thp_migration_success")
    local delta_thp_mig_fail=$(vm_delta "thp_migration_fail")
    local delta_thp_mig_split=$(vm_delta "thp_migration_split")
    local delta_mig_wait_cnt=$(vm_delta "mig_wait_count")
    local delta_mig_wait_us=$(vm_delta "mig_wait_us")
    local delta_mig_wait_huge_cnt=$(vm_delta "mig_wait_huge_count")
    local delta_mig_wait_huge_us=$(vm_delta "mig_wait_huge_us")
    local delta_mig_copy_ns=$(vm_delta "mig_copy_ns")

    # Memtis Deltas
    local delta_memtis_prom=$(vm_delta "htmm_nr_promoted")
    local delta_memtis_dem=$(vm_delta "htmm_nr_demoted")
    local delta_memtis_alloc_dram=$(vm_delta "htmm_alloc_dram")
    local delta_memtis_alloc_nvm=$(vm_delta "htmm_alloc_nvm")
    local delta_memtis_split_dram=$(vm_delta "htmm_missed_dramread")
    local delta_memtis_split_nvm=$(vm_delta "htmm_missed_nvmread")

    # Node 1 & PMI Deltas
    local delta_pmi=$(( pmi_after > PMI_BEFORE ? pmi_after - PMI_BEFORE : 0 ))
    local delta_node1=$(( node1_after > NODE1_BEFORE ? node1_after - NODE1_BEFORE : 0 ))

    local total_dem_pages=$(( delta_dem_kswapd + delta_dem_direct ))
    [ "$total_dem_pages" -eq 0 ] && total_dem_pages=$(( delta_dem_page_anon + delta_dem_page_file ))
    local dem_bw=$(pages_to_bw "$total_dem_pages")
    local alloc_gb=$(pages_to_gb "$delta_pgalloc")
    local alloc_bw=$(pages_to_bw "$delta_pgalloc")
    local hit_gb=$(pages_to_gb "$delta_numa_hit")
    local miss_gb=$(pages_to_gb "$delta_numa_miss")

    # Universal Overhead Percentages
    local mig_total=$(( delta_mig_succ + delta_mig_fail ))
    local mig_fail_pct=$(calc_pct "$delta_mig_fail" "$mig_total")
    local spillover_pct=$(calc_pct "$delta_numa_miss" "$(( delta_numa_hit + delta_numa_miss ))")
    local direct_dem_pct=$(calc_pct "$delta_dem_direct" "$total_dem_pages")
    local remote_hint_pct=$(calc_pct "$delta_numa_remote" "$delta_numa")
    local hint_mig_yield_pct=$(calc_pct "$delta_numa_pages_mig" "$delta_numa_remote")
    local thp_mig_total=$(( delta_thp_mig_succ + delta_thp_mig_fail + delta_thp_mig_split ))
    local thp_mig_fail_split_pct=$(calc_pct "$(( delta_thp_mig_fail + delta_thp_mig_split ))" "$thp_mig_total")

    # Print Standard VMSTAT Fault & Allocation Report
    echo ""
    echo "=========================================================="
    echo "          WORKLOAD VMSTAT FAULT & ALLOCATION REPORT       "
    echo "=========================================================="
    echo " Kernel Release                         : ${KERNEL_VER}"
    echo " Workload Execution Runtime             : ${WORKLOAD_RUNTIME} seconds"
    echo " Total Page Faults Delta (pgfault)      : ${delta_pgf}"
    echo " NUMA Hint Faults Delta (numa_hint)     : ${delta_numa}"
    echo " NUMA Remote Hint Faults (remote_hint)  : ${delta_numa_remote} (${remote_hint_pct} of hints, ${hint_mig_yield_pct} migrated)"
    echo " NUMA Pages Migrated (numa_pages_mig)   : ${delta_numa_pages_mig}"
    echo " PMI Interrupts Delta (interrupts)      : ${delta_pmi:-0}"
    echo "----------------------------------------------------------"
    echo " Total Allocated Pages (pgalloc)        : ${delta_pgalloc} (${alloc_gb} GB, ${alloc_bw})"
    echo " NUMA Local Alloc Hits (numa_hit)       : ${delta_numa_hit} (${hit_gb} GB)"
    echo " NUMA Remote Alloc Misses (numa_miss)   : ${delta_numa_miss} (${miss_gb} GB, ${spillover_pct} spillover)"
    echo " Direct Allocation Stalls (allocstall)  : ${delta_allocstall}"
    echo " Direct Demotion Stall Rate             : ${direct_dem_pct} (${delta_dem_direct} direct / ${total_dem_pages} total)"
    echo " Total Migrated Pages Delta (pgmigrate) : ${delta_mig_succ}"
    echo " Migration Failures (pgmigrate_fail)    : ${delta_mig_fail} (${mig_fail_pct} fail rate)"
    echo " THP Migration (succ / fail / split)    : ${delta_thp_mig_succ} / ${delta_thp_mig_fail} / ${delta_thp_mig_split} (${thp_mig_fail_split_pct} fail+split)"
    echo "=========================================================="

    # Print Unified Migration Daemon CPU & Efficiency Report
    local wall_ticks=$(( WORKLOAD_RUNTIME * CLK_TCK ))
    local mig_daemon_sec=$(ticks_to_sec "$total_mig_daemon_ticks")
    local all_daemon_sec=$(ticks_to_sec "$total_all_daemon_ticks")
    local mig_daemon_pct=$(calc_pct "$total_mig_daemon_ticks" "$wall_ticks")
    local all_daemon_pct=$(calc_pct "$total_all_daemon_ticks" "$wall_ticks")
    local eff_migrated_pages="${delta_mig_succ}"
    if [ "${eff_migrated_pages}" -eq 0 ] && [ $(( delta_memtis_prom + delta_memtis_dem )) -gt 0 ]; then
        eff_migrated_pages=$(( delta_memtis_prom + delta_memtis_dem ))
    fi

    echo ""
    echo "=========================================================="
    echo "          MIGRATION DAEMON CPU & EFFICIENCY REPORT        "
    echo "=========================================================="
    local any_daemon_active=0
    if [ "${#DCPU_BY_COMM[@]}" -gt 0 ]; then
        while IFS= read -r comm; do
            [ -n "${comm}" ] || continue
            local d_ticks="${DCPU_BY_COMM[$comm]:-0}"
            if [ "${d_ticks}" -gt 0 ]; then
                any_daemon_active=1
                printf " %-38s : %s s (%s CPU)\n" "Daemon CPU (${comm})" "$(ticks_to_sec "$d_ticks")" "$(calc_pct "$d_ticks" "$wall_ticks")"
            fi
        done < <(printf '%s\n' "${!DCPU_BY_COMM[@]}" | sort)
    fi
    if [ "${any_daemon_active}" -eq 0 ]; then
        echo " Active Migration Daemons               : none (0.00 s)"
    fi
    echo "----------------------------------------------------------"
    echo " Total Migration Daemon CPU             : ${mig_daemon_sec} s (${mig_daemon_pct} CPU)"
    echo " Total All Tiering Daemon CPU           : ${all_daemon_sec} s (${all_daemon_pct} CPU)"
    local us_per_page active_mig_bw
    us_per_page=$(awk -v t="${total_mig_daemon_ticks}" -v hz="${CLK_TCK}" -v p="${eff_migrated_pages}" 'BEGIN {printf "%.2f us/page", (p > 0 ? (t * 1000000.0) / (hz * p) : 0.0)}')
    active_mig_bw=$(awk -v t="${total_mig_daemon_ticks}" -v hz="${CLK_TCK}" -v p="${eff_migrated_pages}" 'BEGIN {printf "%.2f MB/s", (t > 0 ? (p * 4096.0 * hz) / (1048576.0 * t) : 0.0)}')
    echo " Daemon CPU Cost per Migrated Page      : ${us_per_page} (${eff_migrated_pages} pages)"
    echo " Active Daemon Migration Bandwidth      : ${active_mig_bw}"
    local wl_cores="${WORKLOAD_CORES:-1}"
    [ "${wl_cores}" -le 0 ] 2>/dev/null && wl_cores=1
    local wl_thread_us=$(( WORKLOAD_RUNTIME * wl_cores * 1000000 ))
    local total_wait_us=$(( delta_mig_wait_us + delta_mig_wait_huge_us ))
    print_wait_line() {
        awk -v lbl="$1" -v c="$2" -v u="$3" -v w="$4" -v n="$5" \
            'BEGIN {printf " %-38s : %d waits, %.2f ms (%.2f%% of %d-core time, avg %.2f us/wait)\n", lbl, c, u/1000.0, (u*100.0)/w, n, (c > 0 ? u/c : 0.0)}'
    }
    echo "----------------------------------------------------------"
    print_wait_line "Migration Wait 4KB (mig_wait)" "${delta_mig_wait_cnt}" "${delta_mig_wait_us}" "${wl_thread_us}" "${wl_cores}"
    print_wait_line "Migration Wait Huge (mig_wait_huge)" "${delta_mig_wait_huge_cnt}" "${delta_mig_wait_huge_us}" "${wl_thread_us}" "${wl_cores}"
    awk -v u="${total_wait_us}" -v w="${wl_thread_us}" -v n="${wl_cores}" \
        'BEGIN {printf " Total Migration Stall Time             : %.2f ms (%.2f%% of %d-core time, %.2f ms/thread)\n", u/1000.0, (u*100.0)/w, n, u/(1000.0*n)}'
    awk -v n="${delta_mig_copy_ns}" -v w="${WORKLOAD_RUNTIME}" -v p="${eff_migrated_pages}" \
        'BEGIN {printf " Batch Migration Time (mig_copy_ns)     : %.2f ms (%.2f%% of 1 core, avg %.2f us/page)\n", n/1e6, (n*100.0)/(w*1e9), (p > 0 ? n/(1000.0*p) : 0.0)}'
    if [ -n "${TS_CSV_FILE}" ] && [ -s "${TS_CSV_FILE}" ]; then
        local ts_rows=$(( $(wc -l < "${TS_CSV_FILE}") - 1 ))
        [ "${ts_rows}" -lt 0 ] && ts_rows=0
        echo " Time-Series CSV (1s, Core ${TIMESERIES_CPU}/Node ${TIMESERIES_MEMNODE}) : ${TS_CSV_FILE} (${ts_rows} samples)"
    fi
    echo "=========================================================="

    # Print Uncore DRAM Traffic Report (Node 0 IMC vs. Node 1 UPI)
    echo ""
    echo "=========================================================="
    echo "       UNCORE DRAM TRAFFIC REPORT (NODE 0 vs. NODE 1)     "
    echo "=========================================================="
    awk -v imc="${UNCORE_IMC_CNT:-0}" -v upi="${UNCORE_UPI_CNT:-0}" \
        -v ems="${UNCORE_ELAPSED_MS:-0}" -v rt="${WORKLOAD_RUNTIME:-1}" \
        -v n0r="${NODE0_RD_BYTES:-0}" -v n0w="${NODE0_WR_BYTES:-0}" \
        -v n1r="${NODE1_RD_BYTES:-0}" -v n1w="${NODE1_WR_BYTES:-0}" '
    function pct(n, d) { return (d > 0) ? (n * 100.0 / d) : 0.0 }
    BEGIN {
        sec = (ems > 0) ? (ems / 1000.0) : (rt + 0.0);
        if (sec <= 0) sec = 1.0;
        gb = 1073741824.0; mb_s = 1048576.0 * sec;
        tot_r = n0r + n1r; tot_w = n0w + n1w;
        tot_0 = n0r + n0w; tot_1 = n1r + n1w; tot_a = tot_0 + tot_1;
        printf " Uncore PMUs Active (IMC / UPI)         : %d IMC / %d UPI (%.2f s)\n", imc, upi, sec;
        printf " Node 0 (Fast Tier) DRAM Read           : %.2f GB (%.2f MB/s)\n", n0r / gb, n0r / mb_s;
        printf " Node 0 (Fast Tier) DRAM Write          : %.2f GB (%.2f MB/s)\n", n0w / gb, n0w / mb_s;
        printf " Node 1 (Slow Tier) DRAM Read (UPI Rx)  : %.2f GB (%.2f MB/s)\n", n1r / gb, n1r / mb_s;
        printf " Node 1 (Slow Tier) DRAM Write (UPI Tx) : %.2f GB (%.2f MB/s)\n", n1w / gb, n1w / mb_s;
        printf "----------------------------------------------------------\n";
        printf " DRAM Read Traffic Share (Node 0 / 1)   : %.2f%% / %.2f%% (%.2f GB total)\n", pct(n0r, tot_r), pct(n1r, tot_r), tot_r / gb;
        printf " DRAM Write Traffic Share (Node 0 / 1)  : %.2f%% / %.2f%% (%.2f GB total)\n", pct(n0w, tot_w), pct(n1w, tot_w), tot_w / gb;
        printf " DRAM Total Traffic Share (Node 0 / 1)  : %.2f%% / %.2f%% (%.2f GB total)\n", pct(tot_0, tot_a), pct(tot_1, tot_a), tot_a / gb;
    }'
    echo "=========================================================="

    # AutoNUMA-only Core PMU Report (0% mux: HW/SW Prefetch Interplay + Cache Pollution)
    if [ "${CORE_PMU_ENABLED:-0}" -ne 0 ] || [ "${ENABLE_AUTONUMA_PMU:-0}" -ne 0 ]; then
        echo ""
        echo "=========================================================="
        echo "   AUTONUMA CORE PMU (HW/SW PREFETCH & CACHE POLLUTION)   "
        echo "=========================================================="
        awk -v cpus="${CORE_PMU_CPUS}" -v fds="${CORE_PMU_OPEN_FDS:-0}" -v rpct="${CORE_PMU_RUN_PCT:-0.00}" \
            -v inst="${CORE_USER_INST:-0}" -v cyc="${CORE_USER_CYCLES:-0}" \
            -v lmiss="${CORE_USER_LLC_MISS:-0}" -v lref="${CORE_USER_LLC_REF:-0}" \
            -v shit="${CORE_KERN_SWPF_HIT:-0}" -v smiss="${CORE_KERN_SWPF_MISS:-0}" \
            -v hwpf="${CORE_KERN_ALL_HWPF:-0}" -v fbf="${CORE_KERN_FB_FULL:-0}" \
            -v mig="${eff_migrated_pages:-0}" '
        function pct(n, d) { return (d > 0) ? (n * 100.0 / d) : 0.0 }
        BEGIN {
            ipc = (cyc > 0) ? (inst / cyc) : 0.0;
            mpki = (inst > 0) ? (lmiss * 1000.0 / inst) : 0.0;
            sw_tot = shit + smiss;
            fbf_pg = (mig > 0) ? (fbf / mig) : 0.0;
            printf " Monitored Workload Cores (PMU Status)  : %s (%d fds, %.2f%% running)\n", cpus, fds, rpct + 0.0;
            printf "----------------------------------------------------------\n";
            printf " User Instructions / Cycles (IPC)       : %.0f / %.0f (IPC %.2f)\n", inst, cyc, ipc;
            printf " User LLC Misses / Refs (Miss Rate)     : %.0f / %.0f (%.2f%%)\n", lmiss, lref, pct(lmiss, lref);
            printf " User LLC MPKI (Cache Pollution)        : %.3f misses / 1K inst\n", mpki;
            printf "----------------------------------------------------------\n";
            printf " Kernel SWPF Hit / Miss (Redundancy)    : %.0f / %.0f (%.2f%% hit)\n", shit, smiss, pct(shit, sw_tot);
            printf " Kernel HWPF Requests (l2_rqsts.hwpf)   : %.0f (SWPF/HWPF %.2f%%)\n", hwpf, pct(sw_tot, hwpf);
            printf " Kernel L1D Fill-Buffer Full (fb_full)  : %.0f cycles (%.2f cyc/mig_pg)\n", fbf, fbf_pg;
        }'
        echo "=========================================================="
    fi

    # Shared TPP/Nomad vmstat breakdown printer
    print_tpp_extra_stats() {
        local dst_full_den=$(( delta_prom_tried > 0 ? delta_prom_tried : mig_total ))
        echo " Ping-Pong / Re-promotion Rate            : $(calc_pct "$delta_prom_cand_dem" "$delta_prom_cand") (${delta_prom_cand_dem} / ${delta_prom_cand} candidates)"
        echo " Migration Failure Breakdown              : dst_full=${delta_mig_dst_full} ($(calc_pct "$delta_mig_dst_full" "$dst_full_den")), isolate=${delta_mig_isolate_fail}, nomem=${delta_mig_nomem_fail}, refcnt=${delta_mig_refcnt_fail}"
    }

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

        local prom_mb prom_bw abort_rate tx_fail_pct retreat_pct
        prom_mb=$(pages_to_mb "$delta_success")
        prom_bw=$(pages_to_bw "$delta_success")
        abort_rate=$(calc_pct "$delta_retry" "$delta_total")
        tx_fail_pct=$(calc_pct "$delta_tx_fail" "$(( delta_tx_succ + delta_tx_fail ))")
        retreat_pct=$(calc_pct "$delta_retreat" "$delta_try")

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
        echo " Transactional Promotions Failed          : ${delta_tx_fail} (${tx_fail_pct} tx fail rate)"
        echo " Retreated Inactive Pages                 : ${delta_retreat} (${retreat_pct} of try_nr)"
        echo " Average Promotion Bandwidth              : ${prom_bw}"
        echo " Average Demotion Bandwidth               : ${dem_bw}"
        echo " Overall Application Abortion Rate        : ${abort_rate}"
        print_tpp_extra_stats
        echo " Slow Tier Node 1 Used Memory             : ${node1_after} MB (Growth: +${delta_node1} MB)"
        echo "=========================================================================================="

    # Memtis (HTMM) Performance Summary
    elif [ "$delta_memtis_prom" -gt 0 ] || [ "$delta_memtis_dem" -gt 0 ] || [[ "${KERNEL_VER,,}" =~ memtis|htmm ]]; then
        local prom_mb prom_bw dem_mb dem_bw_m
        prom_mb=$(pages_to_mb "$delta_memtis_prom")
        prom_bw=$(pages_to_bw "$delta_memtis_prom")
        dem_mb=$(pages_to_mb "$delta_memtis_dem")
        dem_bw_m=$(pages_to_bw "$delta_memtis_dem")

        local memtis_total_alloc=$(( delta_memtis_alloc_dram + delta_memtis_alloc_nvm ))
        local memtis_spill_pct=$(calc_pct "$delta_memtis_alloc_nvm" "$memtis_total_alloc")
        local memtis_prom_share_pct=$(calc_pct "$delta_memtis_prom" "$(( delta_memtis_prom + delta_memtis_dem ))")
        local h_tot=$(( memtis_hot + memtis_warm + memtis_cold ))

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
        echo " Promotion Share of Migrations       : ${memtis_prom_share_pct}"
        echo " Direct DRAM Allocations             : ${delta_memtis_alloc_dram}"
        echo " Direct NVM / Slow Allocations       : ${delta_memtis_alloc_nvm}"
        echo " Slow-Tier Allocation Spillover Rate : ${memtis_spill_pct} (${delta_memtis_alloc_nvm} / ${memtis_total_alloc})"
        echo " Deferred THP Splits (DRAM / NVM)    : ${delta_memtis_split_dram} / ${delta_memtis_split_nvm}"
        echo " Cgroup Hotness (hot / warm / cold)  : ${memtis_hot} ($(calc_pct "$memtis_hot" "$h_tot")) / ${memtis_warm} ($(calc_pct "$memtis_warm" "$h_tot")) / ${memtis_cold} ($(calc_pct "$memtis_cold" "$h_tot"))"
        echo " Average Promotion Bandwidth         : ${prom_bw}"
        echo " Average Demotion Bandwidth          : ${dem_bw_m}"
        echo " Slow Tier Node 1 Used Memory        : ${node1_after} MB (Growth: +${delta_node1} MB)"
        echo "=========================================================================================="

    # Tiered Migration Performance Summary (TPP, Colloid-TPP, AutoNUMA, PACT, HybridTier)
    else
        local prom_pages=$(( delta_prom_page > 0 ? delta_prom_page : delta_mig_succ ))
        local prom_mb prom_bw prom_succ_pct prom_drop_pct
        prom_mb=$(pages_to_mb "$prom_pages")
        prom_bw=$(pages_to_bw "$prom_pages")
        prom_succ_pct=$(calc_pct "$delta_prom_page" "$delta_prom_tried")
        prom_drop_pct=$(calc_pct "$(( delta_prom_cand > delta_prom_page ? delta_prom_cand - delta_prom_page : 0 ))" "$delta_prom_cand")

        echo ""
        echo "=========================================================================================="
        echo "                 TIERED MEMORY MIGRATION & BANDWIDTH SUMMARY                              "
        echo "=========================================================================================="
        echo " Executed Command          : ${cmd}"
        echo " Application Runtime       : ${WORKLOAD_RUNTIME} seconds"
        echo " Timestamp                 : $(date +%H:%M:%S)"
        echo "------------------------------------------------------------------------------------------"
        echo " Promotion Candidates (pgpromote_cand)    : ${delta_prom_cand}"
        echo " Promotion Tried (pgpromote_tried)        : ${delta_prom_tried}"
        echo " Promoted Memory Volume                   : ${prom_mb} MB (${prom_pages} pages)"
        echo " Promotion Success Rate (prom / tried)    : ${prom_succ_pct} (Drop vs cand: ${prom_drop_pct})"
        print_tpp_extra_stats
        echo " Demoted Memory Volume                    : $(pages_to_mb "$total_dem_pages") MB (${total_dem_pages} pages)"
        echo " Demoted Pages (anon / file)              : ${delta_dem_page_anon} anon / ${delta_dem_page_file} file"
        echo " Demoted By (kswapd / direct)             : ${delta_dem_kswapd} kswapd / ${delta_dem_direct} direct (${direct_dem_pct} direct)"
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
        stop_timeseries_sampler
        rm -f "${STATE_META}" "${STATE_VMSTAT}" "${STATE_PERFNOMAD}" "${STATE_DAEMON_CPU}" "${STATE_TS_PID}" "${STATE_UNCORE}" 2>/dev/null || true
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
