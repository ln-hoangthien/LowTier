/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 MoatLab, Virginia Tech. */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/perf_event.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "logging.h"
#include "mig_cha_mon.h"

#define DEFAULT_UNCORE_FREQ_GHZ 2.5
#define SPR_MAX_CHA_MAPPING 32

typedef struct {
  uint64_t nr;
  uint64_t time_enabled;
  uint64_t time_running;
  struct {
    uint64_t value;
    uint64_t id;
  } values[];
} perf_read_format_t;

/* Dedicated Sapphire Rapids CHA TOR PMU configuration.
 * Local DRAM (Tier 0): DRD_LOC opcode in ext umask 0x00c816fe.
 * Remote DRAM (Tier 1): DRD_REM opcode in ext umask 0x00c8177e. */
static void mig_get_cha_tor_pe_config(int event_idx, int tier,
                                      uint64_t *out_config,
                                      uint64_t *out_config1) {
  uint64_t op_mask =
      (tier == 0) ? 0x00c816fe00000000ULL : 0x00c8177e00000000ULL;
  if (event_idx == MIG_CHA_TOR_OCCUPANCY) {
    *out_config = op_mask | 0x0136ULL;
  } else if (event_idx == MIG_CHA_TOR_INSERTS) {
    *out_config = op_mask | 0x0135ULL;
  } else {
    *out_config = 0;
  }
  *out_config1 = 0;
}

static long sys_perf_event_open(struct perf_event_attr *hw_event, pid_t pid,
                                int cpu, int group_fd, unsigned long flags) {
  return syscall(__NR_perf_event_open, hw_event, pid, cpu, group_fd, flags);
}

/* CHA TOR_OCCUPANCY counts in Package 0 uncore clock cycles (independent of
 * core Turbo frequency). Read pkg0 uncore frequency so latency stays accurate
 * when core clocks are pinned at 2.1, 3.0, or 3.5 GHz. */
static double mig_detect_uncore_freq_ghz(void) {
  static const char *const paths[] = {
      "/sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/current_freq_khz",
      "/sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/max_freq_khz",
      "/sys/devices/system/cpu/intel_uncore_frequency/uncore00/current_freq_khz",
      "/sys/devices/system/cpu/intel_uncore_frequency/uncore00/max_freq_khz",
  };
  for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
    FILE *fp = fopen(paths[i], "r");
    if (fp) {
      unsigned long khz = 0;
      if (fscanf(fp, "%lu", &khz) == 1 && khz > 500000) {
        fclose(fp);
        return (double)khz / 1e6;
      }
      fclose(fp);
    }
  }
  return DEFAULT_UNCORE_FREQ_GHZ;
}

static int mig_open_tor_group(mig_cha_info_t *cha, int tier, int target_cpu) {
  mig_cha_event_group_t *g = (tier == 0) ? &cha->group_fast : &cha->group_slow;
  int leader_fd = -1;

  for (int i = 0; i < MIG_CHA_TOR_EVENT_COUNT; i++) {
    struct perf_event_attr pe;
    memset(&pe, 0, sizeof(pe));
    pe.size = sizeof(pe);
    pe.type = cha->pmu_type;
    pe.sample_type = PERF_SAMPLE_IDENTIFIER;
    pe.read_format = PERF_FORMAT_TOTAL_TIME_ENABLED |
                     PERF_FORMAT_TOTAL_TIME_RUNNING | PERF_FORMAT_GROUP |
                     PERF_FORMAT_ID;

    uint64_t config = 0, config1 = 0;
    mig_get_cha_tor_pe_config(i, tier, &config, &config1);
    pe.config = config;
    pe.config1 = config1;
    pe.config2 = 0;

    pe.disabled = (i == MIG_CHA_TOR_OCCUPANCY) ? 1 : 0;
    pe.exclude_kernel = 0;
    pe.exclude_hv = 0;
    pe.exclude_idle = 0;
    pe.inherit = 0;

    int group_fd = (i == MIG_CHA_TOR_OCCUPANCY) ? -1 : leader_fd;
    int fd = (int)sys_perf_event_open(&pe, -1, target_cpu, group_fd, 0);
    if (fd < 0) {
      return -1;
    }

    ioctl(fd, PERF_EVENT_IOC_ID, &g->ids[i]);
    g->fds[i] = fd;

    if (i == MIG_CHA_TOR_OCCUPANCY) {
      leader_fd = fd;
    }
  }

  return 0;
}

