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
RUN_WORKLOADS="${ROOT_DIR}/workloads/scripts/run_workloads.sh"

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
        pact-prefetch)
            [[ "$k_str" =~ pact && "$k_str" =~ prefetch ]]
            ;;
        pact)
            [[ "$k_str" =~ pact && ! "$k_str" =~ prefetch ]]
            ;;
        colloid-tpp-alto-prefetch)
            [[ "$k_str" =~ colloid && "$k_str" =~ alto && "$k_str" =~ prefetch ]]
            ;;
        colloid-tpp-prefetch)
            [[ "$k_str" =~ colloid && ! "$k_str" =~ alto && "$k_str" =~ prefetch ]]
            ;;
        colloid-tpp-alto)
            [[ "$k_str" =~ colloid && "$k_str" =~ alto && ! "$k_str" =~ prefetch ]]
            ;;
        colloid-tpp)
            [[ "$k_str" =~ colloid && ! "$k_str" =~ alto && ! "$k_str" =~ prefetch ]]
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
        nomad-alto)
            [[ "$k_str" =~ nomad && "$k_str" =~ alto && ! "$k_str" =~ prefetch ]]
            ;;
        nomad)
            [[ "$k_str" =~ nomad && ! "$k_str" =~ alto && ! "$k_str" =~ prefetch ]]
            ;;
        hybridtier)
            [[ "$k_str" =~ hybridtier ]]
            ;;
        tpp)
            [[ "$k_str" =~ tpp && ! "$k_str" =~ colloid ]]
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

    local kdir="${ROOT_DIR}/baselines/${target}/linux"
    [ -d "$kdir" ] && ([ -f "$kdir/arch/x86/boot/bzImage" ] || [ -f "$kdir/vmlinux" ])
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
    THP_MODES=()
    # shellcheck source=/dev/null
    source "$REGRESSION_LIST"
    read -ra TIER_RATIOS <<< "${TIER_RATIOS[*]:-}"
    read -ra BENCHMARKS <<< "${BENCHMARKS[*]:-}"
    read -ra KERNELS <<< "${KERNELS[*]:-}"
    read -ra PREFETCH_DISTANCES <<< "${PREFETCH_DISTANCES[*]:-}"
    read -ra PREFETCH_BOUNDS <<< "${PREFETCH_BOUNDS[*]:-${PREFETCH_MAX_DISTANCES[*]:-}}"
    read -ra PREFETCH_ADAPTIVE_MODES <<< "${PREFETCH_ADAPTIVE_MODES[*]:-}"
    read -ra THP_MODES <<< "${THP_MODES[*]:-}"

    [ ${#KERNELS[@]} -eq 0 ] && { echo -e "${RED}Error: No target kernels specified in ${REGRESSION_LIST}${NC}"; exit 1; }
    [ ${#BENCHMARKS[@]} -eq 0 ] && { echo -e "${RED}Error: No benchmarks specified in ${REGRESSION_LIST}${NC}"; exit 1; }
    [ ${#TIER_RATIOS[@]} -eq 0 ] && { echo -e "${RED}Error: No tier ratios specified in ${REGRESSION_LIST}${NC}"; exit 1; }

    [ ${#PREFETCH_ADAPTIVE_MODES[@]} -eq 0 ] && PREFETCH_ADAPTIVE_MODES=(1)
    [ ${#THP_MODES[@]} -eq 0 ] && THP_MODES=(madvise)

    # Pre-build prefetch evaluation configurations: "adaptive_mode|distance|bounds"
    local prefetch_configs=()
    for a in "${PREFETCH_ADAPTIVE_MODES[@]}"; do
        if [ "$a" == "1" ]; then
            # Adaptive mode: evaluates dynamically adjusted lookahead within bounds
            if [ ${#PREFETCH_BOUNDS[@]} -gt 0 ]; then
                for bound in "${PREFETCH_BOUNDS[@]}"; do
                    prefetch_configs+=("1||${bound}")
                done
            else
                prefetch_configs+=("1||")
            fi
        elif [ "$a" == "0" ]; then
            # Static mode: evaluates fixed lookahead distances (clamp bounds do not apply)
            if [ ${#PREFETCH_DISTANCES[@]} -gt 0 ]; then
                for d in "${PREFETCH_DISTANCES[@]}"; do
                    prefetch_configs+=("0|${d}|")
                done
            else
                prefetch_configs+=("0|p5_d2|")
            fi
        fi
    done
    [ ${#prefetch_configs[@]} -eq 0 ] && prefetch_configs+=("1||")

    # Execution matrix: Kernel -> Benchmark -> Ratio -> THP -> PrefetchConfig
    # Grouping THP and prefetch configs under the same (Kernel, Benchmark, Ratio) minimizes reboots
    TARGET_ITEMS=()
    for k in "${KERNELS[@]}"; do
        local configs=()
        if is_prefetch_kernel "$k"; then
            configs=("${prefetch_configs[@]}")
        else
            configs=("||")
        fi

        for b in "${BENCHMARKS[@]}"; do
            for r in "${TIER_RATIOS[@]}"; do
                for thp in "${THP_MODES[@]}"; do
                    for cfg in "${configs[@]}"; do
                        IFS='|' read -r a d bound <<< "$cfg"
                        TARGET_ITEMS+=("${k}|${b}|${r}|${d}|${a}|${bound}|${thp}")
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

    ensure_cpus_online
    local MANAGE_KERNELS="${ROOT_DIR}/baselines/scripts/manage_kernels.sh"
    if is_kernel_installed "$target_kernel"; then
        log "${GREEN}[*] Kernel '${target_kernel}' found in /boot. Updating GRUB default...${NC}"
        bash "$MANAGE_KERNELS" "$target_kernel" update_grub --memmap "$target_memmap" --reboot
    elif is_kernel_ready "$target_kernel"; then
        log "${YELLOW}[!] Kernel '${target_kernel}' built in tree but not installed in /boot. Installing and updating GRUB...${NC}"
        bash "$MANAGE_KERNELS" "$target_kernel" --memmap "$target_memmap" --reboot
    else
        log "${YELLOW}[!] Source/binary for '${target_kernel}' not built. Compiling and installing...${NC}"
        bash "$MANAGE_KERNELS" "$target_kernel" --memmap "$target_memmap" --reboot
    fi

    # Fallback reboot in case manage_kernels.sh returned without rebooting
    sleep 2
    log "${YELLOW}[*] Triggering system reboot...${NC}"
    reboot
}

# ------------------------------------------------------------------------------
# Execute workload with inline prefetch, ratio, and THP environment options
# ------------------------------------------------------------------------------
run_target_benchmark() {
    local bench="$1" ratio="${2:-}" dist="${3:-}" adaptive="${4:-}" bound="${5:-}" thp="${6:-}"

    TIER_RATIO="${ratio}" \
    THP_MODE="${thp}" \
    THP="${thp}" \
    PREFETCH_PROMOTE_DISTANCE="${dist}" \
    PREFETCH_DEMOTE_DISTANCE="${dist}" \
    PREFETCH_DISTANCE="${dist}" \
    PREFETCH_MIN_DISTANCE="${bound}" \
    PREFETCH_MAX_DISTANCE="${bound}" \
    PREFETCH_ADAPTIVE="${adaptive}" \
    bash "$RUN_WORKLOADS" "$bench"
}

# ------------------------------------------------------------------------------
# Iterate through regression matrix, manage reboots, and execute benchmarks
# ------------------------------------------------------------------------------
execute_step() {
    load_targets
    [ ! -f "$STATE_FILE" ] && { log "${RED}No active regression state found. Exiting.${NC}"; exit 0; }

    # shellcheck source=/dev/null
    source "$STATE_FILE"
    local total="${#TARGET_ITEMS[@]}"
    local start_idx="${CURRENT_INDEX:-0}"

    for ((idx = start_idx; idx < total; idx++)); do
        IFS='|' read -r CURRENT_KERNEL CURRENT_BENCHMARK CURRENT_RATIO CURRENT_DIST CURRENT_ADAPTIVE CURRENT_BOUND CURRENT_THP <<< "${TARGET_ITEMS[$idx]}"
        CURRENT_THP="${CURRENT_THP:-}"
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
            switch_kernel_and_reboot "$CURRENT_KERNEL" "$CURRENT_MEMMAP"
            return 0
        fi

        # Successfully running target kernel and memmap; reset reboot attempts
        LAST_REBOOT_KERNEL=""
        LAST_REBOOT_MEMMAP=""
        REBOOT_ATTEMPTS=0

        # Build informative logging tag for prefetch and THP parameters
        local dist_tag=""
        if is_prefetch_kernel "$CURRENT_KERNEL"; then
            [ "$CURRENT_ADAPTIVE" == "1" ] && dist_tag+=" | Mode: Adaptive"
            [ "$CURRENT_ADAPTIVE" == "0" ] && dist_tag+=" | Mode: Static"
            [ -n "$CURRENT_DIST" ] && dist_tag+=" | Distance: ${CURRENT_DIST}"
            [ -n "${CURRENT_BOUND:-}" ] && dist_tag+=" | Bounds: ${CURRENT_BOUND}"
        fi
        [ -n "$CURRENT_THP" ] && dist_tag+=" | THP: ${CURRENT_THP}"

        log "${CYAN}================================================================================${NC}"
        log "${CYAN} [Step $((idx + 1))/${total}] Kernel: ${CURRENT_KERNEL} | Workload: ${CURRENT_BENCHMARK} | Ratio: ${CURRENT_RATIO}${dist_tag} (${CURRENT_MEMMAP})${NC}"
        log "${CYAN}================================================================================${NC}"

        # Settle system before running benchmark
        log "Allowing system to settle for 10 seconds before starting benchmark..."
        sleep 10

        # Execute targeted workload
        log "${GREEN}Executing targeted benchmark: ${CURRENT_BENCHMARK} (Ratio: ${CURRENT_RATIO}${dist_tag})...${NC}"
        run_target_benchmark "$CURRENT_BENCHMARK" "$CURRENT_RATIO" "$CURRENT_DIST" "$CURRENT_ADAPTIVE" "${CURRENT_BOUND:-}" "${CURRENT_THP:-}" || log "${RED}[WARNING] Benchmark ${CURRENT_BENCHMARK} exited with status $?${NC}"

        log "${GREEN}Completed benchmark: ${CURRENT_BENCHMARK} (Ratio: ${CURRENT_RATIO}${dist_tag}).${NC}"

        # Advance to next item
        CURRENT_INDEX=$((CURRENT_INDEX + 1))
        echo "CURRENT_INDEX=${CURRENT_INDEX}" > "$STATE_FILE"
        echo "STARTED_TIME=${STARTED_TIME:-$(date +%s)}" >> "$STATE_FILE"
    done

    # Clean up state and service upon completing all execution steps
    log "${GREEN}================================================================================${NC}"
    log "${GREEN} ALL MULTI-KERNEL & MULTI-RATIO REGRESSIONS COMPLETED (${total}/${total})! ${NC}"
    log "${GREEN}================================================================================${NC}"
    remove_service
    rm -f "$STATE_FILE"
}

# ------------------------------------------------------------------------------
# Initialize state and start regression suite from step 0
# ------------------------------------------------------------------------------
start_regression() {
    load_targets
    local total="${#TARGET_ITEMS[@]}"

    echo -e "${CYAN}================================================================================${NC}"
    echo -e "${CYAN} Starting Automated Multi-Kernel & Multi-Ratio Regression Suite (${total} Steps) ${NC}"
    print_regression_config
    echo -e "${CYAN}================================================================================${NC}"

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
            IFS='|' read -r k b r d a bound thp <<< "${TARGET_ITEMS[$curr]}"
            local m
            m=$(resolve_memmap "$b" "$r")
            echo -e "\n Current Progress   : Step $((curr + 1)) of ${total}"
            local mode_str=""
            if is_prefetch_kernel "$k"; then
                [ "$a" == "1" ] && mode_str=", Mode=Adaptive"
                [ "$a" == "0" ] && mode_str=", Mode=Static"
            fi
            local d_info=""
            if [ -n "$d" ] && is_prefetch_kernel "$k"; then
                d_info=", Distance='${d}'"
            fi
            local bound_info=""
            if [ -n "$bound" ] && is_prefetch_kernel "$k"; then
                bound_info=", Bounds='${bound}'"
            fi
            echo -e " Active Target      : Kernel='${k}', Benchmark='${b}', Ratio='${r}'${d_info}${bound_info}${mode_str}${thp:+, THP=${thp}} (${m})"
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
    log "${YELLOW}Aborting automated regression and cleaning up...${NC}"
    ensure_cpus_online
    remove_service
    rm -f "$STATE_FILE"
    log "${GREEN}Automated regression stopped.${NC}"
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
            execute_step
            ;;
        status|check)
            show_status
            ;;
        stop|abort|cancel|reset)
            abort_regression
            ;;
        -h|--help|help)
            echo "Usage: sudo $0 [start | resume | status | stop | reset]"
            echo ""
            echo "Commands:"
            echo "  start (default) : Start or resume automated regression over regression_list"
            echo "  resume          : Resume regression from current state step"
            echo "  status          : Display current progress and active target"
            echo "  stop / abort    : Cancel running regression and remove autostart service"
            echo "  reset           : Clear state, remove autostart service, and bring CPUs online"
            ;;
        *)
            echo "Usage: sudo $0 [start | resume | status | stop | reset]"
            exit 1
            ;;
    esac
fi
