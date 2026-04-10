#!/bin/bash
# 不使用 set -e，以便在交互式菜单中优雅处理错误
if [ "$EUID" -ne 0 ]; then
    log_error "Please run this script with root privileges (sudo ./install_snell.sh)"
    exit 1
fi

# --- 检查系统是否为 Debian 或 Ubuntu ---
check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
            log_error "This script only supports Debian and Ubuntu."
            exit 1
        fi
    else
        log_error "Cannot detect OS. This script only supports Debian and Ubuntu."
        exit 1
    fi
}

check_os

# --- 工具函数：转义 sed 替换字符串 ---
escape_sed_replacement() {
    # 依次转义反斜杠、斜杠、管道和 &，避免写入配置时破坏格式
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's|/|\/|g' -e 's/|/\\|/g' -e 's/&/\\&/g'
}

# --- Colors & Styling ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[90m'
PLAIN='\033[0m'

log_success() { echo -e "${GREEN}✅ $1${PLAIN}"; }
log_error() { echo -e "${RED}❌ $1${PLAIN}"; }
log_info() { echo -e "${CYAN}ℹ️  $1${PLAIN}"; }
log_action() { echo -e "${CYAN}$1${PLAIN}"; }
log_warn() { echo -e "${YELLOW}⚠️  $1${PLAIN}"; }

pause() {
    echo ""
    read -p "Press Enter to continue..."
}

generate_password() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24
}

# --- 获取 IPv4 地址 (保留多接口回退机制) ---
get_ipv4() {
    local tmp_ip
    for api in "ip.sb" "api.ipify.org" "ifconfig.me" "ipinfo.io/ip"; do
        tmp_ip=$(curl -fsSL --max-time 5 -4 "$api" 2>/dev/null || true)
        if [ -n "$tmp_ip" ]; then
            echo "$tmp_ip"
            return 0
        fi
    done
    return 1
}

# --- 获取已使用的端口列表 ---
get_used_ports() {
    local ports=()
    
    # Snell 端口
    if [ -f /etc/snell/snell-server.conf ]; then
        local snell_port=$(grep -oP 'listen = [^:]+:\K[0-9]+' /etc/snell/snell-server.conf 2>/dev/null)
        [ -n "$snell_port" ] && ports+=("$snell_port")
    fi
    
    # Snell Shadow-TLS 端口
    if [ -f /etc/systemd/system/shadow-tls-snell.service ]; then
        local snell_stls_port=$(grep -oP '\-\-listen 0\.0\.0\.0:\K[0-9]+' /etc/systemd/system/shadow-tls-snell.service 2>/dev/null)
        [ -n "$snell_stls_port" ] && ports+=("$snell_stls_port")
    fi
    
    # SS 端口
    if [ -f /etc/shadowsocks-rust/config.json ]; then
        local ss_port=$(grep -oP '"server_port"\s*:\s*\K[0-9]+' /etc/shadowsocks-rust/config.json 2>/dev/null)
        [ -n "$ss_port" ] && ports+=("$ss_port")
    fi
    
    # SS Shadow-TLS 端口
    if [ -f /etc/systemd/system/shadow-tls-ss.service ]; then
        local ss_stls_port=$(grep -oP '\-\-listen 0\.0\.0\.0:\K[0-9]+' /etc/systemd/system/shadow-tls-ss.service 2>/dev/null)
        [ -n "$ss_stls_port" ] && ports+=("$ss_stls_port")
    fi
    
    echo "${ports[*]}"
}

# --- 检查端口是否与已使用端口冲突 ---
is_port_used() {
    local port=$1
    local used_ports=$(get_used_ports)
    
    for used_port in $used_ports; do
        if [ "$port" = "$used_port" ]; then
            return 0
        fi
    done
    return 1
}

# --- 生成不冲突的随机端口 ---
generate_safe_port() {
    local attempts=0
    local max_attempts=100
    
    while [ $attempts -lt $max_attempts ]; do
        local port=$((20000 + RANDOM % 45536))
        if ! is_port_used "$port"; then
            echo "$port"
            return 0
        fi
        ((attempts++))
    done
    
    # 如果找不到，返回随机端口让用户自己决定
    echo "$((20000 + RANDOM % 45536))"
}


# --- 卸载 Snell 函数 ---
uninstall_snell() {
    echo "=========================================="
    log_action "🗑️  Uninstalling Snell server..."
    echo "=========================================="
    
    # 如果 Shadow-TLS 已安装，先卸载它
    if is_shadowtls_installed; then
        echo ""
        read -p "Shadow-TLS is installed. Uninstall it as well? [Y/n] (default: Y): " uninstall_stls
        uninstall_stls=${uninstall_stls:-Y}
        
        if [[ "$uninstall_stls" =~ ^[Yy]$ ]]; then
            uninstall_shadowtls
        fi
    fi
    
    # 停止并禁用服务
    if systemctl is-active --quiet snell.service; then
        echo "Stopping Snell service..."
        systemctl stop snell.service
    fi
    
    if systemctl is-enabled --quiet snell.service 2>/dev/null; then
        echo "Disabling Snell service..."
        systemctl disable snell.service
    fi
    
    echo "Removing Snell files..."
    rm -f /usr/local/bin/snell-server
    rm -f /etc/systemd/system/snell.service
    rm -rf /etc/snell
    
    systemctl daemon-reload
    
    echo "=========================================="
    log_success "Snell server has been completely removed."
    echo "=========================================="
}

# --- 获取当前安装的版本 ---
get_installed_version() {
    if [ -f /usr/local/bin/snell-server ]; then
        local version=$(/usr/local/bin/snell-server --version 2>&1 | grep -oP 'snell-server v\K[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        echo "$version"
    else
        echo ""
    fi
}

# --- 获取最新版本号 ---
get_latest_version() {
    local version=$(curl -s https://kb.nssurge.com/surge-knowledge-base/release-notes/snell | \
        grep -oP 'snell-server-v\K[0-9]+\.[0-9]+\.[0-9]+(?=-linux-amd64\.zip)' | \
        sort -V -r | \
        head -n 1)
    
    if [ -z "$version" ]; then
        echo "5.0.1"
    else
        echo "$version"
    fi
}

# --- 比较版本号 ---
version_gt() {
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

# --- 1. 安装依赖 ---
install_dependencies() {
    log_info "Checking and installing dependencies..."
    
    local packages_to_install=()
    
    for pkg in wget unzip curl; do
        if ! command -v $pkg &> /dev/null; then
            packages_to_install+=($pkg)
        fi
    done
    
    if [ ${#packages_to_install[@]} -gt 0 ]; then
        echo "Installing: ${packages_to_install[*]}"
        apt update
        apt install -y "${packages_to_install[@]}"
    else
        echo "All dependencies are already installed."
    fi
}

# --- 2. 检测 CPU 架构 ---
detect_architecture() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "aarch64"
            ;;
        *)
            echo "unsupported"
            ;;
    esac
}

# --- 3. 下载并安装 Snell 服务器 ---
download_and_install_snell() {
    local version=$1
    local arch=$2
    
    log_info "Downloading Snell server v${version} for ${arch}..."
    
    local download_url="https://dl.nssurge.com/snell/snell-server-v${version}-linux-${arch}.zip"
    
    if ! wget "${download_url}" -O snell-server.zip; then
        echo "Download failed. Please check your network connection or the URL."
        return 1
    fi
    
    if systemctl is-active --quiet snell.service 2>/dev/null; then
        echo "Stopping Snell service..."
        systemctl stop snell.service
    fi
    
    unzip -o snell-server.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/snell-server
    rm -f snell-server.zip
    
    echo "Snell server v${version} (${arch}) installed successfully."
    return 0
}

# --- 4. 交互式配置 ---
configure_snell() {
    echo "=========================================="
    echo "⚙️  Please configure your Snell server:"
    echo "=========================================="
    
    # 显示已使用的端口
    local used_ports=$(get_used_ports)
    if [ -n "$used_ports" ]; then
        log_warn "Ports in use: ${used_ports}"
        echo ""
    fi
    
    # 生成不冲突的随机端口
    default_port=$(generate_safe_port)
    
    read -p "Enter the listening port [default: ${default_port}]: " port
    port=${port:-${default_port}}
    
    default_psk=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
    
    read -p "Enter the password (psk) [default: ${default_psk}]: " psk
    psk=${psk:-${default_psk}}
    
    # DNS 选择（先于混淆选择）
    echo ""
    local dns_result=$(select_dns false 1)
    dns_servers=$(echo "$dns_result" | cut -d'|' -f1)
    dns_label=$(echo "$dns_result" | cut -d'|' -f2)
    
    # 混淆方式选择
    echo ""
    echo "🎭 Select obfuscation method:"
    echo "  1) No obfuscation"
    echo "  2) obfs http"
    echo "  3) Shadow-TLS v3"
    
    while true; do
        read -p "Enter your choice [1]: " obfs_choice
        obfs_choice=${obfs_choice:-1}
        case "$obfs_choice" in
            1)
                obfs_mode="none"
                break
                ;;
            2)
                obfs_mode="http"
                echo ""
                echo "obfs enabled. obfs mode is set to 'http'."
                host=$(select_obfs_host)
                break
                ;;
            3)
                obfs_mode="shadowtls"
                echo ""
                echo "Shadow-TLS v3 selected."
                
                # 生成 Shadow-TLS 端口（不与其他端口冲突）
                while true; do
                    default_stls_port=$(generate_safe_port)
                    if [ "$default_stls_port" != "$port" ] && ! is_port_used "$default_stls_port"; then
                        break
                    fi
                done
                
                read -p "Enter Shadow-TLS listening port [default: ${default_stls_port}]: " stls_port
                stls_port=${stls_port:-${default_stls_port}}
                
                # 生成 Shadow-TLS 密码
                default_stls_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
                read -p "Enter Shadow-TLS password [default: ${default_stls_password}]: " stls_password
                stls_password=${stls_password:-${default_stls_password}}
                
                # 选择 TLS host
                echo ""
                stls_host=$(select_shadowtls_host)
                break
                ;;
            *)
                echo "Invalid choice. Please enter 1, 2, or 3."
                ;;
    esac
    done
    
    mkdir -p /etc/snell
    
    if [[ "$obfs_mode" == "http" ]]; then
        cat >/etc/snell/snell-server.conf <<EOF
[snell-server]
listen = [::]:${port}
psk = ${psk}
ipv6 = true
dns = ${dns_servers}
obfs = http
host = ${host}
EOF
        echo "Configuration file with obfs created."
    elif [[ "$obfs_mode" == "shadowtls" ]]; then
        # Shadow-TLS 模式：Snell 先配置为 [::]，稍后会自动改为 127.0.0.1
        cat >/etc/snell/snell-server.conf <<EOF
