#!/bin/bash
# Tailscale Derper 管理脚本
# 参考: https://catcat.blog/2025/12/deploy-tailscale-derper
# 功能: 安装、更新、重启、卸载 Derper 中继服务器

# --- Root 权限检查 ---
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with root privileges (sudo ./install_derper.sh)"
    exit 1
fi

# --- 检查系统是否为 Debian 或 Ubuntu ---
check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
            log_error "This script only supports Debian and Ubuntu"
            exit 1
        fi
    else
        log_error "Cannot detect OS. This script only supports Debian and Ubuntu"
        exit 1
    fi
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

# --- 全局变量 ---
DERPER_BIN="/usr/sbin/derper"
DERPER_SERVICE="/etc/systemd/system/derper.service"
DERPER_DATA_DIR="/var/lib/derper"
DERPER_CERT_DIR="/var/lib/derper/certs"
TMP_GO_DIR="/tmp/derper_go"
TMP_BUILD_DIR="/tmp/derper_build"
GO_VERSION="1.22.0"
INSTALLED_DEPS_FILE="/var/lib/derper/.installed_deps"

# --- 检测 CPU 架构 ---
detect_architecture() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            echo "unsupported"
            ;;
    esac
}

# --- 检查 Derper 是否已安装 ---
is_derper_installed() {
    if [ -f "$DERPER_BIN" ] && [ -f "$DERPER_SERVICE" ]; then
        return 0
    fi
    return 1
}

# --- 获取当前配置 ---
get_current_config() {
    if [ ! -f "$DERPER_SERVICE" ]; then
        return 1
    fi
    
    local exec_line=$(grep "^ExecStart=" "$DERPER_SERVICE")
    
    CURRENT_HOSTNAME=$(echo "$exec_line" | grep -oP '\-\-hostname[= ]\K[^ \\]+')
    CURRENT_DERP_PORT=$(echo "$exec_line" | grep -oP '\-a[= ]:\K[0-9]+')
    CURRENT_HTTP_PORT=$(echo "$exec_line" | grep -oP '\-http-port[= ]\K[0-9]+')
    CURRENT_STUN_PORT=$(echo "$exec_line" | grep -oP '\-stun-port[= ]\K[0-9]+' || echo "3478")
    CURRENT_CERTMODE=$(echo "$exec_line" | grep -oP '\-certmode[= ]\K[^ \\]+')
    
    if echo "$exec_line" | grep -q "\-verify-clients"; then
        CURRENT_VERIFY="true"
    else
        CURRENT_VERIFY="false"
    fi
}

# --- 清理临时文件 ---
cleanup_temp() {
    log_info "Cleaning up temporary files..."
    rm -rf "$TMP_GO_DIR" 2>/dev/null
    rm -rf "$TMP_BUILD_DIR" 2>/dev/null
    log_success "Temporary files cleaned up"
}

