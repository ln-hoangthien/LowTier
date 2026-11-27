/* SPDX-License-Identifier: MIT */
/*
 * Zero-workload-overhead tiered memory time-series, uncore DRAM & AutoNUMA core PMU monitor.
 *
 * Runs pinned to a spare core (Core 28) on slow-tier memory (Node 1):
 * - Uncore DRAM traffic (all baselines, 0% core/CHA conflict):
 *     * uncore_imc_*: UNC_M_CAS_COUNT.RD (0x05/0xcf), WR (0x05/0xf0) [64 B/CAS]
 *     * uncore_upi_*: UNC_UPI_RxL_FLITS.ALL_DATA (0x03/0x0f), TxL (0x02/0x0f) [64/9 B/flit]
 * - Optional AutoNUMA core PMUs (--core-cpus, start/stop only, verified 0% mux on SPR):
 *     * Fixed 0/1 : instructions:u, cycles:u
 *     * PMC4-7    : longest_lat_cache.miss:u (0x412e), longest_lat_cache.reference:u (0x4f2e)
 *     * PMC0-3    : l2_rqsts.swpf_hit:k (0xc824), swpf_miss:k (0x2824),
 *                   all_hwpf:k (0xf024), l1d_pend_miss.fb_full:k (0x0248)
 * - Samples /proc/vmstat (+ /proc/perfnomad) and uncore DRAM traffic into a CSV with
 *   zero forks and zero heap allocations in the loop.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <linux/perf_event.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define MAX_UNCORE_PMUS 64
#define MAX_CORE_CPUS   64
#define NR_CORE_EVENTS  8

/* Sapphire Rapids uncore IMC & UPI raw event configs (event: bits 0-7, umask: bits 8-15) */
#define SPR_IMC_CAS_RD_CFG  0xcf05ULL  /* UNC_M_CAS_COUNT.RD         (64 B/CAS)   */
#define SPR_IMC_CAS_WR_CFG  0xf005ULL  /* UNC_M_CAS_COUNT.WR         (64 B/CAS)   */
#define SPR_UPI_RXL_CFG     0x0f03ULL  /* UNC_UPI_RxL_FLITS.ALL_DATA (64/9 B)     */
#define SPR_UPI_TXL_CFG     0x0f02ULL  /* UNC_UPI_TxL_FLITS.ALL_DATA (64/9 B)     */

typedef struct {
    const char *key;
    uint32_t type;
    uint64_t config;
    int is_kernel; /* 0 = user-only (:u), 1 = kernel-only (:k) */
} core_ev_spec_t;

static const core_ev_spec_t k_core_events[NR_CORE_EVENTS] = {
    { "CORE_USER_INST",      PERF_TYPE_HARDWARE, PERF_COUNT_HW_INSTRUCTIONS, 0 },
    { "CORE_USER_CYCLES",    PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES,   0 },
    { "CORE_USER_LLC_MISS",  PERF_TYPE_RAW,      0x412eULL,                  0 },
    { "CORE_USER_LLC_REF",   PERF_TYPE_RAW,      0x4f2eULL,                  0 },
    { "CORE_KERN_SWPF_HIT",  PERF_TYPE_RAW,      0xc824ULL,                  1 },
    { "CORE_KERN_SWPF_MISS", PERF_TYPE_RAW,      0x2824ULL,                  1 },
    { "CORE_KERN_ALL_HWPF",  PERF_TYPE_RAW,      0xf024ULL,                  1 },
    { "CORE_KERN_FB_FULL",   PERF_TYPE_RAW,      0x0248ULL,                  1 },
};

static volatile sig_atomic_t g_stop = 0;

static void handle_sig(int sig) {
    (void)sig;
    g_stop = 1;
}

typedef struct {
    uint64_t value;
    uint64_t time_enabled;
    uint64_t time_running;
} perf_sample_t;

typedef struct {
    int fd;
    perf_sample_t start;
    perf_sample_t prev;
} pmu_counter_t;

typedef struct {
    pmu_counter_t rd;
    pmu_counter_t wr;
} pmu_pair_t;

typedef struct {
    pmu_pair_t items[MAX_UNCORE_PMUS];
    int count;
} pmu_group_t;

typedef struct {
    pmu_group_t imc;
    pmu_group_t upi;
} uncore_mon_t;

