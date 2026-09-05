#!/bin/bash

# Debian 13+ initialization script
# Performs environment detection, tool installation, timezone configuration, and kernel tuning
# Update: 26/08/06

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
        # Prefer VERSION_ID from os-release (numeric on stable Debian).
        # On testing/sid it may be empty; fall back to /etc/debian_version.
        DEBIAN_VERSION="${VERSION_ID:-0}"
        if [ -z "$DEBIAN_VERSION" ] || [ "$DEBIAN_VERSION" = "0" ]; then
            DEBIAN_VERSION=$(cut -d. -f1 /etc/debian_version 2>/dev/null || echo 0)
        fi
        if ! [[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] || [ "$DEBIAN_VERSION" -lt 13 ]; then
            print_error "Supported versions: Debian 13+. Current: ${VERSION:-${PRETTY_NAME:-unknown}}"
            exit 1
        fi
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
    for attempt in 1 2; do
        for api in "ip.sb" "api.ipify.org" "ifconfig.me" "ipinfo.io/ip"; do
            tmp_ip=$(curl -fsSL --max-time 5 -4 "$api" 2>/dev/null || true)
            if [ -n "$tmp_ip" ]; then
                IPV4_ADDR="$tmp_ip"
                break 2
            fi
        done
        if [ "$attempt" -lt 2 ] && { [ -z "$IPV4_ADDR" ] || [ "$IPV4_ADDR" = "N/A" ]; }; then
            sleep 3
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
    DISK_ROOT_USED_NUM=${DISK_ROOT_USED%\%}
    if [ "${DISK_ROOT_USED_NUM:-0}" -ge 95 ]; then
        print_error "Root partition nearly full (${DISK_ROOT_USED}). Free up space before running this script."
        exit 1
    fi
    BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    QDISC_STATUS=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    SWAP_STR="Not enabled"
    if [ "${SWAP_KB:-0}" -gt 0 ]; then
        SWAP_STR="$(awk '/SwapTotal/ {printf "%.1f MB", $2/1024}' /proc/meminfo)"
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
    # Follow the redirect and extract the tag from the effective URL
    # (e.g. .../releases/tag/v1.0.0 -> v1.0.0). Returns empty on failure.
    curl "${curl_opts[@]}" -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" 2>/dev/null \
        | grep -oE 'tag/[^/]+$' | sed 's#tag/##' || true
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

# Skip install when the tool is already present AND matches the latest release.
# $1 = command name, $2 = GitHub repo (user/repo), $3 = display label
# Returns 0 to skip (up to date, or cannot check), 1 to install/update.
tool_skip_check() {
    local cmd="$1" repo="$2" label="$3"
    if ! command_exists "$cmd"; then
        return 1
    fi

    local local_ver
    local_ver=$("$cmd" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
    if [ -z "$local_ver" ]; then
        print_info "${label} installed (version unknown), refreshing..."
        return 1
    fi

    local latest_tag latest_ver
    latest_tag=$(get_github_latest_version "$repo")
    if [ -z "$latest_tag" ]; then
        print_warning "${label} v${local_ver} installed; couldn't check latest release, skipping update."
        return 0
    fi
    latest_ver=$(echo "$latest_tag" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || true)

    if [ -n "$latest_ver" ] && [ "$local_ver" = "$latest_ver" ]; then
        print_success "${label} already up to date (v${local_ver})"
        return 0
    fi
    print_info "${label} update available: v${local_ver} -> v${latest_ver:-latest}"
    return 1
}


install_cf_speedtest() {
    if [ "$GITHUB_ALLOWED" -eq 0 ]; then
        print_warning "IPv6-only detected: skipping Cloudflare Speedtest CLI (GitHub download required)."
        return
    fi
    if tool_skip_check cloudflare-speed-cli "kavehtehrani/cloudflare-speed-cli" "CF Speedtest"; then
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
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
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
    apt-get autoremove $APT_INSTALL_OPTS || true
    apt-get clean || true
    print_success "System update completed"
}

install_helix() {
    if [ "$GITHUB_ALLOWED" -eq 0 ]; then
        print_warning "IPv6-only detected: skipping Helix (GitHub download required)."
        return
    fi
    if tool_skip_check hx "helix-editor/helix" "Helix"; then
        return
    fi
    print_info "Installing Helix..."

    local tag="" ver="" url=""

    tag=$(get_github_latest_version "helix-editor/helix")
    if [ -n "$tag" ]; then
        ver=$(echo "$tag" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || true)
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
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
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
    if tool_skip_check nexttrace "nxtrace/NTrace-core" "Nexttrace"; then
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
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
alias nt='nexttrace'
EOF
        chmod 644 /etc/profile.d/nexttrace-alias.sh
        print_success "Nexttrace installed (alias: nt)"
        rm -f "${TEMP_DIR}/nexttrace"
    else
        print_error "Nexttrace download failed"
    fi
}

MANIFEST_FILE="/var/lib/debian-init/manifest"
# Hidden backup directory under the root user's home
BACKUP_DIR="/root/.init-bak"
GENERATED_MARKER="Generated by: debian_init.sh"
CONFIG_TARGETS=()

# True when the file was created by this script (carries the marker header).
# Such files are refreshed on every run - never backed up.
is_script_generated() {
    [ -f "$1" ] || return 1
    grep -qF "$GENERATED_MARKER" "$1" 2>/dev/null
}

collect_config_targets() {
    CONFIG_TARGETS=(
        "$SYSCTL_NETWORK_FILE"
        "$SYSCTL_IPV6_FILE"
        "/etc/modules-load.d/network-optimized.conf"
        "/etc/modules-load.d/tcp_bbr.conf"
        "/etc/systemd/journald.conf.d/99-limit.conf"
        "/etc/systemd/system/disable-transparent-huge-pages.service"
        "/etc/profile.d/helix-alias.sh"
        "/etc/profile.d/nexttrace-alias.sh"
        "/etc/profile.d/cfspeed-alias.sh"
        "/etc/profile.d/eza-alias.sh"
        "/etc/profile.d/update-alias.sh"
        "/etc/profile.d/bat-alias.sh"
        "/etc/chrony/chrony.conf"
        "/etc/fail2ban/jail.local"
        "/etc/apt/apt.conf.d/50unattended-upgrades"
        "/etc/apt/apt.conf.d/20auto-upgrades"
    )
}

# Back up ONLY files this script did not generate (user-managed ones).
# Files with our marker are regenerated from scratch, so the "latest wins"
# philosophy applies and no backup is needed for them.
# Backups live in BACKUP_DIR (mirroring the original path) and keep only
# the most recent copy - older ones are replaced, never accumulated.
backup_config() {
    local f="$1"
    [ -f "$f" ] || return 0
    is_script_generated "$f" && return 0
    local rel="${f#/}"
    local bak="${BACKUP_DIR}/${rel}.bak"
    mkdir -p "$(dirname "$bak")"
    rm -f "$bak"
    if cp -a "$f" "$bak" 2>/dev/null; then
        print_info "User file backed up: $f -> $bak (latest only)"
    else
        print_warning "Failed to back up $f (continuing without backup)"
    fi
}

# Remove leftovers from older script versions (tracked via manifest), so
# that only the state of the current version stays active.
cleanup_stale_configs() {
    [ -f "$MANIFEST_FILE" ] || return 0
    print_section "${ICON_INFO} Stale config cleanup"
    local f removed=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        local t keep=0
        for t in "${CONFIG_TARGETS[@]}"; do
            if [ "$f" = "$t" ]; then
                keep=1
                break
            fi
        done
        [ "$keep" -eq 1 ] && continue
        [ -e "$f" ] || continue
        if is_script_generated "$f"; then
            rm -f "$f"
            print_warning "Removed stale config from a previous run: $f"
            removed=$((removed + 1))
        else
            print_warning "Manifest lists $f but it was modified outside this script - keeping it"
        fi
    done < "$MANIFEST_FILE"
    if [ "$removed" -eq 0 ]; then
        print_success "No stale configs found"
    fi
}

save_manifest() {
    mkdir -p "$(dirname "$MANIFEST_FILE")"
    : > "$MANIFEST_FILE"
    local t
    for t in "${CONFIG_TARGETS[@]}"; do
        [ -e "$t" ] && echo "$t" >> "$MANIFEST_FILE"
    done
}

preflight_config() {
    collect_config_targets
    mkdir -p /etc/sysctl.d
    print_section "${ICON_INFO} Config pre-check"
    print_info "Files this script will write (NEW / REFRESH / USER FILE):"

    local f new_count=0 refresh_count=0 user_count=0
    for f in "${CONFIG_TARGETS[@]}"; do
        if [ ! -e "$f" ]; then
            printf "  ${GREEN}%-10s${RESET} %s\n" "NEW" "$f"
            new_count=$((new_count + 1))
        elif is_script_generated "$f"; then
            printf "  ${CYAN}%-10s${RESET} %s\n" "REFRESH" "$f"
            refresh_count=$((refresh_count + 1))
        else
            printf "  ${YELLOW}%-10s${RESET} %s\n" "USER FILE" "$f"
            printf "      ${DIM}(not created by this script; backed up before overwriting)${RESET}\n"
            user_count=$((user_count + 1))
        fi
    done

    # Other files in sysctl.d are NOT touched, but will be applied together.
    local others
    others=$(find /etc/sysctl.d -maxdepth 1 -name '*.conf' -type f 2>/dev/null \
        | grep -vE "$(basename "$SYSCTL_NETWORK_FILE")|$(basename "$SYSCTL_IPV6_FILE")" || true)
    if [ -n "$others" ]; then
        print_info "Other configs in /etc/sysctl.d (kept, applied together):"
        while IFS= read -r f; do
            printf "  ${DIM}%s${RESET}\n" "$f"
        done <<< "$others"
    fi

    echo ""
    print_info "${new_count} new, ${refresh_count} refreshed (script-managed), ${user_count} user-managed"
    if [ "$user_count" -gt 0 ]; then
        print_info "User-managed files are overwritten directly; latest copy kept in ${BACKUP_DIR}"
    else
        print_success "No user-managed files affected"
    fi
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    case "$default" in
        y|Y|yes|Yes) default="y" ;;
        *) default="n" ;;
    esac
    local choice
    while true; do
        printf "${CYAN}${BOLD}>>> %s [default: %s] (y/yes, n/no): ${RESET}" "$prompt" "$default"
        read -r choice
        case "$choice" in
            y|Y|yes|Yes)
                print_info "Selected: y"
                return 0
                ;;
            n|N|no|No)
                print_info "Selected: n"
                return 1
                ;;
            "")
                if [ "$default" = "y" ]; then
                    print_info "Selected: y (default)"
                    return 0
                fi
                print_info "Selected: n (default)"
                return 1
                ;;
            *) echo "Please enter y/yes or n/no." ;;
        esac
    done
}

