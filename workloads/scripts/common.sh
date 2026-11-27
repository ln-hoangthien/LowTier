#!/bin/bash
# Shared helpers sourced by run_workloads.sh, setup_kernel.sh, and setup_machine.sh

log_echo() {
    echo -e "$@"
    if [ -n "${REGRESS_LOG_FILE:-}" ]; then
        echo -e "$@" >> "${REGRESS_LOG_FILE}"
    fi
}

read_sysfs() {
    local file="$1"
    [ -f "$file" ] && cat "$file" 2>/dev/null || echo ""
}
