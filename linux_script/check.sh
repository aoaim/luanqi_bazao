#!/bin/bash
# =========================================================
# Customized Region Restriction Check Script
# This script checks the availability of various regional
# streaming and AI services.
# Supported OS: Debian 13+
#
# Variant of check.sh meant for "unlock" DNS servers. Run it on a terminal and
# it asks whether to use a custom DNS (default: no, so pressing Enter keeps the
# system resolver); -D or CUSTOM_DNS answer that question in advance and skip
# the prompt. Left empty, the script behaves exactly like check.sh.
# =========================================================

shopt -s expand_aliases

# =========================================================
# Custom DNS (unlock DNS)
# =========================================================
# Some VPS providers run an "unlock" DNS: query it and the streaming/AI
# services resolve to servers in a region where they are available, which is
# exactly what the checks below are meant to verify. Run on a terminal, the
# script offers to use it interactively; setting a value here skips that
# question. Empty (the default) keeps the system resolver.
# One or more servers, comma or space separated, plus optionally one DoH URL:
#   CUSTOM_DNS="12.34.56.78"                    # single nameserver
#   CUSTOM_DNS="12.34.56.78 87.65.43.21"        # with a failover nameserver
#   CUSTOM_DNS="https://doh.example/dns-query"  # DoH endpoint
# The environment variable CUSTOM_DNS and the -D option override this line.
CUSTOM_DNS="${CUSTOM_DNS:-}"

# Filled in by setupCustomDns below; DNS_MODE stays empty when the script runs
# on the system resolver.
dnsFlags=""
DNS_LABEL=""
DNS_MODE=""
DNS_SERVERS=()
DNS_DOH=""

# Define ANSI color codes for formatted output
Font_Black="\033[30m"
Font_Red="\033[31m"
Font_Green="\033[32m"
Font_Yellow="\033[33m"
Font_Blue="\033[34m"
Font_Purple="\033[35m"
Font_SkyBlue="\033[36m"
Font_White="\033[37m"
Font_Suffix="\033[0m"

# Parse optional command-line arguments for custom proxy, DNS, interface, etc.
while getopts ":I:M:EX:P:F:S:R:C:D:" optname; do
    case "$optname" in
        "I")
            iface="$OPTARG"
            useNIC="--interface $iface"
        ;;
        "M")
            if [[ "$OPTARG" == "4" ]]; then
                NetworkType=4
            elif [[ "$OPTARG" == "6" ]]; then
                NetworkType=6
            fi
        ;;
        "E")
            language="e"
        ;;
        "X")
            XIP="$OPTARG"
            xForward="--header X-Forwarded-For:$XIP"
        ;;
        "P")
            proxy="$OPTARG"
            usePROXY="-x $proxy"
        ;;
        "F")
            func="$OPTARG"
        ;;
        "S")
            Stype="$OPTARG"
        ;;
        "R")
            Resolve="$OPTARG"
            resolve="--resolve *:443:$Resolve"
        ;;
        "C")
            Curl="$OPTARG"
            alias curl=$Curl
        ;;
        "D")
            # Applied by setupCustomDns below, once dependencies are in place
            Dns="$OPTARG"
        ;;
        ":")
            echo "Unknown error while processing options"
            exit 1
        ;;
    esac
done

# Split "12.34.56.78, https://doh.example/dns-query 87.65.43.21" into plain
# nameservers and at most one DoH endpoint
parseDnsSpec() {
    local token
    DNS_SERVERS=()
    DNS_DOH=""
    for token in ${1//,/ }; do
        case "$token" in
            *://*)
                if [ -z "$DNS_DOH" ]; then
                    DNS_DOH="$token"
                else
                    echo -e "${Font_Yellow}  -D: only one DoH endpoint is supported; ignoring ${token}${Font_Suffix}"
                fi
                ;;
            *)
                DNS_SERVERS+=("$token")
                ;;
        esac
    done
}

