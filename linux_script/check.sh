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
            Dns="$OPTARG"
            dns="--dns-servers $Dns"
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

# Base arguments passed to every curl request
curlArgs="$useNIC $usePROXY $xForward $resolve $dns --max-time 10"
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

# Check ChatGPT availability and blocked ISP traces (1-stream)
function Test_ChatGPT() {
    local tmpresult=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsLI --max-time 10 "https://chatgpt.com" 2>&1)
    local tmpresult1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 "https://ios.chat.openai.com" 2>&1)
    local cf_details=$(echo "$tmpresult1" | jq '.cf_details' 2>/dev/null)
    if [[ "$tmpresult" == "curl"* ]]; then
        PrintResult "ChatGPT:" "${Font_Red}Failed (Network Connection)${Font_Suffix}"
        return
    fi

    local result1=$(echo "$tmpresult" | grep 'location' )
    if [ ! -n "$result1" ]; then
        if [[ "$tmpresult1" == *"blocked_why_headline"* ]]; then
            PrintResult "ChatGPT:" "${Font_Red}No (Blocked)${Font_Suffix}"
            return
        fi
        if [[ "$tmpresult1" == *"unsupported_country_region_territory"* ]]; then
            PrintResult "ChatGPT:" "${Font_Red}No (Unsupported Region)${Font_Suffix}"
            return
        fi
        PrintResult "ChatGPT:" "${Font_Red}No${Font_Suffix}"
    else
        local region1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -SsL --max-time 10 "https://chatgpt.com/cdn-cgi/trace" 2>&1 | grep "loc=" | awk -F= '{print $2}')
        if [[ "$cf_details" == *"(1)"* ]]; then
            PrintResult "ChatGPT:" "${Font_Yellow}Web Only (Disallowed ISP[1])${Font_Suffix}"
            return
        fi
        if [[ "$cf_details" == *"(2)"* ]]; then
            PrintResult "ChatGPT:" "${Font_Yellow}Web Only (Disallowed ISP[2])${Font_Suffix}"
            return
        fi
        PrintResult "ChatGPT:" "${Font_Green}Yes (Region: ${region1})${Font_Suffix}"
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
    local tmpresult1=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sL --max-time 10 "https://www.netflix.com/title/81280792" 2>&1)
    local tmpresult2=$(curl $curlArgs -${1} --user-agent "${UA_Browser}" -sL --max-time 10 "https://www.netflix.com/title/70143836" 2>&1)
    if [[ -z "$tmpresult1" ]] || [[ -z "$tmpresult2" ]] || [[ "$tmpresult1" == "curl"* ]] || [[ "$tmpresult2" == "curl"* ]]; then
        PrintResult "Netflix:" "${Font_Red}Failed (Network Connection)${Font_Suffix}"
        return
    fi

    # "Oh no!" appears when the title is unavailable in the current region
    local result1=$(echo "${tmpresult1}" | grep 'Oh no!')
    local result2=$(echo "${tmpresult2}" | grep 'Oh no!')

    # Both titles blocked => originals only (or fully blocked catalog)
    if [ -n "${result1}" ] && [ -n "${result2}" ]; then
        PrintResult "Netflix:" "${Font_Yellow}Originals Only${Font_Suffix}"
        return
    fi

    # At least one title playable => unlocked; extract region from page JSON
    if [ -z "${result1}" ] || [ -z "${result2}" ]; then
        local region1=$(echo "$tmpresult1" | sed -n 's/.*"id":"\([^"]*\)".*"countryName":"[^"]*".*/\1/p' | head -n1)
        if [ -n "$region1" ]; then
            PrintResult "Netflix:" "${Font_Green}Yes (Region: ${region1})${Font_Suffix}"
        else
            PrintResult "Netflix:" "${Font_Green}Yes${Font_Suffix}"
        fi
        return
    fi

    PrintResult "Netflix:" "${Font_Red}Failed${Font_Suffix}"
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
    local region=$(echo "$tmpresult" | grep "countryCode" | head -1 | cut -d '"' -f 4)
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

    if [[ "$tmpresult" == "curl"* ]]; then
        PrintResult "YouTube CDN:" "${Font_Red}Check Failed (Network Connection)${Font_Suffix}"
        return
    fi

    local router=$(echo $tmpresult | grep -o "router: .*" | cut -d '"' -f 2)
    local location=$(echo $router | cut -d "-" -f 1 | tr 'a-z' 'A-Z')
    local cdn_node=$(echo $router | cut -d "-" -f 2 | tr 'a-z' 'A-Z')

    if [ -n "$location" ] && [ -n "$cdn_node" ]; then
        PrintResult "YouTube CDN:" "${Font_Green}Yes ($location / $cdn_node)${Font_Suffix}"
        return
    fi
    PrintResult "YouTube CDN:" "${Font_Red}Failed${Font_Suffix}"
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
    Test_Claude ${IPV} > "$tmp_dir/04" &
    Test_Netflix ${IPV} > "$tmp_dir/05" &
    Test_DisneyPlus ${IPV} > "$tmp_dir/06" &
    Test_BBC ${IPV} > "$tmp_dir/07" &
    Test_YouTube_Premium ${IPV} > "$tmp_dir/08" &
    Test_YouTube_CDN ${IPV} > "$tmp_dir/09" &
    Test_Spotify ${IPV} > "$tmp_dir/10" &
    Test_Steam ${IPV} > "$tmp_dir/11" &

    # Wait for all background tasks to complete
    wait

    # Output grouped by category
    ShowRegion "AI Services"
    cat "$tmp_dir/01" "$tmp_dir/02" "$tmp_dir/03" "$tmp_dir/04" 2>/dev/null
    ShowRegion "Streaming Media"
    cat "$tmp_dir/05" "$tmp_dir/06" "$tmp_dir/07" "$tmp_dir/08" "$tmp_dir/09" 2>/dev/null
    ShowRegion "Other Services"
    cat "$tmp_dir/10" "$tmp_dir/11" 2>/dev/null

    # Tally results from collected output
    local total=0 yes=0 no=0 failed=0
    local GREEN=$'\033[32m'
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
        fi
    done
    echo -e "${Font_Purple}  Summary: ${yes} available, ${no} unavailable, ${failed} failed (of ${total})${Font_Suffix}"

    rm -rf "$tmp_dir"
    echo ""
}

