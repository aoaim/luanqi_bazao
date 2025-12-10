#!/bin/bash

##############################################
# WireGuard 安装和管理脚本
# 支持服务端和客户端的安装与管理
##############################################

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置变量
INSTALL_DIR="/root/wireguard-server"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yaml"
DEFAULT_PORT=51820
DEFAULT_PEERS=1
DEFAULT_DNS="8.8.8.8"
DEFAULT_SUBNET="10.13.13.0"
DEFAULT_SUBNET_V6="fd13:13:13::/64"

##############################################
# 工具函数
##############################################

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_separator() {
    echo "=============================================="
}

# 检查系统版本
check_system() {
    if [ ! -f /etc/os-release ]; then
        print_error "Unable to detect system version"
        exit 1
    fi
    
    source /etc/os-release
    
    if [[ "$ID" != "debian" ]]; then
        print_error "This script only supports Debian"
        print_info "Current system: $PRETTY_NAME"
        exit 1
    fi
    
    if [[ "$VERSION_ID" != "12" && "$VERSION_ID" != "13" ]]; then
        print_error "This script only supports Debian 12 and Debian 13"
        print_info "Current version: Debian $VERSION_ID"
        exit 1
    fi
    
    print_success "System check passed: $PRETTY_NAME"
}

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# 获取主 IPv4（用于路由保持）
get_primary_ipv4() {
    local ip_main=""
    ip_main=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1)
    if [ -z "$ip_main" ]; then
        ip_main=$(ip -4 addr show scope global | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
    fi
    echo "$ip_main"
}

# 检查 Docker 是否安装
check_docker() {
    if ! command -v docker &> /dev/null; then
        print_warning "Docker is not installed"
        read -p "Install Docker now? (y/N): " install_docker
        
        if [[ "$install_docker" =~ ^[Yy]$ ]]; then
            print_info "Updating package list..."
            apt update
            
            print_info "Installing Docker..."
            print_info "Using official install script: https://get.docker.com/"
            
            if wget -qO- https://get.docker.com/ | sh; then
                print_success "Docker installed successfully"
                
                # 启动 Docker 服务
                systemctl start docker
                systemctl enable docker
                
                # 显示 Docker 版本
                docker --version
            else
                print_error "Docker installation failed"
                exit 1
            fi
        else
            print_error "Docker is required. Please install it manually and run this script again"
            exit 1
        fi
    fi
}

# 获取 IP 所在国家代码
# 参数: $1=IP 地址
# 返回: 国家代码 (如 SG, US) 或空
get_ip_country() {
    local ip="$1"
    if [ -z "$ip" ]; then
        echo ""
        return
    fi
    
    # 使用 ip-api.com 查询国家代码
    local country
    country=$(curl -s --max-time 3 "http://ip-api.com/line/${ip}?fields=countryCode" 2>/dev/null)
    
    # 验证返回值是否为有效国家代码（2字母）
    if [[ "$country" =~ ^[A-Z]{2}$ ]]; then
        echo "$country"
    else
        echo ""
    fi
}

# 获取服务器公网 IP
get_public_ip() {
    local ipv4=""
    local ipv6=""
    
    # 尝试多个服务获取 IPv4
    ipv4=$(curl -4 -s --max-time 3 https://api.ipify.org || \
           curl -4 -s --max-time 3 https://ip.sb || \
           curl -4 -s --max-time 3 https://ifconfig.me || \
           echo "")
    
    # 尝试获取 IPv6
    ipv6=$(curl -6 -s --max-time 3 https://api6.ipify.org 2>/dev/null || \
           curl -6 -s --max-time 3 https://ip.sb 2>/dev/null || \
           curl -6 -s --max-time 3 https://ifconfig.me 2>/dev/null || \
           echo "")
    
    echo "$ipv4|$ipv6"
}

# 检测系统是否支持 IPv6
check_ipv6_support() {
    if ip -6 addr show | grep -q "inet6" && \
       curl -6 -s --max-time 5 https://ipv6.google.com > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 获取系统时区
get_timezone() {
    if [ -f /etc/timezone ]; then
        cat /etc/timezone
    elif [ -L /etc/localtime ]; then
        readlink /etc/localtime | sed 's|/usr/share/zoneinfo/||'
    else
        echo "Asia/Shanghai"
    fi
}

# 检测使用的防火墙类型
# 返回: ufw, nftables, iptables
detect_firewall_type() {
    # 优先检查 UFW 是否安装且激活
    if command -v ufw &>/dev/null; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            echo "ufw"
            return
        fi
    fi
    
    # 检查 nftables 是否可用
    if command -v nft &>/dev/null && nft list tables &>/dev/null; then
        echo "nftables"
        return
    fi
    
    # 回退到 iptables
    echo "iptables"
}

# 配置防火墙开放 WireGuard 端口
# 参数: $1=端口号, $2=是否支持IPv6 (true/false), $3=firewall_info文件路径
configure_firewall_open_port() {
    local port="$1"
    local has_ipv6="$2"
    local firewall_info_file="$3"
    
    local firewall_type
    firewall_type=$(detect_firewall_type)
    
    print_info "Detected firewall type: $firewall_type"
    echo "FIREWALL_TYPE=$firewall_type" >> "$firewall_info_file"
    
    case "$firewall_type" in
        ufw)
            # 使用 UFW 开放端口
            if ufw status | grep -q "${port}/udp"; then
                print_info "UFW rule already exists: ${port}/udp"
                echo "UFW_RULE_ADDED=false" >> "$firewall_info_file"
            else
                if ufw allow "${port}/udp" >/dev/null 2>&1; then
                    print_success "Opened UDP port $port (UFW)"
                    echo "UFW_RULE_ADDED=true" >> "$firewall_info_file"
                else
                    print_error "Failed to add UFW rule"
                    echo "UFW_RULE_ADDED=false" >> "$firewall_info_file"
                    return 1
                fi
            fi
            ;;
        nftables)
            # 使用 nftables 开放端口
            local nft_rules_file="/etc/nftables.d/wireguard.nft"
            mkdir -p /etc/nftables.d
            
            # 检查 wireguard 表是否已存在
            if nft list table inet wireguard &>/dev/null; then
                print_info "WireGuard nftables rules already exist, skipping"
                echo "NFT_RULE_ADDED=false" >> "$firewall_info_file"
            else
                # 创建 nftables 规则
                cat > "$nft_rules_file" <<NFT_EOF
#!/usr/sbin/nft -f
# WireGuard 防火墙规则

table inet wireguard {
    chain input {
        type filter hook input priority filter; policy accept;
        udp dport $port accept comment "WireGuard"
    }
}
NFT_EOF
                
                # 应用规则
                if nft -f "$nft_rules_file" 2>/dev/null; then
                    print_success "Opened UDP port $port (nftables)"
                    echo "NFT_RULE_ADDED=true" >> "$firewall_info_file"
                    
                    # 确保 nftables 服务开机自启并包含我们的规则
                    if [ -f /etc/nftables.conf ]; then
                        if ! grep -q 'include "/etc/nftables.d/\*.nft"' /etc/nftables.conf 2>/dev/null; then
                            echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
                            print_info "Added nftables include configuration"
                        fi
                    fi
                    systemctl enable nftables &>/dev/null || true
                else
                    print_warning "nftables rule failed, falling back to iptables..."
                    rm -f "$nft_rules_file"
                    echo "NFT_RULE_ADDED=false" >> "$firewall_info_file"
                    # 回退到 iptables
                    configure_firewall_iptables "$port" "$has_ipv6" "$firewall_info_file"
                fi
            fi
            ;;
        iptables)
            configure_firewall_iptables "$port" "$has_ipv6" "$firewall_info_file"
            ;;
    esac
}

