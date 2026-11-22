/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 MoatLab, Virginia Tech. */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <fcntl.h>
#include <getopt.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "logging.h"
#include "mig_telemetry.h"

int g_verbose = 0;
static volatile sig_atomic_t g_running = 1;

static void sig_handler(int sig) {
  (void)sig;
  g_running = 0;
}

/*
 * Query the 4KB base-page count matched 1-to-1 to the monitored migration
 * thread (telem->mig_comm) whose CPU_CLK_UNHALTED.THREAD is being sampled:
 * - Nomad (async_promote): /proc/perfnomad (success_nr)
 * - Memtis (kmigraterd / kmig): /proc/vmstat (htmm_nr_promoted +
 * htmm_nr_demoted)
 * - Kernel LRU demotion (kswapd*): /proc/vmstat (pgdemote_kswapd)
 * - AutoNUMA kthread (knuma_migrated): /proc/vmstat (numa_pages_migrated)
 */
static uint64_t
get_migration_promoted_pages(const struct mig_telemetry *telem) {
  static int s_fd_perfnomad = -2;
  static int s_fd_vmstat = -1;
  const char *comm = (telem && telem->mig_comm[0]) ? telem->mig_comm : "";

  /* 1. Nomad async_promote worker: exclusively executes Nomad promotions */
  if (strncmp(comm, "async_promote", 13) == 0 ||
      strncmp(comm, "nomad", 5) == 0 || comm[0] == '\0') {
    if (s_fd_perfnomad == -2) {
      s_fd_perfnomad = open("/proc/perfnomad", O_RDONLY | O_CLOEXEC);
    }
    if (s_fd_perfnomad >= 0) {
      char buf[512];
      ssize_t n = pread(s_fd_perfnomad, buf, sizeof(buf) - 1, 0);
      if (n > 0) {
        buf[n] = '\0';
        const char *p = strstr(buf, "success_nr ");
        if (p)
          return strtoull(p + 11, NULL, 10);
      }
    }
  }

  if (s_fd_vmstat < 0) {
    s_fd_vmstat = open("/proc/vmstat", O_RDONLY | O_CLOEXEC);
  }
  if (s_fd_vmstat >= 0) {
    char buf[8192];
    ssize_t n = pread(s_fd_vmstat, buf, sizeof(buf) - 1, 0);
    if (n > 0) {
      buf[n] = '\0';
      const char *p;

      /* 2. Memtis kmigraterd / kmig worker: executes both htmm promote & demote
       */
      if (strncmp(comm, "kmig", 4) == 0) {
        uint64_t total = 0;
        bool found = false;
        if ((p = strstr(buf, "htmm_nr_promoted ")) != NULL) {
          total += strtoull(p + 17, NULL, 10);
          found = true;
        }
        if ((p = strstr(buf, "htmm_nr_demoted ")) != NULL) {
          total += strtoull(p + 16, NULL, 10);
          found = true;
        }
        if (found)
          return total;
      }

      /* 3. Kernel kswapd worker (AutoNUMA / TPP): exclusively executes
       * pgdemote_kswapd */
      if (strncmp(comm, "kswapd", 6) == 0) {
        if ((p = strstr(buf, "pgdemote_kswapd ")) != NULL)
          return strtoull(p + 16, NULL, 10);
      }

      /* 4. AutoNUMA dedicated migration kthread */
      if (strncmp(comm, "knuma_migrated", 14) == 0) {
        if ((p = strstr(buf, "numa_pages_migrated ")) != NULL)
          return strtoull(p + 20, NULL, 10);
      }

      /* Fallback detection when comm is not yet attached */
      if ((p = strstr(buf, "htmm_nr_promoted ")) != NULL) {
        uint64_t prom = strtoull(p + 17, NULL, 10);
        uint64_t dem = 0;
        if ((p = strstr(buf, "htmm_nr_demoted ")) != NULL)
          dem = strtoull(p + 16, NULL, 10);
        return prom + dem;
      }
      if ((p = strstr(buf, "pgpromote_anon ")) != NULL) {
        uint64_t anon = strtoull(p + 15, NULL, 10);
        uint64_t file = 0;
        if ((p = strstr(buf, "pgpromote_file ")) != NULL) {
          file = strtoull(p + 15, NULL, 10);
        }
        return anon + file;
      }
      if ((p = strstr(buf, "pgmigrate_success ")) != NULL) {
        return strtoull(p + 18, NULL, 10);
      }
    }
  }
  return 0;
}

static void print_usage(const char *prog) {
  printf("Usage: %s [OPTIONS]\n", prog);
  printf("Tier Memory Access Latency & Adaptive Prefetch Distance Monitor "
         "Daemon\n\n");
  printf("Options:\n");
  printf("  -m, --mig-tid TID    Explicit migration worker thread TID to "
         "monitor (default: auto-detect)\n");
  printf("  -c, --cpu-mask MASK  CPU mask (hex/dec) to filter active CHAs "
         "(default: 0xffffff = cores 0-23, 0 = disable CHA PMUs)\n");
  printf("  -d, --daemon         Run in background as a daemon\n");
  printf("  -i, --interval-ms MS Sampling interval in milliseconds (default: "
         "50 ms)\n");
  printf("  -t, --t-copy-ns NS   Assumed memory migration copy interval in ns "
         "(default: 18.0 ns)\n");
  printf(
      "  -H, --thp            Explicitly force 2MB THP latency thresholds\n");
  printf("  -v, --verbose        Verbose output logging\n");
  printf("  -h, --help           Show this help message\n");
}