# Describe why a single nameserver token is unusable. Prints nothing and returns
# 0 when the token is fine, so it doubles as a validator.
# Catches typos like "8.8.88.", "1.2.3", "999.1.1.1" or "dns.example", which
# would otherwise reach the resolver and turn every check into a network failure
# blamed on the target service instead of on the address just typed.
dnsTokenProblem() {
    local s="$1" o o1 o2 o3 o4 extra

    case "$s" in
        http://|https://)
            echo "is not a usable DoH URL"
            return 1
            ;;
        http://?*|https://?*)
            if [[ "$s" =~ ^https?://[^/?#[:space:]]+ ]]; then
                return 0
            fi
            echo "is not a usable DoH URL"
            return 1
            ;;
    esac

    # A colon means this is meant as IPv6: only hex groups and colons are legal
    if [[ "$s" == *:* ]]; then
        if [[ "$s" =~ ^[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,7}$ ]]; then
            return 0
        fi
        echo "is not a valid IPv6 address"
        return 1
    fi

    IFS='.' read -r o1 o2 o3 o4 extra <<< "$s"
    if [ -z "$o1" ] || [ -z "$o2" ] || [ -z "$o3" ] || [ -z "$o4" ] || [ -n "$extra" ]; then
        echo "is not a valid IPv4 address (needs exactly 4 octets)"
        return 1
    fi
    for o in "$o1" "$o2" "$o3" "$o4"; do
        if ! [[ "$o" =~ ^[0-9]{1,3}$ ]]; then
            echo "is not a valid IPv4 address (non-numeric octet)"
            return 1
        fi
        if [ "$((10#$o))" -gt 255 ]; then
            echo "is not a valid IPv4 address (octet above 255)"
            return 1
        fi
    done
    return 0
}

# Validate a whole -D / CUSTOM_DNS specification and describe the first problem
# found. Returns 0 when every token is usable.
dnsSpecProblem() {
    local token problem

    # An empty value means "no override"; callers handle that case themselves,
    # but the validator should still refuse to call nothing valid
    if [ -z "${1//[[:space:]]/}" ]; then
        echo "is empty"
        return 1
    fi

    for token in ${1//,/ }; do
        if ! problem=$(dnsTokenProblem "$token"); then
            echo "\"$token\" ${problem}"
            return 1
        fi
    done
    return 0
}

# Arguments shared by every curl request. A resolver override is applied to the
# whole process tree, so it is deliberately not part of these; DoH is, because
# there curl has to do the work itself.
buildCurlArgs() {
    curlArgs="$useNIC $usePROXY $xForward $resolve $dnsFlags --max-time 10"
}

if [ -z "$iface" ]; then
    useNIC=""
fi
if [ -z "$XIP" ]; then
    xForward=""
fi
if [ -z "$proxy" ]; then
    usePROXY=""
fi
if [ -z "$Resolve" ]; then
    resolve=""
fi

# -D wins over the CUSTOM_DNS default; an empty spec means the system resolver
[ -n "$Dns" ] && CUSTOM_DNS="$Dns"

# Base arguments passed to every curl request
buildCurlArgs
# Spoofed User-Agent to mimic a standard Windows 10 Edge browser
UA_Browser="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Safari/537.36 Edg/112.0.1722.64"

# Captured here, at the top level: inside a function "$@" and "$BASH_SOURCE" refer to
# the function's own arguments and defining file, so the custom DNS re-exec below
# needs the script's own path and its original command line
SELF="${BASH_SOURCE[0]}"
ORIG_ARGS=("$@")

# Check if the OS is strictly Debian 13 or higher
checkOS() {
    if [ ! -f /etc/os-release ]; then
        echo -e "${Font_Red}Error: Could not determine OS. Only Debian 13+ is supported.${Font_Suffix}"
        exit 1
    fi

    local os_id=$(grep -w '^ID' /etc/os-release | cut -d '=' -f 2 | tr -d '"')
    local os_version=$(grep -w '^VERSION_ID' /etc/os-release | cut -d '=' -f 2 | tr -d '"')

    if [[ "$os_id" != "debian" ]]; then
        echo -e "${Font_Red}Error: Unsupported OS ($os_id). Only Debian 13+ is supported.${Font_Suffix}"
        exit 1
    fi

    if ! awk -v v="$os_version" 'BEGIN{exit !(v+0>=13)}'; then
        echo -e "${Font_Red}Error: Unsupported Debian version ($os_version). Only Debian 13+ is supported.${Font_Suffix}"
        exit 1
    fi
}
checkOS

# Ensure required commands (curl, jq) are installed, auto-install via apt if missing
checkDependencies() {
    local missing_deps=()
    if ! command -v curl &>/dev/null; then
        missing_deps+=("curl")
    fi
    if ! command -v jq &>/dev/null; then
        missing_deps+=("jq")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        if [ "$(id -u)" -ne 0 ]; then
            echo -e "${Font_Red}Error: Missing dependencies (${missing_deps[*]}). Re-run as root, or install manually: apt install ${missing_deps[*]}${Font_Suffix}"
            exit 1
        fi
        echo -e "${Font_Yellow}Installing missing dependencies: ${missing_deps[*]}...${Font_Suffix}"
        apt update >/dev/null 2>&1
        apt install -y "${missing_deps[@]}" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${Font_Red}Failed to install dependencies. Please run 'apt install ${missing_deps[*]}' manually.${Font_Suffix}"
            exit 1
        fi
        echo -e "${Font_Green}Dependencies installed successfully.${Font_Suffix}"
    fi
}
checkDependencies

# =========================================================
# Custom DNS (-D / CUSTOM_DNS)
# =========================================================
# curl cannot be pointed at a plain nameserver on Debian/Ubuntu: --dns-servers is
# advertised by --help but fails at runtime, because those curl builds resolve via
# glibc instead of c-ares. So the resolver itself is swapped for this process
# tree. Neither strategy touches a real system file:
#
#   1. private mount namespace: a generated resolv.conf is bind-mounted over the
#      real one *inside* a fresh mount namespace, and this script is re-executed
#      there. The mount exists only in that namespace and disappears with the
#      process, so /etc/resolv.conf and /etc/nsswitch.conf on disk are never
#      opened for writing. Needs root, unshare (util-linux) and a script file.
#   2. DoH only: handed straight to curl with --doh-url, which needs neither
#      c-ares nor privileges, so it also works for an unprivileged user.
#
# There is deliberately no fallback that rewrites /etc/resolv.conf: that would be
# a real system modification (and a kill -9 could leave it behind), so when
# neither strategy can be used the -D value is simply not applied, with a message
# saying so.
#
# Debian with systemd-resolved lists "resolve" in nsswitch.conf, which makes glibc
# bypass /etc/resolv.conf completely, so in case 1 the namespace override covers
# nsswitch.conf too (again as a bind mount, never a file write).
# Runs after checkDependencies so any apt install still uses the normal resolver.

# Human readable description of the active override, shown in the banner
describeDns() {
    local servers="${DNS_SERVERS[*]}"
    case "$1" in
        doh)
            DNS_LABEL="DoH ${DNS_DOH}"
            ;;
        namespace)
            DNS_LABEL="${servers} (private mount namespace)"
            ;;
    esac
}

# Build a resolv.conf body for the namespaces bind mount, in $1. Only ever
# written inside a temp file, never over a real system path.
writeDnsResolvConf() {
    local out="$1" server
    {
        for server in "${DNS_SERVERS[@]}"; do
            printf 'nameserver %s\n' "$server"
        done
        printf 'options timeout:2 attempts:2\n'
    } > "$out"
}

# Same for nsswitch.conf: a temp copy with "hosts: files dns", so glibc really
# reads the overridden resolv.conf instead of asking systemd-resolved.
# Returns 1 when no change is needed (glibc already reads /etc/resolv.conf).
writeDnsNsswitchConf() {
    local out="$1"
    [ -f /etc/nsswitch.conf ] || return 1
    grep -qE '^hosts:.*[[:space:]]resolve([[:space:]]|$)' /etc/nsswitch.conf || return 1
    sed -E 's/^hosts:.*/hosts: files dns/' /etc/nsswitch.conf > "$out" 2>/dev/null || return 1
    [ -s "$out" ]
}

# Strategy 1: bind-mount the overrides over the real files inside a private
# mount namespace and re-execute this script there
applyDnsInNamespace() {
    # Re-executing needs a script file, which does not exist when piped into bash
    [ -f "$SELF" ] || return 1
    command -v unshare >/dev/null 2>&1 || return 1
    # Probe the capability first, so a forbidden unshare cannot abort the run
    unshare -m true 2>/dev/null || return 1

    local target resolv nsswitch=""
    target=$(readlink -f /etc/resolv.conf 2>/dev/null)
    [ -n "$target" ] || target=/etc/resolv.conf

    resolv=$(mktemp) || return 1
    if ! writeDnsResolvConf "$resolv"; then
        rm -f "$resolv"
        return 1
    fi
    nsswitch=$(mktemp) || nsswitch=""
    if [ -n "$nsswitch" ] && ! writeDnsNsswitchConf "$nsswitch"; then
        rm -f "$nsswitch"
        nsswitch=""
    fi

    # The child binds the overrides over the real files and then deletes the
    # sources: the mounts keep their content, so no temporary file is left
    # behind. It then re-executes this script, so every lookup - curl's included -
    # goes through the custom resolver. CUSTOM_DNS_ACTIVE=1 tells the re-executed
    # script the override is in place; 0 means "attempted and failed", so it must
    # not try to re-execute again.
    exec unshare -m bash -c '
        resolv="$1"; nsswitch="$2"; target="$3"; shift 3
        if mount --bind "$resolv" "$target" 2>/dev/null; then
            rm -f "$resolv"
            export CUSTOM_DNS_ACTIVE=1
            if [ -n "$nsswitch" ] && mount --bind "$nsswitch" /etc/nsswitch.conf 2>/dev/null; then
                rm -f "$nsswitch"
            fi
        else
            rm -f "$resolv" "$nsswitch"
            export CUSTOM_DNS_ACTIVE=0
            echo "  -D: could not bind the resolver override in a private namespace."
        fi
        exec bash "$@"
    ' rrc-dns "$resolv" "$nsswitch" "$target" "$SELF" "${ORIG_ARGS[@]}"
}

setupCustomDns() {
    parseDnsSpec "$1"

    # The re-executed script arrives here with the namespace already in place
    if [ "$CUSTOM_DNS_ACTIVE" = "1" ]; then
        DNS_MODE="namespace"
        describeDns namespace
        return 0
    fi

    if [ ${#DNS_SERVERS[@]} -eq 0 ]; then
        if [ -n "$DNS_DOH" ]; then
            # curl speaks DoH natively, so nothing has to be overridden here
            dnsFlags="--doh-url $DNS_DOH"
            buildCurlArgs
            DNS_MODE="doh"
            describeDns doh
            return 0
        fi
        echo -e "${Font_Red}  -D: no usable nameserver in \"$1\"; keeping the default DNS.${Font_Suffix}"
        return 1
    fi

    # 0 means a namespace was already attempted (and failed) by a parent process
    if [ "$CUSTOM_DNS_ACTIVE" != "0" ]; then
        applyDnsInNamespace   # re-executes the script, so it never returns on success
    fi

    # No in-place fallback on purpose: rewriting /etc/resolv.conf would be a real
    # change to the system, so this path refuses and says why instead
    echo -e "${Font_Red}  -D: cannot apply ${DNS_SERVERS[*]} without touching system files.${Font_Suffix}"
    echo -e "${Font_Red}     Needs root, unshare (util-linux) and this script run from a file.${Font_Suffix}"
    echo -e "${Font_Yellow}     Keeping the default DNS. Use a DoH URL instead to avoid privileges.${Font_Suffix}"
    return 1
}

# Ask on a terminal whether to use a custom DNS, and for its address if so.
# Default is "no": pressing Enter alone keeps the system resolver, which is also
# what happens when the question cannot be asked at all.
# Skipped when -D or CUSTOM_DNS already gave an answer; also skipped when stdin is
# not a terminal, both because nobody could answer and because with a piped script
# (curl | bash) a read would consume the script itself instead of a keystroke.
promptCustomDns() {
    [ -t 0 ] && [ -t 1 ] || return 0

    local answer spec problem
    printf '  Use a custom DNS? [y/N]: '
    read -r answer || return 0        # EOF / closed stdin
    answer="${answer//[[:space:]]/}"  # drops CR from CRLF terminals too
    case "${answer,,}" in
        y|yes) ;;
        *) return 0 ;;
    esac

    # Keep asking while the address is malformed. Applying a typo here would make
    # every single check fail with a network error and blame the services.
    while :; do
        printf '  DNS server (IP or DoH URL, Enter to cancel): '
        read -r spec || return 0
        # Trim blanks and a stray CR pasted along with the address
        spec="${spec//$'\r'/}"
        spec="${spec#"${spec%%[![:space:]]*}"}"
        spec="${spec%"${spec##*[![:space:]]}"}"

        if [ -z "$spec" ]; then
            echo -e "${Font_Yellow}  No DNS given; keeping the default DNS.${Font_Suffix}"
            return 0
        fi
        if ! problem=$(dnsSpecProblem "$spec"); then
            echo -e "${Font_Red}  Invalid DNS: ${problem}${Font_Suffix}"
            echo -e "${Font_Yellow}  Expected an IPv4/IPv6 address or an http(s) DoH URL.${Font_Suffix}"
            continue
        fi
        break
    done

    CUSTOM_DNS="$spec"
    # Exported so the namespace re-execution below sees it too and does not ask again
    export CUSTOM_DNS
    return 0
}

# Banner first, so the question below appears under the script title. Skipped in
# the re-executed process: the parent already printed it, and CUSTOM_DNS_ACTIVE is
# set (to 1 on success, 0 when the namespace could not be set up) exactly then.
if [ -z "$CUSTOM_DNS_ACTIVE" ]; then
    echo -e "\n${Font_Purple}[ Minimal Service Region Check ]${Font_Suffix}"
    echo -e "${Font_Purple}Legend:${Font_Suffix} ${Font_Green}Green=Available${Font_Suffix} | ${Font_Yellow}Yellow=Partial${Font_Suffix} | ${Font_Red}Red=Unavailable/Failed${Font_Suffix}\n"
fi

# Neither -D nor CUSTOM_DNS answered the question, so ask it on a terminal
if [ -z "$CUSTOM_DNS" ]; then
    promptCustomDns
fi

if [ -n "$CUSTOM_DNS" ]; then
    # Refuse a malformed address outright: falling back to the system resolver
    # would silently report a completely different network than the one asked for
    if ! dnsProblem=$(dnsSpecProblem "$CUSTOM_DNS"); then
        echo -e "${Font_Red}Error: invalid DNS ${dnsProblem}${Font_Suffix}"
        echo -e "${Font_Red}  Expected an IPv4/IPv6 address or an http(s) DoH URL.${Font_Suffix}"
        exit 1
    fi
    setupCustomDns "$CUSTOM_DNS"
fi

# Warn early when the custom resolver cannot answer, instead of letting every
# check fail later with a network error
if [ "$DNS_MODE" = "namespace" ]; then
    getent ahostsv4 www.cloudflare.com >/dev/null 2>&1 \
        || echo -e "${Font_Yellow}  -D: ${DNS_SERVERS[0]} did not answer a test lookup; checks may fail.${Font_Suffix}"
fi

# Fetch required payload templates (cookies) for Disney+ tests
# NOTE: must run in foreground; backgrounding inside $() always yields empty string
# Prefer lmc999 upstream (same as RegionRestrictionCheck); fall back to 1-stream mirror
Media_Cookie=$(curl -s $dnsFlags --retry 3 --max-time 10 "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/cookies")
if [ -z "$Media_Cookie" ]; then
    Media_Cookie=$(curl -s $dnsFlags --retry 3 --max-time 10 "https://raw.githubusercontent.com/1-stream/RegionRestrictionCheck/main/cookies")
fi
if [ -z "$Media_Cookie" ]; then
    echo -e "${Font_Yellow}Warning: Failed to fetch Disney+ cookie template; Disney+ test may fail.${Font_Suffix}"
fi

# Fetch IATA airport code reference, used to turn YouTube CDN node names
# into readable locations (e.g. "ncsina-ag" -> ISP NCSINA at IATA code AG)
# NOTE: this file is CRLF, so CR must be stripped or plain entries (e.g. "NRT")
# never match when compared as a whole field
IATACode=$(curl -s $dnsFlags --retry 3 --max-time 10 "https://raw.githubusercontent.com/1-stream/RegionRestrictionCheck/main/reference/IATACode.txt" | tr -d '\r')
if [ -z "$IATACode" ]; then
    IATACode=$(curl -s $dnsFlags --retry 3 --max-time 10 "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/reference/IATACode.txt" | tr -d '\r')
fi

# Print a section header
ShowRegion() {
    echo -e "${Font_Yellow} --- ${1} ---${Font_Suffix}"
}

# Helper to format and align test results
PrintResult() {
    local name="$1"
    local result="$2"
    printf "  %-24s %b\n" "$name" "$result"
}

# Turn a curl exit code into a short reason, so a connection failure says why it
# failed instead of lumping DNS, TCP and TLS problems into one vague word.
curlFailReason() {
    case "$1" in
        1)  echo "Unsupported protocol" ;;
        5)  echo "DNS proxy" ;;
        6)  echo "DNS" ;;
        7)  echo "Connect" ;;
        22) echo "HTTP error" ;;
        28) echo "Timeout" ;;
        35) echo "TLS" ;;
        52) echo "Empty reply" ;;
        56) echo "Recv failure" ;;
        *)  echo "Network, curl $1" ;;
    esac
}

