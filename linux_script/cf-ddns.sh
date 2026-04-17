#!/bin/bash

# Cloudflare DDNS 管理
# 依赖 curl jq grep

# 运行流程：
# 1. 检查依赖和参数
# 2. 获取当前公网 IP
# 3. 解析对应 Zone ID
# 4. 查询现有 DNS 记录
# 5. 若 IP 未变化则退出
# 6. 若 IP 变化则查询 ipinfo
# 7. 构造请求体
# 8. 更新或创建 DNS 记录

# crontab 示例：每 15 分钟执行一次
# */15 * * * * /bin/bash /path/to/cf-ddns.sh >> /var/log/cf-ddns.log 2>&1

set -euo pipefail

# Cloudflare API token
API_KEY="xxxxxxxx"
# 目标记录域名
DOMAIN="xxxxxxxx"
# 仅处理 A 记录
RECORD_TYPE="A"
# TTL（秒），Cloudflare 支持 120 或 1(自动)
TTL=120

CF_API="https://api.cloudflare.com/client/v4"

# curl 通用参数
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
     # 函数：获取公网 IP
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
          # 提取 IPv4，兼容带额外文本的返回
          candidate_ip=$(echo "$raw" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
          if [[ -n "$candidate_ip" ]]; then
               printf '%s\n%s\n' "$candidate_ip" "$service"
               return 0
          fi
     done

     return 1
}

cf_api() {
     # 函数：统一调用 Cloudflare API
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
     # 函数：检查命令是否存在
     local cmd="$1"
     if ! command -v "$cmd" >/dev/null 2>&1; then
          echo "error: required command not found: $cmd" >&2
          exit 1
     fi
}

is_cf_success() {
     # 函数：判断 Cloudflare 响应是否成功
     local response="$1"
     [[ "$(echo "$response" | jq -r '.success // false')" == "true" ]]
}

cf_errors() {
     # 函数：提取 Cloudflare errors
     local response="$1"
     echo "$response" | jq -c '.errors // []'
}

get_ipinfo() {
     # 函数：查询 IP 的运营商和地理位置
     local ip="$1"
     curl -fsS "${CURL_COMMON_ARGS[@]}" "https://ipinfo.io/$ip/json"
}

resolve_zone_id() {
     # 函数：从域名逐级回退查找 Zone ID
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

# 主流程第 1 步：校验 TTL
if [[ ! "$TTL" =~ ^[0-9]+$ ]]; then
     echo "error: TTL must be a number" >&2
     exit 1
fi

# 主流程第 2 步：获取当前公网 IP
mapfile -t IP_INFO < <(get_public_ip)
IP="${IP_INFO[0]:-}"
IP_SOURCE="${IP_INFO[1]:-}"

if [[ -z "$IP" ]]; then
     echo "error: failed to get public IPv4 from all providers"
     exit 1
fi

# 主流程第 2 步输出：打印 IP 和来源
echo "ip: $IP"
echo "source: $IP_SOURCE"

# 主流程第 3 步：解析 Zone ID
ZONE_ID=$(resolve_zone_id "$DOMAIN")
if [[ -z "$ZONE_ID" ]]; then
     echo "error: failed to resolve zone id from DOMAIN=$DOMAIN (check token permissions: Zone:Read + DNS:Edit)" >&2
     exit 1
fi

# 主流程第 4 步：查询现有 DNS 记录
RECORD_JSON=$(cf_api GET "/zones/$ZONE_ID/dns_records?name=$DOMAIN&type=$RECORD_TYPE")

if ! is_cf_success "$RECORD_JSON"; then
     echo "$(date +'%F %T') query failed: $(cf_errors "$RECORD_JSON")" >&2
     exit 1
fi

# 如果存在记录，读取其 ID 和当前内容 IP
RECORD_ID=$(echo "$RECORD_JSON" | jq -r '.result[0].id // empty')
DNS_IP=$(echo "$RECORD_JSON" | jq -r '.result[0].content // empty')

# 主流程第 5 步：IP 未变化则退出
if [[ -n "$DNS_IP" && "$IP" == "$DNS_IP" ]]; then
     echo "$(date +'%F %T') unchanged: $IP"
     exit 0
fi

# 主流程第 6 步：仅在 IP 变化时查询 ipinfo
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

# 主流程第 7 步：构造请求体
PAYLOAD=$(jq -n \
     --arg type "$RECORD_TYPE" \
     --arg name "$DOMAIN" \
     --arg content "$IP" \
     --argjson ttl "$TTL" \
     '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:false}')

if [[ -n "$RECORD_ID" ]]; then
     # 主流程第 8 步：记录存在则更新
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
     # 主流程第 8 步：记录不存在则创建
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