typedef struct {
    int cpu_start;
    int nr_cpus;
    int nr_open;
    pmu_counter_t ctr[MAX_CORE_CPUS][NR_CORE_EVENTS];
} core_mon_t;

typedef struct {
    uint64_t pgmigrate;
    uint64_t promoted;
    uint64_t demoted;
    uint64_t mig_wait_cnt;
    uint64_t mig_wait_us;
    uint64_t mig_wait_huge_cnt;
    uint64_t mig_wait_huge_us;
    uint64_t mig_copy_ns;
} vm_snap_t;

static inline uint64_t u64_rate(uint64_t cur, uint64_t prev, uint64_t sec) {
    return (cur >= prev) ? ((cur - prev) / sec) : 0;
}

static inline double calc_pct(double num, double den) {
    return (den > 0.0) ? (num * 100.0 / den) : 0.0;
}

static int read_int_file(const char *path, int *out) {
    FILE *fp = fopen(path, "r");
    if (!fp)
        return -1;
    int val = 0;
    int ok = (fscanf(fp, "%d", &val) == 1);
    fclose(fp);
    if (!ok)
        return -1;
    *out = val;
    return 0;
}

static int read_counter(int fd, perf_sample_t *out) {
    if (fd < 0)
        return -1;
    perf_sample_t s;
    if (read(fd, &s, sizeof(s)) != (ssize_t)sizeof(s))
        return -1;
    *out = s;
    return 0;
}

static void pmu_counter_open(pmu_counter_t *c, uint32_t type, int cpu,
                             uint64_t config, int excl_user, int excl_kern) {
    struct perf_event_attr pe;
    memset(&pe, 0, sizeof(pe));
    pe.size = sizeof(pe);
    pe.type = type;
    pe.config = config;
    pe.exclude_user = excl_user ? 1 : 0;
    pe.exclude_kernel = excl_kern ? 1 : 0;
    pe.exclude_hv = (excl_user || excl_kern) ? 1 : 0;
    pe.read_format = PERF_FORMAT_TOTAL_TIME_ENABLED | PERF_FORMAT_TOTAL_TIME_RUNNING;

    memset(c, 0, sizeof(*c));
    c->fd = (int)syscall(__NR_perf_event_open, &pe, -1, cpu, -1, PERF_FLAG_FD_CLOEXEC);
    if (c->fd >= 0 && read_counter(c->fd, &c->start) == 0)
        c->prev = c->start;
}

static uint64_t pmu_counter_delta(pmu_counter_t *c, int from_start, double *out_run_pct) {
    perf_sample_t cur;
    if (read_counter(c->fd, &cur) != 0)
        return 0;
    const perf_sample_t *ref = from_start ? &c->start : &c->prev;
    uint64_t dv = (cur.value >= ref->value) ? (cur.value - ref->value) : 0;
    uint64_t de = (cur.time_enabled >= ref->time_enabled) ? (cur.time_enabled - ref->time_enabled) : 0;
    uint64_t dr = (cur.time_running >= ref->time_running) ? (cur.time_running - ref->time_running) : 0;
    if (!from_start)
        c->prev = cur;
    if (out_run_pct && de > 0) {
        double pct = (double)dr * 100.0 / (double)de;
        if (pct < *out_run_pct)
            *out_run_pct = pct;
    }
    return (dr > 0 && de > dr) ? (uint64_t)((double)dv * ((double)de / (double)dr)) : dv;
}

static void pmu_group_add(pmu_group_t *g, int pmu_type, int cpu, uint64_t rd_cfg, uint64_t wr_cfg) {
    if (g->count >= MAX_UNCORE_PMUS)
        return;
    pmu_pair_t p;
    pmu_counter_open(&p.rd, (uint32_t)pmu_type, cpu, rd_cfg, 0, 0);
    pmu_counter_open(&p.wr, (uint32_t)pmu_type, cpu, wr_cfg, 0, 0);
    if (p.rd.fd >= 0 || p.wr.fd >= 0)
        g->items[g->count++] = p;
}

static void pmu_group_sample(pmu_group_t *g, int from_start, uint64_t *rd_sum, uint64_t *wr_sum) {
    uint64_t r = 0, w = 0;
    for (int i = 0; i < g->count; i++) {
        r += pmu_counter_delta(&g->items[i].rd, from_start, NULL);
        w += pmu_counter_delta(&g->items[i].wr, from_start, NULL);
    }
    *rd_sum = r;
    *wr_sum = w;
}

