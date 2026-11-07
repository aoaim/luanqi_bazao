#!/bin/bash

# Debian 13+ initialization script
# Performs environment detection, tool installation, timezone configuration, and kernel tuning
# Update: 26/11/07

set -Eeuo pipefail

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
        printf '  [FAIL] Unsupported architecture: %s\n' "$(uname -m)" >&2
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
trap 'report_failure "$?" "$LINENO"' ERR
trap cleanup_temp EXIT
trap 'cleanup_temp; exit 1' INT TERM

APT_INDEX_READY=0
DOCKER_ACTION="keep"
KERNEL_BOOT_PENDING=0
THP_SELECTED=""
THP_DEFRAG_SELECTED=""
UI_SECTION=0
UI_PHASE="Starting"
UI_DETAIL=0
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'
if [ ! -t 1 ] || [ -n "${NO_COLOR+x}" ] || [ "${TERM:-}" = dumb ]; then
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; DIM=""; RESET=""
fi

print_section() {
    UI_SECTION=$((UI_SECTION + 1))
    UI_PHASE=${1# }
    UI_DETAIL=0
    printf '\n%s%s%02d · %s%s\n' "$BLUE" "$BOLD" "$UI_SECTION" "$UI_PHASE" "$RESET"
}
print_status() {
    local indent='  '
    [ "$UI_DETAIL" -eq 0 ] || indent='    '
    printf '%s%s%-6s%s %s\n' "$indent" "$1" "$2" "$RESET" "$3"
}
print_success() { print_status "$GREEN" '[OK]' "$1"; }
print_warning() { print_status "$YELLOW" '[WARN]' "$1"; }
print_error() { print_status "$RED" '[FAIL]' "$1" >&2; }
print_info() { print_status "$CYAN" '[INFO]' "$1"; }
print_subsection() { UI_DETAIL=1; printf '\n  %s%s%s\n' "$BOLD" "$1" "$RESET"; }
print_kv() {
    local indent='  '
    [ "$UI_DETAIL" -eq 0 ] || indent='    '
    printf '%s%-28s %s\n' "$indent" "$1" "$2"
}

init_ui() {
    printf '%s%sDebian initialization%s\n' "$BLUE" "$BOLD" "$RESET"
}

# Keep output on the terminal. Temporary captures only allow indentation and
# are removed immediately; no diagnostic log file is created.
run_step() {
    local detail=1 display=1 label capture status
    case "${1:-}" in
        --quiet) detail=0; shift ;;
        --silent) detail=0; display=0; shift ;;
    esac
    label="$1"; shift
    capture=$(mktemp "${TEMP_DIR}/command.XXXXXX") || return 1
    if [ "$display" -eq 1 ]; then printf '    %-43s ' "${label}..."; fi
    if "$@" > "$capture" 2>&1; then
        if [ "$display" -eq 1 ]; then printf '%s[OK]%s\n' "$GREEN" "$RESET"; fi
        if [ "$detail" -eq 1 ]; then
            # Drop repetitive progress and service compatibility boilerplate,
            # while retaining package changes, warnings and other details.
            sed -E '/^(Reading package lists|Building dependency tree|Reading state information|Synchronizing state of |Executing: .*systemd-sysv-install|OK: configuration test is successful)/d; /^[[:space:]]*$/d; s/^/      /' "$capture"
        elif grep -Eq '(^|[[:space:]])(WARNING|Warning:|W:|ERROR|Error:)|[Dd]eprecated' "$capture"; then
            print_warning "$label reported a note:"
            grep -E '(^|[[:space:]])(WARNING|Warning:|W:|ERROR|Error:)|[Dd]eprecated' "$capture" | sed 's/^/      /'
        fi
        rm -f "$capture"
        return 0
    else
        status=$?
        if [ "$display" -eq 1 ]; then printf '%s[FAIL]%s\n' "$RED" "$RESET"; else print_error "$label failed (exit $status)."; fi
        if [ -s "$capture" ]; then
            printf '\n    Command output:\n' >&2
            sed 's/^/      /' "$capture" >&2
            printf '\n' >&2
        fi
        rm -f "$capture"
        return "$status"
    fi
}
report_failure() {
    printf '\n' >&2
    print_error "RESULT: Configuration stopped"
    print_kv 'Failed step' "${UI_PHASE:-initialization} (line $2, exit $1)" >&2
    print_info "Completed steps remain applied. Errors are shown above; no log file is required."
}

refresh_apt_indexes() {
    if [ "$APT_INDEX_READY" -eq 0 ]; then
        run_step 'Refreshing package indexes' apt-get update -qq || return 1
        APT_INDEX_READY=1
    fi
}

# Persistent choices are data, never sourced as shell code. Config files
# remain fully generated; this state only records the user's selection.
BUFFER_STATE_FILE="/var/lib/debian-init/buffer-profile.conf"
KERNEL_RESET_FILE="/var/lib/debian-init/kernel-reset.boot-id"
BUFFER_PROFILE="default"
BUFFER_TARGET_MBPS="unknown"
BUFFER_RTT_MS="unknown"
BUFFER_STATE_LOADED=0
BUFFER_REASSESS=0
BUFFER_CLI_PROFILE=""
BUFFER_CLI_MBPS=""
PROBE_TARGETS=()
KERNEL_RESET_REQUIRED=0

print_usage() {
    cat <<'USAGE'
Debian initialization
Usage: bash debian_init.sh [options]
  --reassess-buffers          Measure and choose a buffer profile again
  --buffer-profile PROFILE   Explicit choice: default, 32m or 64m
  --target-mbps RATE          Target rate for one TCP connection (1..100000)
  --probe-target HOST         Business peer to probe; may be repeated (max 5)
  --help                     Show this help without changing the system
Existing choices are reused unless reassessment or a profile is requested.
Without a terminal, a first run uses system-default buffers unless explicitly set.
USAGE
}

valid_target_rate() {
    [[ "$1" =~ ^[1-9][0-9]{0,5}$ ]] && [ "$1" -le 100000 ]
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --reassess-buffers) BUFFER_REASSESS=1; shift ;;
            --buffer-profile|--target-mbps|--probe-target)
                [ "$#" -ge 2 ] || { print_error "Missing value for $1"; return 1; }
                case "$1" in
                    --buffer-profile)
                        case "$2" in default|32m|64m) BUFFER_CLI_PROFILE="$2" ;; *) print_error "Profile must be default, 32m or 64m."; return 1 ;; esac ;;
                    --target-mbps)
                        valid_target_rate "$2" || { print_error "Target rate must be 1..100000 Mbps."; return 1; }
                        BUFFER_CLI_MBPS="$2" ;;
                    --probe-target)
                        [[ "$2" =~ ^[a-zA-Z0-9:][a-zA-Z0-9.:%_-]*$ ]] || { print_error "Invalid probe target: $2"; return 1; }
                        [ "${#PROBE_TARGETS[@]}" -lt 5 ] || { print_error "At most five probe targets are allowed."; return 1; }
                        PROBE_TARGETS+=("$2") ;;
                esac
                shift 2 ;;
            --help|-h) print_usage; exit 0 ;;
            *) print_error "Unknown option: $1"; print_usage; return 1 ;;
        esac
    done
    if [ -n "$BUFFER_CLI_MBPS" ] || [ "${#PROBE_TARGETS[@]}" -gt 0 ]; then BUFFER_REASSESS=1; fi
}

can_prompt() { { : < /dev/tty; } 2>/dev/null; }

read_tty_value() {
    local __dest="$1" __prompt="$2" __input
    printf '    %s%s%s ' "$CYAN" "$__prompt" "$RESET"
    if ! { read -r __input < /dev/tty; } 2>/dev/null; then
        print_warning "Terminal input ended; keeping the previous choice."
        return 1
    fi
    printf -v "$__dest" '%s' "$__input"
}