# iptables 防火墙配置（作为回退方案）
configure_firewall_iptables() {
    local port="$1"
    local has_ipv6="$2"
    local firewall_info_file="$3"
    
    echo "IPTABLES_USED=true" >> "$firewall_info_file"
    
    if ! iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; then
        iptables -A INPUT -p udp --dport "$port" -j ACCEPT
        print_success "Opened UDP port $port (iptables IPv4)"
        echo "IPTABLES_V4_ADDED=true" >> "$firewall_info_file"
    else
        echo "IPTABLES_V4_ADDED=false" >> "$firewall_info_file"
    fi
    
    if [ "$has_ipv6" = "true" ]; then
        if ! ip6tables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; then
            ip6tables -A INPUT -p udp --dport "$port" -j ACCEPT
            print_success "Opened UDP port $port (iptables IPv6)"
            echo "IPTABLES_V6_ADDED=true" >> "$firewall_info_file"
        else
            echo "IPTABLES_V6_ADDED=false" >> "$firewall_info_file"
        fi
    fi
}

# 清理防火墙规则（卸载时调用）
cleanup_firewall_rules() {
    local firewall_info_file="$1"
    
    if [ ! -f "$firewall_info_file" ]; then
        print_warning "Firewall info file not found, skipping cleanup"
        return
    fi
    
    # 读取安装时记录的信息
    source "$firewall_info_file"
    local wg_port=${PORT:-51820}
    local firewall_type=${FIREWALL_TYPE:-""}
    
    case "$firewall_type" in
        ufw)
            if [ "${UFW_RULE_ADDED:-false}" = "true" ]; then
                if ufw delete allow "${wg_port}/udp" >/dev/null 2>&1; then
                    print_success "Removed UDP port $wg_port rule (UFW)"
                else
                    print_warning "Failed to remove UFW rule, may have been manually deleted"
                fi
            else
                print_info "UFW rule not added by this script, keeping"
            fi
            ;;
        nftables)
            if [ "${NFT_RULE_ADDED:-false}" = "true" ]; then
                # 删除 nftables 表
                if nft delete table inet wireguard 2>/dev/null; then
                    print_success "Removed WireGuard nftables rules"
                fi
                # 删除规则文件
                rm -f /etc/nftables.d/wireguard.nft 2>/dev/null
                
                # 如果 nftables.d 目录为空，删除目录和 include 配置
                if [ -d /etc/nftables.d ] && [ -z "$(ls -A /etc/nftables.d 2>/dev/null)" ]; then
                    rmdir /etc/nftables.d 2>/dev/null
                    # 清理 nftables.conf 中的 include 指令
                    if [ -f /etc/nftables.conf ]; then
                        sed -i '/include "\/etc\/nftables.d\/\*.nft"/d' /etc/nftables.conf 2>/dev/null
                    fi
                fi
            else
                print_info "nftables rules not added by this script, keeping"
            fi
            ;;
        iptables|"")
            # 清理 iptables 规则
            if [ "${IPTABLES_V4_ADDED:-false}" = "true" ] || [ "${IPTABLES_USED:-false}" = "true" ]; then
                if iptables -D INPUT -p udp --dport "$wg_port" -j ACCEPT 2>/dev/null; then
                    print_success "Removed UDP port $wg_port rule (iptables IPv4)"
                fi
            fi
            if [ "${IPTABLES_V6_ADDED:-false}" = "true" ]; then
                if ip6tables -D INPUT -p udp --dport "$wg_port" -j ACCEPT 2>/dev/null; then
                    print_success "Removed UDP port $wg_port rule (iptables IPv6)"
                fi
            fi
            # 兼容旧版本的 IPTABLES_FALLBACK 标记
            if [ "${IPTABLES_FALLBACK:-false}" = "true" ]; then
                iptables -D INPUT -p udp --dport "$wg_port" -j ACCEPT 2>/dev/null && \
                    print_success "Removed UDP port $wg_port rule (iptables IPv4)"
                ip6tables -D INPUT -p udp --dport "$wg_port" -j ACCEPT 2>/dev/null && \
                    print_success "Removed UDP port $wg_port rule (iptables IPv6)"
            fi
            ;;
    esac
}

