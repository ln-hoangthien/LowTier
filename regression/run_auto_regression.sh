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
#   sudo ./run_auto_regression.sh [start | status | stop | reset]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
REGRESSION_LIST="${REGRESSION_LIST:-${SCRIPT_DIR}/regression_list}"
STATE_FILE="${SCRIPT_DIR}/.regression_state"
SERVICE_NAME="lowtier-regression.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
LOG_FILE="${SCRIPT_DIR}/auto_regression_orchestrator.log"

# Formatting Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Allow status and help to be checked without root
ACTION="${1:-start}"
if [[ "$ACTION" != "status" && "$ACTION" != "check" && "$ACTION" != "-h" && "$ACTION" != "--help" && "$ACTION" != "help" ]]; then
    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}Notice: Root privileges are required to manage GRUB, reboots, and services.${NC}"
        exec sudo env PATH="$PATH" ROOT_DIR="$ROOT_DIR" bash "$0" "$@"
    fi
fi

log() {
    local timestamp="[$(date '+%Y-%m-%d %H:%M:%S')]"
    local raw_msg="$1"
    # Print formatted message with terminal colors to console / stdout
    echo -e "${timestamp} ${raw_msg}"
    # Strip ANSI escape sequences before appending to the log file
    local clean_msg
    clean_msg=$(printf '%b' "${raw_msg}" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g')
    echo "${timestamp} ${clean_msg}" >> "$LOG_FILE"
}

# ------------------------------------------------------------------------------
# Helper: Memmap calculation via manage_kernels.sh
# ------------------------------------------------------------------------------
resolve_memmap() {
    local bench="$1" ratio="${2:-1:1}"
    bash "${ROOT_DIR}/baselines/scripts/manage_kernels.sh" resolve_memmap "$bench" "$ratio"
}

# ------------------------------------------------------------------------------
# Helper: Parse regression_list
# ------------------------------------------------------------------------------
load_targets() {
    if [ ! -f "$REGRESSION_LIST" ]; then
        echo -e "${RED}Error: regression_list not found at ${REGRESSION_LIST}${NC}"
        exit 1
    fi

    if [ ! -s "$REGRESSION_LIST" ]; then
        echo -e "${RED}Error: regression_list at ${REGRESSION_LIST} is empty${NC}"
        exit 1
    fi

    unset TIER_RATIOS BENCHMARKS KERNELS
    # shellcheck source=/dev/null
    source "$REGRESSION_LIST"
    read -ra TIER_RATIOS <<< "${TIER_RATIOS[*]//,/ }"
    read -ra BENCHMARKS <<< "${BENCHMARKS[*]//,/ }"
    read -ra KERNELS <<< "${KERNELS[*]//,/ }"

    if [ ${#KERNELS[@]} -eq 0 ]; then
        echo -e "${RED}Error: No target kernels specified in ${REGRESSION_LIST}${NC}"
        exit 1
    fi
    if [ ${#BENCHMARKS[@]} -eq 0 ]; then
        echo -e "${RED}Error: No benchmarks specified in ${REGRESSION_LIST} (BENCHMARKS=...)${NC}"
        exit 1
    fi
    if [ ${#TIER_RATIOS[@]} -eq 0 ]; then
        echo -e "${RED}Error: No tier ratios specified in ${REGRESSION_LIST} (TIER_RATIOS=...)${NC}"
        exit 1
    fi

    # Execution matrix: Kernel -> Benchmark -> Ratio
    TARGET_ITEMS=()
    for k in "${KERNELS[@]}"; do
        for b in "${BENCHMARKS[@]}"; do
            for r in "${TIER_RATIOS[@]}"; do
                TARGET_ITEMS+=("${k}|${b}|${r}")
            done
        done
    done
}

# ------------------------------------------------------------------------------
# Helper: Manage systemd autostart service across reboots
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
ExecStart=/bin/bash ${SCRIPT_DIR}/run_auto_regression.sh --step
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
}

remove_service() {
    if [ -f "$SERVICE_FILE" ]; then
        log "${CYAN}Disabling and removing systemd autostart service...${NC}"
        systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    fi
}

# ------------------------------------------------------------------------------
# Helper: Kernel verification
# ------------------------------------------------------------------------------
is_kernel_ready() {
    local target="$1"
    local kdir=""
    case "$target" in
        generic|distro|default)
            return 0
            ;;
        memtis)
            kdir="${ROOT_DIR}/baselines/memtis/linux"
            ;;
        nomad)
            kdir="${ROOT_DIR}/baselines/nomad/linux"
            ;;
        nomad-noinline)
            kdir="${ROOT_DIR}/baselines/nomad-noinline/linux"
            ;;
        nomad-alto|nomad_alto)
            kdir="${ROOT_DIR}/baselines/nomad-alto/linux"
            ;;
        nomad-alto-noinline|nomad_alto_noinline|nomad-noinline-alto|nomad_noinline_alto)
            kdir="${ROOT_DIR}/baselines/nomad-alto-noinline/linux"
            ;;
        tpp)
            kdir="${ROOT_DIR}/baselines/tpp/linux"
            ;;
        colloid-tpp|colloid|colloid_tpp)
            kdir="${ROOT_DIR}/baselines/colloid-tpp/linux"
            ;;
        colloid-tpp-alto|colloid-alto|colloid_tpp_alto|colloid_alto)
            kdir="${ROOT_DIR}/baselines/colloid-tpp-alto/linux"
            ;;
        *)
            kdir="${ROOT_DIR}/baselines/${target}/linux"
            ;;
    esac
    [ -d "$kdir" ] && ([ -f "$kdir/arch/x86/boot/bzImage" ] || [ -f "$kdir/vmlinux" ])
}

