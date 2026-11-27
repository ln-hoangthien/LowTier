#!/bin/bash
# ==============================================================================
# Automated Multi-Kernel & Multi-Ratio Regression Orchestrator
# Location: ~/thienle/LowTier/regression/run_auto_regression.sh
# ==============================================================================
# Description:
#   Reads kernels, tier ratios, and benchmarks from regression_list.
#   For each (Kernel, Benchmark, Ratio), fast-tier capacity is dynamically
#   calculated from the workload RSS, set via memmap in GRUB, and rebooted.
#   Post-reboot, executes the targeted benchmark directly.
#
# Usage:
#   sudo ./run_auto_regression.sh [start | resume | status | stop | reset]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
REGRESSION_LIST="${REGRESSION_LIST:-${SCRIPT_DIR}/regression_list}"
STATE_FILE="${SCRIPT_DIR}/.regression_state"
SERVICE_NAME="lowtier-regression.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
LOG_FILE="${SCRIPT_DIR}/auto_regression_orchestrator.log"
RERUN_LOG_FILE="${SCRIPT_DIR}/failed_reruns.sh"
RUN_WORKLOADS="${ROOT_DIR}/workloads/scripts/run_workloads.sh"
SETUP_WORKLOADS="${ROOT_DIR}/workloads/scripts/setup_workloads.sh"
SETUP_MACHINE="${ROOT_DIR}/workloads/scripts/setup_machine.sh"

# Formatting Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Guard root check when script is executed directly vs sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ACTION="${1:-start}"
    if [[ "$ACTION" != "status" && "$ACTION" != "check" && "$ACTION" != "-h" && "$ACTION" != "--help" && "$ACTION" != "help" ]]; then
        if [ "$EUID" -ne 0 ]; then
            echo -e "${YELLOW}Notice: Root privileges are required to manage GRUB, reboots, and services.${NC}"
            exec sudo env PATH="$PATH" ROOT_DIR="$ROOT_DIR" bash "$0" "$@"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# Log message with timestamp to stdout and orchestrator log file
