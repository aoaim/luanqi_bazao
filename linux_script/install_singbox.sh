#!/bin/sh
# Sing-box OpenWrt 管理脚本
# 适用于 GL.iNet MT3600BE 路由器 OpenWrt 21.02 (fw3/iptables) 系统
# 参考 ShellCrash 项目风格

# ==========================================
#              全局变量
# ==========================================
VERSION="v26.1.001"
SCRIPT_NAME="singbox"
SCRIPT_PATH="/usr/local/bin/singbox"
SCRIPT_URL="https://raw.githubusercontent.com/aoaim/luanqi_bazao/main/linux_script/install_singbox.sh"

SINGBOX_BIN="/usr/bin/sing-box"
SINGBOX_DIR="/etc/sing-box"
SINGBOX_CONF="${SINGBOX_DIR}/config.json"
SINGBOX_FW="${SINGBOX_DIR}/firewall.sh"
SINGBOX_UI_DIR="${SINGBOX_DIR}/ui"
SINGBOX_RUNTIME="/var/lib/sing-box"
SINGBOX_INIT="/etc/init.d/sing-box"
SINGBOX_SUB_FILE="${SINGBOX_DIR}/subscription.url"

TPROXY_PORT=10555
MIXED_PORT=7890
API_PORT=9090
FWMARK=1

# GitHub 下载源
GITHUB_RELEASE="https://github.com/SagerNet/sing-box/releases"
GITHUB_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

# HubProxy 加速 (保存用户选择)
HUBPROXY_CONF="${SINGBOX_DIR}/hubproxy.conf"
HUBPROXY_DEFAULT="https://gh-proxy.com"
HUBPROXY_URL=""  # 运行时设置

# ==========================================
#              颜色与输出
# ==========================================
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    PLAIN='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    PLAIN=''
fi

log_success() { printf "${GREEN}✓ %s${PLAIN}\n" "$1"; }
log_error() { printf "${RED}✗ %s${PLAIN}\n" "$1"; }
log_info() { printf "${CYAN}ℹ %s${PLAIN}\n" "$1"; }
log_warn() { printf "${YELLOW}⚠ %s${PLAIN}\n" "$1"; }
log_action() { printf "${BLUE}→ %s${PLAIN}\n" "$1"; }

# ==========================================
#              HubProxy 加速模块
# ==========================================

# 加载 HubProxy 配置
load_hubproxy() {
    if [ -f "$HUBPROXY_CONF" ]; then
        HUBPROXY_URL=$(cat "$HUBPROXY_CONF" 2>/dev/null)
    fi
}

# 配置 HubProxy
setup_hubproxy() {
    echo ""
    echo "=========================================="
    printf "${CYAN}🚀 GitHub 加速配置${PLAIN}\n"
    echo "=========================================="
    echo ""
    echo "  1) 不使用加速 (直连 GitHub)"
    echo "  2) 使用公共加速 (${HUBPROXY_DEFAULT})"
    echo "  3) 使用自定义 HubProxy 实例"
    echo ""
    
    printf "请选择 [1]: "
    read proxy_choice
    proxy_choice=${proxy_choice:-1}
    
    case "$proxy_choice" in
        1)
            HUBPROXY_URL=""
            log_info "已设置为直连 GitHub"
            ;;
        2)
            HUBPROXY_URL="$HUBPROXY_DEFAULT"
            log_success "已设置公共加速: $HUBPROXY_URL"
            ;;
        3)
            printf "请输入 HubProxy 地址 (如 https://your-proxy.com): "
            read custom_proxy
            if [ -n "$custom_proxy" ]; then
                # 移除末尾斜杠
                HUBPROXY_URL="${custom_proxy%/}"
                log_success "已设置自定义加速: $HUBPROXY_URL"
            else
                HUBPROXY_URL=""
                log_warn "地址为空，使用直连"
            fi
            ;;
        *)
            HUBPROXY_URL=""
            log_info "使用直连 GitHub"
            ;;
    esac
    
    # 保存配置
    mkdir -p "$SINGBOX_DIR"
    echo "$HUBPROXY_URL" > "$HUBPROXY_CONF"
}

# 代理 GitHub URL
proxy_github_url() {
    local url="$1"
    
    if [ -n "$HUBPROXY_URL" ]; then
        # 使用 HubProxy 格式: https://proxy.com/https://github.com/...
        echo "${HUBPROXY_URL}/${url}"
    else
        echo "$url"
    fi
}

# ==========================================
#              脚本自更新模块
# ==========================================

# 比较版本号 (v26.1.001 格式)
# 返回: 0=相等, 1=第一个更大, 2=第二个更大
compare_version() {
    local v1="$1" v2="$2"
    # 移除 v 前缀
    v1="${v1#v}"
    v2="${v2#v}"
    
    # 转换为可比较的数字 (26.1.001 -> 260100001)
    local n1=$(echo "$v1" | awk -F'.' '{printf "%02d%02d%03d", $1, $2, $3}')
    local n2=$(echo "$v2" | awk -F'.' '{printf "%02d%02d%03d", $1, $2, $3}')
    
    if [ "$n1" -eq "$n2" ]; then
        return 0
    elif [ "$n1" -gt "$n2" ]; then
        return 1
    else
        return 2
    fi
}