load_buffer_state() {
    [ -f "$BUFFER_STATE_FILE" ] || return 0
    local key value profile="" rate="unknown" rtt="unknown"
    while IFS='=' read -r key value || [ -n "$key" ]; do
        case "$key" in
            profile) profile="$value" ;;
            target_mbps) rate="$value" ;;
            rtt_ms) rtt="$value" ;;
            ''|'#'*) ;;
            *) print_error "Invalid buffer state field: $key"; return 1 ;;
        esac
    done < "$BUFFER_STATE_FILE"
    case "$profile" in default|32m|64m) ;; *) print_error "Invalid saved buffer profile; supply --buffer-profile to replace it."; return 1 ;; esac
    [ "$rate" = unknown ] || valid_target_rate "$rate" || return 1
    [[ "$rtt" == unknown || "$rtt" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    BUFFER_PROFILE="$profile"; BUFFER_TARGET_MBPS="$rate"; BUFFER_RTT_MS="$rtt"
    BUFFER_STATE_LOADED=1
}

save_buffer_state() {
    local staged
    mkdir -p "$(dirname "$BUFFER_STATE_FILE")" || return 1
    staged=$(mktemp "${BUFFER_STATE_FILE}.tmp.XXXXXX") || return 1
    if ! printf 'profile=%s\ntarget_mbps=%s\nrtt_ms=%s\n' "$BUFFER_PROFILE" "$BUFFER_TARGET_MBPS" "$BUFFER_RTT_MS" > "$staged" ||
       ! chmod 600 "$staged" || ! chown root:root "$staged" || ! mv -fT "$staged" "$BUFFER_STATE_FILE"; then
        rm -f "$staged"; print_error "Cannot save buffer profile."; return 1
    fi
}

profile_allowed() {
    local mem_mb=$((MEM_KB / 1024))
    case "$1" in
        default) return 0 ;;
        32m) [ "$mem_mb" -ge 1024 ] ;;
        64m) [ "$mem_mb" -ge 2048 ] ;;
        *) return 1 ;;
    esac
}

buffer_profile_label() {
    case "$BUFFER_PROFILE" in
        default) printf 'System default' ;;
        32m) printf 'Long-distance transfer / 32 MiB' ;;
        64m) printf 'Long-distance transfer / 64 MiB' ;;
    esac
}

# Coarse sizing heuristic, not a performance guarantee: 2 x bandwidth-delay
# product, rounded up to a supported cap. A low BDP needs no raised cap.
recommend_buffer_profile() {
    local rate="$1" rtt="$2" mem_mb="$3" need
    if [ "$rate" = unknown ] || [ "$rtt" = unknown ] || [ "$mem_mb" -lt 1024 ]; then echo default; return; fi
    need=$(awk -v rate="$rate" -v rtt="$rtt" 'BEGIN { printf "%.3f", 2 * rate * rtt / 8 / 1048.576 }')
    if awk -v n="$need" 'BEGIN { exit !(n <= 6) }'; then echo default
    elif awk -v n="$need" 'BEGIN { exit !(n <= 32) }'; then echo 32m
    elif [ "$mem_mb" -ge 2048 ]; then echo 64m
    else echo 32m
    fi
}

probe_buffer_targets() {
    local target file samples median loss jitter received count=0 best="unknown"
    if [ "${#PROBE_TARGETS[@]}" -eq 0 ]; then
        PROBE_TARGETS=(www.baidu.com www.qq.com www.aliyun.com)
        print_info "Reference destinations in China; these may not match your actual proxy route."
    else
        print_info "Using the specified business peers as the RTT reference."
    fi
    printf '\n    %-24s %8s %13s %12s %12s\n' 'Target' 'Replies' 'Median RTT' 'Probe loss' 'Jitter'
    for target in "${PROBE_TARGETS[@]}"; do
        count=$((count + 1)); file="${TEMP_DIR}/probe-${count}.log"
        # Bound DNS lookup as well as echo replies; ping's own deadline
        # alone does not reliably bound name resolution.
        LC_ALL=C timeout -k 1s 8s ping -n -c 5 -i 0.2 -W 1 -w 6 -- "$target" > "$file" 2>&1 || true
        samples=$(sed -nE 's/.*time[=<]([0-9]+([.][0-9]+)?).*/\1/p' "$file" | sort -n)
        received=$(printf '%s\n' "$samples" | awk 'NF { n++ } END { print n+0 }')
        loss=$(sed -nE 's/.* ([0-9]+([.][0-9]+)?)% packet loss.*/\1/p' "$file" | tail -n1)
        jitter=$(awk -F' = ' '/^(rtt|round-trip)/ { split($2,a,"/"); split(a[4],b," "); print b[1] }' "$file")
        if [ "$received" -lt 3 ] || [ -z "$loss" ]; then
            printf '    %-24s %8s %13s %12s %12s\n' "$target" "$received / 5" 'Unusable' "${loss:-?}%" '-'
            continue
        fi
        median=$(printf '%s\n' "$samples" | awk 'NF { a[++n]=$1 } END { if (n%2) printf "%.2f",a[(n+1)/2]; else printf "%.2f",(a[n/2]+a[n/2+1])/2 }')
        printf '    %-24s %8s %13s %12s %12s\n' "$target" "$received / 5" "$median ms" "$loss%" "${jitter:-?} ms"
        # ICMP loss is only a probe result, not a TCP loss measurement.
        # Incomplete probes inform the report but not buffer sizing.
        if awk -v loss="$loss" 'BEGIN { exit !(loss <= 20) }'; then
            if [ "$best" = unknown ] || awk -v a="$median" -v b="$best" 'BEGIN { exit !(a>b) }'; then best="$median"; fi
        fi
    done
    BUFFER_MEASURED_RTT="$best"
    print_info "ICMP results are advisory; they do not measure TCP loss or available bandwidth."

}

configure_buffers() {
    if [ -z "$BUFFER_CLI_PROFILE" ]; then load_buffer_state || return 1; fi
    if [ -n "$BUFFER_CLI_PROFILE" ]; then
        BUFFER_PROFILE="$BUFFER_CLI_PROFILE"
        BUFFER_TARGET_MBPS="${BUFFER_CLI_MBPS:-unknown}"
        BUFFER_RTT_MS=unknown
        print_info "Using the explicitly requested profile."
    elif [ "$BUFFER_STATE_LOADED" -eq 1 ] && [ "$BUFFER_REASSESS" -eq 0 ]; then
        print_info "Using the saved choice; no measurement or automatic profile change."
    elif ! can_prompt; then
        print_info "No interactive terminal; using the saved choice or system-default buffers."
    else
        local answer rate="${BUFFER_CLI_MBPS:-unknown}" recommended choice peer=""

        if [ "${#PROBE_TARGETS[@]}" -eq 0 ]; then
            if ! read_tty_value peer 'Business peer host/IP [Enter: reference sites in China]:'; then return 0; fi
            if [ -n "$peer" ]; then
                [[ "$peer" =~ ^[a-zA-Z0-9:][a-zA-Z0-9.:%_-]*$ ]] || { print_error "Invalid peer address."; return 1; }
                PROBE_TARGETS=("$peer")
            fi
        fi
        probe_buffer_targets
        if [ "$BUFFER_MEASURED_RTT" = unknown ]; then
            print_warning "No usable RTT reference; keeping the saved profile or system defaults."
            return 0
        fi
        if [ -z "$BUFFER_CLI_MBPS" ]; then
            print_subsection 'Target rate per TCP connection'
            printf '    1) Unknown — system-default recommendation\n    2) 100 Mbps\n    3) 200 Mbps\n    4) 500 Mbps\n    5) 1000 Mbps\n    6) Custom\n' 
            while true; do
                if ! read_tty_value answer 'Target [1]:'; then return 0; fi
                case "$answer" in
                    ''|1) rate=unknown; break ;;
                    2) rate=100; break ;;
                    3) rate=200; break ;;
                    4) rate=500; break ;;
                    5) rate=1000; break ;;
                    6)
                        if ! read_tty_value answer 'Custom target in Mbps (1..100000):'; then return 0; fi
                        if valid_target_rate "$answer"; then rate="$answer"; break; fi
                        print_warning "Enter a whole number from 1 to 100000." ;;
                    *) print_warning "Choose 1, 2, 3, 4, 5 or 6." ;;
                esac
            done
        fi
        recommended=$(recommend_buffer_profile "$rate" "$BUFFER_MEASURED_RTT" "$((MEM_KB / 1024))")
        if [ "$BUFFER_MEASURED_RTT" = unknown ]; then print_kv 'Reference RTT' 'Not measured reliably'; else print_kv 'Reference RTT' "${BUFFER_MEASURED_RTT} ms"; fi
        if [ "$rate" = unknown ]; then print_kv 'Target per connection' 'Not specified'; else print_kv 'Target per connection' "$rate Mbps"; fi
        print_kv 'Recommended profile' "${GREEN}${recommended}${RESET}"
        if [ "$recommended" = default ]; then print_info "Insufficient sizing evidence, low BDP or limited RAM: prefer system defaults."; fi
        if [ "$BUFFER_MEASURED_RTT" != unknown ] && [ "$rate" != unknown ]; then
            local need
            need=$(awk -v r="$rate" -v t="$BUFFER_MEASURED_RTT" 'BEGIN { printf "%.1f",2*r*t/8/1048.576 }')
            print_kv '2 x BDP allowance' "$need MiB"
            if awk -v n="$need" 'BEGIN { exit !(n > 64) }'; then print_warning "The estimate exceeds 64 MiB; this script's profiles cannot promise the target rate."; fi
        fi
        local suggested=1
        case "$recommended" in 32m) suggested=2 ;; 64m) suggested=3 ;; esac
        printf '\n    1) System default\n    2) 32 MiB\n    3) 64 MiB\n'
        while true; do
            if ! read_tty_value choice "Select [$suggested, ? for explanation]:"; then return 0; fi
            choice=${choice:-$suggested}
            case "$choice" in
                1|default) choice=default ;;
                2|32m) choice=32m ;;
                3|64m) choice=64m ;;
                '?')
                    print_info 'Sizing uses the highest reliable median RTT and a coarse 2× bandwidth-delay allowance.'
                    print_info 'Targets with fewer than 3 replies or ICMP loss above 20% are excluded.'
                    print_info 'Caps permit growth, not preallocation. They do not guarantee throughput or safety under high concurrency.'
                    print_info '32 MiB requires at least 1 GiB RAM; 64 MiB requires at least 2 GiB. Unknown bandwidth recommends defaults.'
                    continue ;;
                *) print_warning 'Choose 1, 2, 3 or ?.'; continue ;;
            esac
            if profile_allowed "$choice"; then break; fi
            print_warning 'This profile exceeds the script RAM guard; choose a smaller profile.'
        done
        BUFFER_PROFILE="$choice"; BUFFER_TARGET_MBPS="$rate"; BUFFER_RTT_MS="$BUFFER_MEASURED_RTT"
    fi
    profile_allowed "$BUFFER_PROFILE" || { print_error "Saved/requested buffer profile exceeds the script's RAM guard; reassess it."; return 1; }
    print_kv 'Selected profile' "$(buffer_profile_label)"

}

