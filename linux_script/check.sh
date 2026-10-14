#!/bin/bash
# =========================================================
# Customized Region Restriction Check Script
# This script checks the availability of various regional
# streaming and AI services.
# Supported OS: Debian 13+
# =========================================================

shopt -s expand_aliases

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
            # Applied later by setupCustomDns, which picks a mechanism the local
            # curl build actually supports (see the custom DNS section below)
            Dns="$OPTARG"
        ;;
        ":")
            echo "Unknown error while processing options"
            exit 1
        ;;
    esac
done

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
if [ -z "$Dns" ]; then
    dns=""
fi

# Arguments shared by every request, without any DNS override. The IP banner and
# the metadata lookups use this so they always go through the system resolver.
curlArgsBase="$useNIC $usePROXY $xForward $resolve --max-time 10"
# Requests issued by the tests use this; a custom DNS appends its own arguments
curlArgs="$curlArgsBase $dns"
# Spoofed User-Agent to mimic a standard Windows 10 Edge browser
UA_Browser="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Safari/537.36 Edg/112.0.1722.64"

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

# Fetch required payload templates (cookies) for Disney+ tests
# NOTE: must run in foreground; backgrounding inside $() always yields empty string
# Prefer lmc999 upstream (same as RegionRestrictionCheck); fall back to 1-stream mirror
Media_Cookie=$(curl -s --retry 3 --max-time 10 "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/cookies")
if [ -z "$Media_Cookie" ]; then
    Media_Cookie=$(curl -s --retry 3 --max-time 10 "https://raw.githubusercontent.com/1-stream/RegionRestrictionCheck/main/cookies")
fi
if [ -z "$Media_Cookie" ]; then
    echo -e "${Font_Yellow}Warning: Failed to fetch Disney+ cookie template; Disney+ test may fail.${Font_Suffix}"
fi

# Fetch IATA airport code reference, used to turn YouTube CDN node names
# into readable locations (e.g. "ncsina-ag" -> ISP NCSINA at IATA code AG)
# NOTE: this file is CRLF, so CR must be stripped or plain entries (e.g. "NRT")
# never match when compared as a whole field
IATACode=$(curl -s --retry 3 --max-time 10 "https://raw.githubusercontent.com/1-stream/RegionRestrictionCheck/main/reference/IATACode.txt" | tr -d '\r')
if [ -z "$IATACode" ]; then
    IATACode=$(curl -s --retry 3 --max-time 10 "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/reference/IATACode.txt" | tr -d '\r')
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