# 获取远程脚本版本
get_remote_version() {
    local remote_ver=""
    if check_cmd curl; then
        remote_ver=$(curl -fsSL --connect-timeout 5 "$SCRIPT_URL" 2>/dev/null | grep '^VERSION=' | head -1 | sed 's/VERSION="\([^"]*\)"/\1/')
    elif check_cmd wget; then
        remote_ver=$(wget -qO- --timeout=5 "$SCRIPT_URL" 2>/dev/null | grep '^VERSION=' | head -1 | sed 's/VERSION="\([^"]*\)"/\1/')
    fi
    echo "$remote_ver"
}

# 检查脚本更新
check_script_update() {
    local remote_ver=$(get_remote_version)
    
    if [ -z "$remote_ver" ]; then
        return 1  # 无法获取远程版本
    fi
    
    compare_version "$VERSION" "$remote_ver"
    local result=$?
    
    if [ $result -eq 2 ]; then
        log_warn "发现新版本: $remote_ver (当前: $VERSION)"
        printf "${YELLOW}是否更新脚本？[y/N]: ${PLAIN}"
        read update_choice
        case "$update_choice" in
            y|Y)
                update_script
                ;;
            *)
                log_info "跳过更新"
                ;;
        esac
    fi
}

# 更新脚本
update_script() {
    log_action "下载新版本..."
    
    local tmp_script="/tmp/singbox_new.sh"
    if check_cmd curl; then
        curl -fsSL -o "$tmp_script" "$SCRIPT_URL" 2>/dev/null
    elif check_cmd wget; then
        wget -qO "$tmp_script" "$SCRIPT_URL" 2>/dev/null
    fi
    
    if [ ! -s "$tmp_script" ]; then
        log_error "下载失败"
        rm -f "$tmp_script"
        return 1
    fi
    
    # 验证下载的脚本
    if ! grep -q "^VERSION=" "$tmp_script"; then
        log_error "下载的脚本无效"
        rm -f "$tmp_script"
        return 1
    fi
    
    chmod +x "$tmp_script"
    mv "$tmp_script" "$SCRIPT_PATH"
    
    log_success "脚本已更新，请重新运行"
    exit 0
}

# 安装脚本到系统
install_script() {
    # 复制脚本到系统路径
    if [ ! -f "$SCRIPT_PATH" ] || [ "$(realpath "$0" 2>/dev/null)" != "$SCRIPT_PATH" ]; then
        cp "$0" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
    fi
    
    # 设置别名 (在 /etc/profile.d/ 下创建)
    local alias_file="/etc/profile.d/singbox-alias.sh"
    if [ ! -f "$alias_file" ]; then
        cat > "$alias_file" << 'EOF'
# Sing-box 管理脚本别名
alias sb='sudo /usr/local/bin/singbox'
EOF
        chmod +x "$alias_file"
        log_success "别名 'sb' 已设置 (重新登录后生效)"
    fi
}

# ==========================================
#              工具函数
# ==========================================

# 检查命令是否存在
check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用 root 用户运行此脚本"
        exit 1
    fi
}

# 检查系统类型
check_system() {
    if [ ! -f /etc/openwrt_release ]; then
        log_error "未检测到 OpenWrt 系统"
        exit 1
    fi
}

# 检查设备型号 (仅支持 GL-MT3600BE)
check_device() {
    local model=""
    if [ -f /tmp/sysinfo/model ]; then
        model=$(cat /tmp/sysinfo/model)
    fi
    
    if [ "$model" != "GL.iNet GL-MT3600BE" ]; then
        log_error "此脚本仅支持 GL.iNet GL-MT3600BE (Beryl 7)"
        log_error "当前设备: ${model:-未知}"
        exit 1
    fi
    
    log_success "设备验证通过: $model"
}

# 获取 CPU 架构 (GL-MT3600BE 固定为 arm64)
get_arch() {
    echo "arm64"
}

# 下载文件（带重试）
download_file() {
    local url="$1"
    local dest="$2"
    local retry=3
    local i=1

    while [ $i -le $retry ]; do
        if check_cmd curl; then
            curl -fsSL --connect-timeout 10 -o "$dest" "$url" && return 0
        elif check_cmd wget; then
            wget -q --timeout=10 -O "$dest" "$url" && return 0
        fi
        log_warn "下载失败，重试 $i/$retry..."
        i=$((i + 1))
        sleep 2
    done
    return 1
}

