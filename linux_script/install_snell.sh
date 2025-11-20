#!/bin/bash

set -e
if [ "$EUID" -ne 0 ]; then
    echo "Error: 请使用 root 权限运行此脚本 (sudo ./install_snell.sh)"
    exit 1
fi

# --- 工具函数：转义 sed 替换字符串 ---
escape_sed_replacement() {
    # 依次转义反斜杠、斜杠、管道和 &，避免写入配置时破坏格式
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's|/|\/|g' -e 's/|/\\|/g' -e 's/&/\\&/g'
}

INSTALLED_PACKAGES=()
CLEANUP_RAN=false

cleanup_on_exit() {
    if [ "$CLEANUP_RAN" = "true" ]; then
        return
    fi
    CLEANUP_RAN=true
    :
}

trap cleanup_on_exit EXIT

# --- 卸载 Snell 函数 ---
uninstall_snell() {
    echo "=========================================="
    echo "🗑️  Uninstalling Snell server..."
    echo "=========================================="
    
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
    echo "✅ Snell server has been completely removed."
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
    echo "Checking and installing dependencies..."
    
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
        INSTALLED_PACKAGES+=("${packages_to_install[@]}")
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
    
    echo "Downloading Snell server v${version} for ${arch}..."
    
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
    
    # 生成 20000-65535 之间的随机端口
    default_port=$((20000 + RANDOM % 45536))
    
    read -p "Enter the listening port [default: ${default_port}]: " port
    port=${port:-${default_port}}
    
    default_psk=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
    
    read -p "Enter the password (psk) [default: ${default_psk}]: " psk
    psk=${psk:-${default_psk}}
    
    read -p "Enable obfs (traffic obfuscation)? [y/N]: " enable_obfs
    
    if [[ "$enable_obfs" =~ ^[Yy]$ ]]; then
        echo ""
        echo "obfs enabled. obfs mode is set to 'http'."
        host=$(select_obfs_host)
    fi
    
    echo ""
    local dns_result=$(select_dns false 1)
    dns_servers=$(echo "$dns_result" | cut -d'|' -f1)
    dns_label=$(echo "$dns_result" | cut -d'|' -f2)
    
    mkdir -p /etc/snell
    
    if [[ "$enable_obfs" =~ ^[Yy]$ ]]; then
        cat >/etc/snell/snell-server.conf <<EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
ipv6 = true
dns = ${dns_servers}
obfs = http
host = ${host}
EOF
        echo "Configuration file with obfs created."
    else
        cat >/etc/snell/snell-server.conf <<EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
ipv6 = true
dns = ${dns_servers}
EOF
        echo "Configuration file created (obfs disabled)."
    fi
    
    echo ""
    echo "=========================================="
    echo "📋 Configuration Summary:"
    echo "Port: ${port}"
    echo "PSK: ${psk}"
    echo "DNS: ${dns_servers} (${dns_label})"
    if [[ "$enable_obfs" =~ ^[Yy]$ ]]; then
        echo "Obfs: http"
        echo "Host: ${host}"
    fi
    echo "=========================================="
}

# --- 5. 创建 systemd 服务 ---
create_systemd_service() {
    echo "🔧 Creating systemd service for Snell..."
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

    echo "Enabling and starting Snell service..."
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
    echo "  9) Custom host" >&2
    
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
                read -p "Enter custom host: " custom_host
                if [[ -z "$custom_host" ]]; then
                    echo "Custom host cannot be empty. Please try again." >&2
                    continue
                fi
                selected_host="$custom_host"
                break
                ;;
            *)
                echo "Invalid choice. Please enter a number between 1 and 9." >&2
                ;;
        esac
    done
    
    echo "$selected_host"
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
    read -p "Include IPv6 DNS servers? [Y/n]: " include_ipv6
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

