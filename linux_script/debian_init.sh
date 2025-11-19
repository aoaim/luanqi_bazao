#!/bin/bash

# =====================================================
# Debian 13 Server Initialization Script
# =====================================================

set -e
set -u
set -o pipefail

# Auto-yes mode (skip confirmations)
AUTO_YES=false
if [[ "${1:-}" == "--yes" ]] || [[ "${1:-}" == "-y" ]]; then
    AUTO_YES=true
    echo "🚀 Running in auto-yes mode - all commands will be executed automatically"
fi

MARKER_FILE="/var/lib/init_linux_run.marker"
KERNEL_OPT_MARKER="/var/lib/init_linux_kernel_optimized.marker"
BACKUP_DIR="/root/init_linux_backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
RESET='\033[0m'

print_banner() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}$1${RESET}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

print_success() {
    echo -e "${GREEN}✓ $1${RESET}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${RESET}"
}

print_error() {
    echo -e "${RED}❌ $1${RESET}"
}

print_info() {
    echo -e "${CYAN}ℹ️  $1${RESET}"
}

# Validate yes/no input (accepts yes/y/no/n, case insensitive)
validate_yes_no() {
    local input="$1"
    local input_lower=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    if [ "$input_lower" = "yes" ] || [ "$input_lower" = "y" ] || [ "$input_lower" = "no" ] || [ "$input_lower" = "n" ]; then
        return 0
    else
        return 1
    fi
}

error_exit() {
    print_banner "Error occurred at line $1"
    print_error "Script execution failed. Please check the error message above."
    exit 1
}

cleanup_and_exit() {
    echo ""
    echo ""
    print_banner "⚠️  Script Interrupted"
    print_warning "Script execution was interrupted by user (Ctrl+C)"
    echo ""
    echo -e "${CYAN}${BOLD}Changes made so far:${RESET}"
    echo ""
    
    # Check what has been done
    local changes_made=false
    
    # Check if system packages were updated
    if [ -f "/var/lib/apt/periodic/update-success-stamp" ]; then
        local apt_timestamp=$(stat -c %Y /var/lib/apt/periodic/update-success-stamp 2>/dev/null || echo "0")
        local script_start=$(($(date +%s) - 600)) # Assume script started within last 10 minutes
        if [ "$apt_timestamp" -gt "$script_start" ]; then
            echo "  ✓ System packages updated"
            changes_made=true
        fi
    fi
    
    # Check installed programs
    if command -v speedtest &>/dev/null && [ "$SPEEDTEST_ALREADY_INSTALLED" = false ]; then
        echo "  ✓ Speedtest-cli installed"
        changes_made=true
    fi
    
    if command -v docker &>/dev/null && [ "$DOCKER_ALREADY_INSTALLED" = false ]; then
        echo "  ✓ Docker installed"
        changes_made=true
    fi
    
    if command -v hx &>/dev/null && [ "$HELIX_ALREADY_INSTALLED" = false ]; then
        echo "  ✓ Helix editor installed"
        changes_made=true
    fi
    
    if command -v eza &>/dev/null && [ "$EZA_ALREADY_INSTALLED" = false ]; then
        echo "  ✓ Eza installed"
        changes_made=true
    fi
    
    # Check if unattended-upgrades was installed
    if command -v unattended-upgrade &>/dev/null; then
        echo "  ✓ Unattended-upgrades configured"
        changes_made=true
    fi
    
    # Check if chrony config was modified
    if [ -f "$BACKUP_DIR/chrony.conf."* ] 2>/dev/null; then
        echo "  ✓ Time synchronization configured (chrony)"
        changes_made=true
    fi
    
    # Check if kernel optimization marker exists
    if [ -f "$KERNEL_OPT_MARKER" ]; then
        echo "  ✓ Network & kernel optimization applied"
        changes_made=true
    fi
    
    # Check if BBR is enabled
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
        echo "  ✓ BBR congestion control enabled"
        changes_made=true
    fi
    
    # Check if fail2ban is active
    if systemctl is-active fail2ban &>/dev/null; then
        echo "  ✓ Fail2ban service enabled"
        changes_made=true
    fi
    
    if [ "$changes_made" = false ]; then
        echo "  ℹ️  No significant changes were made"
    fi
    
    echo ""
    if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        print_info "Configuration backups saved to: $BACKUP_DIR"
    fi
    
    echo ""
    print_warning "The script did not complete. You can:"
    echo "  1. Run the script again to continue/complete the setup"
    echo "  2. Check system status manually"
    if [ "$changes_made" = true ]; then
        echo "  3. Some changes may require a system reboot to take effect"
    fi
    echo ""
    
    exit 130
}

trap 'error_exit $LINENO' ERR
trap 'cleanup_and_exit' SIGINT SIGTERM

clear
echo ""
echo -e "${CYAN}"
cat << 'EOF'
 ____       _     _              ___       _ _   
|  _ \  ___| |__ (_) __ _ _ __  |_ _|_ __ (_) |_ 
| | | |/ _ \ '_ \| |/ _` | '_ \  | || '_ \| | __|
| |_| |  __/ |_) | | (_| | | | | | || | | | | |_ 
|____/ \___|_.__/|_|\__,_|_| |_|___|_| |_|_|\__|
EOF
echo -e "${RESET}"
print_banner "Debian 13 Server Initialization Script 🚀"
echo "🔧 This script will help you set up a fresh Debian 13 server"
echo "🤖 Crafted by Claude Sonnet 4.5 & Gemini 3 Pro"

if [ "$(id -u)" != "0" ]; then
    print_error "Error: You must be root to run this script"
    echo "💡 Please run with: sudo bash $0"
    exit 1
fi

# Interactive auto-yes mode prompt (if not already set via command line)
if [ "$AUTO_YES" = false ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}${BOLD}🚀 Auto-Yes Mode${RESET}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "${YELLOW}Enabling auto-yes mode will automatically execute the following operations:${RESET}"
    echo ""
    echo "📦 Package Installation & Updates:"
    echo "   • Update system packages (apt update && apt upgrade)"
    echo "   • Install essential packages (curl, wget, git, etc.)"
    echo "   • Install unattended-upgrades (automatic security updates)"
    echo "   • Install speedtest-cli (network speed testing)"
    echo "   • Install Helix editor (modern terminal editor)"
    echo "   • Install Eza (modern ls replacement)"
    echo ""
    echo "⚙️  System Configuration:"
    echo "   • Configure time synchronization (systemd-timesyncd)"
    echo "   • Load kernel modules (nf_conntrack, tls)"
    echo "   • Enable BBR congestion control (if not already enabled)"
    echo "   • Configure network & security settings (fail2ban)"
    echo ""
    echo "🔧 Shell Customization:"
    echo "   • Configure bash aliases and environment"
    echo "   • Set up color prompt and command shortcuts"
    echo ""
    echo -e "${RED}❌ What will NOT be executed automatically:${RESET}"
    echo "   • Won't install Docker & Docker Compose (default: no)"
    echo "   • Won't install Watchtower (depends on Docker)"
    echo "   • Won't apply aggressive network & kernel optimization (too risky for general use)"
    echo "   • Won't delete any user data or system files"
    echo "   • Won't overwrite configs (backups created in $BACKUP_DIR)"
    echo "   • Won't change timezone (keeps current: $(timedatectl show --property=Timezone --value 2>/dev/null || echo 'Unknown'))"
    echo "   • Won't enable stable/proposed updates (security updates only)"
    echo "   • Won't install optional monitoring tools (iftop, nload, iotop, etc.)"
    echo "   • Won't reboot system (manual reboot required after completion)"
    echo "   • Script aborts on any error to prevent partial installations"
    echo ""
    echo -e "${CYAN}${BOLD}⚠️  Note: A system reboot will be required after completion${RESET}"
    echo ""
    while true; do
        echo -e "${CYAN}${BOLD}>>> Do you want to enable auto-yes mode? (yes/no, default: no):${RESET} "
        read enable_auto_yes
        if [ -z "$enable_auto_yes" ]; then
            enable_auto_yes="no"
        fi
        if validate_yes_no "$enable_auto_yes"; then
            break
        else
            print_error "Invalid input. Please enter 'yes', 'y', 'no', or 'n'"
        fi
    done
    enable_auto_yes_lower=$(echo "$enable_auto_yes" | tr '[:upper:]' '[:lower:]')
    if [ "$enable_auto_yes_lower" = "yes" ] || [ "$enable_auto_yes_lower" = "y" ]; then
        AUTO_YES=true
        echo ""
        print_success "Auto-yes mode enabled - all commands will be executed automatically"
    else
        print_info "Interactive mode - you will be prompted for each step"
    fi
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "debian" ]; then
        print_error "Error: This script only supports Debian (detected: $PRETTY_NAME)"
        exit 1
    fi
    DEBIAN_VERSION=$(cat /etc/debian_version | cut -d. -f1)
    ARCH=$(uname -m)
    if [ "$DEBIAN_VERSION" != "13" ]; then
        print_error "Error: This script only supports Debian 13 (detected: Debian $DEBIAN_VERSION)"
        exit 1
    fi
    if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "amd64" ]; then
        print_error "Error: This script only supports amd64 architecture (detected: $ARCH)"
        exit 1
    fi
    print_success "Running on Debian 13 amd64"
