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

# Function to dynamically calculate Node 1 (slow memory) used memory in MB
get_node1_used_mb() {
    if [ -f /sys/devices/system/node/node1/meminfo ]; then
        local used_kb=$(grep -i "MemUsed:" /sys/devices/system/node/node1/meminfo 2>/dev/null | awk '{print $4}')
        if [ -n "$used_kb" ]; then
            echo $(( used_kb / 1024 ))
            return
        fi
    fi
    local n1_size=$(numactl -H 2>/dev/null | grep "node 1 size" | awk '{print $4}')
    local n1_free=$(numactl -H 2>/dev/null | grep "node 1 free" | awk '{print $4}')
    if [ -n "$n1_size" ] && [ -n "$n1_free" ]; then
        echo $(( n1_size - n1_free ))
    else
        echo 0
    fi
}

SETTLE_SLEEP="${SETTLE_SLEEP:-5}"

# 1. Settling sleep before capturing baseline counters
if [ "$SETTLE_SLEEP" -gt 0 ]; then
    sleep "${SETTLE_SLEEP}"
fi

# 2. Read baseline VMSTAT counters BEFORE workload execution
PGF_BEFORE=$(grep -w "pgfault" /proc/vmstat 2>/dev/null | awk '{print $2}')
NUMA_BEFORE=$(grep -w "numa_hint_faults" /proc/vmstat 2>/dev/null | awk '{print $2}')
NUMA_PAGES_MIG_BEFORE=$(grep -w "numa_pages_migrated" /proc/vmstat 2>/dev/null | awk '{print $2}')
PGALLOC_NORM_BEFORE=$(grep -w "pgalloc_normal" /proc/vmstat 2>/dev/null | awk '{print $2}')
PGALLOC_DMA32_BEFORE=$(grep -w "pgalloc_dma32" /proc/vmstat 2>/dev/null | awk '{print $2}')
NUMA_HIT_BEFORE=$(grep -w "numa_hit" /proc/vmstat 2>/dev/null | awk '{print $2}')
NUMA_MISS_BEFORE=$(grep -w "numa_miss" /proc/vmstat 2>/dev/null | awk '{print $2}')
NUMA_FOREIGN_BEFORE=$(grep -w "numa_foreign" /proc/vmstat 2>/dev/null | awk '{print $2}')
ALLOCSTALL_BEFORE=$(grep -w "allocstall_normal" /proc/vmstat 2>/dev/null | awk '{print $2}')
PROM_CAND_BEFORE=$(grep -w "pgpromote_candidate" /proc/vmstat 2>/dev/null | awk '{print $2}')
PROM_TRIED_BEFORE=$(grep -w "pgpromote_tried" /proc/vmstat 2>/dev/null | awk '{print $2}')
PROM_PAGE_BEFORE=$(grep -w "pgpromote_anon" /proc/vmstat 2>/dev/null | awk '{print $2}')
DEM_PAGE_ANON_BEFORE=$(grep -w "pgdemote_anon" /proc/vmstat 2>/dev/null | awk '{print $2}')
DEM_PAGE_FILE_BEFORE=$(grep -w "pgdemote_file" /proc/vmstat 2>/dev/null | awk '{print $2}')
DEM_KSWAPD_BEFORE=$(grep -w "pgdemote_kswapd" /proc/vmstat 2>/dev/null | awk '{print $2}')
DEM_DIRECT_BEFORE=$(grep -w "pgdemote_direct" /proc/vmstat 2>/dev/null | awk '{print $2}')
MIG_SUCC_BEFORE=$(grep -w "pgmigrate_success" /proc/vmstat 2>/dev/null | awk '{print $2}')
MIG_FAIL_BEFORE=$(grep -w "pgmigrate_fail" /proc/vmstat 2>/dev/null | awk '{print $2}')
MIG_DST_FULL_BEFORE=$(grep -w "pgmigrate_fail_dst_node_full" /proc/vmstat 2>/dev/null | awk '{print $2}')
PMI_BEFORE=$(cat /proc/interrupts 2>/dev/null | grep PMI | awk '{s=0; for(i=2;i<=NF-2;i++) s+=$i; print s}')