# Report a transport failure: the reason from curl's exit code plus the address
# the resolver actually handed out. The address is what separates "this DNS has
# no entry for the service" from "the service is unreachable".
# $1 = label, $2 = curl exit code, $3 = hostname, $4 = 4 or 6.
PrintNetFail() {
    local label="$1" rc="$2" host="${3:-}" family="${4:-4}" ip=""

    if [ -n "$host" ]; then
        case "$family" in
            6) ip=$(getent ahostsv6 "$host" 2>/dev/null | awk 'NR==1{print $1}') ;;
            *) ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}') ;;
        esac
    fi

    if [ -n "$ip" ]; then
        PrintResult "$label" "${Font_Red}Failed ($(curlFailReason "$rc") @${ip})${Font_Suffix}"
    else
        PrintResult "$label" "${Font_Red}Failed ($(curlFailReason "$rc"))${Font_Suffix}"
    fi
}

# Build a "REGION | ASxxxx | ISP" description for an IP address.
# $1 = IP address, $2 = region code from the Cloudflare trace (loc=).
# ASN and holder come from RIPE Stat, which needs no API key. Failures are
# non-fatal: any missing piece is simply omitted from the output.
GetIPInfo() {
    local ip="$1"
    local country="$2"
    local asn="" isp=""

    if [ -n "$ip" ]; then
        local ripe=$(curl $curlArgs -s --max-time 10 "https://stat.ripe.net/data/prefix-overview/data.json?resource=$ip" 2>/dev/null)
        if [ -n "$ripe" ]; then
            asn=$(echo "$ripe" | jq -r '.data.asns[0].asn // empty' 2>/dev/null)
            isp=$(echo "$ripe" | jq -r '.data.asns[0].holder // empty' 2>/dev/null)
        fi
    fi

    local info=""
    [ -n "$country" ] && info="$country"
    [ -n "$asn" ] && info="${info:+${info} | }AS${asn}"
    [ -n "$isp" ] && info="${info:+${info} | }${isp}"
    echo "$info"
}