fi

# ============================================
# Check for updates
# ============================================
print_banner "Checking managed programs for updates..."

UPDATES_AVAILABLE=false
UPDATE_LIST=""
PROGRAMS_FOUND=false

# Track installation status
SPEEDTEST_ALREADY_INSTALLED=false
HELIX_ALREADY_INSTALLED=false
EZA_ALREADY_INSTALLED=false
DOCKER_ALREADY_INSTALLED=false

# Check speedtest-cli
if command -v speedtest &> /dev/null; then
    PROGRAMS_FOUND=true
    SPEEDTEST_ALREADY_INSTALLED=true
    CURRENT_SPEEDTEST=$(speedtest --version 2>/dev/null | grep -oP 'Ookla \K[0-9.]+' | head -n1 || echo "unknown")
    print_success "Speedtest installed: v$CURRENT_SPEEDTEST"
    
    LATEST_SPEEDTEST_VERSION=$(curl -sL "https://packagecloud.io/ookla/speedtest-cli/debian/dists/trixie/main/binary-amd64/Packages" 2>/dev/null | \
        grep -A10 "Package: speedtest" | \
        grep "^Version:" | \
        head -n1 | \
        awk '{print $2}' || echo "")
    
    if [ -n "$LATEST_SPEEDTEST_VERSION" ]; then
        CURRENT_SPEEDTEST_VER="$CURRENT_SPEEDTEST"
        LATEST_SPEEDTEST_VER=$(echo "$LATEST_SPEEDTEST_VERSION" | grep -oP '^[0-9.]+' || echo "0")
        
        if [ "$CURRENT_SPEEDTEST_VER" != "$LATEST_SPEEDTEST_VER" ]; then
            print_warning "New version available: $LATEST_SPEEDTEST_VERSION"
            UPDATES_AVAILABLE=true
            UPDATE_LIST="${UPDATE_LIST}  • speedtest-cli: $CURRENT_SPEEDTEST_VER → $LATEST_SPEEDTEST_VER\n"
        fi
    fi
fi

# Check Helix editor
if command -v hx &> /dev/null; then
    PROGRAMS_FOUND=true
    HELIX_ALREADY_INSTALLED=true
    CURRENT_HELIX=$(hx --version 2>/dev/null | grep -oP 'helix \K[0-9.]+' | head -n1 || echo "unknown")
    print_success "Helix Editor installed: v$CURRENT_HELIX"
    
    LATEST_HELIX_VERSION=$(curl -s --max-time 10 https://api.github.com/repos/helix-editor/helix/releases/latest 2>/dev/null | \
        grep '"tag_name":' | \
        sed -E 's/.*"tag_name": "([^"]+)".*/\1/' || echo "")
    
    if [ -n "$LATEST_HELIX_VERSION" ]; then
        CURRENT_HELIX_VER="$CURRENT_HELIX"
        LATEST_HELIX_VER=$(echo "$LATEST_HELIX_VERSION" | sed 's/^v//')
        
        if [ "$CURRENT_HELIX_VER" != "$LATEST_HELIX_VER" ]; then
            print_warning "New version available: $LATEST_HELIX_VERSION"
            UPDATES_AVAILABLE=true
            UPDATE_LIST="${UPDATE_LIST}  • Helix editor: $CURRENT_HELIX_VER → $LATEST_HELIX_VER\n"
        fi
    fi
fi

# Check eza
if command -v eza &> /dev/null; then
    PROGRAMS_FOUND=true
    EZA_ALREADY_INSTALLED=true
    CURRENT_EZA=$(eza --version 2>/dev/null | grep -oP '^v[0-9.]+' || echo "unknown")
    print_success "Eza installed: $CURRENT_EZA"
    
    LATEST_EZA_VERSION=$(curl -s --max-time 10 https://api.github.com/repos/eza-community/eza/releases/latest 2>/dev/null | \
        grep '"tag_name":' | \
        sed -E 's/.*"tag_name": "([^"]+)".*/\1/' || echo "")
    
    if [ -n "$LATEST_EZA_VERSION" ]; then
        # Extract version from eza output - handles both "v0.23.4" and "eza - description\nv0.23.4"
        CURRENT_EZA_VER=$(eza --version 2>/dev/null | grep -oP '^v\K[0-9.]+' || echo "0")
        LATEST_EZA_VER=$(echo "$LATEST_EZA_VERSION" | sed 's/^v//')
        
        if [ "$CURRENT_EZA_VER" != "$LATEST_EZA_VER" ]; then
            print_warning "New version available: $LATEST_EZA_VERSION"
            UPDATES_AVAILABLE=true
            UPDATE_LIST="${UPDATE_LIST}  • eza: $CURRENT_EZA_VER → $LATEST_EZA_VER\n"
        fi
    fi
fi

# Check Docker
if command -v docker &> /dev/null; then
    DOCKER_ALREADY_INSTALLED=true
fi

if [ "$PROGRAMS_FOUND" = false ]; then
    print_info "No managed programs detected (Speedtest / Helix Editor / Eza). Skipping update check."
fi