track_kernel_default_reset() {
    local boot previous="" removed=0
    boot=$(cat /proc/sys/kernel/random/boot_id) || return 1
    if [ -f "$KERNEL_RESET_FILE" ]; then
        previous=$(cat "$KERNEL_RESET_FILE") || return 1
        if [ "$previous" != "$boot" ]; then rm -f "$KERNEL_RESET_FILE" || return 1; previous=""; fi
    fi
    if [ -f "$SYSCTL_NETWORK_FILE" ]; then
        if grep -qE '^[[:space:]]*net\.ipv4\.tcp_mem[[:space:]]*=' "$SYSCTL_NETWORK_FILE"; then removed=1; fi
        if [ "$BUFFER_PROFILE" = default ] && grep -qE '^[[:space:]]*(net\.core\.[rw]mem_max|net\.ipv4\.tcp_[rw]mem)[[:space:]]*=' "$SYSCTL_NETWORK_FILE"; then removed=1; fi
    fi
    if [ "$removed" -eq 1 ]; then
        mkdir -p "$(dirname "$KERNEL_RESET_FILE")" || return 1
        printf '%s\n' "$boot" > "$KERNEL_RESET_FILE" || return 1
        previous="$boot"
    fi
    if [ "$previous" = "$boot" ]; then
        KERNEL_RESET_REQUIRED=1
        print_warning "Previous TCP memory/buffer overrides are being removed. Reboot is required to restore boot-calculated defaults."
    fi
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
    local cmd missing=0
    for cmd in curl wget ping ip; do command -v "$cmd" >/dev/null 2>&1 || missing=1; done
    if [ "$missing" -eq 1 ]; then
        refresh_apt_indexes || return 1
        run_step 'Installing prerequisites' apt-get install $APT_INSTALL_OPTS curl wget iputils-ping iproute2 || return 1
    fi
    for cmd in curl wget ping ip; do
        command -v "$cmd" >/dev/null 2>&1 || { print_error "Missing required command: $cmd"; return 1; }
    done
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
        run_step "Install packages" apt-get install -qq -y unzip >/dev/null 2>&1 || true
    fi
    if ! command_exists unzip; then
        print_error "unzip install failed"
        return 1
    fi
    return 0
}

ensure_xz() {
    if ! command_exists xz; then
        run_step "Install packages" apt-get install -qq -y xz-utils >/dev/null 2>&1 || true
    fi
    if ! command_exists xz; then
        print_error "xz-utils install failed"
        return 1
    fi
    return 0
}

ensure_bzip2() {
    if ! command_exists bzip2; then
        run_step "Install packages" apt-get install -qq -y bzip2 >/dev/null 2>&1 || true
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
    print_subsection 'System packages'
    refresh_apt_indexes || return 1
    run_step 'Applying package upgrades' apt-get upgrade $APT_INSTALL_OPTS || return 1
    run_step 'Removing unused packages' apt-get autoremove $APT_INSTALL_OPTS || return 1
    run_step --silent 'Cleaning package cache' apt-get clean || return 1
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

        print_success "Nexttrace installed (alias: nt)"
        rm -f "${TEMP_DIR}/nexttrace"
    else
        print_error "Nexttrace download failed"
    fi
}

MANIFEST_FILE="/var/lib/debian-init/manifest"
GENERATED_MARKER="Generated by: debian_init.sh"
CONFIG_TARGETS=()
RETIRED_CONFIGS=("/etc/systemd/system/disable-transparent-huge-pages.service")
STALE_RUNTIME_CONFIG=0

collect_config_targets() {
    CONFIG_TARGETS=(
        "$SYSCTL_NETWORK_FILE"
        "$SYSCTL_IPV6_FILE"
        "/etc/modules-load.d/network-optimized.conf"
        "/etc/modules-load.d/tcp_bbr.conf"
        "/etc/systemd/journald.conf.d/99-limit.conf"
        "/etc/systemd/system/debian-init-thp.service"
        "/etc/profile.d/helix-alias.sh"
        "/etc/profile.d/nexttrace-alias.sh"
        "/etc/profile.d/cfspeed-alias.sh"
        "/etc/profile.d/eza-alias.sh"
        "/etc/profile.d/update-alias.sh"
        "/usr/local/bin/update-tools"
        "/etc/profile.d/bat-alias.sh"
        "/etc/chrony/chrony.conf"
        "/etc/fail2ban/jail.local"
        "/etc/apt/apt.conf.d/50unattended-upgrades"
        "/etc/apt/apt.conf.d/20auto-upgrades"
    )
}

# All listed paths belong to this script. Replace their complete content,
# regardless of markers or manual changes; never merge or create backups.
record_managed_path() {
    local path="$1"
    mkdir -p "$(dirname "$MANIFEST_FILE")" || return 1
    touch "$MANIFEST_FILE" || return 1
    grep -qxF "$path" "$MANIFEST_FILE" || printf '%s\n' "$path" >> "$MANIFEST_FILE"
}

validate_managed_config() {
    local staged="$1" dest="$2"
    [ -s "$staged" ] || { print_error "Empty generated configuration: $dest" >&2; return 1; }
    case "$dest" in
        /etc/profile.d/*.sh|/usr/local/bin/update-tools) bash -n "$staged" ;;
        /etc/chrony/chrony.conf) chronyd -p -f "$staged" >/dev/null ;;
        /etc/apt/apt.conf.d/*) apt-config -c "$staged" dump >/dev/null ;;
        *) return 0 ;;
    esac
}

write_managed_config() {
    local dest="$1" mode="${2:-644}" staged
    mkdir -p "$(dirname "$dest")" || return 1
    # APT silently ignores .disabled staging files during directory scans.
    staged=$(mktemp --suffix=.disabled "${dest}.tmp.XXXXXX") || return 1
    if ! cat > "$staged" || ! run_step --silent "Validate ${dest##*/}" validate_managed_config "$staged" "$dest"; then
        rm -f "$staged"
        print_error "Configuration generation/validation failed: $dest" >&2
        return 1
    fi
    # Record ownership before replacement so an interrupted run can still
    # clean up any new path when a later version retires it.
    if ! record_managed_path "$dest" || ! chmod "$mode" "$staged" ||
       ! chown root:root "$staged" || ! mv -fT -- "$staged" "$dest"; then
        rm -f "$staged"
        print_error "Configuration replacement failed: $dest" >&2
        return 1
    fi
}