# Resolve an IATA code to a city name using the IATACode reference file.
# Column 3 holds an IATA token, optionally followed by a suffix
# (e.g. "BER - All Airports", "YMQ All"), so only the leading token is compared.
lookup_iata() {
    local code="$1"
    [ -n "$code" ] || return
    [ -n "$IATACode" ] || return
    echo "$IATACode" | awk -F'|' -v want="$code" '
        {
            field = $3
            gsub(/\r/, "", field)
            sub(/^[ \t]+/, "", field)
            n = split(field, parts, /[ \t-]+/)
            if (toupper(parts[1]) == toupper(want)) {
                city = $1
                gsub(/^[ \t]+|[ \t]+$/, "", city)
                print city
                exit
            }
        }'
}

# Check Google Search location. The old endpoint (the bard.google.com
# batchexecute JSON API) is retired and answers a plain "Error 404" HTML page
# now, so this check could only ever print Failed. Google still localises its
# homepage footer to the country domain it would serve results from
# (google.com.hk, google.com.sg, google.co.uk, ...), so read the region there.
function Test_Google() {
    local label="Google Search:"
    local body meta code rc ip region

    body=$(mktemp) || {
        PrintResult "$label" "${Font_Red}Failed (no temp file)${Font_Suffix}"
        return
    }
    meta=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 \
        -o "$body" -w '%{http_code}' "https://www.google.com/" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        ip=$(getent ahostsv4 www.google.com 2>/dev/null | awk 'NR==1{print $1}')
        rm -f "$body"
        if [ -n "$ip" ]; then
            PrintResult "$label" "${Font_Red}Failed ($(curlFailReason "$rc") @${ip})${Font_Suffix}"
        else
            PrintResult "$label" "${Font_Red}Failed ($(curlFailReason "$rc"))${Font_Suffix}"
        fi
        return
    fi
    code=$meta

    # Country domain in the footer. google.com itself is the global site, so an
    # empty result means "reachable, country unknown" rather than a failure.
    region=$(grep -oE 'google\.(com\.[a-z]{2,3}|co\.[a-z]{2})' "$body" 2>/dev/null \
        | head -1 | sed -E 's/^google\.(com|co)\.//' | tr 'a-z' 'A-Z')
    rm -f "$body"

    if [[ "$code" != 2* ]]; then
        PrintResult "$label" "${Font_Red}No (HTTP ${code})${Font_Suffix}"
        return
    fi

    if [ -n "$region" ]; then
        PrintResult "$label" "${Font_Green}Yes (Region: ${region})${Font_Suffix}"
    else
        PrintResult "$label" "${Font_Green}Yes${Font_Suffix}"
    fi
}

# Check Google Gemini location via the batchexecute JSON API
function Test_Gemini() {
    local label="Google Gemini:"
    local body meta code rc ip region

    body=$(mktemp) || {
        PrintResult "$label" "${Font_Red}Failed (no temp file)${Font_Suffix}"
        return
    }
    meta=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 \
        -o "$body" -w '%{http_code}' \
        'https://gemini.google.com/_/BardChatUi/data/batchexecute' \
        -H 'accept-language: en-US' \
        --data-raw 'f.req=[[["K4WWud","[[0],[\"en-US\"]]",null,"generic"]]]' 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        ip=$(getent ahostsv4 gemini.google.com 2>/dev/null | awk 'NR==1{print $1}')
        rm -f "$body"
        if [ -n "$ip" ]; then
            PrintResult "$label" "${Font_Red}Failed ($(curlFailReason "$rc") @${ip})${Font_Suffix}"
        else
            PrintResult "$label" "${Font_Red}Failed ($(curlFailReason "$rc"))${Font_Suffix}"
        fi
        return
    fi
    code=$meta

    # The data field of the envelope decodes to
    #   [["<country name>","SWML_DESCRIPTION_FROM_YOUR_INTERNET_ADDRESS",...]]
    # so parse it as JSON and take the leading literal, instead of chopping a
    # fixed number of characters off the escaped text (the old approach broke
    # whenever the payload gained a prefix or a trailing element).
    region=$(grep 'K4WWud' "$body" 2>/dev/null | jq -r '.[0][2]' 2>/dev/null \
        | grep -oE '^\[\["[^"]+' | sed 's/^\[\["//')
    rm -f "$body"

    if [ -n "$region" ]; then
        PrintResult "$label" "${Font_Green}Yes (Region: ${region})${Font_Suffix}"
        return
    fi
    if [[ "$code" != 2* ]]; then
        PrintResult "$label" "${Font_Red}No (HTTP ${code})${Font_Suffix}"
    else
        PrintResult "$label" "${Font_Red}No${Font_Suffix}"
    fi
}

# Check OpenAI ChatGPT availability and blocked ISP traces
function Test_ChatGPT() {
    local label="OpenAI ChatGPT:"
    local tmpresult cf_details region1 probe code body
    local i unlocked=0 regionBlocked=0 rc gotAnswer=0 lastRc=0

    tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsLI --max-time 10 "https://chatgpt.com" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        PrintNetFail "$label" "$rc" "chatgpt.com" "$1"
        return
    fi

    # Small JSON endpoint that reports Cloudflare details and the block reasons
    # the web front end would show. Its absence only costs detail, so a failure
    # here is not fatal.
    tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 "https://ios.chat.openai.com" 2>/dev/null)
    cf_details=$(echo "$tmpresult" | jq '.cf_details' 2>/dev/null)

    if [[ "$tmpresult" == *"blocked_why_headline"* ]]; then
        PrintResult "$label" "${Font_Red}No (Blocked)${Font_Suffix}"
        return
    fi
    if [[ "$tmpresult" == *"unsupported_country_region_territory"* ]]; then
        PrintResult "$label" "${Font_Red}No (Unsupported Region)${Font_Suffix}"
        return
    fi

    # The front page is no longer a signal: chatgpt.com answers HTTP 200 directly
    # instead of redirecting, so the old "no location header => No" rule reported
    # No for every connection, unlocked or not. Ask the API layer instead:
    # backend-api/me answers 401/200 when the region is accepted (401 is just
    # "log in") and 403 unsupported_country when it is not. An unlock DNS relays
    # through several egress nodes and lands on an unsupported one now and then,
    # so retry before believing a rejection.
    for i in 1 2 3; do
        probe=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 \
            -w '\n%{http_code}' "https://chatgpt.com/backend-api/me" 2>/dev/null)
        lastRc=$?
        if [ "$lastRc" -eq 0 ]; then
            gotAnswer=1
            code=${probe##*$'\n'}
            body=${probe%$'\n'*}
            case "$code" in
                200|401)
                    unlocked=1
                    break
                    ;;
                403)
                    [[ "$body" == *"unsupported_country"* ]] && regionBlocked=1
                    ;;
            esac
        fi

        # Inconclusive (transport failure or an odd status): ask the endpoint
        # upstream uses as a tiebreaker
        probe=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 \
            -H 'authorization: Bearer null' -H 'content-type: application/json' \
            "https://api.openai.com/compliance/cookie_requirements" 2>/dev/null)
        lastRc=$?
        if [ "$lastRc" -ne 0 ] || [ -z "$probe" ]; then
            continue
        fi
        gotAnswer=1
        case "$probe" in
            *unsupported_country*) regionBlocked=1 ;;
            *) unlocked=1; break ;;
        esac
    done

    # Every probe died in transport, so there is no regional verdict to report
    if [ "$unlocked" -eq 0 ] && [ "$gotAnswer" -eq 0 ]; then
        PrintNetFail "$label" "$lastRc" "chatgpt.com" "$1"
        return
    fi

    if [ "$unlocked" -eq 0 ]; then
        if [[ "$cf_details" == *"(1)"* ]]; then
            PrintResult "$label" "${Font_Red}No (Disallowed ISP[1])${Font_Suffix}"
            return
        fi
        if [[ "$cf_details" == *"(2)"* ]]; then
            PrintResult "$label" "${Font_Red}No (Disallowed ISP[2])${Font_Suffix}"
            return
        fi
        if [ "$regionBlocked" -eq 1 ]; then
            PrintResult "$label" "${Font_Red}No (Unsupported Region)${Font_Suffix}"
            return
        fi
        PrintResult "$label" "${Font_Red}No${Font_Suffix}"
        return
    fi

    region1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 "https://chatgpt.com/cdn-cgi/trace" 2>/dev/null | grep "loc=" | awk -F= '{print $2}')
    if [[ "$cf_details" == *"(1)"* ]]; then
        PrintResult "$label" "${Font_Yellow}Web Only (Disallowed ISP[1])${Font_Suffix}"
        return
    fi
    if [[ "$cf_details" == *"(2)"* ]]; then
        PrintResult "$label" "${Font_Yellow}Web Only (Disallowed ISP[2])${Font_Suffix}"
        return
    fi
    if [ -n "$region1" ]; then
        PrintResult "$label" "${Font_Green}Yes (Region: ${region1})${Font_Suffix}"
    else
        PrintResult "$label" "${Font_Green}Yes${Font_Suffix}"
    fi
}