PGF_BEFORE="${PGF_BEFORE:-0}"
NUMA_BEFORE="${NUMA_BEFORE:-0}"
NUMA_PAGES_MIG_BEFORE="${NUMA_PAGES_MIG_BEFORE:-0}"
PGALLOC_NORM_BEFORE="${PGALLOC_NORM_BEFORE:-0}"
PGALLOC_DMA32_BEFORE="${PGALLOC_DMA32_BEFORE:-0}"
NUMA_HIT_BEFORE="${NUMA_HIT_BEFORE:-0}"
NUMA_MISS_BEFORE="${NUMA_MISS_BEFORE:-0}"
NUMA_FOREIGN_BEFORE="${NUMA_FOREIGN_BEFORE:-0}"
ALLOCSTALL_BEFORE="${ALLOCSTALL_BEFORE:-0}"
PROM_CAND_BEFORE="${PROM_CAND_BEFORE:-0}"
PROM_TRIED_BEFORE="${PROM_TRIED_BEFORE:-0}"
PROM_PAGE_BEFORE="${PROM_PAGE_BEFORE:-0}"
DEM_PAGE_ANON_BEFORE="${DEM_PAGE_ANON_BEFORE:-0}"
DEM_PAGE_FILE_BEFORE="${DEM_PAGE_FILE_BEFORE:-0}"
DEM_KSWAPD_BEFORE="${DEM_KSWAPD_BEFORE:-0}"
DEM_DIRECT_BEFORE="${DEM_DIRECT_BEFORE:-0}"
MIG_SUCC_BEFORE="${MIG_SUCC_BEFORE:-0}"
MIG_FAIL_BEFORE="${MIG_FAIL_BEFORE:-0}"
MIG_DST_FULL_BEFORE="${MIG_DST_FULL_BEFORE:-0}"
PMI_BEFORE="${PMI_BEFORE:-0}"

# Read baseline PERFNOMAD counters (Nomad Kernel)
if [ -f /proc/perfnomad ]; then
    SUCCESS_BEFORE=$(grep "success_nr" /proc/perfnomad | head -n 1 | awk '{print $2}')
    RETRY_BEFORE=$(grep "retry_nr" /proc/perfnomad | head -n 1 | awk '{print $2}')
    TRY_BEFORE=$(grep "try_to_promote_nr" /proc/perfnomad | head -n 1 | awk '{print $2}')
else
    SUCCESS_BEFORE=0
    RETRY_BEFORE=0
    TRY_BEFORE=0
fi

NODE1_BEFORE=$(get_node1_used_mb)

# 3. Execute the workload command with GNU time to capture runtime & Peak RSS
START_TIME=$(date +%s)
/usr/bin/time -v "$@"
STATUS=$?
END_TIME=$(date +%s)
WORKLOAD_RUNTIME=$((END_TIME - START_TIME))
[ $WORKLOAD_RUNTIME -le 0 ] && WORKLOAD_RUNTIME=1

# 4. Settle sleep after workload execution to allow any async worker threads to finish
if [ "$SETTLE_SLEEP" -gt 0 ]; then
    sleep "${SETTLE_SLEEP}"
fi

