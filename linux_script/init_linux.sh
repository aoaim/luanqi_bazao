#!/bin/bash

# 严格模式：任何命令失败都会中断脚本
set -e  # 命令返回非零退出码时退出
set -u  # 使用未定义变量时退出
set -o pipefail  # 管道中任何命令失败都会导致整个管道失败

# 错误处理函数
error_exit() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "❌ Error occurred at line $1"
    echo "❌ Script execution failed. Please check the error message above."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
}

# 捕获错误并显示行号
trap 'error_exit $LINENO' ERR

# Error if not root
[ "$(id -u)" != "0" ] && { echo "Error: You must be root to run this script"; exit 1; }

# Check if running on Debian 12 or 13 only
if [ ! -f /etc/debian_version ]; then
    echo "Error: This script is designed for Debian systems only"
    exit 1
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "debian" ]; then
        echo "Error: This script only supports Debian (detected: $PRETTY_NAME)"
        exit 1
    fi
    # Get Debian major version
    DEBIAN_VERSION=$(cat /etc/debian_version | cut -d. -f1)
    if [ "$DEBIAN_VERSION" != "12" ] && [ "$DEBIAN_VERSION" != "13" ]; then
        echo "Error: This script only supports Debian 12 and 13 (detected: Debian $DEBIAN_VERSION)"
        exit 1
    fi
    echo "✓ Running on Debian $DEBIAN_VERSION"
fi

# upgrade and install necessary packages
apt update && apt upgrade -y && apt autoremove -y
apt install -y openssl net-tools dnsutils nload curl wget lsof nano htop cron haveged vnstat chrony iftop iotop fail2ban unattended-upgrades unzip logrotate

# speedtest-cli
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
apt-get install speedtest -y