show_docker_status() {
    print_info "Checking Docker status..."
    if command_exists docker; then
        local docker_ver
        docker_ver=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || echo "?")
        print_kv "Docker" "${GREEN}already installed${RESET} (v${docker_ver})"
        return 1
    else
        print_kv "Docker" "${YELLOW}not installed${RESET}"
        return 0
    fi
}

install_docker() {
    print_info "Installing Docker..."
    if command_exists docker; then
        print_success "Docker already installed"
        return
    fi

    if curl -fsSL https://get.docker.com | sh; then
        print_success "Docker installed successfully"
        local docker_user="${SUDO_USER:-${USER:-}}"
        if [ -n "$docker_user" ] && [ "$docker_user" != "root" ]; then
            usermod -aG docker "$docker_user" 2>/dev/null || true
            print_info "Added '$docker_user' to docker group (re-login to take effect)"
        fi
    else
        print_error "Failed to install Docker"
    fi
}

# Returns 0 (ask user) when THP is not already disabled
show_thp_status() {
    print_info "Checking Transparent Huge Pages (THP) status..."
    local thp_enabled thp_defrag
    thp_enabled=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -oE '\[[^]]+\]' | tr -d '[]' || echo "unknown")
    thp_defrag=$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null | grep -oE '\[[^]]+\]' | tr -d '[]' || echo "unknown")
    print_kv "THP enabled" "$thp_enabled"
    print_kv "THP defrag" "$thp_defrag"

    if [ "$thp_enabled" = "never" ]; then
        print_success "THP already disabled"
        return 1
    fi
    if [ "$thp_enabled" = "unknown" ]; then
        print_warning "Cannot read THP status (not supported on this kernel?)"
        return 1
    fi
    return 0
}