[snell-server]
listen = [::]:${port}
psk = ${psk}
ipv6 = true
dns = ${dns_servers}
EOF
        echo "Configuration file created for Shadow-TLS mode."
    else
        cat >/etc/snell/snell-server.conf <<EOF
[snell-server]
listen = [::]:${port}
psk = ${psk}
ipv6 = true
dns = ${dns_servers}
EOF
        echo "Configuration file created (no obfuscation)."
    fi
    
    echo ""
    echo "=========================================="
    echo "📋 Configuration Summary:"
    echo "Port: ${port}"
    echo "PSK: ${psk}"
    echo "DNS: ${dns_servers} (${dns_label})"
    if [[ "$obfs_mode" == "http" ]]; then
        echo "Obfs: http"
        echo "Host: ${host}"
    elif [[ "$obfs_mode" == "shadowtls" ]]; then
        echo "Obfuscation: Shadow-TLS v3"
        echo "Shadow-TLS Port: ${stls_port}"
        echo "Shadow-TLS Password: ${stls_password}"
        echo "Shadow-TLS TLS Host: ${stls_host}"
    else
        echo "Obfuscation: None"
    fi
    echo "=========================================="
}

# --- 5. 创建 systemd 服务 ---
create_systemd_service() {
    log_action "🔧 Creating systemd service for Snell..."
    cat >/etc/systemd/system/snell.service <<EOF
[Unit]
Description=Snell Proxy Service
Documentation=https://kb.nssurge.com/surge-knowledge-base/release-notes/snell
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF

    log_info "Enabling and starting Snell service..."
    systemctl daemon-reload
    systemctl enable --now snell.service
    
    echo "Snell service has been started."
    echo "Verifying service status..."
    systemctl status snell.service --no-pager
}

# --- 6. 选择 Obfs Host ---
select_obfs_host() {
    local selected_host=""
    
    echo "🎭 Select an obfs host:" >&2
    echo "  1) Bilibili" >&2
    echo "     d1--ov-gotcha07.bilivideo.com" >&2
    echo "  2) Contentstack" >&2
    echo "     images.contentstack.io" >&2
    echo "  3) NCBI CDN" >&2
    echo "     cdn.ncbi.nlm.nih.gov" >&2
    echo "  4) ScienceDirect CDN (US East)" >&2
    echo "     sdfestaticassets-us-east-1.sciencedirectassets.com" >&2
    echo "  5) ScienceDirect CDN (EU West)" >&2
    echo "     sdfestaticassets-eu-west-1.sciencedirectassets.com" >&2
    echo "  6) Xiaohongshu CDN" >&2
    echo "     sns-video-qc.xhscdn.com" >&2
    echo "  7) Douyin/TikTok CDN" >&2
    echo "     sf1-cdn-tos.huoshanstatic.com" >&2
    echo "  8) Microsoft CDN" >&2
    echo "     software-static.download.prss.microsoft.com" >&2
    echo "  9) UCSC Genome Browser (Asia)" >&2
    echo "     genome-asia.ucsc.edu" >&2
    echo "  10) UCSC Genome Browser (US)" >&2
    echo "     genome.ucsc.edu" >&2
    echo "  11) Custom host" >&2
    
    while true; do
        read -p "Enter the host option number [1]: " host_choice
        host_choice=${host_choice:-1}
        case "$host_choice" in
            1)
                selected_host="d1--ov-gotcha07.bilivideo.com"
                break
                ;;
            2)
                selected_host="images.contentstack.io"
                break
                ;;
            3)
                selected_host="cdn.ncbi.nlm.nih.gov"
                break
                ;;
            4)
                selected_host="sdfestaticassets-us-east-1.sciencedirectassets.com"
                break
                ;;
            5)
                selected_host="sdfestaticassets-eu-west-1.sciencedirectassets.com"
                break
                ;;
            6)
                selected_host="sns-video-qc.xhscdn.com"
                break
                ;;
            7)
                selected_host="sf1-cdn-tos.huoshanstatic.com"
                break
                ;;
            8)
                selected_host="software-static.download.prss.microsoft.com"
                break
                ;;
            9)
                selected_host="genome-asia.ucsc.edu"
                break
                ;;
            10)
                selected_host="genome.ucsc.edu"
                break
                ;;
            11)
                read -p "Enter custom host: " custom_host
                if [[ -z "$custom_host" ]]; then
                    echo "Custom host cannot be empty. Please try again." >&2
                    continue
                fi
                selected_host="$custom_host"
                break
                ;;
            *)
                echo "Invalid choice. Please enter a number between 1 and 11." >&2
                ;;
        esac
    done
    
    echo "$selected_host"
}

# --- 选择 Shadow-TLS Host ---
select_shadowtls_host() {
    local default_host="gateway.icloud.com"
    
    echo "🔐 Shadow-TLS TLS Host:" >&2
    read -p "Enter TLS host [default: ${default_host}]: " input_host
    
    if [[ -z "$input_host" ]]; then
        echo "$default_host"
    else
        echo "$input_host"
    fi
}

# --- 7. 选择 DNS ---
select_dns() {
    local allow_cancel=${1:-false}
    local default_choice=${2:-1}
    local selected_dns=""
    local selected_label=""
    local provider_name=""
    local ipv4_servers=""
    local ipv6_servers=""
    
    echo "🌐 Select a DNS provider:" >&2
    echo "  1) Google" >&2
    echo "  2) Cloudflare" >&2
    echo "  3) Cloudflare Malware Protection" >&2
    echo "  4) Cloudflare Family" >&2
    echo "  5) Quad9" >&2
    echo "  6) Quad9 Secured" >&2
    echo "  7) Custom DNS" >&2
    if [[ "$allow_cancel" == "true" ]]; then
        echo "  0) Cancel" >&2
    fi
    
    while true; do
        read -p "Enter the DNS provider number [${default_choice}]: " dns_choice
        dns_choice=${dns_choice:-$default_choice}
        case "$dns_choice" in
            1)
                provider_name="Google"
                ipv4_servers="8.8.8.8,8.8.4.4"
                ipv6_servers="2001:4860:4860::8888,2001:4860:4860::8844"
                break
                ;;
            2)
                provider_name="Cloudflare"
                ipv4_servers="1.1.1.1,1.0.0.1"
                ipv6_servers="2606:4700:4700::1111,2606:4700:4700::1001"
                break
                ;;
            3)
                provider_name="Cloudflare Malware Protection"
                ipv4_servers="1.1.1.2,1.0.0.2"
                ipv6_servers="2606:4700:4700::1112,2606:4700:4700::1002"
                break
                ;;
            4)
                provider_name="Cloudflare Family"
                ipv4_servers="1.1.1.3,1.0.0.3"
                ipv6_servers="2606:4700:4700::1113,2606:4700:4700::1003"
                break
                ;;
            5)
                provider_name="Quad9"
                ipv4_servers="9.9.9.9,149.112.112.112"
                ipv6_servers="2620:fe::fe,2620:fe::9"
                break
                ;;
            6)
                provider_name="Quad9 Secured"
                ipv4_servers="9.9.9.11,149.112.112.11"
                ipv6_servers="2620:fe::11,2620:fe::fe:11"
                break
                ;;
            7)
                read -p "Enter custom DNS addresses (comma separated): " custom_dns
                if [[ -z "$custom_dns" ]]; then
                    echo "Custom DNS cannot be empty. Please try again." >&2
                    continue
                fi
                selected_label="Custom DNS"
                selected_dns="$custom_dns"
                echo "${selected_dns}|${selected_label}"
                return 0
                ;;
            0)
                if [[ "$allow_cancel" == "true" ]]; then
                    echo "CANCELLED" >&2
                    return 1
                else
                    echo "Invalid choice. Please enter a number between 1 and 7." >&2
                fi
                ;;
            *)
                if [[ "$allow_cancel" == "true" ]]; then
                    echo "Invalid choice. Please enter a number between 0 and 7." >&2
                else
                    echo "Invalid choice. Please enter a number between 1 and 7." >&2
                fi
                ;;
        esac
    done
    
    echo "" >&2
    read -p "Include IPv6 DNS servers? [Y/n] (default: Y): " include_ipv6
    include_ipv6=${include_ipv6:-Y}
    
    if [[ "$include_ipv6" =~ ^[Yy]$ ]]; then
        selected_dns="${ipv4_servers},${ipv6_servers}"
        selected_label="${provider_name} (IPv4 + IPv6)"
    else
        selected_dns="${ipv4_servers}"
        selected_label="${provider_name} (IPv4 only)"
    fi
    
    echo "${selected_dns}|${selected_label}"
}

# --- 统一 Shadow-TLS 逻辑 ---

get_stls_service_name() {
    echo "shadow-tls-${1}.service"
}

is_stls_installed() {
    local app=$1
    if [ -f "/usr/local/bin/shadow-tls" ] && [ -f "/etc/systemd/system/$(get_stls_service_name $app)" ]; then
        return 0
    fi
    return 1
}

# Return: listen_port|password|server_port|tls_host
get_stls_config() {
    local app=$1
    local service_file="/etc/systemd/system/$(get_stls_service_name $app)"
    if [ ! -f "$service_file" ]; then
        return 1
    fi
    local exec_line=$(grep "^ExecStart=" "$service_file")
    local listen_port=$(echo "$exec_line" | grep -oP '\-\-listen 0\.0\.0\.0:\K[0-9]+')
    local password=$(echo "$exec_line" | grep -oP '\-\-password \K[^ ]+')
    local server_port=$(echo "$exec_line" | grep -oP '\-\-server 127\.0\.0\.1:\K[0-9]+')
    local tls_host=$(echo "$exec_line" | grep -oP '\-\-tls \K[^:]+')
    echo "${listen_port}|${password}|${server_port}|${tls_host}"
}

download_and_install_shadowtls() {
    log_info "Downloading Shadow-TLS..."
    local arch=$(uname -m)
    local download_url=""
    case "$arch" in
        x86_64) download_url="https://github.com/ihciah/shadow-tls/releases/latest/download/shadow-tls-x86_64-unknown-linux-musl" ;;
        aarch64|arm64) download_url="https://github.com/ihciah/shadow-tls/releases/latest/download/shadow-tls-aarch64-unknown-linux-musl" ;;
        *) log_error "Unsupported architecture ${arch}"; return 1 ;;
    esac
    
    if ! wget -O /tmp/shadow-tls "${download_url}"; then
        log_error "Download failed."
        return 1
    fi
    
    chmod 755 /tmp/shadow-tls
    mv /tmp/shadow-tls /usr/local/bin/shadow-tls
    mkdir -p /etc/shadow-tls
    log_success "Shadow-TLS installed successfully."
    return 0
}

