#!/bin/bash

# 参考 https://cdn.skk.moe/sh/optimize.sh
# 严格模式：任何命令失败都会中断脚本
set -e
set -u
set -o pipefail

SCRIPT_VERSION="1.0.0"
MARKER_FILE="/var/lib/init_linux_run.marker"
BACKUP_DIR="/root/init_linux_backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

error_exit() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "❌ Error occurred at line $1"
    echo "❌ Script execution failed. Please check the error message above."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
}
trap 'error_exit $LINENO' ERR

if [ "$(id -u)" != "0" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "❌ Error: You must be root to run this script"
    echo "💡 Please run with: sudo bash $0"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
fi

if [ -f "$MARKER_FILE" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "⚠️  This script has already been run on: $(cat "$MARKER_FILE")"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -p "Do you want to continue anyway? This may overwrite existing configurations. (yes/no): " continue_run
    if [ "$continue_run" != "yes" ]; then
        echo "Exiting..."
        exit 0
    fi
    echo "Continuing with reconfiguration..."
fi

# 仅允许 Debian 13 amd64
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "debian" ]; then
        echo "Error: This script only supports Debian (detected: $PRETTY_NAME)"
        exit 1
    fi
    DEBIAN_VERSION=$(cat /etc/debian_version | cut -d. -f1)
    ARCH=$(uname -m)
    if [ "$DEBIAN_VERSION" != "13" ]; then
        echo "Error: This script only supports Debian 13 (detected: Debian $DEBIAN_VERSION)"
        exit 1
    fi
    if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "amd64" ]; then
        echo "Error: This script only supports amd64 architecture (detected: $ARCH)"
        exit 1
    fi
    echo "✓ Running on Debian 13 amd64"
fi

mkdir -p "$BACKUP_DIR"
echo "✓ Backup directory created: $BACKUP_DIR"

backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        cp "$file" "${BACKUP_DIR}/$(basename "$file").${TIMESTAMP}.bak"
        echo "  Backed up: $file"
    fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 Updating system and installing packages..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
apt update && apt upgrade -y && apt autoremove -y
apt install -y openssl gnupg net-tools dnsutils nload curl wget lsof nano htop cron haveged vnstat chrony iftop iotop fail2ban unattended-upgrades unzip logrotate

echo "Configuring unattended-upgrades..."
if dpkg -l | grep -q "^ii.*unattended-upgrades"; then
    echo "✓ unattended-upgrades installed successfully"
    echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections
    dpkg-reconfigure -f noninteractive unattended-upgrades
    if [ -f /etc/apt/apt.conf.d/20auto-upgrades ]; then
        echo "✓ Auto-updates configuration created"
    fi
    if systemctl is-enabled apt-daily.timer >/dev/null 2>&1; then
        echo "✓ apt-daily.timer is enabled"
    fi
    if systemctl is-enabled apt-daily-upgrade.timer >/dev/null 2>&1; then
        echo "✓ apt-daily-upgrade.timer is enabled"
    fi
    echo "✓ Unattended-upgrades configured and enabled"
else
    echo "⚠️  Warning: unattended-upgrades installation could not be verified"
fi

# speedtest-cli 仅支持 Debian 13 amd64，直接下载安装
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📡 Installing speedtest-cli (Ookla official deb)..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
SPEEDTEST_DEB_URL="https://packagecloud.io/ookla/speedtest-cli/packages/debian/trixie/speedtest_1.2.0.84-1.ea6b6773cf_amd64.deb/download.deb?distro_version_id=221"
wget --content-disposition "$SPEEDTEST_DEB_URL" -O speedtest.deb
if [ -s speedtest.deb ]; then
    dpkg -i speedtest.deb || apt-get install -f -y
    rm -f speedtest.deb
    echo "✓ Speedtest-cli installed"
else
    echo "❌ Failed to download speedtest deb package"
    exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📝 Installing Helix editor..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