disable_thp() {
    print_info "Disabling Transparent Huge Pages..."
    # sysfs values reset on reboot; persist via a systemd oneshot service.
    cat > /etc/systemd/system/disable-transparent-huge-pages.service <<'EOF'
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag'
[Install]
WantedBy=basic.target
EOF
    systemctl daemon-reload
    systemctl enable disable-transparent-huge-pages 2>/dev/null || true
    systemctl start disable-transparent-huge-pages 2>/dev/null || true
    print_success "THP disabled (persistent via systemd service)"
}

install_tools() {
    print_section "${ICON_TOOL} Tools setup"
    install_helix
    install_cf_speedtest
    install_nexttrace
    generate_update_tools_script
}

generate_update_tools_script() {
    cat > /usr/local/bin/update-tools <<'SCRIPT_EOF'
#!/bin/bash
# Generated by debian_init.sh - updates GitHub-sourced tools (Helix, Nexttrace, CF Speedtest)
# Runs independently; invoked by the system-wide "update" alias.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

TEMP_DIR=$(mktemp -d -p /var/tmp)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Architecture detection (self-contained)
case "$(uname -m)" in
    x86_64|amd64)  SYS_ARCH="x86_64"; ARCH_SUFFIX="amd64" ;;
    aarch64|arm64) SYS_ARCH="aarch64"; ARCH_SUFFIX="arm64" ;;
    *) echo "Unsupported architecture"; exit 1 ;;
esac

# ---- helpers ----
cmd_ok() { command -v "$1" >/dev/null 2>&1; }
get_ver() { "$@" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true; }

download_file() {
    curl -fsSL --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 \
        "$1" -o "$2" 2>/dev/null && [ -s "$2" ] && return 0
    rm -f "$2"
    return 1
}

ensure_xz()   { cmd_ok xz   || apt-get install -qq -y xz-utils >/dev/null 2>&1 || true; }
ensure_bzip2(){ cmd_ok bzip2|| apt-get install -qq -y bzip2 >/dev/null 2>&1 || true; }
ensure_unzip(){ cmd_ok unzip|| apt-get install -qq -y unzip >/dev/null 2>&1 || true; }

extract_archive() {
    case "$1" in
        *.tar.xz|*.txz)       ensure_xz    && tar -xJf "$1" -C "$2" ;;
        *.tar.gz|*.tgz)       tar -xzf "$1" -C "$2" ;;
        *.tar.bz2|*.tbz|*.tbz2) ensure_bzip2 && tar -xjf "$1" -C "$2" ;;
        *.zip)                ensure_unzip && unzip -q -o "$1" -d "$2" ;;
        *) return 1 ;;
    esac
}

github_latest_tag() {
    curl -sL --connect-timeout 5 --max-time 15 --retry 3 --retry-delay 1 \
        -o /dev/null -w '%{url_effective}' \
        "https://github.com/$1/releases/latest" 2>/dev/null \
        | grep -oE 'tag/[^/]+$' | sed 's#tag/##' || true
}

github_asset_url() {
    curl -sL --connect-timeout 5 --max-time 20 --retry 3 --retry-delay 1 \
        "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
        | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed -E 's/.*"([^"]+)"$/\1/' | grep -E "$2" | head -n1 || true
}

