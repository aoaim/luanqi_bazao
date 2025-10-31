#!/bin/bash
# 网络检测工具 - Interactive Network Checker
# Origin: https://github.com/Cd1s/network-latency-tester/blob/main/latency.sh
# Modified by aoaim

# 检查bash版本，关联数组需要bash 4.0+
if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
    echo "错误: 此脚本需要 bash 4.0 或更高版本"
    echo "当前版本: $BASH_VERSION"
    echo ""
    echo "macOS用户请安装新版bash:"
    echo "  brew install bash"
    echo "  然后使用新版bash运行: /opt/homebrew/bin/bash latency.sh"
    echo ""
    echo "或者在脚本开头指定新版bash:"
    echo "  #!/opt/homebrew/bin/bash"
    exit 1
fi

# set -eo pipefail  # 暂时注释掉调试

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# 获取毫秒时间戳的跨平台函数
get_timestamp_ms() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import time; print(int(time.time() * 1000))"
    elif command -v python >/dev/null 2>&1; then
        python -c "import time; print(int(time.time() * 1000))"
    elif [[ "$(uname)" == "Darwin" ]]; then
        # macOS fallback: 使用秒*1000
        echo $(($(date +%s) * 1000))
    else
        # Linux with nanosecond support
        local ns=$(date +%s%N 2>/dev/null)
        if [[ "$ns" =~ N$ ]]; then
            # %N not supported, use seconds
            echo $(($(date +%s) * 1000))
        else
            echo $((ns / 1000000))
        fi
    fi
}

# 计算字符串显示宽度（考虑中文字符占2个位置）
display_width() {
    local str="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import sys; s='$str'; print(sum(2 if ord(c) > 127 else 1 for c in s))"
    else
        # 简单估算：中文字符数*2 + 其他字符数
        local len=${#str}
        local width=0
        for ((i=0; i<len; i++)); do
            local byte="${str:$i:1}"
            if [[ -n "$byte" ]] && [[ $(printf '%d' "'$byte" 2>/dev/null) -gt 127 ]]; then
                width=$((width + 2))
            else
                width=$((width + 1))
            fi
        done
        echo "$width"
    fi
}

# 打印对齐的行（考虑中文字符）
print_aligned_row() {
    local rank="$1"
    local col1="$2"  # DNS名称
    local col2="$3"  # IP地址
    local col3="$4"  # 延迟/时间
    local col4="$5"  # 状态（带颜色）
    
    # 计算col1的实际显示宽度
    local col1_display=$(display_width "$col1")
    local col1_target=15
    local padding1=$((col1_target - col1_display))
    
    # 如果padding为负，说明名称太长，需要截断或调整
    if [[ $padding1 -lt 0 ]]; then
        padding1=0
    fi
    
    # 计算col2的实际显示宽度
    local col2_display=$(display_width "$col2")
    local col2_target=20
    local padding2=$((col2_target - col2_display))
    
    # 如果padding为负，说明IP地址太长，需要截断或调整
    if [[ $padding2 -lt 0 ]]; then
        padding2=0
    fi
    
    # 输出对齐的行
    printf "%2d. %s%*s %s%*s %-12s" "$rank" "$col1" "$padding1" "" "$col2" "$padding2" "" "$col3"
    if [[ -n "$col4" ]]; then
        echo -e " $col4"
    else
        echo ""
    fi
}

# 配置变量
PING_COUNT=10  # 增加到10次以获得更准确的丢包率
DOWNLOAD_TEST_SIZE="1M"  # 下载测试文件大小
DNS_TEST_DOMAIN="google.com"  # DNS测试使用的域名
IP_VERSION=""  # IP版本控制 (4/6/auto)
SELECTED_DNS_SERVER=""  # 用户选择的DNS服务器用于IP解析
SELECTED_DNS_NAME=""  # 用户选择的DNS服务器名称

# 检测操作系统类型
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS_TYPE="linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS_TYPE="macos"
    elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ -n "$WSL_DISTRO_NAME" ]]; then
        OS_TYPE="wsl"
    else
        OS_TYPE="unknown"
    fi
}

# 获取适当的ping命令和参数
get_ping_cmd() {
    local version=${1:-"4"}  # 默认IPv4
    local host=$2
    
    if [[ "$version" == "6" ]]; then
        if command -v ping6 >/dev/null 2>&1; then
            echo "ping6"
        elif [[ "$OS_TYPE" == "linux" ]]; then
            echo "ping -6"
        elif [[ "$OS_TYPE" == "macos" ]]; then
            echo "ping6"
        else
            echo "ping -6"
        fi
    else
        if [[ "$OS_TYPE" == "linux" ]]; then
            echo "ping -4"
        else
            echo "ping"
        fi
    fi
}

# 获取适当的ping间隔参数
get_ping_interval() {
    if [[ "$OS_TYPE" == "macos" ]]; then
        echo ""  # macOS ping默认间隔1秒，不需要-i参数
    else
        echo "-i 0.5"  # Linux支持0.5秒间隔
    fi
}

# 获取超时命令
get_timeout_cmd() {
    if [[ "$OS_TYPE" == "macos" ]]; then
        # macOS可能需要安装coreutils或使用其他方法
        if command -v gtimeout >/dev/null 2>&1; then
            echo "gtimeout"
        else
            echo ""  # 返回空表示不使用timeout
        fi
    else
        if command -v timeout >/dev/null 2>&1; then
            echo "timeout"
        else
            echo ""
        fi
    fi
}

detect_os

# 使用fping进行批量测试（跨平台兼容）
test_batch_latency_fping() {
    local hosts=("$@")
    local temp_file="/tmp/fping_hosts_$$"
    local temp_results="/tmp/fping_results_$$"
    
    # 创建主机列表文件
    printf '%s\n' "${hosts[@]}" > "$temp_file"
    
    # 根据IP版本和系统选择fping命令
    local fping_cmd=""
    if command -v fping >/dev/null 2>&1; then
        if [[ "$IP_VERSION" == "6" ]]; then
            if command -v fping6 >/dev/null 2>&1; then
                fping_cmd="fping6"
            else
                fping_cmd="fping -6"
            fi
        elif [[ "$IP_VERSION" == "4" ]]; then
            fping_cmd="fping -4"
        else
            fping_cmd="fping"
        fi
        
        # 执行fping批量测试
        $fping_cmd -c $PING_COUNT -q -f "$temp_file" 2>"$temp_results" || true
    else
        # 如果没有fping，回退到标准ping
        while IFS= read -r host; do
            local ping_cmd=$(get_ping_cmd "$IP_VERSION" "$host")
            local interval=$(get_ping_interval)
            local timeout_cmd=$(get_timeout_cmd)
            
            local ping_result
            if [[ -n "$timeout_cmd" ]]; then
                if [[ -n "$interval" ]]; then
                    ping_result=$($timeout_cmd 10 $ping_cmd -c $PING_COUNT $interval "$host" 2>/dev/null || echo "timeout")
                else
                    ping_result=$($timeout_cmd 10 $ping_cmd -c $PING_COUNT "$host" 2>/dev/null || echo "timeout")
                fi
            else
                # macOS没有timeout命令时，直接使用ping
                if [[ -n "$interval" ]]; then
                    ping_result=$($ping_cmd -c $PING_COUNT $interval "$host" 2>/dev/null || echo "timeout")
                else
                    ping_result=$($ping_cmd -c $PING_COUNT "$host" 2>/dev/null || echo "timeout")
                fi
            fi
            
            if [[ "$ping_result" != "timeout" ]]; then
                local avg_latency=$(echo "$ping_result" | grep -o 'min/avg/max[^=]*= [0-9.]*\/[0-9.]*\/[0-9.]*' | cut -d'=' -f2 | cut -d'/' -f2 || echo "timeout")
                echo "$host : $avg_latency ms" >> "$temp_results"
            else
                echo "$host : timeout" >> "$temp_results"
            fi
        done < "$temp_file"
    fi
    
    # 清理临时文件
    rm -f "$temp_file"
    
    echo "$temp_results"
}

