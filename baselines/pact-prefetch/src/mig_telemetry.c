/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 MoatLab, Virginia Tech. */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <errno.h>
#include <sched.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <linux/perf_event.h>
#include <numaif.h>

#include "pmu.h"
#include "pact.h"
#include "error.h"
#include "mig_telemetry.h"

/* =========================================================================
 * Thread-Scoped PMU Telemetry and CPU Pinning for Migration Pacing
 * ========================================================================= */

/*
 * Read-Mostly Configuration: initialized once during startup and unchanged during benchmark.
 * Kept compact (8 bytes aligned) and isolated from hot write variables.
 */
struct prefetch_config {
    bool enabled;
    bool adaptive;
    uint8_t min_distance;
    uint8_t max_distance;
    bool thp_always;
};

static struct prefetch_config prefetch_cfg __attribute__((aligned(8))) = {
    .enabled = true,
    .adaptive = true,
    .min_distance = PREFETCH_DEFAULT_MIN_DISTANCE,
    .max_distance = PREFETCH_DEFAULT_MAX_DISTANCE,
    .thp_always = false,
};

/*
 * Hot Read/Write State: updated by pacing logic and read by migration worker.
 * Isolated on a dedicated cache line to eliminate false sharing.
 * Stored as uint8_t values packed in a uint16_t union so:
 * - promote (bits 0..7) and demote (bits 8..15) can be read atomically in a single 16-bit instruction.
 * - (uint32_t)val << 16 directly maps into MPOL_MF_PREFETCH flags.
 */
union pact_prefetch_distances {
    struct {
        uint8_t promote;
        uint8_t demote;
    };
    uint16_t val;
};

static union pact_prefetch_distances prefetch_distances __attribute__((aligned(64))) = {
    .promote = PREFETCH_DEFAULT_PROMOTE_DISTANCE,
    .demote = PREFETCH_DEFAULT_DEMOTE_DISTANCE,
};

static const char *get_prefetch_sysfs_dir(void)
{
    static const char *s_sysfs_dir = NULL;
    if (s_sysfs_dir) {
        return s_sysfs_dir;
    }
    if (access("/sys/kernel/mm/page_prefetch", F_OK) == 0) {
        s_sysfs_dir = "/sys/kernel/mm/page_prefetch";
    } else if (access("/sys/kernel/mm/pact_prefetch", F_OK) == 0) {
        s_sysfs_dir = "/sys/kernel/mm/pact_prefetch";
    }
    return s_sysfs_dir;
}

static unsigned int read_sysfs_uint(const char *path, unsigned int default_val)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return default_val;
    }
    char buf[16] = {0};
    unsigned int val = default_val;
    if (read(fd, buf, sizeof(buf) - 1) > 0) {
        int parsed = atoi(buf);
        if (parsed >= 0) {
            val = (unsigned int)parsed;
        }
    }
    close(fd);
    return val;
}

static unsigned int read_prefetch_sysfs_uint(const char *attr, unsigned int default_val)
{
    const char *dir = get_prefetch_sysfs_dir();
    if (!dir) {
        return default_val;
    }
    char path[128];
    snprintf(path, sizeof(path), "%s/%s", dir, attr);
    return read_sysfs_uint(path, default_val);
}

