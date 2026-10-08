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
    if [[ "$ACTION" != "status" && "$ACTION" != "check" && "$ACTION" != "dry-run" && "$ACTION" != "-h" && "$ACTION" != "--help" && "$ACTION" != "help" ]]; then
        if [ "$EUID" -ne 0 ]; then
            echo -e "${YELLOW}Notice: Root privileges are required to manage GRUB, reboots, and services.${NC}"
            exec sudo env PATH="$PATH" ROOT_DIR="$ROOT_DIR" bash "$0" "$@"
        fi
    fi
fi

log() {
    local timestamp="[$(date '+%Y-%m-%d %H:%M:%S')]"
    local raw_msg="$1"
    echo -e "${timestamp} ${raw_msg}"
    local clean_msg
    clean_msg=$(printf '%b' "${raw_msg}" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g')
    echo "${timestamp} ${clean_msg}" >> "$LOG_FILE"
}

# ------------------------------------------------------------------------------
# Helpers: CPU & Prefetch Verification
# ------------------------------------------------------------------------------
ensure_cpus_online() {
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/online; do
        [ -f "$cpu" ] && echo 1 > "$cpu" 2>/dev/null || true
    done
}

is_prefetch_kernel() {
    [[ "${1,,}" =~ prefetch ]]
}

parse_prefetch_params() {
    local dist="${1:-}"
    local bound="${2:-}"
    [ $# -ge 3 ] && [ -n "${3:-}" ] && bound="$3"

    # Reset / unset previous environment values
    unset PREFETCH_DISTANCE PREFETCH_PROMOTE_DISTANCE PREFETCH_DEMOTE_DISTANCE \
          PREFETCH_MIN_DISTANCE PREFETCH_MAX_DISTANCE || true

    # 1. Parse Distance (promote / demote lookahead)
    if [ -n "$dist" ]; then
        if [[ "$dist" =~ p([0-9]+)_d([0-9]+) ]]; then
            export PREFETCH_PROMOTE_DISTANCE="${BASH_REMATCH[1]}"
            export PREFETCH_DEMOTE_DISTANCE="${BASH_REMATCH[2]}"
            export PREFETCH_DISTANCE="${PREFETCH_PROMOTE_DISTANCE}"
        elif [[ "$dist" =~ ^([0-9]+):([0-9]+)$ ]]; then
            export PREFETCH_PROMOTE_DISTANCE="${BASH_REMATCH[1]}"
            export PREFETCH_DEMOTE_DISTANCE="${BASH_REMATCH[2]}"
            export PREFETCH_DISTANCE="${PREFETCH_PROMOTE_DISTANCE}"
        elif [[ "$dist" =~ ^([0-9]+)$ ]]; then
            export PREFETCH_DISTANCE="$dist"
            export PREFETCH_PROMOTE_DISTANCE="$dist"
            export PREFETCH_DEMOTE_DISTANCE="$dist"
        fi
    fi

    # 2. Parse Bounds (min/max clamp)
    local raw_bound="${bound}"
    if [ -z "$raw_bound" ] && [[ "$dist" =~ min[0-9]+|max[0-9]+ ]]; then
        raw_bound="$dist"
    fi
    if [ -n "$raw_bound" ]; then
        if [[ "$raw_bound" =~ min([0-9]+)_max([0-9]+) || "$raw_bound" =~ ^([0-9]+):([0-9]+)$ ]]; then
            export PREFETCH_MIN_DISTANCE="${BASH_REMATCH[1]}"
            export PREFETCH_MAX_DISTANCE="${BASH_REMATCH[2]}"
        else
            [[ "$raw_bound" =~ min([0-9]+) ]] && export PREFETCH_MIN_DISTANCE="${BASH_REMATCH[1]}"
            [[ "$raw_bound" =~ max([0-9]+) ]] && export PREFETCH_MAX_DISTANCE="${BASH_REMATCH[1]}"
            if [[ "$raw_bound" =~ ^([0-9]+)$ ]]; then
                export PREFETCH_MIN_DISTANCE=1
                export PREFETCH_MAX_DISTANCE="$raw_bound"
            fi
        fi
    fi
}

parse_prefetch_distance() {
    parse_prefetch_params "$@"
}

resolve_memmap() {
    local bench="$1" ratio="${2:-1:1}"
    bash "${ROOT_DIR}/baselines/scripts/manage_kernels.sh" resolve_memmap "$bench" "$ratio"
}

# ------------------------------------------------------------------------------
# Helpers: Kernel Identification & State Matching (Unified Single Source of Truth)
# ------------------------------------------------------------------------------
matches_kernel_target() {
    local target="$1"
    local k_str="${2,,}"
    case "$target" in
        generic|distro|default)
            [[ "$k_str" =~ generic ]]
            ;;
        memtis-prefetch|memtis_prefetch)
            [[ "$k_str" =~ memtis && "$k_str" =~ prefetch ]]
            ;;
        memtis)
            [[ "$k_str" =~ memtis && ! "$k_str" =~ prefetch ]]
            ;;
        nomad-alto-prefetch|nomad_alto_prefetch)
            [[ "$k_str" =~ nomad && "$k_str" =~ alto && "$k_str" =~ prefetch ]]
            ;;
        nomad-prefetch|nomad_prefetch)
            [[ "$k_str" =~ nomad && ! "$k_str" =~ alto && "$k_str" =~ prefetch ]]
            ;;
        nomad-alto-noinline|nomad_alto_noinline|nomad-noinline-alto|nomad_noinline_alto)
            [[ "$k_str" =~ nomad && "$k_str" =~ alto && "$k_str" =~ noinline ]]
            ;;
        nomad-noinline)
            [[ "$k_str" =~ nomad && ! "$k_str" =~ alto && "$k_str" =~ noinline ]]
            ;;
        nomad-alto|nomad_alto)
            [[ "$k_str" =~ nomad && "$k_str" =~ alto && ! "$k_str" =~ noinline && ! "$k_str" =~ prefetch ]]
            ;;
        nomad)
            [[ "$k_str" =~ nomad && ! "$k_str" =~ alto && ! "$k_str" =~ noinline && ! "$k_str" =~ prefetch ]]
            ;;
        colloid-tpp-alto-prefetch|colloid_tpp_alto_prefetch)
            [[ "$k_str" =~ colloid && "$k_str" =~ alto && "$k_str" =~ prefetch ]]
            ;;
        colloid-tpp-prefetch|colloid_tpp_prefetch)
            [[ "$k_str" =~ colloid && ! "$k_str" =~ alto && "$k_str" =~ prefetch ]]
            ;;
        colloid-tpp-alto|colloid-alto|colloid_tpp_alto|colloid_alto)
            [[ "$k_str" =~ colloid && "$k_str" =~ alto && ! "$k_str" =~ prefetch ]]
            ;;
        colloid-tpp|colloid|colloid_tpp)
            [[ "$k_str" =~ colloid && ! "$k_str" =~ alto && ! "$k_str" =~ prefetch ]]
            ;;
        pact-prefetch-batch|pact_prefetch_batch)
            [[ "$k_str" =~ prefetch-batch ]]
            ;;
        pact-prefetch|pact_prefetch)
            [[ "$k_str" =~ pact && "$k_str" =~ prefetch && ! "$k_str" =~ prefetch-batch ]]
            ;;
        pact)
            [[ "$k_str" =~ pact && ! "$k_str" =~ prefetch ]]
            ;;
        tpp)
            [[ "$k_str" =~ tpp && ! "$k_str" =~ colloid ]]
            ;;
        hybridtier)
            [[ "$k_str" =~ hybridtier ]]
            ;;
        *)
            [[ "$k_str" =~ $(echo "$target" | tr '[:upper:]' '[:lower:]') ]]
            ;;
    esac
}