# 检测 WireGuard Docker 容器（扫描所有可能的安装）
# 返回格式: container_name|container_id|image|install_path|is_standard
# 如果没有安装返回空
detect_wireguard_containers() {
    local result=""
    
    # 检查 Docker 是否可用
    if ! command -v docker &>/dev/null; then
        echo ""
        return
    fi
    
    # 扫描所有使用 wireguard 镜像的容器（包括已停止的）
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        
        local container_id=$(echo "$line" | awk '{print $1}')
        local container_name=$(echo "$line" | awk '{print $NF}')
        local image=$(echo "$line" | awk '{print $2}')
        
        # 检查镜像是否为 WireGuard 相关
        if [[ "$image" == *wireguard* ]] || [[ "$container_name" == *wireguard* ]]; then
            # 尝试获取容器的挂载路径来确定安装目录
            local install_path=""
            local mount_info
            mount_info=$(docker inspect "$container_id" --format '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
            
            if [ -n "$mount_info" ]; then
                # 从挂载路径推断安装目录（去掉 /config 后缀）
                install_path=$(dirname "$mount_info")
            fi
            
            # 判断是否为标准安装路径
            local is_standard="false"
            if [ "$install_path" = "$INSTALL_DIR" ]; then
                is_standard="true"
            fi
            
            result="${result}${container_name}|${container_id}|${image}|${install_path}|${is_standard}"$'\n'
        fi
    done < <(docker ps -a --format "{{.ID}} {{.Image}} {{.Names}}" 2>/dev/null)
    
    echo "$result"
}

# 获取非标准路径的 WireGuard 安装信息
# 返回: 非标准安装的信息列表，每行一个
get_nonstandard_wireguard_installs() {
    local containers
    containers=$(detect_wireguard_containers)
    
    local nonstandard=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local is_standard=$(echo "$line" | cut -d'|' -f5)
        if [ "$is_standard" = "false" ]; then
            nonstandard="${nonstandard}${line}"$'\n'
        fi
    done <<< "$containers"
    
    echo "$nonstandard"
}

# 清理非标准路径的 WireGuard 安装
# 仅提供卸载功能，不提供管理功能
cleanup_nonstandard_wireguard() {
    check_root
    
    local nonstandard
    nonstandard=$(get_nonstandard_wireguard_installs)
    
    if [ -z "$nonstandard" ]; then
        print_info "No non-standard WireGuard installations detected"
        return 0
    fi
    
    print_separator
    print_warning "Non-standard WireGuard Installation Detected"
    print_separator
    echo ""
    print_info "The following WireGuard installations are not managed by this script:"
    echo ""
    
    local count=0
    local containers_info=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        count=$((count + 1))
        local container_name=$(echo "$line" | cut -d'|' -f1)
        local container_id=$(echo "$line" | cut -d'|' -f2)
        local image=$(echo "$line" | cut -d'|' -f3)
        local install_path=$(echo "$line" | cut -d'|' -f4)
        
        containers_info+=("$line")
        echo "  ${count}) Container: ${container_name}"
        echo "     Image: ${image}"
        echo "     ID: ${container_id:0:12}"
        [ -n "$install_path" ] && echo "     Path: ${install_path}"
        echo ""
    done <<< "$nonstandard"
    
    print_separator
    echo ""
    print_warning "These installations can only be cleaned up (uninstalled)."
    print_info "Management features are only available for standard installations."
    echo ""
    
    read -p "Clean up all non-standard installations? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Cleanup cancelled"
        return 0
    fi
    
    # 逐个清理
    for info in "${containers_info[@]}"; do
        local container_name=$(echo "$info" | cut -d'|' -f1)
        local container_id=$(echo "$info" | cut -d'|' -f2)
        local install_path=$(echo "$info" | cut -d'|' -f4)
        
        print_info "Stopping and removing container: ${container_name}..."
        docker stop "$container_id" 2>/dev/null || true
        docker rm "$container_id" 2>/dev/null || true
        
        # 如果有安装路径，询问是否删除
        if [ -n "$install_path" ] && [ -d "$install_path" ]; then
            read -p "Delete installation directory ${install_path}? (y/N): " del_dir
            if [[ "$del_dir" =~ ^[Yy]$ ]]; then
                rm -rf "$install_path"
                print_success "Removed directory: ${install_path}"
            fi
        fi
        
        print_success "Cleaned up: ${container_name}"
    done
    
    print_separator
    print_success "Non-standard WireGuard installations cleaned up"
    
    # 询问是否清理镜像
    echo ""
    read -p "Also remove WireGuard Docker image? (y/N): " remove_image
    if [[ "$remove_image" =~ ^[Yy]$ ]]; then
        if docker images | grep -q "linuxserver/wireguard"; then
            docker rmi $(docker images linuxserver/wireguard -q) 2>/dev/null || \
                print_warning "Image removal failed, may be in use"
        fi
    fi
}

# 过滤用户粘贴的 WireGuard 配置内容
filter_wireguard_config() {
    local temp_file="$1"
    local config_file="$2"

    # 只提取 WireGuard 关键字段，忽略用户粘贴里可能出现的提示/日志
    local allowed_patterns=(
        '^[[:space:]]*\[Interface\]'
        '^[[:space:]]*\[Peer\]'
        '^[[:space:]]*Address[[:space:]]*='
        '^[[:space:]]*PrivateKey[[:space:]]*='
        '^[[:space:]]*ListenPort[[:space:]]*='
        '^[[:space:]]*DNS[[:space:]]*='
        '^[[:space:]]*MTU[[:space:]]*='
        '^[[:space:]]*Table[[:space:]]*='
        '^[[:space:]]*PreUp[[:space:]]*='
        '^[[:space:]]*PostUp[[:space:]]*='
        '^[[:space:]]*PreDown[[:space:]]*='
        '^[[:space:]]*PostDown[[:space:]]*='
        '^[[:space:]]*SaveConfig[[:space:]]*='
        '^[[:space:]]*PublicKey[[:space:]]*='
        '^[[:space:]]*PresharedKey[[:space:]]*='
        '^[[:space:]]*AllowedIPs[[:space:]]*='
        '^[[:space:]]*Endpoint[[:space:]]*='
        '^[[:space:]]*PersistentKeepalive[[:space:]]*='
    )

    is_allowed_line() {
        local line="$1"
        for pattern in "${allowed_patterns[@]}"; do
            if [[ "$line" =~ $pattern ]]; then
                return 0
            fi
        done
        return 1
    }

    > "$config_file"
    local in_config=false
    local last_was_blank=false
    while IFS= read -r line; do
        # 去掉 CR，避免 Windows 格式的换行符干扰匹配
        line="${line//$'\r'/}"

        if is_allowed_line "$line"; then
            in_config=true
            echo "$line" >> "$config_file"
            last_was_blank=false
        elif [ "$in_config" = true ] && [[ -z "${line//[[:space:]]/}" ]]; then
            # 允许保留单个空行作为分隔
            if [ "$last_was_blank" = false ]; then
                echo "" >> "$config_file"
                last_was_blank=true
            fi
        fi
    done < "$temp_file"
}

# 为客户端配置注入主机路由保持规则
inject_primary_route_rules() {
    local config_file="$1"
    local primary_ipv4
    primary_ipv4=$(get_primary_ipv4)

    if [ -z "$primary_ipv4" ]; then
        print_warning "Unable to detect primary IPv4, PostUp/PostDown route rules not added"
        return
    fi

    if grep -q "PostUp = ip rule add from $primary_ipv4 lookup main" "$config_file" 2>/dev/null; then
        return
    fi

    awk -v ip="$primary_ipv4" '
    BEGIN {added=0}
    /^\[Peer\]/ && added==0 {
        print "PostUp = ip rule add from " ip " lookup main"
        print "PostDown = ip rule delete from " ip " lookup main"
        added=1
    }
    {print}
    END {
        if (added==0) {
            print "PostUp = ip rule add from " ip " lookup main"
            print "PostDown = ip rule delete from " ip " lookup main"
        }
    }' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
}

# 检测 WireGuard 配置中是否支持 IPv6
# 判断依据：AllowedIPs 中是否包含 ::/0
# 参数: $1=配置文件路径
# 返回: 0=支持IPv6, 1=不支持IPv6
check_config_has_ipv6() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        return 1
    fi
    
    # 检查 AllowedIPs 中是否包含 ::/0（表示服务端支持 IPv6）
    if grep -qE 'AllowedIPs[[:space:]]*=.*::/0' "$config_file"; then
        return 0
    fi
    
    # 也检查 Address 中是否包含 IPv6 地址
    if grep -qE 'Address[[:space:]]*=.*:' "$config_file"; then
        return 0
    fi
    
    return 1
}