# 使用fping显示所有网站的快速延迟测试
show_fping_results() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}📡 快速Ping延迟测试 (使用fping批量测试)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    # 收集所有主机
    local hosts=()
    local valid_hosts=()
    for service in "${!FULL_SITES[@]}"; do
        local host="${FULL_SITES[$service]}"
        # 过滤掉空值、脚本文件、本地路径
        # 移除可能的 ./ 前缀
        local clean_host="${host#./}"
        
        # 检查是否是有效的主机名或域名
        if [[ -n "$host" && 
              "$host" != "latency.sh" && 
              "$clean_host" != *".sh" && 
              "$host" != ./* && 
              "$host" != /* &&
              "$host" =~ ^[a-zA-Z0-9].*$ ]]; then
            hosts+=("$host")
            valid_hosts+=("$service|$host")
        fi
    done
    
    # 创建主机列表文件
    local temp_file="/tmp/fping_hosts_$$"
    local temp_results="/tmp/fping_results_$$"
    
    # 清理可能存在的旧文件
    rm -f "$temp_file" "$temp_results" 2>/dev/null
    
    # 根据IP版本选择fping命令
    local fping_cmd=""
    local version_info=""
    
    echo -e "测试版本: "
    
    if [[ "$IP_VERSION" == "6" ]]; then
        echo -e "(IPv6优先) | 测试网站: ${#valid_hosts[@]}个"
        echo ""
        echo "⚡ 正在使用fping进行快速批量测试..."
        
        # IPv6模式：分别处理IPv6和IPv4主机
        local ipv6_hosts=()
        local ipv4_hosts=()
        
        echo -n "检测IPv6支持..."
        for host in "${hosts[@]}"; do
            # 快速检查是否有IPv6地址（dig内置超时1秒）
            if dig +short +time=1 +tries=1 AAAA "$host" 2>/dev/null | grep -q ":" ; then
                ipv6_hosts+=("$host")
            else
                # 没有IPv6则fallback到IPv4
                ipv4_hosts+=("$host")
            fi
        done
        echo " 完成 (IPv6: ${#ipv6_hosts[@]}个, IPv4: ${#ipv4_hosts[@]}个)"
        
        # 测试IPv6主机
        if [[ ${#ipv6_hosts[@]} -gt 0 ]]; then
            echo -n "测试IPv6主机..."
            for host in "${ipv6_hosts[@]}"; do
                echo "$host" >> "${temp_file}_v6"
            done
            
            if command -v fping6 >/dev/null 2>&1; then
                fping6 -c 10 -q -f "${temp_file}_v6" 2>"${temp_results}_v6" || true
            else
                fping -6 -c 10 -q -f "${temp_file}_v6" 2>"${temp_results}_v6" || true
            fi
            echo " 完成"
        fi
        
        # 测试IPv4主机（fallback）
        if [[ ${#ipv4_hosts[@]} -gt 0 ]]; then
            echo -n "测试IPv4主机 (fallback)..."
            for host in "${ipv4_hosts[@]}"; do
                echo "$host" >> "${temp_file}_v4"
            done
            fping -4 -c 10 -q -f "${temp_file}_v4" 2>"${temp_results}_v4" || true
            echo " 完成"
        fi
        
        # 合并结果
        cat "${temp_results}_v6" "${temp_results}_v4" 2>/dev/null > "$temp_results" || true
        rm -f "${temp_file}_v6" "${temp_file}_v4" "${temp_results}_v6" "${temp_results}_v4" 2>/dev/null
        
    elif [[ "$IP_VERSION" == "4" ]]; then
        echo -e "(IPv4) | 测试网站: ${#valid_hosts[@]}个"
        echo ""
        echo "⚡ 正在使用fping进行快速批量测试..."
        fping_cmd="fping -4"
        
        # IPv4模式：直接测试所有主机
        for host in "${hosts[@]}"; do
            echo "$host" >> "$temp_file"
        done
        $fping_cmd -c 10 -q -f "$temp_file" 2>"$temp_results" || true
        
    else
        echo -e "(Auto) | 测试网站: ${#valid_hosts[@]}个"
        echo ""
        echo "⚡ 正在使用fping进行快速批量测试..."
        fping_cmd="fping"
        
        # Auto模式：直接测试所有主机
        for host in "${hosts[@]}"; do
            echo "$host" >> "$temp_file"
        done
        $fping_cmd -c 10 -q -f "$temp_file" 2>"$temp_results" || true
    fi
    
    # 解析并显示结果
    if command -v fping >/dev/null 2>&1; then
        if [[ -s "$temp_results" ]]; then
            echo ""
            printf "%-15s %-20s %-25s %-10s %-8s\n" "排名" "网站" "域名" "延迟" "丢包率"
            echo "─────────────────────────────────────────────────────────────────────────"
            
            local count=1
            declare -a results_array=()
            
            # 解析fping结果
            while IFS= read -r line; do
                if [[ "$line" =~ ([^[:space:]]+)[[:space:]]*:[[:space:]]*(.+) ]]; then
                    local host="${BASH_REMATCH[1]}"
                    local result="${BASH_REMATCH[2]}"
                    
                    # 查找对应的服务名
                    local service_name=""
                    for service in "${!FULL_SITES[@]}"; do
                        if [[ "${FULL_SITES[$service]}" == "$host" ]]; then
                            service_name="$service"
                            break
                        fi
                    done
                    
                    if [[ -z "$service_name" ]]; then
                        service_name="$host"
                    fi
                    
                    # 提取延迟和丢包率信息
                    local latency=""
                    local packet_loss="100%"
                    
                    if echo "$result" | grep -q "min/avg/max"; then
                        latency=$(echo "$result" | grep -o 'min/avg/max = [0-9.]*\/[0-9.]*\/[0-9.]*' | cut -d'=' -f2 | cut -d'/' -f2 | tr -d ' ')
                        # 提取丢包率 (格式: xmt/rcv/%loss = 10/10/0%)
                        if echo "$result" | grep -q "%loss"; then
                            packet_loss=$(echo "$result" | grep -o '%loss = [^,]*' | cut -d'=' -f2 | tr -d ' ' | cut -d'/' -f3)
                        else
                            packet_loss="0%"
                        fi
                        
                        if [[ -n "$latency" ]] && [[ "$latency" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                            results_array+=("$latency|$service_name|$host|$packet_loss")
                        else
                            results_array+=("999999|$service_name|$host|100%")
                        fi
                    else
                        results_array+=("999999|$service_name|$host|100%")
                    fi
                fi
            done < "$temp_results"
            
            # 排序结果（按延迟排序）
            IFS=$'\n' sorted_results=($(sort -t'|' -k1 -n <<< "${results_array[*]}"))
            
            # 显示排序后的结果
            for result in "${sorted_results[@]}"; do
                IFS='|' read -r latency service_name host packet_loss <<< "$result"
                if [[ "$latency" == "999999" ]]; then
                    echo -e "$(printf "%-15s %-20s %-25s" "$count." "$service_name" "$host") ${RED}超时/失败 ❌${NC}    ${RED}${packet_loss}${NC}"
                else
                    local latency_color=""
                    local loss_color=""
                    
                    # 延迟着色 (使用纯bash整数比较，兼容macOS和Linux)
                    local latency_int=$(echo "$latency" | cut -d'.' -f1)
                    if [[ "$latency_int" -lt 50 ]]; then
                        latency_color="${GREEN}"
                    elif [[ "$latency_int" -lt 150 ]]; then
                        latency_color="${YELLOW}"
                    else
                        latency_color="${RED}"
                    fi
                    
                    # 丢包率着色
                    local loss_num=$(echo "$packet_loss" | sed 's/%//')
                    if [[ "$loss_num" == "0" ]]; then
                        loss_color="${GREEN}"
                    elif [[ "$loss_num" -le "5" ]]; then
                        loss_color="${YELLOW}"
                    else
                        loss_color="${RED}"
                    fi
                    
                    # 格式化延迟显示 (兼容macOS和Linux)
                    local latency_display=""
                    if command -v bc >/dev/null 2>&1; then
                        latency_display=$(printf "%.1f" "$latency" 2>/dev/null || echo "$latency")
                    else
                        latency_display="$latency"
                    fi
                    
                    echo -e "$(printf "%-15s %-20s %-25s" "$count." "$service_name" "$host") ${latency_color}${latency_display}ms${NC} ✅    ${loss_color}${packet_loss}${NC}"
                fi
                ((count++))
            done
        else
            echo "❌ fping测试失败或无结果"
        fi
    else
        echo "❌ fping命令不可用，跳过批量测试"
    fi
    
    # 清理临时文件
    rm -f "$temp_file" "$temp_results"
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

# 解析IPv6地址
get_ipv6_address() {
    local domain=$1
    local ipv6=""
    
    # 尝试使用dig获取IPv6
    if command -v dig >/dev/null 2>&1; then
        ipv6=$(dig +short AAAA "$domain" 2>/dev/null | grep -E '^[0-9a-f:]+$' | head -n1)
    fi
    
    # 如果dig失败，尝试使用nslookup
    if [ -z "$ipv6" ] && command -v nslookup >/dev/null 2>&1; then
        ipv6=$(nslookup -type=AAAA "$domain" 2>/dev/null | grep "Address:" | tail -n1 | awk '{print $2}' | grep -E '^[0-9a-f:]+$')
    fi
    
    echo "$ipv6"
}

# 删除基础网站列表，只保留完整网站列表

# 完整网站列表（21个）
declare -A FULL_SITES=(
    ["Google"]="google.com"
    ["GitHub"]="github.com"
    ["Apple"]="apple.com"
    ["Microsoft"]="m365.cloud.microsoft"
    ["AWS"]="aws.amazon.com"
    ["Twitter"]="twitter.com"
    ["ChatGPT"]="openai.com"
    ["Steam"]="steampowered.com"
    ["Netflix"]="fast.com"
    ["Disney"]="disneyplus.com"
    ["Instagram"]="instagram.com"
    ["Telegram"]="tg.d1ss.eu.org"
    ["OneDrive"]="onedrive.live.com"
    ["Twitch"]="twitch.tv"
    ["YouTube"]="youtube.com"
    ["Facebook"]="facebook.com"
    ["TikTok"]="tiktok.com"
)

# DNS服务器列表（全球常用）
declare -A DNS_SERVERS=(
    ["系统DNS"]="system"
    ["Google DNS"]="8.8.8.8"
    ["Google备用"]="8.8.4.4"
    ["Cloudflare DNS"]="1.1.1.1"
    ["Cloudflare备用"]="1.0.0.1"
    ["Quad9 DNS"]="9.9.9.9"
    ["Quad9备用"]="149.112.112.112"
    ["OpenDNS"]="208.67.222.222"
    ["OpenDNS备用"]="208.67.220.220"
    ["AdGuard DNS"]="94.140.14.14"
    ["AdGuard备用"]="94.140.15.15"
    ["Level3 DNS"]="4.2.2.1"
    ["Level3备用"]="4.2.2.2"
)

# 测试文件URL列表（用于下载速度测试）
declare -A DOWNLOAD_TEST_URLS=(
    ["Cloudflare"]="https://speed.cloudflare.com/__down?bytes=104857600"
    ["Fast.com"]="https://fast.com"
    ["YouTube"]="https://www.youtube.com/watch?v=dQw4w9WgXcQ"
)

# 结果数组
declare -a RESULTS=()
declare -a DNS_RESULTS=()
declare -a DOWNLOAD_RESULTS=()

# 获取域名的IP地址
get_ip_address() {
    local domain=$1
    local ip=""
    
    # 如果用户选择了特定的DNS服务器，使用该DNS服务器解析
    if [[ -n "$SELECTED_DNS_SERVER" && "$SELECTED_DNS_SERVER" != "system" ]]; then
        # 尝试使用dig获取IP（指定DNS服务器）
        if command -v dig >/dev/null 2>&1; then
            ip=$(dig +short @"$SELECTED_DNS_SERVER" "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        fi
        
        # 如果dig失败，尝试使用nslookup（指定DNS服务器）
        if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
            ip=$(nslookup "$domain" "$SELECTED_DNS_SERVER" 2>/dev/null | grep -A 1 "Name:" | grep "Address:" | head -n1 | awk '{print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        fi
    else
        # 使用系统默认DNS或未选择DNS时的默认行为
        # 尝试使用dig获取IP
        if command -v dig >/dev/null 2>&1; then
            ip=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        fi
        
        # 如果dig失败，尝试使用nslookup
        if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
            ip=$(nslookup "$domain" 2>/dev/null | grep -A 1 "Name:" | grep "Address:" | head -n1 | awk '{print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        fi
    fi
    
    # 如果还是失败，尝试使用ping获取IP
    if [ -z "$ip" ]; then
        ip=$(ping -c 1 "$domain" 2>/dev/null | grep "PING" | sed -n 's/.*(\([0-9.]*\)).*/\1/p' | head -n1)
    fi
    
    echo "$ip"
}

# 测试DNS解析速度（支持测试多个域名）
test_dns_resolution() {
    local domains=("$@")
    local dns_server=""
    local dns_name=""
    
    # 从参数中提取DNS服务器信息（最后两个参数）
    local total_params=$#
    dns_server="${!total_params}"
    dns_name="${@:$((total_params-1)):1}"
    
    # 移除最后两个参数，剩下的都是域名
    domains=("${@:1:$((total_params-2))}")
    
    echo -e "🔍 测试 ${CYAN}${dns_name}${NC} 解析速度..."
    
    local total_time=0
    local successful_tests=0
    local failed_tests=0
    
    for domain in "${domains[@]}"; do
        echo -n -e "  └─ ${domain}... "
        local start_time end_time resolution_time
        
        if [ "$dns_server" = "system" ]; then
            # 使用系统默认DNS
            start_time=$(date +%s%N)
            if nslookup "$domain" >/dev/null 2>&1; then
                end_time=$(date +%s%N)
                resolution_time=$(( (end_time - start_time) / 1000000 ))
                echo -e "${GREEN}${resolution_time}ms ✅${NC}"
                total_time=$((total_time + resolution_time))
                ((successful_tests++))
            else
                echo -e "${RED}失败 ❌${NC}"
                ((failed_tests++))
            fi
        else
            # 使用指定DNS服务器
            start_time=$(date +%s%N)
            if nslookup "$domain" "$dns_server" >/dev/null 2>&1; then
                end_time=$(date +%s%N)
                resolution_time=$(( (end_time - start_time) / 1000000 ))
                echo -e "${GREEN}${resolution_time}ms ✅${NC}"
                total_time=$((total_time + resolution_time))
                ((successful_tests++))
            else
                echo -e "${RED}失败 ❌${NC}"
                ((failed_tests++))
            fi
        fi
    done
    
    # 计算平均解析时间
    if [ $successful_tests -gt 0 ]; then
        local avg_time=$((total_time / successful_tests))
        echo -e "  ${YELLOW}平均: ${avg_time}ms (成功: ${successful_tests}, 失败: ${failed_tests})${NC}"
        
        # 判断状态
        local status=""
        if (( avg_time < 50 )); then
            status="优秀"
        elif (( avg_time < 100 )); then
            status="良好"
        elif (( avg_time < 200 )); then
            status="一般"
        else
            status="较差"
        fi
        
        DNS_RESULTS+=("${dns_name}|${dns_server}|${avg_time}|${status}")
    else
        echo -e "  ${RED}全部失败${NC}"
        DNS_RESULTS+=("${dns_name}|${dns_server}|999|失败")
    fi
    echo ""
}

# 测试下载速度
test_download_speed() {
    local name=$1
    local url=$2
    
    echo -n -e "📥 测试 ${CYAN}${name}${NC} 下载速度... "
    
    # 使用curl测试下载速度，10秒测试时间
    local speed_output
    local timeout_cmd=$(get_timeout_cmd)
    
    if [[ -n "$timeout_cmd" ]]; then
        speed_output=$($timeout_cmd 12 curl -o /dev/null -s -w '%{speed_download}' --max-time 10 --connect-timeout 4 "$url" 2>/dev/null || echo "0")
    else
        # macOS没有timeout命令时，直接使用curl的超时参数
        speed_output=$(curl -o /dev/null -s -w '%{speed_download}' --max-time 10 --connect-timeout 4 "$url" 2>/dev/null || echo "0")
    fi
    
    if [[ "$speed_output" =~ ^[0-9]+\.?[0-9]*$ ]] && [ "$(echo "$speed_output > 0" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
        # 转换为更易读的格式
        local speed_mbps=$(echo "scale=2; $speed_output / 1048576" | bc -l 2>/dev/null)
        if [ "$(echo "$speed_mbps > 0.1" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
            echo -e "${GREEN}${speed_mbps} MB/s ⚡${NC}"
            DOWNLOAD_RESULTS+=("${name}|${url}|${speed_mbps} MB/s|成功")
        else
            local speed_kbps=$(echo "scale=0; $speed_output / 1024" | bc -l 2>/dev/null)
            echo -e "${YELLOW}${speed_kbps} KB/s 🐌${NC}"
            DOWNLOAD_RESULTS+=("${name}|${url}|${speed_kbps} KB/s|慢速")
        fi
    else
        echo -e "${RED}失败 ❌${NC}"
        DOWNLOAD_RESULTS+=("${name}|${url}|失败|失败")
    fi
}

# 测试丢包率
test_packet_loss() {
    local host=$1
    local service=$2
    
    echo -n -e "📡 测试 ${CYAN}${service}${NC} 丢包率... "
    
    local ping_result
    local timeout_cmd=$(get_timeout_cmd)
    local ping_cmd=$(get_ping_cmd "4" "$host")
    local interval=$(get_ping_interval)
    
    if [[ -n "$timeout_cmd" ]]; then
        if [[ -n "$interval" ]]; then
            ping_result=$($timeout_cmd 15 $ping_cmd -c $PING_COUNT $interval "$host" 2>/dev/null || echo "")
        else
            ping_result=$($timeout_cmd 15 $ping_cmd -c $PING_COUNT "$host" 2>/dev/null || echo "")
        fi
    else
        # macOS没有timeout命令时，直接使用ping
        if [[ -n "$interval" ]]; then
            ping_result=$($ping_cmd -c $PING_COUNT $interval "$host" 2>/dev/null || echo "")
        else
            ping_result=$($ping_cmd -c $PING_COUNT "$host" 2>/dev/null || echo "")
        fi
    fi
    
    if [ -n "$ping_result" ]; then
        # 提取丢包率
        local packet_loss
        packet_loss=$(echo "$ping_result" | grep "packet loss" | sed -n 's/.*\([0-9]\+\)% packet loss.*/\1/p')
        
        if [ -n "$packet_loss" ]; then
            if [ "$packet_loss" -eq 0 ]; then
                echo -e "${GREEN}${packet_loss}% 🟢${NC}"
            elif [ "$packet_loss" -lt 5 ]; then
                echo -e "${YELLOW}${packet_loss}% 🟡${NC}"
            else
                echo -e "${RED}${packet_loss}% 🔴${NC}"
            fi
            return "$packet_loss"
        else
            echo -e "${RED}无法检测 ❌${NC}"
            return 100
        fi
    else
        echo -e "${RED}测试失败 ❌${NC}"
        return 100
    fi
}

# 显示欢迎界面
show_welcome() {
    clear
    echo ""
    echo -e "${CYAN}🚀 ${YELLOW}网络延迟一键检测工具${NC}"
    echo ""
    echo -e "${BLUE}快速检测您的网络连接到各大网站的延迟情况${NC}"
    echo ""
}

# 显示主菜单
show_menu() {
    echo ""
    echo -e "${CYAN}🎯 选择测试模式${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC} 🌐 Ping/真连接测试"
    echo -e "  ${GREEN}2${NC} 🔍 DNS测试"
    echo -e "  ${GREEN}3${NC} 🔄 综合测试"
    echo -e "  ${GREEN}4${NC} 🌍 IPv4/IPv6优先设置"
    echo -e "  ${GREEN}5${NC} ⚙️  DNS解析设置"
    echo -e "  ${RED}0${NC} 🚪 退出程序"
    echo ""
}

# 测试TCP连接延迟
test_tcp_latency() {
    local host=$1
    local port=$2
    local count=${3:-3}
    
    local total_time=0
    local successful_connects=0
    
    for ((i=1; i<=count; i++)); do
        local start_time=$(date +%s%N)
        local timeout_cmd=$(get_timeout_cmd)
        
        if [[ -n "$timeout_cmd" ]]; then
            if $timeout_cmd 5 bash -c "exec 3<>/dev/tcp/$host/$port && exec 3<&- && exec 3>&-" 2>/dev/null; then
                local end_time=$(date +%s%N)
                local connect_time=$(( (end_time - start_time) / 1000000 ))
                total_time=$((total_time + connect_time))
                ((successful_connects++))
            fi
        else
            # macOS没有timeout，直接尝试连接（可能会等待更长时间）
            if bash -c "exec 3<>/dev/tcp/$host/$port && exec 3<&- && exec 3>&-" 2>/dev/null; then
                local end_time=$(date +%s%N)
                local connect_time=$(( (end_time - start_time) / 1000000 ))
                total_time=$((total_time + connect_time))
                ((successful_connects++))
            fi
        fi
    done
    
    if [ $successful_connects -gt 0 ]; then
        echo $((total_time / successful_connects))
    else
        echo "999999"
    fi
}

# 测试HTTP连接延迟
test_http_latency() {
    local host=$1
    local count=${2:-3}
    
    local total_time=0
    local successful_requests=0
    
    for ((i=1; i<=count; i++)); do
        local timeout_cmd=$(get_timeout_cmd)
        local connect_time
        
        if [[ -n "$timeout_cmd" ]]; then
            connect_time=$($timeout_cmd 8 curl -o /dev/null -s -w '%{time_connect}' --max-time 6 --connect-timeout 4 "https://$host" 2>/dev/null || echo "999")
        else
            # macOS没有timeout，直接使用curl的超时参数
            connect_time=$(curl -o /dev/null -s -w '%{time_connect}' --max-time 6 --connect-timeout 4 "https://$host" 2>/dev/null || echo "999")
        fi
        
        if [[ "$connect_time" =~ ^[0-9]+\.?[0-9]*$ ]] && [ "$(echo "$connect_time < 10" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
            local time_ms=$(echo "$connect_time * 1000" | bc -l 2>/dev/null | cut -d'.' -f1)
            total_time=$((total_time + time_ms))
            ((successful_requests++))
        fi
    done
    
    if [ $successful_requests -gt 0 ]; then
        echo $((total_time / successful_requests))
    else
        echo "999999"
    fi
}

# 测试单个网站延迟（跨平台兼容的fping优化）
test_site_latency() {
    local host=$1
    local service=$2
    local show_ip=${3:-true}
    
    # 确定要测试的IP版本并显示相应提示
    local test_version="4"  # 默认IPv4
    local version_label="IPv4"
    local target_ip=""
    local fallback_needed=false
    
    if [[ "$IP_VERSION" == "6" ]]; then
        # IPv6优先：先尝试IPv6，如果没有则fallback到IPv4
        ipv6_addr=$(get_ipv6_address "$host")
        if [[ -n "$ipv6_addr" && "$ipv6_addr" != "N/A" ]]; then
            test_version="6"
            version_label="IPv6"
            target_ip="$ipv6_addr"
        else
            # IPv6不可用，fallback到IPv4
            test_version="4"
            version_label="IPv4(fallback)"
            ip_addr=$(get_ip_address "$host")
            target_ip="$ip_addr"
            fallback_needed=true
        fi
    elif [[ "$IP_VERSION" == "4" ]]; then
        test_version="4" 
        version_label="IPv4"
        ip_addr=$(get_ip_address "$host")
        target_ip="$ip_addr"
    else
        # 自动选择：优先IPv4，如果IPv4不可用则使用IPv6
        test_version="4"
        version_label="IPv4"
        ip_addr=$(get_ip_address "$host")
        target_ip="$ip_addr"
    fi
    
    echo -n -e "🔍 ${CYAN}$(printf "%-12s" "$service")${NC} "
    
    local ping_result=""
    local ping_ms=""
    local status=""
    local latency_ms=""
    local packet_loss=0
    
    # 使用fping进行测试（如果可用且跨平台兼容）
    if command -v fping >/dev/null 2>&1; then
        local fping_cmd=""
        local timeout_cmd=$(get_timeout_cmd)
        
        if [[ "$test_version" == "6" ]] && [[ -n "$ipv6_addr" ]]; then
            if command -v fping6 >/dev/null 2>&1; then
                fping_cmd="fping6"
            else
                fping_cmd="fping -6"
            fi
            if [[ -n "$timeout_cmd" ]]; then
                ping_result=$($timeout_cmd 15 $fping_cmd -c $PING_COUNT -q "$host" 2>&1 || true)
            else
                ping_result=$($fping_cmd -c $PING_COUNT -q "$host" 2>&1 || true)
            fi
        elif [[ "$test_version" == "4" ]] && [[ -n "$ip_addr" ]]; then
            fping_cmd="fping -4"
            if [[ -n "$timeout_cmd" ]]; then
                ping_result=$($timeout_cmd 15 $fping_cmd -c $PING_COUNT -q "$host" 2>&1 || true)
            else
                ping_result=$($fping_cmd -c $PING_COUNT -q "$host" 2>&1 || true)
            fi
        else
            # 如果指定版本的IP不可用，回退到默认fping
            if [[ -n "$timeout_cmd" ]]; then
                ping_result=$($timeout_cmd 15 fping -c $PING_COUNT -q "$host" 2>&1 || true)
            else
                ping_result=$(fping -c $PING_COUNT -q "$host" 2>&1 || true)
            fi
        fi
        
        if [[ -n "$ping_result" ]]; then
            # 解析fping结果 - 兼容不同版本的fping输出格式
            if echo "$ping_result" | grep -q "avg"; then
                ping_ms=$(echo "$ping_result" | grep -o '[0-9.]*ms' | head -n1 | sed 's/ms//')
            else
                ping_ms=$(echo "$ping_result" | grep -o '[0-9.]*\/[0-9.]*\/[0-9.]*' | cut -d'/' -f2 || echo "")
            fi
            
            # 提取丢包率
            if echo "$ping_result" | grep -q "loss"; then
                packet_loss=$(echo "$ping_result" | grep -o '[0-9]*% loss' | sed 's/% loss//' || echo "0")
            else
                packet_loss=$(echo "$ping_result" | grep -o '[0-9]*%' | sed 's/%//' || echo "0")
            fi
            
            if [[ "$ping_ms" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                latency_ms="$ping_ms"
            fi
        fi
    else
        # 回退到标准ping（跨平台兼容）
        local ping_cmd=$(get_ping_cmd "$test_version" "$host")
        local interval=$(get_ping_interval)
        local timeout_cmd=$(get_timeout_cmd)
        
        if [[ -n "$timeout_cmd" ]]; then
            if [[ -n "$interval" ]]; then
                ping_result=$($timeout_cmd 15 $ping_cmd -c $PING_COUNT $interval "$host" 2>/dev/null || true)
            else
                ping_result=$($timeout_cmd 15 $ping_cmd -c $PING_COUNT "$host" 2>/dev/null || true)
            fi
        else
            # macOS没有timeout命令时，直接使用ping
            if [[ -n "$interval" ]]; then
                ping_result=$($ping_cmd -c $PING_COUNT $interval "$host" 2>/dev/null || true)
            else
                ping_result=$($ping_cmd -c $PING_COUNT "$host" 2>/dev/null || true)
            fi
        fi
        
        if [[ -n "$ping_result" ]]; then
            # 兼容不同系统的ping输出格式
            if [[ "$OS_TYPE" == "macos" ]]; then
                ping_ms=$(echo "$ping_result" | grep 'round-trip' | cut -d'=' -f2 | cut -d'/' -f2 2>/dev/null || echo "")
            else
                ping_ms=$(echo "$ping_result" | grep 'rtt min/avg/max/mdev' | cut -d'/' -f5 | cut -d' ' -f1 2>/dev/null || echo "")
            fi
            
            # 提取丢包率
            packet_loss=$(echo "$ping_result" | grep -o '[0-9]*% packet loss' | sed 's/% packet loss//' 2>/dev/null || echo "0")
            
            if [[ "$ping_ms" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                latency_ms="$ping_ms"
            fi
        fi
    fi
    
    # 如果ping失败，尝试HTTP连接测试
    if [[ -z "$latency_ms" ]]; then
        case "$service" in
            "Telegram")
                local tcp_latency=$(test_tcp_latency "$host" 443 2)
                if [[ "$tcp_latency" != "999999" ]]; then
                    latency_ms="$tcp_latency.0"
                fi
                ;;
            "Netflix")
                local timeout_cmd=$(get_timeout_cmd)
                local connect_time
                
                if [[ -n "$timeout_cmd" ]]; then
                    connect_time=$($timeout_cmd 8 curl -o /dev/null -s -w '%{time_connect}' --max-time 6 --connect-timeout 4 "https://$host" 2>/dev/null || echo "999")
                else
                    connect_time=$(curl -o /dev/null -s -w '%{time_connect}' --max-time 6 --connect-timeout 4 "https://$host" 2>/dev/null || echo "999")
                fi
                
                if [[ "$connect_time" =~ ^[0-9]+\.?[0-9]*$ ]] && (( $(echo "$connect_time < 10" | bc -l 2>/dev/null || echo 0) )); then
                    local time_ms=$(echo "$connect_time * 1000" | bc -l 2>/dev/null | cut -d'.' -f1)
                    latency_ms="$time_ms.0"
                fi
                ;;
            *)
                local http_latency=$(test_http_latency "$host" 2)
                if [[ "$http_latency" != "999999" ]]; then
                    latency_ms="$http_latency.0"
                fi
                ;;
        esac
    fi
    
    # 根据延迟结果显示状态
    if [[ -n "$latency_ms" ]] && [[ "$latency_ms" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        local latency_int=$(echo "$latency_ms" | cut -d'.' -f1)
        
        # 构建状态信息
        local loss_info=""
        if [[ "$packet_loss" -gt 0 ]]; then
            loss_info=" 丢包${packet_loss}%"
        fi
        
        # 只显示实际测试的IP版本信息
        local ip_display=""
        if [[ "$test_version" == "6" ]] && [[ -n "$ipv6_addr" ]]; then
            ip_display="${ipv6_addr}"
        elif [[ "$test_version" == "4" ]] && [[ -n "$ip_addr" ]]; then
            ip_display="${ip_addr}"
        elif [[ -n "$target_ip" ]]; then
            ip_display="${target_ip}"
        else
            ip_display="N/A"
        fi
        
        if [[ "$latency_int" -lt 50 ]]; then
            status="优秀"
            echo -e "$(printf "%-8s %-15s %-8s" "${version_label}" "${ip_display}" "${latency_ms}ms") ${GREEN}🟢 优秀${NC}"
        elif [[ "$latency_int" -lt 150 ]]; then
            status="良好"
            echo -e "$(printf "%-8s %-15s %-8s" "${version_label}" "${ip_display}" "${latency_ms}ms") ${YELLOW}🟡 良好${NC}"
        elif [[ "$latency_int" -lt 500 ]]; then
            status="较差"
            echo -e "$(printf "%-8s %-15s %-8s" "${version_label}" "${ip_display}" "${latency_ms}ms") ${RED}🔴 较差${NC}"
        else
            status="很差"
            echo -e "$(printf "%-8s %-15s %-8s" "${version_label}" "${ip_display}" "${latency_ms}ms") ${RED}💀 很差${NC}"
        fi
        
        # 根据实际测试的版本存储相应的IP地址信息
        local result_ipv4="N/A"
        local result_ipv6="N/A"
        
        if [[ "$test_version" == "6" ]]; then
            result_ipv6="${ipv6_addr:-N/A}"
        elif [[ "$test_version" == "4" ]]; then
            result_ipv4="${ip_addr:-N/A}"
        fi
        
        RESULTS+=("$service|$host|${latency_ms}ms|$status|$result_ipv4|$result_ipv6|${packet_loss}%|${version_label}")
    else
        # 最后尝试简单连通性测试
        local timeout_cmd=$(get_timeout_cmd)
        local curl_success=false
        
        if [[ -n "$timeout_cmd" ]]; then
            if $timeout_cmd 5 curl -s --connect-timeout 3 "https://$host" >/dev/null 2>&1; then
                curl_success=true
            fi
        else
            # macOS没有timeout时，使用curl自带的超时
            if curl -s --max-time 5 --connect-timeout 3 "https://$host" >/dev/null 2>&1; then
                curl_success=true
            fi
        fi
        
        if $curl_success; then
            status="连通但测不出延迟"
            local ip_display=""
            if [[ "$test_version" == "6" ]] && [[ -n "$ipv6_addr" ]]; then
                ip_display="${ipv6_addr}"
            elif [[ "$test_version" == "4" ]] && [[ -n "$ip_addr" ]]; then
                ip_display="${ip_addr}"
            elif [[ -n "$target_ip" ]]; then
                ip_display="${target_ip}"
            else
                ip_display="N/A"
            fi
            printf "%-8s %-15s %-8s %s连通%s\n" "${version_label}" "${ip_display}" "N/A" "${YELLOW}🟡 " "${NC}"
            
            local result_ipv4="N/A"
            local result_ipv6="N/A"
            if [[ "$test_version" == "6" ]]; then
                result_ipv6="${ipv6_addr:-N/A}"
            elif [[ "$test_version" == "4" ]]; then
                result_ipv4="${ip_addr:-N/A}"
            fi
            
            RESULTS+=("$service|$host|连通|连通但测不出延迟|$result_ipv4|$result_ipv6|N/A|${version_label}")
        else
            status="失败"
            printf "%-8s %-15s %-8s %s失败%s\n" "${version_label}" "N/A" "超时" "${RED}❌ " "${NC}"
            RESULTS+=("$service|$host|超时|失败|N/A|N/A|N/A|${version_label}")
        fi
    fi
}

# 执行完整网站测试
run_test() {
    clear
    show_welcome
    
    echo -e "${CYAN}🌐 开始Ping/真连接测试 (${#FULL_SITES[@]}个网站)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "测试参数: ${YELLOW}${#FULL_SITES[@]}个网站${NC} | Ping次数: ${YELLOW}${PING_COUNT}${NC}"
    if [ -n "$IP_VERSION" ]; then
        echo -e "IP版本: ${YELLOW}IPv${IP_VERSION}优先${NC}"
    fi
    if [[ -n "$SELECTED_DNS_SERVER" && "$SELECTED_DNS_SERVER" != "system" ]]; then
        echo -e "DNS解析: ${YELLOW}${SELECTED_DNS_NAME} (${SELECTED_DNS_SERVER})${NC}"
    else
        echo -e "DNS解析: ${YELLOW}系统默认${NC}"
    fi
    
    # 第一步：使用fping进行快速批量测试
    show_fping_results
    
    echo ""
    echo -e "${CYAN}🔗 开始真实连接延迟测试...${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # 重置结果数组
    RESULTS=()
    local start_time=$(date +%s)
    
    # 执行详细测试
    for service in "${!FULL_SITES[@]}"; do
        host="${FULL_SITES[$service]}"
        test_site_latency "$host" "$service"
    done
    
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    
    # 显示结果
    show_results "$total_time"
}

# DNS测试模式（测试所有网站）
run_dns_test() {
    clear
    show_welcome
    
    echo -e "${CYAN}🔍 DNS延迟测试${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}选择测试方式:${NC}"
    echo -e "  ${GREEN}1${NC} - DNS延迟+解析速度综合测试 (推荐)"
    echo -e "  ${GREEN}2${NC} - 传统详细DNS解析测试"
    echo -e "  ${GREEN}3${NC} - DNS综合分析 (测试各DNS解析IP的实际延迟)"
    echo -e "  ${RED}0${NC} - 返回主菜单"
    echo ""
    echo -n -e "${YELLOW}请选择 (0-3): ${NC}"
    read -r dns_choice
    
    case $dns_choice in
        1)
            clear
            show_welcome
            echo -e "${CYAN}🔍 DNS服务器延迟 + DNS解析速度测试${NC}"
            echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
            echo ""
            
            # 第一步：使用fping测试DNS服务器延迟
            echo -e "${YELLOW}📡 第1步: DNS服务器延迟测试 (使用fping)${NC}"
            echo -e "${BLUE}测试DNS服务器: 17个${NC}"
            echo ""
            
            local dns_hosts=()
            local dns_host_names=()
            for dns_name in "${!DNS_SERVERS[@]}"; do
                if [[ "${DNS_SERVERS[$dns_name]}" != "system" ]]; then
                    dns_hosts+=("${DNS_SERVERS[$dns_name]}")
                    dns_host_names+=("$dns_name")
                fi
            done
            
            if command -v fping > /dev/null; then
                echo -e "${YELLOW}正在测试DNS服务器网络延迟...${NC}"
                echo ""
                
                local fping_output=$(fping -c 10 -t 2000 -q "${dns_hosts[@]}" 2>&1)
                
                # 显示DNS服务器延迟结果表格 - 使用column命令对齐
                declare -a dns_latency_results=()
                
                for i in "${!dns_host_names[@]}"; do
                    local dns_name="${dns_host_names[$i]}"
                    local ip="${dns_hosts[$i]}"
                    
                    # macOS和Linux的fping输出格式不同，需要分别处理
                    local result=$(echo "$fping_output" | grep "^$ip")
                    
                    if [[ -n "$result" ]]; then
                        # macOS格式: 8.8.8.8 : xmt/rcv/%loss = 3/3/0%, min/avg/max = 45.5/46.6/47.5
                        # Linux格式: 8.8.8.8 : [0], 84 bytes, 46.2 ms (46.2 avg, 0% loss)
                        
                        if echo "$result" | grep -q "min/avg/max"; then
                            # macOS格式
                            local avg=$(echo "$result" | sed -n 's/.*min\/avg\/max = [0-9.]*\/\([0-9.]*\)\/.*/\1/p')
                            local loss=$(echo "$result" | sed -n 's/.*xmt\/rcv\/%loss = [0-9]*\/[0-9]*\/\([0-9]*\)%.*/\1/p')
                        else
                            # Linux格式
                            local avg=$(echo "$result" | sed -n 's/.*avg\/max = [0-9.]*\/[0-9.]*\/\([0-9.]*\).*/\1/p')
                            local loss=$(echo "$result" | sed -n 's/.*loss = \([0-9]*\)%.*/\1/p')
                        fi
                        
                        if [[ -n "$avg" && -n "$loss" ]]; then
                            # 根据延迟和丢包率确定状态和颜色
                            local status=""
                            local latency_int=$(echo "$avg" | cut -d'.' -f1)
                            local score=0
                            
                            # 计算评分：延迟越低越好，丢包率越低越好
                            if [[ "$loss" -gt 5 ]]; then
                                status="差"
                                score=1000  # 丢包率高的排在最后
                            elif [[ "$latency_int" -lt 30 ]]; then
                                status="优秀"
                                score=$((latency_int + loss * 10))
                            elif [[ "$latency_int" -lt 60 ]]; then
                                status="良好"
                                score=$((latency_int + loss * 10))
                            elif [[ "$latency_int" -lt 120 ]]; then
                                status="一般"
                                score=$((latency_int + loss * 10))
                            else
                                status="较差"
                                score=$((latency_int + loss * 10))
                            fi
                            
                            dns_latency_results+=("$score|$dns_name|$ip|${avg}ms|${loss}%($status)")
                        else
                            dns_latency_results+=("9999|$dns_name|$ip|解析失败|100%(失败)")
                        fi
                    else
                        dns_latency_results+=("9999|$dns_name|$ip|超时|100%(超时)")
                    fi
                done
                
                # 显示表格
                echo ""
                printf "%-4s %-15s %-20s %-12s %-8s\n" "排名" "DNS服务器" "IP地址" "平均延迟" "丢包率"
                echo "─────────────────────────────────────────────────────────────────────────"
                
                # 排序并显示结果
                IFS=$'\n' sorted_results=($(printf '%s\n' "${dns_latency_results[@]}" | sort -t'|' -k1 -n))
                
                local rank=1
                for result in "${sorted_results[@]}"; do
                    IFS='|' read -r score dns_name ip latency status <<< "$result"
                    
                    # 提取状态颜色
                    local status_colored=""
                    if [[ "$status" == *"优秀"* ]]; then
                        status_colored="${GREEN}✅ 优秀${NC}"
                    elif [[ "$status" == *"良好"* ]]; then
                        status_colored="${YELLOW}✅ 良好${NC}"
                    elif [[ "$status" == *"一般"* ]]; then
                        status_colored="${PURPLE}⚠️ 一般${NC}"
                    elif [[ "$status" == *"较差"* ]]; then
                        status_colored="${RED}❌ 较差${NC}"
                    elif [[ "$status" == *"差"* ]]; then
                        status_colored="${RED}❌ 差${NC}"
                    else
                        status_colored="${RED}❌ 失败${NC}"
                    fi
                    
                    print_aligned_row "$rank" "$dns_name" "$ip" "$latency" "$status_colored"
                    ((rank++))
                done
                
                echo ""
                echo -e "${GREEN}✅ DNS服务器延迟测试完成${NC}"
                echo ""
                
                # 第二步：DNS解析速度测试
                echo -e "${YELLOW}🔍 第2步: DNS解析速度测试 (测试域名: google.com)${NC}"
                echo ""
                
                declare -a dns_resolution_results=()
                
                for dns_name in "${!DNS_SERVERS[@]}"; do
                    local dns_server="${DNS_SERVERS[$dns_name]}"
                    
                    if [[ "$dns_server" == "system" ]]; then
                        # 系统DNS测试
                        local start_time=$(date +%s%N)
                        nslookup google.com >/dev/null 2>&1
                        local end_time=$(date +%s%N)
                        local resolution_time=$(( (end_time - start_time) / 1000000 ))
                        
                        # 根据解析时间确定状态
                        local status=""
                        if [[ "$resolution_time" -lt 50 ]]; then
                            status="优秀"
                        elif [[ "$resolution_time" -lt 100 ]]; then
                            status="良好"
                        elif [[ "$resolution_time" -lt 200 ]]; then
                            status="一般"
                        else
                            status="较差"
                        fi
                        
                        dns_resolution_results+=("$resolution_time|$dns_name|系统默认|${resolution_time}ms|$status")
                    else
                        # 指定DNS服务器测试
                        local start_time=$(date +%s%N)
                        nslookup google.com "$dns_server" >/dev/null 2>&1
                        local end_time=$(date +%s%N)
                        local resolution_time=$(( (end_time - start_time) / 1000000 ))
                        
                        if [[ $? -eq 0 ]]; then
                            # 根据解析时间确定状态
                            local status=""
                            if [[ "$resolution_time" -lt 50 ]]; then
                                status="优秀"
                            elif [[ "$resolution_time" -lt 100 ]]; then
                                status="良好"
                            elif [[ "$resolution_time" -lt 200 ]]; then
                                status="一般"
                            else
                                status="较差"
                            fi
                            
                            dns_resolution_results+=("$resolution_time|$dns_name|$dns_server|${resolution_time}ms|$status")
                        else
                            dns_resolution_results+=("9999|$dns_name|$dns_server|解析失败|失败")
                        fi
                    fi
                done
                
                # 按解析时间排序并显示
                echo ""
                echo "📊 DNS解析速度测试结果"
                echo "─────────────────────────────────────────────────────────────────────────"
                printf "%-4s %-15s %-20s %-12s %-8s\n" "排名" "DNS服务器" "IP地址" "解析时间" "状态"
                echo "─────────────────────────────────────────────────────────────────────────"
                
                # 排序并显示结果
                IFS=$'\n' sorted_results=($(printf '%s\n' "${dns_resolution_results[@]}" | sort -t'|' -k1 -n))
                
                local rank=1
                for result in "${sorted_results[@]}"; do
                    IFS='|' read -r time dns_name server resolution_time status <<< "$result"
                    
                    # 根据状态着色并添加图标
                    local status_colored=""
                    case "$status" in
                        "优秀") status_colored="${GREEN}优秀${NC}" ;;
                        "良好") status_colored="${YELLOW}良好${NC}" ;;
                        "一般") status_colored="${PURPLE}一般${NC}" ;;
                        "较差") status_colored="${RED}较差${NC}" ;;
                        "失败") status_colored="${RED}失败${NC}" ;;
                        *) status_colored="${RED}失败${NC}" ;;
                    esac
                    
                    print_aligned_row "$rank" "$dns_name" "$server" "$resolution_time" "$status_colored"
                    ((rank++))
                done
                
                echo ""
                echo -e "${GREEN}✅ DNS解析速度测试完成${NC}"
                
            else
                echo -e "${RED}fping未安装，无法进行批量测试${NC}"
                echo -e "${YELLOW}请安装fping: brew install fping${NC}"
            fi
            ;;
        2)
            # 原来的DNS测试方式
            echo -e "${CYAN}🔍 开始全球DNS解析速度测试（测试所有网站）${NC}"
            echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
            echo -e "测试网站: ${YELLOW}${#FULL_SITES[@]}个网站${NC} | DNS服务器: ${YELLOW}$(echo ${!DNS_SERVERS[@]} | wc -w | tr -d ' ')个${NC}"
            echo ""
            
            # 重置结果数组
            DNS_RESULTS=()
            local start_time=$(date +%s)
            
            # 准备所有网站域名列表
            local all_domains=()
            for domain in "${FULL_SITES[@]}"; do
                all_domains+=("$domain")
            done
            
            # 执行DNS测试
            for dns_name in "${!DNS_SERVERS[@]}"; do
                dns_server="${DNS_SERVERS[$dns_name]}"
                test_dns_resolution "${all_domains[@]}" "$dns_name" "$dns_server"
            done
            
            local end_time=$(date +%s)
            local total_time=$((end_time - start_time))
            
            # 显示DNS测试结果
            show_dns_results "$total_time"
            ;;
        3)
            # DNS综合分析
            run_dns_comprehensive_analysis
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}❌ 无效选择${NC}"
            sleep 2
            run_dns_test
            ;;
    esac
    
    # 等待用户按键
    echo ""
    if [[ -t 0 ]]; then
        echo -n -e "${YELLOW}按 Enter 键继续...${NC}"
        read -r
    fi
}

