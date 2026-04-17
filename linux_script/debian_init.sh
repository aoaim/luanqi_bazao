#!/bin/bash

# Debian 12/13 initialization script
# Performs environment detection, tool installation, timezone configuration, and kernel tuning
# Update: 26/04/17

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

GITHUB_ALLOWED=1

DISABLE_IPV6=0

APT_INSTALL_OPTS="-y -qq -o=Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
TEMP_DIR=$(mktemp -d -p /var/tmp)

# Global Architecture Detection
case "$(uname -m)" in
    x86_64|amd64)
        ARCH="x86_64"
        ARCH_DEB="amd64"
        ;;
    aarch64|arm64)
        ARCH="aarch64"
        ARCH_DEB="arm64"
        ;;
    *)
        echo -e "\033[0;31mUnsupported architecture: $(uname -m)\033[0m"
        exit 1
        ;;
esac

SYSCTL_NETWORK_FILE="/etc/sysctl.d/99-network-tuning.conf"
SYSCTL_SWAPPINESS_FILE="/etc/sysctl.d/99-swappiness.conf"
SYSCTL_IPV6_FILE="/etc/sysctl.d/99-ipv6-disable.conf"

cleanup_temp() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_temp EXIT
trap 'cleanup_temp; exit 1' INT TERM

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Icons
ICON_PKG="[PKG]"
ICON_TIME="[TIME]"
ICON_DONE="[DONE]"
ICON_TOOL="[TOOL]"
ICON_OK="[OK]"
ICON_WARN="[WARN]"
ICON_ERR="[ERR]"
ICON_INFO="[INFO]"

print_section() {
    echo ""
    echo -e "${BLUE}${BOLD}▶ $1${RESET}"
}

print_success() { echo -e "${GREEN}${ICON_OK} $1${RESET}"; }
print_warning() { echo -e "${YELLOW}${ICON_WARN} $1${RESET}"; }
print_error()   { echo -e "${RED}${ICON_ERR} $1${RESET}"; }
print_info()    { echo -e "${CYAN}${ICON_INFO} $1${RESET}"; }

print_subsection() {
    echo -e "${BOLD}${CYAN}$1${RESET}"
}

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
        DISTRO_CODENAME="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo trixie)}"
    else
        print_error "Cannot read /etc/os-release. Aborting."
        exit 1
    fi
}

ensure_basic_tools() {
    print_section "${ICON_PKG} Preparing prerequisites"
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
    IPV4_ADDR="N/A"
    for api in "ip.sb" "api.ipify.org" "ifconfig.me" "ipinfo.io/ip"; do
        tmp_ip=$(curl -fsSL --max-time 5 -4 "$api" 2>/dev/null || true)
        if [ -n "$tmp_ip" ]; then
            IPV4_ADDR="$tmp_ip"
            break
        fi
    done

    IPV6_ADDR="N/A"
    for api in "ip.sb" "ifconfig.co" "icanhazip.com" "ident.me"; do
        tmp_ip=$(curl -fsSL --max-time 5 -6 "$api" 2>/dev/null || true)
        if [ -n "$tmp_ip" ]; then
            IPV6_ADDR="$tmp_ip"
            break
        fi
    done

    # Detect IPv6 status: disabled by sysctl, no address assigned, or working
    IPV6_STATUS=""
    if [ "${IPV6_ADDR:-N/A}" = "N/A" ] || [ -z "$IPV6_ADDR" ]; then
        local ipv6_sysctl_disabled
        ipv6_sysctl_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
        if [ "$ipv6_sysctl_disabled" = "1" ]; then
            IPV6_STATUS="disabled by sysctl"
        else
            # Check if any interface has a global IPv6 address
            local has_ipv6_addr
            has_ipv6_addr=$(ip -6 addr show scope global 2>/dev/null | grep -c "inet6" || true)
            has_ipv6_addr=$(echo "$has_ipv6_addr" | tr -d '[:space:]')
            has_ipv6_addr=${has_ipv6_addr:-0}
            if [ "$has_ipv6_addr" -gt 0 ] 2>/dev/null; then
                IPV6_STATUS="address assigned but external unreachable"
            else
                IPV6_STATUS="not assigned by provider"
            fi
        fi
    fi

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

# Silent download with retry support
download_file() {
    local url="$1"
    local dest="$2"

    if curl -fsSL --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 \
         "$url" -o "$dest" 2>/dev/null; then
        [ -s "$dest" ] && return 0
        rm -f "$dest"
        return 1
    else
        rm -f "$dest"
        return 1
    fi
}

ensure_unzip() {
    if ! command_exists unzip; then
        apt-get install -qq -y unzip >/dev/null 2>&1 || true
    fi
    if ! command_exists unzip; then
        print_error "unzip install failed"
        return 1
    fi
    return 0
}

ensure_xz() {
    if ! command_exists xz; then
        apt-get install -qq -y xz-utils >/dev/null 2>&1 || true
    fi
    if ! command_exists xz; then
        print_error "xz-utils install failed"
        return 1
    fi
    return 0
}

ensure_bzip2() {
    if ! command_exists bzip2; then
        apt-get install -qq -y bzip2 >/dev/null 2>&1 || true
    fi
    if ! command_exists bzip2; then
        print_error "bzip2 install failed"
        return 1
    fi
    return 0
}

extract_archive() {
    local archive="$1"
    local dest="$2"

    case "$archive" in
        *.tar.xz|*.txz)
            ensure_xz || return 1
            tar -xJf "$archive" -C "$dest"
            ;;
        *.tar.gz|*.tgz)
            tar -xzf "$archive" -C "$dest"
            ;;
        *.tar.bz2|*.tbz|*.tbz2)
            ensure_bzip2 || return 1
            tar -xjf "$archive" -C "$dest"
            ;;
        *.zip)
            ensure_unzip || return 1
            unzip -q -o "$archive" -d "$dest"
            ;;
        *)
            print_error "Unsupported archive format: $archive"
            return 1
            ;;
    esac
}