static void init_prefetch_sysfs_params(void)
{
    static int is_sysfs_init = 0;
    if (__builtin_expect(is_sysfs_init, 1)) {
        return;
    }
    is_sysfs_init = 1;

    prefetch_cfg.enabled = (read_prefetch_sysfs_uint("enabled", 1) != 0);
    prefetch_cfg.adaptive = (read_prefetch_sysfs_uint("adaptive", 1) != 0);
    prefetch_cfg.min_distance =
        (uint8_t)read_prefetch_sysfs_uint("min_distance", PREFETCH_DEFAULT_MIN_DISTANCE);
    prefetch_cfg.max_distance =
        (uint8_t)read_prefetch_sysfs_uint("max_distance", PREFETCH_DEFAULT_MAX_DISTANCE);
    prefetch_distances.promote =
        (uint8_t)read_prefetch_sysfs_uint("promote_distance", PREFETCH_DEFAULT_PROMOTE_DISTANCE);
    prefetch_distances.demote =
        (uint8_t)read_prefetch_sysfs_uint("demote_distance", PREFETCH_DEFAULT_DEMOTE_DISTANCE);

    if (!prefetch_cfg.enabled) {
        prefetch_cfg.adaptive = false;
        prefetch_distances.val = 0;
    }

    /*
     * Configure baseline cachelines_per_page based on /sys/kernel/mm/transparent_hugepage/:
     * - Only when enabled is [always] AND defrag is [always] are 2MB pages synchronously guaranteed.
     * - If defrag is [defer] (or THP is madvise/never), 2MB pages can split into 4KB pages
     *   or fall back to 4KB on allocation, so default baseline to 64ULL.
     * Note: Per-batch heterogeneous mixture decomposition in mig_telemetry_compute_interval
     * dynamically handles runtime mixtures of 4KB and 2MB pages.
     */
    prefetch_cfg.thp_always = false;
    int fd_thp = open("/sys/kernel/mm/transparent_hugepage/enabled", O_RDONLY | O_CLOEXEC);
    if (fd_thp >= 0) {
        char thp_buf[64] = {0};
        if (read(fd_thp, thp_buf, sizeof(thp_buf) - 1) > 0) {
            if (strstr(thp_buf, "[always]") != NULL || strcmp(thp_buf, "always\n") == 0 ||
                strcmp(thp_buf, "always") == 0) {
                prefetch_cfg.thp_always = true;
            }
        }
        close(fd_thp);
    }
    bool defrag_always = false;
    int fd_defrag = open("/sys/kernel/mm/transparent_hugepage/defrag", O_RDONLY | O_CLOEXEC);
    if (fd_defrag >= 0) {
        char defrag_buf[64] = {0};
        if (read(fd_defrag, defrag_buf, sizeof(defrag_buf) - 1) > 0) {
            if (strstr(defrag_buf, "[always]") != NULL || strcmp(defrag_buf, "always\n") == 0 ||
                strcmp(defrag_buf, "always") == 0) {
                defrag_always = true;
            }
        }
        close(fd_defrag);
    }

    const char *sysfs_dir = get_prefetch_sysfs_dir();
    log_info("init_prefetch_sysfs_params",
             "Migration Prefetch Parameters (%s): enabled=%u (adaptive=%u, promote=%u, demote=%u, "
             "min_dist=%u, max_dist=%u), %s",
             sysfs_dir ? sysfs_dir : "N/A", prefetch_cfg.enabled, prefetch_cfg.adaptive,
             prefetch_distances.promote, prefetch_distances.demote, prefetch_cfg.min_distance,
             prefetch_cfg.max_distance,
             prefetch_cfg.thp_always
                 ? (defrag_always ? "THP enabled" : "THP enabled (defrag defer)")
                 : "THP disabled/4KB");
}

int mig_telemetry_init_caller(struct mig_telemetry *telem, int target_cpu, double core_freq_ghz)
{
    struct perf_event_attr pe;
    cpu_set_t cpuset;

    if (!telem) {
        return -EINVAL;
    }
    memset(telem, 0, sizeof(*telem));

    /* Initialize sysfs parameters once at startup */
    init_prefetch_sysfs_params();

    /* 1. Retrieve the caller's kernel Thread ID (TID) */
    telem->mig_tid = (pid_t)syscall(SYS_gettid);
    telem->pin_cpu = target_cpu;
    telem->core_freq_ghz = (core_freq_ghz > 0.1) ? core_freq_ghz : DEFAULT_CORE_FREQ_GHZ;
    telem->last_valid_t_int = DEFAULT_FALLBACK_T_INT;

    /* 2. Pin migration thread strictly to the isolated target CPU core */
    if (target_cpu >= 0) {
        CPU_ZERO(&cpuset);
        CPU_SET(target_cpu, &cpuset);
        if (sched_setaffinity(0, sizeof(cpu_set_t), &cpuset) != 0) {
            perror("[MIG-TELEM] sched_setaffinity failed");
            return -errno;
        }
    }

    /* 3. Configure UOPS_RETIRED.RETIRE_SLOTS (Sapphire Rapids: Event 0xC2, Umask 0x02) */
    memset(&pe, 0, sizeof(struct perf_event_attr));
    pe.type = PERF_TYPE_RAW;
    pe.size = sizeof(struct perf_event_attr);
    pe.config = 0x02C2;    /* UOPS_RETIRED.RETIRE_SLOTS */
    pe.disabled = 1;       /* Gated: start disabled */
    pe.exclude_kernel = 0; /* Capture kernel-level page migration */
    pe.exclude_user = 0;
    pe.inherit = 0;

    telem->fd_uops = (int)perf_event_open(&pe, telem->mig_tid, -1, -1, 0);
    if (telem->fd_uops < 0) {
        perror("[MIG-TELEM] Failed to open UOPS_RETIRED.RETIRE_SLOTS event");
        return -errno;
    }

    telem->is_initialized = true;
    return 0;
}

