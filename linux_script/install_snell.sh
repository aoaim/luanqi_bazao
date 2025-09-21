#!/bin/bash

# --- 使用方法 ---
# 1. 将此脚本保存为 .sh 文件，例如 install_snell.sh
# 2. 赋予执行权限: chmod +x install_snell.sh
# 3. 运行脚本: ./install_snell.sh

# 如果任何命令执行失败，则立即退出脚本
set -e

# --- 1. 安装依赖 ---
echo "Updating package list and installing dependencies (wget, unzip)..."
apt update
# 移除了 openssl，因为我们使用 tr 和 /dev/urandom 来生成密码
apt install unzip wget -y

# --- 2. 下载并安装 Snell 服务器 ---
echo "Downloading and installing Snell server..."
wget https://dl.nssurge.com/snell/snell-server-v5.0.0-linux-amd64.zip -O snell-server.zip
unzip -o snell-server.zip -d /usr/local/bin/
rm -f snell-server.zip
echo "Snell server installed successfully."

# --- 3. 交互式配置 ---
echo "Please configure your Snell server:"

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

# 确保配置文件目录存在
mkdir -p /etc/snell

# --- 4. 根据用户输入生成配置文件 ---
# 判断用户是否选择开启 obfs
if [[ "$enable_obfs" =~ ^[Yy]$ ]]; then
    # 如果开启 obfs，则设置为 http 模式，并让用户输入 host，默认值为 d1--ov-gotcha07.bilivideo.com
    echo "obfs enabled. obfs mode is set to 'http'."
    read -p "Enter the obfs host [default: d1--ov-gotcha07.bilivideo.com]: " host
    host=${host:-d1--ov-gotcha07.bilivideo.com}

    # 写入包含 obfs 的配置文件
    cat >/etc/snell/snell-server.conf <<EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
ipv6 = true
dns = 8.8.8.8,8.8.4.4,2001:4860:4860::8888,2001:4860:4860::8844
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
dns = 8.8.8.8,8.8.4.4,2001:4860:4860::8888,2001:4860:4860::8844
EOF
    echo "Configuration file created (obfs disabled)."
fi

# --- 5. 创建 systemd 服务 ---
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

# --- 6. 启动并验证服务 ---
echo "Enabling and starting Snell service..."
# 重新加载 systemd 配置，以确保新的 service 文件被识别
systemctl daemon-reload
# 设置开机自启并立即启动服务
systemctl enable --now snell.service

echo "Snell service has been started."
echo "Verifying service status..."
# 检查服务状态，--no-pager 选项可以防止输出内容过多时进入翻页模式
systemctl status snell.service --no-pager

echo "----------------------------------------"
echo "Snell server installation complete!"
echo "Your configuration is:"
echo "Port: ${port}"
echo "PSK: ${psk}"
if [[ "$enable_obfs" =~ ^[Yy]$ ]]; then
    echo "Obfs: http"
    echo "Host: ${host}"
fi
echo "----------------------------------------"