# helix-editor
echo "Fetching latest Helix editor release..."
LATEST_HELIX_URL=$(curl -s https://api.github.com/repos/helix-editor/helix/releases/latest | grep -oP '"browser_download_url":\s*"\K[^"]*amd64\.deb')

if [ -z "$LATEST_HELIX_URL" ]; then
    echo "❌ Failed to fetch latest Helix release URL"
    exit 1
fi

echo "Downloading Helix from: $LATEST_HELIX_URL"
wget -O helix.deb "$LATEST_HELIX_URL"

if [ ! -f helix.deb ]; then
    echo "❌ Failed to download Helix"
    exit 1
fi

dpkg -i helix.deb
apt-get install -f -y
rm -f helix.deb
echo "✓ Helix editor installed successfully"

# helix alias 替代 vi/vim
cat > /etc/profile.d/helix-alias.sh <<'EOF'
# Helix aliases to replace vi/vim
alias vi='hx'
alias vim='hx'
EOF

chmod 644 /etc/profile.d/helix-alias.sh
echo "✓ Helix aliased to vi/vim"

# eza
echo "Installing eza..."
mkdir -p /etc/apt/keyrings
wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc | gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" | tee /etc/apt/sources.list.d/gierens.list
chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
apt update
apt install -y eza

# eza alias 替代 ls
cat > /etc/profile.d/eza-alias.sh <<'EOF'
# Eza aliases to replace ls
alias ls='eza'
alias ll='eza -lh --icons --git'
alias la='eza -lah --icons --git'
alias lt='eza -lh --icons --git --tree'
alias l='eza -lah --icons --git'
EOF

chmod 644 /etc/profile.d/eza-alias.sh
echo "✓ Eza installed and aliased to ls"

# Chrony configuration
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

# Enable and verify chrony
systemctl enable --now chrony
chronyc tracking

# 等待chrony同步，最多等待60秒
for i in {1..12}; do
    status=$(chronyc tracking 2>/dev/null | grep 'Leap status' | cut -d':' -f2 | xargs || true)
    if [[ "$status" == "Normal" ]]; then
        break
    fi
    sleep 5
done

# Timezone
timedatectl set-timezone Asia/Singapore

# Haveged
systemctl enable --now haveged

# Vnstat
systemctl enable --now vnstat

# Fail2ban
systemctl enable --now fail2ban

# logrotate 测试（可选，生产环境可省略）
# logrotate -f /etc/logrotate.conf

# limits
# 备份所有 nproc.conf，防止默认限制覆盖自定义设置
for f in /etc/security/limits.d/*nproc.conf; do
    if [ -e "$f" ]; then
        mv "$f" "${f}_bk"
    fi
done

# 确保 pam_limits.so 被加载，否则 limits 配置不会生效
if [ -f /etc/pam.d/common-session ]; then
    if ! grep -q 'session required pam_limits.so' /etc/pam.d/common-session; then
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
    fi
fi

# 网络服务优化 - 适度提升
cat > /etc/security/limits.d/99-network-limits.conf <<EOF
# 网络服务优化 - 适度提升
* soft nofile 65536
* hard nofile 65536
* soft nproc 32768
* hard nproc 32768

root soft nofile 65536
root hard nofile 65536
root soft nproc 32768
root hard nproc 32768
EOF

# sysctl
if [ -f /etc/sysctl.conf ]; then
    mv /etc/sysctl.conf /etc/sysctl.conf.bak
fi

cat > /etc/sysctl.d/999-bbr-sysctl.conf <<'EOF'
# 1. 队列算法与拥塞控制
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr

# 2. Socket 缓冲区（16 MB 上限，自动调整）
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216

# 3. 延迟与丢包优化
net.ipv4.tcp_mtu_probing = 1          # PLPMTUD，防黑洞
net.ipv4.tcp_fastopen = 3             # TFO 客户端+服务端
net.ipv4.tcp_slow_start_after_idle = 0 # 长连接不降速
net.ipv4.tcp_notsent_lowat = 16384    # 降低缓冲延迟

# 4. 通用 TCP 调优
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_no_metrics_save = 1
net.core.netdev_max_backlog = 2048
net.ipv4.tcp_window_scaling = 1

# 5. 安全加固
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.core.somaxconn = 4096
# net.ipv4.ip_forward = 1   # 如果需要转发

# 防 IP/ARP 欺骗 & 广播 ICMP
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# 6. 端口回收与范围
net.ipv4.tcp_fin_timeout = 10
net.ipv4.ip_local_port_range = 1024 65535

# 7. 崩溃与异常处理
kernel.panic = 10
kernel.core_pattern = core_%e
vm.panic_on_oom = 1
EOF

# Apply sysctl settings
sysctl --system

# 检测磁盘大小
root_disk=$(df / --output=source | tail -1)
disk_device=$(lsblk -no pkname "$root_disk" 2>/dev/null | head -n1)
if [ -n "$disk_device" ]; then
    disk_device="/dev/$disk_device"
else
    disk_device="$root_disk"
fi
disk_size=$(lsblk -b -dn -o SIZE "$disk_device" 2>/dev/null | awk '{printf "%.2f GB", $1/1024/1024/1024}')

# 清屏
clear

# 获取CPU缓存信息
get_cpu_cache_info() {
    local l1d_cache_b=$(lscpu -B 2>/dev/null | grep -oP "(?<=L1d cache:).*(?=)" | sed -e 's/^[ ]*//g')
    local l1i_cache_b=$(lscpu -B 2>/dev/null | grep -oP "(?<=L1i cache:).*(?=)" | sed -e 's/^[ ]*//g')
    local l2_cache_b=$(lscpu -B 2>/dev/null | grep -oP "(?<=L2 cache:).*(?=)" | sed -e 's/^[ ]*//g')
    local l3_cache_b=$(lscpu -B 2>/dev/null | grep -oP "(?<=L3 cache:).*(?=)" | sed -e 's/^[ ]*//g')

    # L1缓存计算 (L1d + L1i)
    if [ -n "$l1d_cache_b" ] && [ -n "$l1i_cache_b" ]; then
        local l1_total_b=$(echo "$l1d_cache_b $l1i_cache_b" | awk '{printf "%d\n",$1+$2}')
        local l1_total_k=$(echo "$l1_total_b" | awk '{printf "%.2f\n",$1/1024}')
        local l1_total_k_int=$(echo "$l1_total_b" | awk '{printf "%d\n",$1/1024}')
        if [ "$l1_total_k_int" -ge "1024" ]; then
            local l1_cache=$(echo "$l1_total_k" | awk '{printf "%.2f MB\n",$1/1024}')
        else
            local l1_cache=$(echo "$l1_total_k" | awk '{printf "%.2f KB\n",$1}')
        fi
    else
        local l1_cache="N/A"
    fi

    # L2缓存计算
    if [ -n "$l2_cache_b" ]; then
        local l2_k=$(echo "$l2_cache_b" | awk '{printf "%.2f\n",$1/1024}')
        local l2_k_int=$(echo "$l2_cache_b" | awk '{printf "%d\n",$1/1024}')
        if [ "$l2_k_int" -ge "1024" ]; then
            local l2_cache=$(echo "$l2_k" | awk '{printf "%.2f MB\n",$1/1024}')
        else
            local l2_cache=$(echo "$l2_k" | awk '{printf "%.2f KB\n",$1}')
        fi
    else
        local l2_cache="N/A"
    fi

    # L3缓存计算
    if [ -n "$l3_cache_b" ]; then
        local l3_k=$(echo "$l3_cache_b" | awk '{printf "%.2f\n",$1/1024}')
        local l3_k_int=$(echo "$l3_cache_b" | awk '{printf "%d\n",$1/1024}')
        if [ "$l3_k_int" -ge "1024" ]; then
            local l3_cache=$(echo "$l3_k" | awk '{printf "%.2f MB\n",$1/1024}')
        else
            local l3_cache=$(echo "$l3_k" | awk '{printf "%.2f KB\n",$1}')
        fi
    else
        local l3_cache="N/A"
    fi

    echo "L1: $l1_cache / L2: $l2_cache / L3: $l3_cache"
}