static void pmu_group_close(pmu_group_t *g) {
    for (int i = 0; i < g->count; i++) {
        if (g->items[i].rd.fd >= 0) close(g->items[i].rd.fd);
        if (g->items[i].wr.fd >= 0) close(g->items[i].wr.fd);
    }
}

static int is_indexed_pmu(const char *name, const char *prefix) {
    size_t plen = strlen(prefix);
    if (strncmp(name, prefix, plen) != 0 || name[plen] == '\0')
        return 0;
    for (const char *p = name + plen; *p; p++) {
        if (!isdigit((unsigned char)*p))
            return 0;
    }
    return 1;
}

static void uncore_mon_scan(uncore_mon_t *m, const char *imc_pfx, const char *upi_pfx) {
    DIR *dir = opendir("/sys/bus/event_source/devices");
    if (!dir)
        return;

    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        int is_imc = is_indexed_pmu(ent->d_name, imc_pfx);
        int is_upi = is_indexed_pmu(ent->d_name, upi_pfx);
        if (!is_imc && !is_upi)
            continue;

        char path[512];
        int pmu_type = -1, cpu = 0;
        snprintf(path, sizeof(path), "/sys/bus/event_source/devices/%s/type", ent->d_name);
        if (read_int_file(path, &pmu_type) != 0 || pmu_type < 0)
            continue;

        snprintf(path, sizeof(path), "/sys/bus/event_source/devices/%s/cpumask", ent->d_name);
        if (read_int_file(path, &cpu) != 0 || cpu < 0)
            cpu = 0;

        if (is_imc)
            pmu_group_add(&m->imc, pmu_type, cpu, SPR_IMC_CAS_RD_CFG, SPR_IMC_CAS_WR_CFG);
        else
            pmu_group_add(&m->upi, pmu_type, cpu, SPR_UPI_RXL_CFG, SPR_UPI_TXL_CFG);
    }
    closedir(dir);
}

static void uncore_mon_init(uncore_mon_t *m) {
    memset(m, 0, sizeof(*m));
    uncore_mon_scan(m, "uncore_imc_", "uncore_upi_");
    /* Fallback for pre-5.18 kernels (e.g. 5.13-rc6 Nomad) using SPR discovery type IDs */
    if (m->imc.count == 0 && m->upi.count == 0)
        uncore_mon_scan(m, "uncore_type_6_", "uncore_type_8_");
}

static void uncore_mon_sample_bytes(uncore_mon_t *m, int from_start,
                                    uint64_t *n0_rd, uint64_t *n0_wr,
                                    uint64_t *n1_rd, uint64_t *n1_wr) {
    uint64_t imc_rd = 0, imc_wr = 0, upi_rx = 0, upi_tx = 0;
    pmu_group_sample(&m->imc, from_start, &imc_rd, &imc_wr);
    pmu_group_sample(&m->upi, from_start, &upi_rx, &upi_tx);
    *n0_rd = (uint64_t)((__uint128_t)imc_rd * 64ULL);
    *n0_wr = (uint64_t)((__uint128_t)imc_wr * 64ULL);
    *n1_rd = (uint64_t)(((__uint128_t)upi_rx * 64ULL) / 9ULL);
    *n1_wr = (uint64_t)(((__uint128_t)upi_tx * 64ULL) / 9ULL);
}

static void core_mon_init(core_mon_t *cm, const char *cpu_range) {
    memset(cm, 0, sizeof(*cm));
    if (!cpu_range || !cpu_range[0])
        return;

    int start = -1, end = -1;
    if (sscanf(cpu_range, "%d-%d", &start, &end) != 2) {
        if (sscanf(cpu_range, "%d", &start) != 1)
            return;
        end = start;
    }
    if (start < 0 || end < start)
        return;

    int nr = end - start + 1;
    if (nr > MAX_CORE_CPUS)
        nr = MAX_CORE_CPUS;
    cm->cpu_start = start;
    cm->nr_cpus = nr;

    for (int i = 0; i < nr; i++) {
        for (int e = 0; e < NR_CORE_EVENTS; e++) {
            const core_ev_spec_t *ev = &k_core_events[e];
            pmu_counter_open(&cm->ctr[i][e], ev->type, start + i, ev->config,
                             ev->is_kernel, !ev->is_kernel);
            if (cm->ctr[i][e].fd >= 0)
                cm->nr_open++;
        }
    }
}