# Build a "REGION | ASxxxx | ISP" description for an IP address.
# $1 = IP address, $2 = region code from the Cloudflare trace (loc=).
# ASN and holder come from RIPE Stat, which needs no API key. Failures are
# non-fatal: any missing piece is simply omitted from the output.
GetIPInfo() {
    local ip="$1"
    local country="$2"
    local asn="" isp=""

    if [ -n "$ip" ]; then
        local ripe=$(curl $curlArgsBase -s --max-time 10 "https://stat.ripe.net/data/prefix-overview/data.json?resource=$ip" 2>/dev/null)
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

# =========================================================
# Custom DNS
# =========================================================
# curl only honours --dns-servers when libcurl is built with c-ares, which the
# Debian/Ubuntu builds are not: the option is advertised but fails at runtime.
# Probe once, then use whichever mechanism this build really supports:
#   - --dns-servers  when c-ares is compiled in
#   - --doh-url      for a DoH endpoint (handled by curl itself, no c-ares needed)
#   - dig + --resolve otherwise (bind9-dnsutils is installed on demand)
# Only the test requests follow the custom DNS; the IP banner and the metadata
# lookups keep using the system resolver on purpose.
#
# NOTE: keep TEST_HOSTS in sync whenever a test starts using a new hostname.
TEST_HOSTS=(
    bard.google.com
    gemini.google.com
    chatgpt.com
    ios.chat.openai.com
    sora.com
    claude.ai
    www.netflix.com
    api.fast.com
    disney.api.edge.bamgrid.com
    disneyplus.com
    open.live.bbc.co.uk
    www.youtube.com
    redirector.googlevideo.com
    www.spotify.com
    store.steampowered.com
    en.wikipedia.org
)

dnsServersSupported=0
if ! curl --dns-servers 127.0.0.1 -s -o /dev/null --max-time 3 "http://example.com" 2>&1 | grep -q 'does not support'; then
    dnsServersSupported=1
fi

# Accept an IPv4/IPv6 literal, or an http(s) DoH endpoint such as
# https://dns.example/dns-query
isValidDNS() {
    local ip="$1"
    case "$ip" in
        http://*|https://*) return 0 ;;
    esac
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local octet
        for octet in ${ip//./ }; do
            [ "$octet" -le 255 ] || return 1
        done
        return 0
    fi
    if [[ "$ip" == *:* ]] && [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
        return 0
    fi
    return 1
}

# Resolve every test hostname through $1 and pin the answers with --resolve, so
# the tests follow that resolver even though curl cannot query it directly.
# Fills the globals dnsResolve (curl arguments) and dnsPinned (hosts resolved);
# deliberately not run in a command substitution, that would lose the values.
# IPv6 answers need bracket notation in --resolve.
buildDnsResolve() {
    local server="$1" host ip
    dnsResolve=""
    dnsPinned=0
    for host in "${TEST_HOSTS[@]}"; do
        ip=$(dig +short +time=3 +tries=1 "@$server" A "$host" 2>/dev/null | grep -Eo '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -n1)
        if [ -z "$ip" ]; then
            ip=$(dig +short +time=3 +tries=1 "@$server" AAAA "$host" 2>/dev/null | grep -Eo '^[0-9a-fA-F:]+$' | head -n1)
        fi
        if [ -n "$ip" ]; then
            case "$ip" in
                *:*) dnsResolve="$dnsResolve --resolve $host:443:[$ip]" ;;
                *)   dnsResolve="$dnsResolve --resolve $host:443:$ip" ;;
            esac
            dnsPinned=$((dnsPinned+1))
        fi
    done
}

# Route the test requests through a user-supplied resolver. Returns non-zero
# when the resolver cannot be honoured, leaving the default DNS in place.
setupCustomDns() {
    local server="$1"

    case "$server" in
        http://*|https://*)
            dns="--doh-url $server"
            curlArgs="$curlArgsBase $dns"
            echo -e "${Font_Green}  Custom DNS: ${server} (DoH)${Font_Suffix}"
            return 0
            ;;
    esac

    if [ "$dnsServersSupported" -eq 1 ]; then
        dns="--dns-servers $server"
        curlArgs="$curlArgsBase $dns"
        echo -e "${Font_Green}  Custom DNS: ${server}${Font_Suffix}"
        return 0
    fi

    # No c-ares support: resolve the test hostnames here and pin them instead
    if ! command -v dig >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
        echo -e "${Font_Yellow}  Installing bind9-dnsutils to query ${server}...${Font_Suffix}"
        apt-get update >/dev/null 2>&1
        apt-get install -y bind9-dnsutils >/dev/null 2>&1
    fi
    if ! command -v dig >/dev/null 2>&1; then
        echo -e "${Font_Red}  Custom DNS needs 'dig' on this curl build; keeping the default DNS.${Font_Suffix}"
        echo -e "${Font_Red}  Install it with: apt install bind9-dnsutils${Font_Suffix}"
        return 1
    fi

    local pinned
    buildDnsResolve "$server"
    pinned="$dnsPinned"
    if [ "$pinned" -eq 0 ]; then
        echo -e "${Font_Red}  ${server} resolved none of the test hostnames; keeping the default DNS.${Font_Suffix}"
        return 1
    fi
    dns="$dnsResolve"
    curlArgs="$curlArgsBase $dns"
    echo -e "${Font_Green}  Custom DNS: ${server} (${pinned}/${#TEST_HOSTS[@]} hosts pinned)${Font_Suffix}"
    return 0
}

# Ask whether to keep the system DNS. The prompt auto-continues after 5 seconds;
# typing a resolver and pressing Enter routes the tests through it instead.
#
# Characters are read one at a time with "read -n 1" (which puts the terminal in
# non-canonical mode) instead of a plain "read -t": a plain read only ever
# receives a complete line, so on a real terminal every keystroke typed before
# Enter would sit in the kernel buffer, be invisible to the countdown, then leak
# to the shell once the script exits. Reading per keystroke also makes the input
# visible while typing, and the 5 second budget is only spent on idle ticks so
# typing never eats into the window.
promptCustomDns() {
    # An explicit -D wins and is applied without asking
    if [ -n "$Dns" ]; then
        setupCustomDns "$Dns"
        return
    fi
    # Only prompt on a real terminal: with piped or redirected streams the prompt
    # could swallow script input, so the default DNS is kept silently
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        return
    fi

    echo -e "${Font_SkyBlue}Use the default DNS?${Font_Suffix} ${Font_White}Press Enter to continue, or type a DNS server (e.g. 1.2.3.4) or a DoH URL, then press Enter.${Font_Suffix}"

    local input="" ch="" esc="" submitted=0 remaining=5
    printf "${Font_SkyBlue}  DNS (auto in ${remaining}s):${Font_Suffix} "
    while [ "$remaining" -gt 0 ]; do
        if read -n 1 -t 1 ch; then
            case "$ch" in
                ""|$'\n'|$'\r')
                    # Enter. read -n 1 reports it as a SUCCESSFUL read of an EMPTY
                    # character (verified: rc=0, ch=""), while some terminals
                    # return CR/LF instead, so all three end the prompt
                    submitted=1
                    break
                    ;;
                $'\177'|$'\b')
                    # backspace / delete: drop the last character
                    input="${input%?}"
                    ;;
                $'\e')
                    # swallow the rest of an escape sequence (arrow keys, etc.)
                    read -n 2 -t 0.2 esc
                    ;;
                *)
                    # keep printable characters only: a closed stdin delivers
                    # control bytes such as ^D, and they would poison the value
                    [[ "$ch" == [[:print:]] ]] && input="${input}${ch}"
                    ;;
            esac
        else
            remaining=$((remaining - 1))
        fi
        # Once something is typed the countdown label is dropped, so the line that
        # stays on screen reads back the value that was entered
        if [ -n "$input" ]; then
            printf "\r\033[K${Font_SkyBlue}  DNS:${Font_Suffix} ${Font_White}%s${Font_Suffix}" "$input"
        elif [ "$remaining" -gt 0 ]; then
            printf "\r\033[K${Font_SkyBlue}  DNS (auto in ${remaining}s):${Font_Suffix} "
        fi
    done
    # Enter is echoed as a newline by the terminal, a timeout is not
    [ "$submitted" -eq 1 ] || printf "\n"

    input=$(echo "$input" | tr -d '[:space:]')
    if [ -z "$input" ]; then
        echo -e "${Font_SkyBlue}  Default DNS selected.${Font_Suffix}"
        return
    fi
    # The entered value is already on screen from the prompt line above
    if ! isValidDNS "$input"; then
        echo -e "${Font_Red}  '${input}' is not a valid IP or DoH URL; keeping the default DNS.${Font_Suffix}"
        return
    fi
    setupCustomDns "$input"
}