detect_system() {
    MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    SWAP_KB=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
    DISK_ROOT=$(df -h / | awk 'NR==2{print $3 " / " $2 " (" $5 " used)"}')
    DISK_ROOT_USED=$(df -P / | awk 'NR==2{print $5}')
    if [ "$DISK_ROOT_USED" = "100%" ]; then
        print_error "Root partition is full! Free up space before running this script."
        exit 1
    fi
    BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    QDISC_STATUS=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    SWAP_STR="Not enabled"
    if [ "${SWAP_KB:-0}" -gt 0 ]; then
        SWAP_STR="$(awk '/SwapTotal/ {printf "%.1f MB", $2/1024}' /proc/meminfo)"
    fi
}

detect_zram_status() {
    ZRAM_STATUS="Not active"
    if grep -q "^/dev/zram" /proc/swaps 2>/dev/null; then
        local size_kb prio
        size_kb=$(awk '$1 ~ /zram/ {s+=$3} END {print s+0}' /proc/swaps)
        prio=$(awk '$1 ~ /zram/ {print $5; exit}' /proc/swaps)
        if [ "${size_kb:-0}" -gt 0 ]; then
            ZRAM_STATUS=$(awk -v s="$size_kb" -v p="$prio" 'BEGIN {printf "Active (%.1f MB, prio %s)", s/1024, p}')
        else
            ZRAM_STATUS="Active (size unknown, prio ${prio:-?})"
        fi
    fi
}

show_detection() {
    print_section "${ICON_INFO} Environment check"
    print_kv "IPv4" "${IPV4_ADDR:-N/A}"
    if [ "${IPV6_ADDR:-N/A}" != "N/A" ] && [ -n "$IPV6_ADDR" ]; then
        print_kv "IPv6" "$IPV6_ADDR"
    elif [ -n "$IPV6_STATUS" ]; then
        print_kv "IPv6" "${YELLOW}Not available${RESET} (${IPV6_STATUS})"
    else
        print_kv "IPv6" "N/A"
    fi
    print_kv "ASN" "${IP_ORG:-?}"
    print_kv "Location" "${IP_CITY:-?}, ${IP_REGION:-?}, ${IP_COUNTRY:-?}"
    CURRENT_TZ_DISPLAY=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Unknown")
    print_kv "Timezone" "${CURRENT_TZ_DISPLAY}"
    print_kv "Kernel" "$(uname -r)"
    local cpu_info
    cpu_info=$(lscpu 2>/dev/null | grep 'Model name' | cut -d: -f2- | xargs || echo '?')
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo '?')
    print_kv "CPU" "$cpu_info (${cpu_cores} Cores)"
    print_kv "Memory" "$(echo "$MEM_KB" | awk '{printf "%.1f MB", $1/1024}')"
    print_kv "Swap" "$SWAP_STR"
    print_kv "ZRAM Swap" "${ZRAM_STATUS:-not detected}"
    print_kv "Disk (/)" "$DISK_ROOT"
    print_kv "BBR / Qdisc" "$BBR_STATUS / $QDISC_STATUS"
}