# 禁用客户端 IPv6（防止泄漏）
# 当服务端不支持 IPv6 时调用此函数
disable_client_ipv6() {
    local backup_file="/etc/wireguard/.ipv6_sysctl_backup"
    local sysctl_conf="/etc/sysctl.d/99-wireguard-noipv6.conf"
    
    # 定义 sysctl 配置内容
    local sysctl_content="# WireGuard 客户端 IPv6 禁用配置
# 由 WireGuard 安装脚本自动生成
# 原因：服务端不支持 IPv6，禁用以防止 IPv6 流量泄漏
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1"
    
    # 如果已经存在禁用配置，直接重新应用设置（防止重启后失效）
    if [ -f "$backup_file" ] || [ -f "$sysctl_conf" ]; then
        # 确保 sysctl 配置存在
        [ ! -f "$sysctl_conf" ] && echo "$sysctl_content" > "$sysctl_conf"
        
        # 确保备份文件存在
        if [ ! -f "$backup_file" ]; then
            echo "IPV6_DISABLED_BY_WG=true" > "$backup_file"
            echo "DISABLED_AT=$(date +%Y%m%d_%H%M%S)" >> "$backup_file"
        fi
        
        # 重新应用禁用设置（同时加载配置文件确保持久化）
        sysctl -p "$sysctl_conf" > /dev/null 2>&1 || {
            sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
            sysctl -w net.ipv6.conf.default.disable_ipv6=1 > /dev/null 2>&1
        }
        print_success "IPv6 disable settings reapplied"
        return 0
    fi
    
    # 首次禁用：检查客户端本机是否有 IPv6
    if ! ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
        print_info "Client has no IPv6, no need to disable"
        return 0
    fi
    
    # 备份当前 IPv6 设置状态（仅记录是否被我们禁用过）
    echo "IPV6_DISABLED_BY_WG=true" > "$backup_file"
    echo "DISABLED_AT=$(date +%Y%m%d_%H%M%S)" >> "$backup_file"
    
    # 创建 sysctl 配置禁用 IPv6
    echo "$sysctl_content" > "$sysctl_conf"
    
    # 立即应用（加载配置文件以确保持久化生效）
    sysctl -p "$sysctl_conf" > /dev/null 2>&1 || {
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 > /dev/null 2>&1
    }
    
    print_success "Client IPv6 disabled (leak prevention)"
    print_info "Reason: Server does not support IPv6, disabling client IPv6 to prevent traffic leakage"
}

# 恢复客户端 IPv6 设置
# 在卸载客户端时调用
restore_client_ipv6() {
    local backup_file="/etc/wireguard/.ipv6_sysctl_backup"
    local sysctl_conf="/etc/sysctl.d/99-wireguard-noipv6.conf"
    
    # 检查是否是我们禁用的 IPv6
    if [ ! -f "$backup_file" ]; then
        return 0
    fi
    
    if ! grep -q "IPV6_DISABLED_BY_WG=true" "$backup_file" 2>/dev/null; then
        return 0
    fi
    
    # 删除 sysctl 配置
    if [ -f "$sysctl_conf" ]; then
        rm -f "$sysctl_conf"
        print_info "IPv6 disable configuration removed"
    fi
    
    # 恢复 IPv6
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 > /dev/null 2>&1
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 > /dev/null 2>&1
    
    # 删除备份文件
    rm -f "$backup_file"
    
    print_success "Client IPv6 settings restored"
}

##############################################
# 服务端安装函数
##############################################