# --- 8. 修改端口 ---
change_port() {
    echo "=========================================="
    echo "🔌 Modify Snell Server Port"
    echo "=========================================="
    
    if [ ! -f /etc/snell/snell-server.conf ]; then
        echo "Error: Configuration file not found!"
        return 1
    fi
    
    local current_port=$(grep -oP 'listen = 0.0.0.0:\K[0-9]+' /etc/snell/snell-server.conf)
    echo "Current port: ${current_port}"
    
    # 生成 20000-65535 之间的随机端口
    local default_new_port=$((20000 + RANDOM % 45536))
    
    read -p "Enter new port number [default: ${default_new_port}]: " new_port
    new_port=${new_port:-${default_new_port}}
    
    if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo "Error: Invalid port number!"
        return 1
    fi
    
    sed -i "s/listen = 0.0.0.0:${current_port}/listen = 0.0.0.0:${new_port}/" /etc/snell/snell-server.conf
    
    echo "Port changed from ${current_port} to ${new_port}"
    echo "Restarting Snell service..."
    systemctl restart snell.service
    
    echo "=========================================="
    echo "✅ Port modification completed!"
    echo "========================================"
}

# --- 9. 修改密码 ---
change_password() {
    echo "=========================================="
    echo "🔐 Modify Snell Server Password (PSK)"
    echo "=========================================="
    
    if [ ! -f /etc/snell/snell-server.conf ]; then
        echo "Error: Configuration file not found!"
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
    echo "✅ Password modification completed!"
    echo "========================================"
}

