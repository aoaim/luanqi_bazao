#!/bin/bash

# Error if not root
[ "$(id -u)" != "0" ] && { echo "Error: You must be root to run this script"; exit 1; }

# Upgrade and install necessary packages
apt update && apt upgrade -y && apt autoremove -y
apt install -y openssl net-tools dnsutils nload curl wget lsof nano htop cron haveged vnstat chrony iftop iotop fail2ban unattended-upgrades unzip logrotate

# speedtest-cli
apt-get update && apt-get purge speedtest speedtest-cli -y
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
apt-get install speedtest -y

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
    status=$(chronyc tracking 2>/dev/null | grep 'Leap status' | cut -d':' -f2 | xargs)
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

# unattended-upgrades 自动启用（自动安全更新，无交互）
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades 2>/dev/null || true

# logrotate 测试（可选，生产环境可省略）
# logrotate -f /etc/logrotate.conf

# Limits
# 备份所有 nproc.conf，防止默认限制覆盖自定义设置
for f in /etc/security/limits.d/*nproc.conf; do
    [ -e "$f" ] && mv "$f" "${f}_bk"
done

# 确保 pam_limits.so 被加载，否则 limits 配置不会生效
[ -f /etc/pam.d/common-session ] && [ -z "$(grep 'session required pam_limits.so' /etc/pam.d/common-session)" ] && echo "session required pam_limits.so" >> /etc/pam.d/common-session

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

# Sysctl
mv /etc/sysctl.conf /etc/sysctl.conf.bak
cat > /etc/sysctl.d/999-bbr-sysctl.conf <<'EOF'
# 1. 队列算法与拥塞控制
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr

# 2. Socket 缓冲区（统一 16 MB 上限，下限 16 KB）
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 16384 262144 16777216
net.ipv4.tcp_wmem = 16384 262144 16777216

# 3. 延迟与丢包优化
net.ipv4.tcp_mtu_probing = 1          # PLPMTUD，防黑洞
net.ipv4.tcp_fastopen = 3             # TFO 客户端+服务端
net.ipv4.tcp_slow_start_after_idle = 0 # 长连接不降速
net.ipv4.tcp_notsent_lowat = 262144   # 平衡延迟与吞吐

# 4. 通用 TCP 调优
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_no_metrics_save = 1
net.core.netdev_max_backlog = 2048

# 5. 安全加固
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.core.somaxconn = 4096
# net.ipv4.ip_forward = 1               # 如果需要转发

# 防 IP/ARP 欺骗 & 广播 ICMP
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# 6. 端口回收与范围
net.ipv4.tcp_tw_reuse = 1
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

# 输出验证配置
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 System Optimization Complete - Configuration Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-22s: %s\n" "BBR Congestion Control" "$(sysctl -n net.ipv4.tcp_congestion_control)"
printf "%-22s: %s\n" "Queue Discipline" "$(sysctl -n net.core.default_qdisc)"
printf "%-22s: %s\n" "Open File Limit" "$(ulimit -n)"
printf "%-22s: %s\n" "Process Limit" "$(ulimit -u)"
printf "%-22s: %s\n" "Time Sync Status" "$(chronyc tracking 2>/dev/null | grep 'Leap status' | cut -d':' -f2 | xargs || echo 'Normal')"
printf "%-22s: %s\n" "Current Timezone" "$(timedatectl show --property=Timezone --value)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-22s: %s\n" "CPU Model" "$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | xargs)"
printf "%-22s: %s\n" "CPU Cores" "$(nproc)"
printf "%-22s: %s\n" "CPU MHz" "$(awk -F: '/cpu MHz/ {print $2; exit}' /proc/cpuinfo | xargs)"
printf "%-22s: %s\n" "Total RAM" "$(free -h | awk '/^Mem:/ {print $2}')"
printf "%-22s: %s\n" "Total Swap" "$(free -h | awk '/^Swap:/ {print $2}')"
printf "%-22s: %s\n" "Disk Size" "$disk_size"
printf "%-22s: %s\n" "OS Version" "$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
printf "%-22s: %s\n" "Kernel Version" "$(uname -r)"
printf "%-22s: %s\n" "Uptime" "$(uptime -p | cut -d' ' -f2-)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 函数：检查服务状态
check_service_status() {
    local service_name=$1
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        echo "Running"
    elif systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        echo "Enabled (Not Running)"
    else
        echo "Inactive"
    fi
}

# 函数：检查包安装状态
check_package_status() {
    local pkg=$1
    local service_name=$2

    if [ "$pkg" = "speedtest" ]; then
        if command -v speedtest &>/dev/null; then
            ver=$(speedtest --version 2>/dev/null | grep -o 'Speedtest by Ookla [0-9.]\+' | head -1)
            printf "  %-20s: Installed (%s)\n" "$pkg" "${ver:-Unknown Version}"
        else
            printf "  %-20s: Not Installed\n" "$pkg"
        fi
    else
        if dpkg -s "$pkg" &>/dev/null; then
            if [ -n "$service_name" ]; then
                status=$(check_service_status "$service_name")
                printf "  %-20s: Installed | Service: %s\n" "$pkg" "$status"
            else
                printf "  %-20s: Installed\n" "$pkg"
            fi
        else
            printf "  %-20s: Not Installed\n" "$pkg"
        fi
    fi
}

echo "Package Install Status & Service Status:"

# 定义包和对应的服务名
declare -A package_services=(
    ["cron"]="cron"
    ["haveged"]="haveged" 
    ["vnstat"]="vnstat"
    ["chrony"]="chrony"
    ["fail2ban"]="fail2ban"
)

# 工具类软件（无服务）
tools="openssl net-tools dnsutils nload curl wget lsof nano htop iftop iotop unattended-upgrades unzip logrotate speedtest"

# 检查有服务的软件包
for pkg in "${!package_services[@]}"; do
    check_package_status "$pkg" "${package_services[$pkg]}"
done

# 检查工具类软件包
for pkg in $tools; do
    check_package_status "$pkg" ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 额外的服务状态检查
echo "Key Services Status:"
printf "  %-20s: %s\n" "SSH" "$(check_service_status ssh)"
printf "  %-20s: %s\n" "Network Manager" "$(check_service_status NetworkManager || check_service_status networking)"
printf "  %-20s: %s\n" "UFW Firewall" "$(check_service_status ufw)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Optimization complete! It is recommended to reboot the system for all settings to take effect."
echo ""