# 5. Read final VMSTAT counters AFTER execution
PGF_AFTER=$(grep -w "pgfault" /proc/vmstat 2>/dev/null | awk '{print $2}')
NUMA_AFTER=$(grep -w "numa_hint_faults" /proc/vmstat 2>/dev/null | awk '{print $2}')
NUMA_PAGES_MIG_AFTER=$(grep -w "numa_pages_migrated" /proc/vmstat 2>/dev/null | awk '{print $2}')
PGALLOC_NORM_AFTER=$(grep -w "pgalloc_normal" /proc/vmstat 2>/dev/null | awk '{print $2}')
PGALLOC_DMA32_AFTER=$(grep -w "pgalloc_dma32" /proc/vmstat 2>/dev/null | awk '{print $2}')
NUMA_HIT_AFTER=$(grep -w "numa_hit" /proc/vmstat 2>/dev/null | awk '{print $2}')
NUMA_MISS_AFTER=$(grep -w "numa_miss" /proc/vmstat 2>/dev/null | awk '{print $2}')
NUMA_FOREIGN_AFTER=$(grep -w "numa_foreign" /proc/vmstat 2>/dev/null | awk '{print $2}')
ALLOCSTALL_AFTER=$(grep -w "allocstall_normal" /proc/vmstat 2>/dev/null | awk '{print $2}')
PROM_CAND_AFTER=$(grep -w "pgpromote_candidate" /proc/vmstat 2>/dev/null | awk '{print $2}')
PROM_TRIED_AFTER=$(grep -w "pgpromote_tried" /proc/vmstat 2>/dev/null | awk '{print $2}')
PROM_PAGE_AFTER=$(grep -w "pgpromote_anon" /proc/vmstat 2>/dev/null | awk '{print $2}')
DEM_PAGE_ANON_AFTER=$(grep -w "pgdemote_anon" /proc/vmstat 2>/dev/null | awk '{print $2}')
DEM_PAGE_FILE_AFTER=$(grep -w "pgdemote_file" /proc/vmstat 2>/dev/null | awk '{print $2}')
DEM_KSWAPD_AFTER=$(grep -w "pgdemote_kswapd" /proc/vmstat 2>/dev/null | awk '{print $2}')
DEM_DIRECT_AFTER=$(grep -w "pgdemote_direct" /proc/vmstat 2>/dev/null | awk '{print $2}')
MIG_SUCC_AFTER=$(grep -w "pgmigrate_success" /proc/vmstat 2>/dev/null | awk '{print $2}')
MIG_FAIL_AFTER=$(grep -w "pgmigrate_fail" /proc/vmstat 2>/dev/null | awk '{print $2}')
MIG_DST_FULL_AFTER=$(grep -w "pgmigrate_fail_dst_node_full" /proc/vmstat 2>/dev/null | awk '{print $2}')
PMI_AFTER=$(cat /proc/interrupts 2>/dev/null | grep PMI | awk '{s=0; for(i=2;i<=NF-2;i++) s+=$i; print s}')

PGF_AFTER="${PGF_AFTER:-0}"
NUMA_AFTER="${NUMA_AFTER:-0}"
NUMA_PAGES_MIG_AFTER="${NUMA_PAGES_MIG_AFTER:-0}"
PGALLOC_NORM_AFTER="${PGALLOC_NORM_AFTER:-0}"
PGALLOC_DMA32_AFTER="${PGALLOC_DMA32_AFTER:-0}"
NUMA_HIT_AFTER="${NUMA_HIT_AFTER:-0}"
NUMA_MISS_AFTER="${NUMA_MISS_AFTER:-0}"
NUMA_FOREIGN_AFTER="${NUMA_FOREIGN_AFTER:-0}"
ALLOCSTALL_AFTER="${ALLOCSTALL_AFTER:-0}"
PROM_CAND_AFTER="${PROM_CAND_AFTER:-0}"
PROM_TRIED_AFTER="${PROM_TRIED_AFTER:-0}"
PROM_PAGE_AFTER="${PROM_PAGE_AFTER:-0}"
DEM_PAGE_ANON_AFTER="${DEM_PAGE_ANON_AFTER:-0}"
DEM_PAGE_FILE_AFTER="${DEM_PAGE_FILE_AFTER:-0}"
DEM_KSWAPD_AFTER="${DEM_KSWAPD_AFTER:-0}"
DEM_DIRECT_AFTER="${DEM_DIRECT_AFTER:-0}"
MIG_SUCC_AFTER="${MIG_SUCC_AFTER:-0}"
MIG_FAIL_AFTER="${MIG_FAIL_AFTER:-0}"
MIG_DST_FULL_AFTER="${MIG_DST_FULL_AFTER:-0}"
PMI_AFTER="${PMI_AFTER:-0}"

# Read final PERFNOMAD counters
if [ -f /proc/perfnomad ]; then
    SUCCESS_AFTER=$(grep "success_nr" /proc/perfnomad | head -n 1 | awk '{print $2}')
    RETRY_AFTER=$(grep "retry_nr" /proc/perfnomad | head -n 1 | awk '{print $2}')
    TRY_AFTER=$(grep "try_to_promote_nr" /proc/perfnomad | head -n 1 | awk '{print $2}')
