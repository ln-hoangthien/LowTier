#!/bin/bash
# ------------------------------------------------------------------------------
# Machine & Hardware Setup Script
# Configures CPU & Uncore frequency locking, Intel Turbo Boost, and core topology
# Usage: sudo ./setup_machine.sh [--restore | --status | --help]
# ------------------------------------------------------------------------------

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

# ------------------------------------------------------------------------------
# Fixed Machine & Hardware Parameters
# ------------------------------------------------------------------------------
UNCORE_PKG0_TARGET=2500000  # Pkg 0 (Fast tier): 2.5 GHz
UNCORE_PKG1_TARGET=1300000  # Pkg 1 (Slow tier): 1.3 GHz
CPU_GOVERNOR="performance"
CPU_MIN_FREQ=2100000        # Base clock: 2.1 GHz
CPU_MAX_FREQ=2100000        # Base clock: 2.1 GHz
WORKLOAD_CORES=24           # 24 physical cores (0..23) for workload
SELECTED_CPUS="0-23"

# ------------------------------------------------------------------------------
# Helper: Print log message with optional tee to REGRESS_LOG_FILE
# ------------------------------------------------------------------------------
log_echo() {
    echo -e "$@"
    if [ -n "${REGRESS_LOG_FILE:-}" ]; then
        echo -e "$@" >> "${REGRESS_LOG_FILE}"
    fi
}

# ------------------------------------------------------------------------------
# Helper: Safely read sysfs attribute file
# ------------------------------------------------------------------------------
read_sysfs() {
    local file="$1"
    [ -f "$file" ] && cat "$file" 2>/dev/null || echo ""
}

# ------------------------------------------------------------------------------
# Helper: Online or offline hyperthreads (CPUs 32..64)
# ------------------------------------------------------------------------------
set_cpus_online() {
    local state="$1"
    for cpu in /sys/devices/system/cpu/cpu{32..64}/online; do
        [ -f "$cpu" ] && echo "$state" > "$cpu" 2>/dev/null || true
    done
}

# ------------------------------------------------------------------------------
# Show current machine frequency and topology status
# ------------------------------------------------------------------------------
show_status() {
    local cpu_gov="$(read_sysfs /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    local cpu_epp="$(read_sysfs /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)"
    local cpu_min="$(read_sysfs /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq)"
    local cpu_max="$(read_sysfs /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"
    local cpu0_cur="$(read_sysfs /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)"
    local no_turbo="$(read_sysfs /sys/devices/system/cpu/intel_pstate/no_turbo)"
    local cur_freq_summary
    cur_freq_summary=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null | awk '{sum+=$1; count++; if (min=="" || $1<min) min=$1; if ($1>max) max=$1} END {if (count>0) printf "avg=%.0fkHz (min=%dkHz, max=%dkHz)", sum/count, min, max; else printf "N/A"}')

    local u0_min="$(read_sysfs /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/min_freq_khz)"
    [ -z "$u0_min" ] && u0_min="$(read_sysfs /sys/devices/system/cpu/intel_uncore_frequency/uncore00/min_freq_khz)"
    local u0_max="$(read_sysfs /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/max_freq_khz)"
    [ -z "$u0_max" ] && u0_max="$(read_sysfs /sys/devices/system/cpu/intel_uncore_frequency/uncore00/max_freq_khz)"

    local u1_min="$(read_sysfs /sys/devices/system/cpu/intel_uncore_frequency/package_01_die_00/min_freq_khz)"
    [ -z "$u1_min" ] && u1_min="$(read_sysfs /sys/devices/system/cpu/intel_uncore_frequency/uncore01/min_freq_khz)"
    local u1_max="$(read_sysfs /sys/devices/system/cpu/intel_uncore_frequency/package_01_die_00/max_freq_khz)"
    [ -z "$u1_max" ] && u1_max="$(read_sysfs /sys/devices/system/cpu/intel_uncore_frequency/uncore01/max_freq_khz)"

    local online_cpus=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "N/A")
    log_echo "[*] CPU Power & Frequency Profile: gov=${cpu_gov:-N/A} (epp=${cpu_epp:-N/A}), clamped=${cpu_min:-N/A}-${cpu_max:-N/A}kHz, cur_freq=${cur_freq_summary} (cpu0=${cpu0_cur:-N/A}kHz)"
    log_echo "[*] Machine Status: turbo=$([ "${no_turbo}" == "1" ] && echo "DISABLED(no_turbo=1)" || echo "active(no_turbo=0)"), uncore_pkg0=${u0_min:-N/A}-${u0_max:-N/A}kHz, uncore_pkg1=${u1_min:-N/A}-${u1_max:-N/A}kHz, online_cores=${online_cpus}"
}

