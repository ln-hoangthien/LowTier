#!/bin/bash
# ------------------------------------------------------------------------------
# Kernel & Tiered Memory Setup Script
# Configures kernel tiering parameters, baselines, prefetch sysfs, and THP
# Usage: sudo ./setup_kernel.sh [--status | --help]
# ------------------------------------------------------------------------------

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
KERNEL_VER="$(uname -r)"

# Default parameter resolution
THP_MODE="${THP_MODE:-madvise}"
PREFETCH_ENABLED="${PREFETCH_ENABLED:-1}"
PREFETCH_ADAPTIVE="${PREFETCH_ADAPTIVE:-1}"
PREFETCH_HINT="${PREFETCH_HINT:-0}"
PREFETCH_PROMOTE_DISTANCE="${PREFETCH_PROMOTE_DISTANCE:-5}"
PREFETCH_DEMOTE_DISTANCE="${PREFETCH_DEMOTE_DISTANCE:-2}"
PREFETCH_MIN_DISTANCE="${PREFETCH_MIN_DISTANCE:-0}"
PREFETCH_MAX_DISTANCE="${PREFETCH_MAX_DISTANCE:-12}"
TARGET_EXE_NAME="${TARGET_EXE_NAME:-pr}"

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
# Helper: Write and verify kernel sysfs attribute
# ------------------------------------------------------------------------------
write_sysfs_verified() {
    local file="$1" val="$2" label="${3:-$(basename "$1")}"
    [ -f "$file" ] || return 1

    if ! echo "$val" > "$file" 2>/dev/null; then
        log_echo "\033[1;33m[WARNING] Failed to write '$val' to sysfs attribute '$label' ($file)!\033[0m"
        return 1
    fi
    local readback
    read -r readback < "$file" 2>/dev/null || true
    if [ "$readback" != "$val" ]; then
        log_echo "\033[1;33m[WARNING] Sysfs mismatch for '$label': requested '$val', but kernel read back '$readback'!\033[0m"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Helper: Ensure kernel module is compiled and loaded
# ------------------------------------------------------------------------------
ensure_module_loaded() {
    local mod_name="$1" base_dir="$2" sub_dir="$3" label="$4"
    local mod_id="${mod_name//-/_}"

    grep -q "^${mod_id}[[:space:]]" /proc/modules 2>/dev/null && return 0

    local target_dir="${base_dir}${sub_dir:+/${sub_dir}}"
    local mod_file="${target_dir}/${mod_name}.ko"
    if [ ! -f "${mod_file}" ]; then
        mod_file=$(ls "${ROOT_DIR}"/baselines/*/${sub_dir:+${sub_dir}/}${mod_name}.ko 2>/dev/null | head -n 1 || true)
    fi

    if [ ! -f "${mod_file}" ] && [ -d "${target_dir}" ]; then
        log_echo "[*] Compiling ${label} ${mod_name}.ko..."
        if [ -d "${base_dir}/linux" ]; then
            make -C "${base_dir}/linux" M="${target_dir}" modules >/dev/null 2>&1 || true
        else
            make -C "${target_dir}" >/dev/null 2>&1 || true
        fi
        mod_file="${target_dir}/${mod_name}.ko"
    fi

    if [ -f "${mod_file}" ]; then
        log_echo "[*] Loading ${label} ${mod_name} module (${mod_file})..."
        insmod "${mod_file}" 2>/dev/null || true
    fi

    if grep -q "^${mod_id}[[:space:]]" /proc/modules 2>/dev/null; then
        log_echo "[+] ${label} ${mod_name} module loaded."
        return 0
    else
        log_echo "\033[1;33m[WARNING] ${label} kernel detected but ${mod_name}.ko is not loaded!\033[0m"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Show current kernel tiering, prefetch, and THP configuration status
# ------------------------------------------------------------------------------
show_status() {
    local prefetch_sysfs=""
    [ -d "/sys/kernel/mm/page_prefetch" ] && prefetch_sysfs="/sys/kernel/mm/page_prefetch"
    [ -d "/sys/kernel/mm/pact_prefetch" ] && prefetch_sysfs="/sys/kernel/mm/pact_prefetch"

    log_echo "=========================================================================================="
    log_echo " Kernel Tiering & Prefetch Configuration Status (${KERNEL_VER})"
    log_echo "=========================================================================================="
    if [ -n "$prefetch_sysfs" ]; then
        local cur_en="$(read_sysfs "${prefetch_sysfs}/enabled")"
        local cur_hint="$(read_sysfs "${prefetch_sysfs}/hint")"
        local cur_adap="$(read_sysfs "${prefetch_sysfs}/adaptive")"
        local cur_prom="$(read_sysfs "${prefetch_sysfs}/promote_distance")"
        local cur_dem="$(read_sysfs "${prefetch_sysfs}/demote_distance")"
        local cur_min="$(read_sysfs "${prefetch_sysfs}/min_distance")"
        local cur_max="$(read_sysfs "${prefetch_sysfs}/max_distance")"
        log_echo "[*] Migration Prefetch (${prefetch_sysfs}): enabled=${cur_en}, adaptive=${cur_adap}, hint=${cur_hint}, promote=${cur_prom:-N/A}, demote=${cur_dem:-N/A}, min=${cur_min:-N/A}, max=${cur_max:-N/A}"
    else
        log_echo "[*] Migration Prefetch: Not present in this kernel"
    fi

    local cur_thp="$(read_sysfs /sys/kernel/mm/transparent_hugepage/enabled)"
    local cur_defrag="$(read_sysfs /sys/kernel/mm/transparent_hugepage/defrag)"
    log_echo "[*] Transparent Huge Pages (THP): enabled=${cur_thp:-N/A}, defrag=${cur_defrag:-N/A}"

    local demote_en="$(read_sysfs /sys/kernel/mm/numa/demotion_enabled)"
    local numa_bal="$(sysctl -n kernel.numa_balancing 2>/dev/null || true)"
    local tiers="$(ls -d /sys/devices/virtual/memory_tiering/memory_tier* 2>/dev/null | xargs -n 1 basename 2>/dev/null | tr '\n' ' ' || true)"
    log_echo "[*] Node 0 Tiering Status: demotion_enabled=${demote_en:-false}, numa_balancing=${numa_bal}${tiers:+, tiers=[${tiers% }]}"
    log_echo "[*] Node 0 Watermark Buffer: min_free_kbytes=$(sysctl -n vm.min_free_kbytes 2>/dev/null), watermark_scale_factor=$(sysctl -n vm.watermark_scale_factor 2>/dev/null)"
    log_echo "=========================================================================================="
}

# ------------------------------------------------------------------------------
# Configure kernel tiering, baseline environments, prefetch sysfs, and THP
# ------------------------------------------------------------------------------
configure_kernel() {
    log_echo "[*] Starting kernel setup for: ${KERNEL_VER}..."

    # Unload kswapdrst if active to allow normal allocation fallback
    if grep -q "^kswapdrst[[:space:]]" /proc/modules 2>/dev/null; then
        log_echo "[*] Unloading kswapdrst module to allow direct allocation fallback to Node 1..."
        rmmod kswapdrst 2>/dev/null || true
    fi

    # Unified Little's Law Memory Latency Monitor
    if [[ "${KERNEL_VER,,}" =~ prefetch ]] && [[ ! "${KERNEL_VER,,}" =~ colloid|pact ]]; then
        ensure_module_loaded "tier_latency_mon" "${ROOT_DIR}/baselines/tier-latency-mon" "" "Tier Latency Monitor"
    fi

    # ------------------
    # NOMAD Setup
    # ------------------
    if [[ "${KERNEL_VER,,}" =~ nomad ]]; then
        local nomad_dir="${ROOT_DIR}/baselines/nomad"
        [[ "${KERNEL_VER,,}" =~ alto ]] && nomad_dir+="-alto"
        [[ "${KERNEL_VER,,}" =~ prefetch ]] && nomad_dir+="-prefetch"
        [ ! -d "${nomad_dir}" ] && nomad_dir=$(ls -d ${ROOT_DIR}/baselines/nomad* 2>/dev/null | head -n 1 || true)
        ensure_module_loaded "async_promote" "${nomad_dir}" "nomad_module" "Nomad"

        log_echo "[*] Activating Nomad Tiered NUMA Balancing (mode 2)..."
        sysctl -w kernel.numa_balancing=2 2>/dev/null || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # ------------------
    # Memtis Setup
    # ------------------
    elif [[ "${KERNEL_VER,,}" =~ memtis|htmm ]]; then
        sysctl -w kernel.numa_balancing=0 2>/dev/null || true
        echo false > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

        [ -f /sys/kernel/mm/htmm/htmm_mode ] && echo 2 > /sys/kernel/mm/htmm/htmm_mode 2>/dev/null || true
        [ -f /sys/kernel/mm/htmm/htmm_cxl_mode ] && echo "enabled" > /sys/kernel/mm/htmm/htmm_cxl_mode 2>/dev/null || true

        echo "${THP_MODE}" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
        echo "defer" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

        echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
        echo "+cpuset" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
        local memtis_cgroup="/sys/fs/cgroup/memtis_workload"
        mkdir -p "${memtis_cgroup}" 2>/dev/null || true
        [ -f "${memtis_cgroup}/memory.htmm_enabled" ] && echo "enabled" > "${memtis_cgroup}/memory.htmm_enabled" 2>/dev/null || true
        [ -f "${memtis_cgroup}/cgroup.procs" ] && { echo "${PPID}" > "${memtis_cgroup}/cgroup.procs" 2>/dev/null || true; echo $$ > "${memtis_cgroup}/cgroup.procs" 2>/dev/null || true; }

        local node0_total_kb=$(awk '/MemTotal:/ {print $4}' /sys/devices/system/node/node0/meminfo 2>/dev/null || echo 0)
        local reserved_kb=2097152  # 2.0 GB reserve
        local node0_usable_bytes=$(( (node0_total_kb - reserved_kb) * 1024 ))

        if [ -f "${memtis_cgroup}/memory.max_at_node0" ]; then
            echo "${node0_usable_bytes}" > "${memtis_cgroup}/memory.max_at_node0" 2>/dev/null || true
            log_echo "[*] Memtis Node 0 Memory Quota set to: $(cat "${memtis_cgroup}/memory.max_at_node0" 2>/dev/null || echo "${node0_usable_bytes}")"
        fi

        if ! pgrep -x ksamplingd >/dev/null 2>&1; then
            python3 -c "import ctypes; ctypes.CDLL(None).syscall(449, -1, 0)" 2>/dev/null || true
            sleep 1
        fi
        if pgrep -x ksamplingd >/dev/null 2>&1; then
            log_echo "[+] Memtis ksamplingd daemon is active (PID $(pgrep -x ksamplingd))."
        else
            log_echo "[!] Note: Memtis ksamplingd is not running."
        fi

    # ------------------
    # Colloid Setup
    # ------------------
    elif [[ "${KERNEL_VER,,}" =~ colloid ]]; then
        local colloid_dir="${ROOT_DIR}/baselines/colloid-tpp"
        [[ "${KERNEL_VER,,}" =~ alto ]] && colloid_dir+="-alto"
        [[ "${KERNEL_VER,,}" =~ prefetch ]] && colloid_dir+="-prefetch"
        [ ! -d "${colloid_dir}" ] && colloid_dir=$(ls -d ${ROOT_DIR}/baselines/colloid* 2>/dev/null | head -n 1 || true)

        ensure_module_loaded "tierinit" "${colloid_dir}" "tierinit" "Colloid"
        ensure_module_loaded "colloid-mon" "${colloid_dir}" "colloid-mon" "Colloid"

        log_echo "[*] Activating Colloid Tiered NUMA Balancing (mode 6: TIERING | COLLOID)..."
        sysctl -w kernel.numa_balancing=6 2>/dev/null || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # ------------------
    # PACT Setup
    # ------------------
    elif [[ "${KERNEL_VER,,}" =~ pact ]]; then
        local pact_dir="${ROOT_DIR}/baselines/pact"
        if [[ "${KERNEL_VER,,}" =~ prefetch.*batch ]]; then
            pact_dir+="-prefetch-batch"
        elif [[ "${KERNEL_VER,,}" =~ prefetch ]]; then
            pact_dir+="-prefetch"
        fi
        [ ! -d "${pact_dir}" ] && pact_dir=$(ls -d ${ROOT_DIR}/baselines/pact* 2>/dev/null | head -n 1 || true)

        ensure_module_loaded "tierinit" "${pact_dir}" "tierinit" "PACT"
        ensure_module_loaded "kswapdrst" "${pact_dir}" "kswapdrst" "PACT"

        log_echo "[*] Activating PACT kernel tiering environment..."
        sysctl -w kernel.numa_balancing=0 2>/dev/null || true
        sysctl -w kernel.perf_event_paranoid=-1 2>/dev/null || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # ------------------
    # HybridTier Setup
    # ------------------
    elif [[ "${KERNEL_VER,,}" =~ hybridtier ]]; then
        local hybridtier_dir="${ROOT_DIR}/baselines/hybridtier"
        [ ! -d "${hybridtier_dir}" ] && hybridtier_dir=$(ls -d ${ROOT_DIR}/baselines/hybridtier* 2>/dev/null | head -n 1 || true)

        if [ -d "${hybridtier_dir}/hook" ]; then
            make -C "${hybridtier_dir}/hook" TARGET_EXE_NAME="${TARGET_EXE_NAME}" >/dev/null 2>&1 || true
        fi

        local hook_so="${hybridtier_dir}/hook/hook.so"
        if [ -f "${hook_so}" ]; then
            log_echo "[+] HybridTier hook library detected: ${hook_so}"
        fi

        log_echo "[*] Activating HybridTier kernel environment..."
        sysctl -w vm.zone_reclaim_mode=0 >/dev/null 2>&1 || true
        sysctl -w kernel.numa_balancing=0 >/dev/null 2>&1 || true
        sysctl -w vm.watermark_scale_factor=10 >/dev/null 2>&1 || true
        echo false > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true
        echo 0x0000 > /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true
        sysctl -w kernel.perf_event_max_sample_rate=150000 >/dev/null 2>&1 || true
        sysctl -w kernel.perf_cpu_time_max_percent=0 >/dev/null 2>&1 || true
        sysctl -w kernel.perf_event_paranoid=-1 >/dev/null 2>&1 || true

        if [ ! -e "/ssd1/songxin8/thesis/autonuma/linux-6.1-rc6/tools/perf/perf" ]; then
            mkdir -p /ssd1/songxin8/thesis/autonuma/linux-6.1-rc6/tools/perf 2>/dev/null || true
            ln -sf "$(command -v perf || echo /usr/bin/perf)" /ssd1/songxin8/thesis/autonuma/linux-6.1-rc6/tools/perf/perf 2>/dev/null || true
        fi

    # ------------------------------------
    # AutoNUMA (Generic) Setup
    # ------------------------------------
    elif [[ "${KERNEL_VER,,}" =~ generic ]]; then
        log_echo "[*] Activating AutoNUMA + Tiered Balancing for generic kernel (mode 3)..."
        sysctl -w kernel.numa_balancing=3 2>/dev/null || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # ------------------------------------
    # Upstream TPP / Generic Fallback
    # ------------------------------------
    else
        log_echo "[*] Activating Tiered NUMA Balancing (mode 2)..."
        sysctl -w kernel.numa_balancing=2 2>/dev/null || sysctl -w kernel.numa_balancing=1 2>/dev/null || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true
    fi

    # ------------------------------------------------------------------------------------------
    # Migration Prefetch Online Configuration
    # ------------------------------------------------------------------------------------------
    local prefetch_sysfs=""
    [ -d "/sys/kernel/mm/page_prefetch" ] && prefetch_sysfs="/sys/kernel/mm/page_prefetch"
    [ -d "/sys/kernel/mm/pact_prefetch" ] && prefetch_sysfs="/sys/kernel/mm/pact_prefetch"

    if [ -n "$prefetch_sysfs" ]; then
        write_sysfs_verified "${prefetch_sysfs}/enabled" "${PREFETCH_ENABLED}" "enabled"
        write_sysfs_verified "${prefetch_sysfs}/adaptive" "${PREFETCH_ADAPTIVE}" "adaptive"
        write_sysfs_verified "${prefetch_sysfs}/hint" "${PREFETCH_HINT}" "hint"

        # Clamp distance limits
        write_sysfs_verified "${prefetch_sysfs}/min_distance" "${PREFETCH_MIN_DISTANCE}" "min_distance" || true
        write_sysfs_verified "${prefetch_sysfs}/max_distance" "${PREFETCH_MAX_DISTANCE}" "max_distance" || true

        if [ -f "${prefetch_sysfs}/promote_distance" ]; then
            if [ "${PREFETCH_ENABLED}" != "0" ]; then
                write_sysfs_verified "${prefetch_sysfs}/promote_distance" "${PREFETCH_PROMOTE_DISTANCE}" "promote_distance"
                write_sysfs_verified "${prefetch_sysfs}/demote_distance"  "${PREFETCH_DEMOTE_DISTANCE}"  "demote_distance"
            fi
        fi

        # Read back verified parameters for logging
        local cur_en cur_hint cur_adap cur_prom cur_dem cur_min cur_max
        cur_en="$(read_sysfs "${prefetch_sysfs}/enabled")"
        cur_hint="$(read_sysfs "${prefetch_sysfs}/hint")"
        cur_adap="$(read_sysfs "${prefetch_sysfs}/adaptive")"
        cur_prom="$(read_sysfs "${prefetch_sysfs}/promote_distance")"
        cur_dem="$(read_sysfs "${prefetch_sysfs}/demote_distance")"
        cur_min="$(read_sysfs "${prefetch_sysfs}/min_distance")"
        cur_max="$(read_sysfs "${prefetch_sysfs}/max_distance")"

        if [ "$cur_en" == "0" ]; then
            log_echo "[*] Migration Prefetch Online Parameters (${prefetch_sysfs}): enabled=0 (disabled), hint=${cur_hint:-0}"
        elif [ -f "${prefetch_sysfs}/promote_distance" ]; then
            local extra_info=""
            [ -n "$cur_min" ] && extra_info+=", min_dist=${cur_min}"
            [ -n "$cur_max" ] && extra_info+=", max_dist=${cur_max}"
            local mode_str="$([ "$cur_adap" == "1" ] && echo "adaptive" || echo "static")"
            local tier_info=" (promote=${cur_prom:-$PREFETCH_PROMOTE_DISTANCE}, demote=${cur_dem:-$PREFETCH_DEMOTE_DISTANCE}, mode=${mode_str}${extra_info})"
            log_echo "[*] Migration Prefetch Online Parameters (${prefetch_sysfs}): enabled=${cur_en}${tier_info}, hint=${cur_hint:-0}"
        else
            log_echo "[*] Migration Prefetch Online Parameters (${prefetch_sysfs}): enabled=${cur_en}, hint=${cur_hint:-0}"
        fi
    fi

    # ------------------------------------------------------------------------------------------
    # Transparent Huge Pages (THP) Online Configuration
    # ------------------------------------------------------------------------------------------
    echo "${THP_MODE}" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo "defer" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    local cur_thp="$(read_sysfs /sys/kernel/mm/transparent_hugepage/enabled)"
    local cur_defrag="$(read_sysfs /sys/kernel/mm/transparent_hugepage/defrag)"
    log_echo "[*] Transparent Huge Pages (THP): enabled=${cur_thp:-N/A} (target=${THP_MODE}), defrag=${cur_defrag:-N/A}"

    # Log active demotion target and watermark state
    local demote_en="$(read_sysfs /sys/kernel/mm/numa/demotion_enabled)"
    local numa_bal="$(sysctl -n kernel.numa_balancing 2>/dev/null || true)"
    local tiers="$(ls -d /sys/devices/virtual/memory_tiering/memory_tier* 2>/dev/null | xargs -n 1 basename 2>/dev/null | tr '\n' ' ' || true)"
    log_echo "[*] Node 0 Tiering Status: demotion_enabled=${demote_en:-false}, numa_balancing=${numa_bal}${tiers:+, tiers=[${tiers% }]}"
    log_echo "[*] Node 0 Watermark Buffer: min_free_kbytes=$(sysctl -n vm.min_free_kbytes 2>/dev/null), watermark_scale_factor=$(sysctl -n vm.watermark_scale_factor 2>/dev/null)"
}

# ------------------------------------------------------------------------------
# Baseline Autotie: Start / Hook daemons to workload process
# ------------------------------------------------------------------------------
autotie_start() {
    # PACT autotie: Launch background watcher to attach PACT daemon once workload starts
    if [[ "${KERNEL_VER,,}" =~ pact ]]; then
        local pact_bin="${ROOT_DIR}/baselines/pact/src/pact"
        if [[ "${KERNEL_VER,,}" =~ prefetch.*batch ]] && [ -x "${ROOT_DIR}/baselines/pact-prefetch-batch/src/pact" ]; then
            pact_bin="${ROOT_DIR}/baselines/pact-prefetch-batch/src/pact"
        elif [[ "${KERNEL_VER,,}" =~ prefetch ]] && [ -x "${ROOT_DIR}/baselines/pact-prefetch/src/pact" ]; then
            pact_bin="${ROOT_DIR}/baselines/pact-prefetch/src/pact"
        fi
        [ ! -x "${pact_bin}" ] && pact_bin=$(ls -d "${ROOT_DIR}"/baselines/pact*/src/pact 2>/dev/null | head -n 1 || true)

        if [ ! -x "${pact_bin}" ]; then
            log_echo "\033[1;33m[WARNING] PACT binary not found or not executable!\033[0m"
            return 0
        fi

        local pact_actual_pid_file="/tmp/pact_actual_pid"
        local pact_watcher_pid_file="/tmp/pact_watcher_pid"
        rm -f "${pact_actual_pid_file}" "${pact_watcher_pid_file}"

        local pact_log_file="${TARGET_DIR:-/tmp}/pact_${FILENAME_SUFFIX:-run}.log"
        local target_exe="${TARGET_EXE_NAME:-pr}"
        local regress_log="${REGRESS_LOG_FILE:-}"

        (
            # Workload-specific synchronization:
            # 1. GAPBS: wait until graph file ingestion completes ("Read Time:")
            # 2. Silo: wait until dataloading completes ("starting benchmark")
            # 3. SPEC 2026: wait until dataloading completes ("Running Benchmarks")
            # 4. Redis / Others: default sleep (2s)
            case "${target_exe}" in
                pr|tc|bc|cc|bfs|sssp)
                    echo "[+] PACT sync: Waiting for GAPBS graph ingestion (Read Time) to complete..."
                    local timeout=20000
                    until [ -n "${regress_log}" -a -f "${regress_log}" ] && grep -q "Read Time:" "${regress_log}" 2>/dev/null || [ $((timeout--)) -le 0 ]; do
                        sleep 0.1
                    done
                    ;;

                dbtest)
                    echo "[+] PACT sync: Waiting for Silo dataloading to complete..."
                    local timeout=50000
                    until ([ -n "${regress_log}" -a -f "${regress_log}" ] && grep -q "starting benchmark" "${regress_log}" 2>/dev/null) || [ $((timeout--)) -le 0 ]; do
                        sleep 0.1
                    done
                    ;;

                runcpu|specperl)
                    echo "[+] PACT sync: Waiting for SPEC CPU 2026 setup & compilation to complete..."
                    local timeout=50000
                    until ([ -n "${regress_log}" -a -f "${regress_log}" ] && grep -q "Running Benchmarks" "${regress_log}" 2>/dev/null) || [ $((timeout--)) -le 0 ]; do
                        sleep 0.1
                    done
                    sleep 1
                    ;;

                *)
                    sleep 2
                    ;;
            esac

            # AutoTie: Resolve target workload PID and attach PACT daemon
            local target_pid=""
            if [ -n "${target_exe}" ] && [ "${target_exe}" != "*" ]; then
                target_pid=$(pgrep -n -x "${target_exe}" 2>/dev/null || true)
            fi

            # Redis override: attach to the redis-server database daemon holding the dataset
            if [ "${target_exe}" = "run_redis.sh" ] || [ "${target_exe}" = "redis-server" ]; then
                for attempt in $(seq 1 30); do
                    local redis_pid=$(pgrep -n -x redis-server 2>/dev/null || true)
                    [ -n "${redis_pid}" ] && { target_pid="${redis_pid}"; break; }
                    sleep 0.5
                done
            fi

            # SPEC CPU 2026 override: attach to the actual compute binary (*_base.mytest)
            if [ "${target_exe}" = "runcpu" ] || [ "${target_exe}" = "specperl" ]; then
                for attempt in $(seq 1 30); do
                    local spec_pid=$(pgrep -n -f "_base\." 2>/dev/null || true)
                    [ -n "${spec_pid}" ] && { target_pid="${spec_pid}"; break; }
                    sleep 0.5
                done
            fi

            if [ -n "${target_pid}" ] && kill -0 "${target_pid}" 2>/dev/null; then
                echo "[+] PACT autotie active: Attaching PACT daemon (PID ${target_pid})..."

                # 1. Save Thread 0's original affinity mask (in case Thread 0 is pinned to Core 0)
                local orig_mask=$(taskset -p "${target_pid}" 2>/dev/null | awk '{print $NF}')

                # 2. Temporarily expand Thread 0's mask so PACT discovers all 24 cores at startup
                taskset -p -c "${SELECTED_CPUS:-0-23}" "${target_pid}" >/dev/null 2>&1 || true

                "${pact_bin}" --workload "${target_pid}" --demotion-margin 250000 > "${pact_log_file}" 2>&1 &
                local actual_pact_pid=$!
                echo "${actual_pact_pid}" > "${pact_actual_pid_file}"

                # Asynchronously restore Thread 0's affinity once PACT has finished startup
                ( sleep 0.5; [ -n "${orig_mask}" ] && taskset -p "${orig_mask}" "${target_pid}" >/dev/null 2>&1 || true ) &

                wait "${actual_pact_pid}"
            fi
        ) &
        local watcher_pid=$!
        echo "${watcher_pid}" > "${pact_watcher_pid_file}"
        log_echo "[+] PACT autotie watcher started (PID ${watcher_pid})."
    fi
}