# Check Google Search location via Bard batchexecute (1-stream)
function Test_Google() {
    local tmp=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 \
        'https://bard.google.com/_/BardChatUi/data/batchexecute' \
        -H 'accept-language: en-US' \
        --data-raw 'f.req=[[["K4WWud","[[0],[\"en-US\"]]",null,"generic"]]]' 2>&1)
    if [[ "$tmp" == "curl"* ]]; then
        PrintResult "Google Search:" "${Font_Red}Failed (Network Connection)${Font_Suffix}"
        return
    fi
    local region=$(echo "$tmp" | grep 'K4WWud' | jq '.[0][2]' 2>/dev/null | grep -Eo '\[\[\\"(.*)\\",\\"S' )
    if [ -n "$region" ]; then
        PrintResult "Google Search:" "${Font_Green}Yes (Region: ${region:4:-6})${Font_Suffix}"
    else
        PrintResult "Google Search:" "${Font_Red}Failed${Font_Suffix}"
    fi
}

# Check Google Gemini location via batchexecute (1-stream)
function Test_Gemini() {
    local tmp=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 \
        'https://gemini.google.com/_/BardChatUi/data/batchexecute' \
        -H 'accept-language: en-US' \
        --data-raw 'f.req=[[["K4WWud","[[0],[\"en-US\"]]",null,"generic"]]]' 2>&1)
    if [[ "$tmp" == "curl"* ]]; then
        PrintResult "Google Gemini:" "${Font_Red}Failed (Network Connection)${Font_Suffix}"
        return
    fi
    local region=$(echo "$tmp" | grep 'K4WWud' | jq '.[0][2]' 2>/dev/null | grep -Eo '\[\[\\"(.*)\\",\\"S' )
    if [ -n "$region" ]; then
        PrintResult "Google Gemini:" "${Font_Green}Yes (Region: ${region:4:-6})${Font_Suffix}"
    else
        PrintResult "Google Gemini:" "${Font_Red}No${Font_Suffix}"
    fi
}