# Only known configuration namespaces are eligible for automated cleanup.
# The manifest is authoritative even if the old file was manually changed.
is_cleanup_path() {
    [[ "$1" != *'/../'* && "$1" != *'/./'* && "$1" != *$'\n'* ]] || return 1
    case "$1" in
        /etc/sysctl.d/*.conf|/etc/modules-load.d/*.conf|/etc/profile.d/*.sh|\
        /etc/systemd/journald.conf.d/*.conf|/etc/systemd/system/*.service|\
        /etc/chrony/*.conf|/etc/fail2ban/*.local|/etc/apt/apt.conf.d/*|\
        /usr/local/bin/update-tools) return 0 ;;
        *) return 1 ;;
    esac
}

cleanup_stale_configs() {
    local candidates="${TEMP_DIR}/managed-candidates" f t keep unit removed=0 reload=0
    : > "$candidates"
    [ ! -f "$MANIFEST_FILE" ] || cat "$MANIFEST_FILE" >> "$candidates"
    for f in "${RETIRED_CONFIGS[@]}"; do printf '%s\n' "$f" >> "$candidates"; done
    # Migrate files produced before a manifest existed, using the exact
    # script marker within the namespaces this script manages.
    local dir
    for dir in /etc/sysctl.d /etc/modules-load.d /etc/profile.d \
               /etc/systemd/journald.conf.d /etc/systemd/system \
               /etc/chrony /etc/fail2ban /etc/apt/apt.conf.d; do
        [ -d "$dir" ] || continue
        while IFS= read -r -d '' f; do
            if grep -qF "$GENERATED_MARKER" "$f"; then printf '%s\n' "$f" >> "$candidates"; fi
        done < <(find "$dir" -maxdepth 1 -type f -print0)
    done
    sort -u "$candidates" -o "$candidates" || return 1
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        keep=0
        for t in "${CONFIG_TARGETS[@]}"; do
            if [ "$f" = "$t" ]; then keep=1; break; fi
        done
        [ "$keep" -eq 0 ] || continue
        is_cleanup_path "$f" || { print_warning "Ignoring out-of-scope manifest path: $f"; continue; }
        [ -e "$f" ] || [ -L "$f" ] || continue
        if [[ "$f" == /etc/systemd/system/*.service ]]; then
            unit=${f##*/}
            if systemctl is-active --quiet "$unit"; then run_step "Stop retired service" systemctl stop "$unit" || return 1; fi
            if systemctl is-enabled --quiet "$unit"; then run_step "Disable retired service" systemctl disable "$unit" || return 1; fi
            reload=1
        fi
        rm -f -- "$f" || { print_error "Cannot remove retired config: $f"; return 1; }
        [ ! -e "$f" ] && [ ! -L "$f" ] || return 1
        case "$f" in /etc/sysctl.d/*|/etc/modules-load.d/*) STALE_RUNTIME_CONFIG=1 ;; esac
        print_kv 'Removed retired file' "$f"
        removed=$((removed + 1))
    done < "$candidates"
    if [ "$reload" -eq 1 ]; then run_step "Reload service definitions" systemctl daemon-reload || return 1; fi
    print_success "Retired configuration cleanup complete ($removed removed)"
    if [ "$STALE_RUNTIME_CONFIG" -eq 1 ]; then
        print_warning "Retired kernel settings/modules can remain in memory until reboot; their old files have been removed."
    fi
}

save_manifest() {
    local staged="${TEMP_DIR}/manifest" t
    : > "$staged"
    for t in "${CONFIG_TARGETS[@]}"; do
        if [ -e "$t" ] || [ -L "$t" ]; then printf '%s\n' "$t" >> "$staged"; fi
    done
    sort -u "$staged" -o "$staged" || return 1
    mkdir -p "$(dirname "$MANIFEST_FILE")" || return 1
    install -m 644 "$staged" "$MANIFEST_FILE" || return 1
}

preflight_config() {
    collect_config_targets
    print_kv 'Configuration policy' 'Full replacement; no merge or backup'
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    case "$default" in
        y|Y|yes|Yes) default="y" ;;
        *) default="n" ;;
    esac
    local choice
    if ! can_prompt; then
        print_info "No interactive terminal; skipped: $prompt"
        return 1
    fi
    while true; do
        local hint='y/N'
        [ "$default" != y ] || hint='Y/n'
        printf '    %s%s [%s]:%s ' "$CYAN" "$prompt" "$hint" "$RESET"
        # Read from the terminal, never from piped script text. EOF is not
        # consent, even when an optional action has a default of yes.
        if ! { read -r choice < /dev/tty; } 2>/dev/null; then
            print_warning "Input ended; current state retained."
            return 1
        fi
        case "$choice" in
            y|Y|yes|Yes)

                return 0
                ;;
            n|N|no|No)

                return 1
                ;;
            "")
                if [ "$default" = "y" ]; then

                    return 0
                fi

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

    local docker_script="${TEMP_DIR}/get-docker.sh"
    if download_file https://get.docker.com "$docker_script" && run_step "Install Docker" sh "$docker_script"; then
        print_success "Docker installed successfully"
        local docker_user="${SUDO_USER:-${USER:-}}"
        if [ -n "$docker_user" ] && [ "$docker_user" != "root" ]; then
            usermod -aG docker "$docker_user" 2>/dev/null || true
            print_info "Added '$docker_user' to docker group (re-login to take effect)"
        fi
    else
        print_error "Failed to install Docker"
        return 1
    fi
}



install_tools() {
    install_helix
    install_cf_speedtest
    install_nexttrace
    generate_update_tools_script
}

generate_update_tools_script() {
    write_managed_config /usr/local/bin/update-tools 755 <<'SCRIPT_EOF'
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
if [ ! -t 1 ] || [ -n "${NO_COLOR+x}" ] || [ "${TERM:-}" = dumb ]; then
    RED= GREEN= YELLOW= CYAN= BOLD= DIM= RESET=
fi

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
    echo -e "${CYAN}[INFO]${RESET} Helix: checking..."
    local local_ver latest_tag latest_ver url
    if cmd_ok hx; then
        local_ver=$(get_ver hx --version)
        echo -e "  ${DIM}Installed:${RESET} ${local_ver:-?}"
    else
        echo -e "  ${YELLOW}[WARN] Not installed, skipping${RESET}"
        return
    fi

    latest_tag=$(github_latest_tag "helix-editor/helix")
    latest_ver=$(echo "$latest_tag" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || true)
    if [ -z "$latest_tag" ] || [ -z "$latest_ver" ]; then
        echo -e "  ${YELLOW}[WARN] Failed to check latest version${RESET}"
        return
    fi

    if [ "$local_ver" = "$latest_ver" ]; then
        echo -e "  ${GREEN}[OK] Already up to date (${latest_ver})${RESET}"
        return
    fi

    echo -e "  ${BOLD}Updating: ${local_ver:-?} → ${latest_ver}${RESET}"
    url="https://github.com/helix-editor/helix/releases/download/${latest_tag}/helix-${latest_ver}-${SYS_ARCH}-linux.tar.xz"
    if [ -z "$url" ] || ! download_file "$url" "${TEMP_DIR}/helix.tar.xz"; then
        url=$(github_asset_url "helix-editor/helix" "helix-.*-${SYS_ARCH}-linux\\.tar\\.xz\$")
        [ -z "$url" ] && { echo -e "  ${RED}[FAIL] No download URL found${RESET}"; return; }
        download_file "$url" "${TEMP_DIR}/helix.tar.xz" || { echo -e "  ${RED}[FAIL] Download failed${RESET}"; return; }
    fi

    extract_archive "${TEMP_DIR}/helix.tar.xz" "$TEMP_DIR" || { echo -e "  ${RED}[FAIL] Extract failed${RESET}"; return; }
    local helix_dir
    helix_dir=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "helix-*" -print -quit)
    if [ -n "$helix_dir" ] && [ -f "${helix_dir}/hx" ]; then
        install -m 755 "${helix_dir}/hx" /usr/local/bin/hx
        [ -d "${helix_dir}/runtime" ] && rm -rf /usr/local/lib/helix/runtime && mkdir -p /usr/local/lib/helix && cp -r "${helix_dir}/runtime" /usr/local/lib/helix/
        echo -e "  ${GREEN}[OK] Updated to ${latest_ver}${RESET}"
    else
        echo -e "  ${RED}[FAIL] Binary not found in archive${RESET}"
    fi
}

update_nexttrace() {
    echo -e "${CYAN}[INFO]${RESET} Nexttrace: checking..."
    local local_ver latest_tag url
    if cmd_ok nexttrace; then
        local_ver=$(get_ver nexttrace --version)
        echo -e "  ${DIM}Installed:${RESET} ${local_ver:-?}"
    else
        echo -e "  ${YELLOW}[WARN] Not installed, skipping${RESET}"
        return
    fi

    latest_tag=$(github_latest_tag "nxtrace/NTrace-core")
    if [ -z "$latest_tag" ]; then
        echo -e "  ${YELLOW}[WARN] Failed to check latest version${RESET}"
        return
    fi

    # Compare version strings; skip if same
    local latest_ver
    latest_ver=$(echo "$latest_tag" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || true)
    if [ -n "$latest_ver" ] && [ "$local_ver" = "$latest_ver" ]; then
        echo -e "  ${GREEN}[OK] Already up to date (${latest_ver})${RESET}"
        return
    fi

    echo -e "  ${BOLD}Updating: ${local_ver:-?} → ${latest_ver:-latest}${RESET}"
    url="https://github.com/nxtrace/NTrace-core/releases/latest/download/nexttrace_linux_${ARCH_SUFFIX}"
    if download_file "$url" "${TEMP_DIR}/nexttrace"; then
        install -m 755 "${TEMP_DIR}/nexttrace" /usr/local/bin/nexttrace
        echo -e "  ${GREEN}[OK] Updated to ${latest_ver:-latest}${RESET}"
    else
        echo -e "  ${RED}[FAIL] Download failed${RESET}"
    fi
}

update_cf_speedtest() {
    echo -e "${CYAN}[INFO]${RESET} CF Speedtest: checking..."
    local local_ver latest_tag latest_ver url
    if cmd_ok cloudflare-speed-cli; then
        local_ver=$(get_ver cloudflare-speed-cli --version)
        echo -e "  ${DIM}Installed:${RESET} ${local_ver:-?}"
    else
        echo -e "  ${YELLOW}[WARN] Not installed, skipping${RESET}"
        return
    fi

    latest_tag=$(github_latest_tag "kavehtehrani/cloudflare-speed-cli")
    if [ -z "$latest_tag" ]; then
        echo -e "  ${YELLOW}[WARN] Failed to check latest version${RESET}"
        return
    fi
    # Release tags are prefixed with 'v' (e.g. v0.6.2); strip it for comparison.
    latest_ver=$(echo "$latest_tag" | sed -E 's/^v//' | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || true)

    if [ -n "$latest_ver" ] && [ "$local_ver" = "$latest_ver" ]; then
        echo -e "  ${GREEN}[OK] Already up to date (${latest_ver})${RESET}"
        return
    fi

    echo -e "  ${BOLD}Updating: ${local_ver:-?} → ${latest_ver:-latest}${RESET}"
    url="https://github.com/kavehtehrani/cloudflare-speed-cli/releases/latest/download/cloudflare-speed-cli-${SYS_ARCH}-unknown-linux-musl.tar.xz"
    if download_file "$url" "${TEMP_DIR}/cfspeed.tar.xz"; then
        extract_archive "${TEMP_DIR}/cfspeed.tar.xz" "$TEMP_DIR" || { echo -e "  ${RED}[FAIL] Extract failed${RESET}"; return; }
        local binpath
        binpath=$(find "$TEMP_DIR" -type f -name "cloudflare-speed-cli*" -executable -print -quit 2>/dev/null || true)
        [ -z "$binpath" ] && binpath=$(find "$TEMP_DIR" -type f -name "cloudflare-speed-cli*" -print -quit 2>/dev/null || true)
        if [ -n "$binpath" ]; then
            install -m 755 "$binpath" /usr/local/bin/cloudflare-speed-cli
            echo -e "  ${GREEN}[OK] Updated to ${latest_ver:-latest}${RESET}"
        else
            echo -e "  ${RED}[FAIL] Binary not found in archive${RESET}"
        fi
    else
        echo -e "  ${YELLOW}[WARN] Download failed (may already be latest)${RESET}"
    fi
}

# ---- main ----
echo ""
echo -e "${BOLD}GitHub tools update${RESET}"
echo ""

update_helix
echo ""
update_nexttrace
echo ""
update_cf_speedtest

echo ""
echo -e "${CYAN}[INFO]${RESET} Tools update checks finished; see the results above."

rm -rf "$TEMP_DIR"
SCRIPT_EOF


}

configure_tool_aliases() {
    if command_exists hx; then
        write_managed_config /etc/profile.d/helix-alias.sh <<'EOF'
# Generated by: debian_init.sh
export HELIX_RUNTIME=/usr/local/lib/helix/runtime
alias vi='hx'
alias vim='hx'
EOF
    else
        rm -f /etc/profile.d/helix-alias.sh || return 1
    fi
    if command_exists nexttrace; then
        write_managed_config /etc/profile.d/nexttrace-alias.sh <<'EOF'
# Generated by: debian_init.sh
alias nt='nexttrace'
EOF
    else
        rm -f /etc/profile.d/nexttrace-alias.sh || return 1
    fi
    if command_exists cloudflare-speed-cli; then
        write_managed_config /etc/profile.d/cfspeed-alias.sh <<'EOF'
# Generated by: debian_init.sh
alias cf='cloudflare-speed-cli'
EOF
    else
        rm -f /etc/profile.d/cfspeed-alias.sh || return 1
    fi
}

configure_eza_aliases() {
    if ! command_exists eza; then
        print_warning "eza not found, removing obsolete eza aliases"
        rm -f /etc/profile.d/eza-alias.sh || return 1
        return
    fi

    write_managed_config /etc/profile.d/eza-alias.sh <<'EOF'
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
# Keep system ls behavior unchanged for compatibility in scripts and automation.
# If you really want interactive ls mapped to eza, uncomment the next line manually.
# alias ls='eza --icons --group-directories-first --git'
alias ll='eza -l --icons --group-directories-first --git'
alias la='eza -al --icons --group-directories-first --git'
alias lt='eza -T --icons --level=2'
EOF


}

configure_update_alias() {
    write_managed_config /etc/profile.d/update-alias.sh <<'EOF'
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
# System-wide alias: apt update + upgrade + autoremove + GitHub tools refresh
alias update='apt update && apt upgrade && apt autoremove -y && update-tools'
EOF


}

configure_chrony() {
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

    write_managed_config "$CHRONY_CONF" <<EOF
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
    run_step 'Restarting Chrony' activate_service chrony || return 1
    print_kv 'NTP pool' "${region_prefix:-global}pool.ntp.org"

    CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Unknown")

    # Timezone: Auto-set to IP_TZ if available and different
    if [ -n "${IP_TZ:-}" ] && [ "$IP_TZ" != "$CURRENT_TZ" ]; then
        print_info "Setting timezone to ${IP_TZ} (detected)..."
         if timedatectl set-timezone "$IP_TZ" 2>/dev/null; then
            print_success "Timezone set to $IP_TZ"
            CURRENT_TZ="$IP_TZ"
        else
            print_error "Failed to set timezone; keeping current."
        fi
    fi
    TIMEZONE_FINAL="$CURRENT_TZ"
    print_kv 'Timezone' "$TIMEZONE_FINAL"
}

ensure_kernel_modules() {
    local modules_conf="/etc/modules-load.d/network-optimized.conf"

    local staged="${TEMP_DIR}/network-modules.conf"
    echo "# Generated by: debian_init.sh" > "$staged"

    # nf_conntrack must be loaded BEFORE the sysctl config is written:
    # filter_sysctl_file drops keys that aren't visible in /proc/sys yet,
    # so without this step all net.netfilter.* keys would be skipped.
    if modprobe nf_conntrack >/dev/null 2>&1 || [ -r /proc/sys/net/netfilter/nf_conntrack_max ]; then
        echo "nf_conntrack" >> "$staged"
        print_kv 'nf_conntrack' 'Loaded'
    else
        print_warning "nf_conntrack unavailable; conntrack tuning keys will be skipped"
    fi

    # TLS offload (optional; only persisted when the module exists)
    if modprobe tls >/dev/null 2>&1; then
        echo "tls" >> "$staged"
        print_kv 'tls' 'Loaded'
    else
        print_info "tls module not available (optional, skipped)"
    fi
    write_managed_config "$modules_conf" < "$staged"
}

configure_journald() {
    local conf_dir="/etc/systemd/journald.conf.d"
    mkdir -p "$conf_dir"

    # Keep a longer troubleshooting window, bounded by disk usage. Rsyslog
    # is not a complete archive of journal fields or all service output.
    write_managed_config "${conf_dir}/99-limit.conf" <<'EOF'
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
[Journal]
SystemMaxUse=384M
SystemMaxFileSize=128M
SystemMaxFiles=3
RuntimeMaxUse=256M
RuntimeMaxFileSize=128M
RuntimeMaxFiles=3
MaxRetentionSec=1209600
MaxFileSec=259200
EOF
    run_step 'Restarting journald' systemctl restart systemd-journald || return 1
    systemctl is-active --quiet systemd-journald || return 1
    print_kv 'Journal limits' '384 MiB disk / 256 MiB runtime / up to 14 days'
    print_info 'Size limits may shorten journal retention.' 
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
# Connection Reliability (tolerate transient loss on cross-region links)
# ============================================================================
# Reboot 1s after kernel panic instead of hanging
kernel.panic = 1
# Keepalive defaults for sockets that enable SO_KEEPALIVE (applications may override).
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
# Retain standard TCP retransmission tolerance; application deadlines handle fast failover.
net.ipv4.tcp_syn_retries = 6
net.ipv4.tcp_synack_retries = 5
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 15

# TCP global memory thresholds are calculated by the kernel at boot.
# This script intentionally does not override net.ipv4.tcp_mem.

# ============================================================================
# Conntrack (requires nf_conntrack module; loaded before this config is written)
# ============================================================================
net.netfilter.nf_conntrack_max = ${conntrack_max}
# Use Linux 6.12 default protocol timeouts to preserve NAT/conntrack state during loss or idle periods.
net.netfilter.nf_conntrack_tcp_timeout_established = 432000
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_close = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 30
net.netfilter.nf_conntrack_tcp_timeout_max_retrans = 300
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 60
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 120
net.netfilter.nf_conntrack_tcp_timeout_unacknowledged = 300
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120
net.netfilter.nf_conntrack_icmp_timeout = 30
net.netfilter.nf_conntrack_icmpv6_timeout = 30
net.netfilter.nf_conntrack_generic_timeout = 600
net.netfilter.nf_conntrack_gre_timeout = 30
net.netfilter.nf_conntrack_gre_timeout_stream = 180

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
# VM settings: < 1GB RAM
# ============================================================================

# --- Core: Aggressive Response Speed ---
# Disable slow start after idle to ensure full speed immediately
net.ipv4.tcp_slow_start_after_idle = 0


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
net.ipv4.tcp_tw_reuse = 2
SYSCTL
    else
        # >= 1GB RAM Profile: Performance & Stability
        cat <<SYSCTL
# ============================================================================
# VM settings: >= 1GB RAM
# ============================================================================

# --- Core: Aggressive Response Speed ---
# Disable slow start after idle
net.ipv4.tcp_slow_start_after_idle = 0


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
net.ipv4.tcp_tw_reuse = 2
# Increased queue depth for high concurrency
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
SYSCTL
    fi
    if [ "$BUFFER_PROFILE" != default ]; then
        local cap=33554432
        [ "$BUFFER_PROFILE" != 64m ] || cap=67108864
        cat <<SYSCTL

# Selected transfer buffer profile: ${BUFFER_PROFILE}
# Initial buffers stay small; limits allow automatic growth as needed.
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.rmem_max = ${cap}
net.core.wmem_max = ${cap}
net.ipv4.tcp_rmem = 4096 131072 ${cap}
net.ipv4.tcp_wmem = 4096 16384 ${cap}
SYSCTL
    fi
}

apply_network_sysctl() {

    local tmpfile
    tmpfile="${TEMP_DIR}/sysctl_network.conf"

    track_kernel_default_reset || return 1
    generate_sysctl_content > "$tmpfile"

    mkdir -p /etc/sysctl.d

    local filtered="${TEMP_DIR}/sysctl_filtered.conf"
    : > "$filtered"
    filter_sysctl_file "$tmpfile" "$filtered"
    write_managed_config "$SYSCTL_NETWORK_FILE" < "$filtered"


}

apply_ipv6_sysctl() {
    mkdir -p /etc/sysctl.d
    if [ "$DISABLE_IPV6" -eq 1 ]; then

        write_managed_config "$SYSCTL_IPV6_FILE" <<'EOF'
# ============================================================================
# Generated by: debian_init.sh
# Do not edit manually - changes may be overwritten
# ============================================================================

# Disable IPv6 completely
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        print_kv 'IPv6 configuration' 'Disabled'
    else
        # Enable IPv6 immediately (kernel defaults to 0 = enabled)
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null || return 1
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null || return 1
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null || return 1
        # Remove IPv6 disable config if exists
        if [ -f "$SYSCTL_IPV6_FILE" ]; then
            rm -f "$SYSCTL_IPV6_FILE"
        fi
        print_kv 'IPv6 configuration' 'Enabled'
    fi
}

configure_ipv6_choice() {
    local disabled ssh_peer
    disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null) || {
        print_info "IPv6 sysctl unavailable; skipping IPv6 options."
        return 0
    }
    if [ "$disabled" = "1" ]; then
        # A disabled stack cannot pass an external IPv6 probe. Still offer
        # recovery, and preserve the old state if input is unavailable.
        if ask_yes_no "Enable IPv6?"; then
            DISABLE_IPV6=0
            apply_ipv6_sysctl || return 1
            IPV6_ADDR="N/A"
            IPV6_STATUS="enabled; external connectivity not rechecked"
        fi
        return 0
    fi

    # Require both a previously successful IPv4 probe and an IPv4 route.
    # Failure is conservative: leave the working network unchanged.
    if [ -z "${IPV4_ADDR:-}" ] || [ "$IPV4_ADDR" = "N/A" ] ||
       ! ip -4 route get 1.1.1.1 >/dev/null 2>&1; then
        print_warning "IPv4 connectivity not confirmed; IPv6 disabling is unavailable."
        return 0
    fi
    ssh_peer=${SSH_CONNECTION:-}
    ssh_peer=${ssh_peer%% *}
    if [[ "$ssh_peer" == *:* ]]; then
        print_warning "Current SSH connection uses IPv6; keeping IPv6 enabled."
        return 0
    fi
    if ask_yes_no "Disable IPv6?"; then
        DISABLE_IPV6=1
        apply_ipv6_sysctl || return 1
        sysctl -p "$SYSCTL_IPV6_FILE" >/dev/null || return 1
        [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" = "1" ] || return 1
    fi
}

show_ipv6_status() {
    print_kv 'Current state' "$(ipv6_status_text)"
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
    local virt
    virt=$(systemd-detect-virt 2>/dev/null || true)
    if [ -z "$virt" ] || [ "$virt" = none ]; then
        print_warning 'Cloud kernels omit hardware drivers; verify suitability before installing on bare metal.'
    fi
    detect_kernel_versions
    if dpkg-query -W -f='${Status}' "linux-image-cloud-${ARCH_DEB}" 2>/dev/null | grep -Eq '^[^ ]+ ok installed$'; then
        print_kv 'Package' 'Installed'
    else
        print_kv 'Package' 'Not installed'
    fi
    print_kv 'Running version' "$CURRENT_KERNEL"
    print_kv 'Latest installed' "${LATEST_KERNEL:-Not detected}"
}

install_cloud_kernel() {
    run_step 'Installing/updating cloud kernel' apt-get install $APT_INSTALL_OPTS "linux-image-cloud-${ARCH_DEB}" || return 1
    if command_exists update-grub; then
        run_step 'Updating GRUB configuration' update-grub || return 1
    else
        print_warning 'No GRUB update command found; verify your bootloader before rebooting.'
    fi
    detect_kernel_versions
    if [ -n "$LATEST_KERNEL" ] && [ "$LATEST_KERNEL" != "$CURRENT_KERNEL" ]; then KERNEL_BOOT_PENDING=1; fi
    print_info 'Kernel installation does not reboot the server. Check uname -r after reboot.'
}

detect_ssh_ports() {
    local config ports
    # Effective daemon configuration includes Include files. An existing
    # service may also use socket activation or command-line overrides;
    # include its live listening ports when sshd owns the socket.
    config=$(sshd -T) || return 1
    ports=$(
        {
            awk '$1 == "port" && $2 ~ /^[0-9]+$/ { print $2 }' <<< "$config"
            ss -H -ltnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); if (a[n] ~ /^[0-9]+$/) print a[n] }'
        } | sort -nu | paste -sd, -
    ) || return 1
    [ -n "$ports" ] || { print_error "Unable to determine SSH ports." >&2; return 1; }
    printf '%s\n' "$ports"
}

install_base_packages() {
    print_subsection 'Required packages'
    local package status missing=()
    local packages=(rsyslog openssl gnupg cron chrony fail2ban python3-systemd logrotate nano vnstat nload htop unzip unattended-upgrades eza duf bat zoxide)
    for package in "${packages[@]}"; do
        status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)
        [[ "$status" == *' ok installed' ]] || missing+=("$package")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        run_step 'Installing missing packages' apt-get install $APT_INSTALL_OPTS "${missing[@]}" || return 1
    else
        print_success "All ${#packages[@]} required packages are installed."
    fi
    write_managed_config /etc/profile.d/bat-alias.sh <<'EOF'
# Generated by: debian_init.sh
command -v bat >/dev/null 2>&1 || alias bat='batcat'
EOF
}

activate_service() {
    local service="$1"
    systemctl enable "$service" || return 1
    systemctl restart "$service" || return 1
    systemctl is-active --quiet "$service"
}

restart_fail2ban() {
    activate_service fail2ban || return 1
    local attempt
    for attempt in {1..10}; do
        if fail2ban-client status sshd >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    print_error 'Fail2Ban SSH jail did not become ready.'
    return 1
}

configure_fail2ban() {
    print_subsection 'SSH protection'
    # Ensure rsyslog is enabled and started
    run_step 'Starting rsyslog' systemctl enable --now rsyslog || return 1
    systemctl is-active --quiet rsyslog || return 1

    # Configure Fail2Ban (systemd backend)
    local ssh_ports
    ssh_ports=$(detect_ssh_ports) || return 1

    write_managed_config /etc/fail2ban/jail.local <<EOF
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
port = ${ssh_ports}
EOF
    run_step --silent "Validate Fail2Ban" fail2ban-client -t || { print_error "Fail2Ban configuration validation failed."; return 1; }
    run_step 'Restarting Fail2Ban and checking SSH jail' restart_fail2ban || return 1
    print_kv 'Protected SSH ports' "$ssh_ports"

}

configure_auto_updates() {
    print_subsection 'Automatic updates'
    # Configure unattended-upgrades for security updates only.
    # The Origins-Pattern must reference the real suite (e.g. trixie-security);
    # a literal ${...} placeholder would silently match nothing, so the
    # codename is read from os-release and the heredoc must stay UNQUOTED.
    local distro_codename
    distro_codename=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")
    distro_codename=${distro_codename:-trixie}

    write_managed_config /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
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

    write_managed_config /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// Generated by: debian_init.sh
// Do not edit manually - changes may be overwritten
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    run_step 'Enabling security update timers' systemctl enable --now apt-daily.timer apt-daily-upgrade.timer || return 1
    systemctl is-active --quiet apt-daily.timer || return 1
    systemctl is-active --quiet apt-daily-upgrade.timer || return 1
    print_kv 'Update scope' 'Debian security updates'
    print_kv 'Update timers' 'Active'
}

verify_sysctl_file() {
    local file="$1" line key expected actual failed=0
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%%#*}
        [[ "$line" == *'='* ]] || continue
        key=$(printf '%s' "${line%%=*}" | xargs)
        expected=$(printf '%s' "${line#*=}" | xargs)
        if ! actual=$(sysctl -n "$key"); then
            print_error "Cannot read applied sysctl: $key" >&2
            failed=1
            continue
        fi
        actual=$(printf '%s' "$actual" | xargs)
        if [ "$actual" != "$expected" ]; then
            print_error "$key: expected '$expected', got '$actual'; check other sysctl files for overrides." >&2
            failed=1
        fi
    done < "$file"
    [ "$failed" -eq 0 ]
}

apply_all_sysctl() {
    modprobe tcp_bbr 2>/dev/null || true
    printf '# Generated by: debian_init.sh\ntcp_bbr\n' | write_managed_config /etc/modules-load.d/tcp_bbr.conf
    run_step --quiet 'Applying kernel parameters' sysctl --system || return 1
    run_step --quiet 'Reading back TCP parameters' verify_network_state || return 1
    print_kv 'TCP data retries' "$(sysctl -n net.ipv4.tcp_retries1) / $(sysctl -n net.ipv4.tcp_retries2)"
    print_kv 'SYN retries' "$(sysctl -n net.ipv4.tcp_syn_retries) / $(sysctl -n net.ipv4.tcp_synack_retries)"
    print_kv 'Keepalive (s / s / probes)' "$(sysctl -n net.ipv4.tcp_keepalive_time) / $(sysctl -n net.ipv4.tcp_keepalive_intvl) / $(sysctl -n net.ipv4.tcp_keepalive_probes)"
    print_kv 'TIME_WAIT reuse' 'Loopback only'
    print_kv 'Connection tracking' 'Standard protocol timeouts'
    print_kv 'Selected buffer profile' "$(buffer_profile_label)"
    print_kv 'Current receive / send caps' "$(current_buffer_caps)"
    print_kv 'TCP global memory override' 'Removed; kernel-managed after any required reboot'
    if [ "$KERNEL_RESET_REQUIRED" -eq 1 ]; then print_warning 'Reboot is required to clear previous TCP memory/buffer overrides.'; fi
}

verify_network_state() {
    verify_sysctl_file "$SYSCTL_NETWORK_FILE" || return 1
    verify_sysctl_file "$SYSCTL_IPV6_FILE"
}

current_buffer_caps() {
    local receive send
    receive=$(sysctl -n net.ipv4.tcp_rmem | awk '{printf "%.1f",$3/1048576}') || return 1
    send=$(sysctl -n net.ipv4.tcp_wmem | awk '{printf "%.1f",$3/1048576}') || return 1
    printf '%s MiB / %s MiB' "$receive" "$send"
}

verify_managed_state() {
    local f line module apt_state journal_state key expected actual
    for module in chrony fail2ban rsyslog systemd-journald apt-daily.timer apt-daily-upgrade.timer; do
        systemctl is-active --quiet "$module" || { print_error "Required service is not active: $module"; return 1; }
    done
    fail2ban-client status sshd >/dev/null || return 1
    if [ "$DOCKER_ACTION" = start ]; then
        systemctl is-active --quiet docker.service || return 1
        systemctl is-enabled --quiet docker.service || return 1
    elif [ "$DOCKER_ACTION" = stop ]; then
        local unit
        while IFS= read -r unit; do
            if systemctl is-active --quiet "$unit" || systemctl is-enabled --quiet "$unit"; then return 1; fi
        done < <(docker_units)
    fi
    if [ -n "$THP_SELECTED" ]; then
        [ "$(read_thp_mode /sys/kernel/mm/transparent_hugepage/enabled)" = "$THP_SELECTED" ] || return 1
        [ "$(read_thp_mode /sys/kernel/mm/transparent_hugepage/defrag)" = "$THP_DEFRAG_SELECTED" ] || return 1
        systemctl is-enabled --quiet debian-init-thp.service || return 1
    fi
    verify_sysctl_file "$SYSCTL_NETWORK_FILE" || return 1
    verify_sysctl_file "$SYSCTL_IPV6_FILE" || return 1
    for f in /etc/modules-load.d/network-optimized.conf /etc/modules-load.d/tcp_bbr.conf; do
        while IFS= read -r line || [ -n "$line" ]; do
            module=$(printf '%s' "${line%%#*}" | xargs)
            [ -n "$module" ] || continue
            [ -d "/sys/module/${module//-/_}" ] || { print_error "Configured module is not loaded: $module"; return 1; }
        done < "$f"
    done
    apt_state=$(apt-config dump) || return 1
    for key in Update-Package-Lists Unattended-Upgrade; do
        grep -qxF "APT::Periodic::${key} \"1\";" <<< "$apt_state" || {
            print_error "APT periodic setting is not effective: $key"; return 1;
        }
    done
    # Inspect the merged journal configuration so later drop-ins cannot
    # silently override settings while the summary reports success.
    journal_state=$(systemd-analyze cat-config systemd/journald.conf) || return 1
    while read -r key expected; do
        actual=$(awk -F= -v key="$key" '
            /^[[:space:]]*\[/ { section=$0; gsub(/[[:space:]]/, "", section) }
            section == "[Journal]" && $0 !~ /^[[:space:]]*[#;]/ {
                name=$1; gsub(/[[:space:]]/, "", name)
                if (name == key) { value=$2; gsub(/[[:space:]]/, "", value) }
            }
            END { print value }' <<< "$journal_state")
        [ "$actual" = "$expected" ] || { print_error "Effective journald $key: expected $expected, got $actual"; return 1; }
    done <<'SETTINGS'
SystemMaxUse 384M
SystemMaxFileSize 128M
SystemMaxFiles 3
RuntimeMaxUse 256M
RuntimeMaxFileSize 128M
RuntimeMaxFiles 3
MaxRetentionSec 1209600
MaxFileSec 259200
SETTINGS

}

docker_units() {
    printf '%s\n' docker.service
    if systemctl cat docker.socket >/dev/null 2>&1; then printf '%s\n' docker.socket; fi
}

set_docker_state() {
    local action="$1" unit units=()
    if [ "$action" = start ]; then
        systemctl enable --now docker.service || return 1
        systemctl is-active --quiet docker.service || return 1
        systemctl is-enabled --quiet docker.service || return 1
    else
        while IFS= read -r unit; do units+=("$unit"); done < <(docker_units)
        systemctl disable --now "${units[@]}" || return 1
        for unit in "${units[@]}"; do
            if systemctl is-active --quiet "$unit" || systemctl is-enabled --quiet "$unit"; then
                print_error "$unit did not stop/disable as requested."
                return 1
            fi
        done
    fi
    DOCKER_ACTION="$action"
}

configure_docker_choice() {
    print_subsection 'Docker'
    if ! command_exists docker; then
        print_kv 'Package' 'Not installed'
        if ask_yes_no 'Install Docker?' n; then install_docker || return 1; else return 0; fi
    fi
    local version state startup choice
    version=$(docker --version 2>/dev/null || true)
    state=$(systemctl is-active docker.service 2>/dev/null || true)
    startup=$(systemctl is-enabled docker.service 2>/dev/null || true)
    print_kv 'Version' "${version:-Unknown}"
    print_kv 'Service' "${state:-Unknown}"
    print_kv 'Start at boot' "${startup:-Unknown}"
    if ! can_prompt; then print_info 'No terminal; Docker state retained.'; return 0; fi
    printf '\n    1) Keep current state\n    2) Start Docker and enable it at boot\n    3) Stop Docker and disable it at boot\n'
    while true; do
        if ! read_tty_value choice 'Select [1]:'; then return 0; fi
        case "$choice" in
            ''|1) print_info 'Docker state retained.'; return 0 ;;
            2) run_step 'Starting/enabling Docker' set_docker_state start; return $? ;;
            3)
                print_warning 'Stopping Docker can interrupt running containers and dependent services.'
                if ask_yes_no 'Stop Docker and disable startup? Confirm' n; then
                    run_step 'Stopping/disabling Docker' set_docker_state stop || return 1
                else
                    print_info 'Docker state retained.'
                fi
                return 0 ;;
            *) print_warning 'Choose 1, 2 or 3.' ;;
        esac
    done
}

read_thp_mode() {
    local file="$1"
    sed -nE 's/.*\[([^]]+)\].*/\1/p' "$file" 2>/dev/null
}