# Auto-update if available
if [ "$UPDATES_AVAILABLE" = true ]; then
    print_banner "Updates available"
    echo -e "$UPDATE_LIST"
    print_info "Automatically updating programs..."
    
    # Update speedtest-cli
    if command -v speedtest &> /dev/null && echo "$UPDATE_LIST" | grep -q "speedtest-cli"; then
        echo "Updating speedtest-cli..."
        SPEEDTEST_DEB_PATH=$(curl -sL "https://packagecloud.io/ookla/speedtest-cli/debian/dists/trixie/main/binary-amd64/Packages" 2>/dev/null | \
            grep -A10 "Package: speedtest" | \
            grep "^Filename:" | \
            head -n1 | \
            awk '{print $2}' || echo "")
        
        if [ -n "$SPEEDTEST_DEB_PATH" ]; then
            SPEEDTEST_DEB_URL="https://packagecloud.io/ookla/speedtest-cli/debian/${SPEEDTEST_DEB_PATH}"
            wget -q --show-progress "$SPEEDTEST_DEB_URL" -O speedtest_update.deb
            if [ -s speedtest_update.deb ]; then
                dpkg -i speedtest_update.deb || apt-get install -f -y
                rm -f speedtest_update.deb
                print_success "speedtest-cli updated to $(speedtest --version 2>/dev/null | head -n1)"
            else
                print_error "Failed to download speedtest update"
                rm -f speedtest_update.deb
            fi
        fi
    fi
    
    # Update Helix
    if command -v hx &> /dev/null && echo "$UPDATE_LIST" | grep -q "Helix"; then
        echo "Updating Helix editor..."
        LATEST_HELIX_URL=$(curl -s --max-time 10 https://api.github.com/repos/helix-editor/helix/releases/latest 2>/dev/null | \
            grep '"browser_download_url".*amd64\.deb"' | \
            head -n1 | \
            cut -d'"' -f4 || echo "")
        
        if [ -n "$LATEST_HELIX_URL" ]; then
            wget -q --show-progress "$LATEST_HELIX_URL" -O helix_update.deb
            if [ -s helix_update.deb ]; then
                dpkg -i helix_update.deb || apt-get install -f -y
                rm -f helix_update.deb
                print_success "Helix updated to $(hx --version 2>/dev/null | head -n1)"
            else
                print_error "Failed to download Helix update"
                rm -f helix_update.deb
            fi
        fi
    fi
    
    # Update eza
    if command -v eza &> /dev/null && echo "$UPDATE_LIST" | grep -q "eza"; then
        echo "Updating eza..."
        LATEST_EZA_TARBALL=$(curl -s --max-time 10 https://api.github.com/repos/eza-community/eza/releases/latest 2>/dev/null | \
            grep '"browser_download_url".*eza_x86_64-unknown-linux-gnu.tar.gz"' | \
            head -n1 | \
            cut -d'"' -f4 || echo "")
        
        if [ -n "$LATEST_EZA_TARBALL" ]; then
            wget -q --show-progress "$LATEST_EZA_TARBALL" -O eza_update.tar.gz
            if [ -s eza_update.tar.gz ]; then
                TMP_EZA_DIR=$(mktemp -d)
                if tar -xzf eza_update.tar.gz -C "$TMP_EZA_DIR" 2>/dev/null; then
                    EZA_BIN_PATH=$(find "$TMP_EZA_DIR" -type f -name eza -executable -print -quit 2>/dev/null || true)
                    if [ -n "$EZA_BIN_PATH" ]; then
                        install -m 755 "$EZA_BIN_PATH" /usr/local/bin/eza
                        print_success "eza updated to $(eza --version 2>/dev/null | head -n1)"
                    else
                        print_error "Failed to locate eza binary in update package"
                    fi
                else
                    print_error "Failed to extract eza update"
                fi
                rm -f eza_update.tar.gz
                rm -rf "$TMP_EZA_DIR"
            else
                print_error "Failed to download eza update"
                rm -f eza_update.tar.gz
            fi
        fi
    fi
    
    print_success "All updates completed successfully!"
else
    if [ "$PROGRAMS_FOUND" = true ]; then
        print_success "All installed programs are up to date"
    fi
fi

# ============================================
# Check if script has run before
# ============================================
if [ -f "$MARKER_FILE" ]; then
    print_banner "Warning"
    print_warning "This script has already been run on: $(cat "$MARKER_FILE")"
    # Even in AUTO_YES mode, we want to confirm reconfiguration
    if [ "$AUTO_YES" = true ]; then
        print_warning "Auto-yes mode detected, but reconfiguration requires manual confirmation."
    fi

    while true; do
        echo -e "${CYAN}${BOLD}>>> Do you want to continue anyway? This may overwrite existing configurations. (yes/no):${RESET} "
        read continue_run
        if validate_yes_no "$continue_run"; then
            break
        else
            print_error "Invalid input. Please enter 'yes', 'y', 'no', or 'n'"
        fi
    done
    continue_run_lower=$(echo "$continue_run" | tr '[:upper:]' '[:lower:]')
    if [ "$continue_run_lower" != "yes" ] && [ "$continue_run_lower" != "y" ]; then
        echo "Exiting..."
        exit 0
    fi
    echo "Continuing with reconfiguration..."
fi

backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        if [ ! -d "$BACKUP_DIR" ]; then
            mkdir -p "$BACKUP_DIR"
            print_success "Backup directory created: $BACKUP_DIR"
        fi
        cp "$file" "${BACKUP_DIR}/$(basename "$file").${TIMESTAMP}.bak"
        echo "  Backed up: $file"
    fi
}

print_banner "Updating system and installing essential packages..."

# Check if dpkg is interrupted or needs configuration
if ! dpkg --audit >/dev/null 2>&1 || dpkg --audit 2>&1 | grep -q "dpkg was interrupted" || ! apt-get check >/dev/null 2>&1; then
    print_warning "Package system needs repair. Need to fix package configuration first."
    echo ""
    
    if [ "$AUTO_YES" = true ]; then
        print_info "Auto-yes mode: Automatically fixing package system..."
        dpkg --configure -a
        if ! apt-get install --fix-broken -y 2>&1 | tee /tmp/apt_fix.log; then
            if grep -q "needs to be reinstalled, but I can't find an archive for it" /tmp/apt_fix.log; then
                broken_pkg=$(grep "The package .* needs to be reinstalled" /tmp/apt_fix.log | head -n1 | awk '{print $4}')
                if [ -n "$broken_pkg" ]; then
                    print_warning "Detected broken package causing repair failure: $broken_pkg"
                    print_info "Force removing $broken_pkg to proceed..."
                    dpkg --remove --force-remove-reinstreq "$broken_pkg"
                    print_info "Retrying package system repair..."
                    apt-get install --fix-broken -y
                fi
            fi
        fi
        print_success "Package system repair attempted"
    else
        while true; do
            echo -e "${CYAN}${BOLD}>>> Do you want to run repair commands (dpkg --configure -a) to fix this? (yes/y):${RESET} "
            read fix_dpkg
            if [ -z "$fix_dpkg" ]; then
                fix_dpkg="yes"
            fi
            if validate_yes_no "$fix_dpkg"; then
                break
            else
                print_error "Invalid input. Please enter 'yes', 'y', 'no', or 'n'"
            fi
        done
        
        fix_dpkg_lower=$(echo "$fix_dpkg" | tr '[:upper:]' '[:lower:]')
        if [ "$fix_dpkg_lower" = "yes" ] || [ "$fix_dpkg_lower" = "y" ]; then
            echo "Running repair commands..."
            dpkg --configure -a
            apt-get install --fix-broken -y
            print_success "Package system repair attempted"
        else
            print_warning "Skipping repair. Subsequent apt commands may fail."
        fi
    fi
    echo ""
fi

apt update && apt upgrade -y && apt autoremove -y
apt install -y openssl gnupg curl wget nano htop cron chrony fail2ban unzip logrotate

print_banner "Network & System Monitoring Tools (Optional)"
if [ "$AUTO_YES" = true ]; then
    install_monitoring_lower="no"
    print_info "Auto-yes mode: Skipping monitoring tools installation"
else
    print_info "These tools help monitor network traffic and system I/O:"
    echo "  • dnsutils     - DNS query tools (dig, nslookup, host)"
    echo "  • nload        - Real-time network traffic monitor"
    echo "  • iftop        - Display bandwidth usage per connection"
    echo "  • vnstat       - Network traffic statistics daemon"
    echo "  • iotop        - Display I/O usage by processes"
    echo ""
    while true; do
        echo -e "${CYAN}${BOLD}>>> Do you want to install these monitoring tools? (y/yes, default: no):${RESET} "
        read install_monitoring
        if [ -z "$install_monitoring" ]; then
            install_monitoring="no"
        fi
        if validate_yes_no "$install_monitoring"; then
            break
        else
            print_error "Invalid input. Please enter 'yes', 'y', 'no', or 'n'"
        fi
    done
    install_monitoring_lower=$(echo "$install_monitoring" | tr '[:upper:]' '[:lower:]')
fi
if [ "$install_monitoring_lower" = "y" ] || [ "$install_monitoring_lower" = "yes" ]; then
    echo "Installing network & system monitoring tools..."
    apt install -y dnsutils nload iftop vnstat iotop
    print_success "Monitoring tools installed successfully"
    
    # Enable vnstat if installed
    if command -v vnstat &> /dev/null; then
        systemctl enable --now vnstat 2>/dev/null || true
        print_success "Vnstat service enabled"
    fi
