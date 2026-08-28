#!/bin/bash
# Take the slow-tier (second-socket) CPUs offline to emulate a CPU-less CXL
# tier. The CPU list is machine-specific (below: the odd-socket sibling lanes
# on the reference dual-socket SKX host) - edit it to match `lscpu`/`numactl -H`
# for your machine. Requires root.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)"; exit 1; }

for i in 2 6 10 14 18 22 26 30 34 38 42 46 50 54 58 62; do
    echo 0 > "/sys/devices/system/cpu/cpu$i/online"
done