apply_thp_mode() {
    local mode="$1" defrag="$2" unit=/etc/systemd/system/debian-init-thp.service
    case "$mode" in always|madvise|never) ;; *) return 1 ;; esac
    case "$defrag" in always|defer|defer+madvise|madvise|never) ;; *) return 1 ;; esac
    write_managed_config "$unit" <<EOF
# Generated by: debian_init.sh
[Unit]
Description=Apply selected Transparent Huge Pages mode
DefaultDependencies=no
After=sysinit.target local-fs.target
ConditionPathIsReadWrite=/sys/kernel/mm/transparent_hugepage/enabled
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo ${mode} > /sys/kernel/mm/transparent_hugepage/enabled && echo ${defrag} > /sys/kernel/mm/transparent_hugepage/defrag'
[Install]
WantedBy=basic.target
EOF
    systemd-analyze verify "$unit" || return 1
    systemctl daemon-reload || return 1
    systemctl enable debian-init-thp.service || return 1
    systemctl restart debian-init-thp.service || return 1
    [ "$(read_thp_mode /sys/kernel/mm/transparent_hugepage/enabled)" = "$mode" ] || return 1
    [ "$(read_thp_mode /sys/kernel/mm/transparent_hugepage/defrag)" = "$defrag" ] || return 1
    THP_SELECTED="$mode"
    THP_DEFRAG_SELECTED="$defrag"
}

