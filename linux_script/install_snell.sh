#!/bin/bash

# --- 使用方法 ---
# 1. 将此脚本保存为 .sh 文件，例如 install_snell.sh
# 2. 赋予执行权限: chmod +x install_snell.sh
# 3. 运行脚本: ./install_snell.sh

# 如果任何命令执行失败，则立即退出脚本
set -e

# 记录脚本安装的依赖，用于清理
INSTALLED_PACKAGES=()

# --- 清理函数 ---
cleanup_on_exit() {
    if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
        echo "Cleaning up installed packages..."
        apt remove -y "${INSTALLED_PACKAGES[@]}"
        apt autoremove -y
        echo "Cleanup completed."
    fi
}

# --- 卸载 Snell 函数 ---
uninstall_snell() {
    echo "=========================================="
    echo "Uninstalling Snell server..."
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
    
    # 删除文件
    echo "Removing Snell files..."
    rm -f /usr/local/bin/snell-server
    rm -f /etc/systemd/system/snell.service
    rm -rf /etc/snell
    
    # 重新加载 systemd
    systemctl daemon-reload
    
    echo "=========================================="
    echo "Snell server has been completely removed."
    echo "=========================================="
}

# --- 获取当前安装的版本 ---
get_installed_version() {
    if [ -f /usr/local/bin/snell-server ]; then
        # 使用 --version 参数获取版本号
        # 输出示例: 2025-11-19 18:13:50.981990 [server_main] <NOTIFY> snell-server v5.0.0 (Jul  7 2025 17:38:28)
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
        echo "5.0.1"  # 备用版本
    else
        echo "$version"
    fi
}

# --- 比较版本号 ---
version_gt() {
    # 如果第一个版本大于第二个版本，返回 0（true）
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

# --- 1. 安装依赖 ---
install_dependencies() {
    echo "Checking and installing dependencies..."
    
    local packages_to_install=()
    
    # 检查每个依赖是否已安装
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
    wget "${download_url}" -O snell-server.zip
    
    if [ $? -ne 0 ]; then
        echo "Download failed. Please check your network connection or the URL."
        return 1
    fi
    
    # 停止服务（如果正在运行）
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
    echo "Please configure your Snell server:"
    echo "=========================================="
    
    # 交互式设置端口，默认值为 6666
    read -p "Enter the listening port [default: 6666]: " port
    port=${port:-6666}
    
    # 使用 /dev/urandom 和 tr 生成兼容性更好的随机密码
    default_psk=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
    
    # 交互式设置密码，默认值为新生成的随机密码
    read -p "Enter the password (psk) [default: ${default_psk}]: " psk
    psk=${psk:-${default_psk}}
    
    # 交互式询问是否开启 obfs，默认为不开启
    read -p "Enable obfs (traffic obfuscation)? [y/N]: " enable_obfs
    
    # 如果开启 obfs，立即询问 host
    if [[ "$enable_obfs" =~ ^[Yy]$ ]]; then
        echo ""
        echo "obfs enabled. obfs mode is set to 'http'."
        echo "Select an obfs host (default: Bilibili):"
        echo "  1) Bilibili"
        echo "     d1--ov-gotcha07.bilivideo.com"
        echo "  2) Contentstack"
        echo "     images.contentstack.io"
        echo "  3) Custom host"
        
        while true; do
            read -p "Enter the host option number [1]: " host_choice
            host_choice=${host_choice:-1}
            case "$host_choice" in
                1)
                    host="d1--ov-gotcha07.bilivideo.com"
                    break
                    ;;
                2)
                    host="images.contentstack.io"
                    break
                    ;;
                3)
                    read -p "Enter custom host: " custom_host
                    if [[ -z "$custom_host" ]]; then
                        echo "Custom host cannot be empty. Please try again."
                        continue
                    fi
                    host="$custom_host"
                    break
                    ;;
                *)
                    echo "Invalid choice. Please enter a number between 1 and 3."
                    ;;
            esac
        done
    fi
    
    # 交互式选择 DNS
    echo ""
    echo "Select a public DNS provider (default: Google):"
    echo "  1) Google"
    echo "     8.8.8.8,8.8.4.4,2001:4860:4860::8888,2001:4860:4860::8844"
    echo "  2) Cloudflare"
    echo "     1.1.1.1,1.0.0.1,2606:4700:4700::1111,2606:4700:4700::1001"
    echo "  3) Cloudflare Malware Protection"
    echo "     1.1.1.2,1.0.0.2,2606:4700:4700::1112,2606:4700:4700::1002"
    echo "  4) Cloudflare Family"
    echo "     1.1.1.3,1.0.0.3,2606:4700:4700::1113,2606:4700:4700::1003"
    echo "  5) Quad9"
    echo "     9.9.9.9,149.112.112.112,2620:fe::fe,2620:fe::9"
    echo "  6) Quad9 Secured"
    echo "     9.9.9.11,149.112.112.11,2620:fe::11,2620:fe::fe:11"
    echo "  7) Custom DNS"
    
    while true; do
        read -p "Enter the DNS option number [1]: " dns_choice
        dns_choice=${dns_choice:-1}
        case "$dns_choice" in
            1)
                dns_label="Google"
                dns_servers="8.8.8.8,8.8.4.4,2001:4860:4860::8888,2001:4860:4860::8844"
                break
                ;;
            2)
                dns_label="Cloudflare"
                dns_servers="1.1.1.1,1.0.0.1,2606:4700:4700::1111,2606:4700:4700::1001"
                break
                ;;
            3)
                dns_label="Cloudflare Malware Protection"
                dns_servers="1.1.1.2,1.0.0.2,2606:4700:4700::1112,2606:4700:4700::1002"
                break
                ;;
            4)
                dns_label="Cloudflare Family"
                dns_servers="1.1.1.3,1.0.0.3,2606:4700:4700::1113,2606:4700:4700::1003"
                break
                ;;
            5)
                dns_label="Quad9"
                dns_servers="9.9.9.9,149.112.112.112,2620:fe::fe,2620:fe::9"
                break
                ;;
            6)
                dns_label="Quad9 Secured"
                dns_servers="9.9.9.11,149.112.112.11,2620:fe::11,2620:fe::fe:11"
                break
                ;;
            7)
                read -p "Enter custom DNS addresses (comma separated): " custom_dns
                if [[ -z "$custom_dns" ]]; then
                    echo "Custom DNS cannot be empty. Please try again."
                    continue
                fi
                dns_label="Custom DNS"
                dns_servers="$custom_dns"
                break
                ;;
            *)
                echo "Invalid choice. Please enter a number between 1 and 7."
                ;;
        esac
    done
    
    # 确保配置文件目录存在
    mkdir -p /etc/snell
    
    # 判断用户是否选择开启 obfs
    if [[ "$enable_obfs" =~ ^[Yy]$ ]]; then
        # 写入包含 obfs 的配置文件
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
        # 如果不开启 obfs，则写入不含 obfs 的配置文件
        cat >/etc/snell/snell-server.conf <<EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