# IPv4/IPv6优先测试模式
run_ip_version_test() {
    clear
    show_welcome
    
    echo -e "${CYAN}🌍 IPv4/IPv6优先设置${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}说明: 这只是测试时的IP协议优先设置，不会更改系统网络配置${NC}"
    echo ""
    echo -e "${YELLOW}选择测试协议优先级:${NC}"
    echo -e "  ${GREEN}1${NC} - IPv4优先测试 (优先使用IPv4地址)"
    echo -e "  ${GREEN}2${NC} - IPv6优先测试 (优先使用IPv6地址)"
    echo -e "  ${GREEN}3${NC} - 自动选择 (系统默认)"
    echo -e "  ${GREEN}4${NC} - 查看当前设置"
    echo -e "  ${RED}0${NC} - 返回主菜单"
    echo ""
    
    # 显示当前设置
    case $IP_VERSION in
        "4")
            echo -e "${CYAN}当前设置: IPv4优先${NC}"
            ;;
        "6")
            echo -e "${CYAN}当前设置: IPv6优先${NC}"
            ;;
        "")
            echo -e "${CYAN}当前设置: 自动选择${NC}"
            ;;
    esac
    echo ""
    
    echo -n -e "${YELLOW}请选择 (0-5): ${NC}"
    read -r ip_choice
    
    case $ip_choice in
        1)
            IP_VERSION="4"
            echo -e "${GREEN}✅ 已设置为IPv4优先模式${NC}"
            echo -e "${YELLOW}设置已保存，返回主菜单后可进行测试${NC}"
            sleep 2
            run_ip_version_test
            ;;
        2)
            IP_VERSION="6"
            echo -e "${GREEN}✅ 已设置为IPv6优先模式${NC}"
            echo -e "${YELLOW}设置已保存，返回主菜单后可进行测试${NC}"
            sleep 2
            run_ip_version_test
            ;;
        3)
            IP_VERSION=""
            echo -e "${GREEN}✅ 已设置为自动选择模式${NC}"
            echo -e "${YELLOW}设置已保存，返回主菜单后可进行测试${NC}"
            sleep 2
            run_ip_version_test
            ;;
        4)
            echo ""
            echo -e "${CYAN}📋 当前IP协议设置详情:${NC}"
            echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
            case $IP_VERSION in
                "4")
                    echo -e "优先级: ${GREEN}IPv4优先${NC}"
                    echo -e "说明: 测试时优先尝试IPv4地址连接"
                    ;;
                "6")
                    echo -e "优先级: ${GREEN}IPv6优先${NC}"
                    echo -e "说明: 测试时优先尝试IPv6地址连接"
                    ;;
                "")
                    echo -e "优先级: ${GREEN}自动选择${NC}"
                    echo -e "说明: 使用系统默认IP协议栈"
                    ;;
            esac
            echo ""
            echo -n -e "${YELLOW}按 Enter 键继续...${NC}"
            read -r
            run_ip_version_test
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}❌ 无效选择${NC}"
            sleep 2
            run_ip_version_test
            ;;
    esac
}
# 综合测试模式
run_comprehensive_test() {
    clear
    show_welcome
    
    echo -e "${CYAN}📊 开始综合测试 (Ping/真连接+下载速度)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # 显示当前DNS设置
    if [[ -n "$SELECTED_DNS_SERVER" && "$SELECTED_DNS_SERVER" != "system" ]]; then
        echo -e "🔍 DNS解析设置: ${YELLOW}${SELECTED_DNS_NAME} (${SELECTED_DNS_SERVER})${NC}"
    else
        echo -e "🔍 DNS解析设置: ${YELLOW}系统默认${NC}"
    fi
    echo ""
    
    # 重置所有结果数组
    RESULTS=()
    DOWNLOAD_RESULTS=()
    local start_time=$(date +%s 2>/dev/null || echo 0)
    
    # 第一步：使用fping进行快速批量测试
    show_fping_results
    
    echo ""
    echo -e "${YELLOW}📡 第1步: 真实连接延迟测试${NC}"
    echo ""
    for service in "${!FULL_SITES[@]}"; do
        host="${FULL_SITES[$service]}"
        test_site_latency "$host" "$service"
    done
    
    echo ""
    echo -e "${YELLOW}🔍 第2步: DNS延迟+解析速度综合测试${NC}"
    echo ""
    
    # 第一步：使用fping测试DNS服务器延迟
    echo -e "${YELLOW}📡 DNS服务器延迟测试 (使用fping)${NC}"
    echo -e "${BLUE}测试DNS服务器: 17个${NC}"
    echo ""
    
    local dns_hosts=()
    local dns_host_names=()
    for dns_name in "${!DNS_SERVERS[@]}"; do
        if [[ "${DNS_SERVERS[$dns_name]}" != "system" ]]; then
            dns_hosts+=("${DNS_SERVERS[$dns_name]}")
            dns_host_names+=("$dns_name")
        fi
    done
    
    if command -v fping > /dev/null; then
        echo -e "${YELLOW}正在测试DNS服务器网络延迟...${NC}"
        echo ""
        
        local fping_output=$(fping -c 10 -t 2000 -q "${dns_hosts[@]}" 2>&1)
        
        # 显示DNS服务器延迟结果表格
        declare -a dns_latency_results=()
        
        for i in "${!dns_host_names[@]}"; do
            local dns_name="${dns_host_names[$i]}"
            local ip="${dns_hosts[$i]}"
            
            local result=$(echo "$fping_output" | grep "^$ip")
            
            if [[ -n "$result" ]]; then
                if echo "$result" | grep -q "min/avg/max"; then
                    # macOS格式
                    local avg=$(echo "$result" | sed -n 's/.*min\/avg\/max = [0-9.]*\/\([0-9.]*\)\/.*/\1/p')
                    local loss=$(echo "$result" | sed -n 's/.*xmt\/rcv\/%loss = [0-9]*\/[0-9]*\/\([0-9]*\)%.*/\1/p')
                else
                    # Linux格式
                    local avg=$(echo "$result" | sed -n 's/.*avg\/max = [0-9.]*\/[0-9.]*\/\([0-9.]*\).*/\1/p')
                    local loss=$(echo "$result" | sed -n 's/.*loss = \([0-9]*\)%.*/\1/p')
                fi
                
                if [[ -n "$avg" && -n "$loss" ]]; then
                    local status=""
                    local latency_int=$(echo "$avg" | cut -d'.' -f1)
                    local score=0
                    
                    if [[ "$loss" -gt 5 ]]; then
                        status="差"
                        score=1000
                    elif [[ "$latency_int" -lt 30 ]]; then
                        status="优秀"
                        score=$((latency_int + loss * 10))
                    elif [[ "$latency_int" -lt 60 ]]; then
                        status="良好"
                        score=$((latency_int + loss * 10))
                    elif [[ "$latency_int" -lt 120 ]]; then
                        status="一般"
                        score=$((latency_int + loss * 10))
                    else
                        status="较差"
                        score=$((latency_int + loss * 10))
                    fi
                    
                    dns_latency_results+=("$score|$dns_name|$ip|${avg}ms|${loss}%($status)")
                else
                    dns_latency_results+=("9999|$dns_name|$ip|解析失败|100%(失败)")
                fi
            else
                dns_latency_results+=("9999|$dns_name|$ip|超时|100%(超时)")
            fi
        done
        
        # 显示表格
        echo ""
        printf "%-4s %-15s %-20s %-12s %-8s\n" "排名" "DNS服务器" "IP地址" "平均延迟" "丢包率"
        echo "─────────────────────────────────────────────────────────────────────────"
        
        # 排序并显示结果
        IFS=$'\n' sorted_results=($(printf '%s\n' "${dns_latency_results[@]}" | sort -t'|' -k1 -n))
        
        local rank=1
        for result in "${sorted_results[@]}"; do
            IFS='|' read -r score dns_name ip latency status <<< "$result"
            
            # 提取状态颜色
            local status_colored=""
            if [[ "$status" == *"优秀"* ]]; then
                status_colored="${GREEN}✅ 优秀${NC}"
            elif [[ "$status" == *"良好"* ]]; then
                status_colored="${YELLOW}✅ 良好${NC}"
            elif [[ "$status" == *"一般"* ]]; then
                status_colored="${PURPLE}⚠️ 一般${NC}"
            elif [[ "$status" == *"较差"* ]]; then
                status_colored="${RED}❌ 较差${NC}"
            elif [[ "$status" == *"差"* ]]; then
                status_colored="${RED}❌ 差${NC}"
            else
                status_colored="${RED}❌ 失败${NC}"
            fi
            
            print_aligned_row "$rank" "$dns_name" "$ip" "$latency" "$status_colored"
            ((rank++))
        done
        
        echo ""
        echo -e "${GREEN}✅ DNS服务器延迟测试完成${NC}"
        echo ""
    fi
    
    # 第二步：DNS解析速度测试
    echo -e "${YELLOW}🔍 DNS解析速度测试 (测试域名: google.com)${NC}"
    echo ""
    
    local all_domains=("google.com")
    
    # 重置DNS_RESULTS
    DNS_RESULTS=()
    
    for dns_name in "${!DNS_SERVERS[@]}"; do
        dns_server="${DNS_SERVERS[$dns_name]}"
        test_dns_resolution "${all_domains[@]}" "$dns_name" "$dns_server"
    done
    
    # 显示DNS解析结果
    if [[ ${#DNS_RESULTS[@]} -gt 0 ]]; then
        echo ""
        echo -e "${CYAN}📊 DNS解析速度测试结果${NC}"
        echo "─────────────────────────────────────────────────────────────────────────"
        printf "%-4s %-15s %-20s %-12s %-8s\n" "排名" "DNS服务器" "IP地址" "解析时间" "状态"
        echo "─────────────────────────────────────────────────────────────────────────"
        
        # 排序DNS结果
        IFS=$'\n' sorted_dns=($(printf '%s\n' "${DNS_RESULTS[@]}" | sort -t'|' -k3 -n))
        
        local rank=1
        for result in "${sorted_dns[@]}"; do
            IFS='|' read -r dns_name dns_server resolution_time status <<< "$result"
            
            local display_server="$dns_server"
            if [[ "$dns_server" == "system" ]]; then
                display_server="系统默认"
            fi
            
            # 处理时间格式
            local clean_time="$resolution_time"
            clean_time="${clean_time/ms/}"
            
            # 处理状态格式和颜色
            local status_colored=""
            if [[ "$status" == "优秀" ]]; then
                status_colored="${GREEN}优秀${NC}"
            elif [[ "$status" == "良好" ]]; then
                status_colored="${YELLOW}良好${NC}"
            elif [[ "$status" == "一般" ]]; then
                status_colored="${PURPLE}一般${NC}"
            elif [[ "$status" == "较差" ]]; then
                status_colored="${RED}较差${NC}"
            else
                status_colored="${RED}失败${NC}"
            fi
            
            print_aligned_row "$rank" "$dns_name" "$display_server" "${clean_time}ms" "$status_colored"
            ((rank++))
        done
        
        echo ""
        echo -e "${GREEN}✅ DNS解析速度测试完成${NC}"
        echo ""
    fi
    
    echo ""
    echo -e "${YELLOW}🧪 第3步: DNS综合分析${NC}"
    echo ""
    
    # 使用DNS菜单中的选项3的内容
    echo -e "${CYAN}🔍 DNS综合分析 (测试各DNS解析IP的实际延迟)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}测试域名: google.com github.com apple.com${NC}"
    echo ""
    
    local test_domains=("google.com" "github.com" "apple.com")
    declare -a analysis_results=()
    local dns_count=0
    
    for dns_name in "${!DNS_SERVERS[@]}"; do
        dns_server="${DNS_SERVERS[$dns_name]}"
        ((dns_count++))
        
        echo -e "${YELLOW}[${dns_count}/17] 测试 ${dns_name} (${dns_server})...${NC}"
        
        local total_score=0
        local test_count=0
        
        for domain in "${test_domains[@]}"; do
            echo -n "  └─ ${domain}: "
            
            # DNS解析测试
            local start_time=$(get_timestamp_ms)
            local resolved_ip=""
            
            if [[ "$dns_server" == "system" ]]; then
                resolved_ip=$(dig +short +time=3 +tries=1 "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
            else
                resolved_ip=$(dig +short +time=3 +tries=1 "@$dns_server" "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
            fi
            
            local end_time=$(get_timestamp_ms)
            local dns_time_ms=$((end_time - start_time))
            
            if [[ -n "$resolved_ip" ]]; then
                echo -n "${resolved_ip} (解析${dns_time_ms}ms) "
                
                # Ping测试
                local ping_result=$(ping -c 3 -W 2000 "$resolved_ip" 2>/dev/null | grep 'avg' | awk -F'/' '{print $(NF-1)}')
                
                if [[ -n "$ping_result" ]]; then
                    echo -e "ping${ping_result}ms ✅"
                    
                    # 计算分数 (简化版)
                    local score=100
                    if (( dns_time_ms > 100 )); then score=$((score - 10)); fi
                    if (( dns_time_ms > 200 )); then score=$((score - 10)); fi
                    local ping_int=${ping_result%.*}
                    if (( ping_int > 50 )); then score=$((score - 10)); fi
                    if (( ping_int > 100 )); then score=$((score - 10)); fi
                    
                    total_score=$((total_score + score))
                    ((test_count++))
                else
                    echo -e "ping失败 ❌"
                fi
            else
                echo -e "解析失败 ❌"
            fi
        done
        
        # 计算平均分数
        if [[ $test_count -gt 0 ]]; then
            local avg_score=$((total_score / test_count))
            analysis_results+=("$avg_score|$dns_name|$dns_server|$test_count")
        else
            analysis_results+=("0|$dns_name|$dns_server|0")
        fi
        
        echo ""
    done
    
    # 显示分析结果
    echo ""
    echo -e "${CYAN}📊 DNS综合分析结果 (100分制)${NC}"
    echo "─────────────────────────────────────────────────────────────────────────"
    printf "%-4s %-15s %-20s %-8s %-6s %-6s\n" "排名" "DNS服务器" "IP地址" "总分" "成功" "评级"
    echo "─────────────────────────────────────────────────────────────────────────"
    
    # 排序并显示结果
    IFS=$'\n' sorted_analysis=($(printf '%s\n' "${analysis_results[@]}" | sort -t'|' -k1 -nr))
    
    local rank=1
    for result in "${sorted_analysis[@]}"; do
        IFS='|' read -r score dns_name server success <<< "$result"
        
        local rating=""
        if [[ $score -ge 90 ]]; then
            rating="${GREEN}S级${NC}"
        elif [[ $score -ge 80 ]]; then
            rating="${GREEN}A级${NC}"
        elif [[ $score -ge 70 ]]; then
            rating="${YELLOW}B级${NC}"
        elif [[ $score -ge 60 ]]; then
            rating="${PURPLE}C级${NC}"
        elif [[ $score -gt 0 ]]; then
            rating="${RED}D级${NC}"
        else
            rating="${RED}失败${NC}"
        fi
        
        # 使用对齐函数，但需要组合总分和成功率
        local score_success="${score}分 ${success}/3"
        print_aligned_row "$rank" "$dns_name" "$server" "$score_success" "$rating"
        ((rank++))
    done
    
    echo ""
    echo -e "${YELLOW}📥 第4步: 下载速度测试${NC}"
    echo ""
    # 执行下载测试
    for test_name in "${!DOWNLOAD_TEST_URLS[@]}"; do
        test_url="${DOWNLOAD_TEST_URLS[$test_name]}"
        test_download_speed "$test_name" "$test_url"
    done
    
    local end_time=$(date +%s 2>/dev/null || echo 0)
    local total_time=$((end_time - start_time))
    
    # 确保时间是有效的
    if [[ $total_time -lt 0 ]] || [[ $total_time -gt 10000 ]]; then
        total_time=0
    fi
    
    # 显示综合结果
    show_comprehensive_results "$total_time"
}

# 显示测试结果
show_results() {
    local total_time=$1
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}📊 测试完成！${NC} 总时间: ${YELLOW}${total_time}秒${NC}"
    echo ""
    
    # 生成表格
    echo -e "${CYAN}📋 延迟测试结果表格:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────────────────────────────────────${NC}"
    printf "%-3s %-12s %-25s %-12s %-8s %-15s %-15s %-8s\n" "排名" "服务" "域名" "延迟" "状态" "IPv4地址" "IPv6地址" "版本"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────────────────────────────────────${NC}"
    
    # 排序结果
    declare -a sorted_results=()
    declare -a failed_results=()
    
    for result in "${RESULTS[@]}"; do
        if [[ "$result" == *"超时"* || "$result" == *"失败"* ]]; then
            failed_results+=("$result")
        else
            sorted_results+=("$result")
        fi
    done
    
    # 按延迟排序成功的结果
    IFS=$'\n' sorted_results=($(printf '%s\n' "${sorted_results[@]}" | sort -t'|' -k3 -n))
    
    # 显示成功的结果
    local rank=1
    for result in "${sorted_results[@]}"; do
        IFS='|' read -r service host latency status ipv4_addr ipv6_addr packet_loss version <<< "$result"
        
        local status_colored=""
        case "$status" in
            "优秀") status_colored="${GREEN}🟢 $status${NC}" ;;
            "良好") status_colored="${YELLOW}🟡 $status${NC}" ;;
            "较差") status_colored="${RED}🔴 $status${NC}" ;;
            "很差") status_colored="${RED}💀 $status${NC}" ;;
            *) status_colored="$status" ;;
        esac
        
        # 截断过长的IP地址显示
        local ipv4_display="$ipv4_addr"
        local ipv6_display="$ipv6_addr"
        if [ ${#ipv4_addr} -gt 15 ]; then
            ipv4_display="${ipv4_addr:0:12}..."
        fi
        if [ ${#ipv6_addr} -gt 15 ]; then
            ipv6_display="${ipv6_addr:0:12}..."
        fi
        
        echo -e "$(printf "%2d. %-10s %-25s %-12s %-15s %-15s %-15s %s" "$rank" "$service" "$host" "$latency" "$status_colored" "$ipv4_display" "$ipv6_display" "${version:-IPv4}")"
        ((rank++))
    done
    
    # 显示失败的结果
    for result in "${failed_results[@]}"; do
        IFS='|' read -r service host latency status ipv4_addr ipv6_addr packet_loss version <<< "$result"
        echo -e "$(printf "%2d. %-10s %-25s %-12s" "$rank" "$service" "$host" "$latency") ${RED}❌ $status${NC} $(printf "%-15s %-15s %-8s %s" "${ipv4_addr:-N/A}" "${ipv6_addr:-N/A}" "${packet_loss:-N/A}" "${version:-IPv4}")"
        ((rank++))
    done
    
    # 统计信息
    local excellent_count=$(printf '%s\n' "${RESULTS[@]}" | grep -c "优秀" || true)
    local good_count=$(printf '%s\n' "${RESULTS[@]}" | grep -c "良好" || true)
    local poor_count=$(printf '%s\n' "${RESULTS[@]}" | grep -c "较差" || true)
    local very_poor_count=$(printf '%s\n' "${RESULTS[@]}" | grep -c "很差" || true)
    local failed_count=$(printf '%s\n' "${RESULTS[@]}" | grep -c "失败" || true)
    
    echo ""
    echo -e "${CYAN}📈 统计摘要:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────${NC}"
    echo -e "🟢 优秀 (< 50ms):     ${GREEN}$excellent_count${NC} 个服务"
    echo -e "🟡 良好 (50-150ms):   ${YELLOW}$good_count${NC} 个服务"
    echo -e "🔴 较差 (150-500ms):  ${RED}$poor_count${NC} 个服务"
    echo -e "💀 很差 (> 500ms):    ${RED}$very_poor_count${NC} 个服务"
    echo -e "❌ 失败:             ${RED}$failed_count${NC} 个服务"
    
    # 网络质量评估
    local total_tested=$((excellent_count + good_count + poor_count + very_poor_count + failed_count))
    if [ $total_tested -gt 0 ]; then
        local success_rate=$(((excellent_count + good_count + poor_count + very_poor_count) * 100 / total_tested))
        echo ""
        if [ $success_rate -gt 80 ] && [ $excellent_count -gt $good_count ]; then
            echo -e "🌟 ${GREEN}网络状况: 优秀${NC} (成功率: ${success_rate}%)"
        elif [ $success_rate -gt 60 ]; then
            echo -e "👍 ${YELLOW}网络状况: 良好${NC} (成功率: ${success_rate}%)"
        else
            echo -e "⚠️  ${RED}网络状况: 一般${NC} (成功率: ${success_rate}%)"
        fi
    fi
    
    # 保存结果
    local output_file="latency_results_$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "# 网络延迟测试结果 - $(date)"
        echo "# 服务|域名|延迟|状态|IPv4地址|IPv6地址|丢包率"
        printf '%s\n' "${RESULTS[@]}"
    } > "$output_file"
    
    echo ""
    echo -e "💾 结果已保存到: ${GREEN}$output_file${NC}"
    echo ""
    echo -e "${CYAN}💡 延迟等级说明:${NC}"
    echo -e "  ${GREEN}🟢 优秀${NC} (< 50ms)     - 适合游戏、视频通话"
    echo -e "  ${YELLOW}🟡 良好${NC} (50-150ms)   - 适合网页浏览、视频"
    echo -e "  ${RED}🔴 较差${NC} (150-500ms)  - 基础使用，可能影响体验"
    echo -e "  ${RED}💀 很差${NC} (> 500ms)    - 网络质量很差"
    
    echo ""
    if [[ -t 0 ]]; then
        echo -n -e "${YELLOW}按 Enter 键返回主菜单...${NC}"
        read -r
    else
        echo -e "${YELLOW}测试完成！${NC}"
        exit 0
    fi
}

# 显示DNS测试结果
show_dns_results() {
    local total_time=$1
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}🔍 DNS测试完成！${NC} 总时间: ${YELLOW}${total_time}秒${NC}"
    echo ""
    
    # 生成DNS结果表格
    echo -e "${CYAN}📋 DNS解析速度结果:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────${NC}"
    printf "%-3s %-15s %-20s %-12s %-8s\n" "排名" "DNS服务商" "DNS服务器" "解析时间" "状态"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────${NC}"
    
    # 排序DNS结果
    declare -a sorted_dns_results=()
    declare -a failed_dns_results=()
    
    for result in "${DNS_RESULTS[@]}"; do
        if [[ "$result" == *"失败"* ]]; then
            failed_dns_results+=("$result")
        else
            sorted_dns_results+=("$result")
        fi
    done
    
    # 按解析时间排序成功的结果
    IFS=$'\n' sorted_dns_results=($(printf '%s\n' "${sorted_dns_results[@]}" | sort -t'|' -k3 -n))
    
    # 显示成功的DNS结果
    local rank=1
    local best_dns=""
    for result in "${sorted_dns_results[@]}"; do
        IFS='|' read -r dns_name dns_server resolution_time status <<< "$result"
        
        if [ $rank -eq 1 ]; then
            best_dns="$dns_name"
        fi
        
        local status_colored=""
        if [[ "$status" == *"成功"* ]]; then
            status_colored="${GREEN}✅ $status${NC}"
        else
            status_colored="${RED}❌ $status${NC}"
        fi
        echo -e "$(printf "%2d. %-13s %-20s %-12s %s" "$rank" "$dns_name" "$dns_server" "$resolution_time" "$status_colored")"
        ((rank++))
    done
    
    # 显示失败的DNS结果
    for result in "${failed_dns_results[@]}"; do
        IFS='|' read -r dns_name dns_server resolution_time status <<< "$result"
        echo -e "$(printf "%2d. %-13s %-20s %-12s" "$rank" "$dns_name" "$dns_server" "$resolution_time") ${RED}❌ $status${NC}"
        ((rank++))
    done
    
    # DNS建议
    echo ""
    echo -e "${CYAN}💡 DNS优化建议:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────${NC}"
    if [ -n "$best_dns" ]; then
        echo -e "🏆 ${GREEN}推荐使用: $best_dns${NC} (解析速度最快)"
    fi
    
    echo -e "📊 各DNS服务商特点:"
    echo -e "  ${CYAN}Google DNS (8.8.8.8)${NC}     - 全球覆盖，稳定可靠"
    echo -e "  ${CYAN}Cloudflare DNS (1.1.1.1)${NC} - 注重隐私，速度快"
    echo -e "  ${CYAN}Quad9 DNS (9.9.9.10)${NC}     - 安全过滤，阻止恶意网站"
    echo -e "  ${CYAN}OpenDNS${NC}                 - 企业级功能，内容过滤"
    
    # 保存DNS结果
    local dns_output_file="dns_results_$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "# DNS解析速度测试结果 - $(date)"
        echo "# DNS服务商|DNS服务器|解析时间|状态"
        printf '%s\n' "${DNS_RESULTS[@]}"
    } > "$dns_output_file"
    
    echo ""
    echo -e "💾 DNS测试结果已保存到: ${GREEN}$dns_output_file${NC}"
    echo ""
    if [[ -t 0 ]]; then
        echo -n -e "${YELLOW}按 Enter 键返回主菜单...${NC}"
        read -r
    else
        echo -e "${YELLOW}DNS测试完成！${NC}"
        exit 0
    fi
}