else
    print_info "Skipping monitoring tools installation"
    echo "  You can install them later with:"
    echo "  apt install -y dnsutils nload iftop vnstat iotop"
fi

print_banner "Unattended-upgrades installation"
print_info "Unattended-upgrades automatically installs security updates daily."
echo ""
if [ "$AUTO_YES" = true ]; then
    install_unattended_lower="yes"
    echo "Auto-yes mode: Installing unattended-upgrades..."
else
    while true; do
        echo -e "${CYAN}${BOLD}>>> Do you want to install and enable unattended-upgrades? (y/yes, default: no):${RESET} "
        read install_unattended
        if [ -z "$install_unattended" ]; then
            install_unattended="no"
        fi
        if validate_yes_no "$install_unattended"; then
            break
        else
            print_error "Invalid input. Please enter 'yes', 'y', 'no', or 'n'"
        fi
    done
    install_unattended_lower=$(echo "$install_unattended" | tr '[:upper:]' '[:lower:]')
fi
if [ "$install_unattended_lower" = "y" ] || [ "$install_unattended_lower" = "yes" ]; then
    echo "Installing unattended-upgrades..."
    apt install -y unattended-upgrades
    
    if dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii" || command -v unattended-upgrade &>/dev/null; then
        print_success "unattended-upgrades installed successfully"
        echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections
        dpkg-reconfigure -f noninteractive unattended-upgrades
        if [ -f /etc/apt/apt.conf.d/20auto-upgrades ]; then
            print_success "Auto-updates configuration created"
        fi
        if systemctl is-enabled apt-daily.timer >/dev/null 2>&1; then
            print_success "apt-daily.timer is enabled"
        fi
        if systemctl is-enabled apt-daily-upgrade.timer >/dev/null 2>&1; then
            print_success "apt-daily-upgrade.timer is enabled"
        fi
        
        echo ""
        echo "By default, only security updates are automatically installed."
        echo "You can also enable automatic updates for:"
        echo "  • Stable updates (bug fixes)"
        echo "  • Proposed updates (testing)"
        if [ "$AUTO_YES" = true ]; then
            enable_more_updates_lower="no"
            echo "Auto-yes mode: Keeping default configuration (security updates only)"
        else
            while true; do
                echo -e "${CYAN}${BOLD}>>> Do you want to enable updates beyond security? (y/yes, default: no):${RESET} "
                read enable_more_updates
                if [ -z "$enable_more_updates" ]; then
                    enable_more_updates="no"
                fi
                if validate_yes_no "$enable_more_updates"; then
                    break
                else
                    print_error "Invalid input. Please enter 'yes', 'y', 'no', or 'n'"
                fi
            done
            enable_more_updates_lower=$(echo "$enable_more_updates" | tr '[:upper:]' '[:lower:]')
        fi
        
        if [ "$enable_more_updates_lower" = "y" ] || [ "$enable_more_updates_lower" = "yes" ]; then
            echo "Configuring additional update sources..."
            cp /etc/apt/apt.conf.d/50unattended-upgrades /etc/apt/apt.conf.d/52unattended-upgrades-local
            
            # Enable stable updates
            sed -i 's|^//      "origin=Debian,codename=\${distro_codename}-updates";|        "origin=Debian,codename=${distro_codename}-updates";|' /etc/apt/apt.conf.d/52unattended-upgrades-local
            
            print_success "Enabled automatic stable updates (bug fixes)"
            print_info "Configuration saved to: /etc/apt/apt.conf.d/52unattended-upgrades-local"
        else
            print_success "Keeping default configuration (security updates only)"
        fi
        
        print_success "Unattended-upgrades configured and enabled"
    else
        print_warning "unattended-upgrades installation could not be verified"
    fi
else
    print_info "Skipping unattended-upgrades installation"
fi

# speedtest-cli
print_banner "Speedtest-cli installation"
if [ "$SPEEDTEST_ALREADY_INSTALLED" = true ]; then
    print_success "Speedtest-cli already installed, skipping..."
    SPEEDTEST_VERSION=$(speedtest --version 2>/dev/null | grep -oP 'Ookla \K[0-9.]+' | head -n1 || echo "N/A")
else
    if [ "$AUTO_YES" = true ]; then
        install_speedtest_lower="yes"
        echo "Auto-yes mode: Installing speedtest-cli..."
    else
        while true; do
            echo -e "${CYAN}${BOLD}>>> Do you want to install speedtest-cli? (y/yes, default: no):${RESET} "
            read install_speedtest
            if [ -z "$install_speedtest" ]; then
                install_speedtest="no"
            fi
            if validate_yes_no "$install_speedtest"; then
                break
            else
                print_error "Invalid input. Please enter 'yes', 'y', 'no', or 'n'"
            fi
        done
        install_speedtest_lower=$(echo "$install_speedtest" | tr '[:upper:]' '[:lower:]')
    fi
    SPEEDTEST_VERSION="N/A"
    if [ "$install_speedtest_lower" = "y" ] || [ "$install_speedtest_lower" = "yes" ]; then
    echo "Fetching latest speedtest-cli version from Debian repository..."
    
    SPEEDTEST_DEB_PATH=$(curl -sL "https://packagecloud.io/ookla/speedtest-cli/debian/dists/trixie/main/binary-amd64/Packages" 2>/dev/null | \
        grep -A10 "Package: speedtest" | \
        grep "^Filename:" | \
        head -n1 | \
        awk '{print $2}' || echo "")
    
    if [ -n "$SPEEDTEST_DEB_PATH" ]; then
        SPEEDTEST_DEB_URL="https://packagecloud.io/ookla/speedtest-cli/debian/${SPEEDTEST_DEB_PATH}"
        SPEEDTEST_VERSION_INFO=$(curl -sL "https://packagecloud.io/ookla/speedtest-cli/debian/dists/trixie/main/binary-amd64/Packages" 2>/dev/null | \
            grep -A10 "Package: speedtest" | \
            grep "^Version:" | \
            head -n1 | \
            awk '{print $2}' || echo "unknown")
        print_success "Found latest version: $SPEEDTEST_VERSION_INFO"
        
        echo "Downloading speedtest-cli..."
        wget -q --show-progress "$SPEEDTEST_DEB_URL" -O speedtest.deb
        if [ -s speedtest.deb ]; then
            echo "Installing speedtest-cli..."
            dpkg -i speedtest.deb || apt-get install -f -y
            rm -f speedtest.deb
            SPEEDTEST_VERSION=$(speedtest --version 2>/dev/null | grep -oP 'Ookla \K[0-9.]+' | head -n1 || echo "N/A")
            echo "✓ Speedtest-cli installed: v$SPEEDTEST_VERSION"
        else
            echo "❌ Failed to download speedtest deb package"
            rm -f speedtest.deb
            print_error "Failed to install speedtest-cli"
        fi
    else
        print_error "Could not fetch latest version from repository. Skipping installation."
    fi
    else
        echo "⏭️  Skipping speedtest-cli installation"
    fi
fi

# Docker
print_banner "Docker installation"
if [ "$DOCKER_ALREADY_INSTALLED" = true ]; then
    print_success "Docker already installed, skipping..."
    DOCKER_VERSION=$(docker --version 2>/dev/null | grep -oP 'Docker version \K[0-9.]+' || echo "N/A")