# 获取最新版本号
get_latest_version() {
    local version
    if check_cmd curl; then
        version=$(curl -fsSL "$GITHUB_API" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')
    elif check_cmd wget; then
        version=$(wget -qO- "$GITHUB_API" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')
    fi
    
    if [ -z "$version" ]; then
        echo "1.11.0"  # 默认版本
    else
        echo "$version"
    fi
}

# 获取已安装版本
get_installed_version() {
    if [ -x "$SINGBOX_BIN" ]; then
        "$SINGBOX_BIN" version 2>/dev/null | head -1 | awk '{print $3}'
    else
        echo ""
    fi
}

# 检查服务状态
is_running() {
    if [ -f "$SINGBOX_INIT" ]; then
        "$SINGBOX_INIT" status >/dev/null 2>&1
        return $?
    fi
    # 备用检查方式
    pgrep -f "sing-box run" >/dev/null 2>&1
}

# 生成随机密码
gen_password() {
    head -c 16 /dev/urandom | md5sum | head -c 16
}

# ==========================================
#              安装模块
# ==========================================

# 安装依赖
install_deps() {
    log_action "检查依赖..."
    
    local deps="kmod-ipt-tproxy iptables-mod-tproxy"
    local installed_pkgs=""
    local pkg_record="${SINGBOX_DIR}/installed_pkgs.txt"
    
    mkdir -p "$SINGBOX_DIR"
    
    for pkg in $deps; do
        if ! opkg list-installed 2>/dev/null | grep -q "^${pkg} "; then
            log_info "安装 ${pkg}..."
            opkg update >/dev/null 2>&1
            if opkg install "$pkg" >/dev/null 2>&1; then
                # 记录新安装的包
                installed_pkgs="$installed_pkgs $pkg"
            fi
        fi
    done
    
    # 保存新安装的包列表 (追加模式，避免覆盖)
    if [ -n "$installed_pkgs" ]; then
        echo "$installed_pkgs" >> "$pkg_record"
    fi
    
    log_success "依赖检查完成"
}

# 下载并安装核心
install_core() {
    local version="$1"
    local arch
    
    arch=$(get_arch)
    if [ "$arch" = "unknown" ]; then
        log_error "不支持的 CPU 架构: $(uname -m)"
        return 1
    fi
    
    if [ -z "$version" ]; then
        log_info "获取最新版本..."
        version=$(get_latest_version)
    fi
    
    log_action "下载 sing-box v${version} (${arch})..."
    
    local tmp_dir="/tmp/singbox_install"
    local github_url="${GITHUB_RELEASE}/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
    local download_url=$(proxy_github_url "$github_url")
    
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"
    
    if ! download_file "$download_url" "${tmp_dir}/sing-box.tar.gz"; then
        log_error "下载失败"
        rm -rf "$tmp_dir"
        return 1
    fi
    
    log_action "解压安装..."
    cd "$tmp_dir" || return 1
    tar -xzf sing-box.tar.gz
    
    local bin_path=$(find . -name "sing-box" -type f | head -1)
    if [ -z "$bin_path" ]; then
        log_error "解压失败，未找到二进制文件"
        rm -rf "$tmp_dir"
        return 1
    fi
    
    # 停止现有服务
    if [ -f "$SINGBOX_INIT" ]; then
        "$SINGBOX_INIT" stop >/dev/null 2>&1
    fi
    
    mv "$bin_path" "$SINGBOX_BIN"
    chmod +x "$SINGBOX_BIN"
    
    rm -rf "$tmp_dir"
    
    log_success "sing-box v${version} 安装完成"
    return 0
}

# 创建目录结构
create_dirs() {
    mkdir -p "$SINGBOX_DIR"
    mkdir -p "$SINGBOX_UI_DIR"
    mkdir -p "$SINGBOX_RUNTIME"
}

# ==========================================
#              配置模块
# ==========================================

# 生成默认配置
generate_config() {
    local tproxy_port="${1:-$TPROXY_PORT}"
    local mixed_port="${2:-$MIXED_PORT}"
    local api_port="${3:-$API_PORT}"
    local api_secret="${4:-$(gen_password)}"
    
    cat > "$SINGBOX_CONF" << EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "experimental": {
    "clash_api": {
      "external_controller": "0.0.0.0:${api_port}",
      "external_ui": "${SINGBOX_UI_DIR}",
      "external_ui_download_url": "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip",
      "external_ui_download_detour": "direct",
      "secret": "${api_secret}",
      "default_mode": "Rule"
    }
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-google",
        "address": "tls://8.8.8.8",
        "detour": "direct"
      },
      {
        "tag": "dns-alidns",
        "address": "https://223.5.5.5/dns-query",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "outbound": "any",
        "server": "dns-alidns"
      }
    ],
    "final": "dns-google"
  },
  "inbounds": [
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "::",
      "listen_port": ${tproxy_port},
      "sniff": true,
      "sniff_override_destination": true
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "::",
      "listen_port": ${mixed_port}
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      }
    ],
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF
    
    log_success "默认配置已生成"
    log_info "请手动编辑 ${SINGBOX_CONF} 添加代理节点"
    log_info "Clash API 密钥: ${api_secret}"
}

# 交互式配置
interactive_config() {
    local tproxy_port mixed_port api_port api_secret
    
    echo ""
    echo "=========================================="
    printf "${CYAN}⚙  Sing-box 配置向导${PLAIN}\n"
    echo "=========================================="
    echo ""
    
    # TProxy 端口
    printf "TProxy 透明代理端口 [${TPROXY_PORT}]: "
    read tproxy_port
    tproxy_port=${tproxy_port:-$TPROXY_PORT}
    
    # Mixed 端口
    printf "HTTP/SOCKS5 代理端口 [${MIXED_PORT}]: "
    read mixed_port
    mixed_port=${mixed_port:-$MIXED_PORT}
    
    # API 端口
    printf "Clash API 端口 [${API_PORT}]: "
    read api_port
    api_port=${api_port:-$API_PORT}
    
    # API 密钥
    local default_secret=$(gen_password)
    printf "Clash API 密钥 [${default_secret}]: "
    read api_secret
    api_secret=${api_secret:-$default_secret}
    
    echo ""
    generate_config "$tproxy_port" "$mixed_port" "$api_port" "$api_secret"
    
    # 更新防火墙端口
    TPROXY_PORT=$tproxy_port
}

# 验证配置
validate_config() {
    if [ ! -f "$SINGBOX_CONF" ]; then
        log_error "配置文件不存在: $SINGBOX_CONF"
        return 1
    fi
    
    if "$SINGBOX_BIN" check -c "$SINGBOX_CONF" >/dev/null 2>&1; then
        log_success "配置文件验证通过"
        return 0
    else
        log_error "配置文件验证失败"
        "$SINGBOX_BIN" check -c "$SINGBOX_CONF"
        return 1
    fi
}

# ==========================================
#              防火墙模块
# ==========================================