void mig_telemetry_start_window(struct mig_telemetry *telem)
{
    if (!telem || !telem->is_initialized) {
        return;
    }
    ioctl(telem->fd_uops, PERF_EVENT_IOC_RESET, 0);
    ioctl(telem->fd_uops, PERF_EVENT_IOC_ENABLE, 0);
}

void mig_telemetry_stop_window(struct mig_telemetry *telem)
{
    if (!telem || !telem->is_initialized) {
        return;
    }
    ioctl(telem->fd_uops, PERF_EVENT_IOC_DISABLE, 0);
}

double mig_telemetry_compute_interval(struct mig_telemetry *telem, uint64_t pages_migrated)
{
    uint64_t uops_retired = 0;

    if (!telem || !telem->is_initialized) {
        return DEFAULT_FALLBACK_T_INT;
    }

    ssize_t ret = read(telem->fd_uops, &uops_retired, sizeof(uops_retired));
    if (ret != (ssize_t)sizeof(uops_retired)) {
        return telem->last_valid_t_int;
    }

    /* Gatekeeper check: Duplicate of the check in pact.c */
    if (pages_migrated < MIN_MIG_PAGES_GATE) {
        return telem->last_valid_t_int;
    }

    /*
     * Heterogeneous Batch Decomposition:
     * Disentangle 4KB base pages and 2MB huge pages from hardware telemetry.
     * Uses stable instruction counts (UOPs) and core execution widths:
     * - 4KB: UOPS_PER_4KB (215.0), CORE_WIDTH_4KB (2.873)
     * - 2MB: UOPS_PER_2MB (67400.0), CORE_WIDTH_2MB (0.160)
     */
    double uops_total = (double)uops_retired;
    double p_total = (double)pages_migrated;

    /* Fast-path for homogeneous 4KB pages (standard non-THP [always] workloads) */
    if (!prefetch_cfg.thp_always) {
        uint64_t total_cachelines = pages_migrated << 6; /* pages * 64 */
        double active_cycles_per_line = uops_total / (CORE_WIDTH_4KB * (double)total_cachelines);
        double t_interval_ns = active_cycles_per_line / telem->core_freq_ghz;
        telem->last_valid_t_int = t_interval_ns;
        log_debug("mig_telemetry_compute_interval",
                  "Uops: %lu, Pages: %lu (4KB only), Lines: %lu, Active/line: %.2f, T_int: %.2f ns",
                  uops_retired, pages_migrated, total_cachelines, active_cycles_per_line,
                  t_interval_ns);
        return t_interval_ns;
    }

    /*
     * If THP is turned on as [always], solve for the number of 2MB pages in the batch.
     */
    double n_2m = (uops_total - p_total * UOPS_PER_4KB) / (UOPS_PER_2MB - UOPS_PER_4KB);
    n_2m = clamp(n_2m, 0.0, p_total);
    double n_4k = p_total - n_2m;

    /* Compute exact cachelines moved across the heterogeneous mix */
    uint64_t total_cachelines = (uint64_t)(n_4k * 64.0 + n_2m * (64.0 * 512.0));
    if (total_cachelines == 0) {
        return telem->last_valid_t_int;
    }

    /*
     * Weighted core width based on data volume (cache lines moved), NOT raw page count:
     * - 4KB (in-cache / compute-bound): CORE_WIDTH_4KB (~2.873 uops/cycle)
     * - 2MB (cross-NUMA / DRAM-bound):  CORE_WIDTH_2MB (~0.160 uops/cycle)
     */
    double lines_4k = n_4k * 64.0;
    double lines_2m = n_2m * (64.0 * 512.0);
    double core_width = (lines_4k / (double)total_cachelines) * CORE_WIDTH_4KB +
                        (lines_2m / (double)total_cachelines) * CORE_WIDTH_2MB;

    double active_cycles = uops_total / core_width;
    double active_cycles_per_line = active_cycles / (double)total_cachelines;

    // /* Sanity clamp: Ensure active cycles per line stays within realistic copy bounds */
    // if (active_cycles_per_line < 5.0 || active_cycles_per_line > 50.0) {
    //     active_cycles_per_line = CALIBRATED_ACTIVE_CYCLES;
    // }

    double t_interval_ns = active_cycles_per_line / telem->core_freq_ghz;

    telem->last_valid_t_int = t_interval_ns;
    log_debug("mig_telemetry_compute_interval",
              "Uops: %lu, Pages: %lu (4KB: %.1f, 2MB: %.1f), Lines: %lu, Active/line: %.2f, T_int: "
              "%.2f ns",
              uops_retired, pages_migrated, n_4k, n_2m, total_cachelines, active_cycles_per_line,
              t_interval_ns);

    return t_interval_ns;
}

