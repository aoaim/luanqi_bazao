#!/bin/bash

# Error if not root
[ "$(id -u)" != "0" ] && { echo "Error: You must be root to run this script"; exit 1; }

# Upgrade and install necessary packages
apt update && apt upgrade -y && apt autoremove -y
apt install -y openssl net-tools dnsutils nload curl wget lsof nano htop cron haveged vnstat chrony

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

# Restart and enable chrony
systemctl restart chrony
systemctl enable chrony

# Verify chrony is running
chronyc tracking

# Timezone
timedatectl set-timezone Asia/Singapore

# Haveged
systemctl disable --now haveged
systemctl enable --now haveged

# Vnstat
systemctl enable --now vnstat

# Limits
[ -e /etc/security/limits.d/*nproc.conf ] && rename nproc.conf nproc.conf_bk /etc/security/limits.d/*nproc.conf
[ -f /etc/pam.d/common-session ] && [ -z "$(grep 'session required pam_limits.so' /etc/pam.d/common-session)" ] && echo "session required pam_limits.so" >> /etc/pam.d/common-session
cat >> /etc/security/limits.conf <<EOF
# End of file
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
* soft core 1048576
* hard core 1048576
* hard memlock unlimited
* soft memlock unlimited
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 1048576
root hard nproc 1048576
root soft core 1048576
root hard core 1048576
root hard memlock unlimited
root soft memlock unlimited
EOF

# Sysctl
cat > /etc/sysctl.conf <<EOF
fs.file-max = 1024000
net.core.rmem_max = 35000000
net.core.rmem_default = 17500000
net.core.wmem_max = 35000000
net.core.wmem_default = 17500000

net.ipv4.tcp_wmem = 4096 17500000 35000000
net.ipv4.tcp_rmem = 4096 17500000 35000000

net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_notsent_lowat = 131072
EOF

# Enable BBR
modprobe tcp_bbr &>/dev/null
if grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    echo "net.core.default_qdisc = fq_pie" >>/etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >>/etc/sysctl.conf
fi

# Apply sysctl settings
sysctl -p && sysctl --system

echo "Successful kernel optimization"