# 显示综合测试结果
show_comprehensive_results() {
    local total_time=$1
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}📊 综合测试完成！${NC} 总时间: ${YELLOW}${total_time}秒${NC}"
    echo ""
    
    # 显示延迟测试结果摘要
    echo -e "${CYAN}🚀 网站延迟测试摘要:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────${NC}"
    local excellent_count=$(printf '%s\n' "${RESULTS[@]}" | grep -c "优秀" || true)
    local good_count=$(printf '%s\n' "${RESULTS[@]}" | grep -c "良好" || true)
    local poor_count=$(printf '%s\n' "${RESULTS[@]}" | grep -c "较差" || true)
    echo -e "🟢 优秀: ${excellent_count}个  🟡 良好: ${good_count}个  🔴 较差: ${poor_count}个"
    
    # 显示DNS测试结果摘要
    echo ""
    echo -e "${CYAN}🔍 DNS解析测试摘要:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────${NC}"
    if [ ${#DNS_RESULTS[@]} -gt 0 ]; then
        # 找出最快的DNS
        local fastest_dns=""
        local fastest_time=9999
        for result in "${DNS_RESULTS[@]}"; do
            if [[ "$result" != *"失败"* ]]; then
                IFS='|' read -r dns_name dns_server resolution_time status <<< "$result"
                local time_val=$(echo "$resolution_time" | sed 's/ms//')
                if [ "$time_val" -lt "$fastest_time" ]; then
                    fastest_time="$time_val"
                    fastest_dns="$dns_name"
                fi
            fi
        done
        
        if [ -n "$fastest_dns" ]; then
            echo -e "🏆 最快DNS: ${GREEN}${fastest_dns}${NC} (${fastest_time}ms)"
        fi
    fi
    
    # 显示下载速度测试摘要
    echo ""
    echo -e "${CYAN}📥 下载速度测试摘要:${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────${NC}"
    if [ ${#DOWNLOAD_RESULTS[@]} -gt 0 ]; then
        for result in "${DOWNLOAD_RESULTS[@]}"; do
            IFS='|' read -r test_name test_url speed status <<< "$result"
            case "$status" in
                "成功") echo -e "✅ ${test_name}: ${GREEN}${speed}${NC}" ;;
                "慢速") echo -e "🐌 ${test_name}: ${YELLOW}${speed}${NC}" ;;
                "失败") echo -e "❌ ${test_name}: ${RED}测试失败${NC}" ;;
            esac
        done
    fi
    
    # 保存综合结果
    local comprehensive_output_file="comprehensive_results_$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "# 综合网络测试结果 - $(date)"
        echo ""
        echo "## 网站延迟测试结果"
        echo "# 服务|域名|延迟|状态|IPv4地址|IPv6地址|丢包率"
        printf '%s\n' "${RESULTS[@]}"
        echo ""
        echo "## DNS解析速度测试结果"
        echo "# DNS服务商|DNS服务器|解析时间|状态"
        printf '%s\n' "${DNS_RESULTS[@]}"
        echo ""
        echo "## 下载速度测试结果"
        echo "# 测试点|URL|速度|状态"
        printf '%s\n' "${DOWNLOAD_RESULTS[@]}"
    } > "$comprehensive_output_file"
    
    echo ""
    echo -e "💾 综合测试结果已保存到: ${GREEN}$comprehensive_output_file${NC}"
    echo ""
    echo -e "${CYAN}💡 网络优化建议:${NC}"
    echo -e "  1. 延迟优化: 选择延迟最低的服务器"
    echo -e "  2. DNS优化: 使用解析最快的DNS服务器"
    echo -e "  3. 下载优化: 选择下载速度最快的CDN节点"
    
    echo ""
    if [[ -t 0 ]]; then
        echo -n -e "${YELLOW}按 Enter 键返回主菜单...${NC}"
        read -r
    else
        echo -e "${YELLOW}综合测试完成！${NC}"
        exit 0
    fi
}