is_kernel_running() {
    local target="$1"
    local curr_k
    curr_k=$(uname -r | tr '[:upper:]' '[:lower:]')

    case "$target" in
        generic|distro|default)
            [[ "$curr_k" =~ generic ]]
            ;;
        memtis)
            [[ "$curr_k" =~ memtis ]]
            ;;
        nomad)
            [[ "$curr_k" =~ nomad && ! "$curr_k" =~ noinline && ! "$curr_k" =~ alto ]]
            ;;
        nomad-noinline)
            [[ "$curr_k" =~ nomad-noinline && ! "$curr_k" =~ alto ]]
            ;;
        nomad-alto|nomad_alto)
            [[ "$curr_k" =~ nomad-alto && ! "$curr_k" =~ noinline ]]
            ;;
        nomad-alto-noinline|nomad_alto_noinline|nomad-noinline-alto|nomad_noinline_alto)
            [[ "$curr_k" =~ nomad-alto && "$curr_k" =~ noinline ]]
            ;;
        tpp)
            [[ "$curr_k" =~ tpp && ! "$curr_k" =~ colloid ]]
            ;;
        colloid-tpp|colloid|colloid_tpp)
            [[ "$curr_k" =~ colloid-tpp && ! "$curr_k" =~ alto ]]
            ;;
        colloid-tpp-alto|colloid-alto|colloid_tpp_alto|colloid_alto)
            [[ "$curr_k" =~ colloid-tpp-alto ]]
            ;;
        *)
            [[ "$curr_k" =~ $(echo "$target" | tr '[:upper:]' '[:lower:]') ]]
            ;;
    esac
}