# ------------------------------------------------------------------------------
log() {
    local timestamp="[$(date '+%Y-%m-%d %H:%M:%S')]"
    local raw_msg="$1"
    echo -e "${timestamp} ${raw_msg}"
    local clean_msg
    clean_msg=$(printf '%b' "${raw_msg}" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g')
    echo "${timestamp} ${clean_msg}" >> "$LOG_FILE"
}

# ------------------------------------------------------------------------------
# Ensure all logical CPU cores are brought online
# ------------------------------------------------------------------------------
ensure_cpus_online() {
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/online; do
        [ -f "$cpu" ] && echo 1 > "$cpu" 2>/dev/null || true
    done
}

restore_machine() {
    bash "$SETUP_MACHINE" --restore 2>/dev/null || ensure_cpus_online
}

# ------------------------------------------------------------------------------
# Configure kernel sysctls to auto-reboot on Oops, soft lockup, or hard lockup
# ------------------------------------------------------------------------------
enable_hang_auto_reboot() {
    local kv
    for kv in \
        "kernel.panic=5" \
        "kernel.panic_on_oops=1" \
        "kernel.softlockup_panic=0" \
        "kernel.hardlockup_panic=1" \
        "kernel.hung_task_panic=1" \
        "kernel.nmi_watchdog=1" \
        "kernel.watchdog_thresh=60"; do
        sysctl -w "$kv" >/dev/null 2>&1 || true
    done
}

# ------------------------------------------------------------------------------
# Check if kernel name contains prefetch support
# ------------------------------------------------------------------------------
is_prefetch_kernel() {
    [[ "${1,,}" =~ prefetch ]]
}

# ------------------------------------------------------------------------------
# Resolve required memmap boot parameter for benchmark and tier ratio
# ------------------------------------------------------------------------------
resolve_memmap() {
    local bench="$1" ratio="${2:-1:1}"
    bash "${ROOT_DIR}/baselines/scripts/manage_kernels.sh" resolve_memmap "$bench" "$ratio"
}

# ------------------------------------------------------------------------------
# Match target kernel alias against uname or vmlinuz release string
# ------------------------------------------------------------------------------
matches_kernel_target() {
    local target="$1"
    local k_str="${2,,}"
    case "$target" in
        generic)
            [[ "$k_str" =~ generic ]]
            ;;
        autonuma-prefetch)
            [[ "$k_str" =~ autonuma && "$k_str" =~ prefetch ]]
            ;;
        autonuma)
            [[ "$k_str" =~ autonuma && ! "$k_str" =~ prefetch ]]
            ;;
        memtis-prefetch)
            [[ "$k_str" =~ memtis && "$k_str" =~ prefetch ]]
            ;;
        memtis)
            [[ "$k_str" =~ memtis && ! "$k_str" =~ prefetch ]]
            ;;
        nomad-alto-prefetch)
            [[ "$k_str" =~ nomad && "$k_str" =~ alto && "$k_str" =~ prefetch ]]
            ;;
        nomad-prefetch)
            [[ "$k_str" =~ nomad && ! "$k_str" =~ alto && "$k_str" =~ prefetch ]]
            ;;
        nomad-alto-noinline)
            [[ "$k_str" =~ nomad && "$k_str" =~ alto && "$k_str" =~ noinline ]]
            ;;
        nomad-noinline)
            [[ "$k_str" =~ nomad && ! "$k_str" =~ alto && "$k_str" =~ noinline ]]
            ;;
        nomad-alto)
            [[ "$k_str" =~ nomad && "$k_str" =~ alto && ! "$k_str" =~ noinline && ! "$k_str" =~ prefetch ]]
            ;;
        nomad)
            [[ "$k_str" =~ nomad && ! "$k_str" =~ alto && ! "$k_str" =~ noinline && ! "$k_str" =~ prefetch ]]
            ;;
        colloid-tpp-alto-prefetch)
            [[ "$k_str" =~ colloid && "$k_str" =~ alto && "$k_str" =~ prefetch ]]
            ;;
        colloid-tpp-prefetch)
            [[ "$k_str" =~ colloid && ! "$k_str" =~ alto && "$k_str" =~ prefetch ]]
            ;;
        colloid-tpp-alto|colloid-alto)
            [[ "$k_str" =~ colloid && "$k_str" =~ alto && ! "$k_str" =~ prefetch ]]
            ;;
        colloid-tpp|colloid)
            [[ "$k_str" =~ colloid && ! "$k_str" =~ alto && ! "$k_str" =~ prefetch ]]
            ;;
        pact-prefetch-batch)
            [[ "$k_str" =~ prefetch-batch || "$k_str" =~ prefetch.*batch ]]
            ;;
        pact-prefetch)
            [[ "$k_str" =~ pact && "$k_str" =~ prefetch && ! "$k_str" =~ batch ]]
            ;;
        pact)
            [[ "$k_str" =~ pact && ! "$k_str" =~ prefetch ]]
            ;;
        hybridtier-prefetch)
            [[ "$k_str" =~ hybridtier && "$k_str" =~ prefetch ]]
            ;;
        hybridtier)
            [[ "$k_str" =~ hybridtier && ! "$k_str" =~ prefetch ]]
            ;;
        tpp-prefetch)
            [[ "$k_str" =~ tpp && ! "$k_str" =~ colloid && "$k_str" =~ prefetch ]]
            ;;
        tpp)
            [[ "$k_str" =~ tpp && ! "$k_str" =~ colloid && ! "$k_str" =~ prefetch ]]
            ;;
        *)
            [[ "$k_str" =~ ${target,,} ]]
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Check if compiled kernel binary exists in baseline source tree
# ------------------------------------------------------------------------------
is_kernel_ready() {
    local target="$1"
    [ "$target" == "generic" ] && return 0

    local base_target="${target%-prefetch}"
    base_target="${base_target%-batch}"
    local kdir="${ROOT_DIR}/baselines/${base_target}/linux"
    [ -d "$kdir" ] || return 1
    ([ -f "$kdir/arch/x86/boot/bzImage" ] || [ -f "$kdir/vmlinux" ]) || return 1

    # Verify the compiled binary in the source tree actually matches target
    if [ -f "$kdir/.config" ]; then
        local krel
        krel=$(make -s -C "$kdir" kernelrelease 2>/dev/null || true)
        [ -n "$krel" ] && matches_kernel_target "$target" "$krel" && return 0
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Check if current running kernel matches target kernel alias
# ------------------------------------------------------------------------------
is_kernel_running() {
    matches_kernel_target "$1" "$(uname -r)"
}

# ------------------------------------------------------------------------------
# Check if kernel image is installed in /boot
# ------------------------------------------------------------------------------
is_kernel_installed() {
    local target="$1"
    for vmlinuz in /boot/vmlinuz-*; do
        [ -f "$vmlinuz" ] && matches_kernel_target "$target" "$(basename "$vmlinuz")" && return 0
    done
    return 1
}

# ------------------------------------------------------------------------------
# Verify both target kernel and required memmap are currently active
# ------------------------------------------------------------------------------
is_target_and_memmap_running() {
    local target_kernel="$1" target_memmap="$2"
    is_kernel_running "$target_kernel" || return 1
    if [ -n "$target_memmap" ] && ! grep -qE "(^|[[:space:]])${target_memmap}([[:space:]]|$)" /proc/cmdline; then
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Install systemd service for automated regression resume on reboot
# ------------------------------------------------------------------------------
install_service() {
    log "${CYAN}Installing systemd autostart service: ${SERVICE_FILE}...${NC}"
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=LowTier Automated Multi-Kernel Regression Service
After=multi-user.target network.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=infinity
TimeoutSec=infinity
Environment="PATH=${PATH}"
Environment="ROOT_DIR=${ROOT_DIR}"
ExecStart=/bin/bash ${SCRIPT_DIR}/run_auto_regression.sh resume
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# Disable and remove autostart systemd service
# ------------------------------------------------------------------------------
remove_service() {
    if [ -f "$SERVICE_FILE" ]; then
        log "${CYAN}Disabling and removing systemd autostart service...${NC}"
        systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    fi
}

# ------------------------------------------------------------------------------
# Parse regression_list and construct the execution target matrix
# ------------------------------------------------------------------------------
load_targets() {
    [ ! -f "$REGRESSION_LIST" ] && { echo -e "${RED}Error: regression_list not found at ${REGRESSION_LIST}${NC}"; exit 1; }
    [ ! -s "$REGRESSION_LIST" ] && { echo -e "${RED}Error: regression_list at ${REGRESSION_LIST} is empty${NC}"; exit 1; }

    TIER_RATIOS=()
    BENCHMARKS=()
    KERNELS=()
    PREFETCH_DISTANCES=()
    PREFETCH_BOUNDS=()
    PREFETCH_MAX_DISTANCES=()
    PREFETCH_ADAPTIVE_MODES=()
    PREFETCH_HINTS=()
    PREFETCH_NAIVE_MODES=()
    THP_MODES=()
    # shellcheck source=/dev/null
    source "$REGRESSION_LIST"
    read -ra TIER_RATIOS <<< "${TIER_RATIOS[*]:-}"
    read -ra BENCHMARKS <<< "${BENCHMARKS[*]:-}"
    read -ra KERNELS <<< "${KERNELS[*]:-}"
    read -ra PREFETCH_DISTANCES <<< "${PREFETCH_DISTANCES[*]:-}"
    read -ra PREFETCH_BOUNDS <<< "${PREFETCH_BOUNDS[*]:-${PREFETCH_MAX_DISTANCES[*]:-}}"
    read -ra PREFETCH_ADAPTIVE_MODES <<< "${PREFETCH_ADAPTIVE_MODES[*]:-}"
    read -ra PREFETCH_HINTS <<< "${PREFETCH_HINTS[*]:-}"
    read -ra PREFETCH_NAIVE_MODES <<< "${PREFETCH_NAIVE_MODES[*]:-}"
    read -ra THP_MODES <<< "${THP_MODES[*]:-}"

    [ ${#KERNELS[@]} -eq 0 ] && { echo -e "${RED}Error: No target kernels specified in ${REGRESSION_LIST}${NC}"; exit 1; }
    [ ${#BENCHMARKS[@]} -eq 0 ] && { echo -e "${RED}Error: No benchmarks specified in ${REGRESSION_LIST}${NC}"; exit 1; }
    [ ${#TIER_RATIOS[@]} -eq 0 ] && { echo -e "${RED}Error: No tier ratios specified in ${REGRESSION_LIST}${NC}"; exit 1; }

    [ ${#PREFETCH_ADAPTIVE_MODES[@]} -eq 0 ] && PREFETCH_ADAPTIVE_MODES=(1)
    [ ${#PREFETCH_HINTS[@]} -eq 0 ] && PREFETCH_HINTS=(0)
    [ ${#PREFETCH_NAIVE_MODES[@]} -eq 0 ] && PREFETCH_NAIVE_MODES=(0)
    [ ${#THP_MODES[@]} -eq 0 ] && THP_MODES=(madvise)

    # Pre-build prefetch evaluation configurations: "adaptive_mode|distance|bounds|hint|naive"
    local prefetch_configs=()
    for naive in "${PREFETCH_NAIVE_MODES[@]}"; do
        for h in "${PREFETCH_HINTS[@]}"; do
            for a in "${PREFETCH_ADAPTIVE_MODES[@]}"; do
                if [ "$a" == "1" ]; then
                    # Adaptive mode: evaluates dynamically adjusted lookahead within bounds
                    if [ ${#PREFETCH_BOUNDS[@]} -gt 0 ]; then
                        for bound in "${PREFETCH_BOUNDS[@]}"; do
                            prefetch_configs+=("1||${bound}|${h}|${naive}")
                        done
                    else
                        prefetch_configs+=("1|||${h}|${naive}")
                    fi
                elif [ "$a" == "0" ]; then
                    # Static mode: evaluates fixed lookahead distances (clamp bounds do not apply)
                    if [ ${#PREFETCH_DISTANCES[@]} -gt 0 ]; then
                        for d in "${PREFETCH_DISTANCES[@]}"; do
                            prefetch_configs+=("0|${d}||${h}|${naive}")
                        done
                    else
                        prefetch_configs+=("0|p5_d2||${h}|${naive}")
                    fi
                fi
            done
        done
    done
    [ ${#prefetch_configs[@]} -eq 0 ] && prefetch_configs+=("1|||0|0")

    # Execution matrix: Kernel -> Ratio -> Benchmark -> THP -> PrefetchConfig
    # Grouping benchmarks under the same (Kernel, Ratio) lets GAPBS workloads sharing the
    # same memmap & graph (e.g. pr/bfs/bc/cc on kron.sg) stay on one boot and reuse vmtouch.
    TARGET_ITEMS=()
    for k in "${KERNELS[@]}"; do
        local configs=()
        if is_prefetch_kernel "$k"; then
            configs=("${prefetch_configs[@]}")
        else
            configs=("||||")
        fi

        for r in "${TIER_RATIOS[@]}"; do
            for b in "${BENCHMARKS[@]}"; do
                for thp in "${THP_MODES[@]}"; do
                    for cfg in "${configs[@]}"; do
                        IFS='|' read -r a d bound h naive <<< "$cfg"
                        TARGET_ITEMS+=("${k}|${b}|${r}|${d}|${a}|${bound}|${thp}|${h}|${naive}")
                    done
                done
            done
        done
    done
}

# ------------------------------------------------------------------------------
# Print summary of regression configuration and parameter sweeps
# ------------------------------------------------------------------------------
print_regression_config() {
    echo -e " Configured Kernels : ${KERNELS[*]}"
    echo -e " Benchmarks         : ${BENCHMARKS[*]}"
    echo -e " Tier Ratios        : ${TIER_RATIOS[*]}"
    echo -e " THP Modes          : ${THP_MODES[*]}"

    local has_prefetch=0
    for k in "${KERNELS[@]}"; do
        is_prefetch_kernel "$k" && { has_prefetch=1; break; }
    done

    if [ "$has_prefetch" == "1" ]; then
        echo -e " Prefetch Engines   : ${PREFETCH_NAIVE_MODES[*]} (0=Deep-tune, 1=Naive)"
        echo -e " Prefetch Hints     : ${PREFETCH_HINTS[*]} (0=NTA, 1=L3, 2=L2, 3=L1)"
        echo -e " Prefetch Modes     : ${PREFETCH_ADAPTIVE_MODES[*]} (for *-prefetch: 0=Static, 1=Adaptive)"
        if [[ " ${PREFETCH_ADAPTIVE_MODES[*]} " =~ [[:space:]]0[[:space:]] ]]; then
            if [ ${#PREFETCH_DISTANCES[@]} -gt 0 ]; then
                echo -e " Prefetch Distances : ${PREFETCH_DISTANCES[*]} (for Static mode)"
            else
                echo -e " Prefetch Distances : Default static range"
            fi
        fi
        if [ ${#PREFETCH_BOUNDS[@]} -gt 0 ]; then
            echo -e " Prefetch Bounds    : ${PREFETCH_BOUNDS[*]} (min:max clamp)"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Update GRUB default boot entry to target kernel and trigger system reboot
# ------------------------------------------------------------------------------
switch_kernel_and_reboot() {
    local target_kernel="$1" target_memmap="$2"
    log "${BLUE}================================================================================${NC}"
    log "${BLUE} Switching to: '${target_kernel}' with ${target_memmap} ${NC}"
    log "${BLUE}================================================================================${NC}"

    local MANAGE_KERNELS="${ROOT_DIR}/baselines/scripts/manage_kernels.sh"
    if is_kernel_installed "$target_kernel"; then
        log "${GREEN}[*] Kernel '${target_kernel}' found in /boot. Updating GRUB default...${NC}"
        bash "$MANAGE_KERNELS" "$target_kernel" update_grub --memmap "$target_memmap" --reboot
    elif is_kernel_ready "$target_kernel"; then
        log "${YELLOW}[!] Kernel '${target_kernel}' built in tree but not installed in /boot. Installing and updating GRUB...${NC}"
        bash "$MANAGE_KERNELS" "$target_kernel" install --memmap "$target_memmap" --reboot
    else
        log "${YELLOW}[!] Source/binary for '${target_kernel}' not built. Compiling and installing...${NC}"
        ensure_cpus_online
        bash "$MANAGE_KERNELS" "$target_kernel" build --memmap "$target_memmap" --reboot
    fi

    # Fallback reboot in case manage_kernels.sh returned without rebooting
    sleep 2
    log "${YELLOW}[*] Triggering system reboot...${NC}"
    reboot
}

# ------------------------------------------------------------------------------
# Record skipped/failed benchmark command into an executable rerun script
# ------------------------------------------------------------------------------
record_failed_rerun() {
    local reason="$1" step_idx="$2" total="$3" kernel="$4" memmap="$5" bench="$6" ratio="${7:-}" dist="${8:-}" adaptive="${9:-}" bound="${10:-}" thp="${11:-}" hint="${12:-0}" naive="${13:-0}"
    local ts="[$(date '+%Y-%m-%d %H:%M:%S')]"

    if [ ! -f "$RERUN_LOG_FILE" ]; then
        {
            echo "#!/bin/bash"
            echo "# Auto-generated list of skipped/failed regression commands to rerun"
            echo ""
        } > "$RERUN_LOG_FILE"
        chmod +x "$RERUN_LOG_FILE"
    fi

    local env_vars="TIER_RATIO='${ratio}' THP_MODE='${thp}'"
    if is_prefetch_kernel "$kernel"; then
        env_vars+=" PREFETCH_PROMOTE_DISTANCE='${dist}' PREFETCH_DEMOTE_DISTANCE='${dist}' PREFETCH_MIN_DISTANCE='${bound}' PREFETCH_ADAPTIVE='${adaptive}' PREFETCH_HINT='${hint}' PREFETCH_NAIVE='${naive}'"
    fi

    {
        echo "# ${ts} Step $((step_idx + 1))/${total} | Reason: ${reason} | Kernel: ${kernel} | Memmap: ${memmap}"
        echo "# Boot cmd: sudo bash '${ROOT_DIR}/baselines/scripts/manage_kernels.sh' '${kernel}' update_grub --memmap '${memmap}' --reboot"
        echo "sudo ${env_vars} bash '${RUN_WORKLOADS}' '${bench}'"
        echo ""
    } >> "$RERUN_LOG_FILE"
    sync
    log "${YELLOW}[!] Logged rerun command to ${RERUN_LOG_FILE}${NC}"
}

# ------------------------------------------------------------------------------
# Execute workload with inline prefetch, ratio, and THP environment options
# ------------------------------------------------------------------------------
run_target_benchmark() {
    local bench="$1" ratio="${2:-}" dist="${3:-}" adaptive="${4:-}" bound="${5:-}" thp="${6:-}" hint="${7:-0}" naive="${8:-0}" extra_flag="${9:-}"

    KEEP_MACHINE_CONFIG=1 \
    TIER_RATIO="${ratio}" \
    THP_MODE="${thp}" \
    PREFETCH_PROMOTE_DISTANCE="${dist}" \
    PREFETCH_DEMOTE_DISTANCE="${dist}" \
    PREFETCH_MIN_DISTANCE="${bound}" \
    PREFETCH_ADAPTIVE="${adaptive}" \
    PREFETCH_HINT="${hint}" \
    PREFETCH_NAIVE="${naive}" \
    bash "$RUN_WORKLOADS" ${extra_flag:+"$extra_flag"} "$bench"
}

# ------------------------------------------------------------------------------
# Persist regression execution state to disk
# ------------------------------------------------------------------------------
save_state() {
    local idx="$1" last_exec="${2:-}" exec_attempts="${3:-0}"
    printf "CURRENT_INDEX=%s\nSTARTED_TIME=%s\nLAST_EXEC_INDEX=%s\nEXEC_ATTEMPTS=%s\n" \
        "$idx" "${STARTED_TIME:-$(date +%s)}" "$last_exec" "$exec_attempts" > "$STATE_FILE"
    sync
}

# ------------------------------------------------------------------------------
# Iterate through regression matrix, manage reboots, and execute benchmarks
# ------------------------------------------------------------------------------
execute_step() {
    load_targets
    [ ! -f "$STATE_FILE" ] && { log "${RED}No active regression state found. Exiting.${NC}"; exit 0; }
    enable_hang_auto_reboot

    # shellcheck source=/dev/null
    source "$STATE_FILE"
    local total="${#TARGET_ITEMS[@]}"
    local start_idx="${CURRENT_INDEX:-0}"
    local steps_run_this_boot=0
    trap 'trap - INT TERM; restore_machine; exit 130' INT TERM

    for ((idx = start_idx; idx < total; idx++)); do
        IFS='|' read -r CURRENT_KERNEL CURRENT_BENCHMARK CURRENT_RATIO CURRENT_DIST CURRENT_ADAPTIVE CURRENT_BOUND CURRENT_THP CURRENT_HINT CURRENT_NAIVE <<< "${TARGET_ITEMS[$idx]}"
        CURRENT_THP="${CURRENT_THP:-}"
        CURRENT_HINT="${CURRENT_HINT:-0}"
        CURRENT_NAIVE="${CURRENT_NAIVE:-0}"
        CURRENT_MEMMAP=$(resolve_memmap "$CURRENT_BENCHMARK" "$CURRENT_RATIO")

        # If current running system doesn't match required kernel and memmap, configure & reboot
        if ! is_target_and_memmap_running "$CURRENT_KERNEL" "$CURRENT_MEMMAP"; then
            local last_k="${LAST_REBOOT_KERNEL:-}" last_m="${LAST_REBOOT_MEMMAP:-}" attempts="${REBOOT_ATTEMPTS:-0}"
            [ "$last_k" == "$CURRENT_KERNEL" ] && [ "$last_m" == "$CURRENT_MEMMAP" ] && attempts=$((attempts + 1)) || attempts=1

            if [ "$attempts" -ge 4 ]; then
                log "${RED}[ERROR] System failed to switch to '${CURRENT_KERNEL}' with ${CURRENT_MEMMAP} after 3 reboot attempts.${NC}"
                log "${RED}[ERROR] Aborting automated regression to prevent an infinite reboot loop / hang.${NC}"
                remove_service
                exit 1
            fi

            # Record reboot attempt in state file
            echo "CURRENT_INDEX=${CURRENT_INDEX}" > "$STATE_FILE"
            echo "STARTED_TIME=${STARTED_TIME:-$(date +%s)}" >> "$STATE_FILE"
            echo "LAST_REBOOT_KERNEL=${CURRENT_KERNEL}" >> "$STATE_FILE"
            echo "LAST_REBOOT_MEMMAP=${CURRENT_MEMMAP}" >> "$STATE_FILE"
            echo "REBOOT_ATTEMPTS=${attempts}" >> "$STATE_FILE"

            log "${YELLOW}[!] Current system does not match target '${CURRENT_KERNEL}' or ${CURRENT_MEMMAP} (Attempt ${attempts}/3).${NC}"
            trap - INT TERM
            switch_kernel_and_reboot "$CURRENT_KERNEL" "$CURRENT_MEMMAP"
            return 0
        fi

        # Successfully running target kernel and memmap; reset reboot attempts
        LAST_REBOOT_KERNEL=""
        LAST_REBOOT_MEMMAP=""
        REBOOT_ATTEMPTS=0

        # Reboot cleanly before next step if a daemon reset was requested or unreclaimable Node 0
        # memory drifted above 3 GiB after a prior benchmark in this boot (never on a fresh boot)
        local reboot_reason=""
        if [ -f /run/lowtier_need_reboot ]; then
            rm -f /run/lowtier_need_reboot
            reboot_reason="Kernel daemon reset requested (/run/lowtier_need_reboot). Rebooting for clean state..."
        elif [ "${steps_run_this_boot}" -gt 0 ] && [ -f /sys/devices/system/node/node0/meminfo ]; then
            local n0_unreclaim_kb
            n0_unreclaim_kb=$(awk '
                $3 == "MemTotal:"     { t = $4 }
                $3 == "MemFree:"      { f = $4 }
                $3 == "FilePages:"    { fp = $4 }
                $3 == "SReclaimable:" { sr = $4 }
                END { u = t - f - fp - sr; print (t > 0 && u > 0) ? u : 0 }
            ' /sys/devices/system/node/node0/meminfo 2>/dev/null || echo 0)
            if [ "${n0_unreclaim_kb}" -gt 3145728 ]; then
                reboot_reason="Node 0 memory drift detected ($(( n0_unreclaim_kb / 1024 )) MiB unreclaimable > 3072 MiB). Rebooting for clean headroom..."
            fi
        fi
        if [ -n "${reboot_reason}" ]; then
            log "${YELLOW}[!] ${reboot_reason}${NC}"
            save_state "$idx" "${LAST_EXEC_INDEX:-}" "${EXEC_ATTEMPTS:-0}"
            trap - INT TERM
            sleep 2 && reboot
            return 0
        fi

        # Crash-loop skip guard: track mid-benchmark panics/reboots per step
        local max_exec_attempts="${MAX_EXEC_ATTEMPTS:-3}"
        local last_exec_idx="${LAST_EXEC_INDEX:-}"
        local exec_attempts="${EXEC_ATTEMPTS:-0}"

        # If a prior attempt already wrote a completed log before a teardown panic/reboot,
        # preserve it and advance instead of overwriting/retrying it.
        if [ "${last_exec_idx}" == "${idx}" ]; then
            local prev_log
            prev_log=$(run_target_benchmark "$CURRENT_BENCHMARK" "$CURRENT_RATIO" "$CURRENT_DIST" "$CURRENT_ADAPTIVE" "${CURRENT_BOUND:-}" "${CURRENT_THP:-}" "${CURRENT_HINT}" "${CURRENT_NAIVE}" --get-log-path 2>/dev/null || true)
            if [ -n "${prev_log}" ] && [ -f "${prev_log}" ] && \
               [ "$(stat -c %Y "${prev_log}" 2>/dev/null || echo 0)" -ge "${STARTED_TIME:-0}" ] && \
               grep -qF "[+] Workload completed (status=0)." "${prev_log}" 2>/dev/null; then
                log "${GREEN}[+] Step $((idx + 1))/${total} already completed before teardown reboot (${prev_log}); advancing.${NC}"
                CURRENT_INDEX=$((idx + 1))
                LAST_EXEC_INDEX=""
                EXEC_ATTEMPTS=0
                save_state "${CURRENT_INDEX}" "" 0
                continue
            fi
        fi

        if [ "${last_exec_idx}" == "${idx}" ]; then
            exec_attempts=$((exec_attempts + 1))
        else
            exec_attempts=1
        fi

        if [ "${exec_attempts}" -gt "${max_exec_attempts}" ]; then
            log "${RED}[ERROR] Step $((idx + 1))/${total} (${CURRENT_KERNEL} | ${CURRENT_BENCHMARK} | ${CURRENT_RATIO}${CURRENT_THP:+ | THP: ${CURRENT_THP}}) crashed/rebooted ${max_exec_attempts} times.${NC}"
            log "${YELLOW}[!] Skipping unstable step $((idx + 1))/${total} to prevent an infinite crash-reboot loop.${NC}"
            record_failed_rerun "crashed/rebooted ${max_exec_attempts} times" "$idx" "$total" "$CURRENT_KERNEL" "$CURRENT_MEMMAP" "$CURRENT_BENCHMARK" "$CURRENT_RATIO" "$CURRENT_DIST" "$CURRENT_ADAPTIVE" "${CURRENT_BOUND:-}" "${CURRENT_THP:-}" "${CURRENT_HINT}" "${CURRENT_NAIVE}"
            CURRENT_INDEX=$((idx + 1))
            LAST_EXEC_INDEX=""
            EXEC_ATTEMPTS=0
            save_state "${CURRENT_INDEX}" "" 0
            continue
        fi

        # Persist current step attempt BEFORE launching workload so it survives a kernel panic/reboot
        LAST_EXEC_INDEX="${idx}"
        EXEC_ATTEMPTS="${exec_attempts}"
        save_state "${idx}" "${LAST_EXEC_INDEX}" "${EXEC_ATTEMPTS}"

        # Build informative logging tag for prefetch and THP parameters
        local dist_tag=""
        if is_prefetch_kernel "$CURRENT_KERNEL"; then
            [ "$CURRENT_NAIVE" == "1" ] && dist_tag+=" | Engine: Naive"
            [ "$CURRENT_NAIVE" == "0" ] && dist_tag+=" | Engine: Deep-tune"
            [ -n "$CURRENT_HINT" ] && dist_tag+=" | Hint: ${CURRENT_HINT}"
            [ "$CURRENT_ADAPTIVE" == "1" ] && dist_tag+=" | Mode: Adaptive"
            [ "$CURRENT_ADAPTIVE" == "0" ] && dist_tag+=" | Mode: Static"
            [ -n "$CURRENT_DIST" ] && dist_tag+=" | Distance: ${CURRENT_DIST}"
            [ -n "${CURRENT_BOUND:-}" ] && dist_tag+=" | Bounds: ${CURRENT_BOUND}"
        fi
        [ -n "$CURRENT_THP" ] && dist_tag+=" | THP: ${CURRENT_THP}"

        log "${CYAN}================================================================================${NC}"
        log "${CYAN} [Step $((idx + 1))/${total}] Kernel: ${CURRENT_KERNEL} | Workload: ${CURRENT_BENCHMARK} | Ratio: ${CURRENT_RATIO}${dist_tag} (${CURRENT_MEMMAP}) [Attempt ${exec_attempts}/${max_exec_attempts}]${NC}"
        log "${CYAN}================================================================================${NC}"

        # Settle system before running benchmark
        log "Allowing system to settle for 10 seconds before starting benchmark..."
        sleep 10

        # Execute targeted workload
        log "${GREEN}Executing targeted benchmark: ${CURRENT_BENCHMARK} (Ratio: ${CURRENT_RATIO}${dist_tag})...${NC}"
        local bench_rc=0
        run_target_benchmark "$CURRENT_BENCHMARK" "$CURRENT_RATIO" "$CURRENT_DIST" "$CURRENT_ADAPTIVE" "${CURRENT_BOUND:-}" "${CURRENT_THP:-}" "${CURRENT_HINT}" "${CURRENT_NAIVE}" || bench_rc=$?
        if [ "${bench_rc}" -ne 0 ]; then
            log "${RED}[WARNING] Benchmark ${CURRENT_BENCHMARK} exited with status ${bench_rc}${NC}"
            record_failed_rerun "exited with status ${bench_rc}" "$idx" "$total" "$CURRENT_KERNEL" "$CURRENT_MEMMAP" "$CURRENT_BENCHMARK" "$CURRENT_RATIO" "$CURRENT_DIST" "$CURRENT_ADAPTIVE" "${CURRENT_BOUND:-}" "${CURRENT_THP:-}" "${CURRENT_HINT}" "${CURRENT_NAIVE}"
        fi

        log "${GREEN}Completed benchmark: ${CURRENT_BENCHMARK} (Ratio: ${CURRENT_RATIO}${dist_tag}).${NC}"
        steps_run_this_boot=$((steps_run_this_boot + 1))

        # Advance to next item and reset crash-loop counters
        CURRENT_INDEX=$((idx + 1))
        LAST_EXEC_INDEX=""
        EXEC_ATTEMPTS=0
        save_state "${CURRENT_INDEX}" "" 0
    done

    # Clean up state and service upon completing all execution steps
    trap - INT TERM
    log "${GREEN}================================================================================${NC}"
    log "${GREEN} ALL MULTI-KERNEL & MULTI-RATIO REGRESSIONS COMPLETED (${total}/${total})! ${NC}"
    log "${GREEN}================================================================================${NC}"
    restore_machine
    remove_service
    rm -f "$STATE_FILE"
}

# ------------------------------------------------------------------------------
# Initialize state and start regression suite from step 0
# ------------------------------------------------------------------------------
start_regression() {
    load_targets
    local total="${#TARGET_ITEMS[@]}"

    # Start fresh logs for a new regression run (resume preserves existing logs)
    rm -f "$LOG_FILE" "$RERUN_LOG_FILE"

    echo -e "${CYAN}================================================================================${NC}"
    echo -e "${CYAN} Starting Automated Multi-Kernel & Multi-Ratio Regression Suite (${total} Steps) ${NC}"
    print_regression_config
    echo -e "${CYAN}================================================================================${NC}"

    # Always clean & pre-build configured benchmarks once before starting reboots
    ensure_cpus_online
    log "${CYAN}Cleaning and pre-building configured benchmarks (${BENCHMARKS[*]})...${NC}"
    bash "$SETUP_WORKLOADS" prebuild "${BENCHMARKS[@]}"
    log "${GREEN}Completed benchmark clean & pre-build.${NC}"

    echo "CURRENT_INDEX=0" > "$STATE_FILE"
    echo "STARTED_TIME=$(date +%s)" >> "$STATE_FILE"
    install_service
    execute_step
}

# ------------------------------------------------------------------------------
# Display current regression progress, system status, and active target
# ------------------------------------------------------------------------------
show_status() {
    load_targets
    local total="${#TARGET_ITEMS[@]}"

    echo -e "${CYAN}================================================================================${NC}"
    echo -e "${CYAN}                  Automated Regression Status                                   ${NC}"
    echo -e "${CYAN}================================================================================${NC}"
    print_regression_config
    echo -e "${CYAN}================================================================================${NC}"
    echo -e "${CYAN} Current Configs:                                                               ${NC}"
    echo -e " Total Steps        : ${total}"
    echo -e " Running Kernel     : $(uname -r)"
    echo -e " Active Cmdline     : $(grep -oE 'memmap=[^ ]+' /proc/cmdline 2>/dev/null || echo 'none')"
    echo -e " Active THP Mode    : $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "N/A")"
    local svc_status="inactive"
    if [ -f "$SERVICE_FILE" ]; then
        svc_status="$(timeout 2 systemctl is-active "${SERVICE_NAME}" 2>/dev/null)" || svc_status="${svc_status:-inactive}"
    fi
    echo -e " Autostart Service  : ${svc_status}"

    if [ ! -f "$STATE_FILE" ]; then
        echo -e "\n${YELLOW}No active regression in progress.${NC}"
    else
        # shellcheck source=/dev/null
        source "$STATE_FILE"
        local curr="${CURRENT_INDEX:-0}"
        if [ "$curr" -lt "$total" ]; then
            IFS='|' read -r k b r d a bound thp h naive <<< "${TARGET_ITEMS[$curr]}"
            local m
            m=$(resolve_memmap "$b" "$r")
            echo -e "\n Current Progress   : Step $((curr + 1)) of ${total}"
            local mode_str=""
            if is_prefetch_kernel "$k"; then
                [ "$naive" == "1" ] && mode_str+=", Engine=Naive"
                [ "$naive" == "0" ] && mode_str+=", Engine=Deep-tune"
                [ -n "$h" ] && mode_str+=", Hint=${h}"
                [ "$a" == "1" ] && mode_str+=", Mode=Adaptive"
                [ "$a" == "0" ] && mode_str+=", Mode=Static"
            fi
            local d_info=""
            if [ -n "$d" ] && is_prefetch_kernel "$k"; then
                d_info=", Distance='${d}'"
            fi
            local bound_info=""
            if [ -n "$bound" ] && is_prefetch_kernel "$k"; then
                bound_info=", Bounds='${bound}'"
            fi
            echo -e " Active Target      : Kernel='${k}', Benchmark='${b}', Ratio='${r}'${mode_str}${d_info}${bound_info}${thp:+, THP=${thp}} (${m})"
        else
            echo -e "\n Current Progress   : Completed all ${total} steps"
        fi
    fi
    echo -e "${CYAN}================================================================================${NC}"
}

# ------------------------------------------------------------------------------
# Cancel running regression, bring CPUs online, and reset state
# ------------------------------------------------------------------------------
abort_regression() {
    local clean_all="${1:-0}"
    log "${YELLOW}Aborting automated regression and cleaning up...${NC}"
    restore_machine
    remove_service
    if [ "${clean_all}" == "1" ]; then
        rm -f "$STATE_FILE" "$LOG_FILE" "$RERUN_LOG_FILE"
        echo -e "${GREEN}Automated regression reset (state and logs cleared).${NC}"
    else
        log "${GREEN}Automated regression stopped (state preserved for resume).${NC}"
    fi
}

# ------------------------------------------------------------------------------
# CLI Router and Entry Point
# ------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ACTION="${1:-start}"

    case "$ACTION" in
        start|run)
            start_regression
            ;;
        resume)
            if [ ! -f "$SERVICE_FILE" ]; then
                sed -i 's/^REBOOT_ATTEMPTS=.*/REBOOT_ATTEMPTS=0/; s/^EXEC_ATTEMPTS=.*/EXEC_ATTEMPTS=0/; s/^LAST_EXEC_INDEX=.*/LAST_EXEC_INDEX=/' "$STATE_FILE" 2>/dev/null || true
                install_service
            fi
            execute_step
            ;;
        status|check)
            show_status
            ;;
        stop|abort|cancel)
            abort_regression 0
            ;;
        reset)
            abort_regression 1
            ;;
        -h|--help|help)
            echo "Usage: sudo $0 [start | resume | status | stop | reset]"
            echo ""
            echo "Commands:"
            echo "  start (default) : Clean & pre-build benchmarks, then start fresh automated regression"
            echo "  resume          : Resume regression from current state step (preserves logs)"
            echo "  status          : Display current progress and active target"
            echo "  stop / abort    : Cancel running regression and remove autostart service (keeps state & logs)"
            echo "  reset           : Clear state, logs, failed_reruns.sh, remove service, and online CPUs"
            ;;
        *)
            echo "Usage: sudo $0 [start | resume | status | stop | reset]"
            exit 1
            ;;
    esac
fi