create_stls_service() {
    local app=$1
    local listen_port=$2
    local password=$3
    local server_port=$4
    local tls_host=$5
    local service_name=$(get_stls_service_name $app)
    local desc_name="Snell" && [ "$app" == "ss" ] && desc_name="ShadowSocks"

    log_info "Creating systemd service for Shadow-TLS ($desc_name)..."
    cat >/etc/systemd/system/${service_name} <<EOF
[Unit]
Description=Shadow-TLS Server Service for ${desc_name}
Documentation=https://github.com/ihciah/shadow-tls
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
WorkingDirectory=/etc/shadow-tls/
ExecStart=/usr/local/bin/shadow-tls --v3 server --listen 0.0.0.0:${listen_port} --password ${password} --server 127.0.0.1:${server_port} --tls ${tls_host}:443

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now ${service_name}
    log_success "Shadow-TLS service for ${desc_name} started."
}

uninstall_stls_service() {
    local app=$1
    local service_name=$(get_stls_service_name $app)
    
    log_info "Uninstalling Shadow-TLS for $app..."
    
    systemctl disable --now $service_name 2>/dev/null
    rm -f /etc/systemd/system/$service_name
    
    local other_app="ss" && [ "$app" == "ss" ] && other_app="snell"
    if ! is_stls_installed $other_app; then
        echo "Removing Shadow-TLS binary..."
        rm -f /usr/local/bin/shadow-tls
        rm -rf /etc/shadow-tls
    fi
    
    systemctl daemon-reload
    log_success "Shadow-TLS for $app removed."
}

modify_stls_setting() {
    local app=$1
    local setting=$2 # port, password, host
    
    if ! is_stls_installed $app; then
        log_error "Shadow-TLS for $app is not installed!"
        return 1
    fi

    local config=$(get_stls_config $app)
    local current_port=$(echo "$config" | cut -d'|' -f1)
    local current_pwd=$(echo "$config" | cut -d'|' -f2)
    local current_host=$(echo "$config" | cut -d'|' -f4)
    local service_file="/etc/systemd/system/$(get_stls_service_name $app)"

    echo "=========================================="
    case "$setting" in
        "port")
            echo "🔌 Modify Shadow-TLS Port ($app)"
            echo "Current: $current_port"
            local new_port=$(generate_safe_port)
            read -p "Enter new port [default: $new_port]: " input
            new_port=${input:-$new_port}
             if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                log_error "Invalid port!"
                return 1
            fi
            sed -i "s/--listen 0.0.0.0:${current_port}/--listen 0.0.0.0:${new_port}/" $service_file
            log_success "Port changed to $new_port"
            ;;
        "password")
            echo "🔐 Modify Shadow-TLS Password ($app)"
            echo "Current: $current_pwd"
            local new_pwd=$(generate_password)
            read -p "Enter new password [default: $new_pwd]: " input
            new_pwd=${input:-$new_pwd}
            local esc_old=$(escape_sed_replacement "$current_pwd")
            local esc_new=$(escape_sed_replacement "$new_pwd")
            sed -i "s|--password ${esc_old}|--password ${esc_new}|" $service_file
            log_success "Password changed."
            ;;
        "host")
            echo "🌐 Modify Shadow-TLS Host ($app)"
            echo "Current: $current_host"
            local new_host=$(select_shadowtls_host)
            sed -i "s|--tls ${current_host}:443|--tls ${new_host}:443|" $service_file
            log_success "Host changed to $new_host"
            ;;
    esac
    echo "=========================================="
    systemctl daemon-reload
    systemctl restart $(get_stls_service_name $app)
}

# --- Snell Shadow-TLS Wrappers ---
is_shadowtls_installed() { is_stls_installed "snell"; }
get_shadowtls_config() { get_stls_config "snell"; }
create_shadowtls_service() { create_stls_service "snell" "$@"; }
uninstall_shadowtls() { uninstall_stls_service "snell"; }
change_shadowtls_port() { modify_stls_setting "snell" "port"; }
change_shadowtls_password() { modify_stls_setting "snell" "password"; }
change_shadowtls_host() { modify_stls_setting "snell" "host"; }


# ==========================================
# ShadowSocks + Shadow-TLS 相关函数
# ==========================================

# --- 获取 Shadowsocks-Rust 最新版本 ---
get_ss_latest_version() {
    local version=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | \
        grep -oP '"tag_name": "v\K[0-9]+\.[0-9]+\.[0-9]+' || echo "1.23.5")
    echo "$version"
}

# --- 检查 SS 是否已安装 ---
is_ss_installed() {
    if [ -f /usr/local/bin/ssserver ] && [ -f /etc/shadowsocks-rust/config.json ]; then
        return 0
    else
        return 1
    fi
}

# --- 获取 SS 安装版本 ---
get_ss_installed_version() {
    if [ -f /usr/local/bin/ssserver ]; then
        # ssserver -V 输出格式: "shadowsocks 1.24.0"
        local version=$(/usr/local/bin/ssserver -V 2>&1 | grep -oP 'shadowsocks\s+\K[0-9]+\.[0-9]+\.[0-9]+' || echo "")
        echo "$version"
    else
        echo ""
    fi
}

# --- SS Shadow-TLS Wrappers ---
is_ss_shadowtls_installed() { is_stls_installed "ss"; }
get_ss_shadowtls_config() { get_stls_config "ss"; }

# --- 获取 SS 配置 ---
get_ss_config() {
    if [ ! -f /etc/shadowsocks-rust/config.json ]; then
        return 1
    fi
    
    local port=$(grep -oP '"server_port"\s*:\s*\K[0-9]+' /etc/shadowsocks-rust/config.json)
    local password=$(grep -oP '"password"\s*:\s*"\K[^"]+' /etc/shadowsocks-rust/config.json)
    local method=$(grep -oP '"method"\s*:\s*"\K[^"]+' /etc/shadowsocks-rust/config.json)
    
    echo "${port}|${password}|${method}"
}

# --- 选择 SS 加密方法 ---
select_ss_method() {
    local selected_method=""
    
    echo "🔒 Select encryption method:" >&2
    echo "  1) 2022-blake3-aes-128-gcm (recommended, 16-byte key)" >&2
    echo "  2) 2022-blake3-aes-256-gcm (32-byte key)" >&2
    echo "  3) 2022-blake3-chacha20-poly1305 (32-byte key)" >&2
    
    while true; do
        read -p "Enter your choice [1]: " method_choice
        method_choice=${method_choice:-1}
        case "$method_choice" in
            1)
                selected_method="2022-blake3-aes-128-gcm"
                break
                ;;
            2)
                selected_method="2022-blake3-aes-256-gcm"
                break
                ;;
            3)
                selected_method="2022-blake3-chacha20-poly1305"
                break
                ;;
            *)
                echo "Invalid choice. Please enter 1, 2, or 3." >&2
                ;;
        esac
    done
    
    echo "$selected_method"
}

# --- 生成 SS 密码 ---
generate_ss_password() {
    local method=$1
    local key_length=16
    
    case "$method" in
        "2022-blake3-aes-128-gcm")
            key_length=16
            ;;
        "2022-blake3-aes-256-gcm"|"2022-blake3-chacha20-poly1305")
            key_length=32
            ;;
    esac
    
    openssl rand -base64 $key_length
}

# --- 下载并安装 SS ---
download_and_install_ss() {
    local version=$1
    log_info "Downloading Shadowsocks-Rust v${version}..."
    
    local arch=$(uname -m)
    local download_url=""
    
    case "$arch" in
        x86_64)
            download_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${version}/shadowsocks-v${version}.x86_64-unknown-linux-gnu.tar.xz"
            ;;
        aarch64|arm64)
            download_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${version}/shadowsocks-v${version}.aarch64-unknown-linux-gnu.tar.xz"
            ;;
        *)
            log_error "Unsupported architecture ${arch}"
            return 1
            ;;
    esac
    
    if ! wget -O /tmp/shadowsocks.tar.xz "${download_url}"; then
        echo "Download failed. Please check your network connection."
        return 1
    fi
    
    # 解压并安装
    cd /tmp
    tar -xf shadowsocks.tar.xz
    mv ssserver /usr/local/bin/
    chmod +x /usr/local/bin/ssserver
    
    # 清理
    rm -f shadowsocks.tar.xz sslocal ssmanager ssservice ssurl
    
    echo "Shadowsocks-Rust v${version} installed successfully."
    return 0
}