# 检查并安装依赖（跨平台兼容）
check_dependencies() {
    echo -e "${CYAN}🔧 检查系统依赖...${NC}"
    echo -e "系统类型: ${YELLOW}$OS_TYPE${NC} | Bash版本: ${YELLOW}${BASH_VERSION%%.*}${NC}"
    
    local missing_deps=()
    local install_cmd=""
    
    # 检测系统类型和包管理器
    if command -v apt-get >/dev/null 2>&1; then
        install_cmd="apt-get"
    elif command -v yum >/dev/null 2>&1; then
        install_cmd="yum"
    elif command -v dnf >/dev/null 2>&1; then
        install_cmd="dnf"
    elif command -v apk >/dev/null 2>&1; then
        install_cmd="apk"
    elif command -v brew >/dev/null 2>&1; then
        install_cmd="brew"
    elif command -v pacman >/dev/null 2>&1; then
        install_cmd="pacman"
    fi
    
    # 检查必要的依赖
    if ! command -v ping >/dev/null 2>&1; then
        missing_deps+=("ping")
    fi
    
    if ! command -v curl >/dev/null 2>&1; then
        missing_deps+=("curl")
    fi
    
    if ! command -v bc >/dev/null 2>&1; then
        missing_deps+=("bc")
    fi
    
    # nslookup通常是内置的，但检查一下
    if ! command -v nslookup >/dev/null 2>&1; then
        missing_deps+=("nslookup")
    fi
    
    # timeout命令检查（某些系统可能没有）
    if ! command -v timeout >/dev/null 2>&1; then
        if [[ "$OS_TYPE" == "macos" ]]; then
            echo -e "${YELLOW}💡 macOS建议安装coreutils以获得timeout命令: brew install coreutils${NC}"
        fi
    fi
    
    # fping是可选的，但强烈推荐
    if ! command -v fping >/dev/null 2>&1; then
        echo -e "${YELLOW}💡 建议安装 fping 以获得更好的性能${NC}"
        missing_deps+=("fping")
    fi
    
    # 如果有缺失的依赖，尝试自动安装
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${YELLOW}⚠️  发现缺失依赖: ${missing_deps[*]}${NC}"
        
        if [ -n "$install_cmd" ] && [ "$(id -u)" = "0" ]; then
            echo -e "${CYAN}🚀 正在自动安装依赖...${NC}"
            
            case $install_cmd in
                "apt-get")
                    apt-get update -qq >/dev/null 2>&1
                    if echo "${missing_deps[*]}" | grep -q "ping"; then
                        apt-get install -y iputils-ping >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "curl"; then
                        apt-get install -y curl >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "bc"; then
                        apt-get install -y bc >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "nslookup"; then
                        apt-get install -y dnsutils >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "fping"; then
                        apt-get install -y fping >/dev/null 2>&1
                    fi
                    ;;
                "yum"|"dnf")
                    if echo "${missing_deps[*]}" | grep -q "ping"; then
                        $install_cmd install -y iputils >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "curl"; then
                        $install_cmd install -y curl >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "bc"; then
                        $install_cmd install -y bc >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "nslookup"; then
                        $install_cmd install -y bind-utils >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "fping"; then
                        $install_cmd install -y fping >/dev/null 2>&1
                    fi
                    ;;
                "apk")
                    apk update >/dev/null 2>&1
                    if echo "${missing_deps[*]}" | grep -q "ping"; then
                        apk add iputils >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "curl"; then
                        apk add curl >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "bc"; then
                        apk add bc >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "nslookup"; then
                        apk add bind-tools >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "fping"; then
                        apk add fping >/dev/null 2>&1
                    fi
                    ;;
                "brew")
                    if echo "${missing_deps[*]}" | grep -q "curl"; then
                        brew install curl >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "bc"; then
                        brew install bc >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "fping"; then
                        brew install fping >/dev/null 2>&1
                    fi
                    # macOS通常已有ping和nslookup
                    ;;
                "pacman")
                    if echo "${missing_deps[*]}" | grep -q "ping"; then
                        pacman -S --noconfirm iputils >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "curl"; then
                        pacman -S --noconfirm curl >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "bc"; then
                        pacman -S --noconfirm bc >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "nslookup"; then
                        pacman -S --noconfirm bind-tools >/dev/null 2>&1
                    fi
                    if echo "${missing_deps[*]}" | grep -q "fping"; then
                        pacman -S --noconfirm fping >/dev/null 2>&1
                    fi
                    ;;
            esac
            
            # 再次检查安装结果
            local still_missing=()
            for dep in "${missing_deps[@]}"; do
                case $dep in
                    "ping")
                        if ! command -v ping >/dev/null 2>&1; then
                            still_missing+=("ping")
                        fi
                        ;;
                    "curl")
                        if ! command -v curl >/dev/null 2>&1; then
                            still_missing+=("curl")
                        fi
                        ;;
                    "bc")
                        if ! command -v bc >/dev/null 2>&1; then
                            still_missing+=("bc")
                        fi
                        ;;
                    "nslookup")
                        if ! command -v nslookup >/dev/null 2>&1; then
                            still_missing+=("nslookup")
                        fi
                        ;;
                    "fping")
                        if ! command -v fping >/dev/null 2>&1; then
                            still_missing+=("fping")
                        fi
                        ;;
                esac
            done
            
            if [ ${#still_missing[@]} -eq 0 ]; then
                echo -e "${GREEN}✅ 所有依赖安装成功！${NC}"
            else
                echo -e "${RED}❌ 部分依赖安装失败: ${still_missing[*]}${NC}"
                show_manual_install_instructions
                exit 1
            fi
            
        else
            echo -e "${RED}❌ 无法自动安装依赖${NC}"
            if [ "$(id -u)" != "0" ]; then
                echo -e "${YELLOW}💡 提示: 请使用 root 权限运行脚本以自动安装依赖${NC}"
            fi
            show_manual_install_instructions
            exit 1
        fi
    else
        echo -e "${GREEN}✅ 所有依赖已安装${NC}"
    fi
    
    echo ""
}

# 显示手动安装说明
show_manual_install_instructions() {
    echo ""
    echo -e "${CYAN}📝 手动安装说明:${NC}"
    echo ""
    echo "🐧 Ubuntu/Debian:"
    echo "   sudo apt update && sudo apt install curl iputils-ping bc dnsutils fping"
    echo ""
    echo "🎩 CentOS/RHEL/Fedora:"
    echo "   sudo yum install curl iputils bc bind-utils fping"
    echo "   # 或者: sudo dnf install curl iputils bc bind-utils fping"
    echo ""
    echo "🏔️  Alpine Linux:"
    echo "   sudo apk update && sudo apk add curl iputils bc bind-tools fping"
    echo ""
    echo "🍎 macOS:"
    echo "   brew install curl bc fping"
    echo "   # ping 和 nslookup 通常已预装"
    echo ""
}

# 主循环
main() {
    # 检查依赖
    check_dependencies
    
    while true; do
        show_welcome
        show_menu
        
        # 读取用户输入，确保等待输入
        echo -n -e "${YELLOW}请选择 (0-5): ${NC}"
        read -r choice
        
        # 处理空输入
        if [ -z "$choice" ]; then
            continue
        fi
        
        case $choice in
            1)
                run_test
                ;;
            2)
                run_dns_test
                ;;
            3)
                run_comprehensive_test
                ;;
            4)
                run_ip_version_test
                ;;
            5)
                run_dns_management
                ;;
            0)
                echo ""
                echo -e "${GREEN}👋 感谢使用网络延迟检测工具！${NC}"
                echo -e "${CYAN}🌟 项目地址: https://github.com/Cd1s/network-latency-tester${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}❌ 无效选择，请输入 0-5${NC}"
                if [[ -t 0 ]]; then
                    echo -n -e "${YELLOW}按 Enter 键继续...${NC}"
                    read -r
                else
                    echo -e "${YELLOW}程序结束${NC}"
                    exit 1
                fi
                ;;
        esac
    done
}

