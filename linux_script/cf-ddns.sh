#!/bin/bash

# Cloudflare DDNS Management
# Dependencies: curl, jq, grep

# Execution flow:
# 1. Check dependencies and parameters
# 2. Get current public IP
# 3. Resolve corresponding Zone ID
# 4. Query existing DNS records
# 5. Exit if IP remains unchanged
# 6. Query ipinfo if IP changed
# 7. Construct request body
# 8. Update or create DNS record

# crontab example: execute every 15 minutes
# */15 * * * * /bin/bash /path/to/cf-ddns.sh >> /var/log/cf-ddns.log 2>&1

# Ensure execution permission before use: chmod +x cf-ddns.sh

set -euo pipefail

# Cloudflare API token
API_KEY="xxxxxxxx"
# Target domain
DOMAIN="xxxxxxxx"
# Process A records only
RECORD_TYPE="A"
# TTL (seconds), Cloudflare supports 120 or 1 (auto)
TTL=120
# Optional: Comment for the DNS record
COMMENT=""

CF_API="https://api.cloudflare.com/client/v4"

# General curl parameters
CURL_TIMEOUT=8
CURL_RETRY=2
CURL_RETRY_DELAY=1
CURL_COMMON_ARGS=(
     --max-time "$CURL_TIMEOUT"
     --retry "$CURL_RETRY"
     --retry-delay "$CURL_RETRY_DELAY"
     --retry-all-errors
)

CF_API_HEADERS=(
     -H "Authorization: Bearer $API_KEY"
     -H "Content-Type: application/json"
)

