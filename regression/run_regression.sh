#!/bin/bash
# -------------------------------------------------------------------
# LowTier Single-Kernel Regression Workload Suite
# -------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
KERNEL_VER="$(uname -r)"

OUTPUT_DIR="${ROOT_DIR}/workloads/output"
TARGET_DIR="${OUTPUT_DIR}/${KERNEL_VER}"
mkdir -p "${TARGET_DIR}"

RUN_WORKLOADS="${ROOT_DIR}/workloads/scripts/run_workloads.sh"
[ ! -f "$RUN_WORKLOADS" ] && RUN_WORKLOADS="run_workloads.sh"

#${RUN_WORKLOADS} stream
#${RUN_WORKLOADS} stream_hot
${RUN_WORKLOADS} stream_phase

#${RUN_WORKLOADS} gapbs_pr kron
#${RUN_WORKLOADS} gapbs_pr urand
#${RUN_WORKLOADS} gapbs_pr twitter

#${RUN_WORKLOADS} gapbs_tc kron
#${RUN_WORKLOADS} gapbs_tc urand
#${RUN_WORKLOADS} gapbs_tc twitter

#${RUN_WORKLOADS} gapbs_bfs kron
#${RUN_WORKLOADS} gapbs_bfs urand
#${RUN_WORKLOADS} gapbs_bfs twitter

#${RUN_WORKLOADS} gapbs_bc kron
#${RUN_WORKLOADS} gapbs_bc urand
#${RUN_WORKLOADS} gapbs_bc twitter

#${RUN_WORKLOADS} gapbs_cc kron
#${RUN_WORKLOADS} gapbs_cc urand
#${RUN_WORKLOADS} gapbs_cc twitter

#${RUN_WORKLOADS} gapbs_sssp kron
#${RUN_WORKLOADS} gapbs_sssp urand
#${RUN_WORKLOADS} gapbs_sssp twitter

#${RUN_WORKLOADS} silo_tpcc
#${RUN_WORKLOADS} silo_ycsb
#${RUN_WORKLOADS} silo_queuep
#${RUN_WORKLOADS} silo_bid
#${RUN_WORKLOADS} silo_encstress
#${RUN_WORKLOADS} redis
#${RUN_WORKLOADS} xsbench