get_github_latest_version() {
    # $1 = repo (user/repo)
    # Returns tag (e.g., v1.0.0 or 1.0.0 depending on repo)
    local curl_opts=("-sL" "--connect-timeout" "5" "--max-time" "15" "--retry" "3" "--retry-delay" "1" "--retry-connrefused")
    if [ -n "${IPV4_ADDR:-}" ] && [ "${IPV4_ADDR}" != "N/A" ]; then
        curl_opts+=("-4")
    fi
    curl "${curl_opts[@]}" -o /dev/null -w %{url_effective} "https://github.com/$1/releases/latest" | grep -oE '[^/]+$'
}

get_github_api_asset_url() {
    # $1 = repo (user/repo)
    # $2 = grep -E pattern for browser_download_url
    local repo="$1"
    local pattern="$2"
    local curl_opts=("-sL" "--connect-timeout" "5" "--max-time" "20" "--retry" "3" "--retry-delay" "1" "--retry-connrefused")

    if [ -n "${IPV4_ADDR:-}" ] && [ "${IPV4_ADDR}" != "N/A" ]; then
        curl_opts+=("-4")
    fi

    curl "${curl_opts[@]}" "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
        | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/^"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]+)"$/\1/' \
        | grep -E "$pattern" \
        | head -n1 || true
}


install_cf_speedtest() {
    if [ "$GITHUB_ALLOWED" -eq 0 ]; then
        print_warning "IPv6-only detected: skipping Cloudflare Speedtest CLI (GitHub download required)."
        return
    fi
    print_info "Installing Cloudflare Speedtest CLI..."

    local arch_url=""
    if [ "$ARCH" = "x86_64" ]; then
        arch_url="https://github.com/kavehtehrani/cloudflare-speed-cli/releases/latest/download/cloudflare-speed-cli-x86_64-unknown-linux-musl.tar.xz"
    elif [ "$ARCH" = "aarch64" ]; then
        arch_url="https://github.com/kavehtehrani/cloudflare-speed-cli/releases/latest/download/cloudflare-speed-cli-aarch64-unknown-linux-musl.tar.xz"
    else
        print_warning "Unsupported architecture for Cloudflare Speedtest CLI: $ARCH"
        return
    fi

    if download_file "$arch_url" "${TEMP_DIR}/cfspeed.tar.xz"; then
        if extract_archive "${TEMP_DIR}/cfspeed.tar.xz" "$TEMP_DIR"; then
            local binpath
            binpath=$(find "$TEMP_DIR" -type f -name "cloudflare-speed-cli*" -executable -print -quit 2>/dev/null || true)
            if [ -z "$binpath" ]; then
                binpath=$(find "$TEMP_DIR" -type f -name "cloudflare-speed-cli*" -print -quit 2>/dev/null || true)
            fi

            if [ -n "$binpath" ]; then
                install -m 755 "$binpath" /usr/local/bin/cloudflare-speed-cli
                cat > /etc/profile.d/cfspeed-alias.sh <<'EOF'
alias cf='cloudflare-speed-cli'
EOF
                chmod 644 /etc/profile.d/cfspeed-alias.sh
                print_success "Cloudflare Speedtest CLI installed (alias: cf)"
            else
                print_error "Binary not found in archive"
            fi
        else
            print_error "Failed to extract archive"
        fi
        rm -f "${TEMP_DIR}/cfspeed.tar.xz"
    else
        print_error "Failed to download Cloudflare Speedtest CLI"
    fi
}

apt_refresh() {
    print_section "${ICON_PKG} System update"
    apt-get update -qq || true
    apt-get upgrade $APT_INSTALL_OPTS || true
    apt-get autoremove $APT_INSTALL_OPTS
    apt-get clean
    print_success "System update completed"
}

