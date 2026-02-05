#!/bin/bash

# Global Variables
REALM_BIN="/usr/local/bin/realm"
REALM_CONF_DIR="/etc/realm"
REALM_CONF="${REALM_CONF_DIR}/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# Check Root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root!${PLAIN}"
        exit 1
    fi
}

# Check OS
check_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "$ID" != "debian" && "$ID" != "ubuntu" && "$ID_LIKE" != *"debian"* ]]; then
            echo -e "${RED}Error: This script only supports Debian and Ubuntu!${PLAIN}"
            exit 1
        fi
    else
        echo -e "${RED}Error: OS detection failed. This script only supports Debian and Ubuntu!${PLAIN}"
        exit 1
    fi
}

# Install Dependencies
install_deps() {
    echo -e "${GREEN}Installing dependencies...${PLAIN}"
    apt-get update
    apt-get install -y wget tar systemd jq
}

# Get Latest Version
get_latest_version() {
    latest_version=$(wget -qO- "https://github.com/zhboner/realm/releases" | grep -o 'href="/zhboner/realm/releases/tag/v[0-9]*\.[0-9]*\.[0-9]*"' | head -n 1 | awk -F'/' '{print $6}' | tr -d '"')
    if [[ -z "$latest_version" ]]; then
        echo -e "${RED}Error: Failed to get latest version from GitHub.${PLAIN}"
        exit 1
    fi
    echo "$latest_version"
}

# Install Realm
install_realm() {
    check_root
    check_os
    install_deps

    local version
    if [[ -n "$LATEST_VERSION" ]]; then
        version="$LATEST_VERSION"
    else
        version=$(get_latest_version)
    fi
    echo -e "${GREEN}Latest version: ${version}${PLAIN}"

    echo -e "${GREEN}Downloading Realm...${PLAIN}"
    wget -O realm.tar.gz "https://github.com/zhboner/realm/releases/download/${version}/realm-x86_64-unknown-linux-gnu.tar.gz"

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Error: Download failed.${PLAIN}"
        rm -f realm.tar.gz
        exit 1
    fi

    echo -e "${GREEN}Extracting Realm...${PLAIN}"
    tar -zxvf realm.tar.gz
    chmod +x realm
    mv realm "$REALM_BIN"
    rm -f realm.tar.gz

    echo -e "${GREEN}Realm installed successfully to ${REALM_BIN}${PLAIN}"
    
    configure_service
    init_config
}

# Initial Config
init_config() {
    if [[ ! -d "$REALM_CONF_DIR" ]]; then
        mkdir -p "$REALM_CONF_DIR"
    fi
    
    if [[ ! -f "$REALM_CONF" ]]; then
        cat > "$REALM_CONF" <<EOF
[log]
level = "warn"
output = "realm.log"

[network]
no_tcp = false
use_udp = true
zero_copy = true
EOF
        echo -e "${GREEN}Config created at ${REALM_CONF}${PLAIN}"
    fi
}

# Configure Service
configure_service() {
    echo -e "${GREEN}Configuring systemd service...${PLAIN}"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
WorkingDirectory=${REALM_CONF_DIR}
ExecStart=${REALM_BIN} -c ${REALM_CONF}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm
    echo -e "${GREEN}Service enabled and started.${PLAIN}"
}

# Update Realm
update_realm() {
    check_root
    check_os
    local current_version
    if [[ -f "$REALM_BIN" ]]; then
        current_version=$($REALM_BIN --version | awk '{print $2}')
    else
        current_version="None"
    fi
    
    local latest_version
    if [[ -n "$LATEST_VERSION" ]]; then
        latest_version="$LATEST_VERSION"
    else
        latest_version=$(get_latest_version)
    fi
    
    echo -e "${GREEN}Current version: ${current_version}${PLAIN}"
    echo -e "${GREEN}Latest version: ${latest_version}${PLAIN}"
    
    
    # Normalize versions (remove 'v' prefix)
    local current_v_norm="${current_version#v}"
    local latest_v_norm="${latest_version#v}"

    if [[ "$current_v_norm" == "$latest_v_norm" ]]; then
        echo -e "${GREEN}Realm is already up to date.${PLAIN}"
    else
        echo -e "${YELLOW}New version available. Updating...${PLAIN}"
        install_realm
    fi
}

