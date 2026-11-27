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
source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/cpu_config.sh"

# Default parameter resolution
THP_MODE="${THP_MODE:-madvise}"
PREFETCH_ENABLED="${PREFETCH_ENABLED:-1}"
PREFETCH_NAIVE="${PREFETCH_NAIVE:-0}"
PREFETCH_ADAPTIVE="${PREFETCH_ADAPTIVE:-1}"
PREFETCH_HINT="${PREFETCH_HINT:-0}"
PREFETCH_PROMOTE_DISTANCE="${PREFETCH_PROMOTE_DISTANCE:-5}"
PREFETCH_DEMOTE_DISTANCE="${PREFETCH_DEMOTE_DISTANCE:-2}"
PREFETCH_MIN_DISTANCE="${PREFETCH_MIN_DISTANCE:-0}"
PREFETCH_MAX_DISTANCE="${PREFETCH_MAX_DISTANCE:-12}"
TARGET_EXE_NAME="${TARGET_EXE_NAME:-pr}"

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
# Helper: Detect active migration prefetch sysfs interface
# ------------------------------------------------------------------------------
get_prefetch_sysfs() {
    if [ -d "/sys/kernel/mm/page_prefetch" ]; then
        echo "/sys/kernel/mm/page_prefetch"
    elif [ -d "/sys/kernel/mm/pact_prefetch" ]; then
        echo "/sys/kernel/mm/pact_prefetch"
    fi
}

get_hybridtier_hook() {
    local base="${1:-${ROOT_DIR}/baselines/hybridtier}"
    local name="hook.so"
    [ "${THP_MODE:-madvise}" == "always" ] && name="hook_huge.so"
    echo "${HYBRIDTIER_HOOK:-${base}/hook/${name}}"
}

# ------------------------------------------------------------------------------
# Helper: Compute usable Node 0 byte quota for Memtis cgroup
# ------------------------------------------------------------------------------
compute_memtis_node0_quota() {
    local node0_total_kb=$(awk '$3 == "MemTotal:" {print $4}' /sys/devices/system/node/node0/meminfo 2>/dev/null || echo 0)
    local reserve_kb=2306868  # 2.2 GiB (OS_HEADROOM=3 GiB minus ~0.8 GiB hardware/boot hole)
    local quota_kb=$(( node0_total_kb - reserve_kb ))
    [ "${quota_kb}" -lt 131072 ] && quota_kb=131072
    echo $(( quota_kb * 1024 ))
}

# ------------------------------------------------------------------------------
# Helper: Detect stuck kmigraterd spin loop (Memtis 5.15 LRU underflow bug)
# ------------------------------------------------------------------------------
is_kmigraterd_stuck() {
    local pid st1 t1 st2 t2
    for pid in $(pgrep -x 'kmigraterd[0-9]+' 2>/dev/null); do
        read -r st1 t1 <<< "$(awk '{print $3, $14 + $15}' "/proc/${pid}/stat" 2>/dev/null || echo "S 0")"
        [ "${st1}" = "R" ] || continue
        sleep 1
        read -r st2 t2 <<< "$(awk '{print $3, $14 + $15}' "/proc/${pid}/stat" 2>/dev/null || echo "S 0")"
        [ "${st2}" = "R" ] && [ $(( t2 - t1 )) -ge 50 ] && return 0
    done
    return 1
}

