#!/bin/bash

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
systemctl enable --now vnstat
echo "✓ Vnstat enabled"
systemctl enable --now fail2ban
echo "✓ Fail2ban enabled"

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
cat > /etc/security/limits.d/99-network-limits.conf <<EOF
* soft nofile 65536
* hard nofile 65536
* soft nproc 32768
* hard nproc 32768

root soft nofile 65536
root hard nofile 65536
root soft nproc 32768
root hard nproc 32768
EOF
echo "✓ System limits configured"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚙️  Configuring kernel parameters..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ -f /etc/sysctl.conf ]; then
    backup_file /etc/sysctl.conf
    mv /etc/sysctl.conf /etc/sysctl.conf.bak
fi
cat > /etc/sysctl.d/999-bbr-sysctl.conf <<'EOF'
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_no_metrics_save = 1
net.core.netdev_max_backlog = 2048
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.core.somaxconn = 4096
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.ip_local_port_range = 1024 65535
kernel.panic = 10
kernel.core_pattern = core_%e
vm.panic_on_oom = 1
EOF
sysctl --system >/dev/null 2>&1 || true
echo "✓ Kernel parameters configured"

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
