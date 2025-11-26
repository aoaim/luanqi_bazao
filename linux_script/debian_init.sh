#!/bin/bash

# Debian 12/13 amd64 initialization (single flow, no modes)
# - Performs environment detection, optional installs, timezone confirmation, and kernel tuning per memory size
# - Backs up configs to /root/init_linux_backups where applicable

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

MARKER_FILE="/var/lib/init_linux_run.marker"
BACKUP_DIR="/root/init_linux_backups"
SYSCTL_FILE="/etc/sysctl.d/999-bbr-optimize.conf"
MODE_LITE=0
GITHUB_ALLOWED=1
MEM_TIER_LABEL="unknown"
MEM_TIER_COLOR=""
SYSCTL_MODE="compatible"
ENABLE_FORWARDING=0
DOCKER_STATUS="unknown"
APT_INSTALL_OPTS="-y -qq -o=Dpkg::Use-Pty=0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Icons
ICON_INFO="ℹ️ "
ICON_WARN="⚠️ "
ICON_ERR="❌ "
ICON_OK="✓ "
ICON_PKG="📦 "
ICON_GEAR="⚙️ "
ICON_TIME="🕐 "
ICON_SEARCH="🔍 "
ICON_DOC="📜 "
ICON_TOOL="🧰 "

clear
echo ""
echo -e "${BLUE}"
cat << 'EOF'
 ____       _     _              ___       _ _   
|  _ \  ___| |__ (_) __ _ _ __  |_ _|_ __ (_) |_ 
| | | |/ _ \ '_ \| |/ _` | '_ \  | || '_ \| | __|
| |_| |  __/ |_) | | (_| | | | | | || | | | | |_ 
|____/ \___|_.__/|_|\__,_|_| |_|___|_| |_|_|\__|
EOF
echo -e "${RESET}"

print_banner() {
    echo ""
    echo -e "${BLUE}╭──────────────────────────────────────────────────────────────────────────────╮${RESET}"
    echo -e "${BLUE}│${RESET} ${BOLD}$1${RESET}"
    echo -e "${BLUE}╰──────────────────────────────────────────────────────────────────────────────╯${RESET}"
}

print_success() { echo -e "${GREEN}${ICON_OK} $1${RESET}"; }
print_warning() { echo -e "${YELLOW}${ICON_WARN} $1${RESET}"; }
print_error()   { echo -e "${RED}${ICON_ERR} $1${RESET}"; }
print_info()    { echo -e "${CYAN}${ICON_INFO} $1${RESET}"; }

print_kv() {
    local key="$1"
    local val="$2"
    printf "${DIM}%-22s${RESET} : %b\n" "$key" "$val"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "Root privileges required. Please run with sudo."
        exit 1
    fi
}

check_marker() {
    if [ -f "$MARKER_FILE" ]; then
        MODE_LITE=1
        print_warning "Marker detected ($MARKER_FILE)."
        print_warning "Skipping system update/timezone/sysctl."
        print_warning "Only checking developer tools (Eza/Helix/Speedtest) and optional Docker."
    fi
}

require_debian() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "${ID:-}" != "debian" ]; then
            print_error "Debian only. Detected: ${PRETTY_NAME:-unknown}"
            exit 1
        fi
        DEBIAN_VERSION=$(cut -d. -f1 /etc/debian_version)
        if [ "$DEBIAN_VERSION" != "12" ] && [ "$DEBIAN_VERSION" != "13" ]; then
            print_error "Supported versions: Debian 12/13. Current: $DEBIAN_VERSION"
            exit 1
        fi
        ARCH=$(uname -m)
        if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "amd64" ]; then
            print_error "amd64 only. Current: $ARCH"
            exit 1
        fi
        DISTRO_CODENAME="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo trixie)}"
    else
        print_error "Cannot read /etc/os-release. Aborting."
        exit 1
    fi
}

backup_file() {
    local file="$1"
    [ -f "$file" ] || return 0
    mkdir -p "$BACKUP_DIR"
    cp "$file" "${BACKUP_DIR}/$(basename "$file").$(date +%Y%m%d_%H%M%S).bak"
}

ensure_basic_tools() {
    print_banner "${ICON_PKG} Preparing prerequisites"
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install $APT_INSTALL_OPTS curl wget >/dev/null 2>&1 || true
    if ! command -v curl >/dev/null || ! command -v wget >/dev/null; then
        print_error "Failed to install curl or wget. Please check network or mirrors."
        exit 1
    fi
    print_success "Base utilities ready (curl, wget)"
}