is_target_and_memmap_running() {
    local target_kernel="$1"
    local target_memmap="$2"

    if ! is_kernel_running "$target_kernel"; then
        return 1
    fi
    if [ -n "$target_memmap" ] && ! grep -qF "$target_memmap" /proc/cmdline; then
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Helper: Kernel switch & reboot
# ------------------------------------------------------------------------------
switch_kernel_and_reboot() {
    local target_kernel="$1"
    local target_memmap="$2"
    log "${BLUE}================================================================================${NC}"
    log "${BLUE} Switching to: '${target_kernel}' with ${target_memmap} ${NC}"
    log "${BLUE}================================================================================${NC}"

    local MANAGE_KERNELS="${ROOT_DIR}/baselines/scripts/manage_kernels.sh"
    if is_kernel_ready "$target_kernel"; then
        bash "$MANAGE_KERNELS" "$target_kernel" update_grub --memmap "$target_memmap" --reboot
    else
        log "${YELLOW}[!] Source/binary for '${target_kernel}' not built. Compiling and installing...${NC}"
        bash "$MANAGE_KERNELS" "$target_kernel" --memmap "$target_memmap" --reboot
    fi
}

# ------------------------------------------------------------------------------
# Helper: Execute targeted benchmark directly
# ------------------------------------------------------------------------------
run_target_benchmark() {
    local bench="$1"
    local ratio="${2:-${TIER_RATIO:-}}"
    local run_sh="${ROOT_DIR}/workloads/scripts/run_workloads.sh"
    if [[ "$bench" =~ ^(gapbs_[a-z]+)_(kron|urand|twitter|web|road)$ ]]; then
        bash "$run_sh" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$ratio"
    else
        bash "$run_sh" "$bench" "" "$ratio"
    fi
}

# ------------------------------------------------------------------------------
# Action: Step Execution
# ------------------------------------------------------------------------------
execute_step() {
    load_targets
    [ ! -f "$STATE_FILE" ] && { log "${RED}No active regression state found. Exiting.${NC}"; exit 0; }

    # shellcheck source=/dev/null
    source "$STATE_FILE"
    CURRENT_INDEX="${CURRENT_INDEX:-0}"
    TOTAL_ITEMS="${#TARGET_ITEMS[@]}"

    while [ "$CURRENT_INDEX" -lt "$TOTAL_ITEMS" ]; do
        IFS='|' read -r CURRENT_KERNEL CURRENT_BENCHMARK CURRENT_RATIO <<< "${TARGET_ITEMS[$CURRENT_INDEX]}"
        CURRENT_MEMMAP=$(resolve_memmap "$CURRENT_BENCHMARK" "$CURRENT_RATIO")

        # If current running system doesn't match required kernel and memmap, configure & reboot
        if ! is_target_and_memmap_running "$CURRENT_KERNEL" "$CURRENT_MEMMAP"; then
            log "${YELLOW}[!] Current system does not match target '${CURRENT_KERNEL}' or ${CURRENT_MEMMAP}.${NC}"
            switch_kernel_and_reboot "$CURRENT_KERNEL" "$CURRENT_MEMMAP"
            return 0
        fi

        log "${CYAN}================================================================================${NC}"
        log "${CYAN} [Step $((CURRENT_INDEX + 1))/${TOTAL_ITEMS}] Kernel: ${CURRENT_KERNEL} | Workload: ${CURRENT_BENCHMARK} | Ratio: ${CURRENT_RATIO} (${CURRENT_MEMMAP})${NC}"
        log "${CYAN}================================================================================${NC}"

        log "Allowing system to settle for 10 seconds before starting benchmark..."
        sleep 10

        log "${GREEN}Executing targeted benchmark: ${CURRENT_BENCHMARK} (Ratio: ${CURRENT_RATIO})...${NC}"
        export TIER_RATIO="$CURRENT_RATIO"
        run_target_benchmark "$CURRENT_BENCHMARK" "$CURRENT_RATIO"
        log "${GREEN}Completed benchmark: ${CURRENT_BENCHMARK} (Ratio: ${CURRENT_RATIO}).${NC}"

        # Advance to next item
        CURRENT_INDEX=$((CURRENT_INDEX + 1))
        echo "CURRENT_INDEX=${CURRENT_INDEX}" > "$STATE_FILE"
        echo "STARTED_TIME=${STARTED_TIME:-$(date +%s)}" >> "$STATE_FILE"

        if [ "$CURRENT_INDEX" -lt "$TOTAL_ITEMS" ]; then
            IFS='|' read -r NEXT_KERNEL NEXT_BENCHMARK NEXT_RATIO <<< "${TARGET_ITEMS[$CURRENT_INDEX]}"
            NEXT_MEMMAP=$(resolve_memmap "$NEXT_BENCHMARK" "$NEXT_RATIO")
            if ! is_target_and_memmap_running "$NEXT_KERNEL" "$NEXT_MEMMAP"; then
                log "${YELLOW}Next target [Step $((CURRENT_INDEX + 1))/${TOTAL_ITEMS}]: '${NEXT_KERNEL}' | ${NEXT_BENCHMARK} | ${NEXT_RATIO} (${NEXT_MEMMAP})${NC}"
                switch_kernel_and_reboot "$NEXT_KERNEL" "$NEXT_MEMMAP"
                return 0
            fi
        fi
    done

    log "${GREEN}================================================================================${NC}"
    log "${GREEN} ALL MULTI-KERNEL & MULTI-RATIO REGRESSIONS COMPLETED (${TOTAL_ITEMS}/${TOTAL_ITEMS})! ${NC}"
    log "${GREEN}================================================================================${NC}"
    remove_service
    rm -f "$STATE_FILE"
}

# ------------------------------------------------------------------------------
# Action: Start Regression Suite
# ------------------------------------------------------------------------------
start_regression() {
    load_targets
    local total="${#TARGET_ITEMS[@]}"

    echo -e "${CYAN}================================================================================${NC}"
    echo -e "${CYAN} Starting Automated Multi-Kernel & Multi-Ratio Regression Suite (${total} Steps) ${NC}"
    echo -e "${CYAN} Kernels     : ${KERNELS[*]}${NC}"
    echo -e "${CYAN} Benchmarks  : ${BENCHMARKS[*]}${NC}"
    echo -e "${CYAN} Tier Ratios : ${TIER_RATIOS[*]}${NC}"
    echo -e "${CYAN}================================================================================${NC}"

    echo "CURRENT_INDEX=0" > "$STATE_FILE"
    echo "STARTED_TIME=$(date +%s)" >> "$STATE_FILE"
    install_service

    execute_step
}

# ------------------------------------------------------------------------------
# Action: Check Status
# ------------------------------------------------------------------------------
show_status() {
    load_targets
    local total="${#TARGET_ITEMS[@]}"

    echo -e "${CYAN}================================================================================${NC}"
    echo -e "${CYAN}                  Automated Regression Status                                   ${NC}"
    echo -e "${CYAN}================================================================================${NC}"
    echo -e " Configured Kernels : ${KERNELS[*]}"
    echo -e " Benchmarks         : ${BENCHMARKS[*]}"
    echo -e " Tier Ratios        : ${TIER_RATIOS[*]}"
    echo -e " Total Steps        : ${total}"
    echo -e " Running Kernel     : $(uname -r)"
    echo -e " Active Cmdline     : $(grep -oE 'memmap=[^ ]+' /proc/cmdline 2>/dev/null || echo 'none')"
    echo -e " Autostart Service  : $(systemctl is-active --quiet "${SERVICE_NAME}" && echo "active" || echo "inactive")"

    if [ ! -f "$STATE_FILE" ]; then
        echo -e "\n${YELLOW}No active regression in progress.${NC}"
    else
        # shellcheck source=/dev/null
        source "$STATE_FILE"
        local curr="${CURRENT_INDEX:-0}"
        if [ "$curr" -lt "$total" ]; then
            IFS='|' read -r k b r <<< "${TARGET_ITEMS[$curr]}"
            local m
            m=$(resolve_memmap "$b" "$r")
            echo -e "\n Current Progress   : Step $((curr + 1)) of ${total}"
            echo -e " Active Target      : Kernel='${k}', Benchmark='${b}', Ratio='${r}' (${m})"
        else
            echo -e "\n Current Progress   : Completed all ${total} steps"
        fi
    fi
    echo -e "${CYAN}================================================================================${NC}"
}

# ------------------------------------------------------------------------------
# Action: Stop / Abort
# ------------------------------------------------------------------------------
abort_regression() {
    log "${YELLOW}Aborting automated regression and cleaning up...${NC}"
    remove_service
    rm -f "$STATE_FILE"
    log "${GREEN}Automated regression stopped.${NC}"
}

# ------------------------------------------------------------------------------
# CLI Router
# ------------------------------------------------------------------------------
ACTION="${1:-start}"

case "$ACTION" in
    start|run)
        start_regression
        ;;
    --step|step)
        execute_step
        ;;
    status|check)
        show_status
        ;;
    stop|abort|cancel|reset)
        abort_regression
        ;;
    -h|--help|help)
        echo "Usage: sudo $0 [start | status | stop | reset]"
        echo ""
        echo "Commands:"
        echo "  start (default) : Start the automated regression over regression_list"
        echo "  status          : Display current progress and active target"
        echo "  stop / abort    : Cancel running regression and remove autostart service"
        echo "  reset           : Clear state and autostart service"
        ;;
    *)
        echo "Usage: sudo $0 [start | status | stop | reset]"
        exit 1
        ;;
esac