install_helix() {
    if [ "$GITHUB_ALLOWED" -eq 0 ]; then
        print_warning "IPv6-only detected: skipping Helix (GitHub download required)."
        return
    fi
    print_info "Installing Helix..."

    local tag="" ver="" url=""

    tag=$(get_github_latest_version "helix-editor/helix")
    if [ -n "$tag" ]; then
        ver=$(echo "$tag" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
        [ -n "$ver" ] && url="https://github.com/helix-editor/helix/releases/download/${tag}/helix-${ver}-${ARCH}-linux.tar.xz"
    fi

    # Fallback to API if tag/url construction failed
    if [ -z "$url" ]; then
        url=$(get_github_api_asset_url "helix-editor/helix" "helix-.*-${ARCH}-linux\\.tar\\.xz$")
    fi

    if [ -z "$url" ]; then
        print_error "Unable to get Helix download URL"
        return
    fi

    if download_file "$url" "${TEMP_DIR}/helix.tar.xz"; then
        if extract_archive "${TEMP_DIR}/helix.tar.xz" "$TEMP_DIR"; then
            local helix_dir
            helix_dir=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "helix-*" -print -quit)

            if [ -n "$helix_dir" ] && [ -f "${helix_dir}/hx" ]; then
                install -m 755 "${helix_dir}/hx" /usr/local/bin/hx
                mkdir -p /usr/local/lib/helix
                rm -rf /usr/local/lib/helix/runtime
                [ -d "${helix_dir}/runtime" ] && cp -r "${helix_dir}/runtime" /usr/local/lib/helix/

                cat > /etc/profile.d/helix-alias.sh <<'EOF'
export HELIX_RUNTIME=/usr/local/lib/helix/runtime
alias vi='hx'
alias vim='hx'
EOF
                chmod 644 /etc/profile.d/helix-alias.sh
                print_success "Helix installed (aliases: vi, vim, hx)"
            else
                print_error "Helix binary or directory structure not found in archive"
            fi
        else
            print_error "Failed to extract Helix archive"
        fi
        rm -f "${TEMP_DIR}/helix.tar.xz"
        rm -rf "${TEMP_DIR}/helix-"* 2>/dev/null || true
    else
        print_error "Helix download failed"
    fi
}

install_nexttrace() {
    if [ "$GITHUB_ALLOWED" -eq 0 ]; then
        print_warning "IPv6-only detected: skipping Nexttrace (GitHub download required)."
        return
    fi
    print_info "Installing Nexttrace..."
    # nexttrace_linux_amd64 or nexttrace_linux_arm64
    local arch_suffix
    if [ "$ARCH" = "x86_64" ]; then
        arch_suffix="amd64"
    else
        arch_suffix="arm64"
    fi

    local url="https://github.com/nxtrace/NTrace-core/releases/latest/download/nexttrace_linux_${arch_suffix}"

    if download_file "$url" "${TEMP_DIR}/nexttrace"; then
        install -m 755 "${TEMP_DIR}/nexttrace" /usr/local/bin/nexttrace
        cat > /etc/profile.d/nexttrace-alias.sh <<'EOF'
alias nt='nexttrace'
EOF
        chmod 644 /etc/profile.d/nexttrace-alias.sh
        print_success "Nexttrace installed (alias: nt)"
        rm -f "${TEMP_DIR}/nexttrace"
    else
        print_error "Nexttrace download failed"
    fi
}

ask_yes_no() {
    local prompt="$1"
    local choice
    while true; do
        printf "${CYAN}${BOLD}>>> %s [default: n] (y/yes, n/no): ${RESET}" "$prompt"
        read choice
        case "$choice" in
            y|Y|yes|Yes)
                print_info "Selected: y"
                return 0
                ;;
            n|N|no|No|"")
                print_info "Selected: n"
                return 1
                ;;
            *) echo "Please enter y/yes or n/no." ;;
        esac
    done
}

install_docker() {
    print_info "Installing Docker..."
    if command_exists docker; then
        print_success "Docker already installed"
        return
    fi

    if curl -fsSL https://get.docker.com | sh; then
        print_success "Docker installed successfully"
        usermod -aG docker debian 2>/dev/null || usermod -aG docker root 2>/dev/null || true
    else
        print_error "Failed to install Docker"
    fi
}