ipv6 = true
dns = ${dns_servers}
EOF
        echo "Configuration file created (obfs disabled)."
    fi
    
    # 显示配置信息
    echo ""
    echo "=========================================="
    echo "Configuration Summary:"
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
    echo "Creating systemd service for Snell..."
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

# --- 6. 修改端口 ---
change_port() {
    echo "=========================================="
    echo "Modify Snell Server Port"
    echo "=========================================="
    
    # 读取当前配置
    if [ ! -f /etc/snell/snell-server.conf ]; then
        echo "Error: Configuration file not found!"
        return 1
    fi
    
    local current_port=$(grep -oP 'listen = 0.0.0.0:\K[0-9]+' /etc/snell/snell-server.conf)
    echo "Current port: ${current_port}"
    
    read -p "Enter new port number: " new_port
    
    if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo "Error: Invalid port number!"
        return 1
    fi
    
    # 修改配置文件中的端口
    sed -i "s/listen = 0.0.0.0:${current_port}/listen = 0.0.0.0:${new_port}/" /etc/snell/snell-server.conf
    
    echo "Port changed from ${current_port} to ${new_port}"
    echo "Restarting Snell service..."
    systemctl restart snell.service
    
    echo "=========================================="
    echo "Port modification completed!"
    echo "=========================================="
}