# --- 10. 修改 Obfs ---
change_obfs() {
    echo "=========================================="
    echo "🎭 Modify Snell Server Obfs Settings"
    echo "=========================================="
    
    if [ ! -f /etc/snell/snell-server.conf ]; then
        echo "Error: Configuration file not found!"
        return 1
    fi
    
    local current_obfs=$(grep -oP 'obfs = \K.+' /etc/snell/snell-server.conf || echo "")
    local current_host=$(grep -oP 'host = \K.+' /etc/snell/snell-server.conf || echo "")
    
    if [[ -n "$current_obfs" ]]; then
        echo "Current obfs status: Enabled (mode: ${current_obfs})"
        echo "Current host: ${current_host}"
        echo ""
        echo "What would you like to do?"
        echo "  1) Change obfs host"
        echo "  2) Disable obfs"
        echo "  0) Cancel"
        
        while true; do
            read -p "Enter your choice [0-2]: " obfs_action
            case "$obfs_action" in
                1)
                    echo ""
                    new_host=$(select_obfs_host)
                    
                    sed -i "s|host = ${current_host}|host = ${new_host}|" /etc/snell/snell-server.conf
                    
                    echo "Obfs host changed to: ${new_host}"
                    echo "Restarting Snell service..."
                    systemctl restart snell.service
                    
                    echo "=========================================="
                    echo "✅ Obfs host modification completed!"
                    echo "=========================================="
                    return 0
                    ;;
                2)
                    echo "Disabling obfs..."
                    sed -i '/^obfs = /d' /etc/snell/snell-server.conf
                    sed -i '/^host = /d' /etc/snell/snell-server.conf
                    
                    echo "Obfs has been disabled."
                    echo "Restarting Snell service..."
                    systemctl restart snell.service
                    
                    echo "=========================================="
                    echo "✅ Obfs disabled successfully!"
                    echo "=========================================="
                    return 0
                    ;;
                0)
                    echo "Cancelled."
                    return 0
                    ;;
                *)
                    echo "Invalid choice. Please enter a number between 0 and 2."
                    ;;
            esac
        done
    else
        echo "Current obfs status: Disabled"
        echo ""
        read -p "Would you like to enable obfs? [y/N]: " enable_obfs
        
        if [[ ! "$enable_obfs" =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            return 0
        fi
        
        echo ""
        new_host=$(select_obfs_host)
        
        sed -i "/^dns = /a host = ${new_host}" /etc/snell/snell-server.conf
        sed -i "/^dns = /a obfs = http" /etc/snell/snell-server.conf
        
        echo "Obfs enabled with host: ${new_host}"
        echo "Restarting Snell service..."
        systemctl restart snell.service
        
        echo "=========================================="
        echo "✅ Obfs enabled successfully!"
        echo "=========================================="
    fi
}

# --- 11. 修改 DNS ---
change_dns() {
    echo "=========================================="
    echo "🌐 Modify Snell Server DNS Settings"
    echo "=========================================="
    
    if [ ! -f /etc/snell/snell-server.conf ]; then
        echo "Error: Configuration file not found!"
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
    echo "✅ DNS modification completed!"
    echo "========================================"
}

# --- 12. 显示 Surge 节点配置 ---
show_surge_config() {
    echo "=========================================="
    echo "📱 Surge Node Configuration"
    echo "=========================================="
    
    if [ ! -f /etc/snell/snell-server.conf ]; then
        echo "Error: Configuration file not found!"
        return 1
    fi
    
    local port=$(grep -oP 'listen = 0.0.0.0:\K[0-9]+' /etc/snell/snell-server.conf)
    local psk=$(grep -oP 'psk = \K.+' /etc/snell/snell-server.conf)
    local obfs=$(grep -oP 'obfs = \K.+' /etc/snell/snell-server.conf || echo "")
    local host=$(grep -oP 'host = \K.+' /etc/snell/snell-server.conf || echo "")
    
    echo "Getting server IP address..."
    local ip=$(curl -s ip.sb -4)
    
    if [ -z "$ip" ]; then
        echo "Error: Failed to get server IP address!"
        return 1
    fi
    
    echo ""
    echo "Copy the following node configuration to Surge:"
    echo "=========================================="
    
    if [[ -n "$obfs" && -n "$host" ]]; then
        echo "node_name = snell, ${ip}, ${port}, psk=${psk}, obfs=${obfs}, obfs-host=${host}, version=5, reuse=true"
    else
        echo "node_name = snell, ${ip}, ${port}, psk=${psk}, version=5, reuse=true"
    fi
    
    echo "========================================"
}

# --- 13. 查看当前配置 ---
show_config() {
    echo "=========================================="
    echo "📋 Current Snell Configuration"
    echo "=========================================="
    
    if [ ! -f /etc/snell/snell-server.conf ]; then
        echo "Error: Configuration file not found!"
        return 1
    fi
    
    cat /etc/snell/snell-server.conf
    echo "========================================"
}

# --- 14. 已安装菜单 ---
show_installed_menu() {
    local installed_version=$1
    local latest_version=$2
    
    clear
    echo "=========================================="
    echo "🚀 Snell Server Management Menu"
    echo "=========================================="
    echo "Current version: v${installed_version}"
    echo "Latest version:  v${latest_version}"
    
    if systemctl is-active --quiet snell.service; then
        echo "Service status:  ✓ Running"
    else
        echo "Service status:  ✗ Stopped"
    fi
    
    if [ "$installed_version" != "$latest_version" ]; then
        echo ""
        echo "⚠️  New version available!"
    fi
    
    echo ""
    echo "Please select an option:"
    echo "  1) Update Snell"
    echo "  2) Uninstall Snell"
    echo "  3) Modify Port"
    echo "  4) Modify Password (PSK)"
    echo "  5) Modify Obfs"
    echo "  6) Modify DNS"
    echo "  7) Show Current Configuration"
    echo "  8) Show Surge Node Configuration"
    echo "  9) Restart Service"
    echo "  0) Exit"
    echo "========================================"
}

# --- 15. 未安装菜单 ---
show_not_installed_menu() {
    local latest_version=$1
    
    clear
    echo "=========================================="
    echo "🚀 Snell Server Management Script"
    echo "=========================================="
    echo "Snell server is not installed."
    echo "Latest available version: v${latest_version}"
    echo ""
    echo "Would you like to install Snell server?"
    echo "  1) Yes, install now"
    echo "  0) No, exit"
    echo "=========================================="
}

# ==========================================
# 主程序流程
# ==========================================

clear
snell_arch=$(detect_architecture)
if [ "$snell_arch" = "unsupported" ]; then
    echo "Error: Unsupported architecture $(uname -m)"
    echo "This script only supports x86_64 (amd64) and aarch64 architectures."
    exit 1
fi

installed_version=$(get_installed_version)

install_dependencies

latest_version=$(get_latest_version)

if [ -n "$installed_version" ]; then
    while true; do
        show_installed_menu "$installed_version" "$latest_version"
        
        read -p "Enter your choice [0-9]: " choice
        echo ""
        
        case "$choice" in
            1)
                if [ "$installed_version" = "$latest_version" ]; then
                    echo "You are already running the latest version (v${latest_version})."
                    read -p "Press Enter to continue..."
                else
                    echo "Updating Snell server from v${installed_version} to v${latest_version}..."
                    if download_and_install_snell "$latest_version" "$snell_arch"; then
                        echo ""
                        echo "Restarting Snell service..."
                        systemctl restart snell.service
                        installed_version="$latest_version"
                        echo ""
                        echo "=========================================="
                        echo "✅ Update completed successfully!"
                        echo "Snell server is now running v${latest_version}"
                        echo "=========================================="
                        systemctl status snell.service --no-pager
                    else
                        echo "Update failed."
                    fi
                    echo ""
                    read -p "Press Enter to continue..."
                fi
                ;;
            2)
                echo "Are you sure you want to uninstall Snell server?"
                while true; do
                    read -p "Type 'yes' or 'no': " confirm
                    confirm_lower=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
                    if [ "$confirm_lower" = "yes" ]; then
                        uninstall_snell
                        cleanup_on_exit
                        exit 0
                    elif [ "$confirm_lower" = "no" ]; then
                        echo "Uninstallation cancelled."
                        break
                    else
                        echo "Invalid input. Please type 'yes' or 'no'."
                    fi
                done
                echo ""
                read -p "Press Enter to continue..."
                ;;
            3)
                change_port
                echo ""
                read -p "Press Enter to continue..."
                ;;
            4)
                change_password
                echo ""
                read -p "Press Enter to continue..."
                ;;
            5)
                change_obfs
                echo ""
                read -p "Press Enter to continue..."
                ;;
            6)
                change_dns
                echo ""
                read -p "Press Enter to continue..."
                ;;
            7)
                echo "========================================="
                echo "Current Snell Configuration"
                echo "========================================="
                echo ""
                
                if [ -f /etc/snell/snell-server.conf ]; then
                    cat /etc/snell/snell-server.conf
                    echo ""
                    echo "========================================="
                else
                    echo "Error: Configuration file not found!"
                fi
                
                echo ""
                read -p "Press Enter to continue..."
                ;;
            8)
                show_surge_config
                echo ""
                read -p "Press Enter to continue..."
                ;;
            9)
                echo "Restarting Snell service..."
                systemctl restart snell.service
                echo "Service restarted successfully!"
                systemctl status snell.service --no-pager
                echo ""
                read -p "Press Enter to continue..."
                ;;
            0)
                echo "Exiting..."
                cleanup_on_exit
                exit 0
                ;;
            *)
                echo "Invalid choice. Please enter a number between 0 and 9."
                read -p "Press Enter to continue..."
                ;;
        esac
    done
else
    show_not_installed_menu "$latest_version"
    
    while true; do
        read -p "Enter your choice [0-1]: " choice
        case "$choice" in
            1)
                echo ""
                echo "Starting Snell installation..."
                echo "Detected architecture: $(uname -m) (using ${snell_arch} binary)"
                
                if download_and_install_snell "$latest_version" "$snell_arch"; then
                    echo ""
                    configure_snell
                    echo ""
                    create_systemd_service
                    echo ""
                    echo "=========================================="
                    echo "✅ Snell server installation complete!"
                    echo "Version: v${latest_version}"
                    echo "=========================================="
                    echo ""
                    show_surge_config
                else
                    echo "Installation failed."
                    cleanup_on_exit
                    exit 1
                fi
                cleanup_on_exit
                exit 0
                ;;
            0)
                echo "Exiting..."
                cleanup_on_exit
                exit 0
                ;;
            *)
                echo "Invalid choice. Please enter 0 or 1."
                ;;
        esac
    done
fi
