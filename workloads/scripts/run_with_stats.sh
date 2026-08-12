#!/bin/bash
# ===================================================================
# Nomad Application-Wide Monitor: VMSTAT Faults + Perfnomad Metrics
# Measures performance deltas & bandwidth for the ENTIRE workload run ($@)
# ===================================================================

if [ $# -eq 0 ]; then
    echo "Usage: $0 <command>"
    exit 1
fi

# 1. Sleep 30s before capturing baseline counters to ensure system is 100% settled
sleep 30

START_TIME=$(date +%s)

# 2. Read baseline VMSTAT counters BEFORE workload execution
PGF_BEFORE=$(grep -w "pgfault" /proc/vmstat | awk '{print $2}')
NUMA_BEFORE=$(grep -w "numa_hint_faults" /proc/vmstat | awk '{print $2}')
PROM_CAND_BEFORE=$(grep -w "pgpromote_candidate" /proc/vmstat 2>/dev/null | awk '{print $2}')
PROM_PAGE_BEFORE=$(grep -w "pgpromote_anon" /proc/vmstat 2>/dev/null | awk '{print $2}')
DEM_CAND_BEFORE=$(grep -w "pgdemote_anon" /proc/vmstat 2>/dev/null | awk '{print $2}')
DEM_PAGE_DIR_BEFORE=$(grep -w "pgdemote_direct" /proc/vmstat 2>/dev/null | awk '{print $2}')
DEM_PAGE_KSW_BEFORE=$(grep -w "pgdemote_kswapd" /proc/vmstat 2>/dev/null | awk '{print $2}')
MIG_SUCC_BEFORE=$(grep -w "pgmigrate_success" /proc/vmstat 2>/dev/null | awk '{print $2}')

PGF_BEFORE="${PGF_BEFORE:-0}"
NUMA_BEFORE="${NUMA_BEFORE:-0}"
PROM_CAND_BEFORE="${PROM_CAND_BEFORE:-0}"
PROM_PAGE_BEFORE="${PROM_PAGE_BEFORE:-0}"
DEM_CAND_BEFORE="${DEM_CAND_BEFORE:-0}"
DEM_PAGE_DIR_BEFORE="${DEM_PAGE_DIR_BEFORE:-0}"
DEM_PAGE_KSW_BEFORE="${DEM_PAGE_KSW_BEFORE:-0}"
MIG_SUCC_BEFORE="${MIG_SUCC_BEFORE:-0}"

# Read baseline PERFNOMAD counters BEFORE workload execution
if [ -f /proc/perfnomad ]; then
    SUCCESS_BEFORE=$(grep "success_nr" /proc/perfnomad | head -n 1 | awk '{print $2}')
    RETRY_BEFORE=$(grep "retry_nr" /proc/perfnomad | head -n 1 | awk '{print $2}')
    TRY_BEFORE=$(grep "try_to_promote_nr" /proc/perfnomad | head -n 1 | awk '{print $2}')
else
    SUCCESS_BEFORE=0
    RETRY_BEFORE=0
    TRY_BEFORE=0
fi

NODE1_BEFORE=$(numactl -H 2>/dev/null | grep "node 1 free" | awk '{print 7926 - $4}')
NODE1_BEFORE="${NODE1_BEFORE:-0}"

# 3. Execute the workload application binary
"$@"

# 4. Sleep 30s after workload execution to allow Nomad's async ring queue worker threads to finish migrating
sleep 30

END_TIME=$(date +%s)

# 5. Read final VMSTAT counters AFTER async worker threads complete
PGF_AFTER=$(grep -w "pgfault" /proc/vmstat | awk '{print $2}')
NUMA_AFTER=$(grep -w "numa_hint_faults" /proc/vmstat | awk '{print $2}')
PROM_CAND_AFTER=$(grep -w "pgpromote_candidate" /proc/vmstat 2>/dev/null | awk '{print $2}')
PROM_PAGE_AFTER=$(grep -w "pgpromote_anon" /proc/vmstat 2>/dev/null | awk '{print $2}')
DEM_CAND_AFTER=$(grep -w "pgdemote_anon" /proc/vmstat 2>/dev/null | awk '{print $2}')
DEM_PAGE_DIR_AFTER=$(grep -w "pgdemote_direct" /proc/vmstat 2>/dev/null | awk '{print $2}')
DEM_PAGE_KSW_AFTER=$(grep -w "pgdemote_kswapd" /proc/vmstat 2>/dev/null | awk '{print $2}')
MIG_SUCC_AFTER=$(grep -w "pgmigrate_success" /proc/vmstat 2>/dev/null | awk '{print $2}')

PGF_AFTER="${PGF_AFTER:-0}"
NUMA_AFTER="${NUMA_AFTER:-0}"
PROM_CAND_AFTER="${PROM_CAND_AFTER:-0}"
PROM_PAGE_AFTER="${PROM_PAGE_AFTER:-0}"
DEM_CAND_AFTER="${DEM_CAND_AFTER:-0}"
DEM_PAGE_DIR_AFTER="${DEM_PAGE_DIR_AFTER:-0}"
DEM_PAGE_KSW_AFTER="${DEM_PAGE_KSW_AFTER:-0}"
MIG_SUCC_AFTER="${MIG_SUCC_AFTER:-0}"

# Read final PERFNOMAD counters AFTER async worker threads complete
if [ -f /proc/perfnomad ]; then
    SUCCESS_AFTER=$(grep "success_nr" /proc/perfnomad | head -n 1 | awk '{print $2}')
    RETRY_AFTER=$(grep "retry_nr" /proc/perfnomad | head -n 1 | awk '{print $2}')
    TRY_AFTER=$(grep "try_to_promote_nr" /proc/perfnomad | head -n 1 | awk '{print $2}')
else
    SUCCESS_AFTER=0
    RETRY_AFTER=0
    TRY_AFTER=0
fi

NODE1_AFTER=$(numactl -H 2>/dev/null | grep "node 1 free" | awk '{print 7926 - $4}')
NODE1_AFTER="${NODE1_AFTER:-0}"

# 6. Calculate VMSTAT Deltas
DELTA_PGF=$((PGF_AFTER - PGF_BEFORE))
DELTA_NUMA=$((NUMA_AFTER - NUMA_BEFORE))
DELTA_PROM_CAND=$((PROM_CAND_AFTER - PROM_CAND_BEFORE))
DELTA_PROM_PAGE=$((PROM_PAGE_AFTER - PROM_PAGE_BEFORE))
DELTA_DEM_CAND=$((DEM_CAND_AFTER - DEM_CAND_BEFORE))
DELTA_DEM_PAGE_DIR=$((DEM_PAGE_DIR_AFTER - DEM_PAGE_DIR_BEFORE))
DELTA_DEM_PAGE_KSW=$((DEM_PAGE_KSW_AFTER - DEM_PAGE_KSW_BEFORE))
DELTA_DEM_PAGE_TOTAL=$((DELTA_DEM_PAGE_DIR + DELTA_DEM_PAGE_KSW))
DELTA_MIG_SUCC=$((MIG_SUCC_AFTER - MIG_SUCC_BEFORE))

[ $DELTA_PGF -lt 0 ] && DELTA_PGF=0
[ $DELTA_NUMA -lt 0 ] && DELTA_NUMA=0
[ $DELTA_PROM_CAND -lt 0 ] && DELTA_PROM_CAND=0
[ $DELTA_PROM_PAGE -lt 0 ] && DELTA_PROM_PAGE=0
[ $DELTA_DEM_CAND -lt 0 ] && DELTA_DEM_CAND=0
[ $DELTA_DEM_PAGE_TOTAL -lt 0 ] && DELTA_DEM_PAGE_TOTAL=0
[ $DELTA_MIG_SUCC -lt 0 ] && DELTA_MIG_SUCC=0

# Calculate PERFNOMAD Deltas & Bandwidth
ELAPSED_SEC=$((END_TIME - START_TIME))
[ $ELAPSED_SEC -le 0 ] && ELAPSED_SEC=1

DELTA_TRY=$((TRY_AFTER - TRY_BEFORE))
[ $DELTA_TRY -lt 0 ] && DELTA_TRY=0

DELTA_SUCCESS=$((SUCCESS_AFTER - SUCCESS_BEFORE))
[ $DELTA_SUCCESS -lt 0 ] && DELTA_SUCCESS=0

DELTA_RETRY=$((RETRY_AFTER - RETRY_BEFORE))
[ $DELTA_RETRY -lt 0 ] && DELTA_RETRY=0

DELTA_TOTAL=$((DELTA_SUCCESS + DELTA_RETRY))

# Calculate Average Promotion Bandwidth over application runtime
PROM_MB=$(awk "BEGIN {printf \"%.2f\", ($DELTA_SUCCESS * 4096) / (1024 * 1024)}")
PROM_BW=$(awk "BEGIN {printf \"%.2f MB/s\", ($DELTA_SUCCESS * 4096) / (1024 * 1024 * $ELAPSED_SEC)}")

# Calculate Average Demotion Bandwidth (Node 1 memory growth rate)
DELTA_NODE1=$((NODE1_AFTER - NODE1_BEFORE))
[ $DELTA_NODE1 -lt 0 ] && DELTA_NODE1=0
DEM_BW=$(awk "BEGIN {printf \"%.2f MB/s\", $DELTA_NODE1 / $ELAPSED_SEC}")

# Calculate Application Abortion Rate
if [ $DELTA_TOTAL -gt 0 ]; then
    ABORT_RATE=$(awk "BEGIN {printf \"%.2f%%\", ($DELTA_RETRY / $DELTA_TOTAL) * 100}")
else
    ABORT_RATE="0.00%"
fi

# 7. Print Output Reports
echo ""
echo "=========================================================="
echo "       WORKLOAD VMSTAT TIERING & FAULT DELTA REPORT       "
echo "=========================================================="
echo " Total Page Faults Delta (pgfault)      : ${DELTA_PGF}"
echo " NUMA Hint Faults Delta (numa_hint)     : ${DELTA_NUMA}"
echo "----------------------------------------------------------"
echo " Promotion Candidates Delta (pgpromote_cand) : ${DELTA_PROM_CAND}"
echo " Promoted Pages Delta (pgpromote_anon)       : ${DELTA_PROM_PAGE}"
echo " Demotion Candidates Delta (pgdemote_anon)   : ${DELTA_DEM_CAND}"
echo " Demoted Pages Delta (pgdemote_direct/ksw)   : ${DELTA_DEM_PAGE_TOTAL}"
echo " Total Migrated Pages Delta (pgmigrate_succ) : ${DELTA_MIG_SUCC}"
echo "=========================================================="

if [ -f /proc/perfnomad ]; then
    echo ""
    echo "=========================================================================================="
    echo "                   NOMAD APPLICATION-WIDE PERFORMANCE REPORT                              "
    echo "=========================================================================================="
    echo " Executed Command          : $@"
    echo " Application Runtime       : ${ELAPSED_SEC} seconds"
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
fi
echo ""