# --- 安装依赖 ---
install_dependencies() {
    log_info "Checking and installing dependencies..."
    
    local packages_to_install=()
    local deps_installed=()
    
    for pkg in git wget curl; do
        if ! command -v $pkg &> /dev/null; then
            packages_to_install+=($pkg)
        fi
    done
    
    if [ ${#packages_to_install[@]} -gt 0 ]; then
        echo "Installing: ${packages_to_install[*]}"
        apt update
        apt install -y "${packages_to_install[@]}"
        
        # 记录安装的依赖，便于卸载时清理
        mkdir -p "$DERPER_DATA_DIR"
        echo "${packages_to_install[*]}" > "$INSTALLED_DEPS_FILE"
        deps_installed=("${packages_to_install[@]}")
    else
        echo "All dependencies are already installed"
    fi
}

# --- 下载并设置临时 Go 环境 ---
setup_temp_go() {
    local arch=$(detect_architecture)
    
    if [ "$arch" = "unsupported" ]; then
        log_error "Unsupported CPU architecture: $(uname -m)"
        return 1
    fi
    
    log_info "Downloading Go ${GO_VERSION} to temporary directory..."
    
    mkdir -p "$TMP_GO_DIR"
    cd "$TMP_GO_DIR"
    
    local go_arch="$arch"
    local download_url="https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz"
    
    if ! wget -q --show-progress "$download_url" -O go.tar.gz; then
        log_error "Failed to download Go"
        return 1
    fi
    
    tar -xzf go.tar.gz
    rm -f go.tar.gz
    
    # 设置临时 Go 环境变量
    export GOROOT="$TMP_GO_DIR/go"
    export GOPATH="$TMP_GO_DIR/gopath"
    export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"
    
    mkdir -p "$GOPATH"
    
    # 验证 Go 安装
    if ! go version &>/dev/null; then
        log_error "Go installation verification failed"
        return 1
    fi
    
    log_success "Go ${GO_VERSION} is ready"
    return 0
}

# --- 编译 Derper ---
compile_derper() {
    log_info "Cloning Tailscale repository and compiling Derper..."
    
    mkdir -p "$TMP_BUILD_DIR"
    cd "$TMP_BUILD_DIR"
    
    # 克隆 Tailscale 仓库
    if ! git clone --depth 1 https://github.com/tailscale/tailscale.git; then
        log_error "Failed to clone repository"
        return 1
    fi
    
    cd tailscale
    
    # 编译 derper
    log_info "Compiling derper, please wait..."
    if ! go build -o derper ./cmd/derper; then
        log_error "Compilation failed"
        return 1
    fi
    
    # 停止现有服务（如果存在）
    if systemctl is-active --quiet derper.service 2>/dev/null; then
        log_info "Stopping existing Derper service..."
        systemctl stop derper.service
    fi
    
    # 移动二进制文件
    mv derper "$DERPER_BIN"
    chmod +x "$DERPER_BIN"
    
    log_success "Derper compiled successfully"
    return 0
}

# --- 交互式配置 ---
configure_derper() {
    echo "=========================================="
    echo "⚙️  Configure Derper Service:"
    echo "=========================================="
    
    # 域名配置（必填）
    while true; do
        read -p "Enter hostname (e.g. derper.example.com): " HOSTNAME
        if [ -n "$HOSTNAME" ]; then
            break
        fi
        log_warn "Hostname cannot be empty"
    done
    
    # DERP 端口
    read -p "Enter DERP service port [default: 443]: " DERP_PORT
    DERP_PORT=${DERP_PORT:-443}
    
    # HTTP 端口
    read -p "Enter HTTP port (for certificate validation) [default: 80]: " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-80}
    
    # STUN 端口
    read -p "Enter STUN port [default: 3478]: " STUN_PORT
    STUN_PORT=${STUN_PORT:-3478}
    
    # 证书模式
    echo ""
    echo "🔐 Select certificate mode:"
    echo "  1) Let's Encrypt auto-apply (requires ports 80/443)"
    echo "  2) Manual certificate management"
    read -p "Select [default: 1]: " CERT_CHOICE
    CERT_CHOICE=${CERT_CHOICE:-1}
    
    case "$CERT_CHOICE" in
        1)
            CERT_MODE="letsencrypt"
            ;;
        2)
            CERT_MODE="manual"
            log_info "Manual mode: Please place certificate files in $DERPER_CERT_DIR/"
            log_info "File naming: ${HOSTNAME}.crt and ${HOSTNAME}.key"
            ;;
        *)
            CERT_MODE="letsencrypt"
            ;;
    esac
    
    # 客户端验证
    echo ""
    echo "🛡️  Enable client verification (prevent unauthorized use)?"
    echo "  Requires Tailscale client installed and logged in on this server"
    read -p "Enable client verification? [y/N]: " VERIFY_CHOICE
    VERIFY_CHOICE=${VERIFY_CHOICE:-N}
    
    if [[ "$VERIFY_CHOICE" =~ ^[Yy]$ ]]; then
        VERIFY_CLIENTS="true"
        
        # 检查 Tailscale 是否已安装
        if ! command -v tailscale &>/dev/null; then
            echo ""
            read -p "Tailscale is not installed. Install now? [Y/n]: " INSTALL_TS
            INSTALL_TS=${INSTALL_TS:-Y}
            
            if [[ "$INSTALL_TS" =~ ^[Yy]$ ]]; then
                log_info "Installing Tailscale client..."
                curl -fsSL https://tailscale.com/install.sh | sh
                log_success "Tailscale installed"
                log_warn "Please run 'sudo tailscale up' later to login to Tailscale network"
            fi
        fi
    else
        VERIFY_CLIENTS="false"
    fi
    
    # 创建数据目录
    mkdir -p "$DERPER_CERT_DIR"
    
    echo ""
    echo "=========================================="
    echo "📋 Configuration Summary:"
    echo "  Hostname: $HOSTNAME"
    echo "  DERP Port: $DERP_PORT"
    echo "  HTTP Port: $HTTP_PORT"
    echo "  STUN Port: $STUN_PORT"
    echo "  Certificate Mode: $CERT_MODE"
    echo "  Client Verification: $VERIFY_CLIENTS"
    echo "=========================================="
}

