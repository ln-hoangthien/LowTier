/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 MoatLab, Virginia Tech. */

#ifndef MIG_TELEMETRY_H
#define MIG_TELEMETRY_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdint.h>
#include <unistd.h>
#include <stdbool.h>

#define CACHELINES_PER_PAGE 64ULL
#define MIN_MIG_PAGES_GATE 32ULL
#define CALIBRATED_ACTIVE_CYCLES 25.0 /* Intrinsic ERMS copy rate (~18 cycles/line) */
#define DEFAULT_CORE_WIDTH 2.875
#define DEFAULT_CORE_FREQ_GHZ 2.1
#define DEFAULT_FALLBACK_T_INT 8.5

/* Prefetch Distance Configuration & Defaults */
#define PREFETCH_DEFAULT_PROMOTE_DISTANCE 5U
#define PREFETCH_DEFAULT_DEMOTE_DISTANCE 2U
#define PREFETCH_DEFAULT_MIN_DISTANCE 1U
#define PREFETCH_DEFAULT_MAX_DISTANCE 16U
#define PREFETCH_DEFAULT_ALPHA_STEADY 20U
#define PREFETCH_DEFAULT_ALPHA_SATURATE 70U

/*
 * Heterogeneous Batch Decomposition Constants:
 * Stable instruction counts (UOPs) and microarchitectural core execution widths (IPC):
 * - 4KB (in-cache / pipeline-bound): ~215 uops, IPC ~2.873
 * - 2MB (cross-NUMA / DRAM bus-bound): ~67,400 uops, IPC ~0.160
 */
#define UOPS_PER_4KB 214.5
#define UOPS_PER_2MB 67044.73
#define CORE_WIDTH_4KB 2.873
#define CORE_WIDTH_2MB 0.155

/*
 * Calibrated against MLC --loaded_latency (-W6 50/50 R/W)
 * Fast (Node 0): Baseline ~104 ns, Knee ~173 ns, Cliff >1400 ns
 * Slow (Node 1): Baseline ~172 ns, Knee ~223 ns, Cliff >760 ns
 */
#define PREFETCH_LATENCY_FAST_THRESHOLD_NS 500.0
#define PREFETCH_LATENCY_SLOW_THRESHOLD_NS 700.0

#ifndef clamp
#define clamp(val, min_val, max_val)                                                               \
    ((val) < (min_val) ? (min_val) : ((val) > (max_val) ? (max_val) : (val)))
#endif

#ifndef READ_ONCE
#define READ_ONCE(x) (*(const volatile __typeof__(x) *)&(x))
#endif

#ifndef WRITE_ONCE
#define WRITE_ONCE(x, val) (*(volatile __typeof__(x) *)&(x) = (val))
#endif

static inline bool is_tiered_promotion(int source_id)
{
    if (source_id < 0) {
        return false;
    }
    /* In tiered memory systems, Node 0 is top-tier (fast DRAM); Node > 0 is slow tier */
    return (source_id > 0);
}

unsigned int get_migration_prefetch_distance(int source_id, double l_slow_ns, double l_fast_ns,
                                             double interval_ns);

struct mig_telemetry {
    pid_t mig_tid;           /* Thread ID (TID) of the migration worker */
    int pin_cpu;             /* Dedicated isolated core */
    int fd_uops;             /* UOPS_RETIRED.RETIRE_SLOTS (0x02C2) */
    double core_freq_ghz;    /* Core clock frequency in GHz */
    double last_valid_t_int; /* Fallback / last valid T_interval */
    bool is_initialized;
};

/* API Lifecycle */
int mig_telemetry_init_caller(struct mig_telemetry *telem, int target_cpu, double core_freq_ghz);
void mig_telemetry_start_window(struct mig_telemetry *telem);
void mig_telemetry_stop_window(struct mig_telemetry *telem);
double mig_telemetry_compute_interval(struct mig_telemetry *telem, uint64_t pages_migrated);
void mig_telemetry_close(struct mig_telemetry *telem);

/* Forward declaration */
struct pact_context;
typedef struct pact_context pact_context_t;

/* Prefetch Distance & numa_move_pages flags helpers */
#define MPOL_MF_PREFETCH_ENABLE (1U << 15)
#define MPOL_MF_PREFETCH_PROMOTE_SHIFT 16
#define MPOL_MF_PREFETCH_DEMOTE_SHIFT 24

double read_loaded_latency_tier_ns(pact_context_t *ctx, bool is_slow_tier);
void log_mig_telemetry_status(double latency_ns, double interval_ns, unsigned int dist);
void mig_telemetry_update_pacing(pact_context_t *ctx, struct mig_telemetry *telem,
                                 uint64_t pages_migrated);
int mig_telemetry_get_move_pages_flags(void);

#endif /* MIG_TELEMETRY_H */