int main(int argc, char *argv[]) {
  bool daemon_mode = false;
  bool verbose = false;
  pid_t explicit_mig_tid = 0; /* Default: auto-detect (pass -m -1 to disable) */
  unsigned int interval_ms = 50;
  double t_copy_ns = DEFAULT_FALLBACK_T_INT; /* Dynamic T_int fallback */
  uint64_t cpu_mask = 0xFFFFFFULL; /* Default: 24 workload cores (0..23) */
  bool cpu_mask_set = false;

  static struct option long_options[] = {
      {"mig-tid", required_argument, 0, 'm'},
      {"cpu-mask", required_argument, 0, 'c'},
      {"daemon", no_argument, 0, 'd'},
      {"interval-ms", required_argument, 0, 'i'},
      {"t-copy-ns", required_argument, 0, 't'},
      {"thp", no_argument, 0, 'H'},
      {"verbose", no_argument, 0, 'v'},
      {"help", no_argument, 0, 'h'},
      {0, 0, 0, 0}};

  int opt;
  while ((opt = getopt_long(argc, argv, "m:c:di:t:Hvh", long_options, NULL)) !=
         -1) {
    switch (opt) {
    case 'm':
      explicit_mig_tid = (pid_t)atoi(optarg);
      break;
    case 'c':
      cpu_mask = strtoull(optarg, NULL, 0);
      cpu_mask_set = true;
      break;
    case 'd':
      daemon_mode = true;
      break;
    case 'i':
      interval_ms = (unsigned int)atoi(optarg);
      if (interval_ms < 10)
        interval_ms = 10;
      break;
    case 't':
      t_copy_ns = atof(optarg);
      if (t_copy_ns < 1.0)
        t_copy_ns = 1.0;
      break;
    case 'H':
      setenv("THP_MODE", "always", 1);
      break;
    case 'v':
      verbose = true;
      break;
    case 'h':
      print_usage(argv[0]);
      return 0;
    default:
      print_usage(argv[0]);
      return 1;
    }
  }

  if (!cpu_mask_set) {
    const char *env_mask = getenv("CPU_MASK");
    if (env_mask && env_mask[0] != '\0') {
      cpu_mask = strtoull(env_mask, NULL, 0);
    }
  }

  g_verbose = verbose ? 1 : 0;

  if (daemon_mode) {
    /* nochdir=0, noclose=1 preserves redirected stdout/stderr to log files */
    if (daemon(0, 1) < 0) {
      perror("daemon() failed");
      return 1;
    }
  }

  /* Record PID for clean termination by teardown scripts */
  FILE *pid_fp = fopen("/tmp/tier_prefetch_mon.pid", "w");
  if (pid_fp) {
    fprintf(pid_fp, "%d\n", getpid());
    fclose(pid_fp);
  }

  signal(SIGINT, sig_handler);
  signal(SIGTERM, sig_handler);

  struct mig_telemetry telem;
  int target_cpu = 31; /* Default hosting core for standalone daemon */
  if (mig_telemetry_init(&telem, explicit_mig_tid, cpu_mask, target_cpu) != 0) {
    mig_log_error("main", "Failed to initialize migration telemetry subsystem");
    return 1;
  }
  if (telem.cha_mon_enabled) {
    mig_cha_mon_start(&telem.cha_mon);
  }
  if (t_copy_ns != DEFAULT_FALLBACK_T_INT) {
    telem.last_valid_t_int = t_copy_ns;
  }

  mig_log_info("main",
               "Daemon running (PID: %d, interval: %u ms, cpu_mask: 0x%lx)",
               getpid(), interval_ms, cpu_mask);
  fflush(stdout);

  struct timespec sleep_ts;
  sleep_ts.tv_sec = interval_ms / 1000;
  sleep_ts.tv_nsec = (interval_ms % 1000) * 1000000L;

  bool has_base_pages = false;
  uint64_t base_pages = 0;

  while (g_running) {
    nanosleep(&sleep_ts, NULL);
    if (!g_running)
      break;

    /* If not attached to the migration worker thread yet, attempt attachment */
    if (telem.fd_uops < 0 && explicit_mig_tid >= 0) {
      mig_telemetry_try_attach(&telem);
    }

    /* Retrieve per-thread matched migrated 4KB base pages relative to run start */
    uint64_t raw_pages = get_migration_promoted_pages(&telem);
    if (!has_base_pages && (telem.fd_uops >= 0 || explicit_mig_tid < 0)) {
      base_pages = raw_pages;
      has_base_pages = true;
    }
    uint64_t pages_promoted =
        (has_base_pages && raw_pages >= base_pages) ? (raw_pages - base_pages) : 0;
    /* CHA counters stay free-running and mig_cha_read_group() computes deltas
     * directly, avoiding per-step ioctl(RESET/ENABLE) uncore MSR writes. */
    mig_telemetry_step(&telem, pages_promoted);
  }

  mig_log_info("main", "Shutting down...");
  fflush(stdout);
  mig_telemetry_close(&telem);
  unlink("/tmp/tier_prefetch_mon.pid");
  return 0;
}
