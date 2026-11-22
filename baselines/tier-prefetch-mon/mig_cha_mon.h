/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 MoatLab, Virginia Tech. */

#ifndef MIG_CHA_MON_H
#define MIG_CHA_MON_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stdint.h>

#define MIG_MAX_CHAS 64

typedef enum {
  MIG_CHA_TOR_OCCUPANCY = 0,
  MIG_CHA_TOR_INSERTS,
  MIG_CHA_TOR_EVENT_COUNT
} mig_cha_event_index_t;

typedef struct {
  int fds[MIG_CHA_TOR_EVENT_COUNT];
  uint64_t ids[MIG_CHA_TOR_EVENT_COUNT];
  uint64_t values[MIG_CHA_TOR_EVENT_COUNT];
  uint64_t last_values[MIG_CHA_TOR_EVENT_COUNT];
} mig_cha_event_group_t;

typedef struct {
  int cha_id;
  int pmu_type;
  int core_id;
  char device_name[256];
  mig_cha_event_group_t group_fast; /* Tier 0: Local DRAM */
  mig_cha_event_group_t group_slow; /* Tier 1: Remote CXL / NUMA */
} mig_cha_info_t;

typedef struct {
  mig_cha_info_t chas[MIG_MAX_CHAS];
  int nr_chas;
  int target_cpu;
  double tsc_freq_ghz;
} mig_cha_mon_t;

unsigned long mig_read_ulong_file(const char *path);
int mig_cha_mon_init(mig_cha_mon_t *mon, uint64_t cpu_mask, int target_cpu);
void mig_cha_mon_start(mig_cha_mon_t *mon);
void mig_cha_mon_stop(mig_cha_mon_t *mon);
void mig_cha_mon_close(mig_cha_mon_t *mon);
void mig_cha_read_group(mig_cha_event_group_t *g);
void mig_cha_mon_read_groups(mig_cha_mon_t *mon);

#ifdef __cplusplus
}
#endif

#endif /* MIG_CHA_MON_H */
