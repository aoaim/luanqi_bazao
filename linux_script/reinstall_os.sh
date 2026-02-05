#!/bin/bash
# Linux Reinstall Script
# Auto-generate 18-char password + Interactive OS selection
# Based on: https://github.com/leitbogioro/Tools

set -e

PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 18)

echo "Select OS:"
echo "1) Debian 13   2) Ubuntu 24"
echo "3) Rocky 9     4) Alma 9"
echo "5) Alpine      0) Exit"
echo ""
read -rp "> " choice

case $choice in
    1) OS="-debian trixie"; NAME="Debian 13" ;;
    2) OS="-ubuntu 24.04"; NAME="Ubuntu 24.04" ;;
    3) OS="-rocky 9"; NAME="Rocky 9" ;;
    4) OS="-alma 9"; NAME="Alma 9" ;;
    5) OS="-alpine edge"; NAME="Alpine Linux Edge" ;;
    0) exit 0 ;;
    *) echo "Invalid"; exit 1 ;;
esac

# Hostname
echo ""
read -rp "Set hostname? (enter to skip): " HOSTNAME
[[ -n "$HOSTNAME" ]] && OS="$OS -hostname $HOSTNAME"

# SSH Port
read -rp "SSH port? (default 22): " PORT
PORT=${PORT:-22}
OS="$OS -port $PORT"

# Cloud kernel
read -rp "Use cloud kernel? (y/N): " CK
[[ "$CK" == "y" || "$CK" == "Y" ]] && OS="$OS --cloudkernel 1"

# BBR
read -rp "Enable BBR? (y/N): " BBR
[[ "$BBR" == "y" || "$BBR" == "Y" ]] && OS="$OS --bbr"

# Fail2ban
read -rp "Enable fail2ban? (y/N): " F2B
[[ "$F2B" == "y" || "$F2B" == "Y" ]] && OS="$OS --fail2ban 1"

echo ""
echo "OS: $NAME"
[[ -n "$HOSTNAME" ]] && echo "Hostname: $HOSTNAME"
echo "SSH Port: $PORT"
[[ "$CK" == "y" || "$CK" == "Y" ]] && echo "Cloud kernel: enabled"
[[ "$BBR" == "y" || "$BBR" == "Y" ]] && echo "BBR: enabled"
[[ "$F2B" == "y" || "$F2B" == "Y" ]] && echo "Fail2ban: enabled"
echo -e "Password: \033[31m$PASSWORD\033[0m"
echo ""
read -rp "Confirm reinstall? (yes): " c
[[ "$c" != "yes" ]] && exit 0

wget --no-check-certificate -qO InstallNET.sh 'https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/InstallNET.sh'
chmod +x InstallNET.sh
bash InstallNET.sh $OS -pwd "$PASSWORD"