# 创建防火墙脚本
create_firewall_script() {
    local port="${1:-$TPROXY_PORT}"
    
    cat > "$SINGBOX_FW" << 'FWEOF'
#!/bin/sh
# Sing-box TProxy 防火墙规则
# 适用于 OpenWrt fw3 (iptables)

SINGBOX_PORT=PLACEHOLDER_PORT
SINGBOX_FWMARK=1

# 清理函数
cleanup_rules() {
    # 清理 IPv4 规则
    iptables -t mangle -D PREROUTING -j SINGBOX_DIVERT 2>/dev/null
    iptables -t mangle -F SINGBOX_DIVERT 2>/dev/null
    iptables -t mangle -X SINGBOX_DIVERT 2>/dev/null
    iptables -t mangle -D PREROUTING -p tcp -j SINGBOX_TPROXY 2>/dev/null
    iptables -t mangle -D PREROUTING -p udp -j SINGBOX_TPROXY 2>/dev/null
    iptables -t mangle -F SINGBOX_TPROXY 2>/dev/null
    iptables -t mangle -X SINGBOX_TPROXY 2>/dev/null
    
    # 清理 OUTPUT 链 (本机流量)
    iptables -t mangle -D OUTPUT -j SINGBOX_MARK 2>/dev/null
    iptables -t mangle -F SINGBOX_MARK 2>/dev/null
    iptables -t mangle -X SINGBOX_MARK 2>/dev/null
    
    # 清理策略路由
    ip rule del fwmark $SINGBOX_FWMARK table 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
}

# 停止
stop() {
    cleanup_rules
    echo "防火墙规则已清理"
}

# 启动
start() {
    cleanup_rules
    
    # 1. DIVERT 链：防止闭环
    iptables -t mangle -N SINGBOX_DIVERT
    iptables -t mangle -A SINGBOX_DIVERT -j MARK --set-mark $SINGBOX_FWMARK
    iptables -t mangle -A SINGBOX_DIVERT -j ACCEPT
    
    # 2. TPROXY 链：流量筛选与劫持
    iptables -t mangle -N SINGBOX_TPROXY
    
    # 排除局域网和私有地址
    iptables -t mangle -A SINGBOX_TPROXY -d 0.0.0.0/8 -j RETURN
    iptables -t mangle -A SINGBOX_TPROXY -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A SINGBOX_TPROXY -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A SINGBOX_TPROXY -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A SINGBOX_TPROXY -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A SINGBOX_TPROXY -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A SINGBOX_TPROXY -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A SINGBOX_TPROXY -d 240.0.0.0/4 -j RETURN
    
    # 已建立连接走 DIVERT
    iptables -t mangle -A SINGBOX_TPROXY -p tcp -m socket -j SINGBOX_DIVERT
    iptables -t mangle -A SINGBOX_TPROXY -p udp -m socket -j SINGBOX_DIVERT
    
    # 新连接走 TPROXY
    iptables -t mangle -A SINGBOX_TPROXY -p tcp -j TPROXY --on-port $SINGBOX_PORT --tproxy-mark $SINGBOX_FWMARK
    iptables -t mangle -A SINGBOX_TPROXY -p udp -j TPROXY --on-port $SINGBOX_PORT --tproxy-mark $SINGBOX_FWMARK
    
    # 3. 应用到 PREROUTING (处理局域网设备流量)
    iptables -t mangle -A PREROUTING -p tcp -j SINGBOX_TPROXY
    iptables -t mangle -A PREROUTING -p udp -j SINGBOX_TPROXY
    
    # 4. 策略路由
    ip rule add fwmark $SINGBOX_FWMARK table 100 2>/dev/null
    ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null
    
    echo "防火墙规则已应用"
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        stop
        start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac
FWEOF
    
    # 替换端口占位符
    sed -i "s/PLACEHOLDER_PORT/${port}/" "$SINGBOX_FW"
    chmod +x "$SINGBOX_FW"
    
    log_success "防火墙脚本已创建"
}

# ==========================================
#              服务模块
# ==========================================

# 创建 procd 服务
create_service() {
    cat > "$SINGBOX_INIT" << 'INITEOF'
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

PROG=/usr/bin/sing-box
CONF=/etc/sing-box/config.json
FIREWALL_SCRIPT=/etc/sing-box/firewall.sh
RUNTIME_DIR=/var/lib/sing-box

start_service() {
    mkdir -p $RUNTIME_DIR
    
    procd_open_instance
    procd_set_param command $PROG run -c $CONF -D $RUNTIME_DIR
    procd_set_param user root
    procd_set_param respawn ${respawn_threshold:-3600} ${respawn_timeout:-5} ${respawn_retry:-5}
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
    
    # 启动防火墙劫持
    sleep 1
    [ -x "$FIREWALL_SCRIPT" ] && $FIREWALL_SCRIPT start
}

stop_service() {
    [ -x "$FIREWALL_SCRIPT" ] && $FIREWALL_SCRIPT stop
}

reload_service() {
    stop
    start
}

service_triggers() {
    procd_add_reload_trigger "sing-box"
}
INITEOF
    
    chmod +x "$SINGBOX_INIT"
    log_success "系统服务已创建"
}

# 启动服务
start_service() {
    if ! validate_config; then
        return 1
    fi
    
    "$SINGBOX_INIT" start
    sleep 2
    
    if is_running; then
        log_success "sing-box 已启动"
    else
        log_error "sing-box 启动失败"
        return 1
    fi
}

# 停止服务
stop_service() {
    "$SINGBOX_INIT" stop
    log_success "sing-box 已停止"
}

# 重启服务
restart_service() {
    "$SINGBOX_INIT" restart
    sleep 2
    
    if is_running; then
        log_success "sing-box 已重启"
    else
        log_error "sing-box 重启失败"
        return 1
    fi
}

# 启用开机自启
enable_autostart() {
    "$SINGBOX_INIT" enable
    log_success "已设置开机自启"
}

# 禁用开机自启
disable_autostart() {
    "$SINGBOX_INIT" disable
    log_success "已取消开机自启"
}

# ==========================================
#              订阅模块
# ==========================================

# 更新订阅
# 生成基础配置模板（不含代理节点）
generate_base_template() {
    local tproxy_port="${1:-$TPROXY_PORT}"
    local mixed_port="${2:-$MIXED_PORT}"
    local api_port="${3:-$API_PORT}"
    local api_secret="${4:-$(gen_password)}"
    local template_file="${SINGBOX_DIR}/config_template.json"
    
    cat > "$template_file" << EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "experimental": {
    "clash_api": {
      "external_controller": "0.0.0.0:${api_port}",
      "external_ui": "${SINGBOX_UI_DIR}",
      "external_ui_download_url": "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip",
      "external_ui_download_detour": "Proxy",
      "secret": "${api_secret}",
      "default_mode": "Rule"
    }
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-google",
        "address": "tls://8.8.8.8",
        "detour": "Proxy"
      },
      {
        "tag": "dns-alidns",
        "address": "https://223.5.5.5/dns-query",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "outbound": "any",
        "server": "dns-alidns"
      }
    ],
    "final": "dns-google"
  },
  "inbounds": [
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "::",
      "listen_port": ${tproxy_port},
      "sniff": true,
      "sniff_override_destination": true
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "::",
      "listen_port": ${mixed_port}
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "Proxy",
      "outbounds": ["auto", "direct"],
      "default": "auto"
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": [],
      "url": "https://www.gstatic.com/generate_204",
      "interval": "5m"
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      },
      {
        "domain_suffix": [".cn"],
        "outbound": "direct"
      },
      {
        "geoip": "cn",
        "outbound": "direct"
      }
    ],
    "final": "Proxy",
    "auto_detect_interface": true
  }
}
EOF
    
    log_success "配置模板已生成: $template_file"
}