# Check OpenAI ChatGPT availability and blocked ISP traces (1-stream)
function Test_ChatGPT() {
    local label="OpenAI ChatGPT:"
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsLI --max-time 10 "https://chatgpt.com" 2>&1)
    local tmpresult1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 "https://ios.chat.openai.com" 2>&1)
    local cf_details=$(echo "$tmpresult1" | jq '.cf_details' 2>/dev/null)
    if [[ "$tmpresult" == "curl"* ]]; then
        PrintResult "$label" "${Font_Red}Failed (Network Connection)${Font_Suffix}"
        return
    fi

    local result1=$(echo "$tmpresult" | grep 'location' )
    if [ ! -n "$result1" ]; then
        if [[ "$tmpresult1" == *"blocked_why_headline"* ]]; then
            PrintResult "$label" "${Font_Red}No (Blocked)${Font_Suffix}"
            return
        fi
        if [[ "$tmpresult1" == *"unsupported_country_region_territory"* ]]; then
            PrintResult "$label" "${Font_Red}No (Unsupported Region)${Font_Suffix}"
            return
        fi
        if [[ "$cf_details" == *"(1)"* ]]; then
            PrintResult "$label" "${Font_Red}No (Disallowed ISP[1])${Font_Suffix}"
            return
        fi
        if [[ "$cf_details" == *"(2)"* ]]; then
            PrintResult "$label" "${Font_Red}No (Disallowed ISP[2])${Font_Suffix}"
            return
        fi
        PrintResult "$label" "${Font_Red}No${Font_Suffix}"
    else
        local region1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 "https://chatgpt.com/cdn-cgi/trace" 2>&1 | grep "loc=" | awk -F= '{print $2}')
        if [[ "$cf_details" == *"(1)"* ]]; then
            PrintResult "$label" "${Font_Yellow}Web Only (Disallowed ISP[1])${Font_Suffix}"
            return
        fi
        if [[ "$cf_details" == *"(2)"* ]]; then
            PrintResult "$label" "${Font_Yellow}Web Only (Disallowed ISP[2])${Font_Suffix}"
            return
        fi
        PrintResult "$label" "${Font_Green}Yes (Region: ${region1})${Font_Suffix}"
    fi
}

# Check Claude.ai availability (1-stream)
function Test_Claude(){
    local result=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -s -o /dev/null -L --max-time 10 -w '%{url_effective}%{http_code}\n' "https://claude.ai/" 2>&1 | grep -E 'unavailable|000')

    if [ -n "$result" ]; then
        PrintResult "Anthropic Claude:" "${Font_Red}No${Font_Suffix}"
    else
        PrintResult "Anthropic Claude:" "${Font_Green}Yes${Font_Suffix}"
    fi
}