# ---- update functions ----

update_helix() {
    echo -e "${CYAN}[HELIX]${RESET} Checking..."
    local local_ver latest_tag latest_ver url
    if cmd_ok hx; then
        local_ver=$(get_ver hx --version)
        echo -e "  ${DIM}Installed:${RESET} ${local_ver:-?}"
    else
        echo -e "  ${YELLOW}Not installed, skipping${RESET}"
        return
    fi

    latest_tag=$(github_latest_tag "helix-editor/helix")
    latest_ver=$(echo "$latest_tag" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || true)
    if [ -z "$latest_tag" ] || [ -z "$latest_ver" ]; then
        echo -e "  ${YELLOW}Failed to check latest version${RESET}"
        return
    fi

    if [ "$local_ver" = "$latest_ver" ]; then
        echo -e "  ${GREEN}Already up to date (${latest_ver})${RESET}"
        return
    fi

    echo -e "  ${BOLD}Updating: ${local_ver:-?} → ${latest_ver}${RESET}"
    url="https://github.com/helix-editor/helix/releases/download/${latest_tag}/helix-${latest_ver}-${SYS_ARCH}-linux.tar.xz"
    if [ -z "$url" ] || ! download_file "$url" "${TEMP_DIR}/helix.tar.xz"; then
        url=$(github_asset_url "helix-editor/helix" "helix-.*-${SYS_ARCH}-linux\\.tar\\.xz\$")
        [ -z "$url" ] && { echo -e "  ${RED}No download URL found${RESET}"; return; }
        download_file "$url" "${TEMP_DIR}/helix.tar.xz" || { echo -e "  ${RED}Download failed${RESET}"; return; }
    fi

    extract_archive "${TEMP_DIR}/helix.tar.xz" "$TEMP_DIR" || { echo -e "  ${RED}Extract failed${RESET}"; return; }
    local helix_dir
    helix_dir=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "helix-*" -print -quit)
    if [ -n "$helix_dir" ] && [ -f "${helix_dir}/hx" ]; then
        install -m 755 "${helix_dir}/hx" /usr/local/bin/hx
        [ -d "${helix_dir}/runtime" ] && rm -rf /usr/local/lib/helix/runtime && mkdir -p /usr/local/lib/helix && cp -r "${helix_dir}/runtime" /usr/local/lib/helix/
        echo -e "  ${GREEN}Updated to ${latest_ver}${RESET}"
    else
        echo -e "  ${RED}Binary not found in archive${RESET}"
    fi
}

update_nexttrace() {
    echo -e "${CYAN}[NEXTTRACE]${RESET} Checking..."
    local local_ver latest_tag url
    if cmd_ok nexttrace; then
        local_ver=$(get_ver nexttrace --version)
        echo -e "  ${DIM}Installed:${RESET} ${local_ver:-?}"
    else
        echo -e "  ${YELLOW}Not installed, skipping${RESET}"
        return
    fi

    latest_tag=$(github_latest_tag "nxtrace/NTrace-core")
    if [ -z "$latest_tag" ]; then
        echo -e "  ${YELLOW}Failed to check latest version${RESET}"
        return
    fi

    # Compare version strings; skip if same
    local latest_ver
    latest_ver=$(echo "$latest_tag" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || true)
    if [ -n "$latest_ver" ] && [ "$local_ver" = "$latest_ver" ]; then
        echo -e "  ${GREEN}Already up to date (${latest_ver})${RESET}"
        return
    fi

    echo -e "  ${BOLD}Updating to ${latest_tag}${RESET}"
    url="https://github.com/nxtrace/NTrace-core/releases/latest/download/nexttrace_linux_${ARCH_SUFFIX}"
    if download_file "$url" "${TEMP_DIR}/nexttrace"; then
        install -m 755 "${TEMP_DIR}/nexttrace" /usr/local/bin/nexttrace
        echo -e "  ${GREEN}Updated${RESET}"
    else
        echo -e "  ${RED}Download failed${RESET}"
    fi
}