# Uninstall Realm
uninstall_realm() {
    check_root
    echo -e "${YELLOW}Uninstalling Realm...${PLAIN}"
    systemctl stop realm
    systemctl disable realm
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    
    rm -f "$REALM_BIN"
    # Optional: remove config dir? User might want to keep it.
    # checking if user wants to remove config
    read -p "Do you want to remove configuration files? [y/N] " remove_conf
    if [[ "$remove_conf" =~ ^[Yy]$ ]]; then
        rm -rf "$REALM_CONF_DIR"
        echo -e "${GREEN}Configuration removed.${PLAIN}"
    fi

    echo -e "${GREEN}Realm uninstalled.${PLAIN}"
}

# Service Management Wrappers
start_service() { systemctl start realm; echo -e "${GREEN}Realm started.${PLAIN}"; }
stop_service() { systemctl stop realm; echo -e "${GREEN}Realm stopped.${PLAIN}"; }
restart_service() { systemctl restart realm; echo -e "${GREEN}Realm restarted.${PLAIN}"; }
show_status() { systemctl status realm; }

# Configuration Management
add_rule() {
    echo -e "${GREEN}Adding a new forwarding rule...${PLAIN}"
    echo -e "Format: ${YELLOW}LocalPort:RemoteIP:RemotePort${PLAIN} (e.g., 5000:1.2.3.4:443)"
    echo -e "Or press Enter to input step by step."
    read -p "Enter Rule or Local Port: " input_rule

    local local_port remote_addr remote_port

    if [[ "$input_rule" =~ ^([0-9]+):(.+):([0-9]+)$ ]]; then
        local_port="${BASH_REMATCH[1]}"
        remote_addr="${BASH_REMATCH[2]}"
        remote_port="${BASH_REMATCH[3]}"
    else
        local_port="$input_rule"
        if [[ -z "$local_port" ]]; then
             if [[ -z "$input_rule" ]]; then
                 return
             fi
             read -p "Enter Local Binding Port (e.g., 5000): " local_port
        fi
        read -p "Enter Remote IP/Domain (e.g., 1.2.3.4 or example.com): " remote_addr
        read -p "Enter Remote Port (e.g., 443): " remote_port
    fi

    if [[ -z "$local_port" || -z "$remote_addr" || -z "$remote_port" ]]; then
        echo -e "${RED}Error: All fields are required.${PLAIN}"
        return 1
    fi

    cat >> "$REALM_CONF" <<EOF

[[endpoints]]
listen = "0.0.0.0:$local_port"
remote = "$remote_addr:$remote_port"
EOF

    echo -e "${GREEN}Rule added: 0.0.0.0:$local_port -> $remote_addr:$remote_port${PLAIN}"
    restart_service
    add_rule
}

show_config() {
    echo -e "${GREEN}Current Configuration File Content:${PLAIN}"
    echo -e "${YELLOW}------------------------------------------------${PLAIN}"
    cat "$REALM_CONF"
    echo -e "${YELLOW}------------------------------------------------${PLAIN}"
}

get_ip_country() {
    local ip=$1
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local country=$(wget -qO- "http://ip-api.com/json/$ip?fields=country" | jq -r .country)
        if [[ -n "$country" && "$country" != "null" ]]; then
            echo "[$country]"
        else
            echo "[Unknown]"
        fi
    else
        echo "[Domain]"
    fi
}

