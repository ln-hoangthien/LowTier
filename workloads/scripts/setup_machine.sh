#!/bin/bash
# ------------------------------------------------------------------------------
# Machine & Hardware Setup Script
# Configures CPU & Uncore frequency locking, Intel Turbo Boost, and core topology
# Usage: sudo ./setup_machine.sh [--restore | --status | --help]
# ------------------------------------------------------------------------------

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/cpu_config.sh"

# ------------------------------------------------------------------------------
# Fixed Machine & Hardware Parameters
# ------------------------------------------------------------------------------
UNCORE_PKG0_TARGET=2500000  # Pkg 0 (Fast tier): 2.5 GHz
UNCORE_PKG1_TARGET=1300000  # Pkg 1 (Slow tier): 1.3 GHz
CPU_GOVERNOR="performance"
CPU_MIN_FREQ=3000000        # Sustainable all-core Turbo clock: 3.0 GHz (Xeon Gold 6448Y)
CPU_MAX_FREQ=3000000        # Clamped to 3.0 GHz to eliminate dynamic Turbo jitter

# ------------------------------------------------------------------------------
# Helper: Resolve Intel uncore frequency sysfs directory for package (0 or 1)
# (handles package_0X_die_00, package_0X_die_01, and legacy uncore0X layouts)
# ------------------------------------------------------------------------------
get_uncore_dir() {
    local pkg="$1"
    for d in /sys/devices/system/cpu/intel_uncore_frequency/package_0"${pkg}"_die_* \
             /sys/devices/system/cpu/intel_uncore_frequency/uncore0"${pkg}"; do
        [ -d "$d" ] && { echo "$d"; return 0; }
    done
    return 0
}

# ------------------------------------------------------------------------------
# Helper: Safely update a (min, max) sysfs frequency pair in either direction
# (Linux enforces min <= max on every write; writing max -> min -> max handles
#  both raising and lowering without failing on intermediate bounds)
# ------------------------------------------------------------------------------
set_freq_bounds() {
    local min_file="$1" max_file="$2" min_val="$3" max_val="$4"
    [ -n "$max_val" ] && [ -w "$max_file" ] && echo "$max_val" > "$max_file" 2>/dev/null || true
    [ -n "$min_val" ] && [ -w "$min_file" ] && echo "$min_val" > "$min_file" 2>/dev/null || true
    [ -n "$max_val" ] && [ -w "$max_file" ] && echo "$max_val" > "$max_file" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Helper: Lock a single CPU's governor and clamped frequency
# ------------------------------------------------------------------------------
lock_cpu_freq() {
    local cpu="$1"
    [ -w "$cpu/cpufreq/scaling_governor" ] && echo "${CPU_GOVERNOR}" > "$cpu/cpufreq/scaling_governor" 2>/dev/null || true
    set_freq_bounds "$cpu/cpufreq/scaling_min_freq" "$cpu/cpufreq/scaling_max_freq" "${CPU_MIN_FREQ}" "${CPU_MAX_FREQ}"
}

# ------------------------------------------------------------------------------
# Helper: Online or offline CPUs (${OFFLINE_CPU_START}..${OFFLINE_CPU_END})
# ------------------------------------------------------------------------------
set_cpus_online() {
    local state="$1" c cpu cur
    CPUS_CHANGED=0
    for (( c = OFFLINE_CPU_START; c <= OFFLINE_CPU_END; c++ )); do
        cpu="/sys/devices/system/cpu/cpu${c}/online"
        [ -f "$cpu" ] || continue
        read -r cur < "$cpu" 2>/dev/null || continue
        if [ "$cur" != "$state" ]; then
            echo "$state" > "$cpu" 2>/dev/null || true
            CPUS_CHANGED=1
        fi
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
    local no_turbo="$(read_sysfs /sys/devices/system/cpu/intel_pstate/no_turbo)"

    local u0_dir="$(get_uncore_dir 0)"
    local u1_dir="$(get_uncore_dir 1)"
    local u0_min="$( [ -n "$u0_dir" ] && read_sysfs "$u0_dir/min_freq_khz" )"
    local u0_max="$( [ -n "$u0_dir" ] && read_sysfs "$u0_dir/max_freq_khz" )"
    local u1_min="$( [ -n "$u1_dir" ] && read_sysfs "$u1_dir/min_freq_khz" )"
    local u1_max="$( [ -n "$u1_dir" ] && read_sysfs "$u1_dir/max_freq_khz" )"

    local online_cpus=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "N/A")
    log_echo "[*] CPU Power & Frequency Profile: gov=${cpu_gov:-N/A} (epp=${cpu_epp:-N/A}), clamped=${cpu_min:-N/A}-${cpu_max:-N/A}kHz"
    log_echo "[*] Machine Status: turbo=$([ "${no_turbo}" == "1" ] && echo "DISABLED(no_turbo=1)" || echo "active(no_turbo=0)"), uncore_pkg0=${u0_min:-N/A}-${u0_max:-N/A}kHz, uncore_pkg1=${u1_min:-N/A}-${u1_max:-N/A}kHz, online_cores=${online_cpus}"
}