# --- 7. 修改密码 ---
change_password() {
    echo "=========================================="
    echo "Modify Snell Server Password (PSK)"
    echo "=========================================="
    
    # 读取当前配置
    if [ ! -f /etc/snell/snell-server.conf ]; then
        echo "Error: Configuration file not found!"
        return 1
    fi
    
    local current_psk=$(grep -oP 'psk = \K.+' /etc/snell/snell-server.conf)
    echo "Current PSK: ${current_psk}"
    
    # 生成新的随机密码作为默认值
    local default_new_psk=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
    
    read -p "Enter new password [default: ${default_new_psk}]: " new_psk
    new_psk=${new_psk:-${default_new_psk}}
    
    # 修改配置文件中的密码
    sed -i "s/psk = ${current_psk}/psk = ${new_psk}/" /etc/snell/snell-server.conf
    
    echo "Password changed successfully!"
    echo "New PSK: ${new_psk}"
    echo "Restarting Snell service..."
    systemctl restart snell.service
    
    echo "=========================================="
    echo "Password modification completed!"
    echo "=========================================="
}

# --- 8. 查看当前配置 ---
show_config() {
    echo "=========================================="
    echo "Current Snell Configuration"
    echo "=========================================="
    
    if [ ! -f /etc/snell/snell-server.conf ]; then
        echo "Error: Configuration file not found!"
        return 1
    fi
    
    cat /etc/snell/snell-server.conf
    echo "=========================================="
}

# --- 9. 已安装菜单 ---
show_installed_menu() {
    local installed_version=$1
    local latest_version=$2
    
    clear
    echo "=========================================="
    echo "Snell Server Management Menu"
    echo "=========================================="
    echo "Current version: v${installed_version}"
    echo "Latest version:  v${latest_version}"
    
    if [ "$installed_version" != "$latest_version" ]; then
        echo ""
        echo "⚠️  New version available!"
    fi
    
    echo ""
    echo "=========================================="
    show_config
    
    echo ""
    clear
    echo "=========================================="
    echo "Snell Server Management Menu"
    echo "=========================================="
    echo "Current version: v${installed_version}"
    echo "Latest version:  v${latest_version}"
    
    # 检查服务状态
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
    echo "  5) Show Current Configuration"
    echo "  6) Restart Service"
    echo "  0) Exit"
    echo "=========================================="
}

# --- 10. 未安装菜单 ---
show_not_installed_menu() {
    local latest_version=$1
    
    clear
    echo "=========================================="
    echo "Snell Server Management Script"
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

# 清空屏幕
clear

# 检测 CPU 架构
snell_arch=$(detect_architecture)
if [ "$snell_arch" = "unsupported" ]; then
    echo "Error: Unsupported architecture $(uname -m)"
    echo "This script only supports x86_64 (amd64) and aarch64 architectures."
    exit 1
fi

# 检查是否已安装 Snell
installed_version=$(get_installed_version)

# 安装依赖以获取最新版本
install_dependencies

# 获取最新版本
latest_version=$(get_latest_version)

if [ -n "$installed_version" ]; then
    # ==========================================
    # 已安装 Snell - 显示管理菜单
    # ==========================================
    
    while true; do
        show_installed_menu "$installed_version" "$latest_version"
        
        read -p "Enter your choice [0-6]: " choice
        echo ""
        
        case "$choice" in
            1)
                # 更新 Snell
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
                        echo "Update completed successfully!"
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
                # 卸载 Snell
                echo "Are you sure you want to uninstall Snell server?"
                read -p "Type 'yes' to confirm: " confirm
                if [ "$confirm" = "yes" ]; then
                    uninstall_snell
                    cleanup_on_exit
                    exit 0
                else
                    echo "Uninstallation cancelled."
                    read -p "Press Enter to continue..."
                fi
                ;;
            3)
                # 修改端口
                change_port
                echo ""
                read -p "Press Enter to continue..."
                ;;
            4)
                # 修改密码
                change_password
                echo ""
                read -p "Press Enter to continue..."
                ;;
            5)
                # 显示当前配置
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
            6)
                # 重启服务
                echo "Restarting Snell service..."
                systemctl restart snell.service
                echo "Service restarted successfully!"
                systemctl status snell.service --no-pager
                echo ""
                read -p "Press Enter to continue..."
                ;;
            0)
                # 退出
                echo "Exiting..."
                cleanup_on_exit
                exit 0
                ;;
            *)
                echo "Invalid choice. Please enter a number between 0 and 6."
                read -p "Press Enter to continue..."
                ;;
        esac
    done
else
    # ==========================================
    # 未安装 Snell - 询问是否安装
    # ==========================================
    
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
                    echo "Snell server installation complete!"
                    echo "Version: v${latest_version}"
                    echo "=========================================="
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