# --- 创建 systemd 服务 ---
create_systemd_service() {
    log_action "🔧 Creating systemd service..."
    
    # 构建 ExecStart 命令
    local exec_cmd="$DERPER_BIN \\"$'\n'
    exec_cmd+="  --hostname=$HOSTNAME \\"$'\n'
    exec_cmd+="  -a :$DERP_PORT \\"$'\n'
    exec_cmd+="  -http-port $HTTP_PORT \\"$'\n'
    exec_cmd+="  -stun-port $STUN_PORT \\"$'\n'
    exec_cmd+="  -certmode $CERT_MODE \\"$'\n'
    exec_cmd+="  --certdir $DERPER_CERT_DIR"
    
    if [ "$VERIFY_CLIENTS" = "true" ]; then
        exec_cmd+=" \\"$'\n'
        exec_cmd+="  -verify-clients"
    fi
    
    cat >"$DERPER_SERVICE" <<EOF
[Unit]
Description=Tailscale Derper
Documentation=https://tailscale.com/kb/1118/custom-derp-servers
Wants=network-pre.target
After=network-pre.target NetworkManager.service systemd-resolved.service

[Service]
ExecStart=$exec_cmd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable derper.service
    
    log_success "Systemd service created"
}

# --- 启动服务 ---
start_service() {
    log_info "Starting Derper service..."
    systemctl start derper.service
    
    sleep 2
    
    if systemctl is-active --quiet derper.service; then
        log_success "Derper service started successfully"
        echo ""
        systemctl status derper.service --no-pager
    else
        log_error "Derper service failed to start"
        echo "View logs: journalctl -u derper -f"
        return 1
    fi
}