int mig_cha_mon_init(mig_cha_mon_t *mon, uint64_t cpu_mask, int target_cpu) {
  if (!mon)
    return -EINVAL;
  memset(mon, 0, sizeof(*mon));

  mon->target_cpu = target_cpu;
  mon->tsc_freq_ghz = mig_detect_uncore_freq_ghz();

  DIR *dir = opendir("/sys/devices");
  if (!dir)
    return -errno;

  int n_discovered = 0;
  struct dirent *entry;
  while ((entry = readdir(dir)) != NULL) {
    if (strncmp(entry->d_name, "uncore_cha_", 11) != 0)
      continue;
    int cha_id = atoi(entry->d_name + 11);
    if (cha_id < 0 || cha_id >= MIG_MAX_CHAS)
      continue;

    char path[512];
    snprintf(path, sizeof(path), "/sys/devices/%s/type", entry->d_name);
    FILE *fp = fopen(path, "r");
    if (!fp)
      continue;

    int pmu_type = 0;
    if (fscanf(fp, "%d", &pmu_type) != 1) {
      fclose(fp);
      continue;
    }
    fclose(fp);

    mon->chas[n_discovered].cha_id = cha_id;
    mon->chas[n_discovered].pmu_type = pmu_type;
    snprintf(mon->chas[n_discovered].device_name,
             sizeof(mon->chas[n_discovered].device_name), "%s", entry->d_name);
    n_discovered++;
  }
  closedir(dir);

  if (n_discovered == 0) {
    mig_log_info("detect_cha_pmus", "No CHA PMUs discovered");
    return -ENODEV;
  }
  mig_log_info("detect_cha_pmus", "Total CHA PMUs discovered: %d",
               n_discovered);

  int base_type = INT_MAX;
  for (int i = 0; i < n_discovered; i++) {
    if (mon->chas[i].pmu_type < base_type) {
      base_type = mon->chas[i].pmu_type;
    }
  }

  int active = 0, skipped = 0;

  for (int i = 0; i < n_discovered; i++) {
    int offset = mon->chas[i].pmu_type - base_type;
    if (offset < 0 || offset >= SPR_MAX_CHA_MAPPING)
      continue;

    /* Sapphire Rapids CHA box maps 1:1 to core ID */
    int core_id = offset;
    if (cpu_mask != 0 && !(cpu_mask & (1ULL << core_id))) {
      mig_log_debug("detect_cha_pmus",
                    "Skipping CHA %d (core %d not in target CPU mask 0x%lx)",
                    mon->chas[i].cha_id, core_id, (unsigned long)cpu_mask);
      skipped++;
      continue;
    }

    if (active != i) {
      mon->chas[active].cha_id = mon->chas[i].cha_id;
      mon->chas[active].pmu_type = mon->chas[i].pmu_type;
      snprintf(mon->chas[active].device_name,
               sizeof(mon->chas[active].device_name), "%s",
               mon->chas[i].device_name);
    }
    mon->chas[active].core_id = core_id;

    mig_log_info("setup_uncore_events",
                 "Setting up CHA %d (%s, PMU type %d, core %d)",
                 mon->chas[active].cha_id, mon->chas[active].device_name,
                 mon->chas[active].pmu_type, core_id);

    if (mig_open_tor_group(&mon->chas[active], 0, mon->target_cpu) == 0 &&
        mig_open_tor_group(&mon->chas[active], 1, mon->target_cpu) == 0) {
      active++;
    }
  }

  mon->nr_chas = active;
  if (skipped > 0) {
    mig_log_info("detect_cha_pmus",
                 "Active CHA PMUs: %d (skipped %d CHAs not in target CPU mask)",
                 active, skipped);
  } else {
    mig_log_info("detect_cha_pmus", "Active CHA PMUs: %d", active);
  }
  printf("[MIG-CHA-MON] Successfully activated %d CHAs (Sapphire Rapids, "
         "Uncore freq: %.2f GHz)\n",
         mon->nr_chas, mon->tsc_freq_ghz);
  return (active > 0) ? 0 : -ENODEV;
}

