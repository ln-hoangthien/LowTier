/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 MoatLab, Virginia Tech. */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#include "logging.h"
#include "mig_telemetry.h"

__attribute__((weak)) int g_verbose = 0;

static const char *s_sysfs_dir = NULL;

/* Locate and return the active kernel page_prefetch sysfs directory path. */
static const char *get_sysfs_dir(void) {
  if (s_sysfs_dir)
    return s_sysfs_dir;
  if (access("/sys/kernel/mm/page_prefetch", F_OK) == 0) {
    s_sysfs_dir = "/sys/kernel/mm/page_prefetch";
  } else if (access("/sys/kernel/mm/pact_prefetch", F_OK) == 0) {
    s_sysfs_dir = "/sys/kernel/mm/pact_prefetch";
  }
  return s_sysfs_dir;
}

/* Read an unsigned integer attribute from the kernel prefetch sysfs interface.
 */
static unsigned int read_sysfs_uint(const char *attr,
                                    unsigned int default_val) {
  const char *dir = get_sysfs_dir();
  if (!dir)
    return default_val;

  char path[256];
  snprintf(path, sizeof(path), "%s/%s", dir, attr);
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0)
    return default_val;

  char buf[32] = {0};
  unsigned int val = default_val;
  if (read(fd, buf, sizeof(buf) - 1) > 0) {
    int parsed = atoi(buf);
    if (parsed >= 0)
      val = (unsigned int)parsed;
  }
  close(fd);
  return val;
}

static int s_fd_promote = -1;
static int s_fd_demote = -1;
static prefetch_sysfs_cfg_t s_cfg;
static bool s_cfg_initialized = false;
static bool s_last_enabled = true;
static uint16_t s_ema_promote = 0;
static uint16_t s_ema_demote = 0;
static bool s_ema_initialized = false;
static time_t s_last_attach_check = 0;
static time_t s_last_cfg_refresh = 0;

/* Write an unsigned integer value to a kernel prefetch sysfs attribute via
 * cached fd. Returns true on success. */
static bool write_sysfs_cached_fd(int *pfd, const char *attr,
                                  unsigned int val) {
  if (*pfd < 0) {
    const char *dir = get_sysfs_dir();
    if (!dir)
      return false;
    char path[256];
    snprintf(path, sizeof(path), "%s/%s", dir, attr);
    *pfd = open(path, O_WRONLY | O_CLOEXEC);
    if (*pfd < 0) {
      mig_log_error("write_sysfs_cached_fd", "Failed to open %s: %s", path,
                    strerror(errno));
      return false;
    }
  }

  char buf[32];
  int len = snprintf(buf, sizeof(buf), "%u\n", val);
  if (len <= 0)
    return false;

  lseek(*pfd, 0, SEEK_SET);
  if (write(*pfd, buf, (size_t)len) < 0) {
    mig_log_error("write_sysfs_cached_fd", "Failed to write %u to %s: %s", val,
                  attr, strerror(errno));
    close(*pfd);
    *pfd = -1;
    return false;
  }
  return true;
}

static bool node_has_online_cpus(int nid) {
  if (nid < 0)
    return false;
  char path[96];
  snprintf(path, sizeof(path), "/sys/devices/system/node/node%d/cpulist", nid);
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0)
    return true; /* Fallback if sysfs node topology is unavailable */
  char buf[64] = {0};
  ssize_t n = read(fd, buf, sizeof(buf) - 1);
  close(fd);
  if (n <= 0)
    return false;
  for (ssize_t i = 0; i < n; i++) {
    if (buf[i] >= '0' && buf[i] <= '9')
      return true;
  }
  return false;
}

static bool match_comm(const char *comm, const char *target) {
  if (!comm || !target)
    return false;
  if (strcmp(target, "kswapd") == 0) {
    if (strncmp(comm, "kswapd", 6) != 0)
      return false;
    /* Only monitor kswapd on top-tier (CPU-bearing) nodes, since slow-tier
     * kswapd reclaims without demoting and would not increment pgdemote_kswapd. */
    if (comm[6] >= '0' && comm[6] <= '9') {
      return node_has_online_cpus(atoi(comm + 6));
    }
    return true;
  }
  if (strcmp(target, "kmigraterd") == 0)
    return strncmp(comm, "kmigraterd", 10) == 0;
  if (strcmp(target, "kmig") == 0)
    return strncmp(comm, "kmig", 4) == 0;
  if (strcmp(target, "async_promote") == 0)
    return strncmp(comm, "async_promote", 13) == 0;
  return strcmp(comm, target) == 0;
}