# ------------------------------------------------------------------------------
# Restore machine hardware settings to default / powersave state
# ------------------------------------------------------------------------------
restore_machine() {
    log_echo "[*] Restoring machine configuration..."

    # Re-enable Intel Turbo Boost
    [ -w /sys/devices/system/cpu/intel_pstate/no_turbo ] && echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true

    # Bring all hyperthreads back online
    set_cpus_online 1

    # Restore default governor
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -w "$cpu/cpufreq/scaling_governor" ] && echo "powersave" > "$cpu/cpufreq/scaling_governor" 2>/dev/null || true
    done

    log_echo "[+] Machine configuration restored."
}

# ------------------------------------------------------------------------------
# Configure deterministic machine hardware environment
# ------------------------------------------------------------------------------
configure_machine() {
    log_echo "[*] Starting machine setup: Locking CPU & uncore frequencies..."

    # 1. Disable Intel Turbo Boost explicitly to eliminate dynamic frequency jitter
    [ -w /sys/devices/system/cpu/intel_pstate/no_turbo ] && echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true

    # 2. Uncore Frequency: Lock Fast Tier (Pkg 0) to 2.5 GHz, degrade Slow Tier (Pkg 1) to 1.3 GHz
    for p0 in /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00 \
              /sys/devices/system/cpu/intel_uncore_frequency/uncore00; do
        if [ -d "$p0" ]; then
            [ -w "$p0/min_freq_khz" ] && echo "${UNCORE_PKG0_TARGET}" > "$p0/min_freq_khz" 2>/dev/null || true
            [ -w "$p0/max_freq_khz" ] && echo "${UNCORE_PKG0_TARGET}" > "$p0/max_freq_khz" 2>/dev/null || true
        fi
    done

    for p1 in /sys/devices/system/cpu/intel_uncore_frequency/package_01_die_00 \
              /sys/devices/system/cpu/intel_uncore_frequency/uncore01; do
        if [ -d "$p1" ]; then
            [ -w "$p1/min_freq_khz" ] && echo "${UNCORE_PKG1_TARGET}" > "$p1/min_freq_khz" 2>/dev/null || true
            [ -w "$p1/max_freq_khz" ] && echo "${UNCORE_PKG1_TARGET}" > "$p1/max_freq_khz" 2>/dev/null || true
        fi
    done

    # 3. CPU Governor & Frequency Pinning: Lock all online cores symmetrically to base clock (2.1 GHz)
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -w "$cpu/cpufreq/scaling_governor" ] && echo "${CPU_GOVERNOR}" > "$cpu/cpufreq/scaling_governor" 2>/dev/null || true
        [ -w "$cpu/cpufreq/scaling_min_freq" ] && echo "${CPU_MIN_FREQ}" > "$cpu/cpufreq/scaling_min_freq" 2>/dev/null || true
        [ -w "$cpu/cpufreq/scaling_max_freq" ] && echo "${CPU_MAX_FREQ}" > "$cpu/cpufreq/scaling_max_freq" 2>/dev/null || true
    done

    # 4. CPU Topology: Offline hyperthreads 32..64, leaving physical cores 0..31 online
    log_echo "[*] Configuring tiered CPU topology: Offlining CPUs 32..64..."
    set_cpus_online 0

    # 5. Display verified profile summary
    show_status
}

# ------------------------------------------------------------------------------
# Help / Usage Banner
# ------------------------------------------------------------------------------
if [ "${1:-}" == "-h" ] || [ "${1:-}" == "--help" ]; then
    echo "Usage: sudo $0 [--restore | --status | --help]"
    echo "  (No arguments): Lock CPU & uncore frequencies, disable turbo, offline hyperthreads"
    echo "  --restore, -r : Restore Turbo Boost, online all CPUs, reset governor"
    echo "  --status,  -s : Show current machine frequency and topology settings"
    exit 0
fi

# ------------------------------------------------------------------------------
# Root Privilege Elevation
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "[!] Machine setup requires root privileges. Elevating via sudo..."
    exec sudo env PATH="$PATH" ROOT_DIR="$ROOT_DIR" "$0" "$@"
fi

# ------------------------------------------------------------------------------
# Main Dispatcher
# ------------------------------------------------------------------------------
case "${1:-}" in
    --restore|-r)
        restore_machine
        ;;
    --status|-s)
        show_status
        ;;
    *)
        configure_machine
        ;;
esac