update_cf_speedtest() {
    echo -e "${CYAN}[CF-SPEED]${RESET} Checking..."
    local local_ver latest_tag latest_ver url
    if cmd_ok cloudflare-speed-cli; then
        local_ver=$(get_ver cloudflare-speed-cli --version)
        echo -e "  ${DIM}Installed:${RESET} ${local_ver:-?}"
    else
        echo -e "  ${YELLOW}Not installed, skipping${RESET}"
        return
    fi

    latest_tag=$(github_latest_tag "kavehtehrani/cloudflare-speed-cli")
    if [ -z "$latest_tag" ]; then
        echo -e "  ${YELLOW}Failed to check latest version${RESET}"
        return
    fi
    # Release tags are prefixed with 'v' (e.g. v0.6.2); strip it for comparison.
    latest_ver=$(echo "$latest_tag" | sed -E 's/^v//' | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || true)

    if [ -n "$latest_ver" ] && [ "$local_ver" = "$latest_ver" ]; then
        echo -e "  ${GREEN}Already up to date (${latest_ver})${RESET}"
        return
    fi

    echo -e "  ${BOLD}Updating: ${local_ver:-?} → ${latest_ver:-latest}${RESET}"
    url="https://github.com/kavehtehrani/cloudflare-speed-cli/releases/latest/download/cloudflare-speed-cli-${SYS_ARCH}-unknown-linux-musl.tar.xz"
    if download_file "$url" "${TEMP_DIR}/cfspeed.tar.xz"; then
        extract_archive "${TEMP_DIR}/cfspeed.tar.xz" "$TEMP_DIR" || { echo -e "  ${RED}Extract failed${RESET}"; return; }
        local binpath
        binpath=$(find "$TEMP_DIR" -type f -name "cloudflare-speed-cli*" -executable -print -quit 2>/dev/null || true)
        [ -z "$binpath" ] && binpath=$(find "$TEMP_DIR" -type f -name "cloudflare-speed-cli*" -print -quit 2>/dev/null || true)
        if [ -n "$binpath" ]; then
            install -m 755 "$binpath" /usr/local/bin/cloudflare-speed-cli
            echo -e "  ${GREEN}Updated to ${latest_ver:-latest}${RESET}"
        else
            echo -e "  ${RED}Binary not found in archive${RESET}"
        fi
    else
        echo -e "  ${YELLOW}Download failed (may already be latest)${RESET}"
    fi
}

# ---- main ----
echo ""
echo -e "${BOLD}${CYAN}▶ GitHub Tools Update${RESET}"
echo ""

update_helix
echo ""
update_nexttrace
echo ""
update_cf_speedtest

echo ""
echo -e "${GREEN}Done.${RESET}"

rm -rf "$TEMP_DIR"
SCRIPT_EOF
    chmod 755 /usr/local/bin/update-tools
    print_success "update-tools script generated (/usr/local/bin/update-tools)"
}

configure_eza_aliases() {
    if ! command_exists eza; then
        print_warning "eza not found, skipping eza aliases"
        return
    fi

    cat > /etc/profile.d/eza-alias.sh <<'EOF'
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
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

configure_update_alias() {
    cat > /etc/profile.d/update-alias.sh <<'EOF'
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
# System-wide alias: apt update + upgrade + autoremove + GitHub tools refresh
alias update='apt update && apt upgrade && apt autoremove -y && update-tools'
EOF
    chmod 644 /etc/profile.d/update-alias.sh
    print_success "Update alias configured (update -> apt update && apt upgrade && apt autoremove -y && update-tools)"
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
    backup_config "$CHRONY_CONF"
    cat > "$CHRONY_CONF" <<EOF
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
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

ensure_kernel_modules() {
    print_section "${ICON_TOOL} Kernel modules"
    local modules_conf="/etc/modules-load.d/network-optimized.conf"
    backup_config "$modules_conf"
    echo "# Generated by: debian_init.sh" > "$modules_conf"

    # nf_conntrack must be loaded BEFORE the sysctl config is written:
    # filter_sysctl_file drops keys that aren't visible in /proc/sys yet,
    # so without this step all net.netfilter.* keys would be skipped.
    if modprobe nf_conntrack >/dev/null 2>&1 || [ -d /proc/sys/net/netfilter ]; then
        echo "nf_conntrack" >> "$modules_conf"
        print_success "nf_conntrack ready (conntrack tuning will apply)"
    else
        print_warning "nf_conntrack unavailable; conntrack tuning keys will be skipped"
    fi

    # TLS offload (optional; only persisted when the module exists)
    if modprobe tls >/dev/null 2>&1; then
        echo "tls" >> "$modules_conf"
        print_success "tls module loaded (optional)"
    else
        print_info "tls module not available (optional, skipped)"
    fi
}

configure_journald() {
    print_section "${ICON_TOOL} Journald limits"
    local conf_dir="/etc/systemd/journald.conf.d"
    mkdir -p "$conf_dir"
    backup_config "${conf_dir}/99-limit.conf"
    # Cap journal growth to keep the system partition small.
    # rsyslog (installed by this script) keeps the full history in /var/log,
    # so nothing is lost by restricting journald itself.
    cat > "${conf_dir}/99-limit.conf" <<'EOF'
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
[Journal]
SystemMaxUse=384M
SystemMaxFileSize=128M
SystemMaxFiles=3
RuntimeMaxUse=256M
RuntimeMaxFileSize=128M
RuntimeMaxFiles=3
MaxRetentionSec=86400
MaxFileSec=259200
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    print_success "journald capped (384M / 1 day; rsyslog keeps full history)"
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

# List NICs that obtain IPv6 via SLAAC/RA: NICs holding an IPv6 default route
# plus NICs with a global IPv6 address (deduplicated, order preserved).
#
# Rationale: once net.ipv6.conf.all.forwarding=1 is applied, the kernel treats
# the host as a router: it ignores Router Advertisements (and stops sending
# Router Solicitations) on every interface whose OWN accept_ra is < 2.
# conf/all/accept_ra and conf/default/accept_ra do NOT propagate to
# interfaces that already exist (unlike forwarding, which does propagate from
# conf/all), so the physical NIC name must be written into the sysctl file
# explicitly, or SLAAC IPv6 breaks after the next reboot.
detect_slaac_nics() {
    {
        ip -6 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); break } }'
        ip -6 -o addr show scope global 2>/dev/null | awk '{print $2}'
    } | awk '!seen[$0]++ && NF'
}