# --- 配置 SS ---
configure_ss() {
    echo "=========================================="
    echo "⚙️  Please configure your ShadowSocks server:"
    echo "=========================================="
    
    # 显示已使用的端口
    local used_ports=$(get_used_ports)
    if [ -n "$used_ports" ]; then
        log_warn "Ports in use: ${used_ports}"
        echo ""
    fi
    
    # 选择加密方法
    echo ""
    ss_method=$(select_ss_method)
    echo "Selected method: ${ss_method}"
    
    # 生成不冲突的端口
    default_ss_port=$(generate_safe_port)
    read -p "Enter the ShadowSocks listening port [default: ${default_ss_port}]: " ss_port
    ss_port=${ss_port:-${default_ss_port}}
    
    # 生成密码
    default_ss_password=$(generate_ss_password "$ss_method")
    echo ""
    echo "Generated password for ${ss_method}: ${default_ss_password}"
    read -p "Use this password? [Y/n] (default: Y): " use_default_pwd
    use_default_pwd=${use_default_pwd:-Y}
    
    if [[ "$use_default_pwd" =~ ^[Yy]$ ]]; then
        ss_password="$default_ss_password"
    else
        read -p "Enter custom password (must be valid base64 with correct length): " ss_password
    fi
    
    # 询问是否使用 Shadow-TLS 混淆（默认开启）
    echo ""
    echo "🔐 Shadow-TLS v3 provides additional obfuscation for ShadowSocks."
    read -p "Enable Shadow-TLS? [Y/n] (default: Y): " enable_stls
    enable_stls=${enable_stls:-Y}
    
    # 标记是否使用 Shadow-TLS
    ss_use_shadowtls=false
    
    if [[ "$enable_stls" =~ ^[Yy]$ ]]; then
        ss_use_shadowtls=true
        
        echo ""
        echo "==========================================="
        echo "🔐 Configure Shadow-TLS for ShadowSocks:"
        echo "==========================================="
        
        # Shadow-TLS 端口（不与其他端口冲突）
        while true; do
            default_ss_stls_port=$(generate_safe_port)
            if [ "$default_ss_stls_port" != "$ss_port" ] && ! is_port_used "$default_ss_stls_port"; then
                break
            fi
        done
        
        read -p "Enter Shadow-TLS listening port [default: ${default_ss_stls_port}]: " ss_stls_port
        ss_stls_port=${ss_stls_port:-${default_ss_stls_port}}
        
        # Shadow-TLS 密码
        default_ss_stls_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
        read -p "Enter Shadow-TLS password [default: ${default_ss_stls_password}]: " ss_stls_password
        ss_stls_password=${ss_stls_password:-${default_ss_stls_password}}
        
        # 选择 TLS host
        echo ""
        ss_stls_host=$(select_shadowtls_host)
    fi
    
    # 创建配置目录
    mkdir -p /etc/shadowsocks-rust
    
    # 创建配置文件 - Shadow-TLS 开启时绑定 127.0.0.1，否则 [::] (IPv4 + IPv6)
    local ss_bind_addr="::"
    if $ss_use_shadowtls; then
        ss_bind_addr="127.0.0.1"
    fi
    
    cat >/etc/shadowsocks-rust/config.json <<EOF
{
    "server": "${ss_bind_addr}",
    "server_port": ${ss_port},
    "password": "${ss_password}",
    "timeout": 300,
    "method": "${ss_method}",
    "fast_open": false,
    "mode": "tcp_and_udp"
}
EOF
    
    echo ""
    echo "=========================================="
    echo "📋 Configuration Summary:"
    echo "ShadowSocks Port: ${ss_port}"
    echo "ShadowSocks Method: ${ss_method}"
    echo "ShadowSocks Password: ${ss_password}"
    if $ss_use_shadowtls; then
        echo "ShadowSocks Bind: ${ss_bind_addr} (via Shadow-TLS only)"
        echo "Shadow-TLS Port: ${ss_stls_port}"
        echo "Shadow-TLS Password: ${ss_stls_password}"
        echo "Shadow-TLS Host: ${ss_stls_host}"
    else
        echo "ShadowSocks Bind: ${ss_bind_addr} (public)"
    fi
    echo "=========================================="
}

# --- 创建 SS systemd 服务 ---
create_ss_service() {
    log_action "🔧 Creating systemd service for ShadowSocks..."
    cat >/usr/lib/systemd/system/shadowsocks-rust.service <<EOF
[Unit]
Description=Shadowsocks-Rust Proxy Service
After=network.target

[Service]
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks-rust/config.json
Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=ssserver
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
EOF

    log_info "Enabling and starting ShadowSocks service..."
    systemctl daemon-reload
    systemctl enable --now shadowsocks-rust.service
    
    echo "ShadowSocks service has been started."
    echo "Verifying service status..."
    systemctl status shadowsocks-rust.service --no-pager
}

# --- 创建 SS Shadow-TLS systemd 服务 ---
create_ss_shadowtls_service() { create_stls_service "ss" "$@"; }

# --- 卸载 SS ---
uninstall_ss() {
    echo "=========================================="
    log_action "🗑️  Uninstalling ShadowSocks server..."
    echo "=========================================="
    
    # 先卸载 Shadow-TLS
    if is_ss_shadowtls_installed; then
        uninstall_stls_service "ss"
    fi
    
    # 停止并禁用 SS 服务
    if systemctl is-active --quiet shadowsocks-rust.service; then
        echo "Stopping ShadowSocks service..."
        systemctl stop shadowsocks-rust.service
    fi
    
    if systemctl is-enabled --quiet shadowsocks-rust.service 2>/dev/null; then
        echo "Disabling ShadowSocks service..."
        systemctl disable shadowsocks-rust.service
    fi
    
    echo "Removing ShadowSocks files..."
    rm -f /usr/local/bin/ssserver
    rm -f /usr/lib/systemd/system/shadowsocks-rust.service
    rm -rf /etc/shadowsocks-rust
    
    systemctl daemon-reload
    
    echo "=========================================="
    log_success "ShadowSocks server has been completely removed."
    echo "=========================================="
}

# --- 显示 SS Surge 节点配置 ---
show_ss_surge_config() {
    echo "=========================================="
    echo "📱 ShadowSocks Surge Node Configuration"
    echo "=========================================="
    
    if ! is_ss_installed; then
        log_error "ShadowSocks is not installed!"
        return 1
    fi
    
    local ss_config=$(get_ss_config)
    local ss_port=$(echo "$ss_config" | cut -d'|' -f1)
    local ss_password=$(echo "$ss_config" | cut -d'|' -f2)
    local ss_method=$(echo "$ss_config" | cut -d'|' -f3)
    
    echo "Getting server IP address..."
    local ip=$(get_ipv4)
    
    if [ -z "$ip" ]; then
        log_error "Failed to get server IP address!"
        return 1
    fi
    
    echo ""
    echo "Copy the following node configuration to Surge:"
    echo "=========================================="
    
    if is_ss_shadowtls_installed; then
        local stls_config=$(get_ss_shadowtls_config)
        local stls_port=$(echo "$stls_config" | cut -d'|' -f1)
        local stls_password=$(echo "$stls_config" | cut -d'|' -f2)
        local stls_host=$(echo "$stls_config" | cut -d'|' -f4)
        echo "node_name = ss, ${ip}, ${stls_port}, encrypt-method=${ss_method}, password=${ss_password}, shadow-tls-password=${stls_password}, shadow-tls-sni=${stls_host}, shadow-tls-version=3"
    else
        echo "node_name = ss, ${ip}, ${ss_port}, encrypt-method=${ss_method}, password=${ss_password}"
    fi
    
    echo "=========================================="
}

# --- 修改 SS 端口 ---
change_ss_port() {
    echo "=========================================="
    echo "🔌 Modify ShadowSocks Port"
    echo "=========================================="
    
    if ! is_ss_installed; then
        log_error "ShadowSocks is not installed!"
        return 1
    fi
    
    local ss_config=$(get_ss_config)
    local current_port=$(echo "$ss_config" | cut -d'|' -f1)
    echo "Current ShadowSocks port: ${current_port}"
    
    local default_new_port=$((20000 + RANDOM % 45536))
    
    read -p "Enter new port number [default: ${default_new_port}]: " new_port
    new_port=${new_port:-${default_new_port}}
    
    if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        log_error "Invalid port number!"
        return 1
    fi
    
    # 更新配置文件
    sed -i "s/\"server_port\": ${current_port}/\"server_port\": ${new_port}/" /etc/shadowsocks-rust/config.json
    
    # 更新 Shadow-TLS 服务中的后端端口
    if is_ss_shadowtls_installed; then
        sed -i "s/--server 127.0.0.1:${current_port}/--server 127.0.0.1:${new_port}/" /etc/systemd/system/shadow-tls-ss.service
        systemctl daemon-reload
        systemctl restart shadow-tls-ss.service
    fi
    
    systemctl restart shadowsocks-rust.service
    
    echo "Port changed from ${current_port} to ${new_port}"
    echo "=========================================="
    log_success "ShadowSocks port modification completed!"
    echo "=========================================="
}

# --- 修改 SS 密码 ---
change_ss_password() {
    echo "=========================================="
    echo "🔐 Modify ShadowSocks Password"
    echo "=========================================="
    
    if ! is_ss_installed; then
        log_error "ShadowSocks is not installed!"
        return 1
    fi
    
    local ss_config=$(get_ss_config)
    local current_password=$(echo "$ss_config" | cut -d'|' -f2)
    local current_method=$(echo "$ss_config" | cut -d'|' -f3)
    echo "Current ShadowSocks password: ${current_password}"
    echo "Current encryption method: ${current_method}"
    
    local default_new_password=$(generate_ss_password "$current_method")
    
    echo ""
    echo "Generated new password: ${default_new_password}"
    read -p "Use this password? [Y/n] (default: Y): " use_default
    use_default=${use_default:-Y}
    
    if [[ "$use_default" =~ ^[Yy]$ ]]; then
        new_password="$default_new_password"
    else
        read -p "Enter custom password: " new_password
    fi
    
    local escaped_current=$(escape_sed_replacement "$current_password")
    local escaped_new=$(escape_sed_replacement "$new_password")
    sed -i "s|\"password\": \"${escaped_current}\"|\"password\": \"${escaped_new}\"|" /etc/shadowsocks-rust/config.json
    
    systemctl restart shadowsocks-rust.service
    
    echo "Password changed successfully!"
    echo "New password: ${new_password}"
    echo "=========================================="
    log_success "ShadowSocks password modification completed!"
    echo "=========================================="
}

# --- 修改 SS 加密方法 ---
change_ss_method() {
    echo "=========================================="
    echo "🔒 Modify ShadowSocks Encryption Method"
    echo "=========================================="
    
    if ! is_ss_installed; then
        log_error "ShadowSocks is not installed!"
        return 1
    fi
    
    local ss_config=$(get_ss_config)
    local current_method=$(echo "$ss_config" | cut -d'|' -f3)
    echo "Current encryption method: ${current_method}"
    echo ""
    
    new_method=$(select_ss_method)
    
    if [ "$new_method" = "$current_method" ]; then
        echo "Method unchanged."
        return 0
    fi
    
    # 生成新密码
    echo ""
    log_warn "Changing encryption method requires a new password."
    new_password=$(generate_ss_password "$new_method")
    echo "Generated new password for ${new_method}: ${new_password}"
    
    local old_password=$(echo "$ss_config" | cut -d'|' -f2)
    local escaped_old=$(escape_sed_replacement "$old_password")
    local escaped_new=$(escape_sed_replacement "$new_password")
    
    sed -i "s|\"method\": \"${current_method}\"|\"method\": \"${new_method}\"|" /etc/shadowsocks-rust/config.json
    sed -i "s|\"password\": \"${escaped_old}\"|\"password\": \"${escaped_new}\"|" /etc/shadowsocks-rust/config.json
    
    systemctl restart shadowsocks-rust.service
    
    echo ""
    echo "Method changed to: ${new_method}"
    echo "New password: ${new_password}"
    echo "=========================================="
    log_success "ShadowSocks encryption method modification completed!"
    echo "=========================================="
}

