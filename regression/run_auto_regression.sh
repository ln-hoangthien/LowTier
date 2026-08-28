#!/bin/bash
# ==============================================================================
# Automated Multi-Kernel Regression Orchestrator
# Location: ~/thienle/LowTier/regression/run_auto_regression.sh
# ==============================================================================
# Description:
#   Reads kernel targets sequentially from regression_list, sets GRUB default
#   kernel via manage_kernels.sh, reboots, runs run_regression.sh upon boot,
#   and proceeds to the next kernel until all targets are evaluated.
#
# Usage:
#   sudo ./run_auto_regression.sh [start | status | stop | reset]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
REGRESSION_LIST="${SCRIPT_DIR}/regression_list"
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
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg" | tee -a "$LOG_FILE"
}

# ------------------------------------------------------------------------------
# Helper: Parse regression_list
# ------------------------------------------------------------------------------
load_targets() {
    if [ ! -f "$REGRESSION_LIST" ]; then
        echo -e "${RED}Error: regression_list not found at ${REGRESSION_LIST}${NC}"
        exit 1
    fi
    TARGETS=()
    while IFS= read -r line || [ -n "$line" ]; do
        # Strip comments and whitespace
        local cleaned
        cleaned=$(echo "$line" | sed 's/#.*//' | tr -d ' \t\r\n')
        if [ -n "$cleaned" ]; then
            TARGETS+=("$cleaned")
        fi
    done < "$REGRESSION_LIST"

    if [ ${#TARGETS[@]} -eq 0 ]; then
        echo -e "${RED}Error: No valid kernel targets found in ${REGRESSION_LIST}${NC}"
        exit 1
    fi
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
# Helper: Check if target kernel source tree and compiled bzImage/vmlinux exist
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

    # Check if the linux source directory exists and contains a built bzImage or vmlinux
    if [ -d "$kdir" ] && ([ -f "$kdir/arch/x86/boot/bzImage" ] || [ -f "$kdir/vmlinux" ]); then
        return 0
    fi

    return 1
}

# ------------------------------------------------------------------------------
# Helper: Check if system is already booted into the requested target kernel
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# Helper: Set next kernel in GRUB and reboot (compiles first if not ready)
# ------------------------------------------------------------------------------
switch_kernel_and_reboot() {
    local target="$1"
    log "${BLUE}================================================================================${NC}"
    log "${BLUE} Preparing kernel switch to: '${target}' ${NC}"
    log "${BLUE}================================================================================${NC}"

    local MANAGE_KERNELS="${ROOT_DIR}/baselines/scripts/manage_kernels.sh"
    if [ ! -f "$MANAGE_KERNELS" ]; then
        log "${RED}Error: manage_kernels.sh not found at ${MANAGE_KERNELS}${NC}"
        exit 1
    fi

    if is_kernel_ready "$target"; then
        if [[ "$target" =~ ^(generic|distro|default)$ ]]; then
            log "${GREEN}[+] Setting GRUB default to official distro generic kernel...${NC}"
        else
            log "${GREEN}[+] Kernel '${target}' source and binary found in baselines/${target}/linux.${NC}"
            log "${CYAN}Updating GRUB default boot entry to '${target}' and rebooting...${NC}"
        fi
        bash "$MANAGE_KERNELS" "$target" update_grub --reboot
    else
        log "${YELLOW}[!] Kernel '${target}' source/binary NOT found in baselines/${target}/linux.${NC}"
        log "${CYAN}Automatically compiling, installing modules & kernel, and setting GRUB default via manage_kernels.sh...${NC}"
        bash "$MANAGE_KERNELS" "$target" --reboot
    fi
}

# ------------------------------------------------------------------------------
# Action: Step Execution (Run workload on current kernel, then switch to next)
# ------------------------------------------------------------------------------
execute_step() {
    load_targets

    if [ ! -f "$STATE_FILE" ]; then
        log "${RED}No active regression state found. Exiting.${NC}"
        exit 0
    fi

    # Read state
    # shellcheck source=/dev/null
    source "$STATE_FILE"
    CURRENT_INDEX="${CURRENT_INDEX:-0}"
    TOTAL_KERNELS="${#TARGETS[@]}"

    if [ "$CURRENT_INDEX" -ge "$TOTAL_KERNELS" ]; then
        log "${GREEN}================================================================================${NC}"
        log "${GREEN} ALL KERNEL REGRESSIONS COMPLETED (${TOTAL_KERNELS}/${TOTAL_KERNELS})! ${NC}"
        log "${GREEN}================================================================================${NC}"
        remove_service
        rm -f "$STATE_FILE"
        exit 0
    fi

    CURRENT_TARGET="${TARGETS[$CURRENT_INDEX]}"
    log "${CYAN}================================================================================${NC}"
    log "${CYAN} [Step $((CURRENT_INDEX + 1))/${TOTAL_KERNELS}] Target: '${CURRENT_TARGET}' | Current Kernel: $(uname -r)${NC}"
    log "${CYAN}================================================================================${NC}"

    # Allow system services to fully settle after boot
    log "Allowing system to settle for 10 seconds before starting workloads..."
    sleep 10

    # Execute workload suite for this kernel
    local RUN_REGRESS="${SCRIPT_DIR}/run_regression.sh"
    if [ -f "$RUN_REGRESS" ]; then
        log "${GREEN}Running workload regression suite: ${RUN_REGRESS}...${NC}"
        bash "$RUN_REGRESS"
        log "${GREEN}Workload regression completed for target: '${CURRENT_TARGET}' (Kernel: $(uname -r))${NC}"
    else
        log "${RED}Error: run_regression.sh not found at ${RUN_REGRESS}${NC}"
    fi

    # Advance to next kernel target
    NEXT_INDEX=$((CURRENT_INDEX + 1))
    if [ "$NEXT_INDEX" -lt "$TOTAL_KERNELS" ]; then
        NEXT_TARGET="${TARGETS[$NEXT_INDEX]}"
        echo "CURRENT_INDEX=${NEXT_INDEX}" > "$STATE_FILE"
        echo "STARTED_TIME=${STARTED_TIME:-$(date +%s)}" >> "$STATE_FILE"
        log "${YELLOW}Progress: Finished $((NEXT_INDEX))/${TOTAL_KERNELS} kernels. Next target: '${NEXT_TARGET}'${NC}"
        switch_kernel_and_reboot "$NEXT_TARGET"
    else
        log "${GREEN}================================================================================${NC}"
        log "${GREEN} ALL KERNEL REGRESSIONS COMPLETED SUCCESSFULLY! (${TOTAL_KERNELS}/${TOTAL_KERNELS})${NC}"
        log "${GREEN} Output logs saved to: ${ROOT_DIR}/workloads/output/${NC}"
        log "${GREEN}================================================================================${NC}"
        remove_service
        rm -f "$STATE_FILE"
    fi
}

# ------------------------------------------------------------------------------
# Action: Start Regression Suite
# ------------------------------------------------------------------------------
start_regression() {
    load_targets
    local total="${#TARGETS[@]}"

    echo -e "${CYAN}================================================================================${NC}"
    echo -e "${CYAN}        Starting Automated Multi-Kernel Regression Suite (${total} Kernels)        ${NC}"
    echo -e "${CYAN}================================================================================${NC}"
    echo "Targets to evaluate in sequence:"
    local i=1
    for t in "${TARGETS[@]}"; do
        echo "  $i. $t"
        i=$((i + 1))
    done
    echo -e "${CYAN}================================================================================${NC}"

    # Save initial state
    echo "CURRENT_INDEX=0" > "$STATE_FILE"
    echo "STARTED_TIME=$(date +%s)" >> "$STATE_FILE"

    # Install autostart service for cross-reboot execution
    install_service

    FIRST_TARGET="${TARGETS[0]}"
    if is_kernel_running "$FIRST_TARGET"; then
        log "${GREEN}[+] Currently running target kernel '${FIRST_TARGET}' ($(uname -r)). Starting regression immediately without reboot...${NC}"
        execute_step
    else
        log "Initiating first target: '${FIRST_TARGET}'..."
        switch_kernel_and_reboot "$FIRST_TARGET"
    fi
}

# ------------------------------------------------------------------------------
# Action: Check Status
# ------------------------------------------------------------------------------
show_status() {
    load_targets
    local total="${#TARGETS[@]}"

    if [ ! -f "$STATE_FILE" ]; then
        echo -e "${YELLOW}No active regression in progress.${NC}"
        echo "Configured targets in regression_list (${total} total):"
        local i=1
        for t in "${TARGETS[@]}"; do
            echo "  $i. $t"
            i=$((i + 1))
        done
        return 0
    fi

    # shellcheck source=/dev/null
    source "$STATE_FILE"
    local curr="${CURRENT_INDEX:-0}"
    local target="${TARGETS[$curr]:-Unknown}"

    echo -e "${CYAN}================================================================================${NC}"
    echo -e "${CYAN}                  Automated Regression Status                                   ${NC}"
    echo -e "${CYAN}================================================================================${NC}"
    echo -e " Current Progress   : $((curr + 1)) of ${total} kernels"
    echo -e " Current Target     : ${target}"
    echo -e " Running Kernel     : $(uname -r)"
    echo -e " Autostart Service  : $(systemctl is-enabled ${SERVICE_NAME} 2>/dev/null || echo "inactive")"
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
    --step)
        execute_step
        ;;
    status|check)
        show_status
        ;;
    stop|abort|cancel)
        abort_regression
        ;;
    reset)
        abort_regression
        ;;
    -h|--help|help)
        echo "Usage: sudo $0 [start | status | stop | reset]"
        echo ""
        echo "Commands:"
        echo "  start (default) : Start the automated regression over regression_list"
        echo "  status          : Display current progress and active target"
        echo "  stop / abort    : Cancel the running regression and remove reboot service"
        echo "  reset           : Clear state and service configuration"
        ;;
    *)
        echo "Usage: sudo $0 [start | status | stop | reset]"
        exit 1
        ;;
esac