# --- 完整安装流程 ---
install_derper() {
    echo "=========================================="
    log_action "🚀 Installing Tailscale Derper..."
    echo "=========================================="
    
    if is_derper_installed; then
        log_warn "Derper is already installed"
        read -p "Reinstall? [y/N]: " REINSTALL
        REINSTALL=${REINSTALL:-N}
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi
    
    # 安装依赖
    install_dependencies
    
    # 设置临时 Go 环境
    if ! setup_temp_go; then
        cleanup_temp
        return 1
    fi
    
    # 编译 Derper
    if ! compile_derper; then
        cleanup_temp
        return 1
    fi
    
    # 配置
    configure_derper
    
    # 创建服务
    create_systemd_service
    
    # 清理临时文件
    cleanup_temp
    
    # 启动服务
    start_service
    
    echo ""
    echo "=========================================="
    log_success "Derper installation complete!"
    echo ""
    echo "📝 Next steps:"
    echo "  1. Make sure firewall allows these ports:"
    echo "     - TCP $DERP_PORT (DERP)"
    echo "     - TCP $HTTP_PORT (HTTP/Certificate validation)"
    echo "     - UDP $STUN_PORT (STUN)"
    echo ""
    echo "  2. Add DERP server in Tailscale ACL:"
    echo '     "derpMap": {'
    echo '       "Regions": {'
    echo '         "900": {'
    echo "           \"RegionID\": 900,"
    echo "           \"RegionCode\": \"myderp\","
    echo "           \"RegionName\": \"My DERP Server\","
    echo '           "Nodes": [{'
    echo "             \"Name\": \"1\","
    echo "             \"RegionID\": 900,"
    echo "             \"HostName\": \"$HOSTNAME\""
    if [ "$DERP_PORT" != "443" ]; then
        echo "             \"DERPPort\": $DERP_PORT"
    fi
    if [ "$STUN_PORT" != "3478" ]; then
        echo "             \"STUNPort\": $STUN_PORT"
    fi
    echo '           }]'
    echo '         }'
    echo '       }'
    echo '     }'
    
    if [ "$VERIFY_CLIENTS" = "true" ]; then
        echo ""
        echo "  3. Run 'sudo tailscale up' to login to Tailscale network"
    fi
    echo "=========================================="
}

# --- 更新 Derper ---
update_derper() {
    echo "=========================================="
    log_action "🔄 Updating Tailscale Derper..."
    echo "=========================================="
    
    if ! is_derper_installed; then
        log_error "Derper is not installed"
        return 1
    fi
    
    # 获取当前配置
    get_current_config
    
    # 安装依赖（如果需要）
    install_dependencies
    
    # 设置临时 Go 环境
    if ! setup_temp_go; then
        cleanup_temp
        return 1
    fi
    
    # 编译新版本
    if ! compile_derper; then
        cleanup_temp
        return 1
    fi
    
    # 清理临时文件
    cleanup_temp
    
    # 重启服务
    systemctl restart derper.service
    
    sleep 2
    
    if systemctl is-active --quiet derper.service; then
        log_success "Derper updated successfully"
        systemctl status derper.service --no-pager
    else
        log_error "Service failed to start after update"
        echo "View logs: journalctl -u derper -f"
    fi
}

# --- 卸载 Derper ---
uninstall_derper() {
    echo "=========================================="
    log_action "🗑️  Uninstalling Tailscale Derper..."
    echo "=========================================="
    
    if ! is_derper_installed; then
        log_warn "Derper is not installed"
        return 0
    fi
    
    read -p "Are you sure you want to uninstall Derper? [y/N]: " CONFIRM
    CONFIRM=${CONFIRM:-N}
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled"
        return 0
    fi
    
    # 停止并禁用服务
    if systemctl is-active --quiet derper.service; then
        log_info "Stopping Derper service..."
        systemctl stop derper.service
    fi
    
    if systemctl is-enabled --quiet derper.service 2>/dev/null; then
        log_info "Disabling Derper service..."
        systemctl disable derper.service
    fi
    
    # 删除文件
    log_info "Removing Derper files..."
    rm -f "$DERPER_BIN"
    rm -f "$DERPER_SERVICE"
    
    # 询问是否删除数据目录
    read -p "Delete certificates and data directory $DERPER_DATA_DIR? [y/N]: " DEL_DATA
    DEL_DATA=${DEL_DATA:-N}
    if [[ "$DEL_DATA" =~ ^[Yy]$ ]]; then
        rm -rf "$DERPER_DATA_DIR"
        log_info "Data directory deleted"
    fi
    
    # 询问是否清理安装的依赖
    if [ -f "$INSTALLED_DEPS_FILE" ]; then
        local installed_deps=$(cat "$INSTALLED_DEPS_FILE")
        if [ -n "$installed_deps" ]; then
            echo ""
            log_info "The following dependencies were installed by this script: $installed_deps"
            read -p "Uninstall these dependencies? [y/N]: " DEL_DEPS
            DEL_DEPS=${DEL_DEPS:-N}
            if [[ "$DEL_DEPS" =~ ^[Yy]$ ]]; then
                apt remove -y $installed_deps
                apt autoremove -y
                log_info "Dependencies uninstalled"
            fi
        fi
        rm -f "$INSTALLED_DEPS_FILE"
    fi
    
    systemctl daemon-reload
    
    # 清理临时文件
    cleanup_temp
    
    log_success "Derper has been completely uninstalled"
}