# ------------------------------------------------------------------------------
# Baseline Autotie: Stop daemons and clean up temporary state
# ------------------------------------------------------------------------------
autotie_stop() {
    # Terminate PACT daemon and watcher
    local pact_actual_pid_file="/tmp/pact_actual_pid"
    local pact_watcher_pid_file="/tmp/pact_watcher_pid"
    local actual_pact_pid=$(cat "${pact_actual_pid_file}" 2>/dev/null || true)

    if [ -n "${actual_pact_pid}" ] && kill -0 "${actual_pact_pid}" 2>/dev/null; then
        log_echo "[*] Waiting for PACT daemon (PID ${actual_pact_pid}) to finalize..."
        for i in {1..20}; do
            kill -0 "${actual_pact_pid}" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "${actual_pact_pid}" 2>/dev/null; then
            kill -INT "${actual_pact_pid}" 2>/dev/null || true
            sleep 0.5
        fi
        if kill -0 "${actual_pact_pid}" 2>/dev/null; then
            kill -9 "${actual_pact_pid}" 2>/dev/null || true
        fi
    fi

    local watcher_pid=$(cat "${pact_watcher_pid_file}" 2>/dev/null || true)
    if [ -n "${watcher_pid}" ]; then
        kill -9 "${watcher_pid}" 2>/dev/null || true
    fi
    rm -f "${pact_actual_pid_file}" "${pact_watcher_pid_file}"

    # Terminate orphan perf stat process spawned by HybridTier's hook.so
    if [[ "${KERNEL_VER,,}" =~ hybridtier ]]; then
        pkill -f "perf stat -I 60000" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Baseline Autotie: Wrap workload command with required preload environment
# ------------------------------------------------------------------------------
autotie_wrap() {
    shift # Remove --wrap-cmd argument
    if [[ "${KERNEL_VER,,}" =~ hybridtier ]]; then
        local hybrid_hook="${HYBRIDTIER_HOOK:-${ROOT_DIR}/baselines/hybridtier/hook/hook.so}"
        if [ -f "${hybrid_hook}" ]; then
            echo "env LD_PRELOAD=\"${hybrid_hook}\${LD_PRELOAD:+:\$LD_PRELOAD}\" TARGET_EXE_NAME=\"${TARGET_EXE_NAME}\" $*"
            return 0
        fi
    fi
    echo "$*"
}

# ------------------------------------------------------------------------------
# Clean up kernel tiering state and unload baseline modules
# ------------------------------------------------------------------------------
cleanup_kernel() {
    log_echo "[*] Cleaning up kernel tiering state and modules..."

    # Stop any running autotie daemons first
    autotie_stop

    # Clean up Memtis state: Stop ksamplingd BEFORE restoring CPUs.
    if [[ "${KERNEL_VER,,}" =~ memtis|htmm ]]; then
        if pgrep -x ksamplingd >/dev/null 2>&1; then
            python3 -c "import ctypes; ctypes.CDLL(None).syscall(450, -1)" 2>/dev/null || true
        fi
        if [ -f /sys/fs/cgroup/memtis_workload/memory.htmm_enabled ]; then
            echo "disabled" > /sys/fs/cgroup/memtis_workload/memory.htmm_enabled 2>/dev/null || true
        fi
    fi

    # Unload tier-latency-mon, colloid-mon, and kswapdrst if active
    rmmod tier_latency_mon 2>/dev/null || true
    rmmod colloid-mon 2>/dev/null || true
    rmmod kswapdrst 2>/dev/null || true

    log_echo "[+] Kernel tiering state cleaned up."
}

# ------------------------------------------------------------------------------
# Help / Usage Banner
# ------------------------------------------------------------------------------
if [ "${1:-}" == "-h" ] || [ "${1:-}" == "--help" ]; then
    echo "Usage: sudo $0 [--cleanup | --status | --autotie-start | --autotie-stop | --wrap-cmd <cmd> | --help]"
    echo "  (No arguments)  : Configure kernel tiering, baseline daemons, prefetch sysfs, and THP"
    echo "  --autotie-start : Start baseline autotie background watcher / cgroup attachment"
    echo "  --autotie-stop  : Stop baseline autotie daemons and cleanup"
    echo "  --wrap-cmd <cmd>: Wrap workload command with required preload environment (HybridTier)"
    echo "  --cleanup, -c   : Stop baseline daemons (ksamplingd, pact) and unload tiering modules"
    echo "  --status,  -s   : Show current kernel tiering and prefetch parameters"
    exit 0
fi

# ------------------------------------------------------------------------------
# Root Privilege Elevation
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ] && [ "${1:-}" != "--wrap-cmd" ]; then
    echo "[!] Kernel setup requires root privileges. Elevating via sudo..."
    exec sudo env PATH="$PATH" ROOT_DIR="$ROOT_DIR" THP_MODE="${THP_MODE}" \
        PREFETCH_ENABLED="${PREFETCH_ENABLED}" PREFETCH_ADAPTIVE="${PREFETCH_ADAPTIVE}" \
        PREFETCH_HINT="${PREFETCH_HINT}" PREFETCH_PROMOTE_DISTANCE="${PREFETCH_PROMOTE_DISTANCE}" \
        PREFETCH_DEMOTE_DISTANCE="${PREFETCH_DEMOTE_DISTANCE}" \
        PREFETCH_MIN_DISTANCE="${PREFETCH_MIN_DISTANCE}" \
        PREFETCH_MAX_DISTANCE="${PREFETCH_MAX_DISTANCE}" \
        TARGET_EXE_NAME="${TARGET_EXE_NAME}" "$0" "$@"
fi

# ------------------------------------------------------------------------------
# Main Dispatcher
# ------------------------------------------------------------------------------
case "${1:-}" in
    --cleanup|-c|--restore|-r)
        cleanup_kernel
        ;;
    --status|-s)
        show_status
        ;;
    --autotie-start)
        autotie_start "$@"
        ;;
    --autotie-stop)
        autotie_stop
        ;;
    --wrap-cmd)
        autotie_wrap "$@"
        ;;
    *)
        configure_kernel
        ;;
esac