configure_thp_choice() {
    print_subsection 'Transparent Huge Pages'
    local mode defrag
    mode=$(read_thp_mode /sys/kernel/mm/transparent_hugepage/enabled || true)
    defrag=$(read_thp_mode /sys/kernel/mm/transparent_hugepage/defrag || true)
    case "$mode" in always|madvise|never) ;; *) print_info 'THP is not supported; skipped.'; return 0 ;; esac
    case "$defrag" in always|defer|defer+madvise|madvise|never) ;; *) print_warning 'Unknown THP defrag mode; leaving THP unchanged.'; return 0 ;; esac
    print_kv 'Current mode' "$mode"
    print_kv 'Defragmentation' "$defrag"
    if [ "$mode" = never ]; then
        if ask_yes_no 'Enable THP in madvise mode?' n; then mode=madvise; defrag=madvise; fi
    else
        if ask_yes_no 'Disable THP?' n; then mode=never; defrag=never; fi
    fi
    run_step 'Persisting selected THP mode' apply_thp_mode "$mode" "$defrag" || return 1
    print_kv 'Selected mode' "$THP_SELECTED"
}

configure_optional_components() {
    print_subsection 'Cloud kernel'
    show_kernel_info
    if ask_yes_no 'Install/update cloud kernel?' n; then
        install_cloud_kernel || return 1
    else
        print_info 'No additional kernel installation requested; boot configuration is unchanged here.'
    fi
    configure_docker_choice || return 1
    configure_thp_choice || return 1
    print_subsection 'IPv6'
    show_ipv6_status
    configure_ipv6_choice || return 1
}