# Check Netflix availability for full catalog or originals only
function Test_Netflix() {
    # 81280792 = LEGO Ninjago (non-original); 70143836 = Breaking Bad (licensed)
    # --tlsv1.3 matches upstream: Netflix fingerprints the TLS handshake
    local tmpresult1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sL --tlsv1.3 --max-time 10 "https://www.netflix.com/title/81280792" 2>&1)
    local tmpresult2=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sL --tlsv1.3 --max-time 10 "https://www.netflix.com/title/70143836" 2>&1)
    if [[ -z "$tmpresult1" ]] || [[ -z "$tmpresult2" ]] || [[ "$tmpresult1" == "curl"* ]] || [[ "$tmpresult2" == "curl"* ]]; then
        PrintResult "Netflix:" "${Font_Red}Failed (Network Connection)${Font_Suffix}"
        return
    fi

    # "og:video" is only emitted for a playable title; "Oh no!" means the
    # title is unavailable in the current region
    local playable1=$(echo "${tmpresult1}" | grep -c 'og:video')
    local playable2=$(echo "${tmpresult2}" | grep -c 'og:video')

    # Region id lives in the reactContext JSON: models.geo.data.requestCountry
    # (line-based field cutting is unreliable because the page is minified)
    local region1=$(echo "$tmpresult1" | grep -oE '"requestCountry":\{[^}]*\}' | head -n1 | grep -oE '"id":"[^"]{2}"' | cut -d'"' -f4)

    # At least one title playable => unlocked
    if [ "$playable1" -gt 0 ] || [ "$playable2" -gt 0 ]; then
        if [ -n "$region1" ]; then
            PrintResult "Netflix:" "${Font_Green}Yes (Region: ${region1})${Font_Suffix}"
        else
            PrintResult "Netflix:" "${Font_Green}Yes${Font_Suffix}"
        fi
        return
    fi

    # Nothing playable but the region is known => originals only (or fully blocked)
    if [ -n "$region1" ]; then
        PrintResult "Netflix:" "${Font_Yellow}Originals Only (Region: ${region1})${Font_Suffix}"
        return
    fi

    PrintResult "Netflix:" "${Font_Red}Failed${Font_Suffix}"
}

# Check which Netflix Open Connect Appliance (OCA) serves this connection,
# i.e. which cache city/ISP the Netflix traffic is actually routed to.
# "isp.1.oca" in the target hostname means the ISP embeds the cache itself
# (Open Connect partner); otherwise the route lands on Netflix's own OCA.
function Test_NetflixCDN() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sS --max-time 10 \
        "https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=1" 2>&1)

    if [[ -z "$tmpresult" ]] || [[ "$tmpresult" == "curl"* ]]; then
        PrintResult "Netflix CDN:" "${Font_Red}Failed (Network Connection)${Font_Suffix}"
        return
    fi

    local isp=$(echo "$tmpresult" | jq -r '.client.isp // empty' 2>/dev/null)
    local target_city=$(echo "$tmpresult" | jq -r '.targets[0].location.city // empty' 2>/dev/null)
    local target_country=$(echo "$tmpresult" | jq -r '.targets[0].location.country // empty' 2>/dev/null)
    local target_url=$(echo "$tmpresult" | jq -r '.targets[0].url // empty' 2>/dev/null)
    local target_fqdn=$(echo "$target_url" | awk -F"/" '{print $3}' | awk -F"." '{print $1}')

    if [ -z "$target_city" ]; then
        PrintResult "Netflix CDN:" "${Font_Red}Failed${Font_Suffix}"
        return
    fi

    if [[ "$target_url" == *"isp.1.oca"* ]]; then
        if [ -n "$isp" ]; then
            PrintResult "Netflix CDN:" "${Font_Yellow}${isp}'s OCAs in ${target_city},${target_country} (${target_fqdn})${Font_Suffix}"
        else
            PrintResult "Netflix CDN:" "${Font_Yellow}ISP's OCAs in ${target_city},${target_country} (${target_fqdn})${Font_Suffix}"
        fi
        return
    fi

    PrintResult "Netflix CDN:" "${Font_Green}${target_city},${target_country} (${target_fqdn})${Font_Suffix}"
}