# 合并 provider outbounds 到配置
merge_provider_config() {
    local provider_file="$1"
    local template_file="${SINGBOX_DIR}/config_template.json"
    local output_file="$SINGBOX_CONF"
    
    # 检查模板是否存在
    if [ ! -f "$template_file" ]; then
        log_error "配置模板不存在，请先运行安装配置"
        return 1
    fi
    
    # 提取 provider 中的节点 tags
    local node_tags=$(awk -F'"' '/"tag"/ {print $4}' "$provider_file" | tr '\n' ',' | sed 's/,$//')
    
    if [ -z "$node_tags" ]; then
        log_error "Provider 中没有找到有效节点"
        return 1
    fi
    
    log_info "发现 $(echo "$node_tags" | tr ',' '\n' | wc -l | tr -d ' ') 个节点"
    
    # 使用 awk 合并配置
    # 1. 读取模板
    # 2. 在 "outbounds" 数组中插入 provider 节点
    # 3. 更新 Proxy selector 和 auto urltest 的 outbounds 列表
    
    awk -v provider="$provider_file" -v node_tags="$node_tags" '
    BEGIN {
        # 读取 provider 的 outbounds
        while ((getline line < provider) > 0) {
            provider_content = provider_content line "\n"
        }
        close(provider)
        
        # 提取 provider 的 outbounds 数组内容（去掉外层括号）
        match(provider_content, /"outbounds"[[:space:]]*:[[:space:]]*\[/)
        if (RSTART > 0) {
            rest = substr(provider_content, RSTART + RLENGTH)
            # 找到匹配的 ]
            depth = 1
            for (i = 1; i <= length(rest); i++) {
                c = substr(rest, i, 1)
                if (c == "[") depth++
                else if (c == "]") {
                    depth--
                    if (depth == 0) {
                        provider_outbounds = substr(rest, 1, i-1)
                        break
                    }
                }
            }
        }
    }
    
    # 处理模板，在 outbounds 数组中合适位置插入节点
    {
        # 检测 Proxy selector 的 outbounds
        if (/"outbounds"[[:space:]]*:[[:space:]]*\["auto"/) {
            # 替换为包含所有节点的列表
            gsub(/\["auto"[^]]*\]/, "[\"auto\", " node_tags_quoted "]")
        }
        
        # 检测 auto urltest 的空 outbounds
        if (/"outbounds"[[:space:]]*:[[:space:]]*\[\]/) {
            # 替换为节点列表
            gsub(/\[\]/, "[" node_tags_quoted "]")
        }
        
        print
    }
    ' "$template_file" > /tmp/singbox_merged_tmp.json
    
    # 由于 awk 处理 JSON 比较困难，使用更简单的方法：
    # 直接读取模板，替换关键部分
    
    # 备份当前配置
    if [ -f "$output_file" ]; then
        cp "$output_file" "${output_file}.bak"
    fi
    
    # 简化处理：直接生成新配置
    local tags_json=$(echo "$node_tags" | sed 's/,/", "/g' | sed 's/^/["/' | sed 's/$/"]/')
    local tags_for_selector=$(echo "\"auto\", $node_tags" | sed 's/,/, "/g' | sed 's/", $//')
    
    # 读取 provider outbounds
    local provider_outbounds=$(cat "$provider_file" | sed -n '/"outbounds"/,/^}/p' | sed '1d;$d')
    
    # 获取模板的配置值
    local tproxy_port=$(grep -o '"listen_port": [0-9]*' "$template_file" | head -1 | grep -o '[0-9]*')
    local mixed_port=$(grep -o '"listen_port": [0-9]*' "$template_file" | tail -1 | grep -o '[0-9]*')
    local api_port=$(grep -o '"external_controller": "[^"]*"' "$template_file" | grep -o ':[0-9]*' | grep -o '[0-9]*')
    local api_secret=$(grep -o '"secret": "[^"]*"' "$template_file" | sed 's/.*: "\([^"]*\)".*/\1/')
    
    tproxy_port=${tproxy_port:-$TPROXY_PORT}
    mixed_port=${mixed_port:-$MIXED_PORT}
    api_port=${api_port:-$API_PORT}
    api_secret=${api_secret:-$(gen_password)}

    # 生成完整配置
    cat > "$output_file" << CONFIGEOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "experimental": {
    "clash_api": {
      "external_controller": "0.0.0.0:${api_port}",
      "external_ui": "${SINGBOX_UI_DIR}",
      "external_ui_download_url": "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip",
      "external_ui_download_detour": "Proxy",
      "secret": "${api_secret}",
      "default_mode": "Rule"
    }
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-google",
        "address": "tls://8.8.8.8",
        "detour": "Proxy"
      },
      {
        "tag": "dns-alidns",
        "address": "https://223.5.5.5/dns-query",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "outbound": "any",
        "server": "dns-alidns"
      }
    ],
    "final": "dns-google"
  },
  "inbounds": [
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "::",
      "listen_port": ${tproxy_port},
      "sniff": true,
      "sniff_override_destination": true
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "::",
      "listen_port": ${mixed_port}
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "Proxy",
      "outbounds": [${tags_for_selector}],
      "default": "auto"
    },
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ${tags_json},
      "url": "https://www.gstatic.com/generate_204",
      "interval": "5m"
    },
