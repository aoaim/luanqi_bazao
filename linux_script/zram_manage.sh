#!/bin/bash

# ZRAM swap management script for Debian 13+
# Commands: status | install | reconfigure | remove | auto | (no args = interactive menu)
# Update: 07/24/2026

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

ICON_OK="[OK]"
ICON_WARN="[WARN]"
ICON_ERR="[ERR]"
ICON_INFO="[INFO]"

print_ok()    { echo -e "${GREEN}${ICON_OK} $1${RESET}"; }
print_warn()  { echo -e "${YELLOW}${ICON_WARN} $1${RESET}"; }
print_err()   { echo -e "${RED}${ICON_ERR} $1${RESET}"; }
print_info()  { echo -e "${CYAN}${ICON_INFO} $1${RESET}"; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_err "Root privileges required. Run with sudo."
        exit 1
    fi
}

require_debian() {
    if [ ! -f /etc/os-release ]; then
        print_err "Cannot read /etc/os-release. Aborting."
        exit 1
    fi
    . /etc/os-release
    if [ "${ID:-}" != "debian" ]; then
        print_err "Debian only. Detected: ${PRETTY_NAME:-unknown}"
        exit 1
    fi
    local debian_version
    debian_version=$(cut -d. -f1 /etc/debian_version)
    if [[ ! "$debian_version" =~ ^[0-9]+$ ]]; then
        # testing/sid → "trixie/sid" 等，视为最新，放行
        print_info "Non-numeric debian_version ('$debian_version'), assuming sid/testing."
    elif [ "$debian_version" -lt 13 ]; then
        print_err "Supported versions: Debian 13+. Current: $debian_version"
        exit 1
    fi
}

cmd_ok() { command -v "$1" >/dev/null 2>&1; }

# ---- status ----
show_status() {
    echo ""
    echo -e "${BOLD}${CYAN}▶ ZRAM Status${RESET}"
    echo ""

    local zram_swap_size=0 zram_swap_prio="?"
    if grep -q "^/dev/zram" /proc/swaps 2>/dev/null; then
        zram_swap_size=$(awk '$1 ~ /zram/ {s+=$3} END {print s+0}' /proc/swaps)
        zram_swap_prio=$(awk '$1 ~ /zram/ {print $5; exit}' /proc/swaps)
    fi

    if [ "$zram_swap_size" -gt 0 ]; then
        local size_mb algo
        size_mb=$(awk -v s="$zram_swap_size" 'BEGIN {printf "%.1f", s/1024}')
        algo=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | grep -oP '\[.*?\]' | tr -d '[]' || echo "?")
        echo -e "  Status     : ${GREEN}Active${RESET}"
        echo -e "  Size       : ${size_mb} MB"
        echo -e "  Algorithm  : ${algo}"
        echo -e "  Priority   : ${zram_swap_prio}"
        echo -e "  Device     : /dev/zram0"
        echo ""
        echo -e "  Current zram swap usage:"
        swapon --show 2>/dev/null | grep zram || echo "  (none)"
    else
        echo -e "  Status : ${YELLOW}Not active${RESET}"
    fi

    # Show zram-tools package status
    if dpkg -l zram-tools 2>/dev/null | grep -q "^ii"; then
        echo -e "  Package : zram-tools ${GREEN}installed${RESET}"
        if [ -f /etc/default/zramswap ]; then
            echo ""
            echo "  /etc/default/zramswap:"
            grep -v '^#' /etc/default/zramswap 2>/dev/null | grep -v '^$' | sed 's/^/    /' || true
        fi
    else
        echo -e "  Package : zram-tools ${YELLOW}not installed${RESET}"
    fi

    echo ""
}

# ---- helpers ----

_auto_size() {
    local mem_mb
    mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    local s=$((mem_mb / 4))
    [ "$s" -lt 256 ] && s=256
    [ "$s" -gt 4096 ] && s=4096
    echo "$s"
}

# 从 /etc/default/zramswap 读取当前配置：$1=变量名(ALGO|SIZE)，echo 值（无则空）
_current_config() {
    local key="$1"
    [ -f /etc/default/zramswap ] || return 0
    awk -v k="$key" -F= '
        $1 == k { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }
    ' /etc/default/zramswap 2>/dev/null
}

