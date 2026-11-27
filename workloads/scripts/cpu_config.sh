#!/bin/bash
# ==============================================================================
# Centralized CPU Topology & Core Allocation Map (Socket 0: 32 physical cores)
#
#   Core  0      : Reserved for OS interrupts & Socket 0 uncore_cha_* PMUs
#   Cores 1..24  : Benchmark workload threads (24 physical cores)
#   Cores 25..27 : Kernel headroom (kswapd0, kcompactd0, kworker)
#   Core  28     : 1s time-series telemetry sampler (Node 1 RAM)
#   Core  29     : PACT migration thread (--migration-cpu)
#   Core  30     : PACT monitor / PEBS coroutine loop (--monitor-cpu)
#   Core  31     : Standalone tier-prefetch-mon daemon
#   Cores 32..64 : Offlined hyperthreads / Socket 1 CPUs
# ==============================================================================

# Fixed workload physical cores
WORKLOAD_CPU_START=1
WORKLOAD_CORES=24
WORKLOAD_CPU_END=$(( WORKLOAD_CPU_START + WORKLOAD_CORES - 1 ))

# Derived workload CPU formats
WORKLOAD_CPU_RANGE="${WORKLOAD_CPU_START}-${WORKLOAD_CPU_END}"
SELECTED_CPUS="$(seq -s, "${WORKLOAD_CPU_START}" "${WORKLOAD_CPU_END}")"
WORKLOAD_CPU_MASK="$(printf '0x%x' $(( ((1 << WORKLOAD_CORES) - 1) << WORKLOAD_CPU_START )))"

# Fixed service & daemon cores
TIMESERIES_CPU=28
TIMESERIES_MEMNODE=1
PACT_MIGRATION_CPU=29
PACT_MONITOR_CPU=30
PREFETCH_MON_CPU=31

# Fixed offlined CPUs (Socket 1 / hyperthreads)
OFFLINE_CPU_START=32
OFFLINE_CPU_END=64