# ------------------------------------------------------------------------------
# Restore machine hardware settings to default / powersave state
# ------------------------------------------------------------------------------
restore_machine() {
    log_echo "[*] Restoring machine configuration..."

    # Re-enable Intel Turbo Boost and bring all hyperthreads back online
    [ -w /sys/devices/system/cpu/intel_pstate/no_turbo ] && echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    set_cpus_online 1

    # Restore default CPU governor and unclamp CPU frequency limits
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        local hw_min="$(read_sysfs "$cpu/cpufreq/cpuinfo_min_freq")"
        local hw_max="$(read_sysfs "$cpu/cpufreq/cpuinfo_max_freq")"
        [ -w "$cpu/cpufreq/scaling_governor" ] && echo "powersave" > "$cpu/cpufreq/scaling_governor" 2>/dev/null || true
        set_freq_bounds "$cpu/cpufreq/scaling_min_freq" "$cpu/cpufreq/scaling_max_freq" "$hw_min" "$hw_max"
    done

    # Restore default uncore frequency limits on both packages
    for pkg in 0 1; do
        local udir="$(get_uncore_dir "$pkg")"
        if [ -n "$udir" ]; then
            local u_init_min="$(read_sysfs "$udir/initial_min_freq_khz")"
            local u_init_max="$(read_sysfs "$udir/initial_max_freq_khz")"
            set_freq_bounds "$udir/min_freq_khz" "$udir/max_freq_khz" "$u_init_min" "$u_init_max"
        fi
    done

    log_echo "[+] Machine configuration restored."
}

# ------------------------------------------------------------------------------
# Configure deterministic machine hardware environment
# ------------------------------------------------------------------------------
configure_machine() {
    log_echo "[*] Starting machine setup: Locking CPU & uncore frequencies..."

    # 1. Enable Turbo Boost so cores can reach the clamped 3.0 GHz all-core target (jitter prevented by min=max clamp)
    [ -w /sys/devices/system/cpu/intel_pstate/no_turbo ] && echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true

    # 2. Uncore Frequency: Lock Fast Tier (Pkg 0) to 2.5 GHz, Slow Tier (Pkg 1) to 1.3 GHz
    local u0_dir="$(get_uncore_dir 0)"
    local u1_dir="$(get_uncore_dir 1)"
    [ -n "$u0_dir" ] && set_freq_bounds "$u0_dir/min_freq_khz" "$u0_dir/max_freq_khz" "${UNCORE_PKG0_TARGET}" "${UNCORE_PKG0_TARGET}"
    [ -n "$u1_dir" ] && set_freq_bounds "$u1_dir/min_freq_khz" "$u1_dir/max_freq_khz" "${UNCORE_PKG1_TARGET}" "${UNCORE_PKG1_TARGET}"

    # 3. CPU Governor & Frequency Pinning: Lock all online cores symmetrically to 3.0 GHz (min=max)
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        lock_cpu_freq "$cpu"
    done

    # 3.1. Display verified profile summary (captures Pkg 1 uncore before CPUs 32..64 go offline)
    show_status

    # 4. CPU Topology: Offline CPUs ${OFFLINE_CPU_START}..${OFFLINE_CPU_END}, leaving Socket 0 physical cores online
    set_cpus_online 0
    if [ "${CPUS_CHANGED}" -eq 1 ]; then
        log_echo "[*] Configured tiered CPU topology: Offlined CPUs ${OFFLINE_CPU_START}..${OFFLINE_CPU_END}."

        # 4.1. Workaround for Linux 5.13-rc6 (Nomad) CPU hotplug ordering bug:
        #      migration_offline_cpu (CPUHP_AP_ONLINE_DYN) runs before vmstat_cpu_dead
        #      (CPUHP_MM_VMSTAT_DEAD) clears Node 1 from N_CPU, leaving node_demotion[0]=-1.
        #      Bouncing one Node 0 CPU afterward re-triggers set_migration_target_nodes().
        local kver="$(uname -r)"
        if [[ "${kver,,}" =~ nomad ]]; then
            local bounce_cpu="/sys/devices/system/cpu/cpu${PREFETCH_MON_CPU}"
            if [ -f "${bounce_cpu}/online" ]; then
                echo 0 > "${bounce_cpu}/online" 2>/dev/null || true
                echo 1 > "${bounce_cpu}/online" 2>/dev/null || true
                lock_cpu_freq "${bounce_cpu}"
            fi
        fi

        # 4.2. Display verified post-hotplug profile summary
        show_status
    else
        log_echo "[+] Tiered CPU topology already active (CPUs ${OFFLINE_CPU_START}..${OFFLINE_CPU_END} offline); skipping hotplug."
    fi
}

# ------------------------------------------------------------------------------
# Help / Usage Banner
# ------------------------------------------------------------------------------
if [ "${1:-}" == "-h" ] || [ "${1:-}" == "--help" ]; then
    echo "Usage: sudo $0 [--restore | --status | --help]"
    echo "  (No arguments): Pin CPU (3.0 GHz) & uncore frequencies, offline hyperthreads"
    echo "  --restore, -r : Restore Turbo Boost, online all CPUs, reset governor"
    echo "  --status,  -s : Show current machine frequency and topology settings"
    exit 0
fi

# ------------------------------------------------------------------------------
# Root Privilege Elevation (status/help do not require root)
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ] && [ "${1:-}" != "--status" ] && [ "${1:-}" != "-s" ] && [ "${1:-}" != "--help" ] && [ "${1:-}" != "-h" ]; then
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