else
    if [ "$AUTO_YES" = true ]; then
        install_docker_lower="no"
        echo "Auto-yes mode: Skipping Docker installation"
    else
        while true; do
            echo -e "${CYAN}${BOLD}>>> Do you want to install Docker? (y/yes, default: no):${RESET} "
            read install_docker
            if [ -z "$install_docker" ]; then
                install_docker="no"
            fi
            if validate_yes_no "$install_docker"; then
                break
            else
                print_error "Invalid input. Please enter 'yes', 'y', 'no', or 'n'"
            fi
        done
        install_docker_lower=$(echo "$install_docker" | tr '[:upper:]' '[:lower:]')
    fi
    DOCKER_VERSION="N/A"
    if [ "$install_docker_lower" = "y" ] || [ "$install_docker_lower" = "yes" ]; then
        echo "Installing Docker..."
        wget -qO- https://get.docker.com/ | sh
        DOCKER_VERSION=$(docker --version 2>/dev/null | grep -oP 'Docker version \K[0-9.]+' || echo "N/A")
        print_success "Docker installed successfully"
        
        print_banner "Watchtower installation"
        if [ "$AUTO_YES" = true ]; then
            install_watchtower_lower="yes"
            echo "Auto-yes mode: Enabling Watchtower..."
        else
            while true; do
                echo -e "${CYAN}${BOLD}>>> Do you want to enable Watchtower (auto-update Docker containers)? (y/yes, default: no):${RESET} "
                read install_watchtower
                if [ -z "$install_watchtower" ]; then
                    install_watchtower="no"
                fi
                if validate_yes_no "$install_watchtower"; then
                    break
                else
                    print_error "Invalid input. Please enter 'yes', 'y', 'no', or 'n'"
                fi
            done
            install_watchtower_lower=$(echo "$install_watchtower" | tr '[:upper:]' '[:lower:]')
        fi
        if [ "$install_watchtower_lower" = "y" ] || [ "$install_watchtower_lower" = "yes" ]; then
            echo "Starting Watchtower container..."
            docker run -d \
                --name watchtower \
                --restart unless-stopped \
                -v /var/run/docker.sock:/var/run/docker.sock \
                nickfedor/watchtower \
                --cleanup
            print_success "Watchtower enabled"
        else
            print_info "Skipping Watchtower installation"
        fi
    else
        print_info "Skipping Docker installation"
    fi
fi

# Helix
print_banner "Helix editor installation"
if [ "$HELIX_ALREADY_INSTALLED" = true ]; then
    print_success "Helix editor already installed, skipping..."
    HELIX_VERSION=$(hx --version 2>/dev/null | grep -oP 'helix \K[0-9.]+' | head -n1 || echo "N/A")
else
    if [ "$AUTO_YES" = true ]; then
        install_helix_lower="yes"
        echo "Auto-yes mode: Installing Helix editor..."
    else
        while true; do
            echo -e "${CYAN}${BOLD}>>> Do you want to install Helix editor? (y/yes, default: no):${RESET} "
            read install_helix
            if [ -z "$install_helix" ]; then
                install_helix="no"
            fi
            if validate_yes_no "$install_helix"; then
                break
            else
                print_error "Invalid input. Please enter 'yes', 'y', 'no', or 'n'"
            fi
        done
        install_helix_lower=$(echo "$install_helix" | tr '[:upper:]' '[:lower:]')
    fi
    HELIX_INSTALLED=false
    HELIX_VERSION="N/A"
    if [ "$install_helix_lower" = "y" ] || [ "$install_helix_lower" = "yes" ]; then
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
                        print_success "Helix editor installed successfully"
                        break
                    else
                        print_warning "Failed to install downloaded package, retrying..."
                        rm -f helix.deb
                    fi
                else
                    print_warning "Download failed, retrying..."
                    rm -f helix.deb
                fi
            else
                print_warning "Failed to fetch release URL, retrying..."
            fi
            sleep 2
        done
        if [ "$HELIX_INSTALLED" = false ]; then
            print_warning "Could not install Helix editor from GitHub"
            print_info "You can install it manually later from: https://helix-editor.com"
        fi
        if [ "$HELIX_INSTALLED" = true ]; then
            cat > /etc/profile.d/helix-alias.sh <<'EOF'
alias vi='hx'
alias vim='hx'
EOF
            chmod 644 /etc/profile.d/helix-alias.sh
            HELIX_VERSION=$(hx --version 2>/dev/null | grep -oP 'helix \K[0-9.]+' | head -n1 || echo "N/A")
            print_success "Helix aliased to vi/vim"
        fi
    else
        print_info "Skipping Helix editor installation"
    fi
fi

# Eza
print_banner "Eza installation"
if [ "$EZA_ALREADY_INSTALLED" = true ]; then
    print_success "Eza already installed, skipping..."
    EZA_VERSION=$(eza --version 2>/dev/null | grep -oP '^v[0-9.]+' || echo "N/A")