install_server() {
    print_separator
    print_info "Installing WireGuard server..."
    print_separator
    
    # 检查权限
    check_root
    
    # 检查系统版本
    check_system
    
    # 检查 Docker
    check_docker
    
    # 检查目录是否存在
    if [ -d "$INSTALL_DIR" ]; then
        print_error "Directory $INSTALL_DIR already exists!"
        print_warning "Possible reasons:"
        echo "  1. WireGuard server is already installed"
        echo "  2. Directory or file with the same name exists"
        echo ""
        print_warning "Solutions:"
        echo "  1. To reinstall, run: rm -rf $INSTALL_DIR"
        echo "  2. Or choose a different installation directory"
        exit 1
    fi
    
    # 获取服务器信息
    print_info "Detecting server configuration..."
    
    local ip_info=$(get_public_ip)
    local server_ipv4=$(echo "$ip_info" | cut -d'|' -f1)
    local server_ipv6=$(echo "$ip_info" | cut -d'|' -f2)
    
    if [ -z "$server_ipv4" ]; then
        print_error "Unable to get server public IPv4 address"
        read -p "Please enter server public IP manually: " server_ipv4
        if [ -z "$server_ipv4" ]; then
            print_error "Server IP cannot be empty"
            exit 1
        fi
    fi
    
    local timezone=$(get_timezone)
    local has_ipv6=false
    local subnet_v6=""
    
    # 获取默认出口网卡名称
    local default_iface
    default_iface=$(ip -4 route show default | awk '/default/ {print $5}' | head -n1)
    if [ -z "$default_iface" ]; then
        default_iface="eth0"
        print_warning "Unable to detect network interface, using default: $default_iface"
    else
        print_info "Detected default interface: $default_iface"
    fi
    
    if check_ipv6_support && [ -n "$server_ipv6" ]; then
        has_ipv6=true
        print_success "IPv6 support detected"
        print_info "IPv4 address: $server_ipv4"
        print_info "IPv6 address: $server_ipv6"
    else
        print_warning "No IPv6 support detected, configuring IPv4 only"
        print_info "IPv4 address: $server_ipv4"
    fi
    
    print_info "Timezone: $timezone"
    
    # 询问配置参数
    echo ""
    print_info "Configuration parameters (press Enter for defaults):"
    
    # 端口验证（1-65535）
    while true; do
        read -p "WireGuard port [default: $DEFAULT_PORT]: " server_port
        server_port=${server_port:-$DEFAULT_PORT}
        if [[ "$server_port" =~ ^[0-9]+$ ]] && [ "$server_port" -ge 1 ] && [ "$server_port" -le 65535 ]; then
            break
        else
            print_error "Invalid port number (must be 1-65535)"
        fi
    done
    
    # Peer 数量验证（仅允许 1-3）
    while true; do
        read -p "Number of clients (1-3) [default: $DEFAULT_PEERS]: " peers
        peers=${peers:-$DEFAULT_PEERS}
        if [[ "$peers" =~ ^[1-3]$ ]]; then
            break
        else
            print_error "Number of clients must be between 1 and 3"
        fi
    done
    
    read -p "DNS server [default: $DEFAULT_DNS]: " dns
    dns=${dns:-$DEFAULT_DNS}
    
    # 内网子网验证（IPv4 格式）
    while true; do
        read -p "Internal subnet [default: $DEFAULT_SUBNET]: " subnet
        subnet=${subnet:-$DEFAULT_SUBNET}
        # 验证 IPv4 子网格式：x.x.x.0 其中 x 为 0-255
        if [[ "$subnet" =~ ^([0-9]{1,3}\.){3}0$ ]]; then
            local valid=true
            IFS='.' read -ra octets <<< "$subnet"
            for octet in "${octets[@]}"; do
                if [ "$octet" -gt 255 ]; then
                    valid=false
                    break
                fi
            done
            if [ "$valid" = true ]; then
                break
            fi
        fi
        print_error "Invalid subnet format (e.g., 10.13.13.0)"
    done
    
    if [ "$has_ipv6" = true ]; then
        read -p "Internal IPv6 subnet [default: $DEFAULT_SUBNET_V6]: " subnet_v6
        subnet_v6=${subnet_v6:-$DEFAULT_SUBNET_V6}
    fi
    
    # 配置 AllowedIPs
    local allowed_ips="0.0.0.0/0"
    if [ "$has_ipv6" = true ]; then
        allowed_ips="0.0.0.0/0, ::/0"
    fi
    
    local compose_ipv6_env=""
    if [ "$has_ipv6" = true ]; then
        compose_ipv6_env="      - INTERNAL_SUBNET_V6=$subnet_v6"
    fi
    
    # 创建安装目录
    print_info "Creating installation directory: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    # 创建 docker-compose.yaml
    print_info "Generating docker-compose.yaml..."
    cat > "$COMPOSE_FILE" <<EOF
services:
  wireguard:
    image: linuxserver/wireguard:latest
    container_name: wireguard
    network_mode: host
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=$timezone
      - SERVERURL=$server_ipv4
      - SERVERPORT=$server_port
      - PEERS=$peers
      - PEERDNS=$dns
      - INTERNAL_SUBNET=$subnet
      - ALLOWEDIPS=$allowed_ips
$compose_ipv6_env
    volumes:
      - ./config:/config
      - /lib/modules:/lib/modules
    restart: unless-stopped
EOF

    print_success "docker-compose.yaml created successfully"
    
    # 配置内核参数（IP 转发）
    print_info "Configuring kernel parameters..."
    
    # 创建或更新 sysctl 配置
    cat > /etc/sysctl.d/99-wireguard.conf <<SYSCTL_EOF
# WireGuard 需要的内核参数
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
SYSCTL_EOF
    
    if [ "$has_ipv6" = true ]; then
        cat >> /etc/sysctl.d/99-wireguard.conf <<SYSCTL_EOF
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
SYSCTL_EOF
    fi
    
    # 应用 sysctl 配置
    sysctl -p /etc/sysctl.d/99-wireguard.conf > /dev/null 2>&1
    print_success "Kernel parameters applied"
    
    # 配置防火墙规则（自动检测 UFW/nftables/iptables）
    print_info "Configuring firewall rules..."
    
    # 记录添加的规则信息（用于卸载时清理）
    local firewall_info_file="$INSTALL_DIR/.firewall_info"
    echo "PORT=$server_port" > "$firewall_info_file"
    echo "IPV6=$has_ipv6" >> "$firewall_info_file"
    
    # 调用统一的防火墙配置函数
    configure_firewall_open_port "$server_port" "$has_ipv6" "$firewall_info_file"
    print_success "Firewall rules configured"

    
    # 启动容器
    print_separator
    print_info "Starting WireGuard container..."
    
    docker compose up -d
    
    # 等待容器启动
    print_info "Waiting for container to initialise (this may take a few seconds)..."
    sleep 5
    
    # 检查容器状态
    if docker ps | grep -q wireguard; then
        print_success "WireGuard container started successfully!"
    else
        print_error "WireGuard container failed to start, check logs: docker logs wireguard"
        exit 1
    fi
    
    # 等待配置文件生成
    print_info "Waiting for configuration files to generate..."
    local max_wait=30
    local waited=0
    while [ ! -f "$INSTALL_DIR/config/peer1/peer1.conf" ] && [ $waited -lt $max_wait ]; do
        sleep 1
        waited=$((waited + 1))
    done
    
    if [ ! -f "$INSTALL_DIR/config/peer1/peer1.conf" ]; then
        print_error "Configuration file generation timed out, check logs: docker logs wireguard"
        exit 1
    fi
    
    # 修复服务端配置文件中的网卡名称（适用于所有情况，包括纯 IPv4）
    local server_conf="$INSTALL_DIR/config/wg_confs/wg0.conf"
    
    # 等待服务端配置文件生成
    local conf_wait=10
    local conf_waited=0
    while [ ! -f "$server_conf" ] && [ $conf_waited -lt $conf_wait ]; do
        sleep 1
        conf_waited=$((conf_waited + 1))
    done
    
    if [ -f "$server_conf" ]; then
        # 修复 iptables 规则中的网卡名称（将 eth+ 替换为实际网卡）
        # 这对于纯 IPv4 和双栈服务器都是必需的
        if grep -q "eth+" "$server_conf"; then
            sed -i "s|eth+|${default_iface}|g" "$server_conf"
            print_success "Server interface configuration fixed: eth+ -> $default_iface"
            
            # 重启容器以应用新配置
            print_info "Restarting WireGuard container to apply interface configuration..."
            docker compose restart
            sleep 2
        fi
    fi
    
    # 如果支持 IPv6，修复配置文件添加 ip6tables 规则和 IPv6 地址
    if [ "$has_ipv6" = true ]; then
        print_info "Fixing IPv6 configuration..."
        # 从子网地址提取前缀（如 fd13:13:13::/64 -> fd13:13:13）
        local ipv6_prefix=$(echo "$subnet_v6" | sed -E 's|::/[0-9]+$||; s|::$||')
        
        if [ -f "$server_conf" ]; then
            # 备份原配置
            cp "$server_conf" "${server_conf}.backup"
            
            # 修复服务端配置：添加 IPv6 地址到 Address
            sed -i "s|^Address = \(.*\)$|Address = \1, ${ipv6_prefix}::1/64|" "$server_conf"
            
            # 添加 ip6tables 规则（在现有 PostUp 后添加）
            if ! grep -q "ip6tables" "$server_conf"; then
                sed -i "/^PostUp = iptables/a PostUp = ip6tables -A FORWARD -i %i -j ACCEPT; ip6tables -A FORWARD -o %i -j ACCEPT; ip6tables -t nat -A POSTROUTING -o ${default_iface} -j MASQUERADE" "$server_conf"
                sed -i "/^PostDown = iptables/a PostDown = ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -D FORWARD -o %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ${default_iface} -j MASQUERADE" "$server_conf"
            fi
            
            # 修复 Peer 的 AllowedIPs：添加 IPv6 地址
            # 提取 IPv4 子网前缀（如 10.13.13.0 -> 10.13.13）
            local ipv4_prefix=$(echo "$subnet" | sed 's/\.[0-9]*$//')
            
            local peer_num=1
            while [ $peer_num -le $peers ]; do
                local peer_ipv4="${ipv4_prefix}.$((peer_num + 1))"
                local peer_ipv6="${ipv6_prefix}::$((peer_num + 1))/128"
                
                # 在服务端配置中为每个 peer 添加 IPv6 AllowedIPs
                if grep -q "AllowedIPs = .*${peer_ipv4}/32" "$server_conf"; then
                    sed -i "s|AllowedIPs = ${peer_ipv4}/32$|AllowedIPs = ${peer_ipv4}/32, ${peer_ipv6}|" "$server_conf"
                fi
                
                peer_num=$((peer_num + 1))
            done
            
            print_success "Server IPv6 configuration fixed"
        fi
        
        # 修复所有客户端配置文件
        for peer_num in $(seq 1 $peers); do
            local peer_conf="$INSTALL_DIR/config/peer${peer_num}/peer${peer_num}.conf"
            if [ -f "$peer_conf" ]; then
                # 备份
                cp "$peer_conf" "${peer_conf}.backup"
                
                # 添加 IPv6 地址到客户端 Address
                local peer_ipv6="${ipv6_prefix}::$((peer_num + 1))/64"
                sed -i "s|^Address = \(.*\)$|Address = \1, ${peer_ipv6}|" "$peer_conf"
                
                print_success "Client peer${peer_num} IPv6 configuration fixed"
            fi
        done
        
        # 重启容器以应用新配置
        print_info "Restarting WireGuard container to apply IPv6 configuration..."
        docker compose restart
        
        sleep 3
        
        if docker ps | grep -q wireguard; then
            print_success "WireGuard container restarted successfully, IPv6 enabled"
        else
            print_error "Container restart failed, please check logs"
        fi
    fi
    
    # 显示服务端配置信息
    print_separator
    print_success "WireGuard server installation complete!"
    print_separator
    echo ""
    
    print_info "Configuration details:"
    echo "  Server address: $server_ipv4:$server_port"
    if [ "$has_ipv6" = true ]; then
        echo "  Server IPv6: $server_ipv6"
    fi
    echo "  Number of clients: $peers"
    echo "  Internal subnet: $subnet"
    if [ "$has_ipv6" = true ]; then
        echo "  Internal IPv6 subnet: $subnet_v6"
    fi
    echo ""
    
    print_info "Configuration file locations:"
    echo "  Server: $INSTALL_DIR/config/wg_confs/wg0.conf"
    echo "  Clients: $INSTALL_DIR/config/peer1/, peer2/, ..."
    echo ""
    
    print_info "Management commands:"
    echo "  View client config: run script and select option 3"
    echo "  Restart/stop/start: docker compose -f $COMPOSE_FILE restart|stop|start"
    print_separator
}