static void core_mon_sample_totals(core_mon_t *cm, uint64_t totals[NR_CORE_EVENTS],
                                   double *min_run_pct) {
    memset(totals, 0, sizeof(uint64_t) * NR_CORE_EVENTS);
    *min_run_pct = 0.0;
    if (cm->nr_open == 0)
        return;

    double min_pct = 100.0;
    for (int i = 0; i < cm->nr_cpus; i++) {
        for (int e = 0; e < NR_CORE_EVENTS; e++)
            totals[e] += pmu_counter_delta(&cm->ctr[i][e], 1, &min_pct);
    }
    *min_run_pct = min_pct;
}

static void core_mon_close(core_mon_t *cm) {
    for (int i = 0; i < cm->nr_cpus; i++) {
        for (int e = 0; e < NR_CORE_EVENTS; e++) {
            if (cm->ctr[i][e].fd >= 0)
                close(cm->ctr[i][e].fd);
        }
    }
}

static uint64_t parse_kv_u64(const char *buf, const char *key) {
    size_t klen = strlen(key);
    for (const char *p = buf; *p; ) {
        if (strncmp(p, key, klen) == 0 && (p[klen] == ' ' || p[klen] == '\t')) {
            const char *v = p + klen;
            while (*v == ' ' || *v == '\t')
                v++;
            return strtoull(v, NULL, 10);
        }
        const char *nl = strchr(p, '\n');
        if (!nl)
            break;
        p = nl + 1;
    }
    return 0;
}

static ssize_t read_entire_proc(int fd, char *buf, size_t cap) {
    if (fd < 0 || cap < 2 || lseek(fd, 0, SEEK_SET) < 0)
        return -1;
    size_t off = 0;
    while (off < cap - 1) {
        ssize_t n = read(fd, buf + off, cap - 1 - off);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (n == 0)
            break;
        off += (size_t)n;
    }
    buf[off] = '\0';
    return (ssize_t)off;
}

static int read_vm_snapshot(int fd_vmstat, int fd_perfnomad, vm_snap_t *out) {
    static char vmbuf[32768];
    static char pnbuf[4096];

    if (read_entire_proc(fd_vmstat, vmbuf, sizeof(vmbuf)) <= 0)
        return -1;

    memset(out, 0, sizeof(*out));
    out->pgmigrate         = parse_kv_u64(vmbuf, "pgmigrate_success");
    out->mig_wait_cnt      = parse_kv_u64(vmbuf, "mig_wait_count");
    out->mig_wait_us       = parse_kv_u64(vmbuf, "mig_wait_us");
    out->mig_wait_huge_cnt = parse_kv_u64(vmbuf, "mig_wait_huge_count");
    out->mig_wait_huge_us  = parse_kv_u64(vmbuf, "mig_wait_huge_us");
    out->mig_copy_ns       = parse_kv_u64(vmbuf, "mig_copy_ns");

    uint64_t htmm_prom = parse_kv_u64(vmbuf, "htmm_nr_promoted");
    uint64_t htmm_dem  = parse_kv_u64(vmbuf, "htmm_nr_demoted");
    int is_htmm = (htmm_prom > 0 || htmm_dem > 0);

    if (fd_perfnomad >= 0 && read_entire_proc(fd_perfnomad, pnbuf, sizeof(pnbuf)) > 0)
        out->promoted = parse_kv_u64(pnbuf, "success_nr");
    else if (is_htmm)
        out->promoted = htmm_prom;
    else
        out->promoted = parse_kv_u64(vmbuf, "pgpromote_anon") + parse_kv_u64(vmbuf, "pgpromote_file");

    if (is_htmm) {
        out->demoted = htmm_dem;
    } else {
        uint64_t d = parse_kv_u64(vmbuf, "pgdemote_kswapd") + parse_kv_u64(vmbuf, "pgdemote_direct");
        if (d == 0)
            d = parse_kv_u64(vmbuf, "pgdemote_anon") + parse_kv_u64(vmbuf, "pgdemote_file");
        out->demoted = d;
    }
    return 0;
}

static uint64_t now_monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)(ts.tv_nsec / 1000000L);
}

