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
#include <math.h>
#include <errno.h>
#include <sched.h>
#include <fcntl.h>
#include <time.h>
#include <sys/types.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <linux/perf_event.h>

#include "pmu.h"
#include "pact.h"
#include "error.h"
#include "mig_telemetry.h"

/* =========================================================================
 * Thread-Scoped PMU Telemetry and CPU Pinning for Migration Pacing
 * ========================================================================= */

static unsigned int prefetch_enabled = 1;
static unsigned int prefetch_adaptive = 1;
static unsigned int prefetch_promote_distance = PREFETCH_DEFAULT_PROMOTE_DISTANCE;
static unsigned int prefetch_demote_distance = PREFETCH_DEFAULT_DEMOTE_DISTANCE;
static unsigned int prefetch_min_distance = PREFETCH_DEFAULT_MIN_DISTANCE;
static unsigned int prefetch_max_distance = PREFETCH_DEFAULT_MAX_DISTANCE;
static bool thp_always = false;

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

    prefetch_enabled = read_prefetch_sysfs_uint("enabled", 1);
    prefetch_adaptive = read_prefetch_sysfs_uint("adaptive", 1);
    prefetch_min_distance = read_prefetch_sysfs_uint("min_distance", PREFETCH_DEFAULT_MIN_DISTANCE);
    prefetch_max_distance = read_prefetch_sysfs_uint("max_distance", PREFETCH_DEFAULT_MAX_DISTANCE);
    prefetch_promote_distance =
        read_prefetch_sysfs_uint("promote_distance", PREFETCH_DEFAULT_PROMOTE_DISTANCE);
    prefetch_demote_distance =
        read_prefetch_sysfs_uint("demote_distance", PREFETCH_DEFAULT_DEMOTE_DISTANCE);

    if (prefetch_enabled == 0) {
        prefetch_adaptive = 0;
        prefetch_promote_distance = 0;
        prefetch_demote_distance = 0;
    }

    /*
     * Configure baseline cachelines_per_page based on /sys/kernel/mm/transparent_hugepage/:
     * - Only when enabled is [always] AND defrag is [always] are 2MB pages synchronously guaranteed.
     * - If defrag is [defer] (or THP is madvise/never), 2MB pages can split into 4KB pages
     *   or fall back to 4KB on allocation, so default baseline to 64ULL.
     * Note: Per-batch heterogeneous mixture decomposition in mig_telemetry_compute_interval
     * dynamically handles runtime mixtures of 4KB and 2MB pages.
     */
    thp_always = false;
    int fd_thp = open("/sys/kernel/mm/transparent_hugepage/enabled", O_RDONLY | O_CLOEXEC);
    if (fd_thp >= 0) {
        char thp_buf[64] = {0};
        if (read(fd_thp, thp_buf, sizeof(thp_buf) - 1) > 0) {
            if (strstr(thp_buf, "[always]") != NULL || strcmp(thp_buf, "always\n") == 0 ||
                strcmp(thp_buf, "always") == 0) {
                thp_always = true;
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
             sysfs_dir ? sysfs_dir : "N/A", prefetch_enabled, prefetch_adaptive,
             prefetch_promote_distance, prefetch_demote_distance, prefetch_min_distance,
             prefetch_max_distance,
             thp_always ? (defrag_always ? "THP enabled" : "THP enabled (defrag defer)")
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

    /*
     * If THP is turned off (madvise or never), no 2MB pages can exist; n_2m is strictly 0.
     * Only when THP is enabled as [always] do we solve for the number of 2MB pages in the batch.
     */
    double n_2m = 0.0;
    if (thp_always) {
        n_2m = (uops_total - p_total * UOPS_PER_4KB) / (UOPS_PER_2MB - UOPS_PER_4KB);
        n_2m = clamp(n_2m, 0.0, p_total);
    }
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

double read_loaded_latency_tier_ns(pact_context_t *ctx, bool is_slow_tier)
{
    static double s_smoothed_lat_slow_ns =
        190.0; /* Initial calibrated baseline (~771 cyc / 2.4 GHz) */
    static double s_smoothed_lat_fast_ns = 80.0; /* Initial calibrated local DRAM baseline */

    double *p_lat = is_slow_tier ? &s_smoothed_lat_slow_ns : &s_smoothed_lat_fast_ns;

    /* Native PACT CHA TOR Dynamic Measurement (Little's Law) */
    if (ctx && ctx->workload && ctx->workload->nr_cha > 0) {
        pact_workload_t *wl = ctx->workload;
        uint64_t sum_occupancy = 0;
        uint64_t sum_inserts = 0;
        int valid_chas = 0;

        for (int i = 0; i < wl->nr_cha; i++) {
            event_group_t *g =
                is_slow_tier ? &wl->cha_pmus[i].group_slow : &wl->cha_pmus[i].group_fast;
            if (g->time_running - g->last_time_running >= 1000000) {
                sum_occupancy += g->values[CHA_TOR_OCCUPANCY];
                sum_inserts += g->values[CHA_TOR_INSERTS];
                valid_chas++;
            }
        }

        double core_freq_ghz =
            (ctx->tsc_freq_hz > 0) ? ((double)ctx->tsc_freq_hz / 1e9) : DEFAULT_CORE_FREQ_GHZ;

        /* Little's Law: Average Latency = TOR_OCCUPANCY / TOR_INSERTS */
        if (valid_chas > 0 && sum_inserts >= 16 && sum_occupancy > 0) {
            double dwell_time_uncore_cyc = (double)sum_occupancy / (double)sum_inserts;
            *p_lat = dwell_time_uncore_cyc / core_freq_ghz;
        }
    }

    return *p_lat;
}

unsigned int get_migration_prefetch_distance(int source_id, double l_slow_ns, double l_fast_ns,
                                             double interval_ns)
{
    bool is_promote = is_tiered_promotion(source_id);

    /* Return default distance if adaptive prefetching is disabled */
    if (!READ_ONCE(prefetch_adaptive)) {
        return is_promote ? READ_ONCE(prefetch_promote_distance)
                          : READ_ONCE(prefetch_demote_distance);
    }

    unsigned int min_dist = READ_ONCE(prefetch_min_distance);
    unsigned int max_dist = READ_ONCE(prefetch_max_distance);
    if (min_dist > max_dist) {
        min_dist = max_dist;
    }

    static unsigned int s_promote_ema = 0;
    static unsigned int s_demote_ema = 0;
    unsigned int *p_ema = is_promote ? &s_promote_ema : &s_demote_ema;

    /* Primary source-tier latency used for Little's Law pacing */
    double primary_latency_ns = is_promote ? l_slow_ns : l_fast_ns;

    unsigned int effective_min_dist = min_dist;
    unsigned int raw_dist = 0;
    unsigned int final_dist = 0;

    /* 
     * Global Saturation Check:
     * Trigger shutdown if Slow tier breaches SLOW threshold OR Fast tier breaches FAST threshold.
     */
    bool is_slow_saturated = (l_slow_ns > PREFETCH_LATENCY_SLOW_THRESHOLD_NS);
    bool is_fast_saturated = (l_fast_ns > PREFETCH_LATENCY_FAST_THRESHOLD_NS);
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
            /* Pacing via Little's Law using the read-source tier's latency */
            double calculated_dist = primary_latency_ns / interval_ns;
            raw_dist = (unsigned int)round(calculated_dist);
        }

        /* Clamp raw_dist */
        raw_dist = clamp(raw_dist, effective_min_dist, max_dist);

        if (!ema_dist) {
            ema_dist = raw_dist;
        } else {
            ema_dist = (alpha * raw_dist + (100 - alpha) * ema_dist + 50) / 100;
        }

        ema_dist = clamp(ema_dist, effective_min_dist, max_dist);
        *p_ema = ema_dist;
        final_dist = ema_dist;
    } else if (*p_ema == 0) {
        log_warning("get_migration_prefetch_distance", "Fallback to default distance for %s.",
                    is_promote ? "Promotion" : "Demotion");
        *p_ema = is_promote ? PREFETCH_DEFAULT_PROMOTE_DISTANCE : PREFETCH_DEFAULT_DEMOTE_DISTANCE;
        final_dist = *p_ema;
    } else {
        final_dist = *p_ema;
    }

    final_dist = clamp(final_dist, effective_min_dist, max_dist);

    log_debug("get_migration_prefetch_distance",
              "%s : raw_dist: %u, ema_dist: %u (alpha: %d), final_dist: %u",
              is_promote ? "Promotion" : "Demotion", raw_dist, *p_ema, alpha, final_dist);

    if (is_promote) {
        prefetch_promote_distance = final_dist;
    } else {
        prefetch_demote_distance = final_dist;
    }

    return final_dist;
}

int write_sysfs_distances(unsigned int dist_promote, unsigned int dist_demote, double lat_slow_ns,
                          double lat_fast_ns, double interval_ns)
{
    static int fd_promote = -2;
    static int fd_demote = -2;
    static unsigned int last_promote = (unsigned int)-1;
    static unsigned int last_demote = (unsigned int)-1;
    static time_t last_log_time = 0;
    time_t now = time(NULL);
    char buf[16];

    unsigned int final_promote = dist_promote;
    unsigned int final_demote = dist_demote;

    /* Log status if distance changed or periodically (~1Hz) */
    if (final_promote != last_promote || final_demote != last_demote || now - last_log_time >= 1) {
        last_log_time = now;
        log_debug("write_sysfs_distances",
                  "Status: lat_slow=%.1f ns, lat_fast=%.1f ns, interval=%.2f ns, dist_promote=%u, "
                  "dist_demote=%u",
                  lat_slow_ns, lat_fast_ns, interval_ns, final_promote, final_demote);
    }

    if (!prefetch_adaptive) {
        return 0;
    }

    /* 1. Update promote_distance sysfs (allow 0 to be written if it changes from non-zero) */
    if (final_promote != last_promote) {
        if (__builtin_expect(fd_promote == -2, 0)) {
            const char *dir = get_prefetch_sysfs_dir();
            if (dir) {
                char path[128];
                snprintf(path, sizeof(path), "%s/promote_distance", dir);
                fd_promote = open(path, O_WRONLY | O_CLOEXEC);
            } else {
                fd_promote = -1;
            }
        }
        if (fd_promote >= 0) {
            int len = snprintf(buf, sizeof(buf), "%u\n", final_promote);
            if (len > 0 && pwrite(fd_promote, buf, (size_t)len, 0) > 0) {
                last_promote = final_promote;
            }
        }
    }

    /* 2. Update demote_distance sysfs (allow 0 to be written if it changes from non-zero) */
    if (final_demote != last_demote) {
        if (__builtin_expect(fd_demote == -2, 0)) {
            const char *dir = get_prefetch_sysfs_dir();
            if (dir) {
                char path[128];
                snprintf(path, sizeof(path), "%s/demote_distance", dir);
                fd_demote = open(path, O_WRONLY | O_CLOEXEC);
            } else {
                fd_demote = -1;
            }
        }
        if (fd_demote >= 0) {
            int len = snprintf(buf, sizeof(buf), "%u\n", final_demote);
            if (len > 0 && pwrite(fd_demote, buf, (size_t)len, 0) > 0) {
                last_demote = final_demote;
            }
        }
    }

    return 0;
}

void mig_telemetry_update_pacing(pact_context_t *ctx, struct mig_telemetry *telem,
                                 uint64_t pages_migrated)
{
    if (!telem || !telem->is_initialized) {
        return;
    }

    double t_interval = mig_telemetry_compute_interval(telem, pages_migrated);

    double l_slow = read_loaded_latency_tier_ns(ctx, true);
    double l_fast = read_loaded_latency_tier_ns(ctx, false);

    unsigned int dist_promote = get_migration_prefetch_distance(1, l_slow, l_fast, t_interval);
    unsigned int dist_demote = get_migration_prefetch_distance(0, l_slow, l_fast, t_interval);

    write_sysfs_distances(dist_promote, dist_demote, l_slow, l_fast, t_interval);
}