${provider_outbounds}
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      },
      {
        "domain_suffix": [".cn"],
        "outbound": "direct"
      },
      {
        "geoip": "cn",
        "outbound": "direct"
      }
    ],
    "final": "Proxy",
    "auto_detect_interface": true
  }
}
CONFIGEOF
    
    rm -f /tmp/singbox_merged_tmp.json
    
    # 验证生成的配置
    if "$SINGBOX_BIN" check -c "$output_file" >/dev/null 2>&1; then
        log_success "配置合并并验证成功"
        return 0
    else
        log_error "配置验证失败"
        "$SINGBOX_BIN" check -c "$output_file" 2>&1 | head -5
        # 恢复备份
        if [ -f "${output_file}.bak" ]; then
            mv "${output_file}.bak" "$output_file"
        fi
        return 1
    fi
}

# 更新订阅
update_subscription() {
    local url="$1"
    
    if [ -z "$url" ]; then
        if [ -f "$SINGBOX_SUB_FILE" ]; then
            url=$(cat "$SINGBOX_SUB_FILE")
        fi
    fi
    
    if [ -z "$url" ]; then
        log_error "未设置订阅地址"
        printf "请输入 Provider 订阅 URL: "
        read url
        if [ -z "$url" ]; then
            return 1
        fi
    fi
    
    log_action "下载 Provider 节点..."
    
    local tmp_provider="/tmp/singbox_provider.json"
    if ! download_file "$url" "$tmp_provider"; then
        log_error "订阅下载失败"
        return 1
    fi
    
    # 检查是否为 provider 格式 (只有 outbounds)
    if grep -q '"outbounds"' "$tmp_provider" && ! grep -q '"inbounds"' "$tmp_provider"; then
        log_info "检测到 Provider 格式，合并配置..."
        
        # 确保模板存在
        if [ ! -f "${SINGBOX_DIR}/config_template.json" ]; then
            log_info "生成配置模板..."
            generate_base_template
        fi
        
        if ! merge_provider_config "$tmp_provider"; then
            rm -f "$tmp_provider"
            return 1
        fi
    else
        # 完整配置格式
        log_info "检测到完整配置格式..."
        if ! "$SINGBOX_BIN" check -c "$tmp_provider" >/dev/null 2>&1; then
            log_error "配置验证失败"
            rm -f "$tmp_provider"
            return 1
        fi
        
        if [ -f "$SINGBOX_CONF" ]; then
            cp "$SINGBOX_CONF" "${SINGBOX_CONF}.bak"
        fi
        mv "$tmp_provider" "$SINGBOX_CONF"
    fi
    
    rm -f "$tmp_provider"
    echo "$url" > "$SINGBOX_SUB_FILE"
    
    log_success "订阅更新成功"
    
    # 重启服务
    if is_running; then
        restart_service
    fi
}

# 设置自动更新
setup_cron() {
    local hour="${1:-4}"
    
    # 检查订阅 URL
    if [ ! -f "$SINGBOX_SUB_FILE" ]; then
        log_error "请先设置订阅地址"
        return 1
    fi
    
    # 添加 cron 任务
    local cron_cmd="0 ${hour} * * * /bin/sh -c '${0} update-sub' >/dev/null 2>&1"
    
    # 移除旧任务
    crontab -l 2>/dev/null | grep -v "singbox" | grep -v "sing-box" > /tmp/cron_tmp
    echo "$cron_cmd" >> /tmp/cron_tmp
    crontab /tmp/cron_tmp
    rm -f /tmp/cron_tmp
    
    log_success "已设置每天 ${hour}:00 自动更新订阅"
}

