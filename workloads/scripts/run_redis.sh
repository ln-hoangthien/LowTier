#!/bin/bash
# ==============================================================================
# Redis Automated Tiered Memory Workload Execution Script
# Reference: workloads/redis_src/README.md
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

if [ ! -x "$REDIS_SERVER" ]; then
    echo "ERROR: ${REDIS_SERVER} is not built or not executable."
    echo "Please build Redis using 'sudo ./setup_workloads.sh redis' first."
    exit 1
fi

# Configuration file selection per workloads/redis_src/README.md:
# If building from git checkout with module configuration, use redis-full.conf if present.
# Otherwise, fall back to redis.conf.
CONFIG_FILE=""
if [ -f "${REDIS_DIR}/redis-full.conf" ]; then
    CONFIG_FILE="${REDIS_DIR}/redis-full.conf"
elif [ -f "${REDIS_DIR}/redis.conf" ]; then
    CONFIG_FILE="${REDIS_DIR}/redis.conf"
fi

# Shutdown any existing redis-server instance safely
"${REDIS_CLI}" shutdown 2>/dev/null || true
sleep 1

echo "==> Starting Redis server (Config: ${CONFIG_FILE:-default})..."
if [ -n "$CONFIG_FILE" ]; then
    "${REDIS_SERVER}" "${CONFIG_FILE}" --daemonize yes --protected-mode no --save ""
else
    "${REDIS_SERVER}" --daemonize yes --protected-mode no --save ""
fi

# Wait up to 10 seconds for redis-server to respond
READY=false
for i in $(seq 1 10); do
    if "${REDIS_CLI}" ping 2>/dev/null | grep -q "PONG"; then
        READY=true
        break
    fi
    sleep 1
done

if [ "$READY" = false ]; then
    echo "ERROR: Failed to start redis-server."
    exit 1
fi

echo "==> Redis server is running. Launching benchmark workload..."

# Run redis-benchmark if available
if [ -x "$REDIS_BENCH" ]; then
    "${REDIS_BENCH}" -t set,get,lpush,mset -n 2000000 -c 50 -d 4096 -r 1000000 --threads 4 || true
else
    echo "redis-benchmark binary missing; performing set/get workload via redis-cli..."
    for i in $(seq 1 100000); do
        "${REDIS_CLI}" SET "key:$i" "value_$i_$(printf '%0100d' $i)" >/dev/null 2>&1 || true
    done
fi

echo "==> Benchmark completed. Shutting down Redis server..."
"${REDIS_CLI}" shutdown 2>/dev/null || true
echo "==> Redis workload finished cleanly."