# 获取内存使用信息
get_memory_usage_detailed() {
    local memtotal_kib=$(awk '/MemTotal/{print $2}' /proc/meminfo | head -n1)
    local memfree_kib=$(awk '/MemFree/{print $2}' /proc/meminfo | head -n1)
    local buffers_kib=$(awk '/Buffers/{print $2}' /proc/meminfo | head -n1)
    local cached_kib=$(awk '/Cached/{print $2}' /proc/meminfo | head -n1)

    local memfree_total_kib=$(echo "$memfree_kib $buffers_kib $cached_kib" | awk '{printf $1+$2+$3}')
    local memused_kib=$(echo "$memtotal_kib $memfree_total_kib" | awk '{printf $1-$2}')

    local memused_mib=$(echo "$memused_kib" | awk '{printf "%.2f",$1/1024}')
    local memtotal_gib=$(echo "$memtotal_kib" | awk '{printf "%.2f",$1/1048576}')

    if [ "$(echo "$memused_kib" | awk '{printf "%d",$1}')" -lt "1048576" ]; then
        echo "$memused_mib MiB / $memtotal_gib GiB"
    else
        local memused_gib=$(echo "$memused_kib" | awk '{printf "%.2f",$1/1048576}')
        echo "$memused_gib GiB / $memtotal_gib GiB"
    fi
}