# DNS设置管理功能
run_dns_management() {
    clear
    show_welcome
    
    echo -e "${CYAN}⚙️ DNS设置管理${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}说明: 选择用于解析测试网站IP地址的DNS服务器，不会更改系统DNS设置${NC}"
    echo ""
    echo -e "${YELLOW}选择用于IP解析的DNS服务器:${NC}"
    
    local count=1
    declare -a dns_list=()
    
    # 系统默认选项
    echo -e "  ${GREEN}$count${NC} - 系统默认 (使用系统DNS设置)"
    dns_list+=("system|系统默认")
    ((count++))
    
    # 列出所有DNS服务器
    for dns_name in "${!DNS_SERVERS[@]}"; do
        local dns_server="${DNS_SERVERS[$dns_name]}"
        if [[ "$dns_server" != "system" ]]; then
            echo -e "  ${GREEN}$count${NC} - $dns_name ($dns_server)"
            dns_list+=("$dns_server|$dns_name")
            ((count++))
        fi
    done
    
    echo -e "  ${RED}0${NC} - 返回主菜单"
    echo ""
    
    # 显示当前设置
    if [[ -z "$SELECTED_DNS_SERVER" || "$SELECTED_DNS_SERVER" == "system" ]]; then
        echo -e "${CYAN}当前设置: 系统默认${NC}"
    else
        echo -e "${CYAN}当前设置: $SELECTED_DNS_NAME ($SELECTED_DNS_SERVER)${NC}"
    fi
    echo ""
    
    echo -n -e "${YELLOW}请选择 (0-$((count-1))): ${NC}"
    read -r dns_choice
    
    case $dns_choice in
        0)
            return
            ;;
        1)
            SELECTED_DNS_SERVER="system"
            SELECTED_DNS_NAME="系统默认"
            echo -e "${GREEN}✅ 已设置为系统默认DNS${NC}"
            echo -e "${YELLOW}现在进行网站测试时将使用系统默认DNS解析IP地址...${NC}"
            sleep 2
            ;;
        *)
            if [[ "$dns_choice" =~ ^[0-9]+$ ]] && [[ "$dns_choice" -ge 2 ]] && [[ "$dns_choice" -le $((count-1)) ]]; then
                local selected_dns="${dns_list[$((dns_choice-1))]}"
                SELECTED_DNS_SERVER=$(echo "$selected_dns" | cut -d'|' -f1)
                SELECTED_DNS_NAME=$(echo "$selected_dns" | cut -d'|' -f2)
                
                echo -e "${GREEN}✅ 已设置DNS服务器为: $SELECTED_DNS_NAME ($SELECTED_DNS_SERVER)${NC}"
                echo -e "${YELLOW}现在进行网站测试时将使用此DNS服务器解析IP地址...${NC}"
                sleep 2
            else
                echo -e "${RED}❌ 无效选择${NC}"
                sleep 2
                run_dns_management
                return
            fi
            ;;
    esac
    
    # 询问是否立即进行测试
    echo ""
    echo -e "${YELLOW}是否立即进行网站连接测试？${NC}"
    echo -e "  ${GREEN}1${NC} - 是，进行Ping/真连接测试"
    echo -e "  ${GREEN}2${NC} - 是，进行综合测试"
    echo -e "  ${RED}0${NC} - 否，返回主菜单"
    echo ""
    echo -n -e "${YELLOW}请选择 (0-2): ${NC}"
    read -r test_choice
    
    case $test_choice in
        1)
            run_test
            ;;
        2)
            run_comprehensive_test
            ;;
        0|*)
            return
            ;;
    esac
}