static int collect_child_tids(pid_t pid, pid_t *out_tids, int max_tids) {
  char task_dir[64];
  snprintf(task_dir, sizeof(task_dir), "/proc/%d/task", pid);
  DIR *dir = opendir(task_dir);
  if (!dir)
    return 0;

  int count = 0;
  struct dirent *ent;
  while ((ent = readdir(dir)) != NULL && count < max_tids) {
    if (ent->d_name[0] < '0' || ent->d_name[0] > '9')
      continue;
    pid_t tid = (pid_t)atoi(ent->d_name);
    if (tid > 0 && tid != pid) {
      out_tids[count++] = tid;
    }
  }
  closedir(dir);
  return count;
}

/* Scan /proc to discover all active tiered migration worker threads matching
 * the highest-priority entry in s_migration_threads[]. For multi-node kthreads
 * (e.g., Memtis kmigraterd0 + kmigraterd1), returns every matching worker TID
 * so total CPU_CLK_UNHALTED matches aggregate migration page counters. */
static int find_migration_threads(pid_t *out_tids, int max_tids) {
  if (!out_tids || max_tids <= 0)
    return 0;

  DIR *proc = opendir("/proc");
  if (!proc)
    return 0;

  int best_prio = 999;
  int nr_found = 0;

  struct dirent *ent;
  while ((ent = readdir(proc)) != NULL) {
    if (ent->d_name[0] < '0' || ent->d_name[0] > '9')
      continue;

    pid_t pid = (pid_t)atoi(ent->d_name);
    char comm_path[64];
    snprintf(comm_path, sizeof(comm_path), "/proc/%d/comm", pid);
    int fd = open(comm_path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
      continue;

    char comm[64] = {0};
    ssize_t n = read(fd, comm, sizeof(comm) - 1);
    close(fd);
    if (n <= 0)
      continue;
    comm[strcspn(comm, "\r\n")] = 0;

    for (int i = 0; s_migration_threads[i].name != NULL; i++) {
      if (i > best_prio)
        break; /* Already found a strictly higher-priority class */

      if (match_comm(comm, s_migration_threads[i].name)) {
        pid_t matched[MIG_MAX_WORKERS + 1];
        int nr_matched = 0;

        if (s_migration_threads[i].is_child_thread) {
          nr_matched =
              collect_child_tids(pid, matched, MIG_MAX_WORKERS + 1);
        } else {
          matched[0] = pid;
          nr_matched = 1;
        }

        if (nr_matched > 0) {
          if (i < best_prio) {
            best_prio = i;
            nr_found = 0;
          }
          for (int k = 0; k < nr_matched && nr_found < max_tids; k++) {
            out_tids[nr_found++] = matched[k];
          }
        }
        break;
      }
    }
  }

  closedir(proc);
  return nr_found;
}

static int open_worker_cycles_fd(pid_t tid) {
  struct perf_event_attr pe;
  memset(&pe, 0, sizeof(struct perf_event_attr));
  pe.type = PERF_TYPE_HARDWARE;
  pe.size = sizeof(struct perf_event_attr);
  pe.config = PERF_COUNT_HW_CPU_CYCLES; /* Unhalted core cycles
                                           (CPU_CLK_UNHALTED.THREAD) */
  pe.disabled = 0;                      /* Start counting */
  pe.exclude_kernel = 0; /* Capture kernel migration copy routines */
  pe.exclude_user = 1;   /* Exclude userspace idle spin loops (_mm_pause) */
  pe.inherit = 0;

  return (int)syscall(__NR_perf_event_open, &pe, tid, -1, -1, 0);
}

static void read_tid_comm(pid_t tid, char *buf, size_t buf_sz) {
  if (!buf || buf_sz == 0)
    return;
  buf[0] = '\0';
  char comm_path[64];
  snprintf(comm_path, sizeof(comm_path), "/proc/%d/comm", tid);
  int cfd = open(comm_path, O_RDONLY | O_CLOEXEC);
  if (cfd >= 0) {
    ssize_t n = read(cfd, buf, buf_sz - 1);
    close(cfd);
    if (n > 0) {
      buf[n] = '\0';
      buf[strcspn(buf, "\r\n")] = '\0';
    }
  }
}

static void close_worker_fds(struct mig_telemetry *telem) {
  if (!telem)
    return;
  if (telem->fd_uops >= 0) {
    close(telem->fd_uops);
    telem->fd_uops = -1;
  }
  for (int i = 0; i < telem->nr_extra_workers; i++) {
    if (telem->extra_fds[i] >= 0) {
      close(telem->extra_fds[i]);
      telem->extra_fds[i] = -1;
    }
    telem->extra_tids[i] = -1;
    telem->extra_last_cycles[i] = 0;
  }
  telem->nr_extra_workers = 0;
  telem->has_baseline = false;
  telem->last_raw_uops = 0;
  telem->last_pages_migrated = 0;
  telem->pending_cycles = 0;
  telem->pending_pages = 0;
  telem->pending_idle_steps = 0;
}

/* Explicitly attach hardware CLK_UNHALTED perf event to a specific migration
 * worker TID. */
int mig_telemetry_attach_tid(struct mig_telemetry *telem, pid_t tid) {
  if (!telem || tid <= 0)
    return -EINVAL;

  if (telem->fd_uops >= 0) {
    if (telem->mig_tid == tid)
      return 0; /* Already attached to this TID */
    close_worker_fds(telem);
  }

  int fd = open_worker_cycles_fd(tid);
  if (fd < 0) {
    mig_log_warn(
        "mig_telemetry_attach_tid",
        "Could not open CPU_CYCLES event on migration TID %d (errno %d: %s)",
        tid, errno, strerror(errno));
    return -errno;
  }

  telem->fd_uops = fd;
  telem->mig_tid = tid;
  telem->has_baseline = false;
  telem->last_raw_uops = 0;
  telem->last_pages_migrated = 0;
  telem->pending_cycles = 0;
  telem->pending_pages = 0;
  telem->pending_idle_steps = 0;
  read_tid_comm(tid, telem->mig_comm, sizeof(telem->mig_comm));

  mig_log_info("mig_telemetry_attach_tid",
               "Hardware CLK_UNHALTED telemetry attached to migration worker "
               "(TID: %d [%s], fd: %d)",
               tid, telem->mig_comm[0] ? telem->mig_comm : "unknown", fd);
  return 0;
}

/* Attempt to discover and attach to active migration worker thread(s).
 * Discovery is rate-limited to once every 2 seconds to eliminate /proc
 * overhead. */
bool mig_telemetry_try_attach(struct mig_telemetry *telem) {
  if (!telem || telem->fd_uops >= 0)
    return true;

  if (telem->mig_tid < 0)
    return false; /* Explicitly disabled */

  time_t now = time(NULL);
  if (now - s_last_attach_check < 2) {
    return false;
  }
  s_last_attach_check = now;

  if (telem->mig_tid > 0) {
    return (mig_telemetry_attach_tid(telem, telem->mig_tid) == 0);
  }

  pid_t tids[MIG_MAX_WORKERS + 1];
  int nr_tids = find_migration_threads(tids, MIG_MAX_WORKERS + 1);
  if (nr_tids <= 0)
    return false;

  if (mig_telemetry_attach_tid(telem, tids[0]) != 0)
    return false;

  for (int i = 1; i < nr_tids && telem->nr_extra_workers < MIG_MAX_WORKERS;
       i++) {
    int efd = open_worker_cycles_fd(tids[i]);
    if (efd >= 0) {
      int idx = telem->nr_extra_workers++;
      telem->extra_fds[idx] = efd;
      telem->extra_tids[idx] = tids[i];
      telem->extra_last_cycles[idx] = 0;

      char ecomm[32];
      read_tid_comm(tids[i], ecomm, sizeof(ecomm));
      mig_log_info("mig_telemetry_try_attach",
                   "Hardware CLK_UNHALTED telemetry attached to peer migration "
                   "worker (TID: %d [%s], fd: %d)",
                   tids[i], ecomm[0] ? ecomm : "unknown", efd);
    }
  }

  return true;
}

/* Initialize migration telemetry subsystem, core clock frequency, THP mode,
 * CHA PMUs, and migration thread perf events. */
int mig_telemetry_init(struct mig_telemetry *telem, pid_t explicit_mig_tid,
                       uint64_t cpu_mask, int target_cpu) {
  const char *dir = get_sysfs_dir();
  if (!dir) {
    mig_log_warn("mig_telemetry_init",
                 "page_prefetch sysfs not found yet, will retry");
    return -ENOENT;
  }
  mig_log_info("mig_telemetry_init", "Connected to kernel prefetch sysfs: %s",
               dir);

  /* One-time initialization of sysfs config */
  mig_telemetry_init_sysfs(&s_cfg);

  if (telem) {
    memset(telem, 0, sizeof(*telem));
    telem->mig_tid = explicit_mig_tid;
    telem->auto_detect = (explicit_mig_tid == 0);
    telem->fd_uops = -1;
    for (int i = 0; i < MIG_MAX_WORKERS; i++) {
      telem->extra_fds[i] = -1;
      telem->extra_tids[i] = -1;
    }
    telem->last_valid_t_int = DEFAULT_FALLBACK_T_INT;
    telem->core_freq_ghz = DEFAULT_CORE_FREQ_GHZ;
    telem->latencies.slow_ns = (uint16_t)DEFAULT_LATENCY_SLOW_NS;
    telem->latencies.fast_ns = (uint16_t)DEFAULT_LATENCY_FAST_NS;

    /* Prefer actual current CPU core frequency (reflects real all-core clock
     * under load), falling back to scaling_max_freq if unavailable. */
    {
      unsigned long freq_khz = 0;
      FILE *fp =
          fopen("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", "r");
      if (fp) {
        if (fscanf(fp, "%lu", &freq_khz) != 1)
          freq_khz = 0;
        fclose(fp);
      }
      if (freq_khz <= 500000) {
        fp =
            fopen("/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq", "r");
        if (fp) {
          if (fscanf(fp, "%lu", &freq_khz) != 1)
            freq_khz = 0;
          fclose(fp);
        }
      }
      if (freq_khz > 500000) {
        telem->core_freq_ghz = (double)freq_khz / 1e6;
      }
    }

    telem->thp_always = s_cfg.thp_always;

    /* Initialize CHA PMU monitor only if explicitly requested (cpu_mask != 0)
     */
    if (cpu_mask != 0 &&
        mig_cha_mon_init(&telem->cha_mon, cpu_mask, target_cpu) == 0) {
      telem->cha_mon_enabled = true;
      mig_log_info("mig_telemetry_init",
                   "Dedicated CHA PMUs initialized successfully (cpu_mask: "
                   "0x%lx, target_cpu: %d)",
                   cpu_mask, target_cpu);
    } else {
      telem->cha_mon_enabled = false;
      mig_log_info("mig_telemetry_init",
                   "Dedicated CHA PMUs disabled (cha_mon_enabled = false); "
                   "using external/baseline latencies");
    }

    /* Attach to the migration worker thread(s) */
    if (explicit_mig_tid > 0) {
      mig_telemetry_attach_tid(telem, explicit_mig_tid);
    } else if (explicit_mig_tid < 0) {
      telem->mig_tid = -1;
      mig_log_info("mig_telemetry_init",
                   "Migration thread PMC profiling explicitly disabled. Using "
                   "fixed T_int (%.1f ns).",
                   DEFAULT_FALLBACK_T_INT);
    } else {
      if (!mig_telemetry_try_attach(telem)) {
        mig_log_info(
            "mig_telemetry_init",
            "Migration thread not active yet. Using fallback T_int (%.1f "
            "ns) until thread appears.",
            DEFAULT_FALLBACK_T_INT);
      }
    }

    telem->is_initialized = true;
  }
  return 0;
}

/* Release hardware telemetry, CHA PMU file descriptors, and sysfs cached
 * descriptors. */
void mig_telemetry_close(struct mig_telemetry *telem) {
  if (telem) {
    close_worker_fds(telem);
    if (telem->cha_mon_enabled) {
      mig_cha_mon_close(&telem->cha_mon);
      telem->cha_mon_enabled = false;
    }
    telem->mig_tid = -1;
    telem->is_initialized = false;
  }
  if (s_fd_promote >= 0) {
    close(s_fd_promote);
    s_fd_promote = -1;
  }
  if (s_fd_demote >= 0) {
    close(s_fd_demote);
    s_fd_demote = -1;
  }
  s_cfg_initialized = false;
  s_last_enabled = true;
  s_ema_promote = 0;
  s_ema_demote = 0;
  s_ema_initialized = false;
  s_last_attach_check = 0;
  s_last_cfg_refresh = 0;
}

/* Calculate dynamic page copy interval (T_int) using direct CLK_UNHALTED
 * across all attached migration workers and migrated 4KB base-page deltas. */
double mig_telemetry_compute_interval(struct mig_telemetry *telem,
                                      uint64_t pages_migrated) {
  if (!telem || !telem->is_initialized) {
    return DEFAULT_FALLBACK_T_INT;
  }

  /* If not attached to migration thread yet, attempt auto-attachment */
  if (telem->fd_uops < 0 && !mig_telemetry_try_attach(telem)) {
    return telem->last_valid_t_int;
  }

  /* Verify primary migration thread is still alive */
  if (telem->mig_tid > 0 && kill(telem->mig_tid, 0) != 0) {
    mig_log_info("mig_telemetry_compute_interval",
                 "Migration thread TID %d exited. Closing events.",
                 telem->mig_tid);
    close_worker_fds(telem);
    /* Preserve auto-reattach if initialized in auto-detect mode */
    telem->mig_tid = telem->auto_detect ? 0 : -1;
    return telem->last_valid_t_int;
  }

  uint64_t raw_primary = 0;
  ssize_t ret = read(telem->fd_uops, &raw_primary, sizeof(raw_primary));
  if (ret != (ssize_t)sizeof(raw_primary)) {
    return telem->last_valid_t_int;
  }

  /* Read all peer migration workers (e.g., kmigraterd1..N) */
  uint64_t extra_raw[MIG_MAX_WORKERS];
  bool extra_valid[MIG_MAX_WORKERS];
  for (int i = 0; i < telem->nr_extra_workers; ) {
    if (telem->extra_tids[i] > 0 && kill(telem->extra_tids[i], 0) != 0) {
      mig_log_info("mig_telemetry_compute_interval",
                   "Peer migration thread TID %d exited. Closing event.",
                   telem->extra_tids[i]);
      if (telem->extra_fds[i] >= 0)
        close(telem->extra_fds[i]);
      int last = telem->nr_extra_workers - 1;
      telem->extra_fds[i] = telem->extra_fds[last];
      telem->extra_tids[i] = telem->extra_tids[last];
      telem->extra_last_cycles[i] = telem->extra_last_cycles[last];
      telem->extra_fds[last] = -1;
      telem->extra_tids[last] = -1;
      telem->extra_last_cycles[last] = 0;
      telem->nr_extra_workers--;
      continue;
    }

    uint64_t c = 0;
    if (telem->extra_fds[i] >= 0 &&
        read(telem->extra_fds[i], &c, sizeof(c)) == (ssize_t)sizeof(c)) {
      extra_raw[i] = c;
      extra_valid[i] = true;
    } else {
      extra_raw[i] = telem->extra_last_cycles[i];
      extra_valid[i] = false;
    }
    i++;
  }

  /* Establish baseline anchor on first reading */
  if (!telem->has_baseline) {
    telem->last_raw_uops = raw_primary;
    for (int i = 0; i < telem->nr_extra_workers; i++) {
      if (extra_valid[i])
        telem->extra_last_cycles[i] = extra_raw[i];
    }
    telem->last_pages_migrated = pages_migrated;
    telem->has_baseline = true;
    return telem->last_valid_t_int;
  }

  /* Sum per-worker cycle deltas */
  uint64_t delta_cycles = (raw_primary >= telem->last_raw_uops)
                              ? (raw_primary - telem->last_raw_uops)
                              : raw_primary;
  telem->last_raw_uops = raw_primary;

  for (int i = 0; i < telem->nr_extra_workers; i++) {
    if (extra_valid[i]) {
      uint64_t dc = (extra_raw[i] >= telem->extra_last_cycles[i])
                        ? (extra_raw[i] - telem->extra_last_cycles[i])
                        : extra_raw[i];
      delta_cycles += dc;
      telem->extra_last_cycles[i] = extra_raw[i];
    }
  }

  uint64_t delta_pages = (pages_migrated >= telem->last_pages_migrated)
                             ? (pages_migrated - telem->last_pages_migrated)
                             : pages_migrated;
  telem->last_pages_migrated = pages_migrated;

  /* Do not accumulate idle/background worker cycles when no migration is
   * active; accumulate partial sub-gate bursts across consecutive windows. */
  if (delta_pages == 0) {
    if (telem->pending_pages == 0) {
      return telem->last_valid_t_int;
    }
    telem->pending_idle_steps++;
    if (telem->pending_idle_steps >= 5) {
      telem->pending_cycles = 0;
      telem->pending_pages = 0;
      telem->pending_idle_steps = 0;
      return telem->last_valid_t_int;
    }
    telem->pending_cycles += delta_cycles;
    return telem->last_valid_t_int;
  }

  telem->pending_idle_steps = 0;
  telem->pending_cycles += delta_cycles;
  telem->pending_pages += delta_pages;

  /* Gatekeeper check on accumulated active migration window:
   * Callers report migrated pages normalized to 4KB base units. */
  if (telem->pending_pages < MIN_MIG_PAGES_GATE) {
    return telem->last_valid_t_int;
  }

  uint64_t window_cycles = telem->pending_cycles;
  uint64_t window_pages = telem->pending_pages;
  telem->pending_cycles = 0;
  telem->pending_pages = 0;
  telem->pending_idle_steps = 0;

  if (window_cycles == 0) {
    return telem->last_valid_t_int;
  }

  /*
   * Direct CLK_UNHALTED calculation:
   * Directly uses unhalted kernel execution cycles from the migration workers.
   * Zero dependency on CORE_WIDTH (IPC).
   * Each page represents 4KB (64 cachelines).
   */
  uint64_t total_cachelines = window_pages << 6;

  double active_cycles_per_line =
      (double)window_cycles / (double)total_cachelines;

  double t_interval_ns = active_cycles_per_line / telem->core_freq_ghz;

  if (t_interval_ns > MAX_T_INTERVAL_NS) {
    t_interval_ns = MAX_T_INTERVAL_NS;
  }

  telem->last_valid_t_int = t_interval_ns;
  mig_log_debug("mig_telemetry_compute_interval",
                "Window Cycles: %lu, Window Pages: %lu, Lines: %lu, "
                "Active/line: %.2f cycles, T_int: %.2f ns",
                window_cycles, window_pages, total_cachelines,
                active_cycles_per_line, t_interval_ns);
  return t_interval_ns;
}

/* One-time initialization and reading of kernel prefetch sysfs configuration.
 */
void mig_telemetry_init_sysfs(prefetch_sysfs_cfg_t *cfg) {
  if (s_cfg_initialized) {
    if (cfg && cfg != &s_cfg)
      *cfg = s_cfg;
    return;
  }

  s_cfg.enabled = (read_sysfs_uint("enabled", 1) != 0);
  s_cfg.adaptive = (read_sysfs_uint("adaptive", 1) != 0);
  s_cfg.min_distance =
      (uint8_t)read_sysfs_uint("min_distance", PREFETCH_DEFAULT_MIN_DISTANCE);
  s_cfg.max_distance =
      (uint8_t)read_sysfs_uint("max_distance", PREFETCH_DEFAULT_MAX_DISTANCE);
  s_cfg.distances.promote = (uint16_t)read_sysfs_uint(
      "promote_distance", PREFETCH_DEFAULT_PROMOTE_DISTANCE);
  s_cfg.distances.demote = (uint16_t)read_sysfs_uint(
      "demote_distance", PREFETCH_DEFAULT_DEMOTE_DISTANCE);

  /* Detect THP mode: check sysfs [always], environment variables
   * (THP_MODE/THP), and compile-time flags. */
  s_cfg.thp_always = false;
  int fd_thp =
      open("/sys/kernel/mm/transparent_hugepage/enabled", O_RDONLY | O_CLOEXEC);
  if (fd_thp >= 0) {
    char thp_buf[64] = {0};
    if (read(fd_thp, thp_buf, sizeof(thp_buf) - 1) > 0) {
      if (strstr(thp_buf, "[always]") != NULL) {
        s_cfg.thp_always = true;
      }
    }
    close(fd_thp);
  }

  const char *env_thp = getenv("THP_MODE");
  if (!env_thp)
    env_thp = getenv("THP");
  if (env_thp) {
    if (strcmp(env_thp, "always") == 0 || strcmp(env_thp, "1") == 0 ||
        strcmp(env_thp, "true") == 0) {
      s_cfg.thp_always = true;
    } else if (strcmp(env_thp, "never") == 0 || strcmp(env_thp, "0") == 0 ||
               strcmp(env_thp, "false") == 0) {
      s_cfg.thp_always = false;
    }
  }

#if defined(HYBRIDTIER_HUGE)
  s_cfg.thp_always = true;
#endif

  s_cfg_initialized = true;
  s_last_cfg_refresh = time(NULL);

  mig_log_info("mig_telemetry_init_sysfs",
               "One-time sysfs prefetch config: enabled=%d, adaptive=%d, "
               "thp_always=%d, min_dist=%u, max_dist=%u, promote=%u, demote=%u",
               s_cfg.enabled, s_cfg.adaptive, s_cfg.thp_always,
               s_cfg.min_distance, s_cfg.max_distance, s_cfg.distances.promote,
               s_cfg.distances.demote);

  if (cfg && cfg != &s_cfg)
    *cfg = s_cfg;
}

/* Periodically refresh mutable sysfs control knobs (rate-limited to 2 s). */
static void refresh_sysfs_runtime_cfg(void) {
  time_t now = time(NULL);
  if (now - s_last_cfg_refresh < 2)
    return;
  s_last_cfg_refresh = now;

  s_cfg.enabled = (read_sysfs_uint("enabled", s_cfg.enabled ? 1U : 0U) != 0);
  s_cfg.adaptive = (read_sysfs_uint("adaptive", s_cfg.adaptive ? 1U : 0U) != 0);
  s_cfg.min_distance =
      (uint8_t)read_sysfs_uint("min_distance", s_cfg.min_distance);
  s_cfg.max_distance =
      (uint8_t)read_sysfs_uint("max_distance", s_cfg.max_distance);
  if (!s_cfg.adaptive) {
    s_cfg.distances.promote =
        (uint16_t)read_sysfs_uint("promote_distance", s_cfg.distances.promote);
    s_cfg.distances.demote =
        (uint16_t)read_sysfs_uint("demote_distance", s_cfg.distances.demote);
  }
}

/* Return the cached prefetch configuration parameters. */
void mig_telemetry_read_sysfs(prefetch_sysfs_cfg_t *cfg) {
  if (!cfg)
    return;
  if (!s_cfg_initialized)
    mig_telemetry_init_sysfs(cfg);
  else
    *cfg = s_cfg;
}

/* Compute adaptive prefetch distance using latency, migration interval, EMA,
 * and saturation throttle. */
static uint16_t compute_tier_distance(bool is_promote, double l_slow_ns,
                                      double l_fast_ns, double interval_ns,
                                      const prefetch_sysfs_cfg_t *cfg,
                                      uint16_t *inout_ema) {
  if (!cfg->adaptive) {
    return is_promote ? cfg->distances.promote : cfg->distances.demote;
  }

  uint8_t min_dist = cfg->min_distance;
  uint8_t max_dist = cfg->max_distance;
  if (min_dist > max_dist)
    min_dist = max_dist;

  double primary_latency_ns = is_promote ? l_slow_ns : l_fast_ns;
  uint8_t effective_min_dist = min_dist;
  uint8_t raw_dist = 0;
  uint8_t final_dist = (uint8_t)((*inout_ema + 50U) / 100U);

  /* Global Saturation Check (Differentiated for 4KB vs 2MB THP) */
  double fast_thresh = cfg->thp_always ? PREFETCH_LATENCY_FAST_THRESHOLD_2MB
                                       : PREFETCH_LATENCY_FAST_THRESHOLD_4KB;
  double slow_thresh = cfg->thp_always ? PREFETCH_LATENCY_SLOW_THRESHOLD_2MB
                                       : PREFETCH_LATENCY_SLOW_THRESHOLD_4KB;

  bool is_slow_saturated = (l_slow_ns > slow_thresh);
  bool is_fast_saturated = (l_fast_ns > fast_thresh);
  bool is_saturated = is_slow_saturated || is_fast_saturated;

  unsigned int alpha = is_saturated ? PREFETCH_DEFAULT_ALPHA_SATURATE
                                    : PREFETCH_DEFAULT_ALPHA_STEADY;

  if (primary_latency_ns > 0.0 && interval_ns > 0.0) {
    if (is_saturated) {
      effective_min_dist = 0U;
      raw_dist = 0;
      mig_log_debug(
          "compute_tier_distance",
          "[%s] Memory saturation! (slow=%.1f/%.1f ns, fast=%.1f/%.1f ns) -> "
          "throttling %s distance to 0",
          cfg->thp_always ? "2MB-THP" : "4KB", l_slow_ns, slow_thresh,
          l_fast_ns, fast_thresh, is_promote ? "promote" : "demote");
    } else {
      double calc = primary_latency_ns / interval_ns;
      if (calc < 1.0) {
        raw_dist = 0;
      } else if (calc >= (double)max_dist) {
        raw_dist = max_dist;
      } else {
        raw_dist = (uint8_t)calc;
      }
    }

    raw_dist = mig_clamp(raw_dist, effective_min_dist, max_dist);
    unsigned int target_scaled = (unsigned int)raw_dist * 100U;

    *inout_ema =
        (uint16_t)(((100U - alpha) * (unsigned int)(*inout_ema) +
                    alpha * target_scaled + 50U) /
                   100U);
    final_dist = (uint8_t)((*inout_ema + 50U) / 100U);
  }

  final_dist = mig_clamp(final_dist, effective_min_dist, max_dist);
  return final_dist;
}

/* Update promote and demote prefetch distances and sync changed values to
 * kernel sysfs. */
void mig_telemetry_update_distances(double l_slow_ns, double l_fast_ns,
                                    double interval_ns) {
  if (!s_cfg_initialized) {
    mig_telemetry_init_sysfs(&s_cfg);
  } else {
    refresh_sysfs_runtime_cfg();
  }

  if (!s_cfg.enabled) {
    if (s_last_enabled) {
      mig_log_info("update_distances",
                   "Prefetch is currently disabled in sysfs");
      s_last_enabled = false;
    }
    return;
  }
  s_last_enabled = true;

  /* Seed EMA from initial sysfs distances to avoid a cold-start drop to 0 */
  if (!s_ema_initialized) {
    uint8_t max_d = s_cfg.max_distance;
    uint16_t init_p =
        (s_cfg.distances.promote > max_d) ? max_d : s_cfg.distances.promote;
    uint16_t init_d =
        (s_cfg.distances.demote > max_d) ? max_d : s_cfg.distances.demote;
    s_ema_promote = (uint16_t)(init_p * 100U);
    s_ema_demote = (uint16_t)(init_d * 100U);
    s_ema_initialized = true;
  }

  uint16_t p_dist = compute_tier_distance(true, l_slow_ns, l_fast_ns,
                                          interval_ns, &s_cfg, &s_ema_promote);
  uint16_t d_dist = compute_tier_distance(false, l_slow_ns, l_fast_ns,
                                          interval_ns, &s_cfg, &s_ema_demote);

  prefetch_distances_t next_distances;
  next_distances.promote = p_dist;
  next_distances.demote = d_dist;

  if (s_cfg.distances.val != next_distances.val) {
    if (s_cfg.distances.promote != next_distances.promote) {
      if (write_sysfs_cached_fd(&s_fd_promote, "promote_distance",
                                next_distances.promote)) {
        s_cfg.distances.promote = next_distances.promote;
      }
    }
    if (s_cfg.distances.demote != next_distances.demote) {
      if (write_sysfs_cached_fd(&s_fd_demote, "demote_distance",
                                next_distances.demote)) {
        s_cfg.distances.demote = next_distances.demote;
      }
    }
  }
}

/* Convert Little's Law dwell cycles (occ / ins) at uncore freq_ghz to ns,
 * clamped to [0, UINT16_MAX] to prevent 16-bit wraparound. */
static uint16_t cha_dwell_to_latency_ns(uint64_t sum_occ, uint64_t sum_ins,
                                        double freq_ghz, uint16_t fallback_ns) {
  if (sum_ins == 0 || freq_ghz <= 0.0)
    return fallback_ns;
  double ns = ((double)sum_occ / (double)sum_ins) / freq_ghz;
  ns = mig_clamp(ns, 0.0, (double)UINT16_MAX);
  return (uint16_t)(ns + 0.5);
}

/* Sample memory access latencies across active CHA PMU groups via Little's
 * Law using free-running counter deltas. */
mig_latencies_t mig_cha_mon_sample_latencies(mig_cha_mon_t *mon) {
  mig_latencies_t lat;
  lat.slow_ns = (uint16_t)DEFAULT_LATENCY_SLOW_NS;
  lat.fast_ns = (uint16_t)DEFAULT_LATENCY_FAST_NS;

  if (!mon || mon->nr_chas == 0) {
    return lat;
  }

  /* Read all active CHA fast and slow event groups */
  mig_cha_mon_read_groups(mon);

  uint64_t sum_occ_slow = 0, sum_ins_slow = 0;
  uint64_t sum_occ_fast = 0, sum_ins_fast = 0;

  for (int i = 0; i < mon->nr_chas; i++) {
    sum_occ_slow += mon->chas[i].group_slow.values[MIG_CHA_TOR_OCCUPANCY];
    sum_ins_slow += mon->chas[i].group_slow.values[MIG_CHA_TOR_INSERTS];

    sum_occ_fast += mon->chas[i].group_fast.values[MIG_CHA_TOR_OCCUPANCY];
    sum_ins_fast += mon->chas[i].group_fast.values[MIG_CHA_TOR_INSERTS];
  }

  lat.slow_ns = cha_dwell_to_latency_ns(sum_occ_slow, sum_ins_slow,
                                        mon->tsc_freq_ghz, lat.slow_ns);
  lat.fast_ns = cha_dwell_to_latency_ns(sum_occ_fast, sum_ins_fast,
                                        mon->tsc_freq_ghz, lat.fast_ns);
  return lat;
}

void mig_telemetry_step(struct mig_telemetry *telem, uint64_t pages_promoted) {
  if (!telem || !telem->is_initialized) {
    return;
  }

  /* Compute dynamic T_int */
  double dynamic_t_int = mig_telemetry_compute_interval(telem, pages_promoted);

  /* Sample latencies if CHA monitor is active */
  if (telem->cha_mon_enabled) {
    telem->latencies = mig_cha_mon_sample_latencies(&telem->cha_mon);
  }

  mig_telemetry_update_distances((double)telem->latencies.slow_ns,
                                 (double)telem->latencies.fast_ns,
                                 dynamic_t_int);

  mig_log_debug("prefetch_coro",
                "Prefetch Step: Latency (Slow=%u ns, Fast=%u ns) | "
                "T_interval=%.2f ns | "
                "Promoted=%lu => (p_dist=%u, d_dist=%u)",
                telem->latencies.slow_ns, telem->latencies.fast_ns,
                dynamic_t_int, pages_promoted, s_cfg.distances.promote,
                s_cfg.distances.demote);
}