show_report() {
    printf '\n'
    if [ "$KERNEL_RESET_REQUIRED" -eq 1 ] || [ "$STALE_RUNTIME_CONFIG" -eq 1 ] || [ "$KERNEL_BOOT_PENDING" -eq 1 ]; then
        print_warning 'RESULT: Configuration completed — reboot required'
    else
        print_success 'RESULT: Configuration completed'
    fi
    print_subsection 'Active now'
    print_kv 'Saved buffer profile' "$(buffer_profile_label)"
    if [ "$BUFFER_TARGET_MBPS" = unknown ]; then print_kv 'Target per connection' 'Not specified'; else print_kv 'Target per connection' "$BUFFER_TARGET_MBPS Mbps"; fi
    print_kv 'Receive / send caps' "$(current_buffer_caps)"
    print_kv 'Congestion / default qdisc' "$(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
    print_kv 'IPv6' "$(ipv6_status_text)"
    if command_exists docker; then
        print_kv 'Docker service / startup' "$(systemctl is-active docker.service 2>/dev/null || true) / $(systemctl is-enabled docker.service 2>/dev/null || true)"
    fi
    print_kv 'THP mode' "$(read_thp_mode /sys/kernel/mm/transparent_hugepage/enabled || echo unavailable)"
    if [ "$KERNEL_RESET_REQUIRED" -eq 1 ] || [ "$STALE_RUNTIME_CONFIG" -eq 1 ] || [ "$KERNEL_BOOT_PENDING" -eq 1 ]; then
        print_subsection 'Action required'
        if [ "$KERNEL_RESET_REQUIRED" -eq 1 ] || [ "$STALE_RUNTIME_CONFIG" -eq 1 ]; then
            print_warning 'Reboot when a service interruption is acceptable to clear retired kernel settings.'
            print_info 'Selected buffer caps are already applied; boot-calculated defaults may still be pending.'
        fi
        if [ "$KERNEL_BOOT_PENDING" -eq 1 ]; then
            print_warning 'A different kernel is installed; reboot and verify the selected kernel to complete the change.'
        fi
        printf '\n    After reboot:\n      uname -r\n'
        if [ "$KERNEL_RESET_REQUIRED" -eq 1 ]; then printf '      sysctl net.ipv4.tcp_mem net.ipv4.tcp_rmem net.ipv4.tcp_wmem\n'; fi
    fi
    print_subsection 'Next steps'
    print_info 'Re-login to load shell shortcuts. Check the running kernel after any planned reboot.'
    print_info 'To reassess buffers, this command also works when launched through Script Hub:'
    printf '    curl -fsSL https://raw.githubusercontent.com/aoaim/luanqi_bazao/main/linux_script/debian_init.sh | bash -s -- --reassess-buffers\n'
}