# Check Disney+ availability and specific region logic using GraphQL
function Test_DisneyPlus() {
    # 1. Fetch pre-assertion payload
    local PreAssertion=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -s --max-time 10 -X POST "https://disney.api.edge.bamgrid.com/devices" -H "authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" -H "content-type: application/json; charset=UTF-8" -d '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}' 2>&1)
    if [[ -z "$PreAssertion" ]] || [[ "$PreAssertion" == "curl"* ]]; then
        PrintResult "Disney+:" "${Font_Red}Failed (Network Connection[1])${Font_Suffix}"
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
    local TokenContent=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -s --max-time 10 -X POST "https://disney.api.edge.bamgrid.com/token" -H "authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" -d "$disneycookie" 2>&1)
    if [[ -z "$TokenContent" ]] || [[ "$TokenContent" == "curl"* ]]; then
        PrintResult "Disney+:" "${Font_Red}Failed (Network Connection[2])${Font_Suffix}"
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
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -X POST -sSL --max-time 10 "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" -H "authorization: ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" -d "$disneycontent" 2>&1)
    if [[ -z "$tmpresult" ]] || [[ "$tmpresult" == "curl"* ]]; then
        PrintResult "Disney+:" "${Font_Red}Failed (Network Connection[3])${Font_Suffix}"
        return
    fi

    # 4. Preview check to distinguish between available and unavailable/coming-soon regions
    local previewchecktmp=$(curl $curlArgs -${1} -s -o /dev/null -L --max-time 10 -w '%{url_effective}\n' "https://disneyplus.com")
    if [[ "$previewchecktmp" == "curl"* ]]; then
        PrintResult "Disney+:" "${Font_Red}Failed (Network Connection[4])${Font_Suffix}"
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
    local tmpresult=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsL --max-time 10 "https://open.live.bbc.co.uk/mediaselector/6/select/version/2.0/mediaset/pc/vpid/bbc_one_london/format/json/jsfunc/JS_callbacks0" 2>&1)
    # curl -f returns empty body on HTTP errors; treat empty/curl-error as network failure
    if [[ -z "$tmpresult" ]] || [[ "${tmpresult}" == "curl"* ]]; then
        PrintResult "BBC iPlayer:" "${Font_Red}Failed (Network Connection)${Font_Suffix}"
        return
    fi

    local result=$(echo "$tmpresult" | grep 'geolocation')
    if [ -n "$result" ]; then
        PrintResult "BBC iPlayer:" "${Font_Red}No${Font_Suffix}"
    else
        PrintResult "BBC iPlayer:" "${Font_Green}Yes${Font_Suffix}"
    fi
}

# Check YouTube Premium availability by parsing main page elements
function Test_YouTube_Premium() {
    local tmpresult=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} --max-time 10 -sSL -H "Accept-Language: en" "https://www.youtube.com/premium" 2>&1)

    if [[ "$tmpresult" == "curl"* ]]; then
        PrintResult "YouTube Premium:" "${Font_Red}Failed (Network Connection)${Font_Suffix}"
        return
    fi

    local isCN=$(echo "$tmpresult" | grep 'www.google.cn')
    if [ -n "$isCN" ]; then
        PrintResult "YouTube Premium:" "${Font_Red}No (Region: CN)${Font_Suffix}"
        return
    fi

    local isAvailable=$(echo "$tmpresult" | grep 'Premium is not available in your country')
    # The page is minified into one huge line, so line-based field cutting
    # returns an arbitrary field; match the "countryCode":"XX" pair directly
    local region=$(echo "$tmpresult" | grep -oE '"countryCode":"[^"]{2}"' | head -1 | cut -d'"' -f4)
    if [ -z "$isAvailable" ]; then
        if [ -n "$region" ]; then
            PrintResult "YouTube Premium:" "${Font_Green}Yes (Region: $region)${Font_Suffix}"
        else
            PrintResult "YouTube Premium:" "${Font_Green}Yes${Font_Suffix}"
        fi
    else
        if [ -n "$region" ]; then
            PrintResult "YouTube Premium:" "${Font_Red}No (Region: $region)${Font_Suffix}"
        else
            PrintResult "YouTube Premium:" "${Font_Red}No${Font_Suffix}"
        fi
    fi
}