# --- 修改 SS Shadow-TLS 端口 ---
change_ss_shadowtls_port() {
    echo "=========================================="
    echo "🔌 Modify Shadow-TLS Port (ShadowSocks)"
    echo "=========================================="
    
    if ! is_ss_shadowtls_installed; then
        log_error "Shadow-TLS for ShadowSocks is not installed!"
        return 1
    fi
    
    local config=$(get_ss_shadowtls_config)
    local current_port=$(echo "$config" | cut -d'|' -f1)
    echo "Current Shadow-TLS port: ${current_port}"
    
    local default_new_port=$((20000 + RANDOM % 45536))
    
    read -p "Enter new port number [default: ${default_new_port}]: " new_port
    new_port=${new_port:-${default_new_port}}
    
    if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        log_error "Invalid port number!"
        return 1
    fi
    
    sed -i "s/--listen 0.0.0.0:${current_port}/--listen 0.0.0.0:${new_port}/" /etc/systemd/system/shadow-tls-ss.service
    
    systemctl daemon-reload
    systemctl restart shadow-tls-ss.service
    
    echo "Port changed from ${current_port} to ${new_port}"
    echo "=========================================="
    log_success "Shadow-TLS port modification completed!"
    echo "=========================================="
}

# --- 修改 SS Shadow-TLS 密码 ---
change_ss_shadowtls_password() {
    echo "=========================================="
    echo "🔐 Modify Shadow-TLS Password (ShadowSocks)"
    echo "=========================================="
    
    if ! is_ss_shadowtls_installed; then
        log_error "Shadow-TLS for ShadowSocks is not installed!"
        return 1
    fi
    
    local config=$(get_ss_shadowtls_config)
    local current_password=$(echo "$config" | cut -d'|' -f2)
    echo "Current Shadow-TLS password: ${current_password}"
    
    local default_new_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
    
    read -p "Enter new password [default: ${default_new_password}]: " new_password
    new_password=${new_password:-${default_new_password}}
    
    local escaped_current=$(escape_sed_replacement "$current_password")
    local escaped_new=$(escape_sed_replacement "$new_password")
    sed -i "s|--password ${escaped_current}|--password ${escaped_new}|" /etc/systemd/system/shadow-tls-ss.service
    
    systemctl daemon-reload
    systemctl restart shadow-tls-ss.service
    
    echo "Password changed successfully!"
    echo "New password: ${new_password}"
    echo "=========================================="
    log_success "Shadow-TLS password modification completed!"
    echo "=========================================="
}

# --- 修改 SS Shadow-TLS Host ---
change_ss_shadowtls_host() {
    echo "=========================================="
    echo "🌐 Modify Shadow-TLS Host (ShadowSocks)"
    echo "=========================================="
    
    if ! is_ss_shadowtls_installed; then
        log_error "Shadow-TLS for ShadowSocks is not installed!"
        return 1
    fi
    
    local config=$(get_ss_shadowtls_config)
    local current_host=$(echo "$config" | cut -d'|' -f4)
    echo "Current TLS host: ${current_host}"
    echo ""
    
    new_host=$(select_shadowtls_host)
    
    sed -i "s|--tls ${current_host}:443|--tls ${new_host}:443|" /etc/systemd/system/shadow-tls-ss.service
    
    systemctl daemon-reload
    systemctl restart shadow-tls-ss.service
    
    echo "TLS host changed to: ${new_host}"
    echo "=========================================="
    log_success "Shadow-TLS host modification completed!"
    echo "=========================================="
}

# --- SS 混淆管理菜单 ---
manage_ss_obfuscation() {
    while true; do
        clear
        echo "=========================================="
        echo "🔐 Manage ShadowSocks Obfuscation"
        echo "=========================================="
        
        local stls_installed=false
        if is_ss_shadowtls_installed; then
            stls_installed=true
            echo -e "Current status: ${GREEN}✓ Shadow-TLS Enabled${PLAIN}"
        else
            echo -e "Current status: ${GRAY}None (Plain ShadowSocks)${PLAIN}"
        fi
        
        echo ""
        echo "Options:"
        
        if $stls_installed; then
            echo "  1) 🚫 Disable Shadow-TLS"
            echo "  2) 🔌 Modify Shadow-TLS Port"
            echo "  3) 🔐 Modify Shadow-TLS Password"
            echo "  4) 🌐 Modify Shadow-TLS Host"
        else
            echo "  1) 🟢 Enable Shadow-TLS"
        fi
        
        echo "  0) 🔙 Back"
        echo " 00) 🚪 Exit Script"
        echo "=========================================="
        
        read -p "Enter your choice: " obfs_choice
        echo ""
        
        case "$obfs_choice" in
            1)
                if $stls_installed; then
                    # Disable Shadow-TLS
                    uninstall_stls_service "ss"
                    
                    # 修改 SS 监听地址为 [::] (公网)
                    # 读取当前 SS 端口
                    local ss_port=$(grep -oP '"server_port":\s*\K[0-9]+' /etc/shadowsocks-rust/config.json)
                    # 简单替换 server 字段
                    sed -i 's/"server":\s*"127.0.0.1"/"server": "::"/' /etc/shadowsocks-rust/config.json
                    
                    systemctl restart shadowsocks-rust.service
                    log_success "Shadow-TLS disabled. ShadowSocks is now accessible from public network."
                    pause
                else
                    # Enable Shadow-TLS
                    local ss_port=$(grep -oP '"server_port":\s*\K[0-9]+' /etc/shadowsocks-rust/config.json)
                    
                    # 生成默认参数
                    local default_stls_port=$(generate_safe_port)
                    local default_stls_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
                    
                    read -p "Shadow-TLS port [default: ${default_stls_port}]: " stls_port
                    stls_port=${stls_port:-$default_stls_port}
                    
                    read -p "Shadow-TLS password [default: ${default_stls_password}]: " stls_password
                    stls_password=${stls_password:-$default_stls_password}
                    
                    echo ""
                    local stls_host=$(select_shadowtls_host)
                    
                    echo ""
                    echo "Installing/Enabling Shadow-TLS..."
                    if download_and_install_shadowtls; then
                        create_ss_shadowtls_service "$stls_port" "$stls_password" "$ss_port" "$stls_host"
                        
                        # 修改 SS 监听地址为 127.0.0.1
                        sed -i 's/"server":\s*"::"/"server": "127.0.0.1"/' /etc/shadowsocks-rust/config.json
                        sed -i 's/"server":\s*"\[::\]"/"server": "127.0.0.1"/' /etc/shadowsocks-rust/config.json
                        sed -i 's/"server":\s*"0.0.0.0"/"server": "127.0.0.1"/' /etc/shadowsocks-rust/config.json
                        
                        systemctl restart shadowsocks-rust.service
                        log_success "Shadow-TLS enabled. ShadowSocks is now restricted to localhost."
                    fi
                    pause
                fi
                ;;
            2)
                $stls_installed && change_ss_shadowtls_port && pause
                ;;
            3)
                $stls_installed && change_ss_shadowtls_password && pause
                ;;
            4)
                $stls_installed && change_ss_shadowtls_host && pause
                ;;
            0)
                return 0
                ;;
            00)
                exit 0
                ;;
            *)
                echo "Invalid choice."
                ;;
        esac
    done
}

# --- 显示 SS 管理菜单 ---
show_ss_menu() {
    local installed_version=$1
    local latest_version=$2
    
    clear
    echo "=========================================="
    echo "🚀 ShadowSocks Server Management"
    echo "=========================================="
    echo "Current version: v${installed_version}"
    echo "Latest version:  v${latest_version}"
    
    # 检查服务状态
    local ss_running=false
    local stls_installed=false
    local stls_running=false
    
    systemctl is-active --quiet shadowsocks-rust.service && ss_running=true
    is_ss_shadowtls_installed && stls_installed=true
    $stls_installed && systemctl is-active --quiet shadow-tls-ss.service && stls_running=true
    
    # 显示 SS 服务状态
    if $ss_running; then
        echo -e "Service status:  ${GREEN}✓ Running${PLAIN}"
    else
        echo -e "Service status:  ${RED}✗ Stopped${PLAIN}"
    fi
    
    # 显示混淆状态
    if $stls_installed; then
        if $stls_running; then
            echo -e "ShadowSocks Obfuscation:     ${GREEN}✓ Shadow-TLS v3${PLAIN}"
        else
            echo -e "ShadowSocks Obfuscation:     ${RED}✗ Shadow-TLS (Stopped)${PLAIN}"
        fi
    else
        echo -e "ShadowSocks Obfuscation:     ${GRAY}None${PLAIN}"
    fi
    
    # 显示 Snell 状态（如果已安装）
    local snell_ver=$(get_installed_version)
    if [ -n "$snell_ver" ]; then
        if systemctl is-active --quiet snell.service; then
            echo -e "← Snell:           ${GREEN}✓ Running${PLAIN}"
        else
            echo -e "← Snell:           ${RED}✗ Stopped${PLAIN}"
        fi
    fi

    echo ""
    echo "Please select an option:"
    echo "  1) 🗑️  Uninstall ShadowSocks"
    echo "  2) 🔌 Modify Port"
    echo "  3) 🔐 Modify Password"
    echo "  4) 🔒 Modify Encryption Method"
    echo "  5) 🎭 Manage Obfuscation →"
    echo "  6) 🔄 Restart Service"
    echo "  7) 📋 Show Current Configuration"
    echo "  8) 📱 Show Surge Node Configuration"
    
    # Snell 共存选项
    echo ""
    if [ -n "$snell_ver" ]; then
        echo " 20) 💠 Manage Snell →"
    else
        echo " 20) 💠 Install Snell"
    fi
    
    echo "  0) 🔙 Back"
    echo " 00) 🚪 Exit Script"
    echo "=========================================="
}

# --- 显示 SS 当前配置 ---
show_ss_config() {
    echo "=========================================="
    echo "📋 Current ShadowSocks Configuration"
    echo "=========================================="
    
    if [ ! -f /etc/shadowsocks-rust/config.json ]; then
        log_error "Configuration file not found!"
        return 1
    fi
    
    local ss_port=$(grep -oP '"server_port"\s*:\s*\K[0-9]+' /etc/shadowsocks-rust/config.json)
    local ss_password=$(grep -oP '"password"\s*:\s*"\K[^"]+' /etc/shadowsocks-rust/config.json)
    local ss_method=$(grep -oP '"method"\s*:\s*"\K[^"]+' /etc/shadowsocks-rust/config.json)
    local ip=$(get_ipv4)
    
    echo "IP:        ${ip}"
    echo "Port:      $ss_port"
    echo "Method:    $ss_method"
    echo "Password:  $ss_password"
    
    if is_ss_shadowtls_installed; then
        local config=$(get_ss_shadowtls_config)
        local stls_port=$(echo "$config" | cut -d'|' -f1)
        local stls_password=$(echo "$config" | cut -d'|' -f2)
        local stls_host=$(echo "$config" | cut -d'|' -f4)
        
        echo "Obfs:      Shadow-TLS v3"
        echo "           ├─ Port:     $stls_port"
        echo "           ├─ Password: $stls_password"
        echo "           └─ Host:     $stls_host"
    else
        echo "Obfs:      None"
    fi
    
    echo "=========================================="
}