void mig_cha_read_group(mig_cha_event_group_t *g) {
  if (g->fds[0] < 0)
    return;
  char buf[1024];
  perf_read_format_t *rf = (perf_read_format_t *)buf;
  ssize_t res = read(g->fds[0], buf, sizeof(buf));
  if (res <= 0)
    return;

  for (int j = 0; j < MIG_CHA_TOR_EVENT_COUNT; j++) {
    g->values[j] = 0;
  }
  for (uint64_t i = 0; i < rf->nr; i++) {
    for (int j = 0; j < MIG_CHA_TOR_EVENT_COUNT; j++) {
      if (rf->values[i].id == g->ids[j]) {
        uint64_t cur = rf->values[i].value;
        uint64_t prev = g->last_values[j];
        g->values[j] = (cur >= prev) ? (cur - prev) : cur;
        g->last_values[j] = cur;
        break;
      }
    }
  }
}

void mig_cha_mon_read_groups(mig_cha_mon_t *mon) {
  if (!mon)
    return;
  for (int i = 0; i < mon->nr_chas; i++) {
    mig_cha_read_group(&mon->chas[i].group_fast);
    mig_cha_read_group(&mon->chas[i].group_slow);
  }
}

void mig_cha_mon_start(mig_cha_mon_t *mon) {
  if (!mon)
    return;
  for (int i = 0; i < mon->nr_chas; i++) {
    if (mon->chas[i].group_fast.fds[0] >= 0) {
      for (int j = 0; j < MIG_CHA_TOR_EVENT_COUNT; j++) {
        mon->chas[i].group_fast.values[j] = 0;
        mon->chas[i].group_fast.last_values[j] = 0;
      }
      ioctl(mon->chas[i].group_fast.fds[0], PERF_EVENT_IOC_RESET,
            PERF_IOC_FLAG_GROUP);
      ioctl(mon->chas[i].group_fast.fds[0], PERF_EVENT_IOC_ENABLE,
            PERF_IOC_FLAG_GROUP);
    }
    if (mon->chas[i].group_slow.fds[0] >= 0) {
      for (int j = 0; j < MIG_CHA_TOR_EVENT_COUNT; j++) {
        mon->chas[i].group_slow.values[j] = 0;
        mon->chas[i].group_slow.last_values[j] = 0;
      }
      ioctl(mon->chas[i].group_slow.fds[0], PERF_EVENT_IOC_RESET,
            PERF_IOC_FLAG_GROUP);
      ioctl(mon->chas[i].group_slow.fds[0], PERF_EVENT_IOC_ENABLE,
            PERF_IOC_FLAG_GROUP);
    }
  }
}

void mig_cha_mon_stop(mig_cha_mon_t *mon) {
  if (!mon)
    return;
  for (int i = 0; i < mon->nr_chas; i++) {
    if (mon->chas[i].group_fast.fds[0] >= 0) {
      ioctl(mon->chas[i].group_fast.fds[0], PERF_EVENT_IOC_DISABLE,
            PERF_IOC_FLAG_GROUP);
    }
    if (mon->chas[i].group_slow.fds[0] >= 0) {
      ioctl(mon->chas[i].group_slow.fds[0], PERF_EVENT_IOC_DISABLE,
            PERF_IOC_FLAG_GROUP);
    }
  }
}

void mig_cha_mon_close(mig_cha_mon_t *mon) {
  if (!mon)
    return;
  for (int i = 0; i < mon->nr_chas; i++) {
    for (int j = 0; j < MIG_CHA_TOR_EVENT_COUNT; j++) {
      if (mon->chas[i].group_fast.fds[j] >= 0) {
        close(mon->chas[i].group_fast.fds[j]);
        mon->chas[i].group_fast.fds[j] = -1;
      }
      if (mon->chas[i].group_slow.fds[j] >= 0) {
        close(mon->chas[i].group_slow.fds[j]);
        mon->chas[i].group_slow.fds[j] = -1;
      }
    }
  }
  mon->nr_chas = 0;
}