else
    SUCCESS_AFTER=0
    RETRY_AFTER=0
    TRY_AFTER=0
fi

NODE1_AFTER=$(get_node1_used_mb)

# 6. Calculate VMSTAT Deltas
DELTA_PGF=$((PGF_AFTER - PGF_BEFORE))
DELTA_NUMA=$((NUMA_AFTER - NUMA_BEFORE))
DELTA_NUMA_PAGES_MIG=$((NUMA_PAGES_MIG_AFTER - NUMA_PAGES_MIG_BEFORE))
DELTA_PGALLOC=$(( (PGALLOC_NORM_AFTER - PGALLOC_NORM_BEFORE) + (PGALLOC_DMA32_AFTER - PGALLOC_DMA32_BEFORE) ))
DELTA_NUMA_HIT=$((NUMA_HIT_AFTER - NUMA_HIT_BEFORE))
DELTA_NUMA_MISS=$((NUMA_MISS_AFTER - NUMA_MISS_BEFORE))
DELTA_NUMA_FOREIGN=$((NUMA_FOREIGN_AFTER - NUMA_FOREIGN_BEFORE))
DELTA_ALLOCSTALL=$((ALLOCSTALL_AFTER - ALLOCSTALL_BEFORE))
DELTA_PROM_CAND=$((PROM_CAND_AFTER - PROM_CAND_BEFORE))
DELTA_PROM_TRIED=$((PROM_TRIED_AFTER - PROM_TRIED_BEFORE))
DELTA_PROM_PAGE=$((PROM_PAGE_AFTER - PROM_PAGE_BEFORE))
DELTA_DEM_PAGE_ANON=$((DEM_PAGE_ANON_AFTER - DEM_PAGE_ANON_BEFORE))
DELTA_DEM_PAGE_FILE=$((DEM_PAGE_FILE_AFTER - DEM_PAGE_FILE_BEFORE))
DELTA_DEM_KSWAPD=$((DEM_KSWAPD_AFTER - DEM_KSWAPD_BEFORE))
DELTA_DEM_DIRECT=$((DEM_DIRECT_AFTER - DEM_DIRECT_BEFORE))
DELTA_MIG_SUCC=$((MIG_SUCC_AFTER - MIG_SUCC_BEFORE))
DELTA_MIG_FAIL=$((MIG_FAIL_AFTER - MIG_FAIL_BEFORE))
DELTA_MIG_DST_FULL=$((MIG_DST_FULL_AFTER - MIG_DST_FULL_BEFORE))
DELTA_PMI=$((PMI_AFTER - PMI_BEFORE))

[ $DELTA_PGF -lt 0 ] && DELTA_PGF=0
[ $DELTA_NUMA -lt 0 ] && DELTA_NUMA=0
[ $DELTA_NUMA_PAGES_MIG -lt 0 ] && DELTA_NUMA_PAGES_MIG=0
[ $DELTA_PGALLOC -lt 0 ] && DELTA_PGALLOC=0
[ $DELTA_NUMA_HIT -lt 0 ] && DELTA_NUMA_HIT=0
[ $DELTA_NUMA_MISS -lt 0 ] && DELTA_NUMA_MISS=0
[ $DELTA_NUMA_FOREIGN -lt 0 ] && DELTA_NUMA_FOREIGN=0
[ $DELTA_ALLOCSTALL -lt 0 ] && DELTA_ALLOCSTALL=0
[ $DELTA_PROM_CAND -lt 0 ] && DELTA_PROM_CAND=0
[ $DELTA_PROM_TRIED -lt 0 ] && DELTA_PROM_TRIED=0
[ $DELTA_PROM_PAGE -lt 0 ] && DELTA_PROM_PAGE=0
[ $DELTA_DEM_PAGE_ANON -lt 0 ] && DELTA_DEM_PAGE_ANON=0
[ $DELTA_DEM_PAGE_FILE -lt 0 ] && DELTA_DEM_PAGE_FILE=0
[ $DELTA_DEM_KSWAPD -lt 0 ] && DELTA_DEM_KSWAPD=0
[ $DELTA_DEM_DIRECT -lt 0 ] && DELTA_DEM_DIRECT=0
[ $DELTA_MIG_SUCC -lt 0 ] && DELTA_MIG_SUCC=0
[ $DELTA_MIG_FAIL -lt 0 ] && DELTA_MIG_FAIL=0
[ $DELTA_MIG_DST_FULL -lt 0 ] && DELTA_MIG_DST_FULL=0
[ $DELTA_PMI -lt 0 ] && DELTA_PMI=0