is_kernel_ready() {
    local target="$1"
    case "$target" in
        generic|distro|default) return 0 ;;
    esac

    local norm="${target,,}"
    norm="${norm//_/-}"
    case "$norm" in
        colloid|colloid-tpp)           norm="colloid-tpp" ;;
        colloid-alto|colloid-tpp-alto) norm="colloid-tpp-alto" ;;
        nomad-noinline-alto)           norm="nomad-alto-noinline" ;;
    esac

    local kdir="${ROOT_DIR}/baselines/${norm}/linux"
    [ -d "$kdir" ] && ([ -f "$kdir/arch/x86/boot/bzImage" ] || [ -f "$kdir/vmlinux" ])
}

is_kernel_running() {
    matches_kernel_target "$1" "$(uname -r)"
}

is_kernel_installed() {
    local target="$1"
    for vmlinuz in /boot/vmlinuz-*; do
        [ -f "$vmlinuz" ] && matches_kernel_target "$target" "$(basename "$vmlinuz")" && return 0
    done
    return 1
}

is_target_and_memmap_running() {
    local target_kernel="$1" target_memmap="$2"
    is_kernel_running "$target_kernel" || return 1
    if [ -n "$target_memmap" ] && ! grep -qE "(^|[[:space:]])${target_memmap}([[:space:]]|$)" /proc/cmdline; then
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Helpers: Service & Target Parsing
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

    # Execution matrix: Kernel -> Benchmark -> Ratio -> THP -> (Mode -> Distance -> Bounds)
    TARGET_ITEMS=()
    for k in "${KERNELS[@]}"; do
        for b in "${BENCHMARKS[@]}"; do
            for r in "${TIER_RATIOS[@]}"; do
                for thp in "${THP_MODES[@]}"; do
                    if is_prefetch_kernel "$k"; then
                        for a in "${PREFETCH_ADAPTIVE_MODES[@]}"; do
                            local eval_d=()
                            if [ "$a" == "1" ]; then
                                # Adaptive mode dynamically adapts distance; default distance is taken
                                eval_d=("")
                            elif [ "$a" == "0" ]; then
                                # Static mode sweeps prefetch distances
                                if [ ${#PREFETCH_DISTANCES[@]} -gt 0 ]; then
                                    eval_d=("${PREFETCH_DISTANCES[@]}")
                                else
                                    eval_d=(0:0 1:1 2:2 4:4 8:8 10:10 12:12 14:14 16:16)
                                fi
                            fi

                            local eval_bounds=()
                            if [ ${#PREFETCH_BOUNDS[@]} -gt 0 ]; then
                                eval_bounds=("${PREFETCH_BOUNDS[@]}")
                            else
                                eval_bounds=("")
                            fi

                            for d in "${eval_d[@]}"; do
                                for bound in "${eval_bounds[@]}"; do
                                    TARGET_ITEMS+=("${k}|${b}|${r}|${d}|${a}|${bound}|${thp}")
                                done
                            done
                        done
                    else
                        # Non-prefetch kernels: prefetch characteristics are empty, but THP is evaluated!
                        TARGET_ITEMS+=("${k}|${b}|${r}||||${thp}")
                    fi
                done
            done
        done
    done
}

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
# Helpers: Kernel switch & benchmark runner
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

run_target_benchmark() {
    local bench="$1" ratio="${2:-${TIER_RATIO:-}}" dist="${3:-}" adaptive="${4:-}" bound="${5:-}" thp="${6:-}"
    local run_sh="${ROOT_DIR}/workloads/scripts/run_workloads.sh"

    parse_prefetch_params "$dist" "$bound"
    [ -n "$adaptive" ] && export PREFETCH_ADAPTIVE="$adaptive" || unset PREFETCH_ADAPTIVE || true

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
        IFS='|' read -r CURRENT_KERNEL CURRENT_BENCHMARK CURRENT_RATIO CURRENT_DIST CURRENT_ADAPTIVE CURRENT_BOUND CURRENT_THP <<< "${TARGET_ITEMS[$CURRENT_INDEX]}"
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

        local mode_name=""
        if is_prefetch_kernel "$CURRENT_KERNEL"; then
            [ "$CURRENT_ADAPTIVE" == "1" ] && mode_name="Adaptive"
            [ "$CURRENT_ADAPTIVE" == "0" ] && mode_name="Static"
        fi
        local dist_tag=""
        if is_prefetch_kernel "$CURRENT_KERNEL"; then
            [ -n "$CURRENT_DIST" ] && dist_tag+=" | Distance: ${CURRENT_DIST}"
            [ -n "${CURRENT_BOUND:-}" ] && dist_tag+=" | Bounds: ${CURRENT_BOUND}"
            [ -n "$mode_name" ] && dist_tag+=" | Mode: ${mode_name}"
        fi
        [ -n "$CURRENT_THP" ] && dist_tag+=" | THP: ${CURRENT_THP}"

        log "${CYAN}================================================================================${NC}"
        log "${CYAN} [Step $((CURRENT_INDEX + 1))/${TOTAL_ITEMS}] Kernel: ${CURRENT_KERNEL} | Workload: ${CURRENT_BENCHMARK} | Ratio: ${CURRENT_RATIO}${dist_tag} (${CURRENT_MEMMAP})${NC}"
        log "${CYAN}================================================================================${NC}"

        # Configure Transparent Huge Pages (THP) online (for both prefetch and non-prefetch kernels)
        local thp_file="/sys/kernel/mm/transparent_hugepage/enabled"
        cur_thp=$(cat "$thp_file" 2>/dev/null || echo "N/A")
        log "${GREEN}[*] Configured THP (/sys/kernel/mm/transparent_hugepage/enabled): ${cur_thp} (requested=${CURRENT_THP})${NC}"

        # If prefetch kernel, configure online sysfs parameters
        if is_prefetch_kernel "$CURRENT_KERNEL"; then
            parse_prefetch_params "${CURRENT_DIST:-}" "${CURRENT_BOUND:-}"
            [ -n "$CURRENT_ADAPTIVE" ] && export PREFETCH_ADAPTIVE="$CURRENT_ADAPTIVE" || export PREFETCH_ADAPTIVE=1

            local prefetch_sysfs=""
            [ -d "/sys/kernel/mm/page_prefetch" ] && prefetch_sysfs="/sys/kernel/mm/page_prefetch"
            [ -d "/sys/kernel/mm/pact_prefetch" ] && prefetch_sysfs="/sys/kernel/mm/pact_prefetch"

            if [ -n "$prefetch_sysfs" ]; then
                local is_zero=0
                if [ -n "${CURRENT_DIST:-}" ]; then
                    [ "${PREFETCH_DISTANCE:-0}" == "0" ] && [ "${PREFETCH_DEMOTE_DISTANCE:-0}" == "0" ] && is_zero=1
                fi

                [ -f "${prefetch_sysfs}/enabled" ] && echo "$(( 1 - is_zero ))" > "${prefetch_sysfs}/enabled" 2>/dev/null || true
                [ -n "$CURRENT_ADAPTIVE" ] && [ -f "${prefetch_sysfs}/adaptive" ] && echo "$CURRENT_ADAPTIVE" > "${prefetch_sysfs}/adaptive" 2>/dev/null || true
                if [ -n "${PREFETCH_PROMOTE_DISTANCE:-}" ]; then
                    [ -f "${prefetch_sysfs}/promote_distance" ] && echo "$PREFETCH_PROMOTE_DISTANCE" > "${prefetch_sysfs}/promote_distance" 2>/dev/null || true
                    [ -f "${prefetch_sysfs}/distance" ] && echo "$PREFETCH_DISTANCE" > "${prefetch_sysfs}/distance" 2>/dev/null || true
                fi
                if [ -n "${PREFETCH_DEMOTE_DISTANCE:-}" ]; then
                    [ -f "${prefetch_sysfs}/demote_distance" ] && echo "$PREFETCH_DEMOTE_DISTANCE" > "${prefetch_sysfs}/demote_distance" 2>/dev/null || true
                fi
                if [ -n "${PREFETCH_MIN_DISTANCE:-}" ]; then
                    [ -f "${prefetch_sysfs}/min_distance" ] && echo "$PREFETCH_MIN_DISTANCE" > "${prefetch_sysfs}/min_distance" 2>/dev/null || true
                fi
                if [ -n "${PREFETCH_MAX_DISTANCE:-}" ]; then
                    [ -f "${prefetch_sysfs}/max_distance" ] && echo "$PREFETCH_MAX_DISTANCE" > "${prefetch_sysfs}/max_distance" 2>/dev/null || true
                fi

                local cur_d cur_p cur_m cur_a cur_min cur_max tier_info=""
                cur_d=$(cat "${prefetch_sysfs}/distance" 2>/dev/null || echo "${PREFETCH_DISTANCE:-}")
                cur_p=$(cat "${prefetch_sysfs}/promote_distance" 2>/dev/null || echo "")
                cur_m=$(cat "${prefetch_sysfs}/demote_distance" 2>/dev/null || echo "")
                cur_a=$(cat "${prefetch_sysfs}/adaptive" 2>/dev/null || echo "$CURRENT_ADAPTIVE")
                cur_min=$(cat "${prefetch_sysfs}/min_distance" 2>/dev/null || echo "${PREFETCH_MIN_DISTANCE:-}")
                cur_max=$(cat "${prefetch_sysfs}/max_distance" 2>/dev/null || echo "${PREFETCH_MAX_DISTANCE:-}")

                local extra_details=""
                [ -n "$cur_min" ] && extra_details+=", min_dist=${cur_min}"
                [ -n "$cur_max" ] && extra_details+=", max_dist=${cur_max}"

                if [ -n "$cur_p" ] || [ -n "$cur_m" ]; then
                    tier_info=" (promote=${cur_p:-$cur_d}, demote=${cur_m:-$cur_d}${cur_a:+, adaptive=${cur_a}}${extra_details})"
                elif [ -n "$cur_a" ]; then
                    tier_info=" (adaptive=${cur_a}${extra_details})"
                fi
                log "${GREEN}[*] Configured ${prefetch_sysfs}: enabled=$(( 1 - is_zero ))${tier_info}${NC}"
            fi
        else
            parse_prefetch_params ""
            unset PREFETCH_ADAPTIVE || true
        fi

        log "Allowing system to settle for 10 seconds before starting benchmark..."
        sleep 10

        log "${GREEN}Executing targeted benchmark: ${CURRENT_BENCHMARK} (Ratio: ${CURRENT_RATIO}${dist_tag})...${NC}"
        export TIER_RATIO="$CURRENT_RATIO"
        export THP_MODE="${CURRENT_THP:-}"
        export THP="${CURRENT_THP:-}"
        if is_prefetch_kernel "$CURRENT_KERNEL"; then
            run_target_benchmark "$CURRENT_BENCHMARK" "$CURRENT_RATIO" "$CURRENT_DIST" "$CURRENT_ADAPTIVE" "${CURRENT_BOUND:-}" "${CURRENT_THP:-}" || log "${RED}[WARNING] Benchmark ${CURRENT_BENCHMARK} exited with status $?${NC}"
        else
            run_target_benchmark "$CURRENT_BENCHMARK" "$CURRENT_RATIO" "" "" "" "${CURRENT_THP:-}" || log "${RED}[WARNING] Benchmark ${CURRENT_BENCHMARK} exited with status $?${NC}"
        fi

        # Safety check: if run_workloads.sh output without distance/adaptive suffix exists, rename it (for *-prefetch* kernels only)
        if [ -n "$CURRENT_DIST" ] && is_prefetch_kernel "$CURRENT_KERNEL"; then
            local out_base="${ROOT_DIR}/workloads/output/$(uname -r)"
            local plain_log="${out_base}/regress_${CURRENT_BENCHMARK}_${CURRENT_RATIO//:/_}.log"
            local adapt_suffix=""
            [ "$CURRENT_ADAPTIVE" == "1" ] && adapt_suffix="_adapt"
            [ "$CURRENT_ADAPTIVE" == "0" ] && adapt_suffix="_static"
            adapt_suffix+="_${CURRENT_THP}"

            local dist_suffix=""
            if [ "${PREFETCH_DISTANCE:-0}" == "0" ] && [ "${PREFETCH_DEMOTE_DISTANCE:-0}" == "0" ]; then
                dist_suffix="_0"
            elif [ -n "${PREFETCH_PROMOTE_DISTANCE:-}" ] && [ -n "${PREFETCH_DEMOTE_DISTANCE:-}" ] && [ "${PREFETCH_PROMOTE_DISTANCE}" != "${PREFETCH_DEMOTE_DISTANCE}" ]; then
                dist_suffix="_p${PREFETCH_PROMOTE_DISTANCE}_d${PREFETCH_DEMOTE_DISTANCE}${adapt_suffix}"
            else
                dist_suffix="_${PREFETCH_DISTANCE}${adapt_suffix}"
            fi
            local dist_log="${out_base}/regress_${CURRENT_BENCHMARK}_${CURRENT_RATIO//:/_}${dist_suffix}.log"
            [ -f "$plain_log" ] && [ ! -f "$dist_log" ] && mv "$plain_log" "$dist_log"
        fi

        log "${GREEN}Completed benchmark: ${CURRENT_BENCHMARK} (Ratio: ${CURRENT_RATIO}${dist_tag}).${NC}"

        # Advance to next item
        CURRENT_INDEX=$((CURRENT_INDEX + 1))
        echo "CURRENT_INDEX=${CURRENT_INDEX}" > "$STATE_FILE"
        echo "STARTED_TIME=${STARTED_TIME:-$(date +%s)}" >> "$STATE_FILE"
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

    if [ -f "$STATE_FILE" ]; then
        # shellcheck source=/dev/null
        source "$STATE_FILE"
        if [ "${CURRENT_INDEX:-0}" -gt 0 ] && [ "${CURRENT_INDEX:-0}" -lt "$total" ]; then
            echo -e "${YELLOW}[!] Existing regression state found at Step $((CURRENT_INDEX + 1))/${total}.${NC}"
            echo -e "${YELLOW}[!] Resuming from current step. (To restart from Step 1, run 'sudo $0 reset' first).${NC}"
            install_service
            execute_step
            return 0
        fi
    fi

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
# Action: Check Status
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

show_dry_run() {
    load_targets
    print_regression_config
    echo -e "\n Planned Execution Steps (${#TARGET_ITEMS[@]} total):"
    local idx=1
    for item in "${TARGET_ITEMS[@]}"; do
        local k b r d a bound thp mode_tag=""
        IFS='|' read -r k b r d a bound thp <<< "$item"
        if is_prefetch_kernel "$k"; then
            [ "$a" == "1" ] && mode_tag=" Mode=Adaptive"
            [ "$a" == "0" ] && mode_tag=" Mode=Static"
            [ -n "$d" ] && mode_tag+=", Dist=${d}"
            [ -n "$bound" ] && mode_tag+=", Bounds=${bound}"
        fi
        echo "  [$idx] Kernel=${k}, Bench=${b}, Ratio=${r}${mode_tag:+,${mode_tag}}${thp:+, THP=${thp}}"
        idx=$((idx + 1))
    done
}

# ------------------------------------------------------------------------------
# Action: Stop / Abort
# ------------------------------------------------------------------------------
abort_regression() {
    log "${YELLOW}Aborting automated regression and cleaning up...${NC}"
    ensure_cpus_online
    remove_service
    rm -f "$STATE_FILE"
    log "${GREEN}Automated regression stopped.${NC}"
}

# ------------------------------------------------------------------------------
# CLI Router
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
        --step|step)
            execute_step
            ;;
        status|check)
            show_status
            ;;
        dry-run|plan|list)
            show_dry_run
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