# ==========================================
#              卸载模块
# ==========================================

uninstall() {
    echo ""
    printf "${YELLOW}确定要卸载 sing-box 吗？[y/N]: ${PLAIN}"
    read confirm
    
    case "$confirm" in
        y|Y|yes|YES)
            ;;
        *)
            log_info "取消卸载"
            return 0
            ;;
    esac
    
    # 1. 停止服务
    log_action "停止服务..."
    if [ -f "$SINGBOX_INIT" ]; then
        "$SINGBOX_INIT" stop >/dev/null 2>&1
        "$SINGBOX_INIT" disable >/dev/null 2>&1
    fi
    
    # 2. 清理防火墙规则 (即使脚本已删除也能清理)
    log_action "清理防火墙规则..."
    if [ -f "$SINGBOX_FW" ]; then
        "$SINGBOX_FW" stop >/dev/null 2>&1
    else
        # 手动清理 iptables 规则
        iptables -t mangle -D PREROUTING -j SINGBOX_DIVERT 2>/dev/null
        iptables -t mangle -F SINGBOX_DIVERT 2>/dev/null
        iptables -t mangle -X SINGBOX_DIVERT 2>/dev/null
        iptables -t mangle -D PREROUTING -p tcp -j SINGBOX_TPROXY 2>/dev/null
        iptables -t mangle -D PREROUTING -p udp -j SINGBOX_TPROXY 2>/dev/null
        iptables -t mangle -F SINGBOX_TPROXY 2>/dev/null
        iptables -t mangle -X SINGBOX_TPROXY 2>/dev/null
        iptables -t mangle -D OUTPUT -j SINGBOX_MARK 2>/dev/null
        iptables -t mangle -F SINGBOX_MARK 2>/dev/null
        iptables -t mangle -X SINGBOX_MARK 2>/dev/null
        ip rule del fwmark 1 table 100 2>/dev/null
        ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    fi
    
    # 3. 卸载新安装的包
    local pkg_record="${SINGBOX_DIR}/installed_pkgs.txt"
    if [ -f "$pkg_record" ]; then
        log_action "卸载依赖包..."
        for pkg in $(cat "$pkg_record" | tr ' ' '\n' | sort -u); do
            if [ -n "$pkg" ] && opkg list-installed 2>/dev/null | grep -q "^${pkg} "; then
                log_info "卸载 ${pkg}..."
                opkg remove "$pkg" >/dev/null 2>&1
            fi
        done
    fi
    
    # 4. 删除 sing-box 文件
    log_action "删除文件..."
    rm -f "$SINGBOX_BIN"
    rm -f "$SINGBOX_INIT"
    rm -rf "$SINGBOX_DIR"
    rm -rf "$SINGBOX_RUNTIME"
    
    # 5. 清理管理脚本和别名
    log_action "清理脚本和别名..."
    rm -f "$SCRIPT_PATH"
    rm -f /etc/profile.d/singbox-alias.sh
    
    # 6. 清理 cron
    crontab -l 2>/dev/null | grep -v "singbox" | grep -v "sing-box" | crontab - 2>/dev/null
    
    echo ""
    log_success "sing-box 已完全卸载"
    log_info "防火墙规则已清理"
    log_info "新安装的依赖包已卸载"
    log_info "请重新登录以移除 'sb' 别名"
}

# ==========================================
#              状态显示
# ==========================================

show_status() {
    echo ""
    echo "=========================================="
    printf "${CYAN}  Sing-box 运行状态${PLAIN}\n"
    echo "=========================================="
    echo ""
    
    # 安装状态
    printf "安装状态: "
    if [ -x "$SINGBOX_BIN" ]; then
        local ver=$(get_installed_version)
        printf "${GREEN}已安装${PLAIN} (v${ver})\n"
    else
        printf "${RED}未安装${PLAIN}\n"
        return
    fi
    
    # 运行状态
    printf "运行状态: "
    if is_running; then
        printf "${GREEN}运行中${PLAIN}\n"
    else
        printf "${RED}已停止${PLAIN}\n"
    fi
    
    # 开机自启
    printf "开机自启: "
    if [ -f "$SINGBOX_INIT" ] && "$SINGBOX_INIT" enabled 2>/dev/null; then
        printf "${GREEN}已启用${PLAIN}\n"
    else
        printf "${YELLOW}未启用${PLAIN}\n"
    fi
    
    # 配置文件
    printf "配置文件: "
    if [ -f "$SINGBOX_CONF" ]; then
        printf "${GREEN}存在${PLAIN}\n"
    else
        printf "${RED}不存在${PLAIN}\n"
    fi
    
    # 防火墙规则
    printf "防火墙规则: "
    if iptables -t mangle -L SINGBOX_TPROXY >/dev/null 2>&1; then
        printf "${GREEN}已加载${PLAIN}\n"
    else
        printf "${YELLOW}未加载${PLAIN}\n"
    fi
    
    # 端口信息
    if [ -f "$SINGBOX_CONF" ]; then
        echo ""
        echo "端口配置:"
        local tproxy=$(grep -o '"listen_port": [0-9]*' "$SINGBOX_CONF" | head -1 | grep -o '[0-9]*')
        local mixed=$(grep -o '"listen_port": [0-9]*' "$SINGBOX_CONF" | tail -1 | grep -o '[0-9]*')
        local api=$(grep -o '"external_controller": "[^"]*"' "$SINGBOX_CONF" | grep -o ':[0-9]*' | grep -o '[0-9]*')
        
        [ -n "$tproxy" ] && echo "  TProxy: $tproxy"
        [ -n "$mixed" ] && echo "  Mixed:  $mixed"
        [ -n "$api" ] && echo "  API:    $api (http://$(ip route get 1 | awk '{print $7}' 2>/dev/null || echo "路由器IP"):${api}/ui)"
    fi
    
    echo ""
}