_validate_algo() {
    # $1 = desired algo, echoes best available algo (may differ from input)
    local algo="${1:-lz4}"

    if ! modprobe zram 2>/dev/null; then
        print_err "zram kernel module not available" >&2
        return 1
    fi

    local available
    available=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "")
    if [ -n "$available" ] && ! echo "$available" | grep -qF "$algo"; then
        print_warn "$algo not supported by kernel. Available: $available" >&2
        if echo "$available" | grep -qF "lz4"; then
            algo="lz4"
        elif echo "$available" | grep -qF "lzo"; then
            algo="lzo"
        else
            algo=$(echo "$available" | grep -oP '\[.*?\]' | tr -d '[]' || echo "lzo")
        fi
        print_info "Falling back to: $algo" >&2
    fi

    # 不在此处 rmmod：reconfigure 时 zram 正作为 swap 使用，rmmod 必失败。
    # 模块清理交给 _apply_zram_config / remove_zram 处理。
    echo "$algo"
}

_apply_zram_config() {
    # $1 = size in MB, $2 = algo. Stops existing zram, writes config, starts.
    local size_mb="$1"
    local algo="$2"
    local expected_kb=$((size_mb * 1024))

    # Install zram-tools if missing
    if ! dpkg -l zram-tools 2>/dev/null | grep -q "^ii"; then
        print_info "Installing zram-tools..."
        apt-get update -qq >/dev/null 2>&1 || true
        if ! apt-get install -y -qq zram-tools; then
            print_err "Failed to install zram-tools"
            return 1
        fi
    fi

    # Stop & destroy existing zram
    systemctl stop zramswap.service 2>/dev/null || true
    swapoff /dev/zram0 2>/dev/null || true
    if lsmod 2>/dev/null | grep -q "^zram "; then
        rmmod zram 2>/dev/null || true
    fi

    # Write config
    cat > /etc/default/zramswap <<EOF
# zramswap config
ALGO=${algo}
SIZE=${size_mb}
PRIORITY=100
EOF
    print_info "Config written: ALGO=${algo} SIZE=${size_mb}MB"

    # Start
    modprobe zram 2>/dev/null || true
    systemctl enable zramswap.service 2>/dev/null || true
    systemctl start zramswap.service 2>/dev/null || true

    # Wait for initialization (up to 5s)
    local retries=5
    while [ $retries -gt 0 ]; do
        local current_kb
        current_kb=$(awk '$1 ~ /zram/ {print $3; exit}' /proc/swaps 2>/dev/null || echo 0)
        if [ "${current_kb:-0}" -gt $((expected_kb * 9 / 10)) ]; then
            break
        fi
        sleep 1
        retries=$((retries - 1))
    done

    # Set swappiness high for zram (compressed-in-RAM swap benefits from aggressive use)
    cat > /etc/sysctl.d/99-zram-swappiness.conf <<EOF
# ZRAM swap: compressed in RAM, set high swappiness to actively use it
vm.swappiness = 100
EOF
    sysctl --system >/dev/null 2>&1 || true
    print_info "swappiness set to 100 (zram-optimized)"

    if grep -q "^/dev/zram" /proc/swaps 2>/dev/null; then
        # 核对实际 size/algo，避免 swapoff 失败导致旧配置仍在跑却报假成功
        local actual_kb actual_algo
        actual_kb=$(awk '$1 ~ /zram/ {print $3; exit}' /proc/swaps 2>/dev/null || echo 0)
        actual_algo=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | grep -oP '\[.*?\]' | tr -d '[]' || echo "?")
        local actual_mb=$((actual_kb / 1024))
        if [ "$actual_mb" -eq "$size_mb" ] && [ "$actual_algo" = "$algo" ]; then
            print_ok "ZRAM swap enabled: ${size_mb}MB (${algo})"
        else
            print_err "ZRAM active but mismatch: got ${actual_mb}MB/${actual_algo}, expected ${size_mb}MB/${algo}"
            print_err "swapoff may have failed (memory in use). Check: journalctl -u zramswap"
            return 1
        fi
    else
        print_err "ZRAM swap failed to start. Check: journalctl -u zramswap"
        return 1
    fi
}