# 使用指定DNS服务器解析域名并返回IP
resolve_with_dns() {
    local domain=$1
    local dns_server=$2
    local ip=""
    
    if [[ "$dns_server" == "system" ]]; then
        # 使用系统默认DNS
        if command -v dig >/dev/null 2>&1; then
            ip=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        fi
        
        if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
            ip=$(nslookup "$domain" 2>/dev/null | grep -A 1 "Name:" | grep "Address:" | head -n1 | awk '{print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        fi
    else
        # 使用指定DNS服务器
        if command -v dig >/dev/null 2>&1; then
            ip=$(dig +short @"$dns_server" "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        fi
        
        if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
            ip=$(nslookup "$domain" "$dns_server" 2>/dev/null | grep -A 1 "Name:" | grep "Address:" | head -n1 | awk '{print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        fi
    fi
    
    echo "$ip"
}

# 测试IP的ping延迟
test_ip_latency() {
    local ip=$1
    local count=${2:-5}
    
    if [[ -z "$ip" || "$ip" == "N/A" ]]; then
        echo "999999"
        return
    fi
    
    local total_time=0
    local successful_pings=0
    local ping_cmd=$(get_ping_cmd "4" "$ip")
    local interval=$(get_ping_interval)
    local timeout_cmd=$(get_timeout_cmd)
    
    for ((i=1; i<=count; i++)); do
        local ping_result=""
        if [[ -n "$timeout_cmd" ]]; then
            if [[ -n "$interval" ]]; then
                ping_result=$($timeout_cmd 5 $ping_cmd -c 1 $interval "$ip" 2>/dev/null || true)
            else
                ping_result=$($timeout_cmd 5 $ping_cmd -c 1 "$ip" 2>/dev/null || true)
            fi
        else
            if [[ -n "$interval" ]]; then
                ping_result=$($ping_cmd -c 1 $interval "$ip" 2>/dev/null || true)
            else
                ping_result=$($ping_cmd -c 1 "$ip" 2>/dev/null || true)
            fi
        fi
        
        if [[ -n "$ping_result" ]]; then
            local ping_ms=""
            if [[ "$OS_TYPE" == "macos" ]]; then
                ping_ms=$(echo "$ping_result" | grep 'round-trip' | cut -d'=' -f2 | cut -d'/' -f2 2>/dev/null || echo "")
            else
                ping_ms=$(echo "$ping_result" | grep 'time=' | sed 's/.*time=\([0-9.]*\).*/\1/' 2>/dev/null || echo "")
            fi
            
            if [[ "$ping_ms" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                total_time=$(echo "$total_time + $ping_ms" | bc -l 2>/dev/null || echo "$total_time")
                ((successful_pings++))
            fi
        fi
    done
    
    if [ $successful_pings -gt 0 ]; then
        echo "scale=1; $total_time / $successful_pings" | bc -l 2>/dev/null || echo "999999"
    else
        echo "999999"
    fi
}

# DNS综合分析功能
run_dns_comprehensive_analysis() {
    clear
    show_welcome
    
    echo -e "${CYAN}🧪 DNS综合分析 - 测试各DNS解析IP的实际延迟${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}📋 测试说明：${NC}"
    echo -e "   • 使用每个DNS服务器解析测试域名获得IP地址"
    echo -e "   • 测试解析出的IP地址的实际ping延迟"
    echo -e "   • 综合考虑DNS解析速度和ping延迟给出最佳建议"
    echo ""
    
    # 选择测试域名
    local test_domains=("google.com" "github.com" "apple.com")
    echo -e "${CYAN}🎯 测试域名: ${test_domains[*]}${NC}"
    echo ""
    
    # 存储所有结果的数组
    declare -a analysis_results=()
    
    # 测试每个DNS服务器
    local dns_count=0
    local total_dns=${#DNS_SERVERS[@]}
    
    for dns_name in "${!DNS_SERVERS[@]}"; do
        local dns_server="${DNS_SERVERS[$dns_name]}"
        ((dns_count++))
        
        echo -e "${BLUE}[$dns_count/$total_dns]${NC} 测试 ${CYAN}$dns_name${NC} (${dns_server})..."
        
        local total_resolution_time=0
        local total_ping_time=0
        local successful_resolutions=0
        local successful_pings=0
        
        # 测试每个域名
        for domain in "${test_domains[@]}"; do
            echo -n "  └─ $domain: "
            
            # 测试DNS解析速度
            local start_time=$(date +%s%N)
            local resolved_ip=$(resolve_with_dns "$domain" "$dns_server")
            local end_time=$(date +%s%N)
            local resolution_time=$(( (end_time - start_time) / 1000000 ))
            
            if [[ -n "$resolved_ip" && "$resolved_ip" != "N/A" ]]; then
                total_resolution_time=$((total_resolution_time + resolution_time))
                ((successful_resolutions++))
                
                echo -n "${resolved_ip} (解析${resolution_time}ms) "
                
                # 测试IP延迟
                local ping_latency=$(test_ip_latency "$resolved_ip" 3)
                if [[ "$ping_latency" != "999999" ]] && [[ "$ping_latency" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    total_ping_time=$(echo "$total_ping_time + $ping_latency" | bc -l 2>/dev/null || echo "$total_ping_time")
                    ((successful_pings++))
                    echo -e "${GREEN}ping${ping_latency}ms ✅${NC}"
                else
                    echo -e "${RED}ping失败 ❌${NC}"
                fi
            else
                echo -e "${RED}解析失败 ❌${NC}"
            fi
        done
        
        # 计算平均值
        local avg_resolution_time=0
        local avg_ping_time=0
        
        if [ $successful_resolutions -gt 0 ]; then
            avg_resolution_time=$((total_resolution_time / successful_resolutions))
        else
            avg_resolution_time=9999
        fi
        
        if [ $successful_pings -gt 0 ]; then
            avg_ping_time=$(echo "scale=1; $total_ping_time / $successful_pings" | bc -l 2>/dev/null || echo "9999")
        else
            avg_ping_time=9999
        fi
        
        # 计算综合得分 (100分制，分数越高越好)
        # 使用更严谨的评分算法，避免太多100分
        local composite_score=0
        if [[ "$avg_ping_time" != "9999" ]] && [[ "$avg_resolution_time" != "9999" ]]; then
            # 将浮点数转为整数（去掉小数部分）
            local ping_time_int=${avg_ping_time%.*}
            local resolution_time_int=${avg_resolution_time%.*}
            
            # 确保是有效数字
            if [[ ! "$ping_time_int" =~ ^[0-9]+$ ]]; then ping_time_int=999; fi
            if [[ ! "$resolution_time_int" =~ ^[0-9]+$ ]]; then resolution_time_int=999; fi
            
            # Ping延迟评分 (0-70分)
            local ping_score=0
            if (( ping_time_int <= 20 )); then
                ping_score=70
            elif (( ping_time_int <= 40 )); then
                ping_score=$((70 - (ping_time_int - 20) / 2))
            elif (( ping_time_int <= 60 )); then
                ping_score=$((60 - (ping_time_int - 40) / 2))
            elif (( ping_time_int <= 100 )); then
                ping_score=$((50 - (ping_time_int - 60) / 2))
            elif (( ping_time_int <= 150 )); then
                ping_score=$((30 - (ping_time_int - 100) / 3))
            elif (( ping_time_int <= 200 )); then
                ping_score=$((15 - (ping_time_int - 150) / 5))
            else
                ping_score=5
            fi
            
            # DNS解析评分 (0-30分)
            local dns_score=0
            if (( resolution_time_int <= 30 )); then
                dns_score=30
            elif (( resolution_time_int <= 50 )); then
                dns_score=$((30 - (resolution_time_int - 30) / 4))
            elif (( resolution_time_int <= 80 )); then
                dns_score=$((25 - (resolution_time_int - 50) / 6))
            elif (( resolution_time_int <= 120 )); then
                dns_score=$((20 - (resolution_time_int - 80) / 8))
            elif (( resolution_time_int <= 200 )); then
                dns_score=$((15 - (resolution_time_int - 120) / 16))
            else
                dns_score=5
            fi
            
            # 确保分数不为负数
            if [[ $ping_score -lt 0 ]]; then ping_score=0; fi
            if [[ $dns_score -lt 0 ]]; then dns_score=0; fi
            
            composite_score=$((ping_score + dns_score))
        fi
        
        # 存储结果 (按分数降序排序，所以用负数)
        analysis_results+=("$((100-composite_score))|$dns_name|$dns_server|$avg_resolution_time|$avg_ping_time|$successful_resolutions|$successful_pings|$composite_score")
        
        echo ""
    done
    
    echo ""
    echo -e "${CYAN}📊 DNS综合分析结果${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    # 按综合得分排序 (分数越高越好)
    IFS=$'\n' sorted_results=($(printf '%s\n' "${analysis_results[@]}" | sort -t'|' -k1 -n))
    
    local rank=1
    local best_dns=""
    local best_score=""
    
    # 创建临时文件用于column对齐
    local temp_table="/tmp/dns_table_$$"
    
    # 写入表头
    echo "DNS服务器|IP地址|解析速度|Ping延迟|综合得分|状态" > "$temp_table"
    
    for result in "${sorted_results[@]}"; do
        IFS='|' read -r sort_key dns_name dns_server avg_resolution_time avg_ping_time successful_resolutions successful_pings composite_score <<< "$result"
        
        # 处理长IP地址显示
        local display_server="$dns_server"
        if [[ ${#dns_server} -gt 18 ]]; then
            display_server="${dns_server:0:15}..."
        fi
        
        # 确定状态和颜色
        local status=""
        if [[ "$composite_score" == "0" ]]; then
            status="失败"
            composite_score="0"
            avg_resolution_time="${avg_resolution_time}ms"
            avg_ping_time="失败"
        else
            avg_resolution_time="${avg_resolution_time}ms"
            avg_ping_time="${avg_ping_time}ms"
            
            if [[ $composite_score -ge 95 ]]; then
                status="优秀"
            elif [[ $composite_score -ge 85 ]]; then
                status="良好"
            elif [[ $composite_score -ge 70 ]]; then
                status="一般"
            else
                status="较差"
            fi
        fi
        
        # 保存最佳DNS信息
        if [[ $rank -eq 1 && "$status" != "失败" ]]; then
            best_dns="$dns_name"
            best_score="$composite_score"
        fi
        
        # 写入数据行
        echo "$dns_name|$display_server|$avg_resolution_time|$avg_ping_time|$composite_score|$status" >> "$temp_table"
        ((rank++))
    done
    
    # 使用printf对齐并着色显示
    while IFS='|' read -r dns_name display_server avg_resolution_time avg_ping_time composite_score status; do
        if [[ "$dns_name" == "DNS服务器" ]]; then
            printf "${CYAN}%-15s %-20s %-12s %-12s %-8s %-8s${NC}\n" "$dns_name" "$display_server" "$avg_resolution_time" "$avg_ping_time" "$composite_score" "$status"
        elif echo "$status" | grep -q "优秀"; then
            printf "${GREEN}%-15s %-20s %-12s %-12s %-8s %-8s${NC}\n" "$dns_name" "$display_server" "$avg_resolution_time" "$avg_ping_time" "$composite_score" "$status"
        elif echo "$status" | grep -q "良好"; then
            printf "${YELLOW}%-15s %-20s %-12s %-12s %-8s %-8s${NC}\n" "$dns_name" "$display_server" "$avg_resolution_time" "$avg_ping_time" "$composite_score" "$status"
        elif echo "$status" | grep -q "一般"; then
            printf "${PURPLE}%-15s %-20s %-12s %-12s %-8s %-8s${NC}\n" "$dns_name" "$display_server" "$avg_resolution_time" "$avg_ping_time" "$composite_score" "$status"
        elif echo "$status" | grep -q "较差\|失败"; then
            printf "${RED}%-15s %-20s %-12s %-12s %-8s %-8s${NC}\n" "$dns_name" "$display_server" "$avg_resolution_time" "$avg_ping_time" "$composite_score" "$status"
        else
            printf "%-15s %-20s %-12s %-12s %-8s %-8s\n" "$dns_name" "$display_server" "$avg_resolution_time" "$avg_ping_time" "$composite_score" "$status"
        fi
    done < "$temp_table"
    
    # 清理临时文件
    rm -f "$temp_table"
    
    echo ""
    echo -e "${CYAN}🏆 综合分析建议${NC}"
    echo -e "${BLUE}─────────────────────────────────────────────────────────────${NC}"
    
    if [[ -n "$best_dns" ]]; then
        echo -e "${GREEN}🥇 最佳推荐: ${best_dns}${NC}"
        echo -e "   • 综合得分: ${best_score}/100分"
        echo -e "   • 建议: 设置为默认DNS可获得最佳网络体验"
        echo ""
        echo -e "${YELLOW}📝 评分标准说明:${NC}"
        echo -e "   • 100分制，分数越高越好（采用严谨的指数衰减算法）"
        echo -e "   • Ping延迟评分: 70分 (≤20ms=70分, 20-40ms递减, >200ms=5分)"
        echo -e "   • DNS解析评分: 30分 (≤30ms=30分, 30-50ms递减, >200ms=5分)"
        echo -e "   • 95分以上=优秀, 85-94分=良好, 70-84分=一般, 70分以下=较差"
    else
        echo -e "${RED}❌ 所有DNS测试均失败，请检查网络连接${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}✅ DNS综合分析完成${NC}"
    echo ""
    echo "按 Enter 键返回主菜单..."
    read -r
}

# 运行主程序
main