# --- 重启服务 ---
restart_derper() {
    if ! is_derper_installed; then
        log_error "Derper is not installed"
        return 1
    fi
    
    log_info "Restarting Derper service..."
    systemctl restart derper.service
    
    sleep 2
    
    if systemctl is-active --quiet derper.service; then
        log_success "Derper service restarted"
        systemctl status derper.service --no-pager
    else
        log_error "Service restart failed"
        echo "View logs: journalctl -u derper -f"
    fi
}

# --- 查看状态 ---
show_status() {
    if ! is_derper_installed; then
        log_error "Derper is not installed"
        return 1
    fi
    
    echo "=========================================="
    echo "📊 Derper Service Status"
    echo "=========================================="
    
    get_current_config
    
    echo ""
    echo "Current Configuration:"
    echo "  Hostname: $CURRENT_HOSTNAME"
    echo "  DERP Port: $CURRENT_DERP_PORT"
    echo "  HTTP Port: $CURRENT_HTTP_PORT"
    echo "  STUN Port: $CURRENT_STUN_PORT"
    echo "  Certificate Mode: $CURRENT_CERTMODE"
    echo "  Client Verification: $CURRENT_VERIFY"
    echo ""
    
    systemctl status derper.service --no-pager
}

# --- 查看日志 ---
show_logs() {
    if ! is_derper_installed; then
        log_error "Derper is not installed"
        return 1
    fi
    
    echo "Press Ctrl+C to exit log view"
    journalctl -u derper -f
}