static void write_summary_file(const char *path, const uncore_mon_t *mon,
                               uint64_t n0_rd, uint64_t n0_wr,
                               uint64_t n1_rd, uint64_t n1_wr,
                               uint64_t elapsed_ms,
                               const core_mon_t *cm,
                               const uint64_t core_tot[NR_CORE_EVENTS],
                               double core_run_pct) {
    if (!path || !path[0])
        return;
    char tmp_path[1024];
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", path);
    FILE *fp = fopen(tmp_path, "w");
    if (!fp)
        return;
    fprintf(fp,
            "UNCORE_IMC_CNT=%d\n"
            "UNCORE_UPI_CNT=%d\n"
            "UNCORE_ELAPSED_MS=%llu\n"
            "NODE0_RD_BYTES=%llu\n"
            "NODE0_WR_BYTES=%llu\n"
            "NODE1_RD_BYTES=%llu\n"
            "NODE1_WR_BYTES=%llu\n",
            mon->imc.count, mon->upi.count,
            (unsigned long long)elapsed_ms,
            (unsigned long long)n0_rd, (unsigned long long)n0_wr,
            (unsigned long long)n1_rd, (unsigned long long)n1_wr);
    if (cm && cm->nr_cpus > 0) {
        fprintf(fp,
                "CORE_PMU_ENABLED=1\n"
                "CORE_PMU_CPUS=\"%d-%d\"\n"
                "CORE_PMU_OPEN_FDS=%d\n"
                "CORE_PMU_RUN_PCT=%.2f\n",
                cm->cpu_start, cm->cpu_start + cm->nr_cpus - 1, cm->nr_open, core_run_pct);
        for (int e = 0; e < NR_CORE_EVENTS; e++)
            fprintf(fp, "%s=%llu\n", k_core_events[e].key, (unsigned long long)core_tot[e]);
    }
    fclose(fp);
    rename(tmp_path, path);
}