# --- 8. 修改端口 ---
change_port() {
    echo "=========================================="
    echo "🔌 Modify Snell Server Port"
    echo "=========================================="
    
    if [ ! -f /etc/snell/snell-server.conf ]; then
        log_error "Configuration file not found!"
        return 1
    fi
    
    # 获取当前监听地址和端口（支持 [::] 和 127.0.0.1）
    local listen_line=$(grep -oP 'listen = \K.+' /etc/snell/snell-server.conf)
    local current_port=$(echo "$listen_line" | grep -oP ':\K[0-9]+$')
    local current_bind=$(echo "$listen_line" | sed "s/:${current_port}$//")
    
    echo "Current: ${listen_line}"
    
    # 生成 20000-65535 之间的随机端口
    local default_new_port=$((20000 + RANDOM % 45536))
    
    read -p "Enter new port number [default: ${default_new_port}]: " new_port
    new_port=${new_port:-${default_new_port}}
    
    if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        log_error "Invalid port number!"
        return 1
    fi
    
    sed -i "s|listen = ${current_bind}:${current_port}|listen = ${current_bind}:${new_port}|" /etc/snell/snell-server.conf
    
    echo "Port changed from ${current_port} to ${new_port}"
    echo "Restarting Snell service..."
    systemctl restart snell.service
    
    echo "=========================================="
    log_success "Port modification completed!"
    echo "========================================"
}

# --- 9. 修改密码 ---
change_password() {
    echo "=========================================="
    echo "🔐 Modify Snell Server Password (PSK)"
    echo "=========================================="
    
    if [ ! -f /etc/snell/snell-server.conf ]; then
        log_error "Configuration file not found!"
        return 1
    fi
    
    local current_psk=$(grep -oP 'psk = \K.+' /etc/snell/snell-server.conf)
    echo "Current PSK: ${current_psk}"
    
    local default_new_psk=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
    
    read -p "Enter new password [default: ${default_new_psk}]: " new_psk
    new_psk=${new_psk:-${default_new_psk}}
    
    local escaped_new_psk=$(escape_sed_replacement "$new_psk")
    sed -i "s|^psk = .*|psk = ${escaped_new_psk}|" /etc/snell/snell-server.conf
    
    echo "Password changed successfully!"
    echo "New PSK: ${new_psk}"
    echo "Restarting Snell service..."
    systemctl restart snell.service
    
    echo "=========================================="
    log_success "Password modification completed!"
    echo "========================================"
}

# --- 10. 管理混淆子菜单 ---
manage_obfuscation() {
    while true; do
        clear
        echo "=========================================="
        echo "🎭 Manage Snell Obfuscation"
        echo "=========================================="
        
        if [ ! -f /etc/snell/snell-server.conf ]; then
            log_error "Configuration file not found!"
            return 1
        fi
        
        # 检测当前模式
        local current_obfs=$(grep -oP '^obfs\s*=\s*\K.+' /etc/snell/snell-server.conf 2>/dev/null || echo "")
        local current_mode="none"
        
        if is_shadowtls_installed; then
            current_mode="shadowtls"
            local stls_config=$(get_shadowtls_config)
            local stls_port=$(echo "$stls_config" | cut -d'|' -f1)
            local stls_host=$(echo "$stls_config" | cut -d'|' -f4)
            echo -e "Current mode: ${GREEN}Shadow-TLS v3${PLAIN}"
            echo "  Port: ${stls_port}"
            echo "  Host: ${stls_host}"
        elif [ "$current_obfs" = "http" ]; then
            current_mode="http"
            local current_host=$(grep -oP '^host\s*=\s*\K.+' /etc/snell/snell-server.conf 2>/dev/null || echo "")
            echo -e "Current mode: ${CYAN}obfs http${PLAIN}"
            echo "  Host: ${current_host}"
        else
            echo -e "Current mode: ${GRAY}None${PLAIN}"
        fi
        
        echo ""
        echo "Options:"
        echo "  1) 🔄 Switch Obfuscation Mode"
        
        if [ "$current_mode" = "shadowtls" ]; then
            echo "  2) 🔌 Modify Shadow-TLS Port"
            echo "  3) 🔐 Modify Shadow-TLS Password"
            echo "  4) 🌐 Modify Shadow-TLS Host"
        elif [ "$current_mode" = "http" ]; then
            echo "  2) 🌐 Modify obfs Host"
        fi
        
        echo "  0) 🔙 Back"
        echo " 00) 🚪 Exit Script"
        echo "=========================================="
        
        read -p "Enter your choice: " obfs_choice
        echo ""
        
        case "$obfs_choice" in
            1)
                switch_obfuscation_mode
                ;;
            2)
                if [ "$current_mode" = "shadowtls" ]; then
                    change_shadowtls_port
                elif [ "$current_mode" = "http" ]; then
                    change_obfs_host
                fi
                ;;
            3)
                [ "$current_mode" = "shadowtls" ] && change_shadowtls_password
                ;;
            4)
                [ "$current_mode" = "shadowtls" ] && change_shadowtls_host
                ;;
            0)
                return 0
                ;;
            00)
                exit 0
                ;;
            *)
                echo "Invalid choice."
                ;;
        esac
        echo ""
        pause
    done
}

# --- 切换混淆模式 ---
switch_obfuscation_mode() {
    echo "=========================================="
    echo "🔄 Switch Obfuscation Mode"
    echo "=========================================="
    
    # 检测当前模式
    local current_obfs=$(grep -oP '^obfs\s*=\s*\K.+' /etc/snell/snell-server.conf 2>/dev/null || echo "")
    local current_mode="none"
    
    if is_shadowtls_installed; then
        current_mode="shadowtls"
        echo "Current: Shadow-TLS v3"
    elif [ "$current_obfs" = "http" ]; then
        current_mode="http"
        echo "Current: obfs http"
    else
        echo "Current: None"
    fi
    
    echo ""
    echo "Select new mode:"
    echo "  1) 🚫 No obfuscation"
    echo "  2) 🌐 obfs http"
    echo "  3) 🔐 Shadow-TLS v3"
    echo "  0) 🔙 Cancel"
    
    read -p "Enter your choice [0-3]: " mode_choice
    
    case "$mode_choice" in
        1)
            if [ "$current_mode" = "shadowtls" ]; then
                echo "Uninstalling Shadow-TLS..."
                uninstall_shadowtls
                local snell_port=$(grep -oP 'listen = [^:]+:\K[0-9]+' /etc/snell/snell-server.conf)
                sed -i "s/listen = 127.0.0.1:${snell_port}/listen = [::]:${snell_port}/" /etc/snell/snell-server.conf
            elif [ "$current_mode" = "http" ]; then
                sed -i '/^obfs\s*=/d' /etc/snell/snell-server.conf
                sed -i '/^host\s*=/d' /etc/snell/snell-server.conf
            fi
            systemctl restart snell.service
            log_success "Obfuscation disabled!"
            ;;
        2)
            if [ "$current_mode" = "shadowtls" ]; then
                echo "Uninstalling Shadow-TLS first..."
                uninstall_shadowtls
                local snell_port=$(grep -oP 'listen = [^:]+:\K[0-9]+' /etc/snell/snell-server.conf)
                sed -i "s/listen = 127.0.0.1:${snell_port}/listen = [::]:${snell_port}/" /etc/snell/snell-server.conf
            fi
            sed -i '/^obfs\s*=/d' /etc/snell/snell-server.conf
            sed -i '/^host\s*=/d' /etc/snell/snell-server.conf
            
            echo ""
            new_host=$(select_obfs_host)
            sed -i "/^dns\s*=/a obfs = http" /etc/snell/snell-server.conf
            sed -i "/^obfs\s*=/a host = ${new_host}" /etc/snell/snell-server.conf
            
            systemctl restart snell.service
            log_success "Switched to obfs http!"
            ;;
        3)
            if [ "$current_mode" = "http" ]; then
                sed -i '/^obfs\s*=/d' /etc/snell/snell-server.conf
                sed -i '/^host\s*=/d' /etc/snell/snell-server.conf
            fi
            
            if [ "$current_mode" = "shadowtls" ]; then
                echo "Already using Shadow-TLS."
                return 0
            fi
            
            local snell_port=$(grep -oP 'listen = [^:]+:\K[0-9]+' /etc/snell/snell-server.conf)
            local stls_port=$(generate_safe_port)
            local stls_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
            
            echo ""
            read -p "Shadow-TLS port [default: ${stls_port}]: " input_port
            stls_port=${input_port:-$stls_port}
            
            read -p "Shadow-TLS password [default: ${stls_password}]: " input_pwd
            stls_password=${input_pwd:-$stls_password}
            
            echo ""
            stls_host=$(select_shadowtls_host)
            
            echo ""
            echo "Installing Shadow-TLS..."
            if download_and_install_shadowtls; then
                create_shadowtls_service "$stls_port" "$stls_password" "$snell_port" "$stls_host"
                sed -i "s/listen = \[::\]:${snell_port}/listen = 127.0.0.1:${snell_port}/" /etc/snell/snell-server.conf
                systemctl restart snell.service
                log_success "Switched to Shadow-TLS v3!"
            else
                echo "❌ Shadow-TLS installation failed!"
            fi
            ;;
        0)
            echo "Cancelled."
            ;;
        *)
            echo "Invalid choice."
            ;;
    esac
}

# --- 修改 obfs http host ---
change_obfs_host() {
    echo "=========================================="
    echo "🌐 Modify obfs HTTP Host"
    echo "=========================================="
    
    local current_host=$(grep -oP '^host\s*=\s*\K.+' /etc/snell/snell-server.conf 2>/dev/null || echo "")
    echo "Current host: ${current_host}"
    echo ""
    
    new_host=$(select_obfs_host)
    
    sed -i "s|^host\s*=.*|host = ${new_host}|" /etc/snell/snell-server.conf
    
    echo "Restarting Snell service..."
    systemctl restart snell.service
    log_success "obfs host changed to: ${new_host}"
}