main() {
    parse_args "$@"
    require_root
    require_debian
    init_ui

    print_section 'Environment'
    ensure_basic_tools
    fetch_ipinfo
    detect_system
    show_detection

    print_section 'Transfer buffers'
    configure_buffers
    profile_allowed "$BUFFER_PROFILE" || { print_error 'Buffer profile is not allowed on this host.'; return 1; }

    print_section 'Packages and tools'
    apt_refresh
    install_base_packages
    print_subsection 'Additional tools'
    install_tools
    configure_tool_aliases
    configure_eza_aliases
    configure_update_alias
    print_subsection 'Shell shortcuts'
    if command_exists hx; then print_kv 'vi / vim' 'Helix'; fi
    if command_exists cloudflare-speed-cli; then print_kv 'cf' 'Cloudflare Speedtest'; fi
    if command_exists nexttrace; then print_kv 'nt' 'Nexttrace'; fi
    if command_exists eza; then print_kv 'll / la / lt' 'Eza listings'; fi
    print_kv 'update' 'Package and tool updates'

    print_section 'System configuration'
    preflight_config
    cleanup_stale_configs
    print_subsection 'Time synchronization'
    configure_chrony
    configure_fail2ban
    configure_auto_updates
    print_subsection 'Journal retention'
    configure_journald
    print_subsection 'Kernel modules'
    ensure_kernel_modules

    print_section 'Network configuration'
    apply_network_sysctl
    case "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo unavailable)" in
        0) apply_ipv6_sysctl ;;
        1) DISABLE_IPV6=1; apply_ipv6_sysctl ;;
        *) print_info 'IPv6 sysctl unavailable; IPv6 configuration skipped.' ;;
    esac
    apply_all_sysctl

    print_section 'Optional components'
    configure_optional_components

    print_section 'Verification and result'
    run_step --quiet 'Verifying configuration and services' verify_managed_state
    save_manifest
    save_buffer_state
    show_report
}

main "$@"