# 查看服务端配置
show_server_config() {
    if [ ! -d "$INSTALL_DIR" ]; then
        print_error "WireGuard server is not installed"
        exit 1
    fi
    
    local server_config="$INSTALL_DIR/config/wg_confs/wg0.conf"
    
    print_separator
    print_info "WireGuard Server Configuration"
    print_separator
    echo ""
    
    # 显示服务端配置
    if [ -f "$server_config" ]; then
        cat "$server_config"
        echo ""
        print_info "Configuration file location: $server_config"
    else
        print_warning "Server configuration file does not exist: $server_config"
        print_info "Please check if the service is running properly"
    fi
    
    print_separator
}

# 查看客户端配置（用于服务端）
show_client_config() {
    if [ ! -d "$INSTALL_DIR" ]; then
        print_error "WireGuard server is not installed"
        exit 1
    fi
    
    local config_dir="$INSTALL_DIR/config"
    
    print_separator
    print_info "WireGuard Client Configuration List"
    print_separator
    echo ""
    
    # 查找所有 peer 目录
    local peer_count=0
    local peer_dirs=()
    
    if [ -d "$config_dir" ]; then
        # 查找所有 peer 目录（peer1, peer2, peer3...）
        while IFS= read -r -d '' peer_dir; do
            peer_dirs+=("$peer_dir")
            peer_count=$((peer_count + 1))
        done < <(find "$config_dir" -maxdepth 1 -type d -name "peer*" -print0 | sort -z)
    fi
    
    if [ $peer_count -eq 0 ]; then
        print_warning "No client configurations found"
        print_info "Please check if the service is running properly"
    else
        print_success "Found $peer_count client configuration(s)"
        echo ""
        
        # 显示所有 peer 的配置
        for peer_dir in "${peer_dirs[@]}"; do
            local peer_name=$(basename "$peer_dir")
            local peer_config="$peer_dir/$peer_name.conf"
            
            if [ -f "$peer_config" ]; then
                print_info "=== $peer_name ==="
                print_separator
                cat "$peer_config"
                print_separator
                echo ""
                print_info "Configuration file location: $peer_dir/"
                echo ""
            fi
        done
    fi
    
    print_separator
}

# 查看服务端状态
show_server_status() {
    if [ ! -d "$INSTALL_DIR" ]; then
        print_error "WireGuard server is not installed"
        exit 1
    fi
    
    print_separator
    print_info "WireGuard Service Status:"
    print_separator
    
    if docker ps | grep -q wireguard; then
        print_success "Service is running"
        echo ""
        docker ps --filter "name=wireguard" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        print_info "Connected clients:"
        docker exec wireguard wg show 2>/dev/null || print_warning "Unable to get client connection info"
    else
        print_error "Service is not running"
    fi
    print_separator
}

# 卸载服务端
uninstall_server() {
    if [ ! -d "$INSTALL_DIR" ]; then
        print_error "WireGuard server is not installed"
        exit 1
    fi
    
    check_root
    
    print_warning "About to uninstall WireGuard server"
    read -p "Confirm uninstall? This will delete all configuration files (y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Uninstall cancelled"
        exit 0
    fi
    
    # 停止并删除容器
    print_info "Stopping and removing container..."
    cd "$INSTALL_DIR"
    docker compose down
    
    # 清除内核参数配置
    if [ -f /etc/sysctl.d/99-wireguard.conf ]; then
        print_info "Removing kernel parameter configuration..."
        rm -f /etc/sysctl.d/99-wireguard.conf
        # 重新加载 sysctl 配置
        sysctl --system > /dev/null 2>&1
        print_success "Kernel parameter configuration removed"
    fi
    
    # 清除防火墙规则
    print_info "Removing firewall rules..."
    local firewall_info_file="$INSTALL_DIR/.firewall_info"
    cleanup_firewall_rules "$firewall_info_file"
    
    # 删除安装目录
    print_info "Removing installation directory..."
    cd /
    rm -rf "$INSTALL_DIR"
    
    print_success "WireGuard server uninstalled"
    
    # 询问是否删除 Docker 镜像
    echo ""
    read -p "Also remove WireGuard Docker image? (y/N): " remove_image
    
    if [[ "$remove_image" =~ ^[Yy]$ ]]; then
        print_info "Looking for WireGuard image..."
        
        if docker images | grep -q "linuxserver/wireguard"; then
            print_info "Removing WireGuard image..."
            docker rmi $(docker images linuxserver/wireguard -q) 2>/dev/null
            
            if [ $? -eq 0 ]; then
                print_success "WireGuard image removed"
            else
                print_warning "Image removal failed or partial, may be in use by other containers"
            fi
        else
            print_info "WireGuard image not found"
        fi
    else
        print_info "Keeping Docker image"
    fi
}

##############################################
# 客户端管理函数
##############################################