# Check YouTube CDN node to determine proxy network quality and actual route
function Test_YouTube_CDN() {
    local tmpresult=$(curl $curlArgs -${1} -sS --max-time 10 "https://redirector.googlevideo.com/report_mapping?di=no" 2>&1)

    if [[ "$tmpresult" == "curl"* ]] || [ -z "$tmpresult" ]; then
        PrintResult "YouTube CDN:" "${Font_Red}Check Failed (Network Connection)${Font_Suffix}"
        return
    fi

    # Plain-text response format: "<client-ip> => <cdn-node> (<ipv4-prefix>)",
    # e.g. "151.245.184.5 => ncsina-ag (151.245.184.0/24)". The node tells which
    # cache serves this connection, hence the real route/quality of the proxy.
    local cdn_node=$(echo "$tmpresult" | awk '{print $3}')
    if [ -z "$cdn_node" ]; then
        PrintResult "YouTube CDN:" "${Font_Red}Failed${Font_Suffix}"
        return
    fi

    # ISP nodes are "<isp>-<iata>" (route goes through the ISP's cache);
    # Google-hosted nodes are "<iata><digits>s<digits>"
    if [[ "$cdn_node" == *"-"* ]]; then
        local cdn_isp=$(echo "$cdn_node" | cut -f1 -d"-" | tr 'a-z' 'A-Z')
        local cdn_loc=$(echo "$cdn_node" | cut -f2 -d"-" | sed 's/[^a-zA-Z]//g' | tr 'a-z' 'A-Z')
        local location=$(lookup_iata "$cdn_loc")
        if [ -n "$location" ]; then
            PrintResult "YouTube CDN:" "${Font_Yellow}${cdn_isp} in ${location} (${cdn_node})${Font_Suffix}"
        else
            PrintResult "YouTube CDN:" "${Font_Yellow}${cdn_isp} (${cdn_node})${Font_Suffix}"
        fi
        return
    fi
    if [[ "$cdn_node" == *"s"* ]]; then
        local cdn_loc=$(echo "$cdn_node" | cut -f2 -d"-" | cut -c1-3 | tr 'a-z' 'A-Z')
        local location=$(lookup_iata "$cdn_loc")
        if [ -n "$location" ]; then
            PrintResult "YouTube CDN:" "${Font_Green}${location} (${cdn_node})${Font_Suffix}"
        else
            PrintResult "YouTube CDN:" "${Font_Green}${cdn_loc} (${cdn_node})${Font_Suffix}"
        fi
        return
    fi

    PrintResult "YouTube CDN:" "${Font_Red}Failed${Font_Suffix}"
}

# Check OpenAI Sora availability via Cloudflare geo redirect (upstream parity)
function Test_Sora() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsLI --max-time 10 "https://sora.com" 2>&1)

    if [[ "$tmpresult" == "curl"* ]]; then
        PrintResult "OpenAI Sora:" "${Font_Red}Failed (Network Connection)${Font_Suffix}"
        return
    fi

    local result1=$(echo "$tmpresult" | grep 'location')
    if [ ! -n "$result1" ]; then
        PrintResult "OpenAI Sora:" "${Font_Red}No${Font_Suffix}"
        return
    fi

    local region1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 "https://sora.com/cdn-cgi/trace" 2>&1 | grep "loc=" | awk -F= '{print $2}')
    PrintResult "OpenAI Sora:" "${Font_Green}Yes (Region: ${region1})${Font_Suffix}"
}

