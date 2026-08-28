#!/bin/bash
echo "=== NOMAD Migration & Abortion Monitor ==="
echo "Timestamp | Prom Candidates/s | Prom Bandwidth | Dem Bandwidth | Abort Rate | Node 1 Used"

PREV_TRY=0
PREV_SUCCESS=0
PREV_RETRY=0
PREV_NODE1=0

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

while true; do
    if [ -f /proc/perfnomad ]; then
        SUCCESS=$(grep "success_nr" /proc/perfnomad | head -n 1 | awk '{print $2}')
        RETRY=$(grep "retry_nr" /proc/perfnomad | head -n 1 | awk '{print $2}')
        TRY=$(grep "try_to_promote_nr" /proc/perfnomad | head -n 1 | awk '{print $2}')
        NODE1_USED=$(get_node1_used_mb)

        if [ $PREV_TRY -gt 0 ]; then
            DELTA_TRY=$((TRY - PREV_TRY))
            DELTA_SUCCESS=$((SUCCESS - PREV_SUCCESS))
            DELTA_RETRY=$((RETRY - PREV_RETRY))
            DELTA_TOTAL=$((DELTA_SUCCESS + DELTA_RETRY))

            # Promotion Bandwidth
            PROM_BW=$(awk "BEGIN {printf \"%.2f MB/s\", ($DELTA_SUCCESS * 4096) / (1024 * 1024)}")

            # Demotion Bandwidth (Node 1 growth rate)
            DELTA_NODE1=$((NODE1_USED - PREV_NODE1))
            if [ $DELTA_NODE1 -lt 0 ]; then
                DELTA_NODE1=0
            fi
            DEM_BW=$(awk "BEGIN {printf \"%.2f MB/s\", $DELTA_NODE1}")

            # Abortion Rate
            if [ $DELTA_TOTAL -gt 0 ]; then
                ABORT_RATE=$(awk "BEGIN {printf \"%.2f%%\", ($DELTA_RETRY / $DELTA_TOTAL) * 100}")
            else
                ABORT_RATE="0.00%"
            fi

            echo "$(date +%H:%M:%S) | $DELTA_TRY | $PROM_BW | $DEM_BW | $ABORT_RATE | ${NODE1_USED} MB"
        fi

        PREV_TRY=$TRY
        PREV_SUCCESS=$SUCCESS
        PREV_RETRY=$RETRY
        PREV_NODE1=$NODE1_USED
    else
        echo "/proc/perfnomad not available (ensure async_promote.ko is loaded)"
    fi

    sleep 0.5
done