install_client() {
    print_separator
    print_info "Installing WireGuard client..."
    print_separator
    
    # 检查权限
    check_root
    
    # 检查系统版本
    check_system
    
    # 检查是否已安装
    if command -v wg &> /dev/null; then
        print_warning "WireGuard is already installed"
        wg --version
        echo ""
        read -p "Continue with configuration? (y/N): " continue_config
        if [[ ! "$continue_config" =~ ^[Yy]$ ]]; then
            print_info "Installation cancelled"
            return
        fi
    else
        # 更新软件包列表
        print_info "Updating package list..."
        apt update
        
        # 安装 WireGuard 和 resolvconf
        print_info "Installing WireGuard and resolvconf..."
        apt install wireguard resolvconf -y
        
        if command -v wg &> /dev/null; then
            print_success "WireGuard installed successfully"
            wg --version
        else
            print_error "WireGuard installation failed"
            exit 1
        fi
    fi
    
    echo ""
    print_separator
    print_info "Configuring WireGuard Client"
    print_separator
    
    # 配置文件路径
    local config_file="/etc/wireguard/wg0.conf"
    
    # 检查配置文件是否已存在
    if [ -f "$config_file" ]; then
        print_warning "Configuration file $config_file already exists"
        read -p "Backup and overwrite? (y/N): " backup_confirm
        if [[ "$backup_confirm" =~ ^[Yy]$ ]]; then
            cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
            print_success "Backed up to ${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
        else
            print_info "Configuration cancelled"
            return
        fi
    fi
    
    echo ""
    print_info "Please enter WireGuard configuration (obtained from server)"
    print_info "Configuration example:"
    echo ""
    echo "[Interface]"
    echo "Address = 10.13.13.2"
    echo "PrivateKey = xxxx"
    echo "ListenPort = 51820"
    echo "DNS = 8.8.8.8"
    echo ""
    echo "[Peer]"
    echo "PublicKey = xxxx"
    echo "PresharedKey = xxxx"
    echo "Endpoint = 89.251.xx.xx:51820"
    echo "AllowedIPs = 0.0.0.0/0"
    echo ""
    print_separator
    
    print_info "Paste the WireGuard configuration directly"
    print_warning "After pasting, type EOF on a new line and press Enter"
    echo ""
    
    # 创建临时文件存储原始输入，并设置 trap 确保清理
    local temp_file=$(mktemp)
    trap "rm -f '$temp_file'" EXIT
    
    while IFS= read -r line; do
        if [ "$line" = "EOF" ]; then
            break
        fi
        echo "$line" >> "$temp_file"
    done

    # 过滤并写入配置
    filter_wireguard_config "$temp_file" "$config_file"
    rm -f "$temp_file"
    trap - EXIT  # 恢复 trap
    
    # 检查配置文件是否有内容
    if [ ! -s "$config_file" ]; then
        print_error "Configuration file is empty, please reconfigure"
        rm -f "$config_file"
        exit 1
    fi
    
    # 注入主机保留路由规则，确保 SSH 不经 WireGuard
    inject_primary_route_rules "$config_file"
    
    # 设置权限
    chmod 600 "$config_file"
    print_success "Configuration file saved to $config_file"
    
    # 检测服务端是否支持 IPv6，如果不支持则禁用客户端 IPv6 防止泄漏
    echo ""
    print_info "Checking server IPv6 support..."
    if check_config_has_ipv6 "$config_file"; then
        print_success "Server supports IPv6, keeping client IPv6 enabled"
    else
        print_warning "Server does not support IPv6"
        disable_client_ipv6
    fi
    
    # 显示配置内容
    echo ""
    print_info "Current configuration:"
    print_separator
    cat "$config_file"
    print_separator
    
    # 询问是否立即启动
    echo ""
    read -p "Start WireGuard now? (Y/n): " start_now
    
    if [[ ! "$start_now" =~ ^[Nn]$ ]]; then
        start_wireguard_client
    else
        print_info "Configuration complete. Use these commands to manage WireGuard:"
        echo "  Start: wg-quick up wg0"
        echo "  Stop: wg-quick down wg0"
        echo "  Status: wg show"
        echo "  Enable on boot: systemctl enable wg-quick@wg0"
    fi
}

# 启动 WireGuard 客户端
start_wireguard_client() {
    print_info "Starting WireGuard..."
    
    local config_file="/etc/wireguard/wg0.conf"
    
    # 如果已经运行，先停止
    if wg show wg0 &> /dev/null; then
        print_info "WireGuard is already running, stopping first..."
        wg-quick down wg0
    fi
    
    # 每次启动前检查并应用 IPv6 设置（防止重启后 sysctl 失效）
    if [ -f "$config_file" ]; then
        if ! check_config_has_ipv6 "$config_file"; then
            # 服务端不支持 IPv6，确保禁用
            local sysctl_conf="/etc/sysctl.d/99-wireguard-noipv6.conf"
            if [ -f "$sysctl_conf" ]; then
                # 重新应用禁用设置
                sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
                sysctl -w net.ipv6.conf.default.disable_ipv6=1 > /dev/null 2>&1
            fi
        fi
    fi
    
    # 启动
    if wg-quick up wg0; then
        print_success "WireGuard started successfully!"
        echo ""
        print_info "Connection status:"
        wg show wg0
        echo ""
        print_info "Testing connectivity:"
        if ping -c 3 8.8.8.8 &> /dev/null; then
            print_success "Network connection OK"
        else
            print_warning "Network connection test failed, please check configuration"
        fi
    else
        print_error "WireGuard failed to start, please check configuration"
        exit 1
    fi
    
    # 询问是否设置开机自启
    echo ""
    read -p "Enable start on boot? (y/N): " enable_autostart
    if [[ "$enable_autostart" =~ ^[Yy]$ ]]; then
        systemctl enable wg-quick@wg0
        print_success "Enabled start on boot"
    fi
}

# 查看客户端状态
show_client_status() {
    if ! command -v wg &> /dev/null; then
        print_error "WireGuard is not installed"
        exit 1
    fi
    
    print_separator
    print_info "WireGuard Client Status:"
    print_separator
    
    if wg show wg0 &> /dev/null; then
        print_success "WireGuard is running"
        echo ""
        wg show wg0
        echo ""
        
        # 检查服务状态
        if systemctl is-enabled wg-quick@wg0 &> /dev/null; then
            print_info "Start on boot: Enabled"
        else
            print_info "Start on boot: Disabled"
        fi
    else
        print_warning "WireGuard is not running"
    fi
    print_separator
}

# 停止 WireGuard 客户端
stop_wireguard_client() {
    check_root
    
    if ! wg show wg0 &> /dev/null; then
        print_warning "WireGuard is not running"
        return
    fi
    
    print_info "Stopping WireGuard..."
    if wg-quick down wg0; then
        print_success "WireGuard stopped"
    else
        print_error "Failed to stop"
        exit 1
    fi
}

# 重新配置 WireGuard 客户端
reconfigure_client() {
    check_root
    
    if ! command -v wg &> /dev/null; then
        print_error "WireGuard is not installed, please install the client first"
        return
    fi
    
    print_separator
    print_info "Reconfiguring WireGuard Client"
    print_separator
    
    local config_file="/etc/wireguard/wg0.conf"
    
    # 如果正在运行，先停止
    if wg show wg0 &> /dev/null; then
        print_info "Stopping current WireGuard connection..."
        wg-quick down wg0
    fi
    
    # 备份现有配置
    if [ -f "$config_file" ]; then
        local backup_file="${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$config_file" "$backup_file"
        print_success "Backed up existing configuration to $backup_file"
    fi
    
    echo ""
    print_info "Please enter new WireGuard configuration (obtained from server)"
    print_warning "After pasting, type EOF on a new line and press Enter"
    echo ""
    
    # 创建临时文件存储原始输入，并设置 trap 确保清理
    local temp_file=$(mktemp)
    trap "rm -f '$temp_file'" EXIT
    
    while IFS= read -r line; do
        if [ "$line" = "EOF" ]; then
            break
        fi
        echo "$line" >> "$temp_file"
    done

    # 过滤并写入配置
    filter_wireguard_config "$temp_file" "$config_file"
    rm -f "$temp_file"
    trap - EXIT  # 恢复 trap
    
    # 检查配置文件是否有内容
    if [ ! -s "$config_file" ]; then
        print_error "Configuration file is empty, please reconfigure"
        # 恢复备份
        if [ -f "$backup_file" ]; then
            cp "$backup_file" "$config_file"
            print_info "Restored previous configuration"
        fi
        return
    fi
    
    # 注入主机保留路由规则
    inject_primary_route_rules "$config_file"
    
    chmod 600 "$config_file"
    print_success "Configuration file updated"
    
    # 检测服务端是否支持 IPv6，如果不支持则禁用客户端 IPv6 防止泄漏
    echo ""
    print_info "Checking server IPv6 support..."
    if check_config_has_ipv6 "$config_file"; then
        print_success "Server supports IPv6, keeping client IPv6 enabled"
        # 如果之前禁用过 IPv6，现在可以恢复
        restore_client_ipv6
    else
        print_warning "Server does not support IPv6"
        disable_client_ipv6
    fi
    
    # 显示配置内容
    echo ""
    print_info "New configuration:"
    print_separator
    cat "$config_file"
    print_separator
    
    # 询问是否立即启动
    echo ""
    read -p "Start WireGuard now? (Y/n): " start_now
    
    if [[ ! "$start_now" =~ ^[Nn]$ ]]; then
        start_wireguard_client
    fi
}