# Node 1 Delta & Demotion Bandwidth
DELTA_NODE1=$((NODE1_AFTER - NODE1_BEFORE))
[ $DELTA_NODE1 -lt 0 ] && DELTA_NODE1=0
DEM_BW=$(awk "BEGIN {printf \"%.2f MB/s\", $DELTA_NODE1 / $WORKLOAD_RUNTIME}")

# Calculate Allocation Volumes & Bandwidth
ALLOC_GB=$(awk "BEGIN {printf \"%.2f\", ($DELTA_PGALLOC * 4096) / (1024 * 1024 * 1024)}")
ALLOC_BW=$(awk "BEGIN {printf \"%.2f MB/s\", ($DELTA_PGALLOC * 4096) / (1024 * 1024 * $WORKLOAD_RUNTIME)}")
HIT_GB=$(awk "BEGIN {printf \"%.2f\", ($DELTA_NUMA_HIT * 4096) / (1024 * 1024 * 1024)}")
MISS_GB=$(awk "BEGIN {printf \"%.2f\", ($DELTA_NUMA_MISS * 4096) / (1024 * 1024 * 1024)}")

# 7. Print Standard VMSTAT Output Report
echo ""
echo "=========================================================="
echo "       WORKLOAD VMSTAT TIERING & FAULT DELTA REPORT       "
echo "=========================================================="
echo " Kernel Release                         : $(uname -r)"
echo " Workload Execution Runtime             : ${WORKLOAD_RUNTIME} seconds"
echo " Total Page Faults Delta (pgfault)      : ${DELTA_PGF}"
echo " NUMA Hint Faults Delta (numa_hint)     : ${DELTA_NUMA}"
echo " NUMA Pages Migrated (numa_pages_mig)   : ${DELTA_NUMA_PAGES_MIG}"
echo " PMI Interrupts Delta (cat /proc/interrupts): ${DELTA_PMI}"
echo "----------------------------------------------------------"
echo " Total Allocated Pages (pgalloc)        : ${DELTA_PGALLOC} (${ALLOC_GB} GB, ${ALLOC_BW})"
echo " NUMA Local Alloc Hits (numa_hit)       : ${DELTA_NUMA_HIT} (${HIT_GB} GB)"
echo " NUMA Remote Alloc Misses (numa_miss)   : ${DELTA_NUMA_MISS} (${MISS_GB} GB spillover)"
if [ $DELTA_ALLOCSTALL -gt 0 ]; then
    echo " Direct Allocation Stalls (allocstall)  : ${DELTA_ALLOCSTALL}"
fi
echo "----------------------------------------------------------"
echo " Promotion Candidates Delta (pgpromote_cand) : ${DELTA_PROM_CAND}"
if [ $DELTA_PROM_TRIED -gt 0 ]; then
    echo " Promotion Attempts (pgpromote_tried)        : ${DELTA_PROM_TRIED}"
fi
echo " Promoted Anon Pages Delta (pgpromote_anon)  : ${DELTA_PROM_PAGE}"
echo " Demoted Anon Pages Delta (pgdemote_anon)    : ${DELTA_DEM_PAGE_ANON}"
echo " Demoted File Pages Delta (pgdemote_file)    : ${DELTA_DEM_PAGE_FILE}"
if [ $DELTA_DEM_KSWAPD -gt 0 ] || [ $DELTA_DEM_DIRECT -gt 0 ]; then
    echo " Demoted kswapd (pgdemote_kswapd)            : ${DELTA_DEM_KSWAPD}"
    echo " Demoted direct (pgdemote_direct)            : ${DELTA_DEM_DIRECT}"