# --- 11. 修改 DNS ---
change_dns() {
    echo "=========================================="
    echo "🌐 Modify Snell Server DNS Settings"
    echo "=========================================="
    
    if [ ! -f /etc/snell/snell-server.conf ]; then
        log_error "Configuration file not found!"
        return 1
    fi
    
    local current_dns=$(grep -oP 'dns = \K.+' /etc/snell/snell-server.conf)
    echo "Current DNS: ${current_dns}"
    echo ""
    
    local dns_result
    dns_result=$(select_dns true 0)
    if [ $? -ne 0 ]; then
        echo "Cancelled."
        return 0
    fi
    
    local new_dns=$(echo "$dns_result" | cut -d'|' -f1)
    local dns_label=$(echo "$dns_result" | cut -d'|' -f2)
    
    sed -i "s|dns = ${current_dns}|dns = ${new_dns}|" /etc/snell/snell-server.conf
    
    echo "DNS changed to: ${new_dns} (${dns_label})"
    echo "Restarting Snell service..."
    systemctl restart snell.service
    
    echo "=========================================="
    log_success "DNS modification completed!"
    echo "========================================"
}

# --- 12. 显示 Surge 节点配置 ---
show_surge_config() {
    echo "=========================================="
    echo "📱 Surge Node Configuration"
    echo "=========================================="
    
    if [ ! -f /etc/snell/snell-server.conf ]; then
        log_error "Configuration file not found!"
        return 1
    fi
    
    # 获取 Snell 配置，支持 0.0.0.0 和 127.0.0.1
    local listen_line=$(grep -oP 'listen = \K.+' /etc/snell/snell-server.conf)
    local snell_port=$(echo "$listen_line" | grep -oP ':\K[0-9]+')
    local psk=$(grep -oP 'psk = \K.+' /etc/snell/snell-server.conf)
    local obfs=$(grep -oP 'obfs = \K.+' /etc/snell/snell-server.conf || echo "")
    local host=$(grep -oP 'host = \K.+' /etc/snell/snell-server.conf || echo "")
    
    echo "Getting server IP address..."
    local ip=$(get_ipv4)
    
    if [ -z "$ip" ]; then
        log_error "Failed to get server IP address!"
        return 1
    fi
    
    echo ""
    echo "Copy the following node configuration to Surge:"
    echo "=========================================="
    
    # 检查是否使用 Shadow-TLS
    if is_shadowtls_installed; then
        local stls_config=$(get_shadowtls_config)
        local stls_port=$(echo "$stls_config" | cut -d'|' -f1)
        local stls_password=$(echo "$stls_config" | cut -d'|' -f2)
        local stls_host=$(echo "$stls_config" | cut -d'|' -f4)
        
        echo "📍 Snell Configuration:"
        echo "node_name = snell, ${ip}, ${stls_port}, psk=${psk}, version=5, reuse=true, shadow-tls-password=${stls_password}, shadow-tls-sni=${stls_host}, shadow-tls-version=3"
        echo ""
        echo "=========================================="
        
        # 如果 Snell 也可直接访问，显示直连配置
        if [[ "$listen_line" == "[::]:"* ]]; then
            echo ""
            echo "📍 Direct Connection (without Shadow-TLS):"
            if [[ -n "$obfs" && -n "$host" ]]; then
                echo "node_name = snell, ${ip}, ${snell_port}, psk=${psk}, obfs=${obfs}, obfs-host=${host}, version=5, reuse=true"
            else
                echo "node_name = snell, ${ip}, ${snell_port}, psk=${psk}, version=5, reuse=true"
            fi
            echo "========================================"
        fi
    elif [[ -n "$obfs" && -n "$host" ]]; then
        echo "node_name = snell, ${ip}, ${snell_port}, psk=${psk}, obfs=${obfs}, obfs-host=${host}, version=5, reuse=true"
    else
        echo "node_name = snell, ${ip}, ${snell_port}, psk=${psk}, version=5, reuse=true"
    fi
    
    echo "========================================"
}

# --- 13. 查看当前配置 ---
show_config() {
    echo "=========================================="
    echo "📋 Current Snell Configuration"
    echo "=========================================="
    
    if [ ! -f /etc/snell/snell-server.conf ]; then
        log_error "Configuration file not found!"
        return 1
    fi
    
    local listen=$(grep -oP 'listen = \K.+' /etc/snell/snell-server.conf)
    local port=$(echo "$listen" | grep -oP ':\K[0-9]+$')
    local psk=$(grep -oP 'psk = \K.+' /etc/snell/snell-server.conf)
    local ipv6=$(grep -oP 'ipv6 = \K.+' /etc/snell/snell-server.conf)
    local dns=$(grep -oP 'dns = \K.+' /etc/snell/snell-server.conf)
    local obfs=$(grep -oP 'obfs = \K.+' /etc/snell/snell-server.conf)
    local host=$(grep -oP 'host = \K.+' /etc/snell/snell-server.conf)
    local ip=$(get_ipv4)
    
    echo "IP:        ${ip}"
    echo "Port:      ${port}"
    echo "PSK:       $psk"
    echo "IPv6:      ${ipv6:-false}"
    echo "DNS:       ${dns:-Default}"
    
    if is_shadowtls_installed; then
        local stls_config=$(get_shadowtls_config)
        local stls_port=$(echo "$stls_config" | cut -d'|' -f1)
        local stls_password=$(echo "$stls_config" | cut -d'|' -f2)
        local stls_host=$(echo "$stls_config" | cut -d'|' -f4)
        
        echo "Obfs:      Shadow-TLS v3"
        echo "           ├─ Port:     $stls_port"
        echo "           ├─ Password: $stls_password"
        echo "           └─ Host:     $stls_host"
    elif [ "$obfs" == "http" ]; then
        echo "Obfs:      http"
        echo "           └─ Host:     $host"
    else
        echo "Obfs:      None"
    fi
     
    echo "========================================"
}

# --- 14. 已安装菜单 ---
show_installed_menu() {
    local installed_version=$1
    local latest_version=$2
    
    # 检测当前混淆模式
    local current_obfs=""
    if [ -f /etc/snell/snell-server.conf ]; then
        current_obfs=$(grep -oP '^obfs\s*=\s*\K.+' /etc/snell/snell-server.conf 2>/dev/null)
    fi
    local using_shadowtls=false
    local using_obfs_http=false
    
    if is_shadowtls_installed; then
        using_shadowtls=true
    elif [ "$current_obfs" = "http" ]; then
        using_obfs_http=true
    fi
    
    clear
    echo "=========================================="
    echo "🚀 Snell Server Management"
    echo "=========================================="
    echo "Current version: v${installed_version}"
    echo "Latest version:  v${latest_version}"
    
    if systemctl is-active --quiet snell.service; then
        echo -e "Service status:  ${GREEN}✓ Running${PLAIN}"
    else
        echo -e "Service status:  ${RED}✗ Stopped${PLAIN}"
    fi
    
    # 显示混淆状态
    if $using_shadowtls; then
        if systemctl is-active --quiet shadow-tls-snell.service; then
            echo -e "Snell Obfuscation:     ${GREEN}✓ Shadow-TLS v3${PLAIN}"
        else
            echo -e "Snell Obfuscation:     ${RED}✗ Shadow-TLS (Stopped)${PLAIN}"
        fi
    elif $using_obfs_http; then
        echo -e "Snell Obfuscation:     ${CYAN}obfs http${PLAIN}"
    else
        echo -e "Snell Obfuscation:     ${GRAY}None${PLAIN}"
    fi
    
    # 显示 SS 状态（如果已安装）
    if is_ss_installed; then
        if systemctl is-active --quiet shadowsocks-rust.service; then
            echo -e "← ShadowSocks:     ${GREEN}✓ Running${PLAIN}"
        else
            echo -e "← ShadowSocks:     ${RED}✗ Stopped${PLAIN}"
        fi
    fi

    echo ""
    echo "Please select an option:"
    echo "  1) 🗑️  Uninstall Snell"
    echo "  2) 🔌 Modify Port"
    echo "  3) 🔐 Modify Password"
    echo "  4) 🌐 Modify DNS"
    echo "  5) 🎭 Manage Obfuscation →"
    echo "  6) 🔄 Restart Service"
    echo "  7) 📋 Show Current Configuration"
    echo "  8) 📱 Show Surge Node Configuration"
    
    # SS 共存选项
    echo ""
    if is_ss_installed; then
        echo " 20) 👻 Manage ShadowSocks →"
    else
        echo " 20) 👻 Install ShadowSocks + Shadow-TLS"
    fi
    
    echo "  0) 🔙 Back"
    echo " 00) 🚪 Exit Script"
    echo "========================================"
}

# --- 16. Snell 菜单处理函数 (可复用) ---
handle_snell_menu() {
    local snell_installed_version=$(get_installed_version)
    local snell_latest_version=$1
    local snell_arch=$2
    local ss_latest_version=$3
    
    while true; do
        show_installed_menu "$snell_installed_version" "$snell_latest_version"
        
        read -p "Enter your choice: " choice
        echo ""
        
        case "$choice" in
            1)
                echo "Are you sure? Type 'yes' to confirm:"
                read confirm
                if [ "$confirm" = "yes" ]; then
                    uninstall_snell
                    return 1  # 返回 1 表示已卸载
                fi
                ;;
            2) change_port; pause ;;
            3) change_password; pause ;;
            4) change_dns; pause ;;
            5) manage_obfuscation ;;
            6)
                systemctl restart snell.service
                is_shadowtls_installed && systemctl restart shadow-tls-snell.service
                echo "Services restarted."
                pause
                ;;
            7) show_config; pause ;;
            8) show_surge_config; pause ;;
            20)
                # 安装或管理 SS (嵌套)
                if is_ss_installed; then
                    handle_ss_menu "$ss_latest_version" "$snell_latest_version" "$snell_arch"
                else
                    install_ss_new "$ss_latest_version"
                fi
                ;;
            0) return 0 ;;  # 返回上级菜单
            00) exit 0 ;;
            *) echo "Invalid choice." ;;
        esac
    done
}

# --- 17. SS 菜单处理函数 (可复用) ---
handle_ss_menu() {
    local ss_installed_version=$(get_ss_installed_version)
    local ss_latest_version=$1
    local snell_latest_version=$2
    local snell_arch=$3
    
    while true; do
        show_ss_menu "$ss_installed_version" "$ss_latest_version"
        
        read -p "Enter your choice: " choice
        echo ""
        
        case "$choice" in
            1)
                echo "Type 'yes' to confirm:"
                read confirm
                if [ "$confirm" = "yes" ]; then
                    uninstall_ss
                    return 1  # 返回 1 表示已卸载
                fi
                ;;
            2) change_ss_port; pause ;;
            3) change_ss_password; pause ;;
            4) change_ss_method; pause ;;
            5) manage_ss_obfuscation ;;
            6)
                systemctl restart shadowsocks-rust.service
                is_ss_shadowtls_installed && systemctl restart shadow-tls-ss.service
                echo "Services restarted."
                pause
                ;;
            7) show_ss_config; pause ;;
            8) show_ss_surge_config; pause ;;
            20)
                # 管理或安装 Snell (嵌套)
                snell_ver=$(get_installed_version)
                if [ -n "$snell_ver" ]; then
                    handle_snell_menu "$snell_latest_version" "$snell_arch" "$ss_latest_version"
                else
                    install_snell_new "$snell_latest_version" "$snell_arch"
                fi
                ;;
            0) return 0 ;;  # 返回上级菜单
            00) exit 0 ;;
            *) echo "Invalid choice." ;;
        esac
    done
}