# 卸载 WireGuard 客户端
uninstall_client() {
    check_root
    
    print_warning "About to uninstall WireGuard client"
    read -p "Confirm uninstall? This will delete configuration files (y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Uninstall cancelled"
        return
    fi
    
    # 停止服务
    if wg show wg0 &> /dev/null; then
        print_info "Stopping WireGuard..."
        wg-quick down wg0
    fi
    
    # 禁用开机自启
    if systemctl is-enabled wg-quick@wg0 &> /dev/null; then
        systemctl disable wg-quick@wg0
    fi
    
    # 恢复 IPv6 设置（如果之前被禁用过）
    print_info "Checking IPv6 settings..."
    restore_client_ipv6
    
    # 卸载软件包
    print_info "Uninstalling WireGuard..."
    apt remove --purge wireguard -y
    apt autoremove -y
    hash -r 2>/dev/null || true
    
    # 删除配置目录
    rm -rf /etc/wireguard
    
    print_success "WireGuard client uninstalled"
}

##############################################
# 主菜单
##############################################

show_menu() {
    clear
    print_separator
    echo -e "${BLUE}     WireGuard Installation and Management${NC}"
    echo -e "${YELLOW}             Debian 12/13 only${NC}"
    print_separator
    echo ""
    
    # 避免 shell 缓存命令路径导致状态误判
    hash -r 2>/dev/null || true
    
    # 检测服务端状态（使用 Docker 容器扫描）
    local server_status=""
    local nonstandard_installs=""
    local containers
    containers=$(detect_wireguard_containers)
    
    # 检查标准路径安装
    local has_standard_install=false
    local standard_running=false
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local is_standard=$(echo "$line" | cut -d'|' -f5)
        local container_id=$(echo "$line" | cut -d'|' -f2)
        if [ "$is_standard" = "true" ]; then
            has_standard_install=true
            # 检查是否运行中
            if docker ps -q --filter "id=$container_id" 2>/dev/null | grep -q .; then
                standard_running=true
            fi
        else
            # 记录非标准安装
            nonstandard_installs="${nonstandard_installs}${line}"$'\n'
        fi
    done <<< "$containers"
    
    if [ "$has_standard_install" = true ]; then
        if [ "$standard_running" = true ]; then
            server_status="${GREEN}Installed | Running${NC}"
        else
            server_status="${YELLOW}Installed | Stopped${NC}"
        fi
    elif [ -d "$INSTALL_DIR" ]; then
        # 目录存在但容器不存在（可能被手动删除）
        server_status="${YELLOW}Directory exists | No container${NC}"
    else
        server_status="${RED}Not installed${NC}"
    fi
    
    # 检测客户端状态
    local client_status=""
    if command -v wg &> /dev/null; then
        if wg show wg0 &> /dev/null 2>&1; then
            client_status="${GREEN}Installed | Running${NC}"
        else
            client_status="${YELLOW}Installed | Stopped${NC}"
        fi
    else
        client_status="${RED}Not installed${NC}"
    fi
    
    local ip_info=$(get_public_ip)
    local public_ipv4=$(echo "$ip_info" | cut -d'|' -f1)
    local public_ipv6=$(echo "$ip_info" | cut -d'|' -f2)
    
    # 格式化显示（分别查询 IPv4 和 IPv6 的国家）
    local ipv4_display=""
    local ipv6_display=""
    
    if [ -z "$public_ipv4" ]; then
        ipv4_display="Not detected"
    else
        local country_v4=$(get_ip_country "$public_ipv4")
        if [ -n "$country_v4" ]; then
            ipv4_display="${country_v4} | ${public_ipv4}"
        else
            ipv4_display="$public_ipv4"
        fi
    fi
    
    if [ -z "$public_ipv6" ]; then
        ipv6_display="Not detected"
    else
        local country_v6=$(get_ip_country "$public_ipv6")
        if [ -n "$country_v6" ]; then
            ipv6_display="${country_v6} | ${public_ipv6}"
        else
            ipv6_display="$public_ipv6"
        fi
    fi
    
    echo -e "  ${BLUE}System Status:${NC}"
    echo -e "    Server: $server_status"
    echo -e "    Client: $client_status"
    echo -e "    Public IPv4: $ipv4_display"
    echo -e "    Public IPv6: $ipv6_display"
    
    # 显示非标准安装警告
    if [ -n "$nonstandard_installs" ]; then
        echo ""
        echo -e "    ${YELLOW}⚠ Non-standard WireGuard installation detected!${NC}"
        echo -e "    ${YELLOW}  Use option 12 to clean up${NC}"
    fi
    echo ""
    print_separator
    echo ""
    echo "  Server Management:"
    echo "    1) Install Server (Docker)"
    echo "    2) View Server Config"
    echo "    3) View Peer Configs"
    echo "    4) View Service Status"
    echo "    5) Uninstall Server"
    echo ""
    echo "  Client Management:"
    echo "    6) Install Client"
    echo "    7) Reconfigure Client"
    echo "    8) View Client Status"
    echo "    9) Stop Client"
    echo "   10) Start Client"
    echo "   11) Uninstall Client"
    echo ""
    echo "  Other:"
    echo "   12) Clean Up Non-standard Installations"
    echo ""
    echo "    0) Exit"
    echo ""
    print_separator
}

main() {
    # 仅交互式菜单模式
    while true; do
        show_menu
        read -p "Select option [0-12]: " choice
        echo ""

        # 选择后先清屏，保持界面简洁
        clear

        case $choice in
            1)
                install_server
                read -p "Press Enter to continue..."
                ;;
            2)
                show_server_config
                read -p "Press Enter to continue..."
                ;;
            3)
                show_client_config
                read -p "Press Enter to continue..."
                ;;
            4)
                show_server_status
                read -p "Press Enter to continue..."
                ;;
            5)
                uninstall_server
                read -p "Press Enter to continue..."
                ;;
            6)
                install_client
                read -p "Press Enter to continue..."
                ;;
            7)
                reconfigure_client
                read -p "Press Enter to continue..."
                ;;
            8)
                show_client_status
                read -p "Press Enter to continue..."
                ;;
            9)
                stop_wireguard_client
                read -p "Press Enter to continue..."
                ;;
            10)
                start_wireguard_client
                read -p "Press Enter to continue..."
                ;;
            11)
                uninstall_client
                read -p "Press Enter to continue..."
                ;;
            12)
                cleanup_nonstandard_wireguard
                read -p "Press Enter to continue..."
                ;;
            0)
                print_info "Exiting script"
                exit 0
                ;;
            *)
                print_error "Invalid option, please try again"
                sleep 2
                ;;
        esac
    done
}

# 运行主函数
main "$@"