# ==========================================
#              交互式菜单
# ==========================================

show_menu() {
    clear
    local installed_ver=$(get_installed_version)
    local status_text
    
    if is_running; then
        status_text="${GREEN}运行中${PLAIN}"
    elif [ -n "$installed_ver" ]; then
        status_text="${YELLOW}已停止${PLAIN}"
    else
        status_text="${RED}未安装${PLAIN}"
    fi
    
    echo ""
    echo "╔══════════════════════════════════════════╗"
    printf "║      ${CYAN}Sing-box 管理脚本${PLAIN} v${VERSION}           ║\n"
    echo "╠══════════════════════════════════════════╣"
    printf "║  状态: ${status_text}                            ║\n"
    if [ -n "$installed_ver" ]; then
    printf "║  版本: v${installed_ver}                              ║\n"
    fi
    echo "╠══════════════════════════════════════════╣"
    echo "║                                          ║"
    echo "║   1) 安装 sing-box                       ║"
    echo "║   2) 卸载 sing-box                       ║"
    echo "║   3) 更新 sing-box 核心                  ║"
    echo "║   ──────────────────────                 ║"
    echo "║   4) 启动服务                            ║"
    echo "║   5) 停止服务                            ║"
    echo "║   6) 重启服务                            ║"
    echo "║   ──────────────────────                 ║"
    echo "║   7) 查看运行状态                        ║"
    echo "║   8) 编辑配置文件                        ║"
    echo "║   9) 验证配置文件                        ║"
    echo "║   ──────────────────────                 ║"
    echo "║  10) 更新订阅配置                        ║"
    echo "║  11) 设置自动更新                        ║"
    echo "║  12) 配置 GitHub 加速                    ║"
    echo "║   ──────────────────────                 ║"
    echo "║   0) 退出                                ║"
    echo "║                                          ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    printf "请输入选项 [0-12]: "
}

# 完整安装流程
full_install() {
    echo ""
    log_action "开始安装 sing-box..."
    echo ""
    
    # 检查是否已安装
    if [ -x "$SINGBOX_BIN" ]; then
        log_warn "sing-box 已安装，将进行更新"
    fi
    
    # 配置 GitHub 加速 (首次安装或未配置时)
    if [ ! -f "$HUBPROXY_CONF" ]; then
        setup_hubproxy
    fi
    
    # 安装依赖
    install_deps
    
    # 下载核心
    if ! install_core; then
        log_error "核心安装失败"
        return 1
    fi
    
    # 创建目录
    create_dirs
    
    # 交互式配置
    if [ ! -f "$SINGBOX_CONF" ]; then
        interactive_config
    else
        printf "检测到现有配置，是否重新配置？[y/N]: "
        read reconf
        case "$reconf" in
            y|Y)
                interactive_config
                ;;
        esac
    fi
    
    # 创建防火墙脚本
    create_firewall_script "$TPROXY_PORT"
    
    # 创建服务
    create_service
    
    # 启用开机自启
    enable_autostart
    
    # 启动服务
    echo ""
    printf "是否立即启动服务？[Y/n]: "
    read start_now
    start_now=${start_now:-Y}
    
    case "$start_now" in
        n|N)
            ;;
        *)
            start_service
            ;;
    esac
    
    echo ""
    log_success "安装完成！"
    show_status
}

# ==========================================
#              主函数
# ==========================================

main() {
    check_root
    check_system
    check_device
    
    # 安装脚本到系统 (首次运行)
    install_script
    
    # 加载 HubProxy 配置
    load_hubproxy
    
    # 检查脚本更新
    check_script_update
    
    # 命令行参数处理
    case "$1" in
        install)
            full_install
            return
            ;;
        uninstall)
            uninstall
            return
            ;;
        update)
            install_core
            return
            ;;
        start)
            start_service
            return
            ;;
        stop)
            stop_service
            return
            ;;
        restart)
            restart_service
            return
            ;;
        status)
            show_status
            return
            ;;
        update-sub)
            update_subscription
            return
            ;;
        *)
            ;;
    esac
    
    # 交互式菜单
    while true; do
        show_menu
        read choice
        
        case "$choice" in
            1)
                full_install
                ;;
            2)
                uninstall
                ;;
            3)
                install_core
                ;;
            4)
                start_service
                ;;
            5)
                stop_service
                ;;
            6)
                restart_service
                ;;
            7)
                show_status
                ;;
            8)
                if check_cmd vi; then
                    vi "$SINGBOX_CONF"
                elif check_cmd nano; then
                    nano "$SINGBOX_CONF"
                else
                    log_error "未找到文本编辑器"
                fi
                ;;
            9)
                validate_config
                ;;
            10)
                printf "请输入订阅 URL (留空使用已保存的): "
                read sub_url
                update_subscription "$sub_url"
                ;;
            11)
                printf "请输入更新时间 (0-23 小时) [4]: "
                read hour
                hour=${hour:-4}
                setup_cron "$hour"
                ;;
            12)
                setup_hubproxy
                ;;
            0)
                echo ""
                log_info "再见！"
                exit 0
                ;;
            *)
                log_error "无效选项"
                ;;
        esac
        
        echo ""
        printf "按 Enter 键继续..."
        read _
    done
}

main "$@"
