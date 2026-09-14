#!/bin/bash
# -------------------------------------------------------------------
# LowTier Regression Workload Runner
# Usage:
#   ./run_regression.sh [BENCHMARK] [DATASET]
#   ./run_regression.sh (runs benchmarks configured in regression_list)
# -------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
RUN_WORKLOADS="${ROOT_DIR}/workloads/scripts/run_workloads.sh"
[ ! -f "$RUN_WORKLOADS" ] && RUN_WORKLOADS="run_workloads.sh"

run_bench() {
    local b="$1" d="${2:-}"
    echo "[*] Executing benchmark: $b ${d:-}"
    if [ -n "$d" ]; then
        bash "$RUN_WORKLOADS" "$b" "$d"
    elif [[ "$b" =~ ^(gapbs_[a-z]+)_(kron|urand|twitter|web|road)$ ]]; then
        bash "$RUN_WORKLOADS" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        bash "$RUN_WORKLOADS" "$b"
    fi
}

if [ -n "${1:-}" ]; then
    run_bench "$1" "${2:-}"
else
    REGRESSION_LIST="${SCRIPT_DIR}/regression_list"
    BENCHMARKS=()
    if [ -s "$REGRESSION_LIST" ]; then
        unset BENCHMARKS
        # shellcheck source=/dev/null
        source "$REGRESSION_LIST"
        read -ra BENCHMARKS <<< "${BENCHMARKS[*]//,/ }"
    fi
    if [ ${#BENCHMARKS[@]} -eq 0 ]; then
        echo "Error: No benchmarks specified in ${REGRESSION_LIST} (BENCHMARKS=...)"
        exit 1
    fi
    for b in "${BENCHMARKS[@]}"; do
        run_bench "$b"
    done
fi