# --- 修改配置菜单 ---
modify_config_menu() {
    if ! is_derper_installed; then
        log_error "Derper is not installed"
        return 1
    fi
    
    get_current_config
    
    while true; do
        echo ""
        echo "=========================================="
        echo "⚙️  Modify Configuration"
        echo "=========================================="
        echo "Current Configuration:"
        echo "  1) Hostname: $CURRENT_HOSTNAME"
        echo "  2) DERP Port: $CURRENT_DERP_PORT"
        echo "  3) HTTP Port: $CURRENT_HTTP_PORT"
        echo "  4) STUN Port: $CURRENT_STUN_PORT"
        echo "  5) Certificate Mode: $CURRENT_CERTMODE"
        echo "  6) Client Verification: $CURRENT_VERIFY"
        echo ""
        echo "  0) Back to Main Menu"
        echo "=========================================="
        
        read -p "Select option to modify [0-6]: " choice
        
        case "$choice" in
            1)
                read -p "Enter new hostname [$CURRENT_HOSTNAME]: " NEW_HOSTNAME
                NEW_HOSTNAME=${NEW_HOSTNAME:-$CURRENT_HOSTNAME}
                sed -i "s/--hostname=$CURRENT_HOSTNAME/--hostname=$NEW_HOSTNAME/" "$DERPER_SERVICE"
                CURRENT_HOSTNAME="$NEW_HOSTNAME"
                systemctl daemon-reload
                log_success "Hostname updated"
                ;;
            2)
                read -p "Enter new DERP port [$CURRENT_DERP_PORT]: " NEW_PORT
                NEW_PORT=${NEW_PORT:-$CURRENT_DERP_PORT}
                sed -i "s/-a :$CURRENT_DERP_PORT/-a :$NEW_PORT/" "$DERPER_SERVICE"
                CURRENT_DERP_PORT="$NEW_PORT"
                systemctl daemon-reload
                log_success "DERP port updated"
                ;;
            3)
                read -p "Enter new HTTP port [$CURRENT_HTTP_PORT]: " NEW_PORT
                NEW_PORT=${NEW_PORT:-$CURRENT_HTTP_PORT}
                sed -i "s/-http-port $CURRENT_HTTP_PORT/-http-port $NEW_PORT/" "$DERPER_SERVICE"
                CURRENT_HTTP_PORT="$NEW_PORT"
                systemctl daemon-reload
                log_success "HTTP port updated"
                ;;
            4)
                read -p "Enter new STUN port [$CURRENT_STUN_PORT]: " NEW_PORT
                NEW_PORT=${NEW_PORT:-$CURRENT_STUN_PORT}
                sed -i "s/-stun-port $CURRENT_STUN_PORT/-stun-port $NEW_PORT/" "$DERPER_SERVICE"
                CURRENT_STUN_PORT="$NEW_PORT"
                systemctl daemon-reload
                log_success "STUN port updated"
                ;;
            5)
                echo "Select certificate mode:"
                echo "  1) letsencrypt"
                echo "  2) manual"
                read -p "Select [1/2]: " CERT_CHOICE
                if [ "$CERT_CHOICE" = "1" ]; then
                    NEW_MODE="letsencrypt"
                elif [ "$CERT_CHOICE" = "2" ]; then
                    NEW_MODE="manual"
                else
                    continue
                fi
                sed -i "s/-certmode $CURRENT_CERTMODE/-certmode $NEW_MODE/" "$DERPER_SERVICE"
                CURRENT_CERTMODE="$NEW_MODE"
                systemctl daemon-reload
                log_success "Certificate mode updated"
                ;;
            6)
                if [ "$CURRENT_VERIFY" = "true" ]; then
                    # 禁用验证
                    sed -i '/-verify-clients/d' "$DERPER_SERVICE"
                    CURRENT_VERIFY="false"
                    log_success "Client verification disabled"
                else
                    # 启用验证
                    sed -i "/--certdir/a\\  -verify-clients" "$DERPER_SERVICE"
                    CURRENT_VERIFY="true"
                    log_success "Client verification enabled"
                    log_warn "Make sure Tailscale client is installed and logged in"
                fi
                systemctl daemon-reload
                ;;
            0)
                break
                ;;
            *)
                log_warn "Invalid option"
                ;;
        esac
        
        read -p "Restart service to apply changes? [Y/n]: " RESTART
        RESTART=${RESTART:-Y}
        if [[ "$RESTART" =~ ^[Yy]$ ]]; then
            restart_derper
        fi
    done
}

# --- 主菜单 ---
main_menu() {
    while true; do
        clear
        echo ""
        echo "=========================================="
        echo "  🌐 Tailscale Derper Manager"
        echo "=========================================="
        
        if is_derper_installed; then
            get_current_config
            echo -e "  Status: ${GREEN}Installed${PLAIN}"
            echo "  Hostname: $CURRENT_HOSTNAME"
            if systemctl is-active --quiet derper.service; then
                echo -e "  Service: ${GREEN}Running${PLAIN}"
            else
                echo -e "  Service: ${RED}Stopped${PLAIN}"
            fi
        else
            echo -e "  Status: ${YELLOW}Not Installed${PLAIN}"
        fi
        
        echo ""
        echo "=========================================="
        echo "  1) Install Derper"
        echo "  2) Update Derper"
        echo "  3) Restart Service"
        echo "  4) Show Status"
        echo "  5) View Logs"
        echo "  6) Modify Configuration"
        echo "  7) Uninstall Derper"
        echo ""
        echo "  0) Exit"
        echo "=========================================="
        
        read -p "Select [0-7]: " choice
        
        case "$choice" in
            1) install_derper; pause ;;
            2) update_derper; pause ;;
            3) restart_derper; pause ;;
            4) show_status; pause ;;
            5) show_logs ;;
            6) modify_config_menu ;;
            7) uninstall_derper; pause ;;
            0) echo "Goodbye!"; exit 0 ;;
            *) log_warn "Invalid option"; pause ;;
        esac
    done
}

# --- 入口 ---
check_os
main_menu