fi
if [ $DELTA_MIG_DST_FULL -gt 0 ]; then
    echo " Blocked Promotions - Dst Full (dst_full)    : ${DELTA_MIG_DST_FULL}"
fi
echo " Total Migrated Pages Delta (pgmigrate_succ) : ${DELTA_MIG_SUCC}"
echo " Migration Failures (pgmigrate_fail)         : ${DELTA_MIG_FAIL}"
echo " Slow Tier Node 1 Used Memory                : ${NODE1_AFTER} MB (Growth: +${DELTA_NODE1} MB)"
echo " Slow Tier Demotion Bandwidth                : ${DEM_BW}"
echo "=========================================================="

# 8. Print Nomad Specific Report (if running on Nomad baseline with async_promote module)
if [ -f /proc/perfnomad ]; then
    DELTA_TRY=$((TRY_AFTER - TRY_BEFORE))
    [ $DELTA_TRY -lt 0 ] && DELTA_TRY=0

    DELTA_SUCCESS=$((SUCCESS_AFTER - SUCCESS_BEFORE))
    [ $DELTA_SUCCESS -lt 0 ] && DELTA_SUCCESS=0

    DELTA_RETRY=$((RETRY_AFTER - RETRY_BEFORE))
    [ $DELTA_RETRY -lt 0 ] && DELTA_RETRY=0

    DELTA_TOTAL=$((DELTA_SUCCESS + DELTA_RETRY))

    PROM_MB=$(awk "BEGIN {printf \"%.2f\", ($DELTA_SUCCESS * 4096) / (1024 * 1024)}")
    PROM_BW=$(awk "BEGIN {printf \"%.2f MB/s\", ($DELTA_SUCCESS * 4096) / (1024 * 1024 * $WORKLOAD_RUNTIME)}")

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
    echo " Single-Line Summary Format (Timestamp | Delta_Try | Prom_BW | Dem_BW | Abort_Rate | Node1_Used):"
    echo "$(date +%H:%M:%S) | $DELTA_TRY | $PROM_BW | $DEM_BW | $ABORT_RATE | ${NODE1_AFTER} MB"
    echo "------------------------------------------------------------------------------------------"
    echo " Total Promotion Candidates (try_nr)  : ${DELTA_TRY}"
    echo " Successful Migrations (success_nr)   : ${DELTA_SUCCESS} (${PROM_MB} MB Promoted)"
    echo " Retried/Aborted Migrations (retry_nr): ${DELTA_RETRY}"
    echo " Average Promotion Bandwidth          : ${PROM_BW}"
    echo " Average Demotion Bandwidth           : ${DEM_BW}"
    echo " Overall Application Abortion Rate    : ${ABORT_RATE}"
    echo " Slow Tier Node 1 Used Memory         : ${NODE1_AFTER} MB"
    echo "=========================================================================================="
elif [ $DELTA_PROM_PAGE -gt 0 ] || [ $DELTA_MIG_SUCC -gt 0 ]; then
    # Upstream TPP / Generic Tiering Summary
    PROM_PAGES=$(( DELTA_PROM_PAGE > 0 ? DELTA_PROM_PAGE : DELTA_MIG_SUCC ))
    PROM_MB=$(awk "BEGIN {printf \"%.2f\", ($PROM_PAGES * 4096) / (1024 * 1024)}")
    PROM_BW=$(awk "BEGIN {printf \"%.2f MB/s\", ($PROM_PAGES * 4096) / (1024 * 1024 * $WORKLOAD_RUNTIME)}")
    echo ""
    echo "=========================================================================================="
    echo "                 TIERED MEMORY MIGRATION & BANDWIDTH SUMMARY                              "
    echo "=========================================================================================="
    echo " Promoted Memory Volume    : ${PROM_MB} MB (${PROM_PAGES} pages)"
    echo " Average Promotion Bandwidth: ${PROM_BW}"
    echo " Average Demotion Bandwidth : ${DEM_BW}"
    echo " Slow Tier Node 1 Used     : ${NODE1_AFTER} MB"
    echo "=========================================================================================="
fi
echo ""