# Check Spotify market region via signup page properties
function Test_Spotify() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -s --max-time 10 https://www.spotify.com/tw/signup 2>&1)

    if [[ "$tmpresult" == "curl"* ]]; then
        PrintResult "Spotify:" "${Font_Red}Failed (Network Connection)${Font_Suffix}"
        return
    fi

    local country=$(echo "$tmpresult" | grep -oE '"geoCountry":"[A-Z]{2}"' | head -1 | cut -d'"' -f4)

    if [ -n "$country" ]; then
        PrintResult "Spotify:" "${Font_Green}Yes (Region: $country)${Font_Suffix}"
        return
    fi
    PrintResult "Spotify:" "${Font_Red}Failed${Font_Suffix}"
}

# Check Steam Store currency representation
function Test_Steam() {
    local result=$(curl $curlArgs --user-agent "${UA_Browser}" -${1} -fsSL --max-time 10 "https://store.steampowered.com/app/761830" 2>&1 | grep priceCurrency | cut -d '"' -f4)

    if [ ! -n "$result" ]; then
        PrintResult "Steam Currency:" "${Font_Red}Failed (Network Connection)${Font_Suffix}"
    else
        PrintResult "Steam Currency:" "${Font_Green}${result}${Font_Suffix}"
    fi
}

# Check whether this IP is allowed to edit Wikipedia. Wikipedia blocks known
# open proxies / hosting ranges at the edit layer, so a "Yes" here also means
# the IP is not on their public proxy blacklist (IP reputation signal).
function Test_Wikipedia() {
    local tmpresult=$(curl $curlArgs -${1} -s --user-agent "${UA_Browser}" --max-time 10 \
        "https://en.wikipedia.org/w/index.php?title=Wikipedia:WikiProject_on_open_proxies&action=edit" 2>&1)

    if [ -z "$tmpresult" ]; then
        PrintResult "Wikipedia Editability:" "${Font_Red}Failed (Network Connection)${Font_Suffix}"
        return
    fi

    local result=$(echo "$tmpresult" | grep -i 'This IP address has been')
    if [ -z "$result" ]; then
        PrintResult "Wikipedia Editability:" "${Font_Green}Yes${Font_Suffix}"
        return
    fi
    PrintResult "Wikipedia Editability:" "${Font_Red}No (Blocked)${Font_Suffix}"
}

# Main executor: Runs all tests concurrently but outputs sequentially with grouping
function Run_All_Tests() {
    local IPV=$1
    echo -e "${Font_SkyBlue}> Network Test - IPv${IPV}${Font_Suffix}"

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

    # Output grouped by category
    ShowRegion "AI Services"
    cat "$tmp_dir/01" "$tmp_dir/02" "$tmp_dir/03" "$tmp_dir/04" "$tmp_dir/05" 2>/dev/null
    ShowRegion "Streaming Media"
    cat "$tmp_dir/06" "$tmp_dir/07" "$tmp_dir/08" "$tmp_dir/09" "$tmp_dir/10" "$tmp_dir/11" 2>/dev/null
    ShowRegion "Other Services"
    cat "$tmp_dir/12" "$tmp_dir/13" "$tmp_dir/14" 2>/dev/null

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

echo -e "\n${Font_Purple}[ Minimal Service Unlock Test ]${Font_Suffix}"
echo -e "${Font_Purple}Legend:${Font_Suffix} ${Font_Green}Green=Available${Font_Suffix} | ${Font_Yellow}Yellow=Partial${Font_Suffix} | ${Font_Red}Red=Unavailable/Failed${Font_Suffix}\n"

# Optional custom DNS, chosen before the tests start
promptCustomDns

# Start IPv4 Tests
if [[ "$NetworkType" == "4" ]] || [[ -z "$NetworkType" ]]; then
    trace4=$(curl $curlArgsBase -4 -s --max-time 10 cloudflare.com/cdn-cgi/trace)
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
    trace6=$(curl $curlArgsBase -6 -s --max-time 10 cloudflare.com/cdn-cgi/trace)
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