void mig_telemetry_close(struct mig_telemetry *telem)
{
    if (!telem) {
        return;
    }
    if (telem->fd_uops >= 0) {
        close(telem->fd_uops);
        telem->fd_uops = -1;
    }
    telem->is_initialized = false;
}

static void read_loaded_latency_both_tiers(pact_context_t *ctx, double *out_l_slow,
                                           double *out_l_fast)
{
    static double s_smoothed_lat_slow_ns = 190.0;
    static double s_smoothed_lat_fast_ns = 80.0;

    /* Native PACT CHA TOR Dynamic Measurement (Little's Law) in a single pass */
    if (ctx && ctx->workload && ctx->workload->nr_cha > 0) {
        pact_workload_t *wl = ctx->workload;
        uint64_t sum_occ_slow = 0, sum_ins_slow = 0;
        uint64_t sum_occ_fast = 0, sum_ins_fast = 0;
        int valid_chas_slow = 0, valid_chas_fast = 0;

        for (int i = 0; i < wl->nr_cha; i++) {
            event_group_t *gs = &wl->cha_pmus[i].group_slow;
            if (gs->time_running - gs->last_time_running >= 1000000) {
                sum_occ_slow += gs->values[CHA_TOR_OCCUPANCY];
                sum_ins_slow += gs->values[CHA_TOR_INSERTS];
                valid_chas_slow++;
            }
            event_group_t *gf = &wl->cha_pmus[i].group_fast;
            if (gf->time_running - gf->last_time_running >= 1000000) {
                sum_occ_fast += gf->values[CHA_TOR_OCCUPANCY];
                sum_ins_fast += gf->values[CHA_TOR_INSERTS];
                valid_chas_fast++;
            }
        }

        double core_freq_ghz =
            (ctx->tsc_freq_hz > 0) ? ((double)ctx->tsc_freq_hz / 1e9) : DEFAULT_CORE_FREQ_GHZ;

        /* Little's Law: Average Latency = TOR_OCCUPANCY / TOR_INSERTS */
        if (valid_chas_slow > 0 && sum_ins_slow >= 16 && sum_occ_slow > 0) {
            double dwell_time_uncore_cyc = (double)sum_occ_slow / (double)sum_ins_slow;
            s_smoothed_lat_slow_ns = dwell_time_uncore_cyc / core_freq_ghz;
        }
        if (valid_chas_fast > 0 && sum_ins_fast >= 16 && sum_occ_fast > 0) {
            double dwell_time_uncore_cyc = (double)sum_occ_fast / (double)sum_ins_fast;
            s_smoothed_lat_fast_ns = dwell_time_uncore_cyc / core_freq_ghz;
        }
    }

    if (out_l_slow) {
        *out_l_slow = s_smoothed_lat_slow_ns;
    }
    if (out_l_fast) {
        *out_l_fast = s_smoothed_lat_fast_ns;
    }
}

double read_loaded_latency_tier_ns(pact_context_t *ctx, bool is_slow_tier)
{
    double l_slow, l_fast;
    read_loaded_latency_both_tiers(ctx, &l_slow, &l_fast);
    return is_slow_tier ? l_slow : l_fast;
}