list_rules() {
    echo -e "${GREEN}Current Forwarding Rules:${PLAIN}"
    if [[ ! -f "$REALM_CONF" ]]; then
        echo -e "${RED}Config file not found!${PLAIN}"
        return
    fi
    
    local i=1
    local listening remote_addr remote_port
    
    while read -r line; do
        if [[ "$line" == "LISTEN"* ]]; then
            listening="${line#LISTEN }"
            # Clean up 0.0.0.0 for better display
            listening="${listening#0.0.0.0:}"
        elif [[ "$line" == "REMOTE"* ]]; then
             remote_val="${line#REMOTE }"
             remote_addr="${remote_val%:*}"
             remote_port="${remote_val##*:}"
             
             country=$(get_ip_country "$remote_addr")
             
             echo -e "${GREEN}$i.${PLAIN} $listening -> $remote_addr:$remote_port ${YELLOW}$country${PLAIN}"
             ((i++))
        fi
    done < <(awk -F'=' '
        /listen/ { gsub(/[ "]/, "", $2); print "LISTEN " $2 }
        /remote/ { gsub(/[ "]/, "", $2); print "REMOTE " $2 }
    ' "$REALM_CONF")
}

delete_rule() {
    list_rules
    echo ""
    read -p "Enter the number of the rule to delete (0 to cancel): " rule_num

    if [[ -z "$rule_num" || ! "$rule_num" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid input.${PLAIN}"
        return
    fi

    if [[ "$rule_num" -eq 0 ]]; then
        echo -e "${GREEN}Cancelled.${PLAIN}"
        return
    fi
    
    # Check if rule exists
    local total_rules
    total_rules=$(grep -c "\[\[endpoints\]\]" "$REALM_CONF")
    
    if [[ "$rule_num" -lt 1 || "$rule_num" -gt "$total_rules" ]]; then
        echo -e "${RED}Rule number out of range.${PLAIN}"
        return
    fi


    # Create a temp file
    local tmp_conf=$(mktemp)
    
    # Use awk to write back all rules EXCEPT the selected one
    awk -v target="$rule_num" '
    BEGIN {count=0; inside=0}
    /\[\[endpoints\]\]/ {
        count++;
        if (count == target) {inside=1} else {inside=0; print}
        next
    }
    {
        if (inside == 0) print
    }
    ' "$REALM_CONF" > "$tmp_conf"

    # Move temp file back
    mv "$tmp_conf" "$REALM_CONF"
    
    echo -e "${GREEN}Rule $rule_num deleted.${PLAIN}"
    restart_service
}

# Main Menu
show_menu() {
    clear
    local current_version
    if [[ -f "$REALM_BIN" ]]; then
        current_version=$($REALM_BIN --version | awk '{print $2}')
    else
        current_version="${RED}Not Installed${PLAIN}"
    fi

    local latest_version="${LATEST_VERSION}"
    if [[ -z "$latest_version" ]]; then
        latest_version="Checking..."
    fi

    local status
    if systemctl is-active --quiet realm; then
        status="${GREEN}Running${PLAIN}"
    else
        status="${RED}Stopped${PLAIN}"
    fi

    local rule_count=0
    if [[ -f "$REALM_CONF" ]]; then
        rule_count=$(grep -c "\[\[endpoints\]\]" "$REALM_CONF")
    fi

    echo -e "Realm Manager Script"
    echo -e "--------------------------------"
    echo -e "Realm Status: $status"
    echo -e "Version: $current_version (Latest: ${GREEN}$latest_version${PLAIN})"
    echo -e "Rules: ${GREEN}$rule_count${PLAIN}"
    echo -e "--------------------------------"
    echo -e "${GREEN}1.${PLAIN} Install Realm"
    echo -e "${GREEN}2.${PLAIN} Update Realm"
    echo -e "${GREEN}3.${PLAIN} Uninstall Realm"
    echo -e "--------------------------------"
    echo -e "${GREEN}4.${PLAIN} Start/Restart Service"
    echo -e "${GREEN}5.${PLAIN} Stop Service"
    echo -e "--------------------------------"
    echo -e "${GREEN}6.${PLAIN} Add Forwarding Rule"
    echo -e "${GREEN}7.${PLAIN} Delete Forwarding Rule"
    echo -e "${GREEN}8.${PLAIN} Show Forwarding Rules"
    echo -e "--------------------------------"
    echo -e "${GREEN}9.${PLAIN} Show Raw Config File"
    echo -e "--------------------------------"
    echo -e "${GREEN}0.${PLAIN} Exit"
    echo -e ""
    read -p "Please enter your choice [0-9]: " choice

    case "$choice" in
        1) install_realm ;;
        2) update_realm ;;
        3) uninstall_realm ;;
        4) 
            if systemctl is-active --quiet realm; then
                restart_service
            else
                start_service
            fi
            ;;
        5) stop_service ;;
        6) add_rule ;;
        7) delete_rule ;;
        8) list_rules ;;
        9) show_config ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid choice.${PLAIN}" ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..."
    show_menu
}

# Entry point
if [[ $# -gt 0 ]]; then
    case "$1" in
        install) install_realm ;;
        update) update_realm ;;
        uninstall) uninstall_realm ;;
        start) start_service ;;
        stop) stop_service ;;
        restart) restart_service ;;
        status) show_status ;;
        add_rule) add_rule ;;
        list_rules) list_rules ;;
        *) echo "Usage: $0 [install|update|uninstall|start|stop|restart|status|add_rule|list_rules]"; exit 1 ;;
    esac
else
    LATEST_VERSION=$(get_latest_version)
    show_menu
fi