int main(int argc, char **argv) {
    const char *csv_path = NULL;
    const char *summary_path = NULL;
    const char *core_cpus = NULL;
    int interval_sec = 1;

    static const struct option long_opts[] = {
        {"csv",       required_argument, 0, 'c'},
        {"summary",   required_argument, 0, 's'},
        {"interval",  required_argument, 0, 'i'},
        {"core-cpus", required_argument, 0, 'p'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "c:s:i:p:", long_opts, NULL)) != -1) {
        switch (opt) {
        case 'c': csv_path = optarg; break;
        case 's': summary_path = optarg; break;
        case 'i': interval_sec = atoi(optarg); break;
        case 'p': core_cpus = optarg; break;
        default: return 1;
        }
    }
    if (interval_sec <= 0)
        interval_sec = 1;

    signal(SIGHUP, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_sig;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    uncore_mon_t umon;
    uncore_mon_init(&umon);

    core_mon_t cmon;
    core_mon_init(&cmon, core_cpus);

    int fd_vmstat = -1, fd_perfnomad = -1;
    FILE *csv_fp = NULL;
    if (csv_path && csv_path[0] && strcmp(csv_path, "-") != 0) {
        csv_fp = fopen(csv_path, "w");
        if (csv_fp) {
            fd_vmstat = open("/proc/vmstat", O_RDONLY | O_CLOEXEC);
            fd_perfnomad = open("/proc/perfnomad", O_RDONLY | O_CLOEXEC);
            fprintf(csv_fp,
                    "t_sec,pgmigrate_s,promoted_s,demoted_s,"
                    "mig_wait_cnt_s,mig_wait_us_s,mig_wait_huge_cnt_s,mig_wait_huge_us_s,mig_copy_ns_s,"
                    "node0_rd_mb_s,node0_wr_mb_s,node1_rd_mb_s,node1_wr_mb_s,node0_rd_pct,node0_tot_pct\n");
            fflush(csv_fp);
        }
    }

    vm_snap_t prev_vm = {0}, cur_vm = {0};
    if (fd_vmstat >= 0)
        read_vm_snapshot(fd_vmstat, fd_perfnomad, &prev_vm);

    struct timespec next_wake;
    clock_gettime(CLOCK_MONOTONIC, &next_wake);
    uint64_t start_ms = (uint64_t)next_wake.tv_sec * 1000ULL + (uint64_t)(next_wake.tv_nsec / 1000000L);
    uint64_t prev_ms = start_ms;

    if (!csv_fp) {
        sigset_t mask, oldmask;
        sigemptyset(&mask);
        sigaddset(&mask, SIGTERM);
        sigaddset(&mask, SIGINT);
        sigprocmask(SIG_BLOCK, &mask, &oldmask);
        while (!g_stop)
            sigsuspend(&oldmask);
        sigprocmask(SIG_SETMASK, &oldmask, NULL);
    } else {
        uint64_t t_sec = 0;

        while (!g_stop) {
            next_wake.tv_sec += interval_sec;
            while (!g_stop) {
                int rc = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next_wake, NULL);
                if (rc == 0 || g_stop || rc != EINTR)
                    break;
            }
            if (g_stop)
                break;

            uint64_t cur_ms = now_monotonic_ms();
            double dt_sec = (cur_ms > prev_ms) ? ((double)(cur_ms - prev_ms) / 1000.0) : (double)interval_sec;
            prev_ms = cur_ms;
            t_sec += (uint64_t)interval_sec;

            uint64_t d_mig = 0, d_prom = 0, d_dem = 0, d_wc = 0, d_wu = 0, d_whc = 0, d_whu = 0, d_cns = 0;
            if (fd_vmstat >= 0 && read_vm_snapshot(fd_vmstat, fd_perfnomad, &cur_vm) == 0) {
                uint64_t iv = (uint64_t)interval_sec;
                d_mig  = u64_rate(cur_vm.pgmigrate, prev_vm.pgmigrate, iv);
                d_prom = u64_rate(cur_vm.promoted, prev_vm.promoted, iv);
                d_dem  = u64_rate(cur_vm.demoted, prev_vm.demoted, iv);
                d_wc   = u64_rate(cur_vm.mig_wait_cnt, prev_vm.mig_wait_cnt, iv);
                d_wu   = u64_rate(cur_vm.mig_wait_us, prev_vm.mig_wait_us, iv);
                d_whc  = u64_rate(cur_vm.mig_wait_huge_cnt, prev_vm.mig_wait_huge_cnt, iv);
                d_whu  = u64_rate(cur_vm.mig_wait_huge_us, prev_vm.mig_wait_huge_us, iv);
                d_cns  = u64_rate(cur_vm.mig_copy_ns, prev_vm.mig_copy_ns, iv);
                prev_vm = cur_vm;
            }

            uint64_t n0_rd = 0, n0_wr = 0, n1_rd = 0, n1_wr = 0;
            uncore_mon_sample_bytes(&umon, 0, &n0_rd, &n0_wr, &n1_rd, &n1_wr);

            double mb_den = 1048576.0 * dt_sec;
            fprintf(csv_fp,
                    "%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f\n",
                    (unsigned long long)t_sec,
                    (unsigned long long)d_mig, (unsigned long long)d_prom, (unsigned long long)d_dem,
                    (unsigned long long)d_wc, (unsigned long long)d_wu,
                    (unsigned long long)d_whc, (unsigned long long)d_whu,
                    (unsigned long long)d_cns,
                    (double)n0_rd / mb_den, (double)n0_wr / mb_den,
                    (double)n1_rd / mb_den, (double)n1_wr / mb_den,
                    calc_pct((double)n0_rd, (double)(n0_rd + n1_rd)),
                    calc_pct((double)(n0_rd + n0_wr), (double)(n0_rd + n0_wr + n1_rd + n1_wr)));
            fflush(csv_fp);
        }
    }

    uint64_t end_ms = now_monotonic_ms();
    uint64_t tot_n0_rd = 0, tot_n0_wr = 0, tot_n1_rd = 0, tot_n1_wr = 0;
    uint64_t core_tot[NR_CORE_EVENTS] = {0};
    double core_run_pct = 0.0;
    uncore_mon_sample_bytes(&umon, 1, &tot_n0_rd, &tot_n0_wr, &tot_n1_rd, &tot_n1_wr);
    core_mon_sample_totals(&cmon, core_tot, &core_run_pct);
    write_summary_file(summary_path, &umon, tot_n0_rd, tot_n0_wr, tot_n1_rd, tot_n1_wr,
                       (end_ms > start_ms) ? (end_ms - start_ms) : 0,
                       &cmon, core_tot, core_run_pct);

    if (csv_fp) fclose(csv_fp);
    if (fd_vmstat >= 0) close(fd_vmstat);
    if (fd_perfnomad >= 0) close(fd_perfnomad);
    core_mon_close(&cmon);
    pmu_group_close(&umon.imc);
    pmu_group_close(&umon.upi);
    return 0;
}