# --- 18. 安装新 Snell ---
install_snell_new() {
    local snell_latest_version=$1
    local snell_arch=$2
    
    echo "Starting Snell installation..."
    echo "Detected architecture: $(uname -m) (using ${snell_arch} binary)"
    
    if download_and_install_snell "$snell_latest_version" "$snell_arch"; then
        configure_snell
        create_systemd_service
        
        if [[ "$obfs_mode" == "shadowtls" ]]; then
            echo ""
            echo "🔐 Installing Shadow-TLS v3..."
            if download_and_install_shadowtls; then
                create_shadowtls_service "$stls_port" "$stls_password" "$port" "$stls_host"
                
                # 自动将 Snell 绑定到 localhost
                sed -i "s/listen = \[::\]:${port}/listen = 127.0.0.1:${port}/" /etc/snell/snell-server.conf
                systemctl restart snell.service
                log_success "Snell restricted to localhost (via Shadow-TLS only)."
            fi
        fi
        
        echo ""
        log_success "Snell server installation complete!"
        show_surge_config
    else
        echo "Installation failed."
    fi
    pause
}

# --- 19. 安装新 SS ---
install_ss_new() {
    local ss_latest_version=$1
    
    echo "Starting ShadowSocks installation..."
    
    if download_and_install_ss "$ss_latest_version"; then
        configure_ss
        create_ss_service
        
        if $ss_use_shadowtls; then
            echo ""
            echo "🔐 Installing Shadow-TLS v3..."
            if download_and_install_shadowtls; then
                create_ss_shadowtls_service "$ss_stls_port" "$ss_stls_password" "$ss_port" "$ss_stls_host"
            fi
        fi
        
        echo ""
        log_success "ShadowSocks installation complete!"
        show_ss_surge_config
    else
        echo "Installation failed."
    fi
    pause
}

# --- 20. 主选择菜单 ---
show_main_selection_menu() {
    local snell_version=$1
    local ss_version=$2
    
    # 获取已安装版本
    local snell_installed=$(get_installed_version)
    local ss_installed=$(get_ss_installed_version)
    
    clear
    echo "=========================================="
    echo "🚀 Proxy Server Management"
    echo "=========================================="
    
    # Snell 状态
    if [ -n "$snell_installed" ]; then
        if [ "$snell_installed" = "$snell_version" ]; then
            echo -e "Snell:       ${GREEN}✓ v${snell_installed}${PLAIN} (latest)"
        else
            echo -e "Snell:       ${GREEN}✓ v${snell_installed}${PLAIN} → ${YELLOW}v${snell_version} update available${PLAIN}"
        fi
        
        # Snell 混淆状态
        local snell_obfs_status=""
        local snell_current_obfs=$(grep -oP '^obfs\s*=\s*\K.+' /etc/snell/snell-server.conf 2>/dev/null)
        if is_shadowtls_installed; then
             if systemctl is-active --quiet shadow-tls-snell.service; then
                 snell_obfs_status="${GREEN}Shadow-TLS v3${PLAIN}"
             else
                 snell_obfs_status="${RED}Shadow-TLS (Stopped)${PLAIN}"
             fi
        elif [ "$snell_current_obfs" = "http" ]; then
             snell_obfs_status="${CYAN}obfs http${PLAIN}"
        else
             snell_obfs_status="${GRAY}None${PLAIN}"
        fi
        echo -e "  └─ Obfuscation: ${snell_obfs_status}"

    else
        echo -e "Snell:       ${RED}✗ Not installed${PLAIN}  Latest: ${GREEN}v${snell_version}${PLAIN}"
    fi
    
    # ShadowSocks 状态
    if [ -n "$ss_installed" ]; then
        if [ "$ss_installed" = "$ss_version" ]; then
            echo -e "ShadowSocks: ${GREEN}✓ v${ss_installed}${PLAIN} (latest)"
        else
            echo -e "ShadowSocks: ${GREEN}✓ v${ss_installed}${PLAIN} → ${YELLOW}v${ss_version} update available${PLAIN}"
        fi
        
        # ShadowSocks 混淆状态
        local ss_obfs_status=""
        if is_ss_shadowtls_installed; then
             if systemctl is-active --quiet shadow-tls-ss.service; then
                 ss_obfs_status="${GREEN}Shadow-TLS v3${PLAIN}"
             else
                 ss_obfs_status="${RED}Shadow-TLS (Stopped)${PLAIN}"
             fi
        else
             ss_obfs_status="${GRAY}None${PLAIN}"
        fi
        echo -e "  └─ Obfuscation: ${ss_obfs_status}"

    else
        echo -e "ShadowSocks: ${RED}✗ Not installed${PLAIN}  Latest: ${GREEN}v${ss_version}${PLAIN}"
    fi
    
    echo ""
    echo "Select the service to manage:"
    echo "  1) 💠 Snell"
    echo "  2) 👻 ShadowSocks"
    echo "  0) 🚪 Exit"
    echo "=========================================="
}

# --- 获取 Shadow-TLS 最新版本 ---
get_shadowtls_latest_version() {
    local version=$(curl -s https://api.github.com/repos/ihciah/shadow-tls/releases/latest | \
        grep -oP '"tag_name": "v\K[0-9]+\.[0-9]+\.[0-9]+' || echo "0.3.0")
    echo "$version"
}

# --- 获取 Shadow-TLS 当前版本 ---
get_shadowtls_installed_version() {
    if [ -f /usr/local/bin/shadow-tls ]; then
        local version=$(/usr/local/bin/shadow-tls --version 2>&1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
        echo "$version"
    else
        echo ""
    fi
}

# --- 自动更新所有组件 ---
auto_update_all() {
    local snell_latest=$1
    local ss_latest=$2
    local stls_latest=$3
    local snell_arch=$4
    local updated=false
    
    echo "=========================================="
    log_action "🔍 Checking for updates..."
    echo "=========================================="
    
    # 检查 Snell 更新
    local snell_current=$(get_installed_version)
    if [ -n "$snell_current" ] && [ "$snell_current" != "$snell_latest" ]; then
        log_action "📦 Snell: v${snell_current} → v${snell_latest}"
        echo "   Updating Snell..."
        if download_and_install_snell "$snell_latest" "$snell_arch"; then
            systemctl restart snell.service
            echo "   ✅ Snell updated!"
            updated=true
        fi
    elif [ -n "$snell_current" ]; then
        log_action "📦 Snell: v${snell_current} (latest)"
    fi
    
    # 检查 ShadowSocks 更新
    local ss_current=$(get_ss_installed_version)
    if [ -n "$ss_current" ] && [ "$ss_current" != "$ss_latest" ]; then
        log_action "📦 ShadowSocks: v${ss_current} → v${ss_latest}"
        echo "   Updating ShadowSocks..."
        if download_and_install_ss "$ss_latest"; then
            systemctl restart shadowsocks-rust.service
            echo "   ✅ ShadowSocks updated!"
            updated=true
        fi
    elif [ -n "$ss_current" ]; then
        log_action "📦 ShadowSocks: v${ss_current} (latest)"
    fi
    
    # 检查 Shadow-TLS 更新
    local stls_current=$(get_shadowtls_installed_version)
    if [ -n "$stls_current" ] && [ "$stls_current" != "$stls_latest" ]; then
        log_action "📦 Shadow-TLS: v${stls_current} → v${stls_latest}"
        echo "   Updating Shadow-TLS..."
        if download_and_install_shadowtls; then
            # 重启使用 Shadow-TLS 的服务
            is_shadowtls_installed && systemctl restart shadow-tls-snell.service
            is_ss_shadowtls_installed && systemctl restart shadow-tls-ss.service
            echo "   ✅ Shadow-TLS updated!"
            updated=true
        fi
    elif [ -n "$stls_current" ]; then
        log_action "📦 Shadow-TLS: v${stls_current} (latest)"
    fi
    
    # 检查是否有任何组件已安装
    local any_installed=false
    if [ -n "$snell_current" ] || [ -n "$ss_current" ] || [ -n "$stls_current" ]; then
        any_installed=true
    fi

    if $updated; then
        echo ""
        log_success "All updates completed!"
    elif $any_installed; then
        echo ""
        log_success "All components are up to date."
    else
        echo ""
        echo "ℹ️  No components installed yet."
    fi
    echo "=========================================="
    echo ""
    sleep 2
}

# ==========================================
# 主程序流程
# ==========================================

clear
snell_arch=$(detect_architecture)
if [ "$snell_arch" = "unsupported" ]; then
    log_error "Unsupported architecture $(uname -m)"
    echo "This script only supports x86_64 (amd64) and aarch64 architectures."
    exit 1
fi

install_dependencies

# 获取版本信息
snell_latest_version=$(get_latest_version)
ss_latest_version=$(get_ss_latest_version)
stls_latest_version=$(get_shadowtls_latest_version)

# 自动更新已安装的组件
auto_update_all "$snell_latest_version" "$ss_latest_version" "$stls_latest_version" "$snell_arch"

# 主循环 - 始终显示主选择菜单
while true; do
    show_main_selection_menu "$snell_latest_version" "$ss_latest_version"
    
    read -p "Enter your choice [0-2]: " main_choice
    echo ""
    
    case "$main_choice" in
        1)
            # Snell 管理
            if [ -n "$(get_installed_version)" ]; then
                handle_snell_menu "$snell_latest_version" "$snell_arch" "$ss_latest_version"
            else
                install_snell_new "$snell_latest_version" "$snell_arch"
            fi
            ;;
        2)
            # ShadowSocks 管理
            if is_ss_installed; then
                handle_ss_menu "$ss_latest_version" "$snell_latest_version" "$snell_arch"
            else
                install_ss_new "$ss_latest_version"
            fi
            ;;
        0)
            exit 0
            ;;
        *)
            echo "Invalid choice. Please enter 0, 1, or 2."
            pause
            ;;
    esac
done