# 获取交换分区信息
get_swap_usage_detailed() {
    local swaptotal_kib=$(awk '/SwapTotal/{print $2}' /proc/meminfo | head -n1)

    if [ "$swaptotal_kib" -eq "0" ]; then
        echo "[ no swap partition or swap file detected ]"
    else
        local swapfree_kib=$(awk '/SwapFree/{print $2}' /proc/meminfo | head -n1)
        local swapused_kib=$(echo "$swaptotal_kib $swapfree_kib" | awk '{printf $1-$2}')

        local swapused_mib=$(echo "$swapused_kib" | awk '{printf "%.2f",$1/1024}')
        local swaptotal_mib=$(echo "$swaptotal_kib" | awk '{printf "%.2f",$1/1024}')

        echo "$swapused_mib MiB / $swaptotal_mib MiB"
    fi
}

# 获取磁盘使用信息
get_disk_usage_detailed() {
    local disktotal_kib=$(df -x tmpfs / | grep -oE "[0-9]{4,}" | awk 'NR==1 {print $1}')
    local diskused_kib=$(df -x tmpfs / | grep -oE "[0-9]{4,}" | awk 'NR==2 {print $1}')

    local diskused_gib=$(echo "$diskused_kib" | awk '{printf "%.2f",$1/1048576}')
    local disktotal_gib=$(echo "$disktotal_kib" | awk '{printf "%.2f",$1/1048576}')

    echo "$diskused_gib GiB / $disktotal_gib GiB"
}

# 获取启动磁盘
get_boot_disk() {
    df -x tmpfs / | awk "NR>1" | sed ":a;N;s/\\n//g;ta" | awk '{print $1}'
}

# 输出验证配置
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 System Optimization Complete - Configuration Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-22s: %s\n" "BBR Congestion Control" "$(sysctl -n net.ipv4.tcp_congestion_control)"
printf "%-22s: %s\n" "Queue Discipline" "$(sysctl -n net.core.default_qdisc)"
printf "%-22s: %s\n" "Open File Limit" "$(ulimit -n)"
printf "%-22s: %s\n" "Process Limit" "$(ulimit -u)"
printf "%-22s: %s\n" "Time Sync Status" "$(chronyc tracking 2>/dev/null | grep 'Leap status' | cut -d':' -f2 | xargs 2>/dev/null || echo 'Checking...')"
printf "%-22s: %s\n" "Current Timezone" "$(timedatectl show --property=Timezone --value)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 系统硬件信息
printf "%-22s: %s\n" "CPU Model Name" "$(lscpu -B 2>/dev/null | grep -oP -m1 "(?<=Model name:).*(?=)" | sed -e 's/^[ ]*//g' || echo 'Unknown')"
printf "%-22s: %s\n" "CPU Cache Size" "$(get_cpu_cache_info)"
printf "%-22s: %s vCPU(s)\n" "CPU Specifications" "$(nproc)"
printf "%-22s: %s\n" "Memory Usage" "$(get_memory_usage_detailed)"
printf "%-22s: %s\n" "Swap Usage" "$(get_swap_usage_detailed)"
printf "%-22s: %s\n" "Disk Usage" "$(get_disk_usage_detailed)"
printf "%-22s: %s\n" "Boot Disk" "$(get_boot_disk)"
printf "%-22s: %s (%s)\n" "OS Release" "$(lsb_release -ds 2>/dev/null || (grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"'))" "$(uname -m)"
printf "%-22s: %s\n" "Kernel Version" "$(uname -r)"
printf "%-22s: %s\n" "Uptime" "$(uptime -p | cut -d' ' -f2-)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 安全检查（临时禁用 set -e 以允许状态检查失败）
set +e
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Security Status:"
ssh_status=$(systemctl is-active ssh 2>/dev/null || echo 'inactive')
fail2ban_status=$(systemctl is-active fail2ban 2>/dev/null || echo 'inactive')
printf "  %-20s: %s\n" "SSH Service" "$ssh_status"
printf "  %-20s: %s\n" "Fail2ban Service" "$fail2ban_status"
set -e
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Optimization complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "⚠️  It is recommended to reboot the system for all settings to take effect."
echo ""
read -p "Would you like to reboot now? (y/yes): " reboot_now

# Convert to lowercase for comparison
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