HELIX_INSTALLED=false
for attempt in 1 2 3; do
    echo "Attempt $attempt: Fetching latest Helix editor release..."
    LATEST_HELIX_URL=$(curl -s --max-time 10 https://api.github.com/repos/helix-editor/helix/releases/latest 2>/dev/null | grep -m1 '"browser_download_url".*amd64\.deb"' | cut -d'"' -f4 || true)
    if [ -n "$LATEST_HELIX_URL" ]; then
        echo "Downloading Helix from: $LATEST_HELIX_URL"
        if wget -q --timeout=30 -O helix.deb "$LATEST_HELIX_URL" 2>/dev/null && [ -f helix.deb ] && [ -s helix.deb ]; then
            if dpkg -i helix.deb 2>/dev/null; then
                apt-get install -f -y
                rm -f helix.deb
                HELIX_INSTALLED=true
                echo "✓ Helix editor installed successfully"
                break
            else
                echo "⚠️  Failed to install downloaded package, retrying..."
                rm -f helix.deb
            fi
        else
            echo "⚠️  Download failed, retrying..."
            rm -f helix.deb
        fi
    else
        echo "⚠️  Failed to fetch release URL, retrying..."
    fi
    sleep 2
done
if [ "$HELIX_INSTALLED" = false ]; then
    echo "⚠️  Warning: Could not install Helix editor from GitHub"
    echo "ℹ️  You can install it manually later from: https://helix-editor.com"
fi
if [ "$HELIX_INSTALLED" = true ]; then
    cat > /etc/profile.d/helix-alias.sh <<'EOF'
alias vi='hx'
alias vim='hx'
EOF
    chmod 644 /etc/profile.d/helix-alias.sh
    echo "✓ Helix aliased to vi/vim"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📁 Installing eza..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
mkdir -p /etc/apt/keyrings
wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc | gpg --batch --yes --dearmor -o /etc/apt/keyrings/gierens.gpg
echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" | tee /etc/apt/sources.list.d/gierens.list
chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
apt update
apt install -y eza
cat > /etc/profile.d/eza-alias.sh <<'EOF'
alias ls='eza'
alias ll='eza -lh --icons --git'
alias la='eza -lah --icons --git'
alias lt='eza -lh --icons --git --tree'
alias l='eza -lah --icons --git'
EOF
chmod 644 /etc/profile.d/eza-alias.sh
echo "✓ Eza installed and aliased to ls"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⏰ Configuring time synchronization..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
backup_file /etc/chrony/chrony.conf
cat > /etc/chrony/chrony.conf <<EOF
server 0.asia.pool.ntp.org iburst
server 1.asia.pool.ntp.org iburst
server 2.asia.pool.ntp.org iburst
server 3.asia.pool.ntp.org iburst
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
log tracking measurements statistics
logdir /var/log/chrony
EOF
systemctl enable --now chrony
sleep 2
chronyc tracking || true
echo "Waiting for time synchronization..."
for i in {1..12}; do
    status=$(chronyc tracking 2>/dev/null | grep 'Leap status' | cut -d':' -f2 | xargs || echo "Unknown")
    if [[ "$status" == "Normal" ]]; then
        echo "✓ Time synchronized"
        break
    fi
    sleep 5
done
timedatectl set-timezone Asia/Singapore
echo "✓ Timezone set to Asia/Singapore"
systemctl enable --now haveged
echo "✓ Haveged enabled"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔧 Installing and configuring random number generators..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
# 安装 rng-tools 改善随机数生成器性能
# 用于加速 SSL/TLS 连接、密钥生成等需要随机数的操作
if [[ -z "$(command -v rngd)" ]]; then
    echo "Installing rng-tools..."
    apt install -y rng-tools
fi

if systemctl list-unit-files | grep -q '^rng-tools-debian.service'; then
    systemctl enable --now rng-tools-debian
else
    systemctl enable --now rngd.service 2>/dev/null || \
        systemctl enable --now rngd 2>/dev/null || \
        systemctl enable --now rng-tools 2>/dev/null || true
fi
echo "✓ rng-tools installed and enabled"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚫 Disabling ksmtuned..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
# 禁用 KSM (Kernel Samepage Merging) 以降低 CPU 开销和延迟波动
# KSM 主要用于虚拟化环境节省内存，对物理机和性能敏感应用不利
if [[ ! -z "$(command -v ksmtuned)" ]]; then
    echo "Disabling and removing ksmtuned..."
    # 停止 KSM 扫描进程
    echo 2 > /sys/kernel/mm/ksm/run

    apt purge tuned --autoremove -y || true
    apt purge ksmtuned --autoremove -y || true

    rm -rf /etc/systemd/system/ksmtuned.service
    mv /usr/sbin/ksmtuned /usr/sbin/ksmtuned.bak || true
    touch /usr/sbin/ksmtuned
    echo "# KSMTUNED DISABLED" > /usr/sbin/ksmtuned
    echo "✓ ksmtuned disabled and removed"
else
    echo "✓ ksmtuned not found, skipping"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚫 Disabling transparent huge pages..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
# 禁用透明大页 (THP) 以避免延迟峰值和内存碎片
# THP 会导致不可预测的延迟波动，数据库 (Redis/MongoDB/PostgreSQL) 强烈建议禁用
cat > /etc/systemd/system/disable-transparent-huge-pages.service << 'THPEOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=mongod.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never | tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null'
ExecStart=/bin/sh -c 'echo never | tee /sys/kernel/mm/transparent_hugepage/defrag > /dev/null'
[Install]
WantedBy=basic.target
THPEOF

systemctl daemon-reload
systemctl start disable-transparent-huge-pages
systemctl enable disable-transparent-huge-pages
echo "✓ Transparent huge pages disabled"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 Loading kernel modules..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
# 加载必要的内核模块
# nf_conntrack: 连接跟踪模块，用于防火墙和 NAT
# tls: 内核 TLS 加速，提升 HTTPS 性能
mkdir -p /usr/lib/modules-load.d
echo nf_conntrack > /usr/lib/modules-load.d/network-performance.conf
echo tls >> /usr/lib/modules-load.d/network-performance.conf
modprobe nf_conntrack 2>/dev/null || true
modprobe tls 2>/dev/null || true
echo "✓ Kernel modules configured (nf_conntrack, tls)"
systemctl enable --now vnstat
echo "✓ Vnstat enabled"
systemctl enable --now fail2ban
echo "✓ Fail2ban enabled"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📝 Configuring journald..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
backup_file /etc/systemd/journald.conf
# 限制 journald 日志大小，防止占用过多磁盘空间
# SystemMaxUse: 持久化日志最大占用空间 (384MB)
# RuntimeMaxUse: 运行时日志最大占用空间 (256MB)
# MaxRetentionSec: 日志最长保留时间 (1天 = 86400秒)
# MaxFileSec: 单个日志文件最长保留时间 (3天 = 259200秒)
cat > /etc/systemd/journald.conf <<'EOF'
[Journal]
SystemMaxUse=384M
SystemMaxFileSize=128M
SystemMaxFiles=3
RuntimeMaxUse=256M
RuntimeMaxFileSize=128M
RuntimeMaxFiles=3
MaxRetentionSec=86400
MaxFileSec=259200
ForwardToSyslog=no
EOF
systemctl restart systemd-journald
echo "✓ Journald configured with size limits"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔧 Configuring system limits..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for f in /etc/security/limits.d/*nproc.conf; do
    if [ -e "$f" ]; then
        backup_file "$f"
        mv "$f" "${f}_bk"
    fi
done
if [ -f /etc/pam.d/common-session ]; then
    if ! grep -q 'session required pam_limits.so' /etc/pam.d/common-session; then
        backup_file /etc/pam.d/common-session
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
    fi
fi

backup_file /etc/security/limits.conf
# 配置系统资源限制为 unlimited，适合高并发网络服务
# nofile: 最大打开文件数
# nproc: 最大进程数
cat > /etc/security/limits.conf <<'EOF'
* soft nofile unlimited
* hard nofile unlimited
* soft nproc unlimited
* hard nproc unlimited
root soft nofile unlimited
root hard nofile unlimited
root soft nproc unlimited
root hard nproc unlimited
EOF

backup_file /etc/systemd/system.conf
# 配置 systemd 默认资源限制和资源记账
# 启用资源记账可以更好地监控和管理系统资源使用
cat > /etc/systemd/system.conf <<'EOF'
[Manager]
DefaultCPUAccounting=yes
DefaultIOAccounting=yes
DefaultIPAccounting=yes
DefaultMemoryAccounting=yes
DefaultTasksAccounting=yes
DefaultLimitCORE=infinity
DefaultLimitNPROC=infinity
DefaultLimitNOFILE=infinity
EOF

echo "✓ System limits configured (unlimited nofile and nproc)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚙️  Configuring kernel parameters..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
# 使用 999 前缀确保最高优先级，覆盖其他 sysctl 配置
# 这是一套激进的网络性能优化参数，适合高性能服务器
cat > /etc/sysctl.d/999-bbr-sysctl.conf <<'EOF'
# === 内核基础配置 ===
kernel.panic = 1                    # 内核 panic 后 1 秒自动重启
kernel.task_delayacct = 1           # 启用任务延迟统计

# === 网络核心配置 ===
# 增加网络设备接收队列长度，防止丢包
net.core.netdev_max_backlog = 32768
# 使用 fq (Fair Queue) 队列算法，BBR 推荐配置
net.core.default_qdisc = fq
# 增加监听队列长度，支持更多并发连接
net.core.somaxconn = 32768

# === IP 配置 ===
# rp_filter=2 允许不对称路由，适合多网卡环境
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.ip_default_ttl = 128          # 默认 TTL 值
net.ipv4.ip_forward = 1                # 启用 IP 转发（用于路由/代理）
net.ipv4.ip_local_port_range = 10240 65535  # 扩大本地端口范围

# === TCP 连接管理 ===
net.ipv4.tcp_abort_on_overflow = 0     # 不因队列溢出而中止连接
net.ipv4.tcp_adv_win_scale = -2        # 调整 TCP 窗口缩放
net.ipv4.tcp_autocorking = 1           # 自动合并小数据包
net.ipv4.tcp_base_mss = 1024          # 基础 MSS 值
net.ipv4.tcp_collapse_max_bytes = 6291456  # 最大折叠字节数

# === TCP BBR 拥塞控制 ===
net.ipv4.tcp_congestion_control = bbr  # 启用 BBR 算法，提升吞吐量
net.ipv4.tcp_dsack = 1                # 启用 D-SACK
net.ipv4.tcp_ecn = 1                  # 启用显式拥塞通知

# === TCP Fast Open ===
net.ipv4.tcp_fastopen = 1027          # 启用 TFO (客户端+服务端)
net.ipv4.tcp_fastopen_blackhole_timeout_sec = 10

# === TCP 超时配置 ===
net.ipv4.tcp_fin_timeout = 3          # 快速回收 FIN_WAIT 连接
net.ipv4.tcp_frto = 1                 # 快速重传恢复
net.ipv4.tcp_keepalive_intvl = 2      # Keepalive 探测间隔
net.ipv4.tcp_keepalive_probes = 2     # Keepalive 探测次数
net.ipv4.tcp_keepalive_time = 120     # Keepalive 开始时间

# === TCP 队列限制 ===
net.ipv4.tcp_max_orphans = 8192       # 最大孤儿连接数
net.ipv4.tcp_max_syn_backlog = 16384  # SYN 队列长度
net.ipv4.tcp_max_tw_buckets = 4096    # TIME_WAIT 连接数限制

# === TCP 优化选项 ===
net.ipv4.tcp_mtu_probing = 1          # 启用 MTU 探测
net.ipv4.tcp_no_ssthresh_metrics_save = 1  # 不保存慢启动阈值
net.ipv4.tcp_slow_start_after_idle = 0     # 禁用空闲后慢启动

# === TCP 重传配置 ===
# can't set to 0, it will then default to 8
net.ipv4.tcp_orphan_retries = 4       # 孤儿连接重传次数
net.ipv4.tcp_retries1 = 2             # 第一阶段重传次数
net.ipv4.tcp_retries2 = 2             # 第二阶段重传次数
net.ipv4.tcp_rfc1337 = 1              # 防御 TIME_WAIT 攻击
# === TCP/UDP 缓冲区配置 ===
# 接收缓冲区：默认 256KB，最大 512MB
net.core.rmem_default = 262144
net.core.rmem_max = 536870912
net.ipv4.tcp_rmem = 8192 262144 536870912  # min default max
# 发送缓冲区：默认 16KB，最大 512MB
net.core.wmem_default = 16384
net.core.wmem_max = 536870912
net.ipv4.tcp_wmem = 4096 16384 536870912   # min default max
net.ipv4.tcp_moderate_rcvbuf = 1           # 自动调整接收缓冲区

# === TCP 功能选项 ===
net.ipv4.tcp_sack = 1                 # 启用选择性确认
# net.ipv4.tcp_shrink_window = 1      # 允许缩小窗口（已注释）
net.ipv4.tcp_syn_retries = 2          # SYN 重传次数
net.ipv4.tcp_synack_retries = 2       # SYN-ACK 重传次数
net.ipv4.tcp_syncookies = 1           # 防御 SYN Flood 攻击
net.ipv4.tcp_timestamps = 1           # 启用时间戳
net.ipv4.tcp_tw_reuse = 1             # 复用 TIME_WAIT 连接
net.ipv4.tcp_window_scaling = 1       # 启用窗口缩放
net.ipv4.tcp_no_metrics_save = 0      # 保存连接指标
net.ipv4.tcp_notsent_lowat = 131072   # 未发送数据低水位标记

# === 低延迟优化 ===
# 禁用 Nagle 算法，实现真正的 0-RTT
net.ipv4.tcp_low_latency = 1

# === UDP 配置 ===
net.ipv4.udp_rmem_min = 8192          # UDP 最小接收缓冲区
net.ipv4.udp_wmem_min = 4096          # UDP 最小发送缓冲区
net.ipv4.route.flush = 1              # 刷新路由缓存
# === IPv6 配置 ===
net.ipv6.conf.all.forwarding = 1      # 启用 IPv6 转发
net.ipv6.conf.default.forwarding = 1

# === Netfilter 连接跟踪配置 ===
# 用于防火墙、NAT 等功能的连接跟踪超时优化
net.netfilter.nf_conntrack_generic_timeout = 10         # 通用协议超时
net.netfilter.nf_conntrack_gre_timeout = 5              # GRE 超时
net.netfilter.nf_conntrack_gre_timeout_stream = 30      # GRE 流超时
net.netfilter.nf_conntrack_icmp_timeout = 5             # ICMP 超时
net.netfilter.nf_conntrack_icmpv6_timeout = 5           # ICMPv6 超时
net.netfilter.nf_conntrack_max = 1048576                # 最大连接跟踪数 (100万)

# TCP 连接跟踪超时（单位：秒）
net.netfilter.nf_conntrack_tcp_timeout_close = 5        # CLOSE 状态
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 5   # CLOSE_WAIT 状态
net.netfilter.nf_conntrack_tcp_timeout_established = 600  # 已建立连接 (10分钟)
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30    # FIN_WAIT 状态
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 5     # LAST_ACK 状态
net.netfilter.nf_conntrack_tcp_timeout_max_retrans = 5  # 最大重传超时
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 5     # SYN_RECV 状态
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 5     # SYN_SENT 状态
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15   # TIME_WAIT 状态
net.netfilter.nf_conntrack_tcp_timeout_unacknowledged = 5  # 未确认数据超时

# UDP 连接跟踪超时
net.netfilter.nf_conntrack_udp_timeout = 5              # UDP 超时
net.netfilter.nf_conntrack_udp_timeout_stream = 60      # UDP 流超时

# === 内存管理 ===
vm.overcommit_memory = 1              # 允许内存过量分配
vm.swappiness = 0                     # 最小化 swap 使用
EOF

# 动态计算 tcp_mem 参数（基于系统总内存）
# tcp_mem 控制 TCP 栈的内存使用：min pressure max
mems=$(free --bytes | grep Mem | awk '{print $2}')
page=$(getconf PAGESIZE)
size=$((mems/page))
echo "net.ipv4.tcp_mem = $((size/100*12)) $((size/100*50)) $((size/100*70))" >> /etc/sysctl.d/999-bbr-sysctl.conf

# 按字母顺序排序配置文件，便于阅读和维护
sort -n /etc/sysctl.d/999-bbr-sysctl.conf -o /etc/sysctl.d/999-bbr-sysctl.conf
# 应用所有 sysctl 配置
sysctl --system >/dev/null 2>&1 || true

echo "✓ Kernel parameters configured with aggressive network optimizations"

get_cpu_cache_info() {
    set +e
    local cache_info=$(lscpu 2>/dev/null | grep -i cache | head -3 | awk -F: '{print $2}' | xargs | tr '\n' ' ' || echo "N/A")
    if [ -z "$cache_info" ] || [ "$cache_info" = "N/A" ]; then
        echo "N/A"
    else
        echo "$cache_info"
    fi
    set -e
}
get_memory_usage_detailed() {
    set +e
    local mem_info=$(free -h 2>/dev/null | awk 'NR==2{printf "%s / %s", $3, $2}' || echo "N/A")
    echo "$mem_info"
    set -e
}
get_swap_usage_detailed() {
    set +e
    local swap_total=$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null | head -n1)
    if [ -z "$swap_total" ] || [ "$swap_total" = "0" ]; then
        if swapon --show 2>/dev/null | grep -q "/"; then
            local swap_info=$(free -h 2>/dev/null | awk 'NR==3{printf "%s / %s", $3, $2}')
            echo "$swap_info"
        else
            echo "No swap detected"
        fi
    else
        local swap_info=$(free -h 2>/dev/null | awk 'NR==3{printf "%s / %s", $3, $2}')
        echo "$swap_info"
    fi
    set -e
}
get_disk_usage_detailed() {
    set +e
    local disk_info=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s used)", $3, $2, $5}' || echo "N/A")
    echo "$disk_info"
    set -e
}
get_boot_disk() {
    set +e
    local root_dev=$(df / 2>/dev/null | awk 'NR==2{print $1}')
    if [[ "$root_dev" == /dev/mapper/* ]]; then
        local real_dev=$(readlink -f "$root_dev" 2>/dev/null || echo "$root_dev")
        echo "$real_dev"
    else
        echo "$root_dev"
    fi
    set -e
}

clear
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 System Optimization Complete - Configuration Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
set +e
printf "%-22s: %s\n" "BBR Congestion Control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A')"
printf "%-22s: %s\n" "Queue Discipline" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo 'N/A')"
printf "%-22s: %s\n" "Open File Limit" "$(ulimit -n 2>/dev/null || echo 'N/A')"
printf "%-22s: %s\n" "Process Limit" "$(ulimit -u 2>/dev/null || echo 'N/A')"
printf "%-22s: %s\n" "Time Sync Status" "$(chronyc tracking 2>/dev/null | grep 'Leap status' | cut -d':' -f2 | xargs 2>/dev/null || echo 'Checking...')"
printf "%-22s: %s\n" "Current Timezone" "$(timedatectl show --property=Timezone --value 2>/dev/null || echo 'N/A')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-22s: %s\n" "CPU Model Name" "$(lscpu 2>/dev/null | grep 'Model name' | cut -d':' -f2 | xargs || echo 'Unknown')"
printf "%-22s: %s\n" "CPU Cache" "$(get_cpu_cache_info)"
printf "%-22s: %s vCPU(s)\n" "CPU Cores" "$(nproc 2>/dev/null || echo 'N/A')"
printf "%-22s: %s\n" "Memory Usage" "$(get_memory_usage_detailed)"
printf "%-22s: %s\n" "Swap Usage" "$(get_swap_usage_detailed)"
printf "%-22s: %s\n" "Disk Usage" "$(get_disk_usage_detailed)"
printf "%-22s: %s\n" "Boot Disk" "$(get_boot_disk)"
printf "%-22s: %s (%s)\n" "OS Release" "$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"' || echo 'Unknown')" "$(uname -m 2>/dev/null || echo 'N/A')"
printf "%-22s: %s\n" "Kernel Version" "$(uname -r 2>/dev/null || echo 'N/A')"
printf "%-22s: %s\n" "Uptime" "$(uptime -p 2>/dev/null | cut -d' ' -f2- || echo 'N/A')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Security Status:"
ssh_status=$(systemctl is-active ssh 2>/dev/null || echo 'inactive')
fail2ban_status=$(systemctl is-active fail2ban 2>/dev/null || echo 'inactive')
unattended_upgrades_timer=$(systemctl is-active apt-daily-upgrade.timer 2>/dev/null || echo 'inactive')
printf "  %-20s: %s\n" "SSH Service" "$ssh_status"
printf "  %-20s: %s\n" "Fail2ban Service" "$fail2ban_status"
printf "  %-20s: %s\n" "Auto-updates Timer" "$unattended_upgrades_timer"
set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Optimization complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 Backup files saved to: $BACKUP_DIR"
echo ""
echo "$(date '+%Y-%m-%d %H:%M:%S') - Script version: $SCRIPT_VERSION" > "$MARKER_FILE"
echo "⚠️  It is recommended to reboot the system for all settings to take effect."
echo ""
read -p "Would you like to reboot now? (y/yes): " reboot_now
reboot_now_lower=$(echo "$reboot_now" | tr '[:upper:]' '[:lower:]')
if [ "$reboot_now_lower" = "y" ] || [ "$reboot_now_lower" = "yes" ]; then
    echo ""
    echo "Rebooting system..."
    reboot
else
    echo ""
    echo "Please remember to reboot manually later with:"
    echo "   reboot"
    echo ""
fi