generate_sysctl_content() {
    local mem_mb=$((MEM_KB / 1024))

    # tcp_mem is expressed in pages; scale with RAM (12% / 50% / 70% of total pages)
    local page_size total_pages tcp_mem_min tcp_mem_pressure tcp_mem_max
    page_size=$(getconf PAGESIZE 2>/dev/null || echo 4096)
    total_pages=$((MEM_KB * 1024 / page_size))
    tcp_mem_min=$((total_pages / 100 * 12))
    tcp_mem_pressure=$((total_pages / 100 * 50))
    tcp_mem_max=$((total_pages / 100 * 70))

    # Conntrack table sized by RAM (each entry costs ~300-350 bytes)
    local conntrack_max
    if [ "$mem_mb" -lt 1024 ]; then
        conntrack_max=131072
    elif [ "$mem_mb" -lt 4096 ]; then
        conntrack_max=262144
    else
        conntrack_max=524288
    fi

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

# ============================================================================
# Forwarding (proxy / NAT gateway ready)
# ============================================================================
net.ipv4.ip_forward = 1
# Loose mode reverse path filtering: compatible with asymmetric routing
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# ============================================================================
# Fast Failover (aggressive dead-connection detection, proxy-friendly)
# ============================================================================
# Reboot 1s after kernel panic instead of hanging
kernel.panic = 1
# Detect dead peers within ~126s (120s idle + 2 probes * 3s)
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 3
net.ipv4.tcp_keepalive_probes = 2
# Fail fast on unresponsive hosts
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_retries1 = 2
net.ipv4.tcp_retries2 = 2

# ============================================================================
# TCP Memory (auto-scaled to RAM: 12% / 50% / 70% of total pages)
# ============================================================================
net.ipv4.tcp_mem = ${tcp_mem_min} ${tcp_mem_pressure} ${tcp_mem_max}

# ============================================================================
# Conntrack (requires nf_conntrack module; loaded before this config is written)
# ============================================================================
net.netfilter.nf_conntrack_max = ${conntrack_max}
# Aggressive expiry keeps the table small on busy NAT/proxy boxes
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_close = 5
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 5
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 5
net.netfilter.nf_conntrack_tcp_timeout_max_retrans = 5
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 5
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 5
net.netfilter.nf_conntrack_tcp_timeout_unacknowledged = 5
net.netfilter.nf_conntrack_udp_timeout = 5
net.netfilter.nf_conntrack_udp_timeout_stream = 60
net.netfilter.nf_conntrack_icmp_timeout = 5
net.netfilter.nf_conntrack_icmpv6_timeout = 5
net.netfilter.nf_conntrack_generic_timeout = 10
net.netfilter.nf_conntrack_gre_timeout = 5
net.netfilter.nf_conntrack_gre_timeout_stream = 30

SYSCTL

    # IPv6 forwarding only when IPv6 is present; accept_ra=2 keeps SLAAC
    # working on providers that assign IPv6 via router advertisements.
    if [ -n "${IPV6_ADDR:-}" ] && [ "${IPV6_ADDR}" != "N/A" ]; then
        # Interfaces that already exist (e.g. eth0) do not inherit
        # conf/all or conf/default accept_ra; each needs its own
        # accept_ra=2, otherwise RAs are dropped once forwarding is on
        # and IPv6 breaks after the next reboot.
        local slaac_nics nic
        slaac_nics=$(detect_slaac_nics)

        cat <<SYSCTL
# ============================================================================
# IPv6 Forwarding (IPv6 detected at install time)
# ============================================================================
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
# Keep accepting RAs while forwarding is enabled (required for SLAAC).
# NOTE: conf/all and conf/default do NOT propagate accept_ra to interfaces
# that already exist when sysctl.d runs at boot; the per-interface lines
# below are what actually keeps SLAAC alive on the physical NIC.
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
SYSCTL
        for nic in $slaac_nics; do
            echo "net.ipv6.conf.${nic}.accept_ra = 2"
        done
        echo ""
    fi

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
    backup_config "$SYSCTL_NETWORK_FILE"
    : > "$SYSCTL_NETWORK_FILE"
    filter_sysctl_file "$tmpfile" "$SYSCTL_NETWORK_FILE"

    print_success "Network tuning config written to $SYSCTL_NETWORK_FILE"
}

