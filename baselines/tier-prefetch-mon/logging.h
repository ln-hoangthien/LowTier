/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 MoatLab, Virginia Tech. */

#ifndef TIER_MON_LOGGING_H
#define TIER_MON_LOGGING_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdio.h>

extern int g_verbose;

#define mig_log_error(func, fmt, ...)                                          \
  fprintf(stderr, "[ERROR] %s: " fmt "\n", func, ##__VA_ARGS__)

#define mig_log_warn(func, fmt, ...)                                           \
  fprintf(stderr, "[WARNING] %s: " fmt "\n", func, ##__VA_ARGS__)

#define mig_log_info(func, fmt, ...)                                           \
  fprintf(stdout, "[INFO] %s: " fmt "\n", func, ##__VA_ARGS__)

#define mig_log_debug(func, fmt, ...)                                          \
  do {                                                                         \
    if (g_verbose) {                                                           \
      fprintf(stdout, "[DEBUG] %s: " fmt "\n", func, ##__VA_ARGS__);           \
    }                                                                          \
  } while (0)

#ifdef __cplusplus
}
#endif

#endif /* TIER_MON_LOGGING_H */