else
    if [ "$AUTO_YES" = true ]; then
        install_eza_lower="yes"
        echo "Auto-yes mode: Installing eza..."
    else
        while true; do
            echo -e "${CYAN}${BOLD}>>> Do you want to install eza (modern ls replacement)? (y/yes, default: no):${RESET} "
            read install_eza
            if [ -z "$install_eza" ]; then
                install_eza="no"
            fi
            if validate_yes_no "$install_eza"; then
                break
            else
                print_error "Invalid input. Please enter 'yes', 'y', 'no', or 'n'"
            fi
        done
        install_eza_lower=$(echo "$install_eza" | tr '[:upper:]' '[:lower:]')
    fi
    EZA_INSTALLED=false
    EZA_VERSION="N/A"
    if [ "$install_eza_lower" = "y" ] || [ "$install_eza_lower" = "yes" ]; then
        for attempt in 1 2 3; do
            echo "Attempt $attempt: Fetching latest eza release from GitHub..."
            LATEST_EZA_TARBALL=$(curl -s --max-time 10 https://api.github.com/repos/eza-community/eza/releases/latest 2>/dev/null | grep -m1 '"browser_download_url".*eza_x86_64-unknown-linux-gnu.tar.gz"' | cut -d'"' -f4 || true)
            if [ -n "$LATEST_EZA_TARBALL" ]; then
                echo "Downloading eza from: $LATEST_EZA_TARBALL"
                if wget -q --show-progress --timeout=30 -O eza.tar.gz "$LATEST_EZA_TARBALL" 2>/dev/null && [ -f eza.tar.gz ] && [ -s eza.tar.gz ]; then
                    TMP_EZA_DIR=$(mktemp -d)
                    if tar -xzf eza.tar.gz -C "$TMP_EZA_DIR" 2>/dev/null; then
                        EZA_BIN_PATH=$(find "$TMP_EZA_DIR" -type f -name eza -executable -print -quit 2>/dev/null || true)
                        if [ -n "$EZA_BIN_PATH" ]; then
                            install -m 755 "$EZA_BIN_PATH" /usr/local/bin/eza
                            rm -f eza.tar.gz
                            rm -rf "$TMP_EZA_DIR"
                            EZA_INSTALLED=true
                            print_success "Eza installed from GitHub release (binary)"
                            break
                        else
                            print_warning "Could not locate eza binary inside tarball"
                            rm -rf "$TMP_EZA_DIR"
                        fi
                    else
                        print_warning "Failed to extract tarball"
                    fi
                    rm -f eza.tar.gz
                    rm -rf "$TMP_EZA_DIR"
                else
                    print_warning "Download failed, retrying..."
                    rm -f eza.tar.gz
                fi
            else
                print_warning "Failed to fetch tarball URL, retrying..."
            fi
            sleep 2
        done
        
        if [ "$EZA_INSTALLED" = false ]; then
            print_warning "Could not install eza from GitHub"
            print_info "You can install it manually later from: https://github.com/eza-community/eza"
        fi
        if [ "$EZA_INSTALLED" = true ]; then
            cat > /etc/profile.d/eza-alias.sh <<'EOF'
alias ls='eza'
alias ll='eza -lh --icons --git'
alias la='eza -lah --icons --git'
alias lt='eza -lh --icons --git --tree'
alias l='eza -lah --icons --git'
EOF
            chmod 644 /etc/profile.d/eza-alias.sh
            EZA_VERSION=$(eza --version 2>/dev/null | grep -oP '^v[0-9.]+' || echo "N/A")
            print_success "Eza aliased to ls"
        fi
    else
        print_info "Skipping eza installation"
    fi
fi

print_banner "Configuring time synchronization..."

# Determine NTP server region based on location
NTP_REGION_PREFIX="" # Default to global pool (0.pool.ntp.org)
print_info "Detecting server location for optimal NTP servers..."

# Try to fetch timezone from ipinfo.io
DETECTED_TZ=$(curl -s --max-time 5 ipinfo.io/timezone || echo "")

# If network fetch fails, try system timezone
if [ -z "$DETECTED_TZ" ]; then
    DETECTED_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")
fi

if [ -n "$DETECTED_TZ" ]; then
    case "$DETECTED_TZ" in
        Asia/*)      NTP_REGION_PREFIX="asia." ;;
        Europe/*)    NTP_REGION_PREFIX="europe." ;;
        Africa/*)    NTP_REGION_PREFIX="africa." ;;
        Australia/*|Pacific/*) NTP_REGION_PREFIX="oceania." ;;
        America/*)
            # Rough heuristic for South America
            if [[ "$DETECTED_TZ" =~ (Argentina|Brazil|Chile|Colombia|Peru|Venezuela|Sao_Paulo|Buenos_Aires|Santiago|Bogota|Lima|Caracas) ]]; then
                NTP_REGION_PREFIX="south-america."
            else
                NTP_REGION_PREFIX="north-america."
            fi
            ;;
    esac
fi

print_success "Selected NTP servers: 0.${NTP_REGION_PREFIX}pool.ntp.org (Detected: ${DETECTED_TZ:-Unknown})"

backup_file /etc/chrony/chrony.conf
cat > /etc/chrony/chrony.conf <<EOF
server 0.${NTP_REGION_PREFIX}pool.ntp.org iburst
server 1.${NTP_REGION_PREFIX}pool.ntp.org iburst
server 2.${NTP_REGION_PREFIX}pool.ntp.org iburst
server 3.${NTP_REGION_PREFIX}pool.ntp.org iburst
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
        print_success "Time synchronized"
        break
    fi
    sleep 5
done

# Timezone
CURRENT_TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Unknown")
echo ""
echo "Current timezone: $CURRENT_TIMEZONE"
if [ "$CURRENT_TIMEZONE" != "Asia/Singapore" ]; then
    if [ "$AUTO_YES" = true ]; then
        change_timezone_lower="no"
        echo "Auto-yes mode: Skipping timezone change (keeping current timezone: $CURRENT_TIMEZONE)"
    else
        while true; do
            echo -e "${CYAN}${BOLD}>>> Do you want to change timezone to Asia/Singapore? (y/yes, default: no):${RESET} "
            read change_timezone
            if [ -z "$change_timezone" ]; then
                change_timezone="no"
            fi
            if validate_yes_no "$change_timezone"; then
                break
            else
                print_error "Invalid input. Please enter 'yes', 'y', 'no', or 'n'"
            fi
        done
        change_timezone_lower=$(echo "$change_timezone" | tr '[:upper:]' '[:lower:]')
    fi
    if [ "$change_timezone_lower" = "y" ] || [ "$change_timezone_lower" = "yes" ]; then
        timedatectl set-timezone Asia/Singapore
        print_success "Timezone changed to Asia/Singapore"
    else
        print_info "Keeping current timezone: $CURRENT_TIMEZONE"
    fi
else
    print_success "Timezone already set to Asia/Singapore"
fi

print_banner "Loading kernel modules..."
# nf_conntrack: Connection tracking
# tls: Kernel TLS acceleration
mkdir -p /usr/lib/modules-load.d
echo nf_conntrack > /usr/lib/modules-load.d/network-performance.conf
echo tls >> /usr/lib/modules-load.d/network-performance.conf
modprobe nf_conntrack 2>/dev/null || true
modprobe tls 2>/dev/null || true
print_success "Kernel modules configured (nf_conntrack, tls)"
systemctl enable --now fail2ban
print_success "Fail2ban enabled"

print_banner "Network & Kernel Optimization (Optional)"

# Check if kernel optimization has already been applied
if [ -f "$KERNEL_OPT_MARKER" ]; then
    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${RED}${BOLD}⚠️  NETWORK & KERNEL OPTIMIZATION ALREADY APPLIED${RESET}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${YELLOW}Applied on: ${BOLD}$(cat "$KERNEL_OPT_MARKER")${RESET}"
    echo -e "${YELLOW}Skipping network & kernel optimization to prevent potential conflicts${RESET}"
    echo ""
    print_info "If you need to re-apply optimizations, manually remove:"
    echo -e "   ${BOLD}rm $KERNEL_OPT_MARKER${RESET}"
    echo ""
    optimize_system_lower="no"
else
    echo -e "${YELLOW}⚠️  These optimizations are designed for high-traffic scenarios:${RESET}"
    echo "  • Proxy servers, CDN nodes, VPN gateways"
    echo "  • High-concurrency web servers"
    echo "  • Network-intensive applications"
    echo ""
    echo -e "${RED}⚠️  NOT recommended for:${RESET}"
    echo "  • General purpose production servers"
    echo "  • Database servers (may cause issues)"
    echo "  • Low-traffic personal servers"
    echo ""
    echo "This will apply:"
    echo "  • System resource limits (unlimited file descriptors and processes)"
    echo "  • Journald log size limits (prevent disk space issues)"
    echo "  • Entropy pool enhancement (haveged)"
    echo "  • Random number generator optimization (rng-tools)"
    echo "  • Disable KSM and transparent huge pages"
    echo "  • Aggressive network tuning (BBR, TCP optimization)"
    echo "  • Reference: Kernel optimizations inspired by https://cdn.skk.moe/sh/optimize.sh"
    echo ""
    if [ "$AUTO_YES" = true ]; then
        optimize_system_lower="no"
        echo "Auto-yes mode: Skipping aggressive network & kernel optimization (BBR will be enabled separately)"
    else
        while true; do
            echo -e "${YELLOW}${BOLD}>>> Do you want to apply these system optimizations? (y/yes, default: no):${RESET} "
            read optimize_system
            if [ -z "$optimize_system" ]; then
                optimize_system="no"
            fi
            if validate_yes_no "$optimize_system"; then
                break
            else
                print_error "Invalid input. Please enter 'yes', 'y', 'no', or 'n'"
            fi
        done
        optimize_system_lower=$(echo "$optimize_system" | tr '[:upper:]' '[:lower:]')
    fi
    if [ "$optimize_system_lower" = "y" ] || [ "$optimize_system_lower" = "yes" ]; then
        print_info "Applying system optimizations..."
    
    # === 1. System Limits Configuration ===
    echo ""
    print_info "Configuring system resource limits..."
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
    
    # Use drop-in file instead of overwriting limits.conf
    mkdir -p /etc/security/limits.d
    cat > /etc/security/limits.d/99-optimization.conf <<'EOF'
* soft nofile unlimited
* hard nofile unlimited
* soft nproc unlimited
* hard nproc unlimited
root soft nofile unlimited
root hard nofile unlimited
root soft nproc unlimited
root hard nproc unlimited
EOF
    
    # Use drop-in file instead of overwriting system.conf
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-optimization.conf <<'EOF'
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
    print_success "System limits configured (drop-in file created)"
    
    # === 2. Journald Configuration ===
    echo ""
    print_info "Configuring journald log limits..."
    
    # Use drop-in file instead of overwriting journald.conf
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-optimization.conf <<'EOF'
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
    print_success "Journald configured with size limits (drop-in file created)"
    
    # === 3. Entropy and Random Number Generation ===
    echo ""
    print_info "Installing haveged (entropy pool enhancement)..."
    apt install -y haveged
    systemctl enable --now haveged
    print_success "Haveged enabled"
    
    print_info "Installing rng-tools (random number generator optimization)..."
    if [[ -z "$(command -v rngd)" ]]; then
        apt install -y rng-tools
    fi
    if systemctl list-unit-files | grep -q '^rng-tools-debian.service'; then
        systemctl enable --now rng-tools-debian
    else
        systemctl enable --now rngd.service 2>/dev/null || \
            systemctl enable --now rngd 2>/dev/null || \
            systemctl enable --now rng-tools 2>/dev/null || true
    fi
    print_success "rng-tools installed and enabled"
    
    # === 4. Disable KSM and Transparent Huge Pages ===
    echo ""
    print_info "Disabling KSM and transparent huge pages..."
    if [[ ! -z "$(command -v ksmtuned)" ]]; then
        echo 2 > /sys/kernel/mm/ksm/run
        apt purge tuned --autoremove -y || true
        apt purge ksmtuned --autoremove -y || true
        rm -rf /etc/systemd/system/ksmtuned.service
        mv /usr/sbin/ksmtuned /usr/sbin/ksmtuned.bak || true
        touch /usr/sbin/ksmtuned
        echo "# KSMTUNED DISABLED" > /usr/sbin/ksmtuned
        print_success "ksmtuned disabled and removed"
    else
        print_success "ksmtuned not found, skipping"
    fi
    
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
    print_success "KSM and transparent huge pages disabled"
    
    # === 5. Kernel Network Parameters ===
    echo ""
    print_info "Configuring kernel network parameters..."
    cat > /etc/sysctl.d/999-bbr-sysctl.conf <<'EOF'
# === Kernel Basic Config ===
kernel.panic = 1
kernel.task_delayacct = 1

# === Network Core ===
net.core.netdev_max_backlog = 32768
net.core.default_qdisc = fq
net.core.somaxconn = 32768

# === IP Config ===
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.ip_default_ttl = 128
net.ipv4.ip_forward = 1
net.ipv4.ip_local_port_range = 10240 65535

# === TCP Connection Management ===
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_autocorking = 1
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_collapse_max_bytes = 6291456

# === TCP BBR Congestion Control ===
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_ecn = 1

# === TCP Fast Open ===
net.ipv4.tcp_fastopen = 1027
net.ipv4.tcp_fastopen_blackhole_timeout_sec = 10

# === TCP Timeouts ===
net.ipv4.tcp_fin_timeout = 3
net.ipv4.tcp_frto = 1
net.ipv4.tcp_keepalive_intvl = 2
net.ipv4.tcp_keepalive_probes = 2
net.ipv4.tcp_keepalive_time = 120

# === TCP Queue Limits ===
net.ipv4.tcp_max_orphans = 8192
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 4096

# === TCP Optimization Options ===
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_ssthresh_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0

# === TCP Retransmission ===
net.ipv4.tcp_orphan_retries = 4
net.ipv4.tcp_retries1 = 2
net.ipv4.tcp_retries2 = 2
net.ipv4.tcp_rfc1337 = 1

# === TCP/UDP Buffers ===
net.core.rmem_default = 262144
net.core.rmem_max = 536870912
net.ipv4.tcp_rmem = 8192 262144 536870912
net.core.wmem_default = 16384
net.core.wmem_max = 536870912
net.ipv4.tcp_wmem = 4096 16384 536870912
net.ipv4.tcp_moderate_rcvbuf = 1

# === TCP Features ===
net.ipv4.tcp_sack = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_notsent_lowat = 131072

# === Low Latency ===
net.ipv4.tcp_low_latency = 1

# === UDP Config ===
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 4096
net.ipv4.route.flush = 1

# === IPv6 Config ===
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1

# === Netfilter Connection Tracking ===
net.netfilter.nf_conntrack_generic_timeout = 10
net.netfilter.nf_conntrack_gre_timeout = 5
net.netfilter.nf_conntrack_gre_timeout_stream = 30
net.netfilter.nf_conntrack_icmp_timeout = 5
net.netfilter.nf_conntrack_icmpv6_timeout = 5
net.netfilter.nf_conntrack_max = 1048576

# TCP Connection Tracking Timeouts
net.netfilter.nf_conntrack_tcp_timeout_close = 5
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 5
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 5
net.netfilter.nf_conntrack_tcp_timeout_max_retrans = 5
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 5
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 5
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_unacknowledged = 5

# UDP Connection Tracking Timeouts
net.netfilter.nf_conntrack_udp_timeout = 5
net.netfilter.nf_conntrack_udp_timeout_stream = 60

# === Memory Management ===
vm.overcommit_memory = 1
vm.swappiness = 0
EOF

    # Dynamic tcp_mem calculation
    mems=$(free --bytes | grep Mem | awk '{print $2}')
    page=$(getconf PAGESIZE)
    size=$((mems/page))
    echo "net.ipv4.tcp_mem = $((size/100*12)) $((size/100*50)) $((size/100*70))" >> /etc/sysctl.d/999-bbr-sysctl.conf

    sort -n /etc/sysctl.d/999-bbr-sysctl.conf -o /etc/sysctl.d/999-bbr-sysctl.conf
    sysctl --system >/dev/null 2>&1 || true

        print_success "Kernel network parameters configured with aggressive optimizations"
        print_success "All system optimizations applied successfully!"
        
        # Create marker file to prevent re-running
        echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$KERNEL_OPT_MARKER"
        print_info "Kernel optimization marker created: $KERNEL_OPT_MARKER"
    else
        print_info "Skipping aggressive network & kernel optimization"
        print_info "Note: System will use default settings (recommended for most production servers)"
        
        # Check if BBR is enabled when optimization is skipped
        echo ""
        print_banner "BBR Congestion Control Check"
        CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
        
        if [ "$CURRENT_CC" != "bbr" ]; then
            print_warning "BBR congestion control is NOT enabled (current: $CURRENT_CC)"
            echo "BBR (Bottleneck Bandwidth and RTT) is a modern congestion control algorithm"
            echo "that can significantly improve network performance and latency."
            echo ""
            if [ "$AUTO_YES" = true ]; then
                enable_bbr_lower="yes"
                echo "Auto-yes mode: Enabling BBR..."
            else
                while true; do
                    echo -e "${CYAN}${BOLD}>>> Do you want to enable BBR? (y/yes, default: yes):${RESET} "
                    read enable_bbr
                    if [ -z "$enable_bbr" ]; then
                        enable_bbr="yes"
                    fi
                    if validate_yes_no "$enable_bbr"; then
                        break
                    else
                        print_error "Invalid input. Please enter 'yes', 'y', 'no', or 'n'"
                    fi
                done
                enable_bbr_lower=$(echo "$enable_bbr" | tr '[:upper:]' '[:lower:]')
            fi
            
            if [ "$enable_bbr_lower" = "y" ] || [ "$enable_bbr_lower" = "yes" ]; then
                print_info "Enabling BBR congestion control..."
                
                # Create sysctl config for BBR only
                cat > /etc/sysctl.d/99-bbr.conf <<'BBREOF'
# BBR Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
BBREOF
                
                # Apply settings immediately
                sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
                
                # Verify BBR is enabled
                NEW_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
                if [ "$NEW_CC" = "bbr" ]; then
                    print_success "BBR congestion control enabled successfully"
                else
                    print_warning "BBR may require a system reboot to take effect"
                fi
            else
                print_info "Skipping BBR enablement"
            fi
        else
            print_success "BBR congestion control is already enabled"
        fi
    fi
fi

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

print_banner "System Configuration Check"
set +e

# Fetch IP information
echo "Fetching network information..."
IPV4_ADDR=$(timeout 5 curl -s -4 ip.sb 2>/dev/null || echo "N/A")
IPV6_ADDR=$(timeout 5 curl -s -6 ip.sb 2>/dev/null || echo "N/A")
IPINFO=$(timeout 5 curl -s ipinfo.io 2>/dev/null || echo "")

if [ -n "$IPINFO" ]; then
    IP_CITY=$(echo "$IPINFO" | grep -oP '"city":\s*"\K[^"]+' || echo "N/A")
    IP_REGION=$(echo "$IPINFO" | grep -oP '"region":\s*"\K[^"]+' || echo "N/A")
    IP_COUNTRY=$(echo "$IPINFO" | grep -oP '"country":\s*"\K[^"]+' || echo "N/A")
    IP_ORG=$(echo "$IPINFO" | grep -oP '"org":\s*"\K[^"]+' || echo "N/A")
else
    IP_CITY="N/A"
    IP_REGION="N/A"
    IP_COUNTRY="N/A"
    IP_ORG="N/A"
fi

# Display network information
printf "%-22s: %s\n" "IPv4 Address" "$IPV4_ADDR"
if [ "$IPV6_ADDR" != "N/A" ]; then
    printf "%-22s: %s\n" "IPv6 Address" "$IPV6_ADDR"
fi
if [ "$IP_CITY" != "N/A" ] || [ "$IP_COUNTRY" != "N/A" ]; then
    if [ "$IP_CITY" = "$IP_REGION" ] || [ -z "$IP_REGION" ]; then
        printf "%-22s: %s, %s\n" "Location" "$IP_CITY" "$IP_COUNTRY"
    else
        printf "%-22s: %s, %s, %s\n" "Location" "$IP_CITY" "$IP_REGION" "$IP_COUNTRY"
    fi
fi
if [ "$IP_ORG" != "N/A" ]; then
    printf "%-22s: %s\n" "ISP/Organization" "$IP_ORG"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

printf "%-22s: %s\n" "BBR Congestion Control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A')"
printf "%-22s: %s\n" "Queue Discipline" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo 'N/A')"
printf "%-22s: %s\n" "Open File Limit" "$(ulimit -n 2>/dev/null || echo 'N/A')"
printf "%-22s: %s\n" "Process Limit" "$(ulimit -u 2>/dev/null || echo 'N/A')"
printf "%-22s: %s\n" "Time Sync Status" "$(chronyc tracking 2>/dev/null | grep 'Leap status' | cut -d':' -f2 | xargs 2>/dev/null || echo 'Checking...')"
printf "%-22s: %s\n" "NTP Server" "$(grep '^server' /etc/chrony/chrony.conf 2>/dev/null | head -n 1 | awk '{print $2}' || echo 'Unknown')"
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
echo "Installed Software:"
if command -v hx &>/dev/null; then
    printf "  %-20s: %s\n" "Helix Editor" "v$(hx --version 2>/dev/null | grep -oP 'helix \K[0-9.]+' | head -n1 || echo 'installed')"
fi
if command -v eza &>/dev/null; then
    printf "  %-20s: %s\n" "Eza" "$(eza --version 2>/dev/null | grep -oP '^v[0-9.]+' || echo 'installed')"
fi
if command -v speedtest &>/dev/null; then
    printf "  %-20s: %s\n" "Speedtest" "v$(speedtest --version 2>/dev/null | grep -oP 'Ookla \K[0-9.]+' | head -n1 || echo 'installed')"
fi
if command -v docker &>/dev/null; then
    printf "  %-20s: %s\n" "Docker" "v$(docker --version 2>/dev/null | grep -oP 'Docker version \K[0-9.]+' || echo 'installed')"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Security Status:"
ssh_status=$(systemctl is-active ssh 2>/dev/null || echo 'inactive')
fail2ban_status=$(systemctl is-active fail2ban 2>/dev/null || echo 'inactive')
unattended_upgrades_timer=$(systemctl is-active apt-daily-upgrade.timer 2>/dev/null || echo 'inactive')
printf "  %-20s: %s\n" "SSH Service" "$ssh_status"
printf "  %-20s: %s\n" "Fail2ban Service" "$fail2ban_status"
printf "  %-20s: %s\n" "Auto-updates Timer" "$unattended_upgrades_timer"

# Check unattended-upgrades config
if command -v unattended-upgrade &>/dev/null; then
    printf "  %-20s: %s\n" "Unattended-upgrades" "installed"
    
    update_sources=""
    if [ -f /etc/apt/apt.conf.d/52unattended-upgrades-local ]; then
        config_file="/etc/apt/apt.conf.d/52unattended-upgrades-local"
    elif [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
        config_file="/etc/apt/apt.conf.d/50unattended-upgrades"
    else
        config_file=""
    fi
    
    if [ -n "$config_file" ]; then
        enabled_list=""
        disabled_list=""

        # Check Security
        # Match line starting with whitespace and quote, followed by origin definition
        # We don't include the closing quote in regex to handle optional labels like ",label=Debian-Security"
        if grep -qE '^\s*"origin=Debian,codename=\$\{distro_codename\}-security' "$config_file" 2>/dev/null; then
            enabled_list="Security"
        else
            disabled_list="Security"
        fi
        
        # Check Stable-updates
        if grep -qE '^\s*"origin=Debian,codename=\$\{distro_codename\}-updates' "$config_file" 2>/dev/null; then
            if [ -n "$enabled_list" ]; then enabled_list="$enabled_list, Stable-updates"; else enabled_list="Stable-updates"; fi
        else
            if [ -n "$disabled_list" ]; then disabled_list="$disabled_list, Stable-updates"; else disabled_list="Stable-updates"; fi
        fi
        
        # Check Proposed-updates
        if grep -qE '^\s*"origin=Debian,codename=\$\{distro_codename\}-proposed-updates' "$config_file" 2>/dev/null; then
            if [ -n "$enabled_list" ]; then enabled_list="$enabled_list, Proposed-updates"; else enabled_list="Proposed-updates"; fi
        else
            if [ -n "$disabled_list" ]; then disabled_list="$disabled_list, Proposed-updates"; else disabled_list="Proposed-updates"; fi
        fi
        
        if [ -n "$enabled_list" ]; then
            printf "    └─ Enabled : %s\n" "$enabled_list"
        else
            printf "    └─ Enabled : None\n"
        fi
        
        if [ -n "$disabled_list" ]; then
            printf "    └─ Disabled: %s\n" "$disabled_list"
        fi
    fi
else
    printf "  %-20s: %s\n" "Unattended-upgrades" "not installed"
fi
set -e

print_banner "Optimization complete!"
echo ""
if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
    print_info "Original configuration files backed up to: $BACKUP_DIR"
    echo "  Backed up files: chrony.conf, limits.conf, system.conf, journald.conf,"
    echo "                   common-session, *nproc.conf (if existed)"
else
    print_info "No configuration files were modified"
fi
echo ""

# Check if network & kernel optimization was skipped
if [ -f "$KERNEL_OPT_MARKER" ] && [ "$optimize_system_lower" = "no" ]; then
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${RED}${BOLD}⚠️  NETWORK & KERNEL OPTIMIZATION WAS SKIPPED${RESET}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${YELLOW}Reason: Network & kernel optimization marker already exists${RESET}"
    echo -e "${YELLOW}Applied on: ${BOLD}$(cat "$KERNEL_OPT_MARKER")${RESET}"
    echo ""
fi

echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$MARKER_FILE"

print_banner "⚠️  REBOOT REQUIRED ⚠️"
print_warning "It is STRONGLY RECOMMENDED to reboot the system for all settings to take effect."
print_warning "This includes kernel parameters, system limits, and various optimizations."
echo ""
if [ "$AUTO_YES" = true ]; then
    print_info "Auto-yes mode: Skipping automatic reboot for safety."
    print_info "Please manually reboot when ready with:"
    echo -e "   ${BOLD}reboot${RESET}"
else
    while true; do
        echo -e "${MAGENTA}${BOLD}>>> Would you like to reboot now? (y/yes, default: no):${RESET} "
        read reboot_now
        if [ -z "$reboot_now" ]; then
            reboot_now="no"
        fi
        if validate_yes_no "$reboot_now"; then
            break
        else
            print_error "Invalid input. Please enter 'yes', 'y', 'no', or 'n'"
        fi
    done
    reboot_now_lower=$(echo "$reboot_now" | tr '[:upper:]' '[:lower:]')
    if [ "$reboot_now_lower" = "y" ] || [ "$reboot_now_lower" = "yes" ]; then
        echo ""
        print_info "Rebooting system in 3 seconds... Press Ctrl+C to cancel"
        sleep 3
        reboot
    else
        echo ""
        print_info "Please remember to reboot manually later with:"
        echo -e "   ${BOLD}reboot${RESET}"
        echo ""
    fi
fi