# ---- install ----
install_zram() {
    echo ""
    echo -e "${BOLD}${CYAN}▶ Installing ZRAM Swap${RESET}"
    echo ""

    if grep -q "^/dev/zram" /proc/swaps 2>/dev/null; then
        print_warn "ZRAM swap is already active. Use 'reconfigure' to change, or 'status' to view."
        return 0
    fi

    local size_mb="${1:-}"
    local algo
    algo=$(_validate_algo "${2:-lz4}") || return 1

    if [ -z "$size_mb" ]; then
        size_mb=$(_auto_size)
        print_info "Auto zram size: ${size_mb} MB (25% of RAM)"
    fi

    _apply_zram_config "$size_mb" "$algo"
    echo ""
}

# ---- reconfigure ----
reconfigure_zram() {
    echo ""
    echo -e "${BOLD}${CYAN}▶ Reconfiguring ZRAM Swap${RESET}"
    echo ""

    if ! grep -q "^/dev/zram" /proc/swaps 2>/dev/null; then
        print_warn "ZRAM swap is not active. Use 'install' instead."
        return 0
    fi

    local size_mb="${1:-}"
    local algo
    algo=$(_validate_algo "${2:-lz4}") || return 1

    if [ -z "$size_mb" ]; then
        size_mb=$(_auto_size)
        print_info "Auto zram size: ${size_mb} MB (25% of RAM)"
    fi

    _apply_zram_config "$size_mb" "$algo"
    echo ""
}

# ---- remove ----
remove_zram() {
    echo ""
    echo -e "${BOLD}${CYAN}▶ Removing ZRAM Swap${RESET}"
    echo ""

    if ! grep -q "^/dev/zram" /proc/swaps 2>/dev/null; then
        print_info "ZRAM swap is not active."
    else
        print_info "Turning off zram swap..."
        local swapoff_ret=0
        systemctl stop zramswap.service 2>/dev/null || true
        swapoff /dev/zram0 2>/dev/null || swapoff_ret=$?
        if [ "$swapoff_ret" -eq 0 ]; then
            print_ok "zram swapoff succeeded"
        else
            print_warn "swapoff returned non-zero (may be normal if no pages in use)"
        fi
        if lsmod 2>/dev/null | grep -q "^zram "; then
            rmmod zram 2>/dev/null || true
        fi
    fi

    # Disable and remove package
    systemctl disable zramswap.service 2>/dev/null || true
    if dpkg -l zram-tools 2>/dev/null | grep -q "^ii"; then
        print_info "Removing zram-tools package..."
        apt-get remove -y -qq --purge zram-tools 2>/dev/null || true
    fi
    rm -f /etc/default/zramswap
    if [ -f /etc/sysctl.d/99-zram-swappiness.conf ]; then
        rm -f /etc/sysctl.d/99-zram-swappiness.conf
        sysctl --system >/dev/null 2>&1 || true
        print_info "zram swappiness config removed (vm.swappiness restored to kernel default 60)"
    fi

    print_ok "ZRAM removed"
    echo ""
}

# ---- auto ----
auto_zram() {
    echo ""
    echo -e "${BOLD}${CYAN}▶ Auto-configuring ZRAM Swap${RESET}"
    echo ""

    local mem_mb size_mb algo
    mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)

    # Algorithm: 优先 zstd，由 _validate_algo 在内核不支持时自动 fallback
    algo="zstd"

    # Size: <800MB → 512MB; 800MB-2GB → 1024MB; ≥2GB → 1536MB
    if [ "$mem_mb" -lt 800 ]; then
        size_mb=512
        print_info "< 800MB RAM → zram ${size_mb}MB (${algo})"
    elif [ "$mem_mb" -lt 2048 ]; then
        size_mb=1024
        print_info "800MB-2GB RAM → zram ${size_mb}MB (${algo})"
    else
        size_mb=1536
        print_info "≥ 2GB RAM → zram ${size_mb}MB (${algo})"
    fi

    if grep -q "^/dev/zram" /proc/swaps 2>/dev/null; then
        reconfigure_zram "$size_mb" "$algo"
    else
        install_zram "$size_mb" "$algo"
    fi
}