fetch_ipinfo() {
    local raw
    raw=$(curl -s --max-time 5 ipinfo.io 2>/dev/null || true)
    IP_CITY=$(echo "$raw" | grep -oP '"city":\s*"\K[^"]+' || true)
    IP_REGION=$(echo "$raw" | grep -oP '"region":\s*"\K[^"]+' || true)
    IP_COUNTRY=$(echo "$raw" | grep -oP '"country":\s*"\K[^"]+' || true)
    IP_ORG=$(echo "$raw" | grep -oP '"org":\s*"\K[^"]+' || true)
    IP_TZ=$(echo "$raw" | grep -oP '"timezone":\s*"\K[^"]+' || true)
    IPV4_ADDR=$(curl -s --max-time 5 -4 ip.sb 2>/dev/null || echo "N/A")
    IPV6_ADDR=$(curl -s --max-time 5 -6 ip.sb 2>/dev/null || echo "N/A")

    # IPv6-only fallback: use ifconfig.co/json to populate IP and region fields
    if { [ -z "${IPV4_ADDR:-}" ] || [ "${IPV4_ADDR}" = "N/A" ]; } && [ "${IPV6_ADDR:-N/A}" != "N/A" ]; then
        local raw6
        raw6=$(curl -s --max-time 8 -6 ifconfig.co/json 2>/dev/null || true)
        if [ -n "$raw6" ]; then
            IPV6_ADDR=$(echo "$raw6" | grep -oP '"ip":\s*"\K[^"]+' || echo "$IPV6_ADDR")
            IP_CITY=$(echo "$raw6" | grep -oP '"city":\s*"\K[^"]+' || echo "${IP_CITY:-}")
            IP_REGION=$(echo "$raw6" | grep -oP '"region":\s*"\K[^"]+' || echo "${IP_REGION:-}")
            IP_COUNTRY=$(echo "$raw6" | grep -oP '"country_iso":\s*"\K[^"]+' || echo "${IP_COUNTRY:-}")
            if [ -z "$IP_COUNTRY" ]; then
                IP_COUNTRY=$(echo "$raw6" | grep -oP '"country":\s*"\K[^"]+' || echo "")
            fi
            IP_ORG=$(echo "$raw6" | grep -oP '"asn_org":\s*"\K[^"]+' || echo "${IP_ORG:-}")
            IP_TZ=$(echo "$raw6" | grep -oP '"time_zone":\s*"\K[^"]+' || echo "${IP_TZ:-}")
            if [ -z "$IP_TZ" ]; then
                IP_TZ=$(echo "$raw6" | grep -oP '"timezone":\s*"\K[^"]+' || echo "")
            fi
        fi
    fi

    # If no IPv4 is available, disable GitHub downloads to avoid failures on IPv6-only hosts.
    if [ -z "${IPV4_ADDR:-}" ] || [ "${IPV4_ADDR}" = "N/A" ]; then
        GITHUB_ALLOWED=0
    fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

get_eza_version() {
    local out ver
    out=$(eza --version 2>/dev/null | head -n2)
    ver=$(echo "$out" | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n1)
    echo "${ver:-unknown}"
}

get_speedtest_version() {
    local out ver
    out=$(speedtest --version 2>/dev/null | head -n1)
    ver=$(echo "$out" | grep -oP '([0-9]+\.)+[0-9]+' | head -n1)
    echo "${ver:-unknown}"
}

detect_versions() {
    EZA_VER="Not installed"
    HELIX_VER="Not installed"
    SPEEDTEST_VER="Not installed"
    AUTO_UPDATES="Not installed"

    if command_exists eza; then EZA_VER=$(get_eza_version); fi
    if command_exists hx; then HELIX_VER=$(hx --version 2>/dev/null | head -n1 || echo "installed"); fi
    if command_exists speedtest; then SPEEDTEST_VER=$(get_speedtest_version); fi
    if command_exists unattended-upgrade; then AUTO_UPDATES="installed"; fi
}

detect_updates_hint() {
    EZA_UPDATE=""
    HELIX_UPDATE=""
    SPEEDTEST_UPDATE=""

    if command_exists eza; then
        latest=$(curl -s --max-time 10 https://api.github.com/repos/eza-community/eza/releases/latest 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/' || true)
        current=$(get_eza_version)
        latest_clean=$(echo "${latest#v}" | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n1)
        if [ -n "$latest_clean" ] && [ -n "$current" ] && [ "$latest_clean" != "$current" ]; then
            EZA_UPDATE="$current → $latest_clean"
        fi
    fi

    if command_exists hx; then
        latest=$(curl -s --max-time 10 https://api.github.com/repos/helix-editor/helix/releases/latest 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"tag_name": "v?([^"]+)".*/\1/' || true)
        current=$(hx --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1 || echo "")
        [ -n "$latest" ] && [ -n "$current" ] && [ "$latest" != "$current" ] && HELIX_UPDATE="$current → $latest"
    fi

    if command_exists speedtest; then
        latest=$(curl -sL "https://packagecloud.io/ookla/speedtest-cli/debian/dists/${DISTRO_CODENAME}/main/binary-amd64/Packages" 2>/dev/null | grep -A10 "Package: speedtest" | grep "^Version:" | head -n1 | awk '{print $2}' || true)
        current=$(get_speedtest_version)
        latest_num=$(echo "$latest" | cut -d- -f1)
        current_num=$(echo "$current" | cut -d- -f1)
        if [ -n "$latest_num" ] && [ -n "$current_num" ] && [ "$latest_num" != "$current_num" ]; then
            SPEEDTEST_UPDATE="$current_num → $latest"
        fi
    fi
}

detect_unattended() {
    UNATTENDED_STATUS="Not installed"
    UNATTENDED_SOURCES="N/A"
    UNATTENDED_TIMER="inactive"
    local codename_regex
    codename_regex="(${DISTRO_CODENAME}|\\\${distro_codename})"
    if command_exists unattended-upgrade; then
        UNATTENDED_STATUS="Installed"
        cfg=""
        if [ -f /etc/apt/apt.conf.d/52unattended-upgrades-local ]; then
            cfg="/etc/apt/apt.conf.d/52unattended-upgrades-local"
        elif [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
            cfg="/etc/apt/apt.conf.d/50unattended-upgrades"
        fi
        if [ -n "$cfg" ]; then
            sec=$(grep -qE "^\s*\"origin=Debian,codename=${codename_regex}-security" "$cfg" 2>/dev/null && echo "Security" || echo "")
            upd=$(grep -qE "^\s*\"origin=Debian,codename=${codename_regex}-updates" "$cfg" 2>/dev/null && echo "Stable-updates" || echo "")
            tmp="${sec}${sec:+ }${upd}"
            UNATTENDED_SOURCES=${tmp:-unknown}
        fi
        UNATTENDED_TIMER=$(systemctl is-active apt-daily-upgrade.timer 2>/dev/null || echo "inactive")
    fi
}

set_memory_tier_label() {
    MEM_TIER_LABEL="unknown"
    MEM_TIER_COLOR="$RESET"
    if (( MEM_KB < 491520 )); then
        MEM_TIER_LABEL="low"
        MEM_TIER_COLOR="$RED"
    elif (( MEM_KB < 921600 )); then
        MEM_TIER_LABEL="small"
        MEM_TIER_COLOR="$YELLOW"
    elif (( MEM_KB < 1945600 )); then
        MEM_TIER_LABEL="medium"
        MEM_TIER_COLOR="$YELLOW"
    else
        MEM_TIER_LABEL="large"
        MEM_TIER_COLOR="$GREEN"
    fi
}

detect_system() {
    MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    SWAP_KB=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
    DISK_ROOT=$(df -h / | awk 'NR==2{print $3 " / " $2 " (" $5 " used)"}')
    BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    QDISC_STATUS=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    SWAP_STR="Not enabled"
    if [ "${SWAP_KB:-0}" -gt 0 ]; then
        SWAP_STR="$(awk '/SwapTotal/ {printf "%.1f MB", $2/1024}' /proc/meminfo)"
    fi
    set_memory_tier_label
}

detect_docker_status() {
    if command_exists docker; then
        DOCKER_STATUS=$(docker --version 2>/dev/null | head -n1 || echo "installed")
    else
        DOCKER_STATUS="not installed"
    fi
}

detect_zram_status() {
    ZRAM_STATUS="not active"
    if grep -q "^/dev/zram" /proc/swaps 2>/dev/null; then
        local size_kb prio
        size_kb=$(awk '$1 ~ /zram/ {s+=$3} END {print s+0}' /proc/swaps)
        prio=$(awk '$1 ~ /zram/ {print $4; exit}' /proc/swaps)
        if [ "${size_kb:-0}" -gt 0 ]; then
            ZRAM_STATUS=$(awk -v s="$size_kb" -v p="$prio" 'BEGIN {printf "active (%.1f MB, prio %s)", s/1024, p}')
        else
            ZRAM_STATUS="active (size unknown, prio ${prio:-?})"
        fi
    fi
}

show_detection() {
    print_banner "${ICON_SEARCH} Environment check"
    print_kv "IPv4" "${IPV4_ADDR:-N/A}"
    [ "${IPV6_ADDR:-N/A}" != "N/A" ] && print_kv "IPv6" "$IPV6_ADDR"
    print_kv "Location" "${IP_CITY:-?}, ${IP_REGION:-?}, ${IP_COUNTRY:-?} (${IP_ORG:-?})"
    print_kv "Suggested TZ" "${IP_TZ:-Unknown}"
    print_kv "CPU" "$(lscpu 2>/dev/null | grep 'Model name' | cut -d: -f2- | xargs || echo '?')"
    print_kv "Memory" "$(echo "$MEM_KB" | awk '{printf "%.1f MB", $1/1024}') (${MEM_TIER_COLOR}${MEM_TIER_LABEL}${RESET})"
    print_kv "Swap" "$SWAP_STR"
    print_kv "zram swap" "${ZRAM_STATUS:-not detected}"
    print_kv "Disk (/)" "$DISK_ROOT"
    print_kv "BBR / qdisc" "$BBR_STATUS / $QDISC_STATUS"
    print_kv "Eza" "$EZA_VER"
    print_kv "Helix" "$HELIX_VER"
    print_kv "Speedtest" "$SPEEDTEST_VER"
    print_kv "Docker" "$DOCKER_STATUS"
    print_kv "unattended-upgrades" "$UNATTENDED_STATUS (sources: $UNATTENDED_SOURCES, timer: $UNATTENDED_TIMER)"
    
    if [ -n "$EZA_UPDATE$HELIX_UPDATE$SPEEDTEST_UPDATE" ]; then
        echo ""
        print_warning "Updates available:"
        [ -n "$EZA_UPDATE" ] && echo -e "  ${YELLOW}•${RESET} Eza $EZA_UPDATE"
        [ -n "$HELIX_UPDATE" ] && echo -e "  ${YELLOW}•${RESET} Helix $HELIX_UPDATE"
        [ -n "$SPEEDTEST_UPDATE" ] && echo -e "  ${YELLOW}•${RESET} Speedtest $SPEEDTEST_UPDATE"
    fi
}

confirm_proceed() {
    echo ""
    print_banner "${ICON_DOC} Planned actions"
    if [ "$MODE_LITE" -eq 1 ]; then
        echo -e " ${BLUE}1)${RESET} Check/install Eza, Helix, Speedtest"
        echo -e " ${BLUE}2)${RESET} Docker: install/update prompt"
        echo -e " ${BLUE}3)${RESET} If RAM <=2GB and no zram swap: offer zram"
        echo -e "\n ${YELLOW}Marker detected: skipping update/timezone/sysctl/base packages.${RESET}"
    else
        echo -e " ${BLUE}1)${RESET} Update/upgrade/autoremove"
        echo -e " ${BLUE}2)${RESET} Tools + unattended-upgrades"
        echo -e " ${BLUE}3)${RESET} Docker: install/update prompt"
        echo -e " ${BLUE}4)${RESET} Base packages: openssl gnupg curl wget nano htop cron chrony fail2ban unzip logrotate vnstat nload"
        echo -e " ${BLUE}5)${RESET} Time sync/timezone; if RAM <=2GB offer zram"
        echo -e " ${BLUE}6)${RESET} Sysctl mode (compat or performance) tuned by memory tier"
    fi
    echo ""
    echo -ne "${BOLD}Proceed? [Y/n]: ${RESET}"
    read -r ans
    ans=${ans:-y}
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        print_warning "Cancelled by user."
        exit 0
    fi
}

apt_refresh() {
    print_banner "${ICON_PKG} System update"
    apt-get update -qq
    apt-get upgrade $APT_INSTALL_OPTS
    apt-get autoremove $APT_INSTALL_OPTS
    print_success "System update completed"
}

install_unattended() {
    print_info "Installing unattended-upgrades..."
    apt-get install $APT_INSTALL_OPTS unattended-upgrades
    echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections
    dpkg-reconfigure -f noninteractive unattended-upgrades
}

install_speedtest() {
    if command_exists speedtest; then
        print_info "Speedtest already installed, skipping."
        return
    fi
    print_info "Installing Speedtest..."
    distro_codename="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo trixie)}"
    pkg_path=$(curl -sL "https://packagecloud.io/ookla/speedtest-cli/debian/dists/${distro_codename}/main/binary-amd64/Packages" 2>/dev/null | grep -A10 "Package: speedtest" | grep "^Filename:" | head -n1 | awk '{print $2}' || true)
    if [ -z "$pkg_path" ]; then print_error "Unable to get Speedtest package path"; return; fi
    url="https://packagecloud.io/ookla/speedtest-cli/debian/${pkg_path}"
    wget -q "$url" -O /tmp/speedtest.deb
    if [ -s /tmp/speedtest.deb ]; then
        dpkg -i /tmp/speedtest.deb || apt-get install -f $APT_INSTALL_OPTS
        rm -f /tmp/speedtest.deb
        print_success "Speedtest installed"
    else
        print_error "Failed to download Speedtest"
    fi
}

install_helix() {
    if [ "$GITHUB_ALLOWED" -eq 0 ]; then
        print_warning "IPv6-only detected: skipping Helix (GitHub download required)."
        return
    fi
    if command_exists hx; then
        print_info "Helix already installed, skipping."
        return
    fi
    print_info "Installing Helix..."
    url=$(curl -s --max-time 10 https://api.github.com/repos/helix-editor/helix/releases/latest 2>/dev/null | grep -m1 '"browser_download_url".*amd64\.deb"' | cut -d'"' -f4 || true)
    if [ -z "$url" ]; then print_error "Failed to fetch Helix release"; return; fi
    wget -q "$url" -O /tmp/helix.deb
    if dpkg -i /tmp/helix.deb 2>/dev/null; then
        apt-get install -f $APT_INSTALL_OPTS
        cat > /etc/profile.d/helix-alias.sh <<'EOF'
alias vi='hx'
alias vim='hx'
EOF
        chmod 644 /etc/profile.d/helix-alias.sh
        print_success "Helix installed and aliased to vi/vim"
    else
        print_error "Helix installation failed"
    fi
    rm -f /tmp/helix.deb
}

install_eza() {
    if [ "$GITHUB_ALLOWED" -eq 0 ]; then
        print_warning "IPv6-only detected: skipping Eza (GitHub download required)."
        return
    fi
    if command_exists eza; then
        print_info "Eza already installed, skipping."
        return
    fi
    print_info "Installing Eza..."
    url=$(curl -s --max-time 10 https://api.github.com/repos/eza-community/eza/releases/latest 2>/dev/null | grep -m1 '"browser_download_url".*eza_x86_64-unknown-linux-gnu.tar.gz"' | cut -d'"' -f4 || true)
    if [ -z "$url" ]; then print_error "Failed to fetch Eza release"; return; fi
    wget -q "$url" -O /tmp/eza.tar.gz
    tmpdir=$(mktemp -d)
    if tar -xzf /tmp/eza.tar.gz -C "$tmpdir" 2>/dev/null; then
        binpath=$(find "$tmpdir" -type f -name eza -executable -print -quit 2>/dev/null || true)
        if [ -n "$binpath" ]; then
            install -m 755 "$binpath" /usr/local/bin/eza
            cat > /etc/profile.d/eza-alias.sh <<'EOF'
alias ls='eza'
alias ll='eza -lh --icons --git'
alias la='eza -lah --icons --git'
alias lt='eza -lh --icons --git --tree'
alias l='eza -lah --icons --git'
EOF
            chmod 644 /etc/profile.d/eza-alias.sh
            print_success "Eza installed with shell aliases"
        else
            print_error "Eza binary not found in archive"
        fi
    else
        print_error "Failed to extract Eza archive"
    fi
    rm -rf "$tmpdir" /tmp/eza.tar.gz
}

install_missing_tools() {
    print_banner "${ICON_TOOL} Tools setup"
    install_eza
    install_helix
    install_speedtest
}

configure_unattended() {
    local codename_regex
    codename_regex="(${DISTRO_CODENAME}|\\\${distro_codename})"
    if ! command_exists unattended-upgrade; then
        echo -ne "${BOLD}Auto-update mode: 1) security-only 2) security + stable updates [1/2, default 1]: ${RESET}"
        read -r upd_choice
        upd_choice=${upd_choice:-1}
        install_unattended
        cp /etc/apt/apt.conf.d/50unattended-upgrades /etc/apt/apt.conf.d/52unattended-upgrades-local
        if [ "$upd_choice" = "2" ]; then
            sed -i "s|^//\\( *\"origin=Debian,codename=\\\${distro_codename}-updates\";\\)|\\1|" /etc/apt/apt.conf.d/52unattended-upgrades-local
            print_success "Enabled automatic security + stable updates"
        else
            print_success "Enabled automatic security updates (default)"
        fi
        systemctl enable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
        return
    fi

    # Already installed: check whether stable updates are enabled
    cfg=""
    if [ -f /etc/apt/apt.conf.d/52unattended-upgrades-local ]; then
        cfg="/etc/apt/apt.conf.d/52unattended-upgrades-local"
    elif [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
        cfg="/etc/apt/apt.conf.d/50unattended-upgrades"
    fi

    stable_enabled="no"
    security_enabled="no"
    if [ -n "$cfg" ]; then
        grep -qE "^\s*\"origin=Debian,codename=${codename_regex}-security" "$cfg" 2>/dev/null && security_enabled="yes"
        grep -qE "^\s*\"origin=Debian,codename=${codename_regex}-updates" "$cfg" 2>/dev/null && stable_enabled="yes"
    fi

    if [ "$stable_enabled" = "yes" ]; then
        print_info "unattended-upgrades already set to security + stable updates; keeping as-is."
        systemctl enable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
        return
    fi

    if [ "$security_enabled" = "yes" ]; then
        echo -ne "${BOLD}Currently security-only. Enable stable updates too? [y/N]: ${RESET}"
        read -r add_stable
        add_stable=${add_stable:-n}
        if [[ "$add_stable" =~ ^[Yy]$ ]]; then
            [ -z "$cfg" ] && cfg="/etc/apt/apt.conf.d/52unattended-upgrades-local"
            [ ! -f "$cfg" ] && cp /etc/apt/apt.conf.d/50unattended-upgrades "$cfg"
            sed -i "s|^//\\( *\"origin=Debian,codename=\\\${distro_codename}-updates\";\\)|\\1|" "$cfg"
            systemctl enable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
            print_success "Stable updates enabled (security remains enabled)"
        else
            print_info "Keeping security-only updates."
        fi
    else
        print_warning "Security updates entry not detected; please review configuration."
    fi
}

install_docker_prompt() {
    if command_exists docker; then
        current_ver=$(docker --version 2>/dev/null | head -n1 || echo "installed")
        echo -ne "${BOLD}Docker already detected (${current_ver}). Reinstall/update via get.docker.com? [y/N]: ${RESET}"
        read -r ans
        ans=${ans:-n}
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            print_info "Keeping existing Docker installation."
            return
        fi
    else
        echo -ne "${BOLD}Install Docker? [y/N]: ${RESET}"
        read -r ans
        ans=${ans:-n}
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            print_info "Skipping Docker installation"
            return
        fi
    fi
    print_info "Installing Docker..."
    wget -qO- https://get.docker.com/ | sh
    print_success "Docker installation finished"
}

install_base_packages() {
    print_banner "${ICON_PKG} Installing base packages"
    apt-get install $APT_INSTALL_OPTS openssl gnupg curl wget nano htop cron chrony fail2ban unzip logrotate vnstat nload
    systemctl enable --now fail2ban 2>/dev/null || true
    print_success "Base packages installed"
}

configure_chrony() {
    print_banner "${ICON_TIME} Time sync & timezone"
    # Choose NTP pool based on IP
    region_prefix=""
    case "${IP_TZ:-}" in
        Asia/*) region_prefix="asia." ;;
        Europe/*) region_prefix="europe." ;;
        Africa/*) region_prefix="africa." ;;
        Australia/*|Pacific/*) region_prefix="oceania." ;;
        America/*)
            if [[ "${IP_TZ:-}" =~ (Argentina|Brazil|Chile|Colombia|Peru|Venezuela|Sao_Paulo|Buenos_Aires|Santiago|Bogota|Lima|Caracas) ]]; then
                region_prefix="south-america."
            else
                region_prefix="north-america."
            fi
            ;;
        *) region_prefix="" ;;
    esac
    CHRONY_CONF="/etc/chrony/chrony.conf"
    mkdir -p /etc/chrony
    if [ -f "$CHRONY_CONF" ]; then
        cp "$CHRONY_CONF" "${CHRONY_CONF}.bak"
    fi
    cat > "$CHRONY_CONF" <<EOF
server 0.${region_prefix}pool.ntp.org iburst
server 1.${region_prefix}pool.ntp.org iburst
server 2.${region_prefix}pool.ntp.org iburst
server 3.${region_prefix}pool.ntp.org iburst
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
log tracking measurements statistics
logdir /var/log/chrony
EOF
    systemctl enable --now chrony 2>/dev/null || true
    print_success "chrony configured (${region_prefix:-global} pool)"

    CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Unknown")
    print_kv "Current timezone" "$CURRENT_TZ"
    print_kv "Suggested timezone" "${IP_TZ:-Unknown}"
    echo ""
    echo -ne "${BOLD}Enter a new timezone to change (e.g., Asia/Shanghai), or press Enter to keep current: ${RESET}"
    read -r newtz
    if [ -n "$newtz" ]; then
        if timedatectl set-timezone "$newtz" 2>/dev/null; then
            print_success "Timezone set to $newtz"
            CURRENT_TZ="$newtz"
        else
            print_error "Failed to set timezone; keeping current."
        fi
    else
        print_info "Keeping current timezone: $CURRENT_TZ"
    fi
    TIMEZONE_FINAL="$CURRENT_TZ"
}

prompt_forwarding() {
    echo ""
    echo -ne "${BOLD}Enable IPv4/IPv6 forwarding (opt-in, turns host into a router)? [y/N]: ${RESET}"
    read -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        ENABLE_FORWARDING=1
    fi
}

choose_sysctl_mode() {
    echo ""
    print_banner "${ICON_GEAR} Sysctl mode options"
    echo -e " ${BLUE}1)${RESET} Compatible (default): BBR + fq with conservative settings"
    echo -e " ${BLUE}2)${RESET} Performance/Experimental: Full tuning, higher compatibility risk"
    echo ""
    echo -ne "${BOLD}Select sysctl mode [1/2, default 1]: ${RESET}"
    read -r mode_choice
    case "${mode_choice:-1}" in
        2) SYSCTL_MODE="performance" ;;
        *) SYSCTL_MODE="compatible" ;;
    esac
    print_info "Selected sysctl mode: $SYSCTL_MODE"
}

is_sysctl_supported() {
    local key="$1"
    local path="/proc/sys/${key//./\/}"
    [ -e "$path" ]
}

filter_sysctl_file() {
    local src="$1" dest="$2" unsupported=0
    while IFS= read -r line; do
        # Preserve comments and blank lines
        if [[ -z "${line// }" || "$line" =~ ^[[:space:]]*# ]]; then
            echo "$line" >>"$dest"
            continue
        fi
        local key val
        key=$(echo "$line" | cut -d= -f1 | xargs)
        val=$(echo "$line" | cut -d= -f2- | sed 's/^ *//')
        if is_sysctl_supported "$key"; then
            echo "$key = $val" >>"$dest"
        else
            echo "# skipped (unsupported): $key = $val" >>"$dest"
            unsupported=1
        fi
    done <"$src"
    if [ "$unsupported" -eq 1 ]; then
        print_warning "Some sysctl keys not supported on this kernel; they were commented out in $dest"
    fi
}

generate_sysctl_content_compatible() {
    cat <<'COMPAT'
# ============================================================================
# Compatible profile - BBR + fq with conservative settings
# ============================================================================
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_rfc1337 = 1
vm.overcommit_memory = 0
COMPAT
}

generate_sysctl_content_performance() {
    cat <<'COMMON'
# ============================================================================
# Shared settings - applied to all memory tiers
# ============================================================================
kernel.panic = 1
net.core.default_qdisc = fq
net.core.optmem_max = 65536
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.ip_default_ttl = 128
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_autocorking = 1
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_fastopen = 1027
net.ipv4.tcp_fastopen_blackhole_timeout_sec = 10
net.ipv4.tcp_frto = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_ssthresh_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_retries1 = 2
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.udp_rmem_min = 4096
net.ipv4.udp_wmem_min = 4096
net.netfilter.nf_conntrack_icmp_timeout = 10
net.netfilter.nf_conntrack_icmpv6_timeout = 10
net.netfilter.nf_conntrack_tcp_timeout_close = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 10
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_unacknowledged = 60
net.netfilter.nf_conntrack_udp_timeout = 30
vm.overcommit_memory = 0
COMMON
}

generate_sysctl_memory_block() {
    local tier="$1"
    case "$tier" in
        small)
            cat <<'SMALL'
# ============================================================================
# Small memory profile - roughly 480 MB to < 900 MB (tolerant for undersized 512 MB nodes)
# ============================================================================
net.core.netdev_max_backlog = 4096
net.core.somaxconn = 2048
net.core.rmem_default = 131072
net.core.wmem_default = 65536
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.ipv4.tcp_max_orphans = 4096
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_max_tw_buckets = 16384
net.ipv4.tcp_rmem = 4096 65536 4194304
net.ipv4.tcp_wmem = 4096 32768 4194304
net.ipv4.tcp_collapse_max_bytes = 2097152
net.ipv4.tcp_mem = 16384 32768 65536
net.ipv4.udp_mem = 16384 32768 65536
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_retries2 = 6
net.netfilter.nf_conntrack_max = 32768
net.netfilter.nf_conntrack_generic_timeout = 30
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_max_retrans = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60
vm.swappiness = 30
vm.vfs_cache_pressure = 150
vm.min_free_kbytes = 16384
kernel.task_delayacct = 0
fs.file-max = 65536
SMALL
            ;;
        medium)
            cat <<'MEDIUM'
# ============================================================================
# Medium memory profile - ~900 MB to < 1.9 GB (covers undersized 1 GB nodes)
# ============================================================================
net.core.netdev_max_backlog = 8192
net.core.somaxconn = 4096
net.core.rmem_default = 262144
net.core.wmem_default = 131072
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.ipv4.tcp_max_orphans = 8192
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.tcp_rmem = 4096 131072 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608
net.ipv4.tcp_collapse_max_bytes = 4194304
net.ipv4.tcp_mem = 32768 65536 131072
net.ipv4.udp_mem = 32768 65536 131072
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_orphan_retries = 2
net.ipv4.tcp_retries2 = 8
net.netfilter.nf_conntrack_max = 65536
net.netfilter.nf_conntrack_generic_timeout = 60
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
net.netfilter.nf_conntrack_tcp_timeout_max_retrans = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 120
vm.swappiness = 10
vm.vfs_cache_pressure = 100
vm.min_free_kbytes = 32768
kernel.task_delayacct = 1
fs.file-max = 131072
MEDIUM
            ;;
        large|*)
            cat <<'LARGE'
# ============================================================================
# Large memory profile - 1.9 GB and above
# ============================================================================
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_max_orphans = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
net.ipv4.tcp_collapse_max_bytes = 8388608
net.ipv4.tcp_mem = 65536 131072 262144
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_orphan_retries = 2
net.ipv4.tcp_retries2 = 10
net.netfilter.nf_conntrack_max = 131072
net.netfilter.nf_conntrack_generic_timeout = 120
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_max_retrans = 120
net.netfilter.nf_conntrack_udp_timeout_stream = 180
vm.swappiness = 10
vm.vfs_cache_pressure = 75
vm.min_free_kbytes = 65536
kernel.task_delayacct = 1
fs.file-max = 262144
LARGE
            ;;
    esac
}

apply_sysctl() {
    print_banner "${ICON_GEAR} Kernel tuning (by memory tier)"
    local mem_mb tier tmpfile
    mem_mb=$(echo "$MEM_KB" | awk '{printf $1/1024}')
    # Tolerant thresholds: <480MB (BBR-only), <900MB (small), <1900MB (medium), otherwise large.
    tmpfile=$(mktemp)
    if (( MEM_KB < 491520 )); then
        print_warning "Memory < 512MB: only enabling BBR + fq without further tuning."
        tier="bbr-only-<512mb"
        cat > "$tmpfile" <<'EOF'
# Minimal tuning for low-memory (<512MB): only enable BBR + fq
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    else
        tier="large"
        if (( MEM_KB < 921600 )); then
            tier="small"
        elif (( MEM_KB < 1945600 )); then
            tier="medium"
        fi
        print_info "Detected memory: ${mem_mb} MB → using ${tier} profile"
        if [ "$SYSCTL_MODE" = "compatible" ]; then
            generate_sysctl_content_compatible > "$tmpfile"
        else
            {
                generate_sysctl_content_performance
                echo ""
                generate_sysctl_memory_block "$tier"
            } > "$tmpfile"
        fi
    fi
    if [ "$ENABLE_FORWARDING" -eq 1 ]; then
        {
            echo ""
            echo "# Opt-in IP forwarding"
            echo "net.ipv4.ip_forward = 1"
            echo "net.ipv6.conf.all.forwarding = 1"
            echo "net.ipv6.conf.default.forwarding = 1"
        } >> "$tmpfile"
    fi
    mkdir -p /etc/sysctl.d
    backup_file "$SYSCTL_FILE"
    : > "$SYSCTL_FILE"
    filter_sysctl_file "$tmpfile" "$SYSCTL_FILE"
    rm -f "$tmpfile"
    sysctl --system >/dev/null 2>&1 || true
    BBR_APPLIED=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    QDISC_APPLIED=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    print_success "sysctl applied (BBR: $BBR_APPLIED, qdisc: $QDISC_APPLIED)"
    OPT_TIER="$tier"
}

maybe_enable_zram_swap() {
    # Offer zram swap for low/small memory (<=2 GB) hosts
    if (( MEM_KB > 2097152 )); then
        return
    fi
    if grep -q "^/dev/zram" /proc/swaps 2>/dev/null; then
        print_info "ZRAM swap already active; skipping."
        return
    fi
    echo -ne "${BOLD}Memory <= 2GB detected. Install zram-tools and enable zram swap? [y/N]: ${RESET}"
    read -r ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        print_info "Skipping zram swap setup."
        return
    fi
    print_info "Installing zram-tools and enabling zram swap..."
    apt-get install $APT_INSTALL_OPTS zram-tools
    cat > /etc/default/zramswap <<'EOF'
# zramswap config managed by init script
ALGO=lz4
PERCENT=50
PRIORITY=100
EOF
    systemctl enable --now zramswap.service 2>/dev/null || true
    print_success "zram swap enabled (50% of RAM, lz4)"
}

write_marker() {
    local ts_utc
    ts_utc=$(TZ=UTC date '+%Y-%m-%d %H:%M:%S UTC')
    mkdir -p "$(dirname "$MARKER_FILE")"
    {
        echo "timestamp_utc: ${ts_utc}"
        echo "timezone: UTC"
        echo "memory_tier: ${OPT_TIER:-unknown}"
        echo "ipv4: ${IPV4_ADDR:-N/A}"
        echo "ipv6: ${IPV6_ADDR:-N/A}"
        echo "zram_status: ${ZRAM_STATUS:-unknown}"
        echo "docker_status: ${DOCKER_STATUS:-unknown}"
    } > "$MARKER_FILE"
    print_info "Marker written to: $MARKER_FILE"
}

show_report() {
    print_banner "${ICON_DOC} Summary"
    print_kv "BBR" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    print_kv "Queueing" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
    print_kv "sysctl file" "$SYSCTL_FILE (tier: ${OPT_TIER:-?})"
    print_kv "chrony" "$(systemctl is-active chrony 2>/dev/null || echo '?')"
    print_kv "fail2ban" "$(systemctl is-active fail2ban 2>/dev/null || echo '?')"
    if command_exists unattended-upgrade; then
        print_kv "unattended-upgrades" "installed ($(systemctl is-active apt-daily-upgrade.timer 2>/dev/null || echo 'timer?'))"
    else
        print_kv "unattended-upgrades" "not installed"
    fi
    print_kv "zram swap" "${ZRAM_STATUS:-not detected}"
    print_kv "Docker" "$DOCKER_STATUS"
    print_kv "Timezone" "${TIMEZONE_FINAL:-unknown}"
    print_kv "Marker" "$MARKER_FILE"
    echo ""
    print_success "All steps complete. Reboot recommended for full effect."
}

show_tools_summary() {
    print_banner "${ICON_DOC} Summary (lite mode)"
    print_kv "Eza" "$EZA_VER"
    print_kv "Helix" "$HELIX_VER"
    print_kv "Speedtest" "$SPEEDTEST_VER"
    print_kv "zram swap" "${ZRAM_STATUS:-not detected}"
    if command_exists docker; then
        print_kv "Docker" "installed"
    else
        print_kv "Docker" "not installed"
    fi
    echo ""
    print_success "Lite mode finished (marker present)."
}

main() {
    require_root
    require_debian
    ensure_basic_tools
    check_marker
    fetch_ipinfo
    detect_versions
    detect_updates_hint
    detect_unattended
    detect_system
    detect_docker_status
    detect_zram_status
    show_detection
    confirm_proceed
    if [ "$MODE_LITE" -eq 1 ]; then
        install_missing_tools
        install_docker_prompt
        maybe_enable_zram_swap
        detect_docker_status
        detect_zram_status
        detect_versions
        show_tools_summary
        exit 0
    fi
    apt_refresh
    install_missing_tools
    install_docker_prompt
    configure_unattended
    install_base_packages
    configure_chrony
    maybe_enable_zram_swap
    choose_sysctl_mode
    prompt_forwarding
    apply_sysctl
    detect_docker_status
    detect_zram_status
    write_marker
    show_report
}

main "$@"