install_tools() {
    print_section "${ICON_TOOL} Tools setup"
    install_helix
    install_cf_speedtest
    install_nexttrace
}

configure_eza_aliases() {
    if ! command_exists eza; then
        print_warning "eza not found, skipping eza aliases"
        return
    fi

    cat > /etc/profile.d/eza-alias.sh <<'EOF'
# Keep system ls behavior unchanged for compatibility in scripts and automation.
# If you really want interactive ls mapped to eza, uncomment the next line manually.
# alias ls='eza --icons --group-directories-first --git'
alias ll='eza -l --icons --group-directories-first --git'
alias la='eza -al --icons --group-directories-first --git'
alias lt='eza -T --icons --level=2'
EOF
    chmod 644 /etc/profile.d/eza-alias.sh
    print_success "Eza aliases configured (ll, la, lt; ls kept native)"
}

configure_chrony() {
    print_section "${ICON_TIME} Time sync & timezone"
    # Choose NTP pool based on IP
    local region_prefix=""
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

    # Timezone: Auto-set to IP_TZ if available and different
    if [ -n "${IP_TZ:-}" ] && [ "$IP_TZ" != "$CURRENT_TZ" ]; then
        print_info "Setting timezone to ${IP_TZ} (detected)..."
         if timedatectl set-timezone "$IP_TZ" 2>/dev/null; then
            print_success "Timezone set to $IP_TZ"
            CURRENT_TZ="$IP_TZ"
        else
            print_error "Failed to set timezone; keeping current."
        fi
    else
        print_info "Timezone already matches detection or no detection available ($CURRENT_TZ)."
    fi
    TIMEZONE_FINAL="$CURRENT_TZ"
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

generate_sysctl_content() {
    local mem_mb=$((MEM_KB / 1024))

    cat <<SYSCTL
# ============================================================================
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
# ============================================================================

# ============================================================================
# Common Settings (IO, Security, Resources)
# ============================================================================

# --- IO 优化 (防卡死关键) ---
# 降低脏数据阈值，强制由于频繁写入磁盘
# 防止小内存机器因瞬间 I/O 高负载而死机
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5

# --- 资源限制 ---
# 扩大文件描述符上限
fs.file-max = 2097152
# 扩大可用端口范围 (1024-65535)
net.ipv4.ip_local_port_range = 1024 65535

# --- 网络安全加固 ---
# 开启 SYN Cookies 防范洪水攻击
net.ipv4.tcp_syncookies = 1
# 开启 RFC1337 防止 TIME-WAIT 暗杀
net.ipv4.tcp_rfc1337 = 1
# 忽略 ICMP 广播和错误消息 (防骚扰)
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# --- 路由与重定向 (禁止非路由器的危险行为) ---
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# ============================================================================
# BBR + TCP Congestion Control
# ============================================================================
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

SYSCTL

    if [ "$mem_mb" -lt 1024 ]; then
        # < 1GB RAM Profile: Aggressive response, tighter buffers
        cat <<SYSCTL
# ============================================================================
# Profile: < 1GB RAM (Aggressive Response)
# ============================================================================

# --- Core: Aggressive Response Speed ---
# Disable slow start after idle to ensure full speed immediately
net.ipv4.tcp_slow_start_after_idle = 0

# --- Buffers: Tight Configuration (32MB) ---
# 1Gbps@200ms needs ~25MB. 32MB covers jitter without OOM risk on 512MB RAM.
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 8192 87380 33554432
net.ipv4.tcp_wmem = 8192 65536 33554432

# --- Congestion Control Tuning ---
# Very low notsent threshold to reduce latency
net.ipv4.tcp_notsent_lowat = 16384

# --- Memory Protection (Strict Mode) ---
# Reserve only 16MB for kernel, maximize RAM for traffic
vm.min_free_kbytes = 16384
# Kill process on OOM, don't panic/reboot
vm.panic_on_oom = 0

# --- Connection Management ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
# Aggressive connection recycling for small memory
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
SYSCTL
    else
        # >= 1GB RAM Profile: Performance & Stability
        cat <<SYSCTL
# ============================================================================
# Profile: >= 1GB RAM (Performance & Stability)
# ============================================================================

# --- Core: Aggressive Response Speed ---
# Disable slow start after idle
net.ipv4.tcp_slow_start_after_idle = 0

# --- Buffers: Luxury Configuration (64MB) ---
# Can handle 400ms+ jitter at Gigabit speeds. Safe for >1GB RAM.
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 8192 262144 67108864
net.ipv4.tcp_wmem = 8192 262144 67108864

# --- Congestion Control Tuning ---
net.ipv4.tcp_notsent_lowat = 16384

# --- Memory Protection (Stable Mode) ---
# Reserve 64MB for kernel stability under load
vm.min_free_kbytes = 65536
vm.panic_on_oom = 0

# --- Connection Management ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
# Increased queue depth for high concurrency
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
SYSCTL
    fi
}

apply_network_sysctl() {
    print_section "${ICON_INFO} Network tuning"

    local tmpfile
    tmpfile="${TEMP_DIR}/sysctl_network.conf"

    generate_sysctl_content > "$tmpfile"

    mkdir -p /etc/sysctl.d
    : > "$SYSCTL_NETWORK_FILE"
    filter_sysctl_file "$tmpfile" "$SYSCTL_NETWORK_FILE"

    print_success "Network tuning config written to $SYSCTL_NETWORK_FILE"
}

apply_swappiness_sysctl() {
    local swappiness
    mkdir -p /etc/sysctl.d

    # Determine swappiness based on swap type
    # zram is fast (in-memory), so higher swappiness is beneficial
    # Disk swap is slow, so lower swappiness is preferred
    if grep -q "^/dev/zram" /proc/swaps 2>/dev/null; then
        swappiness=60
        print_info "${BOLD}zram detected: using swappiness=60${RESET}"
    else
        swappiness=10
        print_info "No zram: using swappiness=10"
    fi

    cat > "$SYSCTL_SWAPPINESS_FILE" <<EOF
# ============================================================================
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
# ============================================================================

# Swappiness - auto-configured based on swap type
# zram (fast, in-memory): 60
# Disk swap (slow): 10
vm.swappiness = ${swappiness}
EOF

    print_success "Swappiness config written to $SYSCTL_SWAPPINESS_FILE"
}

apply_ipv6_sysctl() {
    mkdir -p /etc/sysctl.d
    if [ "$DISABLE_IPV6" -eq 1 ]; then
        cat > "$SYSCTL_IPV6_FILE" <<'EOF'
# ============================================================================
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
# ============================================================================

# Disable IPv6 completely
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        print_success "IPv6 disabled ($SYSCTL_IPV6_FILE)"
    else
        # Enable IPv6 immediately (kernel defaults to 0 = enabled)
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
        # Remove IPv6 disable config if exists
        if [ -f "$SYSCTL_IPV6_FILE" ]; then
            rm -f "$SYSCTL_IPV6_FILE"
        fi
        print_success "IPv6 enabled"
    fi
}

install_cloud_kernel() {
    print_info "Installing Cloud Kernel..."
    if apt-get install $APT_INSTALL_OPTS "linux-image-cloud-${ARCH_DEB}"; then
        print_success "Cloud Kernel installed"
        print_info "Updating GRUB..."
        update-grub 2>/dev/null || true
    else
        print_error "Failed to install Cloud Kernel"
    fi
}

install_base_packages() {
    print_section "${ICON_PKG} Installing base packages"
    apt-get install $APT_INSTALL_OPTS rsyslog openssl gnupg cron chrony fail2ban python3-systemd logrotate nano vnstat nload htop unzip unattended-upgrades eza duf bat zoxide

    # Ensure rsyslog is enabled and started
    systemctl enable --now rsyslog 2>/dev/null || true

    # Configure Fail2Ban for Debian 12 (systemd backend)
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
backend = systemd
mode = normal
port = ssh
EOF
    systemctl enable --now fail2ban 2>/dev/null || true

    # Configure unattended-upgrades for security and stable updates
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

    # Enable automatic updates
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    print_success "Base packages installed"
}

apply_all_sysctl() {
    sysctl --system >/dev/null 2>&1 || true
    BBR_APPLIED=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    QDISC_APPLIED=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    print_success "sysctl applied (BBR: $BBR_APPLIED, qdisc: $QDISC_APPLIED)"
}

get_recommended_zram_config() {
    # Returns: "size_mb algorithm"
    local mem_mb=$1
    if [ "$mem_mb" -lt 800 ]; then
        echo "1024 zstd"   # < 800MB RAM: Try zstd (fallback to lz4 in auto_enable)
    else
        echo "2048 lz4"    # >= 800MB RAM: Fixed 2GB ZRAM (lz4 default)
    fi
}

configure_zram() {
    local size_mb="$1"
    local algo="$2"
    local expected_kb=$((size_mb * 1024))

    # Ensure zram-tools is installed
    if ! dpkg -l zram-tools 2>/dev/null | grep -q "^ii"; then
        print_info "Installing zram-tools..."
        apt-get install $APT_INSTALL_OPTS zram-tools
    fi

    # Completely stop and destroy existing zram
    systemctl stop zramswap.service 2>/dev/null || true
    swapoff /dev/zram0 2>/dev/null || true
    # Unload zram module to fully destroy the device
    rmmod zram 2>/dev/null || true

    # Write configuration BEFORE starting service
    cat > /etc/default/zramswap <<EOF
# zramswap config managed by init script
ALGO=${algo}
SIZE=${size_mb}
PRIORITY=100
EOF

    # Load zram module
    modprobe zram 2>/dev/null || true

    # Start service (not restart, since we fully stopped it)
    systemctl enable zramswap.service 2>/dev/null || true
    systemctl start zramswap.service 2>/dev/null || true

    # Wait for ZRAM to initialize with correct size (up to 5s)
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

    print_success "zram configured: ${size_mb}MB (algo: ${algo})"
}

auto_enable_zram_swap() {
    local mem_mb config recommended_size recommended_algo

    mem_mb=$((MEM_KB / 1024))
    config=$(get_recommended_zram_config "$mem_mb")
    recommended_size=$(echo "$config" | cut -d' ' -f1)
    recommended_algo=$(echo "$config" | cut -d' ' -f2)

    # Check if zstd is supported, fallback to lz4 if not
    if [ "$recommended_algo" = "zstd" ]; then
        if ! modprobe zstd >/dev/null 2>&1 && ! grep -q "zstd" /proc/crypto 2>/dev/null; then
             print_warning "zstd not supported by kernel, falling back to lz4."
             recommended_algo="lz4"
        fi
    fi

    print_info "Configuring zram swap (${recommended_size}MB, algo: ${recommended_algo})..."
    configure_zram "$recommended_size" "$recommended_algo"
}

show_report() {
    print_section "${ICON_DONE} Summary"

    print_subsection "Network"
    print_kv "BBR" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    print_kv "Queueing" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
    print_kv "Swappiness" "$(sysctl -n vm.swappiness 2>/dev/null || echo '?')"

    # IPv6 status: combine sysctl state with assignment state
    local ipv6_display
    local ipv6_sysctl
    ipv6_sysctl=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    if [ "$ipv6_sysctl" = "1" ]; then
        ipv6_display="${RED}disabled${RESET}"
    elif [ -n "${IPV6_STATUS:-}" ]; then
        ipv6_display="${YELLOW}${IPV6_STATUS}${RESET}"
    elif [ -n "${IPV6_ADDR:-}" ] && [ "${IPV6_ADDR}" != "N/A" ]; then
        ipv6_display="${GREEN}enabled${RESET} (${IPV6_ADDR})"
    else
        ipv6_display="${YELLOW}not assigned${RESET}"
    fi
    print_kv "IPv6" "$ipv6_display"
    echo ""

    print_subsection "Sysctl configs"
    print_info "sysctl configs:"
    [ -f "$SYSCTL_NETWORK_FILE" ] && echo -e "  ${GREEN}*${RESET} $SYSCTL_NETWORK_FILE"
    [ -f "$SYSCTL_SWAPPINESS_FILE" ] && echo -e "  ${GREEN}*${RESET} $SYSCTL_SWAPPINESS_FILE"
    [ -f "$SYSCTL_IPV6_FILE" ] && echo -e "  ${GREEN}*${RESET} $SYSCTL_IPV6_FILE"
    echo ""

    print_subsection "Services"
    print_kv "Chrony" "$(systemctl is-active chrony 2>/dev/null || echo '?')"
    print_kv "Fail2Ban" "$(systemctl is-active fail2ban 2>/dev/null || echo '?')"
    print_kv "ZRAM Swap" "${ZRAM_STATUS:-not detected}"
    print_kv "Timezone" "${TIMEZONE_FINAL:-unknown}"

    print_subsection "Auto updates"
    local auto_updates=""
    if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
        if grep -q 'codename=.*-security' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
            auto_updates+="security, "
        fi
        if grep -qE '"origin=Debian,codename=\$\{distro_codename\},label=Debian"' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
            auto_updates+="stable, "
        fi
        if grep -q 'codename=.*-updates' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
            auto_updates+="updates, "
        fi
    fi
    if [ -n "$auto_updates" ]; then
        print_kv "Auto-updates" "${GREEN}${auto_updates%, }${RESET}"
    else
        print_kv "Auto-updates" "${YELLOW}not configured${RESET}"
    fi
    echo ""

    print_subsection "Tools"
    print_info "Installed tools:"
    get_ver() {
        "$@" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
    }

    print_subsection "Kernel"
    local current_kernel
    current_kernel=$(uname -r)
    local latest_kernel
    latest_kernel=$(ls -1vr /boot/vmlinuz* 2>/dev/null | head -n1 | xargs -n1 basename 2>/dev/null | sed 's/vmlinuz-//')

    print_kv "Current Kernel" "$current_kernel"
    if [ -n "$latest_kernel" ] && [ "$latest_kernel" != "$current_kernel" ]; then
        print_kv "Latest Kernel" "$latest_kernel (will load on reboot)"
    fi

    local tools=""
    command -v eza >/dev/null && tools+="  eza $(get_ver eza --version)\n"
    command -v hx >/dev/null && tools+="  helix $(get_ver hx --version)\n"
    command -v cloudflare-speed-cli >/dev/null && tools+="  cloudflare-speed-cli $(get_ver cloudflare-speed-cli --version)\n"
    command -v duf >/dev/null && tools+="  duf $(get_ver duf --version)\n"
    command -v bat >/dev/null && tools+="  bat $(get_ver bat --version)\n"
    command -v zoxide >/dev/null && tools+="  zoxide $(get_ver zoxide --version)\n"
    command -v nexttrace >/dev/null && tools+="  nexttrace $(get_ver nexttrace --version)\n"
    [ -n "$tools" ] && echo -e "$tools" || echo "  (none)"
    echo ""

    print_success "All steps complete. Reboot recommended for full effect."
    echo ""

    # Source aliases
    for f in /etc/profile.d/*.sh; do
        [ -r "$f" ] && . "$f" 2>/dev/null || true
    done
    print_info "If aliases (cf, nt, vi, ll etc.) don't work, run: ${BOLD}source /etc/profile${RESET} or re-login."
}

main() {
    clear
    require_root
    require_debian
    ensure_basic_tools
    fetch_ipinfo
    detect_system
    # detect_zram_status is used by show_detection
    detect_zram_status
    show_detection

    apt_refresh
    install_tools
    install_base_packages
    configure_eza_aliases
    configure_chrony
    auto_enable_zram_swap
    apply_swappiness_sysctl
    apply_network_sysctl

    if [ -n "${IPV6_ADDR:-}" ] && [ "${IPV6_ADDR}" != "N/A" ]; then
        apply_ipv6_sysctl
    else
        print_info "IPv6 not detected, skipping IPv6 configuration."
    fi

    apply_all_sysctl

    print_section "${ICON_TOOL} Optional components"

    # Final Interactive Prompts
    if ask_yes_no "Install Cloud Kernel?"; then
        install_cloud_kernel
    fi

    if ask_yes_no "Install Docker?"; then
        install_docker
    fi

    if [ -n "${IPV6_ADDR:-}" ] && [ "${IPV6_ADDR}" != "N/A" ]; then
        if ask_yes_no "Disable IPv6?"; then
            DISABLE_IPV6=1
            print_info "Disabling IPv6..."
            apply_ipv6_sysctl
            sysctl --system >/dev/null 2>&1 || true
        fi
    fi

    detect_zram_status
    show_report
}

main "$@"