unsigned int get_migration_prefetch_distance(int source_id, double l_slow_ns, double l_fast_ns,
                                             double interval_ns)
{
    bool is_promote = is_tiered_promotion(source_id);

    /* Return default distance if adaptive prefetching is disabled */
    if (!READ_ONCE(prefetch_cfg.adaptive)) {
        return is_promote ? READ_ONCE(prefetch_distances.promote)
                          : READ_ONCE(prefetch_distances.demote);
    }

    uint8_t min_dist = READ_ONCE(prefetch_cfg.min_distance);
    uint8_t max_dist = READ_ONCE(prefetch_cfg.max_distance);
    if (min_dist > max_dist) {
        min_dist = max_dist;
    }

    /* Packed 16-bit EMA state: Byte 0 = promote EMA, Byte 1 = demote EMA */
    static union pact_prefetch_distances s_ema_distances = {
        .promote = PREFETCH_DEFAULT_PROMOTE_DISTANCE,
        .demote = PREFETCH_DEFAULT_DEMOTE_DISTANCE,
    };
    uint8_t *p_ema = is_promote ? &s_ema_distances.promote : &s_ema_distances.demote;

    /* Primary source-tier latency used for Little's Law pacing */
    double primary_latency_ns = is_promote ? l_slow_ns : l_fast_ns;

    uint8_t effective_min_dist = min_dist;
    uint8_t raw_dist = 0;
    uint8_t final_dist = *p_ema;

    /* 
     * Global Saturation Check:
     * Trigger shutdown if Slow tier breaches SLOW threshold OR Fast tier breaches FAST threshold.
     * Slow tier latency is normalized by Memory-Level Parallelism (MLP) from pmu.c.
     */
    double mlp_slow = pmu_get_tier_mlp(NULL, 1);
    double mlp_fast = pmu_get_tier_mlp(NULL, 0);
    bool is_slow_saturated = ((l_slow_ns / mlp_slow) > PREFETCH_LATENCY_SLOW_THRESHOLD_NS);
    bool is_fast_saturated = ((l_fast_ns / mlp_fast) > PREFETCH_LATENCY_FAST_THRESHOLD_NS);
    bool is_saturated = is_slow_saturated || is_fast_saturated;

    /* Dual-alpha unscaled EMA smoothing */
    unsigned int alpha_steady = PREFETCH_DEFAULT_ALPHA_STEADY;
    unsigned int alpha_saturate = PREFETCH_DEFAULT_ALPHA_SATURATE;
    unsigned int alpha = is_saturated ? alpha_saturate : alpha_steady;
    unsigned int ema_dist = *p_ema;

    if (primary_latency_ns > 0.0 && interval_ns > 0.0) {
        if (is_saturated) {
            effective_min_dist = 0U;
            log_debug("get_migration_prefetch_distance",
                      "Memory saturation detected (Slow: %.1f/%.1f ns, Fast: %.1f/%.1f ns). "
                      "Disabling prefetch for %s.",
                      l_slow_ns, PREFETCH_LATENCY_SLOW_THRESHOLD_NS, l_fast_ns,
                      PREFETCH_LATENCY_FAST_THRESHOLD_NS, is_promote ? "Promotion" : "Demotion");
            raw_dist = 0;
        } else {
            /* Pacing via Little's Law with fast integer rounding */
            double calculated_dist = (primary_latency_ns / interval_ns) + 0.5;
            raw_dist = (calculated_dist > (double)max_dist) ? max_dist : (uint8_t)calculated_dist;
        }

        /* Clamp raw_dist */
        raw_dist = clamp(raw_dist, effective_min_dist, max_dist);

        if (!ema_dist) {
            ema_dist = raw_dist;
        } else {
            ema_dist = (alpha * raw_dist + (100 - alpha) * ema_dist + 50) / 100;
        }

        ema_dist = clamp(ema_dist, effective_min_dist, max_dist);
        *p_ema = (uint8_t)ema_dist;
        final_dist = (uint8_t)ema_dist;
    }

    final_dist = clamp(final_dist, effective_min_dist, max_dist);

    if (is_promote) {
        WRITE_ONCE(prefetch_distances.promote, final_dist);
    } else {
        WRITE_ONCE(prefetch_distances.demote, final_dist);
    }

    return final_dist;
}

/*
 * Encode prefetch distances into numa_move_pages flags.
 * Eliminates pwrite() sysfs latency and avoids kernfs lock contention.
 */
int mig_telemetry_get_move_pages_flags(void)
{
    int flags = MPOL_MF_MOVE;
    if (READ_ONCE(prefetch_cfg.enabled)) {
        uint16_t dists = READ_ONCE(prefetch_distances.val);
        flags |= MPOL_MF_PREFETCH_ENABLE | ((uint32_t)dists << MPOL_MF_PREFETCH_PROMOTE_SHIFT);
    }
    return flags;
}

void mig_telemetry_update_pacing(pact_context_t *ctx, struct mig_telemetry *telem,
                                 uint64_t pages_migrated)
{
    if (!telem || !telem->is_initialized) {
        return;
    }

    double t_interval = mig_telemetry_compute_interval(telem, pages_migrated);

    double l_slow, l_fast;
    read_loaded_latency_both_tiers(ctx, &l_slow, &l_fast);

    /* Updates prefetch_promote_distance and prefetch_demote_distance directly */
    get_migration_prefetch_distance(1, l_slow, l_fast, t_interval);
    get_migration_prefetch_distance(0, l_slow, l_fast, t_interval);

    log_debug("mig_telemetry_update_pacing",
              "Pacing : L_slow: %.1f ns, L_fast: %.1f ns, Interval: %.1f ns => "
              "Prefetch: promote=%u, demote=%u",
              l_slow, l_fast, t_interval, prefetch_distances.promote, prefetch_distances.demote);
}