# ------------------------------------------------------------------------------
# Helper: Safely drain and reset Memtis workload cgroup
# ------------------------------------------------------------------------------
reset_memtis_cgroup() {
    local memtis_cgroup="/sys/fs/cgroup/memtis_workload"
    if [ -d "${memtis_cgroup}" ]; then
        # Short-circuit in-flight demote_node() warm-page rescans before calling kthread_stop().
        # Raise max_at_node0 to 512 GiB (never "max", which maps to PAGE_COUNTER_MAX != ULONG_MAX).
        [ -f /sys/kernel/mm/htmm/htmm_nowarm ] && echo 1 > /sys/kernel/mm/htmm/htmm_nowarm 2>/dev/null || true
        [ -f "${memtis_cgroup}/memory.max_at_node0" ] && echo 549755813888 > "${memtis_cgroup}/memory.max_at_node0" 2>/dev/null || true

        if [ -f "${memtis_cgroup}/cgroup.procs" ]; then
            for pid in $(cat "${memtis_cgroup}/cgroup.procs" 2>/dev/null); do
                echo "$pid" > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
            done
        fi
        sleep 0.5

        if is_kmigraterd_stuck; then
            log_echo "\033[1;33m[WARNING] kmigraterd is stuck spinning (Memtis LRU underflow); skipping htmm_enabled=disabled and scheduling clean reboot.\033[0m"
            touch /run/lowtier_need_reboot 2>/dev/null || true
        elif [ -f "${memtis_cgroup}/memory.htmm_enabled" ]; then
            ( echo "disabled" > "${memtis_cgroup}/memory.htmm_enabled" ) </dev/null >/dev/null 2>&1 &
            local dis_pid=$!
            for _ in {1..20}; do
                kill -0 "${dis_pid}" 2>/dev/null || break
                sleep 0.5
            done
            if kill -0 "${dis_pid}" 2>/dev/null; then
                log_echo "\033[1;33m[WARNING] memory.htmm_enabled=disabled stalled >10s (kthread_stop); scheduling clean reboot.\033[0m"
                touch /run/lowtier_need_reboot 2>/dev/null || true
            fi
        fi

        rmdir "${memtis_cgroup}" 2>/dev/null || true
    fi
    [ -f /sys/kernel/mm/htmm/htmm_nowarm ] && echo 0 > /sys/kernel/mm/htmm/htmm_nowarm 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Helper: Stop Memtis ksamplingd daemon (syscall 450)
# ------------------------------------------------------------------------------
stop_memtis_ksamplingd() {
    if pgrep -x ksamplingd >/dev/null 2>&1; then
        python3 -c "import ctypes; ctypes.CDLL(None).syscall(450, -1)" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Helper: Start Memtis ksamplingd daemon (syscall 449)
# ------------------------------------------------------------------------------
start_memtis_ksamplingd() {
    if pgrep -x ksamplingd >/dev/null 2>&1; then
        log_echo "[+] Memtis ksamplingd daemon is already active (PID $(pgrep -x ksamplingd))."
        return 0
    fi
    python3 -c "import ctypes; ctypes.CDLL(None).syscall(449, -1, 0)" 2>/dev/null || true
    sleep 0.5
    if pgrep -x ksamplingd >/dev/null 2>&1; then
        log_echo "[+] Memtis ksamplingd daemon is active (PID $(pgrep -x ksamplingd))."
    else
        log_echo "\033[1;31m[ERROR] Memtis ksamplingd failed to start or is not running!\033[0m"
    fi
}

# ------------------------------------------------------------------------------
# Helper: Ensure kernel module is compiled and loaded
# ------------------------------------------------------------------------------
ensure_module_loaded() {
    local mod_name="$1" base_dir="$2" sub_dir="$3" label="$4"
    local mod_id="${mod_name//-/_}"
    local target_dir="${base_dir}${sub_dir:+/${sub_dir}}"

    [ -d "${target_dir}" ] || return 1

    if grep -q "^${mod_id}[[:space:]]" /proc/modules 2>/dev/null; then
        rmmod "${mod_id}" 2>/dev/null || true
    fi

    local mod_file="${target_dir}/${mod_name}.ko"
    local mod_vermagic=""
    [ -f "${mod_file}" ] && mod_vermagic="$(modinfo -F vermagic "${mod_file}" 2>/dev/null | awk '{print $1}' || true)"

    if [ "${mod_vermagic}" != "${KERNEL_VER}" ]; then
        local kdir="/lib/modules/${KERNEL_VER}/build"
        log_echo "[*] Cleaning and compiling ${label} ${mod_name}.ko for ${KERNEL_VER}..."
        if [ -d "${kdir}" ]; then
            make -C "${kdir}" M="${target_dir}" clean >/dev/null 2>&1 || true
            make -C "${kdir}" M="${target_dir}" modules CC=gcc-11 HOSTCC=gcc-11 >/dev/null 2>&1 || true
        else
            make -C "${target_dir}" clean >/dev/null 2>&1 || true
            make -C "${target_dir}" CC=gcc-11 HOSTCC=gcc-11 >/dev/null 2>&1 || true
        fi
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
# Helper: Log active Node 0 tiering status and watermark buffer
# ------------------------------------------------------------------------------
log_tiering_status() {
    local demote_en="$(read_sysfs /sys/kernel/mm/numa/demotion_enabled)"
    local numa_bal="$(sysctl -n kernel.numa_balancing 2>/dev/null || true)"
    local tiers="$(ls -d /sys/devices/virtual/memory_tiering/memory_tier* 2>/dev/null | xargs -n 1 basename 2>/dev/null | tr '\n' ' ' || true)"
    log_echo "[*] Node 0 Tiering Status: demotion_enabled=${demote_en:-false}, numa_balancing=${numa_bal}${tiers:+, tiers=[${tiers% }]}"
    log_echo "[*] Node 0 Watermark Buffer: min_free_kbytes=$(sysctl -n vm.min_free_kbytes 2>/dev/null), watermark_scale_factor=$(sysctl -n vm.watermark_scale_factor 2>/dev/null)"
}

# ------------------------------------------------------------------------------
# Show current kernel tiering, prefetch, and THP configuration status
# ------------------------------------------------------------------------------
show_status() {
    local prefetch_sysfs="$(get_prefetch_sysfs)"

    log_echo "=========================================================================================="
    log_echo " Kernel Tiering & Prefetch Configuration Status (${KERNEL_VER})"
    log_echo "=========================================================================================="
    if [ -n "$prefetch_sysfs" ]; then
        local cur_en="$(read_sysfs "${prefetch_sysfs}/enabled")"
        local cur_naive="$(read_sysfs "${prefetch_sysfs}/naive")"
        local cur_hint="$(read_sysfs "${prefetch_sysfs}/hint")"
        local cur_adap="$(read_sysfs "${prefetch_sysfs}/adaptive")"
        local cur_prom="$(read_sysfs "${prefetch_sysfs}/promote_distance")"
        local cur_dem="$(read_sysfs "${prefetch_sysfs}/demote_distance")"
        local cur_min="$(read_sysfs "${prefetch_sysfs}/min_distance")"
        local cur_max="$(read_sysfs "${prefetch_sysfs}/max_distance")"
        log_echo "[*] Migration Prefetch (${prefetch_sysfs}): enabled=${cur_en}, engine=$([ "${cur_naive}" == "1" ] && echo "naive" || echo "deep-tune"), adaptive=${cur_adap}, hint=${cur_hint}, promote=${cur_prom:-N/A}, demote=${cur_dem:-N/A}, min=${cur_min:-N/A}, max=${cur_max:-N/A}"
    else
        log_echo "[*] Migration Prefetch: Not present in this kernel"
    fi

    local cur_thp="$(read_sysfs /sys/kernel/mm/transparent_hugepage/enabled)"
    local cur_defrag="$(read_sysfs /sys/kernel/mm/transparent_hugepage/defrag)"
    log_echo "[*] Transparent Huge Pages (THP): enabled=${cur_thp:-N/A}, defrag=${cur_defrag:-N/A}"

    log_tiering_status
    log_echo "=========================================================================================="
}

# ------------------------------------------------------------------------------
# Configure kernel tiering, baseline environments, prefetch sysfs, and THP
# ------------------------------------------------------------------------------
configure_kernel() {
    log_echo "[*] Starting kernel setup for: ${KERNEL_VER}..."
    sysctl -w kernel.perf_event_paranoid=-1 >/dev/null 2>&1 || true

    if grep -q "^kswapdrst[[:space:]]" /proc/modules 2>/dev/null; then
        log_echo "[*] Unloading kswapdrst module to allow direct allocation fallback to Node 1..."
        rmmod kswapdrst 2>/dev/null || true
    fi

    if [[ "${KERNEL_VER,,}" =~ prefetch ]]; then
        local mon_bin="${ROOT_DIR}/baselines/tier-prefetch-mon/tier-prefetch-mon"
        if [ ! -x "${mon_bin}" ] && [ -d "${ROOT_DIR}/baselines/tier-prefetch-mon" ]; then
            make -C "${ROOT_DIR}/baselines/tier-prefetch-mon" >/dev/null 2>&1 || true
        fi
        killall -9 tier-prefetch-mon 2>/dev/null || true
    fi

    # ------------------
    # NOMAD Setup
    # ------------------
    if [[ "${KERNEL_VER,,}" =~ nomad ]]; then
        local nomad_dir="${ROOT_DIR}/baselines/nomad"
        [[ "${KERNEL_VER,,}" =~ alto ]] && nomad_dir+="-alto"
        [ ! -d "${nomad_dir}" ] && nomad_dir=$(ls -d ${ROOT_DIR}/baselines/nomad* 2>/dev/null | head -n 1 || true)
        ensure_module_loaded "async_promote" "${nomad_dir}" "nomad_module" "Nomad" || true

        log_echo "[*] Activating Nomad Tiered NUMA Balancing (mode 2) and demotion..."
        sysctl -w kernel.numa_balancing=2 >/dev/null 2>&1 || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # ------------------
    # Memtis Setup
    # ------------------
    elif [[ "${KERNEL_VER,,}" =~ memtis|htmm ]]; then
        log_echo "[*] Activating Memtis kernel tiering environment (htmm_mode=2 from T=0)..."
        sysctl -w kernel.numa_balancing=0 >/dev/null 2>&1 || true
        echo false > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

        [ -f /sys/kernel/mm/htmm/htmm_cxl_mode ] && echo "enabled" > /sys/kernel/mm/htmm/htmm_cxl_mode 2>/dev/null || true

        # Attach caller shell before workload fork/exec so mm->htmm_enabled and pginfo initialize cleanly
        local memtis_cgroup="/sys/fs/cgroup/memtis_workload"
        reset_memtis_cgroup
        mkdir -p "${memtis_cgroup}" 2>/dev/null || true

        echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
        echo "+cpuset" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
        [ -f "${memtis_cgroup}/memory.htmm_enabled" ] && echo "enabled" > "${memtis_cgroup}/memory.htmm_enabled" 2>/dev/null || true
        if [ -f "${memtis_cgroup}/cgroup.procs" ]; then
            echo "${PPID}" > "${memtis_cgroup}/cgroup.procs" 2>/dev/null || true
            echo $$ > "${memtis_cgroup}/cgroup.procs" 2>/dev/null || true
        fi

        # Apply memory.max_at_node0 immediately so Memtis manages Node 0 from T=0
        local node0_usable_bytes=$(compute_memtis_node0_quota)
        if [ -f "${memtis_cgroup}/memory.max_at_node0" ]; then
            echo "${node0_usable_bytes}" > "${memtis_cgroup}/memory.max_at_node0" 2>/dev/null || true
            log_echo "[*] Memtis Node 0 Memory Quota set to: $(cat "${memtis_cgroup}/memory.max_at_node0" 2>/dev/null || echo "${node0_usable_bytes}") bytes"
        fi

        # Activate HTMM sampling & migration immediately (no autotie deferral)
        [ -f /sys/kernel/mm/htmm/htmm_mode ] && echo 2 > /sys/kernel/mm/htmm/htmm_mode 2>/dev/null || true
        start_memtis_ksamplingd

    # ------------------
    # Colloid Setup
    # ------------------
    elif [[ "${KERNEL_VER,,}" =~ colloid ]]; then
        local colloid_dir="${ROOT_DIR}/baselines/colloid-tpp"
        [[ "${KERNEL_VER,,}" =~ alto ]] && colloid_dir+="-alto"
        [ ! -d "${colloid_dir}" ] && colloid_dir=$(ls -d ${ROOT_DIR}/baselines/colloid* 2>/dev/null | head -n 1 || true)

        ensure_module_loaded "tierinit" "${colloid_dir}" "tierinit" "Colloid" || true
        ensure_module_loaded "colloid-mon" "${colloid_dir}" "colloid-mon" "Colloid" || true

        log_echo "[*] Activating Colloid Tiered NUMA Balancing (mode 6: TIERING | COLLOID) and demotion..."
        sysctl -w kernel.numa_balancing=6 >/dev/null 2>&1 || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # ------------------
    # PACT Setup
    # ------------------
    elif [[ "${KERNEL_VER,,}" =~ pact ]]; then
        local pact_dir="${ROOT_DIR}/baselines/pact"
        [ ! -d "${pact_dir}" ] && pact_dir=$(ls -d ${ROOT_DIR}/baselines/pact* 2>/dev/null | head -n 1 || true)

        ensure_module_loaded "tierinit" "${pact_dir}" "tierinit" "PACT" || true
        ensure_module_loaded "kswapdrst" "${pact_dir}" "kswapdrst" "PACT" || true

        if [ ! -x "${pact_dir}/src/pact" ] && [ -d "${pact_dir}/src" ]; then
            log_echo "[*] Building PACT daemon (${pact_dir}/src/pact)..."
            make -C "${pact_dir}/src" >/dev/null 2>&1 || true
        fi
        if [ ! -x "${pact_dir}/src/pact" ]; then
            log_echo "\033[1;31m[ERROR] PACT daemon binary not found or failed to build: ${pact_dir}/src/pact\033[0m"
        fi

        # Match original PACT methodology (run-pact.sh): start with demotion_enabled=0 and
        # zone_reclaim_mode=0 so heavy initial allocations overflow smoothly to Node 1 without
        # hanging in direct reclaim; PACT's balance loop (Algorithm 2) toggles demotion_enabled online.
        log_echo "[*] Activating PACT kernel tiering environment (demotion_enabled=false; controlled online by PACT)..."
        sysctl -w vm.zone_reclaim_mode=0 >/dev/null 2>&1 || true
        sysctl -w kernel.numa_balancing=0 >/dev/null 2>&1 || true
        echo false > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # ------------------
    # HybridTier Setup
    # ------------------
    elif [[ "${KERNEL_VER,,}" =~ hybridtier ]]; then
        local hybridtier_dir="${ROOT_DIR}/baselines/hybridtier"
        [ ! -d "${hybridtier_dir}" ] && hybridtier_dir=$(ls -d ${ROOT_DIR}/baselines/hybridtier* 2>/dev/null | head -n 1 || true)

        local hook_so="$(get_hybridtier_hook "${hybridtier_dir}")"
        local hook_target="$(basename "${hook_so}")"
        local fast_mem_gb=$(awk '$3 == "MemTotal:" {g=int(($4 + 524288) / 1048576); if (g < 1) g=1; print g}' /sys/devices/system/node/node0/meminfo 2>/dev/null || echo 16)

        if [ -d "${hybridtier_dir}/hook" ]; then
            make -B -C "${hybridtier_dir}/hook" "${hook_target}" TARGET_EXE_NAME="${TARGET_EXE_NAME}" FAST_MEMORY_SIZE_GB="${fast_mem_gb}" >/dev/null 2>&1 || true
        fi

        if [ -f "${hook_so}" ]; then
            log_echo "[+] HybridTier hook library built: ${hook_so} (target=${TARGET_EXE_NAME}, fast_mem=${fast_mem_gb} GB)"
        else
            log_echo "\033[1;31m[ERROR] HybridTier hook library missing: ${hook_so}\033[0m"
        fi

        log_echo "[*] Activating HybridTier kernel environment..."
        sysctl -w vm.zone_reclaim_mode=0 >/dev/null 2>&1 || true
        sysctl -w kernel.numa_balancing=0 >/dev/null 2>&1 || true
        sysctl -w vm.watermark_scale_factor=10 >/dev/null 2>&1 || true
        echo false > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true
        echo 0x0000 > /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true
        sysctl -w kernel.perf_event_max_sample_rate=150000 >/dev/null 2>&1 || true
        sysctl -w kernel.perf_cpu_time_max_percent=0 >/dev/null 2>&1 || true

        if [ ! -e "/ssd1/songxin8/thesis/autonuma/linux-6.1-rc6/tools/perf/perf" ]; then
            mkdir -p /ssd1/songxin8/thesis/autonuma/linux-6.1-rc6/tools/perf 2>/dev/null || true
            ln -sf "$(command -v perf || echo /usr/bin/perf)" /ssd1/songxin8/thesis/autonuma/linux-6.1-rc6/tools/perf/perf 2>/dev/null || true
        fi

    # ------------------------------------
    # AutoNUMA / Generic Setup
    # ------------------------------------
    elif [[ "${KERNEL_VER,,}" =~ generic || "${KERNEL_VER,,}" =~ autonuma ]]; then
        ensure_module_loaded "tierinit" "${ROOT_DIR}/baselines/autonuma" "tierinit" "AutoNUMA" || true

        log_echo "[*] Activating AutoNUMA + Tiered Balancing (mode 3) and demotion..."
        sysctl -w kernel.numa_balancing=3 >/dev/null 2>&1 || sysctl -w kernel.numa_balancing=2 >/dev/null 2>&1 || sysctl -w kernel.numa_balancing=1 >/dev/null 2>&1 || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true

    # ------------------------------------
    # Upstream TPP / Generic Fallback
    # ------------------------------------
    else
        log_echo "[*] Activating TPP Tiered NUMA Balancing (mode 2) and demotion..."
        sysctl -w kernel.numa_balancing=2 >/dev/null 2>&1 || sysctl -w kernel.numa_balancing=1 >/dev/null 2>&1 || true
        echo true > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true
    fi

    # ------------------------------------------------------------------------------------------
    # Migration Prefetch Online Configuration
    # ------------------------------------------------------------------------------------------
    local prefetch_sysfs="$(get_prefetch_sysfs)"

    if [ -n "$prefetch_sysfs" ]; then
        write_sysfs_verified "${prefetch_sysfs}/enabled" "${PREFETCH_ENABLED}" "enabled" || true
        [ -f "${prefetch_sysfs}/naive" ] && write_sysfs_verified "${prefetch_sysfs}/naive" "${PREFETCH_NAIVE}" "naive" || true
        write_sysfs_verified "${prefetch_sysfs}/adaptive" "${PREFETCH_ADAPTIVE}" "adaptive" || true
        write_sysfs_verified "${prefetch_sysfs}/hint" "${PREFETCH_HINT}" "hint" || true

        write_sysfs_verified "${prefetch_sysfs}/min_distance" "${PREFETCH_MIN_DISTANCE}" "min_distance" || true
        write_sysfs_verified "${prefetch_sysfs}/max_distance" "${PREFETCH_MAX_DISTANCE}" "max_distance" || true

        if [ -f "${prefetch_sysfs}/promote_distance" ] && [ "${PREFETCH_ENABLED}" != "0" ]; then
            write_sysfs_verified "${prefetch_sysfs}/promote_distance" "${PREFETCH_PROMOTE_DISTANCE}" "promote_distance" || true
            write_sysfs_verified "${prefetch_sysfs}/demote_distance"  "${PREFETCH_DEMOTE_DISTANCE}"  "demote_distance" || true
        fi

        local cur_en cur_naive cur_hint cur_adap cur_prom cur_dem cur_min cur_max
        cur_en="$(read_sysfs "${prefetch_sysfs}/enabled")"
        cur_naive="$(read_sysfs "${prefetch_sysfs}/naive")"
        cur_hint="$(read_sysfs "${prefetch_sysfs}/hint")"
        cur_adap="$(read_sysfs "${prefetch_sysfs}/adaptive")"
        cur_prom="$(read_sysfs "${prefetch_sysfs}/promote_distance")"
        cur_dem="$(read_sysfs "${prefetch_sysfs}/demote_distance")"
        cur_min="$(read_sysfs "${prefetch_sysfs}/min_distance")"
        cur_max="$(read_sysfs "${prefetch_sysfs}/max_distance")"

        local engine_str="deep-tune"
        [ "$cur_naive" == "1" ] && engine_str="naive"
        if [ "$cur_en" == "0" ]; then
            log_echo "[*] Migration Prefetch Online Parameters (${prefetch_sysfs}): enabled=0 (disabled), hint=${cur_hint:-0}"
        elif [ -f "${prefetch_sysfs}/promote_distance" ]; then
            local extra_info=""
            [ -n "$cur_min" ] && extra_info+=", min_dist=${cur_min}"
            [ -n "$cur_max" ] && extra_info+=", max_dist=${cur_max}"
            local mode_str="static"
            [ "$cur_adap" == "1" ] && mode_str="adaptive"
            local tier_info=" (engine=${engine_str}, promote=${cur_prom:-$PREFETCH_PROMOTE_DISTANCE}, demote=${cur_dem:-$PREFETCH_DEMOTE_DISTANCE}, mode=${mode_str}${extra_info})"
            log_echo "[*] Migration Prefetch Online Parameters (${prefetch_sysfs}): enabled=${cur_en}${tier_info}, hint=${cur_hint:-0}"
        else
            log_echo "[*] Migration Prefetch Online Parameters (${prefetch_sysfs}): enabled=${cur_en} (engine=${engine_str}), hint=${cur_hint:-0}"
        fi
    fi

    # ------------------------------------------------------------------------------------------
    # Transparent Huge Pages (THP) Online Configuration
    # ------------------------------------------------------------------------------------------
    local thp_target="${THP_MODE:-madvise}"
    [[ ! "${thp_target}" =~ ^(always|madvise|never)$ ]] && thp_target="madvise"

    # Always keep defrag=madvise (Linux default) to avoid synchronous compaction stalls on a tight fast tier
    local defrag_target="madvise"

    echo "${thp_target}" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo "${defrag_target}" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    local cur_thp="$(read_sysfs /sys/kernel/mm/transparent_hugepage/enabled)"
    local cur_defrag="$(read_sysfs /sys/kernel/mm/transparent_hugepage/defrag)"

    log_echo "[*] Transparent Huge Pages (THP): enabled=${cur_thp:-N/A} (target=${thp_target}), defrag=${cur_defrag:-N/A} (target=${defrag_target})"

    log_tiering_status
}

# ------------------------------------------------------------------------------
# Helper Daemons: Start userspace tiering/prefetch daemons immediately (no autotie wait)
# ------------------------------------------------------------------------------
autotie_start() {
    # Ensure helper daemons (PACT, tier-prefetch-mon) run in root cgroup, not memtis_workload
    [ -f /sys/fs/cgroup/cgroup.procs ] && echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true

    local target_exe="${TARGET_EXE_NAME:-pr}"
    local pact_actual_pid_file="/tmp/pact_actual_pid"
    local pact_watcher_pid_file="/tmp/pact_watcher_pid"
    rm -f "${pact_actual_pid_file}" "${pact_watcher_pid_file}"

    local pact_bin="${ROOT_DIR}/baselines/pact/src/pact"
    [ ! -x "${pact_bin}" ] && pact_bin=$(ls -d "${ROOT_DIR}"/baselines/pact*/src/pact 2>/dev/null | head -n 1 || true)

    local is_pact=0 need_pact=0
    if [[ "${KERNEL_VER,,}" =~ pact ]]; then
        is_pact=1
        if [ -x "${pact_bin}" ]; then
            need_pact=1
        else
            log_echo "\033[1;31m[ERROR] PACT kernel running but binary is missing: ${pact_bin:-baselines/pact/src/pact}\033[0m"
        fi
    fi

    local is_prefetch=0
    [[ "${KERNEL_VER,,}" =~ prefetch ]] && is_prefetch=1

    local has_embedded_mon=0
    if [ ${need_pact} -eq 1 ] && strings "${pact_bin}" 2>/dev/null | grep -q "prefetch_coro"; then
        has_embedded_mon=1
    elif [[ "${KERNEL_VER,,}" =~ hybridtier ]]; then
        local hybrid_hook="$(get_hybridtier_hook)"
        if [ -f "${hybrid_hook}" ] && strings "${hybrid_hook}" 2>/dev/null | grep -q "hybridtier_prefetch"; then
            has_embedded_mon=1
        fi
    fi

    # Start adaptive prefetch monitor immediately unless the active daemon already embeds mig_telemetry
    if [ ${is_prefetch} -eq 1 ] && [ ${has_embedded_mon} -eq 0 ] && { [ ${is_pact} -eq 0 ] || [ ${need_pact} -eq 1 ]; }; then
        local mon_bin="${ROOT_DIR}/baselines/tier-prefetch-mon/tier-prefetch-mon"
        local prefetch_mon_log="${TARGET_DIR:-/tmp}/prefetch_mon_${FILENAME_SUFFIX:-run}.log"
        if [ "${PREFETCH_ENABLED:-1}" != "0" ] && [ "${PREFETCH_ADAPTIVE:-1}" == "1" ] && [ -x "${mon_bin}" ]; then
            local mon_interval_ms="${PREFETCH_MON_INTERVAL_MS:-50}"
            log_echo "[+] Starting tier-prefetch-mon daemon immediately for ${KERNEL_VER} (cpu_mask=${WORKLOAD_CPU_MASK}, interval=${mon_interval_ms}ms, cpu=${PREFETCH_MON_CPU})..."
            taskset -c "${PREFETCH_MON_CPU}" "${mon_bin}" --daemon --interval-ms "${mon_interval_ms}" --cpu-mask "${WORKLOAD_CPU_MASK}" > "${prefetch_mon_log}" 2>&1 &
            echo $! > /tmp/tier_prefetch_mon.pid
        fi
    fi

    # PACT is a userspace daemon that requires the workload's PID (--workload <PID>).
    # Match original run-pact.sh: do NOT wait for Read Time / ingestion logs; simply wait
    # briefly for the workload process to spawn, then attach immediately.
    # Because configure_kernel() sets demotion_enabled=false and vm.zone_reclaim_mode=0,
    # initial bombard allocations overflow cleanly to Node 1 without hanging in direct reclaim.
    if [ ${need_pact} -eq 1 ]; then
        local pact_log_file="${TARGET_DIR:-/tmp}/pact_${FILENAME_SUFFIX:-run}.log"
        local pact_margin="${PACT_DEMOTION_MARGIN:-25000}"
        local is_multi_pid=0
        local spec_pgrep_pat="_base\\."
        if [ "${target_exe}" = "runcpu" ] || [ "${target_exe}" = "specperl" ]; then
            is_multi_pid=1
        elif [[ "${target_exe}" == *_base.* ]]; then
            is_multi_pid=1
            spec_pgrep_pat="${target_exe}"
        fi
        : > "${pact_log_file}"

        (
            local last_attached_pid=""
            local attached_any=0

            while true; do
                local target_pid=""
                local attempts=0
                local max_attempts=150 # up to 30 seconds for single-process spawn

                while true; do
                    if [ "${target_exe}" = "run_redis.sh" ] || [ "${target_exe}" = "redis-server" ]; then
                        target_pid=$(pgrep -n -x redis-server 2>/dev/null || true)
                    elif [ ${is_multi_pid} -eq 1 ]; then
                        target_pid=$(pgrep -n -f "${spec_pgrep_pat}" 2>/dev/null || true)
                    elif [ -n "${target_exe}" ] && [ "${target_exe}" != "*" ]; then
                        target_pid=$(pgrep -n -x "${target_exe}" 2>/dev/null || true)
                    fi

                    if [ -n "${target_pid}" ] && [ "${target_pid}" != "${last_attached_pid}" ]; then
                        break
                    fi

                    if [ ${is_multi_pid} -eq 0 ]; then
                        attempts=$((attempts + 1))
                        [ ${attempts} -ge ${max_attempts} ] && break
                    fi
                    sleep 0.2
                done

                if [ -z "${target_pid}" ] || [ "${target_pid}" = "${last_attached_pid}" ]; then
                    if [ ${attached_any} -eq 0 ]; then
                        echo -e "\033[1;31m[!] WARNING: PACT attacher could not find running workload '${target_exe}'!\033[0m" >&2
                    fi
                    break
                fi

                # Brief settle matching original run-pact.sh (sleep 2) so the process completes exec
                # and initial first-touch overflow before PACT toggles demotion_enabled online.
                sleep 2

                # For SPEC multi-invocation wrappers, refresh to the newest child in case we woke on a launcher shell
                if [ ${is_multi_pid} -eq 1 ]; then
                    local newer_pid=$(pgrep -n -f "${spec_pgrep_pat}" 2>/dev/null || true)
                    if [ -n "${newer_pid}" ] && [ "${newer_pid}" != "${last_attached_pid}" ]; then
                        target_pid="${newer_pid}"
                    fi
                fi

                if kill -0 "${target_pid}" 2>/dev/null; then
                    last_attached_pid="${target_pid}"
                    attached_any=1
                    echo "[+] PACT daemon attaching immediately to PID ${target_pid} (demotion_margin=${pact_margin})..."

                    # Temporarily expand Thread 0's affinity so PACT discovers all workload cores at startup, then restore
                    local orig_mask=$(taskset -p "${target_pid}" 2>/dev/null | awk '{print $NF}')
                    taskset -p -c "${WORKLOAD_CPU_RANGE}" "${target_pid}" >/dev/null 2>&1 || true

                    "${pact_bin}" --workload "${target_pid}" --monitor-cpu "${PACT_MONITOR_CPU}" --migration-cpu "${PACT_MIGRATION_CPU}" --demotion-margin "${pact_margin}" --log-level 2 >> "${pact_log_file}" 2>&1 &
                    local actual_pact_pid=$!
                    echo "${actual_pact_pid}" > "${pact_actual_pid_file}"

                    ( sleep 0.5; [ -n "${orig_mask}" ] && taskset -p "${orig_mask}" "${target_pid}" >/dev/null 2>&1 || true ) &
                    wait "${actual_pact_pid}"
                    rm -f "${pact_actual_pid_file}"

                    if [ ${is_multi_pid} -eq 1 ]; then
                        echo false > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true
                    fi
                fi

                [ ${is_multi_pid} -eq 0 ] && break
            done
        ) &
        local watcher_pid=$!
        echo "${watcher_pid}" > "${pact_watcher_pid_file}"
        log_echo "[+] PACT PID attacher started (PID ${watcher_pid}, multi_pid=${is_multi_pid})."
    fi
}

# ------------------------------------------------------------------------------
# Helper: Gracefully stop a daemon PID (SIGINT, wait, then SIGKILL if alive)
# ------------------------------------------------------------------------------
stop_pid_gracefully() {
    local pid="$1" wait_sec="${2:-0.2}"
    [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null || return 0
    kill -INT "${pid}" 2>/dev/null || true
    sleep "${wait_sec}"
    kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Helper Daemons: Stop userspace daemons and clean up tiering state
# ------------------------------------------------------------------------------
autotie_stop() {
    stop_pid_gracefully "$(cat "/tmp/tier_prefetch_mon.pid" 2>/dev/null || true)" 0.2
    rm -f "/tmp/tier_prefetch_mon.pid"

    local pact_actual_pid_file="/tmp/pact_actual_pid"
    local pact_watcher_pid_file="/tmp/pact_watcher_pid"

    # Stop watcher first so a multi-PID loop cannot spawn a new PACT during teardown
    local watcher_pid=$(cat "${pact_watcher_pid_file}" 2>/dev/null || true)
    if [ -n "${watcher_pid}" ]; then
        kill -9 "${watcher_pid}" 2>/dev/null || true
    fi

    local actual_pact_pid=$(cat "${pact_actual_pid_file}" 2>/dev/null || true)
    if [ -n "${actual_pact_pid}" ] && kill -0 "${actual_pact_pid}" 2>/dev/null; then
        log_echo "[*] Waiting for PACT daemon (PID ${actual_pact_pid}) to finalize..."
        for i in {1..20}; do
            kill -0 "${actual_pact_pid}" 2>/dev/null || break
            sleep 0.1
        done
        stop_pid_gracefully "${actual_pact_pid}" 0.5
    fi
    rm -f "${pact_actual_pid_file}" "${pact_watcher_pid_file}"

    # Terminate orphan perf stat process spawned by HybridTier's hook.so
    if [[ "${KERNEL_VER,,}" =~ hybridtier ]]; then
        pkill -f "perf stat -I 60000" 2>/dev/null || true
    fi

    if [[ "${KERNEL_VER,,}" =~ memtis|htmm ]]; then
        # 1) Stop ksamplingd first while htmm_mode=2 (fast 2ms exit, stops lru_lock/cooling churn)
        # 2) Stop kmigraterd before setting htmm_mode=0 (avoids promote_node() HTMM_NO_MIG uninitialized-tmp bug)
        stop_memtis_ksamplingd
        reset_memtis_cgroup
        [ -f /sys/kernel/mm/htmm/htmm_mode ] && echo 0 > /sys/kernel/mm/htmm/htmm_mode 2>/dev/null || true
    elif [[ "${KERNEL_VER,,}" =~ pact ]]; then
        echo false > /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || true
    elif [[ ! "${KERNEL_VER,,}" =~ hybridtier ]]; then
        sysctl -w kernel.numa_balancing=0 >/dev/null 2>&1 || true
    fi
}

# ------------------------------------------------------------------------------
# Baseline Autotie: Wrap workload command with stack limit & preload environment
# ------------------------------------------------------------------------------
autotie_wrap() {
    shift
    local prefix=""
    if command -v prlimit >/dev/null 2>&1; then
        prefix="prlimit --stack=unlimited -- "
    fi
    if [[ "${KERNEL_VER,,}" =~ hybridtier ]]; then
        local hybrid_hook="$(get_hybridtier_hook)"
        if [ -f "${hybrid_hook}" ]; then
            echo "${prefix}env LD_PRELOAD=\"${hybrid_hook}\${LD_PRELOAD:+:\$LD_PRELOAD}\" TARGET_EXE_NAME=\"${TARGET_EXE_NAME}\" $*"
            return 0
        fi
    fi
    echo "${prefix}$*"
}

# ------------------------------------------------------------------------------
# Clean up kernel tiering state and unload baseline modules
# ------------------------------------------------------------------------------
cleanup_kernel() {
    log_echo "[*] Cleaning up kernel tiering state and modules..."

    echo "madvise" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo "madvise" > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    if [ "${KEEP_PRELOAD_CACHE:-0}" != "1" ]; then
        rm -f /run/lowtier_preloaded_graph
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    fi

    killall tier-prefetch-mon 2>/dev/null || true
    rmmod colloid-mon 2>/dev/null || true
    rmmod kswapdrst 2>/dev/null || true
    sleep 1 # wait for all cleanup to complete. Ensure the synchronization.

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
    echo "  --cleanup, -c   : Reset kernel tiering state (cgroup/THP) and unload tiering modules"
    echo "  --status,  -s   : Show current kernel tiering and prefetch parameters"
    exit 0
fi

# ------------------------------------------------------------------------------
# Root Privilege Elevation (write/configure commands require root; status/help do not)
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ] && [ "${1:-}" != "--wrap-cmd" ] && [ "${1:-}" != "--status" ] && [ "${1:-}" != "-s" ] && [ "${1:-}" != "--help" ] && [ "${1:-}" != "-h" ]; then
    echo "[!] Kernel setup requires root privileges. Elevating via sudo..."
    exec sudo env PATH="$PATH" ROOT_DIR="$ROOT_DIR" THP_MODE="${THP_MODE}" \
        PREFETCH_ENABLED="${PREFETCH_ENABLED}" PREFETCH_NAIVE="${PREFETCH_NAIVE}" \
        PREFETCH_ADAPTIVE="${PREFETCH_ADAPTIVE}" \
        PREFETCH_HINT="${PREFETCH_HINT}" PREFETCH_PROMOTE_DISTANCE="${PREFETCH_PROMOTE_DISTANCE}" \
        PREFETCH_DEMOTE_DISTANCE="${PREFETCH_DEMOTE_DISTANCE}" \
        PREFETCH_MIN_DISTANCE="${PREFETCH_MIN_DISTANCE}" \
        PREFETCH_MAX_DISTANCE="${PREFETCH_MAX_DISTANCE}" \
        TARGET_EXE_NAME="${TARGET_EXE_NAME}" \
        KEEP_PRELOAD_CACHE="${KEEP_PRELOAD_CACHE:-0}" \
        REGRESS_LOG_FILE="${REGRESS_LOG_FILE:-}" "$0" "$@"
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
