#!/bin/bash
# ==============================================================================
# Redis Server Lifecycle & Benchmark Runner
# All benchmark options (-t, -n, -r, -d, -c, --threads) are configured by
# workloads/scripts/exec_workload.sh and passed via "$@".
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
WORKLOAD_DIR="${ROOT_DIR}/workloads"
REDIS_DIR="${WORKLOAD_DIR}/redis_src"
[ ! -d "$REDIS_DIR" ] && REDIS_DIR="${WORKLOAD_DIR}/redis"

REDIS_SERVER="${REDIS_DIR}/src/redis-server"
REDIS_BENCH="${REDIS_DIR}/src/redis-benchmark"
REDIS_CLI="${REDIS_DIR}/src/redis-cli"

if [ ! -x "$REDIS_SERVER" ] || [ ! -x "$REDIS_BENCH" ] || [ ! -x "$REDIS_CLI" ]; then
    echo "ERROR: Redis binaries not built. Run 'sudo ./setup_workloads.sh redis' first."
    exit 1
fi

CONFIG_FILE=""
[ -f "${REDIS_DIR}/redis.conf" ] && CONFIG_FILE="${REDIS_DIR}/redis.conf"

# Ensure memory overcommit is enabled
if [ "$(id -u)" -eq 0 ]; then
    sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 || true
fi

# Stop any prior redis instance safely
"${REDIS_CLI}" shutdown 2>/dev/null || true

echo "==> Starting Redis server (Config: ${CONFIG_FILE:-default})..."
"${REDIS_SERVER}" ${CONFIG_FILE} --daemonize yes --protected-mode no --save ""

# Wait up to 5 seconds for redis-server to respond
for i in $(seq 1 50); do
    if "${REDIS_CLI}" ping 2>/dev/null | grep -q "PONG"; then break; fi
    sleep 0.1
done

echo "==> Executing redis-benchmark: $*"
BENCH_ARGS=("$@")
[ $# -eq 0 ] && BENCH_ARGS=(-t set,get -n 4300000 -r 4300000 -d 8192 -c 50 --threads 4)
"${REDIS_BENCH}" "${BENCH_ARGS[@]}"

# Capture peak server RSS before shutdown so profilers record the true footprint
SERVER_PID=$("${REDIS_CLI}" info server 2>/dev/null | awk -F: '/process_id/ {print $2}' | tr -d '\r' || true)
SERVER_RSS_GB=""
if [ -n "${SERVER_PID}" ] && [ -f "/proc/${SERVER_PID}/status" ]; then
    SERVER_RSS_KB=$(awk '/VmHWM:/ {print $2}' "/proc/${SERVER_PID}/status" 2>/dev/null || true)
    [ -n "${SERVER_RSS_KB}" ] && SERVER_RSS_GB=$(awk -v kb="${SERVER_RSS_KB}" 'BEGIN { printf "%.2f", kb / 1048576 }')
fi
if [ -z "${SERVER_RSS_GB}" ]; then
    SERVER_RSS_BYTES=$("${REDIS_CLI}" info memory 2>/dev/null | awk -F: '/used_memory_rss:/ {print $2}' | tr -d '\r' || true)
    [ -n "${SERVER_RSS_BYTES}" ] && SERVER_RSS_GB=$(awk -v b="${SERVER_RSS_BYTES}" 'BEGIN { printf "%.2f", b / 1073741824 }')
fi
[ -n "${SERVER_RSS_GB}" ] && echo "Peak Resident Set Size (redis-server): ${SERVER_RSS_GB} GB"

echo "==> Shutting down Redis server..."
"${REDIS_CLI}" shutdown 2>/dev/null || true
echo "==> Redis workload finished cleanly."