# ---- usage ----
show_usage() {
    echo ""
    echo "Usage: $0 <command> [args...]"
    echo ""
    echo "Commands:"
    echo "  status (s)             Show ZRAM swap status"
    echo "  install (i) [MB] [ALG] Install ZRAM swap (default: 25% of RAM, lz4)"
    echo "  reconfigure (rc) [MB] [ALG] Change size/algorithm of running ZRAM swap"
    echo "                     ALG: lz4, zstd, lzo"
    echo "  remove (r)             Remove ZRAM swap and zram-tools package"
    echo "  auto (a)               Auto-detect best config and install"
    echo ""
    echo "Examples:"
    echo "  $0 status"
    echo "  $0 install 2048 zstd"
    echo "  $0 reconfigure 4096 lz4"
    echo "  $0 auto"
}

# ---- interactive ----
interactive_menu() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${CYAN}▶ ZRAM Management${RESET}"
        echo ""

        # Quick status line
        if grep -q "^/dev/zram" /proc/swaps 2>/dev/null; then
            local s a
            s=$(awk '$1 ~ /zram/ {s+=$3} END {print s+0}' /proc/swaps)
            s=$(awk -v s="$s" 'BEGIN {printf "%.0f", s/1024}')
            a=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | grep -oP '\[.*?\]' | tr -d '[]' || echo "?")
            echo -e "  ${GREEN}Active${RESET}  |  ${s} MB  |  ${a}"
        else
            echo -e "  ${YELLOW}Not active${RESET}"
        fi
        echo ""

        echo "  1) Status"
        echo "  2) Install"
        echo "  3) Reconfigure (change size / algorithm)"
        echo "  4) Remove"
        echo "  5) Auto (smart defaults)"
        echo "  0) Exit"
        echo ""

        printf "  Choice: "
        read -r choice || choice=""
        echo ""

        case "$choice" in
            1) show_status
               ;;
            2)
               if grep -q "^/dev/zram" /proc/swaps 2>/dev/null; then
                   print_warn "Already active — use 3) Reconfigure, or 4) Remove first."
               else
                   echo ""
                   printf "  Size in MB [Enter = auto = 25%% RAM]: "
                   read -r size || size=""
                   printf "  Algorithm (lz4/zstd/lzo) [Enter = lz4]: "
                   read -r algo || algo=""
                   install_zram "${size:-}" "${algo:-}"
               fi
               ;;
            3)
               if ! grep -q "^/dev/zram" /proc/swaps 2>/dev/null; then
                   print_warn "Not active — use 2) Install first."
               else
                   local cur_size cur_algo
                   cur_size=$(_current_config SIZE)
                   cur_algo=$(_current_config ALGO)
                   echo ""
                   printf "  New size in MB [Enter = keep current = %s]: " "${cur_size:-?}"
                   read -r size || size=""
                   printf "  New algorithm (lz4/zstd/lzo) [Enter = keep current = %s]: " "${cur_algo:-?}"
                   read -r algo || algo=""
                   reconfigure_zram "${size:-$cur_size}" "${algo:-$cur_algo}"
               fi
               ;;
            4) remove_zram ;;
            5) auto_zram ;;
            0) echo -e "  ${GREEN}Bye.${RESET}"; echo ""; break ;;
            *) echo -e "  ${YELLOW}Invalid choice${RESET}" ;;
        esac

        if [ "$choice" != "0" ]; then
            echo ""
            printf "  Press Enter to continue..."
            read -r _ || true
        fi
    done
}

# ---- main ----
require_root
require_debian

if [ $# -eq 0 ]; then
    interactive_menu
    exit 0
fi

case "${1:-}" in
    status|s)       show_status ;;
    install|i)      install_zram "${2:-}" "${3:-}" ;;
    reconfigure|rc) reconfigure_zram "${2:-}" "${3:-}" ;;
    remove|r|uninstall) remove_zram ;;
    auto|a)         auto_zram ;;
    -h|--help|help) show_usage ;;
    *)              show_usage; exit 1 ;;
esac