echo -e "\n${Font_Purple}[ Minimal Service Unlock Test ]${Font_Suffix}"
echo -e "${Font_Purple}Legend:${Font_Suffix} ${Font_Green}Green=Available${Font_Suffix} | ${Font_Yellow}Yellow=Partial${Font_Suffix} | ${Font_Red}Red=Unavailable/Failed${Font_Suffix}\n"

# Start IPv4 Tests
if [[ "$NetworkType" == "4" ]] || [[ -z "$NetworkType" ]]; then
    local_ipv4=$(curl $curlArgs -4 -s --max-time 10 cloudflare.com/cdn-cgi/trace | grep ip | awk -F= '{print $2}')
    if [ -n "$local_ipv4" ]; then
        echo -e "${Font_SkyBlue}IPv4 Address: ${Font_Green}${local_ipv4}${Font_Suffix}"
        Run_All_Tests 4
    else
        echo -e "\n${Font_Red}No IPv4 Network Detected.${Font_Suffix}"
    fi
fi

# Start IPv6 Tests
if [[ "$NetworkType" == "6" ]] || [[ -z "$NetworkType" ]]; then
    local_ipv6=$(curl $curlArgs -6 -s --max-time 10 cloudflare.com/cdn-cgi/trace | grep ip | awk -F= '{print $2}')
    if [ -n "$local_ipv6" ]; then
        echo -e "${Font_SkyBlue}IPv6 Address: ${Font_Green}${local_ipv6}${Font_Suffix}"
        Run_All_Tests 6
    else
        echo -e "\n${Font_Red}No IPv6 Network Detected.${Font_Suffix}"
    fi
fi