# Check Claude.ai availability. Unsupported countries are redirected to
# /unavailable, which was the whole point of the old check. It only inspected
# the final URL though, so a Cloudflare challenge (HTTP 403 "Just a moment...",
# which datacenter IPs get all the time) fell through to "Yes" - a positive
# verdict about a page that was never actually served.
function Test_Claude(){
    local label="Anthropic Claude:"
    local body meta code url rc ip

    body=$(mktemp) || {
        PrintResult "$label" "${Font_Red}Failed (no temp file)${Font_Suffix}"
        return
    }
    meta=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 \
        -o "$body" -w '%{http_code} %{url_effective}' "https://claude.ai/" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        ip=$(getent ahostsv4 claude.ai 2>/dev/null | awk 'NR==1{print $1}')
        rm -f "$body"
        if [ -n "$ip" ]; then
            PrintResult "$label" "${Font_Red}Failed ($(curlFailReason "$rc") @${ip})${Font_Suffix}"
        else
            PrintResult "$label" "${Font_Red}Failed ($(curlFailReason "$rc"))${Font_Suffix}"
        fi
        return
    fi
    code=${meta%% *}
    url=${meta#* }

    # Anthropic redirects a country it does not serve to /unavailable
    if [[ "$url" == *unavailable* ]] \
        || grep -qiE 'not available in your (country|region)' "$body" 2>/dev/null; then
        rm -f "$body"
        PrintResult "$label" "${Font_Red}No${Font_Suffix}"
        return
    fi

    # Cloudflare's challenge page says nothing about the region, so it must not
    # be reported as available either
    if grep -qiE 'Attention Required|Just a moment|you have been blocked|Cloudflare Ray ID' "$body" 2>/dev/null; then
        rm -f "$body"
        PrintResult "$label" "${Font_Yellow}Blocked (Cloudflare challenge)${Font_Suffix}"
        return
    fi
    rm -f "$body"

    if [[ "$code" == 2* ]]; then
        PrintResult "$label" "${Font_Green}Yes${Font_Suffix}"
    else
        PrintResult "$label" "${Font_Red}No (HTTP ${code})${Font_Suffix}"
    fi
}

# Check Netflix availability for full catalog or originals only
function Test_Netflix() {
    local label="Netflix:"
    local body1 body2 rc playable1 playable2 region1

    body1=$(mktemp) || {
        PrintResult "$label" "${Font_Red}Failed (no temp file)${Font_Suffix}"
        return
    }

    # 81280792 = LEGO Ninjago (non-original); 70143836 = Breaking Bad (licensed)
    # --tlsv1.3 matches upstream: Netflix fingerprints the TLS handshake
    curl $curlArgs -${1} --user-agent "${UA_Browser}" -sL --tlsv1.3 --max-time 10 \
        -o "$body1" "https://www.netflix.com/title/81280792" 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$body1"
        PrintNetFail "$label" "$rc" "www.netflix.com" "$1"
        return
    fi

    body2=$(mktemp) || {
        rm -f "$body1"
        PrintResult "$label" "${Font_Red}Failed (no temp file)${Font_Suffix}"
        return
    }
    curl $curlArgs -${1} --user-agent "${UA_Browser}" -sL --tlsv1.3 --max-time 10 \
        -o "$body2" "https://www.netflix.com/title/70143836" 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$body1" "$body2"
        PrintNetFail "$label" "$rc" "www.netflix.com" "$1"
        return
    fi

    # "og:video" is only emitted for a playable title; "Oh no!" means the
    # title is unavailable in the current region
    playable1=$(grep -c 'og:video' "$body1" 2>/dev/null)
    playable2=$(grep -c 'og:video' "$body2" 2>/dev/null)

    # Region id lives in the reactContext JSON: models.geo.data.requestCountry
    # (line-based field cutting is unreliable because the page is minified)
    region1=$(grep -oE '"requestCountry":\{[^}]*\}' "$body1" 2>/dev/null | head -n1 | grep -oE '"id":"[^"]{2}"' | cut -d'"' -f4)
    rm -f "$body1" "$body2"

    # At least one title playable => unlocked
    if [ "$playable1" -gt 0 ] || [ "$playable2" -gt 0 ]; then
        if [ -n "$region1" ]; then
            PrintResult "$label" "${Font_Green}Yes (Region: ${region1})${Font_Suffix}"
        else
            PrintResult "$label" "${Font_Green}Yes${Font_Suffix}"
        fi
        return
    fi

    # Nothing playable but the region is known => originals only (or fully blocked)
    if [ -n "$region1" ]; then
        PrintResult "$label" "${Font_Yellow}Originals Only (Region: ${region1})${Font_Suffix}"
        return
    fi

    PrintResult "$label" "${Font_Red}Failed (no playable title)${Font_Suffix}"
}

# Check which Netflix Open Connect Appliance (OCA) serves this connection,
# i.e. which cache city/ISP the Netflix traffic is actually routed to.
# "isp.1.oca" in the target hostname means the ISP embeds the cache itself
# (Open Connect partner); otherwise the route lands on Netflix's own OCA.
function Test_NetflixCDN() {
    local label="Netflix CDN:"
    local body rc isp target_city target_country target_url target_fqdn

    body=$(mktemp) || {
        PrintResult "$label" "${Font_Red}Failed (no temp file)${Font_Suffix}"
        return
    }
    curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 -o "$body" \
        "https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=1" 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$body"
        PrintNetFail "$label" "$rc" "api.fast.com" "$1"
        return
    fi

    isp=$(jq -r '.client.isp // empty' "$body" 2>/dev/null)
    target_city=$(jq -r '.targets[0].location.city // empty' "$body" 2>/dev/null)
    target_country=$(jq -r '.targets[0].location.country // empty' "$body" 2>/dev/null)
    target_url=$(jq -r '.targets[0].url // empty' "$body" 2>/dev/null)
    rm -f "$body"

    target_fqdn=$(echo "$target_url" | awk -F"/" '{print $3}' | awk -F"." '{print $1}')

    if [ -z "$target_city" ]; then
        PrintResult "$label" "${Font_Red}Failed (no speedtest target)${Font_Suffix}"
        return
    fi

    if [[ "$target_url" == *"isp.1.oca"* ]]; then
        if [ -n "$isp" ]; then
            PrintResult "$label" "${Font_Yellow}${isp}'s OCAs in ${target_city},${target_country} (${target_fqdn})${Font_Suffix}"
        else
            PrintResult "$label" "${Font_Yellow}ISP's OCAs in ${target_city},${target_country} (${target_fqdn})${Font_Suffix}"
        fi
        return
    fi

    PrintResult "$label" "${Font_Green}${target_city},${target_country} (${target_fqdn})${Font_Suffix}"
}

# Check Disney+ availability and specific region logic using GraphQL
function Test_DisneyPlus() {
    # 1. Fetch pre-assertion payload
    local PreAssertion rc
    PreAssertion=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -s --max-time 10 -X POST "https://disney.api.edge.bamgrid.com/devices" -H "authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" -H "content-type: application/json; charset=UTF-8" -d '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}' 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        PrintNetFail "Disney+:" "$rc" "disney.api.edge.bamgrid.com" "$1"
        return
    fi
    if [ -z "$PreAssertion" ]; then
        PrintResult "Disney+:" "${Font_Red}Failed (Empty reply)${Font_Suffix}"
        return
    fi

    local is403=$(echo "$PreAssertion" | grep -i '403 ERROR')
    if [ -n "$is403" ]; then
        PrintResult "Disney+:" "${Font_Red}No (Banned)${Font_Suffix}"
        return
    fi

    # 2. Extract assertion and fetch token using the cookie template
    local assertion=$(echo "$PreAssertion" | grep -woP '"assertion"\s{0,}:\s{0,}"\K[^"]+')
    if [ -z "$assertion" ]; then
        PrintResult "Disney+:" "${Font_Red}Failed (No Assertion)${Font_Suffix}"
        return
    fi
    if [ -z "$Media_Cookie" ]; then
        PrintResult "Disney+:" "${Font_Red}Failed (No Cookie Template)${Font_Suffix}"
        return
    fi
    local PreDisneyCookie=$(echo "$Media_Cookie" | sed -n '1p')
    local disneycookie=$(echo "$PreDisneyCookie" | sed "s/DISNEYASSERTION/${assertion}/g")
    local TokenContent
    TokenContent=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -s --max-time 10 -X POST "https://disney.api.edge.bamgrid.com/token" -H "authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" -d "$disneycookie" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        PrintNetFail "Disney+:" "$rc" "disney.api.edge.bamgrid.com" "$1"
        return
    fi
    if [ -z "$TokenContent" ]; then
        PrintResult "Disney+:" "${Font_Red}Failed (Empty reply)${Font_Suffix}"
        return
    fi

    local isBanned=$(echo "$TokenContent" | grep -i 'forbidden-location')
    is403=$(echo "$TokenContent" | grep -i '403 ERROR')

    if [ -n "$isBanned" ] || [ -n "$is403" ]; then
        PrintResult "Disney+:" "${Font_Red}No (Banned)${Font_Suffix}"
        return
    fi

    # 3. Use refresh token to query region details
    local fakecontent=$(echo "$Media_Cookie" | sed -n '8p')
    local refreshToken=$(echo "$TokenContent" | grep -woP '"refresh_token"\s{0,}:\s{0,}"\K[^"]+')
    if [ -z "$refreshToken" ]; then
        PrintResult "Disney+:" "${Font_Red}Failed (No Refresh Token)${Font_Suffix}"
        return
    fi
    local disneycontent=$(echo "$fakecontent" | sed "s/ILOVEDISNEY/${refreshToken}/g")
    # NOTE: GraphQL auth header intentionally has no "Bearer " prefix (matches upstream)
    local tmpresult
    tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -X POST -sSL --max-time 10 "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" -H "authorization: ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" -d "$disneycontent" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        PrintNetFail "Disney+:" "$rc" "disney.api.edge.bamgrid.com" "$1"
        return
    fi
    if [ -z "$tmpresult" ]; then
        PrintResult "Disney+:" "${Font_Red}Failed (Empty reply)${Font_Suffix}"
        return
    fi

    # 4. Preview check to distinguish between available and unavailable/coming-soon regions
    local previewchecktmp
    previewchecktmp=$(curl $curlArgs -${1} -s -o /dev/null -L --max-time 10 -w '%{url_effective}' "https://disneyplus.com" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        PrintNetFail "Disney+:" "$rc" "disneyplus.com" "$1"
        return
    fi
    local isUnavailable=$(echo "$previewchecktmp" | grep -E 'preview|unavailable')
    local region=$(echo "$tmpresult" | grep -woP '"countryCode"\s{0,}:\s{0,}"\K[^"]+')
    local inSupportedLocation=$(echo "$tmpresult" | grep -woP '"inSupportedLocation"\s{0,}:\s{0,}\K(false|true)')

    if [ -z "$region" ]; then
        PrintResult "Disney+:" "${Font_Red}No${Font_Suffix}"
        return
    fi
    if [[ "$region" == "JP" ]]; then
        PrintResult "Disney+:" "${Font_Green}Yes (Region: JP)${Font_Suffix}"
        return
    fi
    if [ -n "$isUnavailable" ]; then
        PrintResult "Disney+:" "${Font_Red}No${Font_Suffix}"
        return
    fi
    if [[ "$inSupportedLocation" == "false" ]]; then
        PrintResult "Disney+:" "${Font_Yellow}Available For [Disney+ $region] Soon${Font_Suffix}"
        return
    fi
    if [[ "$inSupportedLocation" == "true" ]]; then
        PrintResult "Disney+:" "${Font_Green}Yes (Region: $region)${Font_Suffix}"
        return
    fi

    PrintResult "Disney+:" "${Font_Red}Failed (${inSupportedLocation}_${region})${Font_Suffix}"
}

# Check BBC iPlayer availability by fetching its geolocation API
function Test_BBC() {
    local label="BBC iPlayer:"
    local tmpresult rc result

    # A geo-blocked request answers HTTP 200 with a "geolocation" marker in the
    # body (verified), so -f only ever fires on a real transport/HTTP problem
    tmpresult=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsL --max-time 10 "https://open.live.bbc.co.uk/mediaselector/6/select/version/2.0/mediaset/pc/vpid/bbc_one_london/format/json/jsfunc/JS_callbacks0" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        PrintNetFail "$label" "$rc" "open.live.bbc.co.uk" "$1"
        return
    fi

    result=$(echo "$tmpresult" | grep 'geolocation')
    if [ -n "$result" ]; then
        PrintResult "$label" "${Font_Red}No${Font_Suffix}"
    else
        PrintResult "$label" "${Font_Green}Yes${Font_Suffix}"
    fi
}

# Check YouTube Premium availability by parsing main page elements
function Test_YouTube_Premium() {
    local label="YouTube Premium:"
    local tmpresult rc isCN isAvailable region

    tmpresult=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} --max-time 10 -sSL -H "Accept-Language: en" "https://www.youtube.com/premium" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        PrintNetFail "$label" "$rc" "www.youtube.com" "$1"
        return
    fi

    isCN=$(echo "$tmpresult" | grep 'www.google.cn')
    if [ -n "$isCN" ]; then
        PrintResult "$label" "${Font_Red}No (Region: CN)${Font_Suffix}"
        return
    fi

    isAvailable=$(echo "$tmpresult" | grep 'Premium is not available in your country')
    # The page is minified into one huge line, so line-based field cutting
    # returns an arbitrary field; match the "countryCode":"XX" pair directly
    region=$(echo "$tmpresult" | grep -oE '"countryCode":"[^"]{2}"' | head -1 | cut -d'"' -f4)
    if [ -z "$isAvailable" ]; then
        if [ -n "$region" ]; then
            PrintResult "$label" "${Font_Green}Yes (Region: $region)${Font_Suffix}"
        else
            PrintResult "$label" "${Font_Green}Yes${Font_Suffix}"
        fi
    else
        if [ -n "$region" ]; then
            PrintResult "$label" "${Font_Red}No (Region: $region)${Font_Suffix}"
        else
            PrintResult "$label" "${Font_Red}No${Font_Suffix}"
        fi
    fi
}

# Check YouTube CDN node to determine proxy network quality and actual route
function Test_YouTube_CDN() {
    local label="YouTube CDN:"
    local tmpresult rc cdn_node cdn_isp cdn_loc location

    tmpresult=$(curl $curlArgs -${1} -sS --max-time 10 "https://redirector.googlevideo.com/report_mapping?di=no" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        PrintNetFail "$label" "$rc" "redirector.googlevideo.com" "$1"
        return
    fi
    if [ -z "$tmpresult" ]; then
        PrintResult "$label" "${Font_Red}Failed (Empty reply)${Font_Suffix}"
        return
    fi

    # Plain-text response format: "<client-ip> => <cdn-node> (<ipv4-prefix>)",
    # e.g. "151.245.184.5 => ncsina-ag (151.245.184.0/24)". The node tells which
    # cache serves this connection, hence the real route/quality of the proxy.
    cdn_node=$(echo "$tmpresult" | awk '{print $3}')
    if [ -z "$cdn_node" ]; then
        PrintResult "$label" "${Font_Red}Failed (unparsable mapping)${Font_Suffix}"
        return
    fi

    # ISP nodes are "<isp>-<iata>" (route goes through the ISP's cache);
    # Google-hosted nodes are "<iata><digits>s<digits>"
    if [[ "$cdn_node" == *"-"* ]]; then
        cdn_isp=$(echo "$cdn_node" | cut -f1 -d"-" | tr 'a-z' 'A-Z')
        cdn_loc=$(echo "$cdn_node" | cut -f2 -d"-" | sed 's/[^a-zA-Z]//g' | tr 'a-z' 'A-Z')
        location=$(lookup_iata "$cdn_loc")
        if [ -n "$location" ]; then
            PrintResult "$label" "${Font_Yellow}${cdn_isp} in ${location} (${cdn_node})${Font_Suffix}"
        else
            PrintResult "$label" "${Font_Yellow}${cdn_isp} (${cdn_node})${Font_Suffix}"
        fi
        return
    fi
    if [[ "$cdn_node" == *"s"* ]]; then
        cdn_loc=$(echo "$cdn_node" | cut -f2 -d"-" | cut -c1-3 | tr 'a-z' 'A-Z')
        location=$(lookup_iata "$cdn_loc")
        if [ -n "$location" ]; then
            PrintResult "$label" "${Font_Green}${location} (${cdn_node})${Font_Suffix}"
        else
            PrintResult "$label" "${Font_Green}${cdn_loc} (${cdn_node})${Font_Suffix}"
        fi
        return
    fi

    PrintResult "$label" "${Font_Red}Failed (unknown node ${cdn_node})${Font_Suffix}"
}

# Check OpenAI Sora availability. The old rule was "no Location header => No",
# which only worked while an unsupported region answered without redirecting:
# sora.com currently answers a Cloudflare challenge page from blocked networks,
# so the redirect check said No for the wrong reason and would also flip to a
# false Yes the day the front end starts redirecting. The status code plus the
# body wording separate the answers that matter: "OpenAI refuses this region",
# "Cloudflare refuses to talk to curl" and "this connection never got anywhere".
function Test_Sora() {
    local label="OpenAI Sora:"
    local body meta code region1 rc ip

    body=$(mktemp) || {
        PrintResult "$label" "${Font_Red}Failed (no temp file)${Font_Suffix}"
        return
    }
    # -o writes the body to a file so the markers can be grepped while -w still
    # appends the status code; stderr is dropped and the exit code kept instead,
    # which is the reliable way to tell a transport failure from an HTTP answer
    meta=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sSL --max-time 10 \
        -o "$body" -w '%{http_code}' "https://sora.com" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        # Name the address the resolver handed out: an unlock DNS that answers
        # with a sinkhole for a service it does not cover makes curl die here,
        # and that address is the only thing separating it from a real outage
        ip=$(getent ahostsv4 sora.com 2>/dev/null | awk 'NR==1{print $1}')
        rm -f "$body"
        if [ -n "$ip" ]; then
            PrintResult "$label" "${Font_Red}Failed ($(curlFailReason "$rc") @${ip})${Font_Suffix}"
        else
            PrintResult "$label" "${Font_Red}Failed ($(curlFailReason "$rc"))${Font_Suffix}"
        fi
        return
    fi
    code=$meta

    # Region from the Cloudflare trace, shown whatever the verdict is
    region1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 "https://sora.com/cdn-cgi/trace" 2>&1 | grep "loc=" | awk -F= '{print $2}')

    # OpenAI's own wording for a country it does not serve
    if grep -qiE 'unsupported_country|not available in your (country|region)' "$body" 2>/dev/null; then
        rm -f "$body"
        PrintResult "$label" "${Font_Red}No (Unsupported Region)${Font_Suffix}"
        return
    fi

    # Cloudflare's challenge / WAF page is not a verdict about the region, so it
    # must not be reported as "No": a real browser passes "Just a moment" on its
    # own, and even "Attention Required" can be a false positive on curl
    if grep -qiE 'Attention Required|Just a moment|you have been blocked|Cloudflare Ray ID' "$body" 2>/dev/null; then
        rm -f "$body"
        if [ -n "$region1" ]; then
            PrintResult "$label" "${Font_Yellow}Blocked (Cloudflare challenge, Region: ${region1})${Font_Suffix}"
        else
            PrintResult "$label" "${Font_Yellow}Blocked (Cloudflare challenge)${Font_Suffix}"
        fi
        return
    fi

    rm -f "$body"

    # A served page means the connection was accepted
    if [[ "$code" == 2* ]]; then
        if [ -n "$region1" ]; then
            PrintResult "$label" "${Font_Green}Yes (Region: ${region1})${Font_Suffix}"
        else
            PrintResult "$label" "${Font_Green}Yes${Font_Suffix}"
        fi
        return
    fi

    if [ -n "$region1" ]; then
        PrintResult "$label" "${Font_Red}No (Region: ${region1}, HTTP ${code})${Font_Suffix}"
    else
        PrintResult "$label" "${Font_Red}No (HTTP ${code})${Font_Suffix}"
    fi
}

# Check Spotify market region via signup page properties
function Test_Spotify() {
    local label="Spotify:"
    local tmpresult rc country

    tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -s --max-time 10 https://www.spotify.com/tw/signup 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        PrintNetFail "$label" "$rc" "www.spotify.com" "$1"
        return
    fi

    country=$(echo "$tmpresult" | grep -oE '"geoCountry":"[A-Z]{2}"' | head -1 | cut -d'"' -f4)

    if [ -n "$country" ]; then
        PrintResult "$label" "${Font_Green}Yes (Region: $country)${Font_Suffix}"
        return
    fi
    PrintResult "$label" "${Font_Red}Failed (no geoCountry)${Font_Suffix}"
}

# Check Steam Store currency representation
function Test_Steam() {
    local label="Steam Currency:"
    local body rc result

    # A body file is needed because the pipeline below would mask curl's exit code
    body=$(mktemp) || {
        PrintResult "$label" "${Font_Red}Failed (no temp file)${Font_Suffix}"
        return
    }
    curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsSL --max-time 10 \
        -o "$body" "https://store.steampowered.com/app/761830" 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$body"
        PrintNetFail "$label" "$rc" "store.steampowered.com" "$1"
        return
    fi

    result=$(grep priceCurrency "$body" | cut -d '"' -f4)
    rm -f "$body"

    if [ -n "$result" ]; then
        PrintResult "$label" "${Font_Green}${result}${Font_Suffix}"
    else
        PrintResult "$label" "${Font_Red}Failed (no price field)${Font_Suffix}"
    fi
}

# Check whether this IP is allowed to edit Wikipedia. Wikipedia blocks known
# open proxies / hosting ranges at the edit layer, so a "Yes" here also means
# the IP is not on their public proxy blacklist (IP reputation signal).
function Test_Wikipedia() {
    local label="Wikipedia Editability:"
    local tmpresult rc result

    tmpresult=$(curl $curlArgs -${1} -s --user-agent "${UA_Browser}" --max-time 10 \
        "https://en.wikipedia.org/w/index.php?title=Wikipedia:WikiProject_on_open_proxies&action=edit" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        PrintNetFail "$label" "$rc" "en.wikipedia.org" "$1"
        return
    fi

    result=$(echo "$tmpresult" | grep -i 'This IP address has been')
    if [ -z "$result" ]; then
        PrintResult "$label" "${Font_Green}Yes${Font_Suffix}"
        return
    fi
    PrintResult "$label" "${Font_Red}No (Blocked)${Font_Suffix}"
}

# Main executor: Runs all tests concurrently but outputs sequentially with grouping
function Run_All_Tests() {
    local IPV=$1
    echo -e "${Font_SkyBlue}> Network Test - IPv${IPV}${Font_Suffix}"
    echo ""

    # Create a temporary directory to store output of each background task
    local tmp_dir=$(mktemp -d)

    # Start all tests concurrently, redirecting output to numbered files
    Test_Google ${IPV} > "$tmp_dir/01" &
    Test_Gemini ${IPV} > "$tmp_dir/02" &
    Test_ChatGPT ${IPV} > "$tmp_dir/03" &
    Test_Sora ${IPV} > "$tmp_dir/04" &
    Test_Claude ${IPV} > "$tmp_dir/05" &
    Test_Netflix ${IPV} > "$tmp_dir/06" &
    Test_NetflixCDN ${IPV} > "$tmp_dir/07" &
    Test_DisneyPlus ${IPV} > "$tmp_dir/08" &
    Test_BBC ${IPV} > "$tmp_dir/09" &
    Test_YouTube_Premium ${IPV} > "$tmp_dir/10" &
    Test_YouTube_CDN ${IPV} > "$tmp_dir/11" &
    Test_Spotify ${IPV} > "$tmp_dir/12" &
    Test_Steam ${IPV} > "$tmp_dir/13" &
    Test_Wikipedia ${IPV} > "$tmp_dir/14" &

    # Wait for all background tasks to complete
    wait

    # Output grouped by category, one blank line after each block so the groups
    # stay visually separate from both each other and the summary
    ShowRegion "AI Services"
    cat "$tmp_dir/01" "$tmp_dir/02" "$tmp_dir/03" "$tmp_dir/04" "$tmp_dir/05" 2>/dev/null
    echo ""
    ShowRegion "Streaming Media"
    cat "$tmp_dir/06" "$tmp_dir/07" "$tmp_dir/08" "$tmp_dir/09" "$tmp_dir/10" "$tmp_dir/11" 2>/dev/null
    echo ""
    ShowRegion "Other Services"
    cat "$tmp_dir/12" "$tmp_dir/13" "$tmp_dir/14" 2>/dev/null
    echo ""

    # Tally results from collected output
    local total=0 yes=0 no=0 partial=0 failed=0
    local GREEN=$'\033[32m'
    local YELLOW=$'\033[33m'
    local RED=$'\033[31m'
    for f in "$tmp_dir"/*; do
        [ -s "$f" ] || continue
        total=$((total+1))
        local line=$(cat "$f")
        if [[ "$line" == *"${GREEN}"* ]]; then
            yes=$((yes+1))
        elif [[ "$line" == *"${RED}"* ]]; then
            if [[ "$line" == *"Failed"* ]]; then
                failed=$((failed+1))
            else
                no=$((no+1))
            fi
        elif [[ "$line" == *"${YELLOW}"* ]]; then
            partial=$((partial+1))
        fi
    done
    echo -e "${Font_Purple}  Summary: ${yes} available, ${no} unavailable, ${partial} partial, ${failed} failed (of ${total})${Font_Suffix}"

    rm -rf "$tmp_dir"
    echo ""
}

if [ -n "$DNS_MODE" ]; then
    echo -e "${Font_SkyBlue}  DNS: ${Font_White}${DNS_LABEL}${Font_Suffix}"
    echo ""
fi

# Start IPv4 Tests
if [[ "$NetworkType" == "4" ]] || [[ -z "$NetworkType" ]]; then
    trace4=$(curl $curlArgs -4 -s --max-time 10 cloudflare.com/cdn-cgi/trace)
    local_ipv4=$(echo "$trace4" | grep '^ip=' | cut -d= -f2)
    loc4=$(echo "$trace4" | grep '^loc=' | cut -d= -f2)
    if [ -n "$local_ipv4" ]; then
        echo -e "${Font_SkyBlue}IPv4 Address: ${Font_Green}${local_ipv4}${Font_Suffix}"
        info4=$(GetIPInfo "$local_ipv4" "$loc4")
        [ -n "$info4" ] && echo -e "${Font_SkyBlue}  IP Info: ${Font_White}${info4}${Font_Suffix}"
        echo ""
        Run_All_Tests 4
    else
        echo -e "${Font_Red}No IPv4 Network Detected.${Font_Suffix}"
        echo ""
    fi
fi

# Start IPv6 Tests
if [[ "$NetworkType" == "6" ]] || [[ -z "$NetworkType" ]]; then
    trace6=$(curl $curlArgs -6 -s --max-time 10 cloudflare.com/cdn-cgi/trace)
    local_ipv6=$(echo "$trace6" | grep '^ip=' | cut -d= -f2)
    loc6=$(echo "$trace6" | grep '^loc=' | cut -d= -f2)
    if [ -n "$local_ipv6" ]; then
        echo -e "${Font_SkyBlue}IPv6 Address: ${Font_Green}${local_ipv6}${Font_Suffix}"
        info6=$(GetIPInfo "$local_ipv6" "$loc6")
        [ -n "$info6" ] && echo -e "${Font_SkyBlue}  IP Info: ${Font_White}${info6}${Font_Suffix}"
        echo ""
        Run_All_Tests 6
    else
        echo -e "${Font_Red}No IPv6 Network Detected.${Font_Suffix}"
        echo ""
    fi
fi

# Closing summary
echo -e "${Font_Green}Testing Done! Thanks for using this script.${Font_Suffix}"
echo -e "${Font_SkyBlue}Finished At: ${Font_White}$(date '+%Y-%m-%d %H:%M:%S %Z')${Font_Suffix}"
echo ""