apply_ipv6_sysctl() {
    mkdir -p /etc/sysctl.d
    if [ "$DISABLE_IPV6" -eq 1 ]; then
        backup_config "$SYSCTL_IPV6_FILE"
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

show_ipv6_status() {
    print_info "Checking IPv6 status..."
    print_kv "IPv6" "$(ipv6_status_text)"
}

# Populates CURRENT_KERNEL / LATEST_KERNEL (latest installed vs running).
detect_kernel_versions() {
    CURRENT_KERNEL=$(uname -r)
    # xargs -r: don't run basename on empty input; || true: glob miss must
    # not kill the script (set -e + pipefail would abort on ls failure).
    LATEST_KERNEL=$(ls -1vr /boot/vmlinuz* 2>/dev/null | head -n1 | xargs -r -n1 basename 2>/dev/null | sed 's/vmlinuz-//' || true)
}

# Single source of truth for the IPv6 status line (interactive check + report).
ipv6_status_text() {
    local ipv6_sysctl
    ipv6_sysctl=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    if [ "$ipv6_sysctl" = "1" ]; then
        echo "${RED}disabled by sysctl${RESET}"
    elif [ -n "${IPV6_ADDR:-}" ] && [ "${IPV6_ADDR}" != "N/A" ]; then
        echo "${GREEN}working${RESET} (${IPV6_ADDR})"
    elif [ -n "${IPV6_STATUS:-}" ]; then
        echo "${YELLOW}${IPV6_STATUS}${RESET}"
    else
        echo "${YELLOW}not assigned by provider${RESET}"
    fi
}

show_kernel_info() {
    print_info "Checking kernel status..."

    # Cloud Kernel is tailored for virtualized environments and omits many
    # hardware drivers; warn before installing on bare metal.
    local virt
    virt=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    if [ "$virt" = "none" ] || [ "$virt" = "unknown" ]; then
        print_warning "Detected bare-metal/unknown environment ($virt). Cloud Kernel omits many hardware drivers and may break networking/storage on physical machines."
    fi

    local current_kernel latest_kernel
    detect_kernel_versions
    current_kernel="$CURRENT_KERNEL"
    latest_kernel="$LATEST_KERNEL"

    print_kv "Current Kernel" "$current_kernel"
    if [ -n "$latest_kernel" ] && [ "$latest_kernel" != "$current_kernel" ]; then
        print_kv "Latest Installed" "$latest_kernel (will load on reboot)"
    fi

    # Check if cloud kernel package is already installed
    if dpkg -l "linux-image-cloud-${ARCH_DEB}" 2>/dev/null | grep -q "^ii"; then
        print_success "Cloud Kernel already installed"
        return 1
    fi
    return 0
}

install_cloud_kernel() {
    echo ""
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
    apt-get install -y -o=Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold rsyslog openssl gnupg cron chrony fail2ban python3-systemd logrotate nano vnstat nload htop unzip unattended-upgrades eza duf bat zoxide || print_warning "Some base packages failed to install"

    # Debian ships bat as batcat on some releases; expose it through a shell alias.
    cat > /etc/profile.d/bat-alias.sh <<'EOF'
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
# Only alias bat to batcat when the real `bat` binary is not installed.
command -v bat >/dev/null 2>&1 || alias bat='batcat'
EOF
    chmod 644 /etc/profile.d/bat-alias.sh
    print_success "bat alias configured (bat -> batcat)"

    # Ensure rsyslog is enabled and started
    systemctl enable --now rsyslog 2>/dev/null || true

    # Configure Fail2Ban (systemd backend)
    backup_config /etc/fail2ban/jail.local
    cat > /etc/fail2ban/jail.local <<EOF
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
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

    # Configure unattended-upgrades for security updates only.
    # The Origins-Pattern must reference the real suite (e.g. trixie-security);
    # a literal ${...} placeholder would silently match nothing, so the
    # codename is read from os-release and the heredoc must stay UNQUOTED.
    local distro_codename
    distro_codename=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")
    distro_codename=${distro_codename:-trixie}
    backup_config /etc/apt/apt.conf.d/50unattended-upgrades
    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
// Generated by: debian_init.sh
// Do not edit manually - changes may be overwritten
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

    # Enable automatic updates
    backup_config /etc/apt/apt.conf.d/20auto-upgrades
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// Generated by: debian_init.sh
// Do not edit manually - changes may be overwritten
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    print_success "Base packages installed"
}

apply_all_sysctl() {
    # Ensure BBR module is available before applying congestion control settings.
    modprobe tcp_bbr 2>/dev/null || true
    backup_config /etc/modules-load.d/tcp_bbr.conf
    { echo "# Generated by: debian_init.sh"; echo "tcp_bbr"; } > /etc/modules-load.d/tcp_bbr.conf 2>/dev/null || true

    # Sanity check: with IPv6 forwarding enabled, every SLAAC NIC must carry
    # its own accept_ra=2 (conf/all and conf/default never propagate to
    # interfaces that already exist, e.g. eth0).
    if [ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)" = "1" ]; then
        local nic nic_ra
        for nic in $(detect_slaac_nics); do
            nic_ra=$(sysctl -n "net.ipv6.conf.${nic}.accept_ra" 2>/dev/null || echo "?")
            if [ "$nic_ra" != "2" ]; then
                print_warning "${nic}: accept_ra=${nic_ra} while IPv6 forwarding is on; SLAAC IPv6 will break after reboot"
            fi
        done
    fi

    local err
    err=$(sysctl --system 2>&1 >/dev/null || true)
    if [ -n "$err" ]; then
        print_warning "sysctl reported issues (may be harmless on this kernel):"
        echo "$err" | sed 's/^/    /'
    fi
    BBR_APPLIED=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    QDISC_APPLIED=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    print_success "sysctl applied (BBR: $BBR_APPLIED, qdisc: $QDISC_APPLIED)"
    if [ "$BBR_APPLIED" != "bbr" ]; then
        print_warning "BBR not active (got: $BBR_APPLIED). Kernel may lack tcp_bbr module."
    fi
}

show_report() {
    print_section "${ICON_DONE} Summary"

    print_subsection "Network"
    print_kv "BBR" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    print_kv "Queueing" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
    local ct_count ct_max
    ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "-")
    ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "-")
    print_kv "Conntrack" "${ct_count} / ${ct_max}"
    local thp_mode
    thp_mode=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -oE '\[[^]]+\]' | tr -d '[]' || echo "?")
    print_kv "THP" "$thp_mode"

    print_kv "IPv6" "$(ipv6_status_text)"
    echo ""

    print_subsection "Sysctl configs"
    print_info "sysctl configs:"
    [ -f "$SYSCTL_NETWORK_FILE" ] && echo -e "  ${GREEN}*${RESET} $SYSCTL_NETWORK_FILE"
    [ -f "$SYSCTL_IPV6_FILE" ] && echo -e "  ${GREEN}*${RESET} $SYSCTL_IPV6_FILE"
    print_info "Config backups (user files, latest only):"
    echo -e "  ${GREEN}*${RESET} $BACKUP_DIR"
    echo ""

    print_subsection "Services"
    print_kv "Chrony" "$(systemctl is-active chrony 2>/dev/null || echo '?')"
    print_kv "Fail2Ban" "$(systemctl is-active fail2ban 2>/dev/null || echo '?')"
    print_kv "Timezone" "${TIMEZONE_FINAL:-unknown}"

    print_subsection "Auto updates"
    local auto_updates=""
    if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ] && \
       grep -q 'codename=.*-security' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
        auto_updates="security"
    fi
    if [ -n "$auto_updates" ]; then
        print_kv "Auto-updates" "${GREEN}${auto_updates}${RESET}"
    else
        print_kv "Auto-updates" "${YELLOW}not configured${RESET}"
    fi
    echo ""

    print_subsection "Tools"
    print_info "Installed tools:"
    get_ver() {
        "$@" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true
    }

    local tools=""
    command -v eza >/dev/null && tools+="  eza $(get_ver eza --version)\n"
    command -v hx >/dev/null && tools+="  helix $(get_ver hx --version)\n"
    command -v cloudflare-speed-cli >/dev/null && tools+="  cloudflare-speed-cli $(get_ver cloudflare-speed-cli --version)\n"
    command -v duf >/dev/null && tools+="  duf $(get_ver duf --version)\n"
    if command -v bat >/dev/null; then
        tools+="  bat $(get_ver bat --version)\n"
    elif command -v batcat >/dev/null; then
        tools+="  bat $(get_ver batcat --version)\n"
    fi
    command -v zoxide >/dev/null && tools+="  zoxide $(get_ver zoxide --version)\n"
    command -v nexttrace >/dev/null && tools+="  nexttrace $(get_ver nexttrace --version)\n"
    [ -n "$tools" ] && echo -e "$tools" || echo "  (none)"
    echo ""

    print_subsection "Kernel"
    detect_kernel_versions
    print_kv "Current Kernel" "$CURRENT_KERNEL"
    if [ -n "$LATEST_KERNEL" ] && [ "$LATEST_KERNEL" != "$CURRENT_KERNEL" ]; then
        print_kv "Latest Kernel" "$LATEST_KERNEL (will load on reboot)"
    fi
    echo ""

    print_success "All steps complete. Reboot recommended for full effect."
    echo ""

    # Source aliases
    # shellcheck disable=SC1090
    for f in /etc/profile.d/*.sh; do
        [ -r "$f" ] && . "$f" 2>/dev/null || true
    done
    print_info "If aliases (cf, nt, vi, ll etc.) don't work, run: ${BOLD}source /etc/profile${RESET} or re-login."
}

main() {
    # clear fails when TERM is unset (e.g. running via curl | bash with no
    # TTY); under set -e that would abort the script before anything runs.
    clear || true
    require_root
    require_debian
    ensure_basic_tools
    fetch_ipinfo
    detect_system
    show_detection

    preflight_config
    cleanup_stale_configs

    apt_refresh
    install_tools
    install_base_packages
    configure_eza_aliases
    configure_update_alias
    configure_chrony
    ensure_kernel_modules
    apply_network_sysctl
    configure_journald

    if [ -n "${IPV6_ADDR:-}" ] && [ "${IPV6_ADDR}" != "N/A" ]; then
        apply_ipv6_sysctl
    else
        print_info "IPv6 not detected, skipping IPv6 configuration."
    fi

    apply_all_sysctl

    print_section "${ICON_TOOL} Optional components"

    # Show kernel info first, then ask
    if show_kernel_info; then
        if ask_yes_no "Install Cloud Kernel?"; then
            install_cloud_kernel
        fi
    fi

    # Show docker status first, then ask
    if show_docker_status; then
        if ask_yes_no "Install Docker?"; then
            install_docker
        fi
    fi

    # Show THP status first, then ask (default: disable)
    if show_thp_status; then
        if ask_yes_no "Disable Transparent Huge Pages (THP)?" y; then
            disable_thp
        fi
    fi

    # Show IPv6 status first, then ask
    show_ipv6_status
    if [ -n "${IPV6_ADDR:-}" ] && [ "${IPV6_ADDR}" != "N/A" ]; then
        if ask_yes_no "Disable IPv6?"; then
            DISABLE_IPV6=1
            print_info "Disabling IPv6..."
            apply_ipv6_sysctl
            sysctl --system >/dev/null 2>&1 || true
        fi
    fi

    save_manifest

    show_report
}

main "$@"