get_public_ip() {
     # Function: Get public IP
     local services=(
          "https://api.ipify.org"
          "https://ifconfig.me/ip"
          "https://ipv4.icanhazip.com"
          "https://checkip.amazonaws.com"
     )

     local service
     local raw
     local candidate_ip

     for service in "${services[@]}"; do
          raw=$(curl -4fsS "${CURL_COMMON_ARGS[@]}" "$service" 2>/dev/null)
          # Extract IPv4, compatible with responses containing extra text
          candidate_ip=$(echo "$raw" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
          if [[ -n "$candidate_ip" ]]; then
               printf '%s\n%s\n' "$candidate_ip" "$service"
               return 0
          fi
     done

     return 1
}

cf_api() {
     # Function: Unified Cloudflare API call
     local method="$1"
     local endpoint="$2"
     local data="${3:-}"

     if [[ -n "$data" ]]; then
          curl -fsS "${CURL_COMMON_ARGS[@]}" \
               -X "$method" "$CF_API$endpoint" \
               "${CF_API_HEADERS[@]}" \
               --data "$data"
     else
          curl -fsS "${CURL_COMMON_ARGS[@]}" \
               -X "$method" "$CF_API$endpoint" \
               "${CF_API_HEADERS[@]}"
     fi
}

require_command() {
     # Function: Check if command exists
     local cmd="$1"
     if ! command -v "$cmd" >/dev/null 2>&1; then
          echo "error: required command not found: $cmd" >&2
          exit 1
     fi
}

is_cf_success() {
     # Function: Determine if Cloudflare response is successful
     local response="$1"
     [[ "$(echo "$response" | jq -r '.success // false')" == "true" ]]
}

cf_errors() {
     # Function: Extract Cloudflare errors
     local response="$1"
     echo "$response" | jq -c '.errors // []'
}

get_ipinfo() {
     # Function: Query IP ISP and geolocation
     local ip="$1"
     curl -fsS "${CURL_COMMON_ARGS[@]}" "https://ipinfo.io/$ip/json"
}

resolve_zone_id() {
     # Function: Find Zone ID by backtracking from domain
     local candidate="$1"
     local response
     local zone_id

     while [[ "$candidate" == *.* ]]; do
          response=$(cf_api GET "/zones?name=$candidate&status=active&per_page=1")
          if is_cf_success "$response"; then
               zone_id=$(echo "$response" | jq -r '.result[0].id // empty')
               if [[ -n "$zone_id" ]]; then
                    echo "$zone_id"
                    return 0
               fi
          fi
          candidate="${candidate#*.}"
     done

     return 1
}

require_command curl
require_command grep
require_command jq

# Step 1: Validate TTL
if [[ ! "$TTL" =~ ^[0-9]+$ ]]; then
     echo "error: TTL must be a number" >&2
     exit 1
fi

# Step 2: Get current public IP
mapfile -t IP_INFO < <(get_public_ip)
IP="${IP_INFO[0]:-}"
IP_SOURCE="${IP_INFO[1]:-}"

if [[ -z "$IP" ]]; then
     echo "error: failed to get public IPv4 from all providers"
     exit 1
fi

# Step 2 Output: Print IP and source
echo "ip: $IP"
echo "source: $IP_SOURCE"

# Step 3: Resolve Zone ID
ZONE_ID=$(resolve_zone_id "$DOMAIN")
if [[ -z "$ZONE_ID" ]]; then
     echo "error: failed to resolve zone id from DOMAIN=$DOMAIN (check token permissions: Zone:Read + DNS:Edit)" >&2
     exit 1
fi

# Step 4: Query existing DNS records
RECORD_JSON=$(cf_api GET "/zones/$ZONE_ID/dns_records?name=$DOMAIN&type=$RECORD_TYPE")

if ! is_cf_success "$RECORD_JSON"; then
     echo "$(date +'%F %T') query failed: $(cf_errors "$RECORD_JSON")" >&2
     exit 1
fi

# If record exists, read its ID and current content IP
RECORD_ID=$(echo "$RECORD_JSON" | jq -r '.result[0].id // empty')
DNS_IP=$(echo "$RECORD_JSON" | jq -r '.result[0].content // empty')

# Step 5: Exit if IP is unchanged
if [[ -n "$DNS_IP" && "$IP" == "$DNS_IP" ]]; then
     echo "$(date +'%F %T') unchanged: $IP"
     exit 0
fi

# Step 6: Query ipinfo only when IP changes
IPINFO_JSON=$(get_ipinfo "$IP")
IPINFO_ORG=$(echo "$IPINFO_JSON" | jq -r '.org // "unknown"')
IPINFO_CITY=$(echo "$IPINFO_JSON" | jq -r '.city // empty')
IPINFO_REGION=$(echo "$IPINFO_JSON" | jq -r '.region // empty')
IPINFO_COUNTRY=$(echo "$IPINFO_JSON" | jq -r '.country // empty')

IPINFO_LOCATION="${IPINFO_CITY:-${IPINFO_REGION:-}}"
if [[ -n "$IPINFO_CITY" && -n "$IPINFO_REGION" ]]; then
     IPINFO_LOCATION="$IPINFO_CITY, $IPINFO_REGION"
elif [[ -z "$IPINFO_LOCATION" && -n "$IPINFO_COUNTRY" ]]; then
     IPINFO_LOCATION="$IPINFO_COUNTRY"
fi

# Step 7: Construct request body
PAYLOAD=$(jq -n \
     --arg type "$RECORD_TYPE" \
     --arg name "$DOMAIN" \
     --arg content "$IP" \
     --argjson ttl "$TTL" \
     --arg comment "${COMMENT:-}" \
     '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:false} | if $comment != "" then .comment = $comment else . end')

if [[ -n "$RECORD_ID" ]]; then
     # Step 8: Update if record exists
     echo "$(date +'%F %T') update: ${DNS_IP:-unknown} -> $IP"
     echo "$(date +'%F %T') ip info: org=$IPINFO_ORG location=$IPINFO_LOCATION"
     RESP=$(cf_api PUT "/zones/$ZONE_ID/dns_records/$RECORD_ID" "$PAYLOAD")
     if is_cf_success "$RESP"; then
          echo "$(date +'%F %T') update ok"
     else
          echo "$(date +'%F %T') update failed: $(cf_errors "$RESP")" >&2
          exit 1
     fi
else
     # Step 8: Create if record does not exist
     echo "$(date +'%F %T') create: $RECORD_TYPE $DOMAIN -> $IP"
     echo "$(date +'%F %T') ipinfo: org=$IPINFO_ORG location=$IPINFO_LOCATION"
     RESP=$(cf_api POST "/zones/$ZONE_ID/dns_records" "$PAYLOAD")
     if is_cf_success "$RESP"; then
          echo "$(date +'%F %T') create ok"
     else
          echo "$(date +'%F %T') create failed: $(cf_errors "$RESP")" >&2
          exit 1
     fi
fi
