/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 MoatLab, Virginia Tech. */

#ifndef MIG_TELEMETRY_H
#define MIG_TELEMETRY_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>

#include "mig_cha_mon.h"

#define CACHELINES_PER_PAGE 64ULL
#define MIN_MIG_PAGES_GATE 64ULL
#define DEFAULT_FALLBACK_T_INT 18.0
#define MAX_T_INTERVAL_NS 45.0
#define DEFAULT_CORE_FREQ_GHZ 3.0

/* Prefetch Distance Configuration & Defaults */
#define PREFETCH_DEFAULT_PROMOTE_DISTANCE 5U
#define PREFETCH_DEFAULT_DEMOTE_DISTANCE 2U
#define PREFETCH_DEFAULT_MIN_DISTANCE 1U
#define PREFETCH_DEFAULT_MAX_DISTANCE 16U
#define PREFETCH_DEFAULT_ALPHA_STEADY 5U
#define PREFETCH_DEFAULT_ALPHA_SATURATE 20U

/*
 * Calibrated against MLC --loaded_latency (-W6 50/50 R/W)
 * Fast (Node 0): Baseline ~104 ns, Knee ~173 ns, Cliff >1400 ns
 * Slow (Node 1): Baseline ~172 ns, Knee ~223 ns, Cliff >760 ns
 */
#define PREFETCH_LATENCY_FAST_THRESHOLD_4KB 450.0
#define PREFETCH_LATENCY_SLOW_THRESHOLD_4KB 550.0

#define PREFETCH_LATENCY_FAST_THRESHOLD_2MB 420.0
#define PREFETCH_LATENCY_SLOW_THRESHOLD_2MB 520.0

#define DEFAULT_LATENCY_SLOW_NS 170.0
#define DEFAULT_LATENCY_FAST_NS 100.0

#ifndef mig_clamp
#define mig_clamp(val, min_val, max_val)                                       \
  ((val) < (min_val) ? (min_val) : ((val) > (max_val) ? (max_val) : (val)))
#endif

#if !defined(__cplusplus) && !defined(clamp)
#define clamp(val, min_val, max_val) mig_clamp(val, min_val, max_val)
#endif

typedef union {
  struct {
    uint16_t promote;
    uint16_t demote;
  };
  uint32_t val;
} __attribute__((aligned(64))) prefetch_distances_t;

typedef union {
  struct {
    uint16_t slow_ns;
    uint16_t fast_ns;
  };
  uint32_t val;
} __attribute__((aligned(64))) mig_latencies_t;

typedef struct {
  bool enabled;
  bool adaptive;
  bool thp_always;
  uint8_t min_distance;
  uint8_t max_distance;
  prefetch_distances_t distances;
} prefetch_sysfs_cfg_t;

void mig_telemetry_init_sysfs(prefetch_sysfs_cfg_t *cfg);

#define MIG_MAX_WORKERS 16

struct mig_telemetry {
  int fd_uops;             /* Primary worker CPU_CLK_UNHALTED.THREAD fd */
  double core_freq_ghz;    /* Core clock frequency in GHz */
  double last_valid_t_int; /* Fallback / last valid T_interval */
  bool is_initialized;
  bool thp_always;
  bool auto_detect;        /* True when initialized with explicit_mig_tid == 0 */
  bool has_baseline;       /* True once initial counter anchor is recorded */
  pid_t mig_tid;           /* Primary monitored migration worker thread TID */
  char mig_comm[32];       /* Monitored migration worker comm name */
  int extra_fds[MIG_MAX_WORKERS];     /* Additional worker perf fds (e.g. kmigraterd1..) */
  pid_t extra_tids[MIG_MAX_WORKERS];  /* Additional worker TIDs */
  uint64_t extra_last_cycles[MIG_MAX_WORKERS];
  int nr_extra_workers;
  mig_cha_mon_t cha_mon; /* CHA PMU monitor for selected cores */
  bool cha_mon_enabled;
  mig_latencies_t latencies;
  uint64_t last_raw_uops;
  uint64_t last_pages_migrated;
  uint64_t pending_cycles;
  uint64_t pending_pages;
  unsigned int pending_idle_steps;
};

struct migration_thread_entry {
  const char *name;     /* Comm name / pattern to match */
  bool is_child_thread; /* If true, look for child thread (TID != PID) */
  const char *desc;
};

/*
 * Known migration thread / worker list across tiered memory systems:
 * - PACT: userspace migration worker (thread named "pact_mig", or child of
 * "pact")
 * - Memtis: kernel migration kthread ("kmigraterd", "kmig", "kmigrated")
 * - Linux Kernel: page demotion / reclaim ("kswapd0", "kswapd1")
 * - Linux Compaction: memory compaction ("kcompactd0", "kcompactd1")
 * - AutoNUMA: kernel migration ("knuma_migrated")
 * - Colloid: migration monitor ("colloid-mon")
 * - Nomad: migration worker ("nomad")
 */
static const struct migration_thread_entry s_migration_threads[]
    __attribute__((unused)) = {
        {"async_promote", false, "Nomad asynchronous promotion worker"},
        {"kmigraterd", false, "Memtis tiered migration worker (kmigraterd)"},
        {"kmig", false, "Memtis tiered migration worker (kmig)"},
        {"colloid-mon", false, "Colloid tiered memory migration monitor"},
        {"nomad", true, "Nomad tiered migration worker"},
        {"kswapd", false, "Kernel slow-tier demotion worker (kswapd)"},
        {"knuma_migrated", false, "AutoNUMA memory migration worker"},
        {"pact_mig", false, "PACT migration worker thread (pact_mig)"},
        {"pact", true, "PACT migration worker thread (child of pact)"},
        {NULL, false, NULL}};

/* Unified Lifecycle API */
int mig_telemetry_init(struct mig_telemetry *telem, pid_t explicit_mig_tid,
                       uint64_t cpu_mask, int target_cpu);
int mig_telemetry_attach_tid(struct mig_telemetry *telem, pid_t tid);
bool mig_telemetry_try_attach(struct mig_telemetry *telem);
void mig_telemetry_read_sysfs(prefetch_sysfs_cfg_t *cfg);
double mig_telemetry_compute_interval(struct mig_telemetry *telem,
                                      uint64_t pages_migrated);
void mig_telemetry_update_distances(double l_slow_ns, double l_fast_ns,
                                    double interval_ns);
void mig_telemetry_step(struct mig_telemetry *telem, uint64_t pages_promoted);
mig_latencies_t mig_cha_mon_sample_latencies(mig_cha_mon_t *mon);
void mig_telemetry_close(struct mig_telemetry *telem);

#ifdef __cplusplus
}
#endif

#endif /* MIG_TELEMETRY_H */
