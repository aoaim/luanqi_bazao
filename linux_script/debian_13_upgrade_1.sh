#!/bin/bash

# 严格模式：任何命令失败都会中断脚本
set -e  # 命令返回非零退出码时退出
set -u  # 使用未定义变量时退出
set -o pipefail  # 管道中任何命令失败都会导致整个管道失败

# 错误处理函数
error_exit() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "❌ Error occurred at line $1"
    echo "❌ Upgrade failed. Please check the error message above."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
}

# 捕获错误并显示行号
trap 'error_exit $LINENO' ERR

# 检查是否为 root 用户
if [ "$(id -u)" != "0" ]; then
    echo "❌ Error: You must be root to run this script"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
APT_FORCE_OPTIONS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# 检查是否为 Debian 系统
if [ ! -f /etc/debian_version ]; then
    echo "❌ Error: This script is designed for Debian systems only"
    exit 1
fi

# 检查是否为 Debian 12
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "${ID,,}" != "debian" ]; then
        echo "❌ Error: This script only supports Debian (detected: ${PRETTY_NAME:-unknown})"
        exit 1
    fi

    CODENAME="${VERSION_CODENAME:-}"
    VERSION_ID_MAJOR=""
    if [ -n "${VERSION_ID:-}" ]; then
        VERSION_ID_MAJOR="${VERSION_ID%%[!0-9]*}"
        VERSION_ID_MAJOR="${VERSION_ID_MAJOR%%/*}"
    fi
    if [ -z "$VERSION_ID_MAJOR" ]; then
        if [ -f /etc/debian_version ]; then
            VERSION_ID_MAJOR="$(cut -d. -f1 /etc/debian_version 2>/dev/null | cut -d/ -f1)"
        fi
    fi

    if [ "$VERSION_ID_MAJOR" != "12" ] && [ "$CODENAME" != "bookworm" ]; then
        echo "❌ Error: This script only supports Debian 12/bookworm (detected: ${PRETTY_NAME:-Debian $VERSION_ID_MAJOR})"
        echo "   This script upgrades Debian 12 (bookworm) to Debian 13 (trixie)"
        exit 1
    fi

    DISPLAY_VERSION="${VERSION_ID_MAJOR:-unknown}"
    DISPLAY_CODENAME="${CODENAME:-unknown}"
    echo "✓ Running on Debian ${DISPLAY_VERSION} (${DISPLAY_CODENAME})"
fi

# 确认升级
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚠️  WARNING: This will upgrade Debian 12 to Debian 13"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "This operation will:"
echo "  1. Clean package cache"
echo "  2. Upgrade all packages to latest Debian 12 versions"
echo "  3. Change sources from bookworm to trixie"
echo "  4. Upgrade to Debian 13 (trixie)"
echo "  5. Remove obsolete packages after the upgrade"
echo ""
read -p "Do you want to continue? (y/yes): " confirm

# Convert to lowercase for comparison
confirm_lower=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')

if [ "$confirm_lower" != "y" ] && [ "$confirm_lower" != "yes" ]; then
    echo "Upgrade cancelled."
    exit 0
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Starting Debian 12 to Debian 13 Upgrade"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 步骤 1: 清理和删除不需要的包
echo ""
echo "Step 1/5: Cleaning package cache..."
apt-get clean

# 步骤 2: 更新并升级当前系统 (Debian 12)
echo ""
echo "Step 2/5: Updating and upgrading current system (Debian 12)..."
apt-get update
apt-get "${APT_FORCE_OPTIONS[@]}" dist-upgrade -y

# 步骤 3: 修改 sources.list (bookworm -> trixie)
echo ""
echo "Step 3/5: Changing sources from bookworm to trixie..."

# 备份原始 sources.list
if [ -f /etc/apt/sources.list ]; then
    cp /etc/apt/sources.list /etc/apt/sources.list.backup-$(date +%Y%m%d-%H%M%S)
    echo "✓ Backed up /etc/apt/sources.list"
fi

replace_codename() {
    local target_file="$1"
    if [ ! -f "$target_file" ]; then
        return
    fi
    if grep -q 'bookworm' "$target_file"; then
        sed -i -E 's/\<bookworm\>/trixie/g' "$target_file"
        if grep -q 'bookworm' "$target_file"; then
            echo "⚠️  Warning: Some bookworm entries remain in $target_file. Please review manually."
        else
            echo "✓ Updated $target_file"
        fi
    else
        echo "⚠️  Warning: No bookworm entries found in $target_file. Please review manually."
    fi
}

replace_codename "/etc/apt/sources.list"

# 替换 sources.list.d 目录下的所有文件
if [ -d /etc/apt/sources.list.d ]; then
    while IFS= read -r -d '' list_file; do
        replace_codename "$list_file"
    done < <(find /etc/apt/sources.list.d -type f -print0)
fi

# 步骤 4: 更新并升级到 Debian 13
echo ""
echo "Step 4/5: Upgrading to Debian 13 (trixie)..."
apt-get update
apt-get "${APT_FORCE_OPTIONS[@]}" dist-upgrade -y

echo ""
echo "Step 5/5: Removing obsolete packages..."
apt-get autoremove -y

# 完成
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Upgrade Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "System has been upgraded from Debian 12 to Debian 13"
echo ""
echo "⚠️  IMPORTANT: Next Steps"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. Reboot your system:"
echo "   reboot"
echo ""
echo "2. After reboot, run the post-upgrade script to modernize APT sources:"
echo "   bash <(curl -fsSL https://raw.githubusercontent.com/aoaim/luanqi_bazao/main/linux_script/debian_13_upgrade_2.sh)"
echo ""
echo "   This will:"
echo "   - Clean up old packages"
echo "   - Modernize APT sources to deb822 format"
echo "   - Fix backports Signed-By field"
echo ""
