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

# 检查是否为 root 用户
if [ "$(id -u)" != "0" ]; then
    echo "❌ Error: You must be root to run this script"
    exit 1
fi

# 检查是否为 Debian 系统
if [ ! -f /etc/debian_version ]; then
    echo "❌ Error: This script is designed for Debian systems only"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# 检查是否为 Debian 13
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

    if [ -z "$VERSION_ID_MAJOR" ]; then
        echo "❌ Error: Unable to determine Debian major version."
        echo "   This script only supports Debian 13 (trixie)."
        exit 1
    fi

    if [ "$VERSION_ID_MAJOR" != "13" ]; then
        echo "❌ Error: This script only supports Debian 13 (detected: ${PRETTY_NAME:-Debian $VERSION_ID_MAJOR})"
        echo "   This script modernizes Debian 13 (trixie) sources"
        exit 1
    fi

    if [ -n "$CODENAME" ] && [ "$CODENAME" != "trixie" ]; then
        echo "❌ Error: This script only supports the trixie release (detected codename: $CODENAME)"
        echo "   This script modernizes Debian 13 (trixie) sources"
        exit 1
    fi

    DISPLAY_VERSION="${VERSION_ID_MAJOR:-unknown}"
    DISPLAY_CODENAME="${CODENAME:-unknown}"
    echo "✓ Running on Debian ${DISPLAY_VERSION} (${DISPLAY_CODENAME})"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Debian 13 Post-Upgrade Cleanup & Modernization"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "This script will:"
echo "  1. Clean up old packages and cache"
echo "  2. Modernize APT sources to deb822 format"
echo "  3. Fix backports keyring if needed"
echo ""

# 步骤 1: 清理旧的包和缓存
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1/3: Cleaning up old packages and cache..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
apt-get autoremove -y
apt-get clean
echo "✓ Cleanup complete"

# 步骤 2: 现代化 APT 源 (转换为 deb822 格式)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2/3: Modernizing APT sources to deb822 format..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "This will create:"
echo "  - /etc/apt/sources.list.d/debian.sources"
echo "  - /etc/apt/sources.list.d/debian-backports.sources"
echo ""

# 执行现代化
apt modernize-sources -y
echo "✓ Sources modernized to deb822 format"

# 步骤 3: 修复 trixie-backports 的签名密钥
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3/3: Fixing backports Signed-By field..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

BACKPORTS_FILE="/etc/apt/sources.list.d/debian-backports.sources"

if [ ! -f "$BACKPORTS_FILE" ]; then
    echo "❌ Error: $BACKPORTS_FILE not found"
    echo "   Please run 'apt modernize-sources' first"
    exit 1
fi

# 检查 Signed-By 字段是否为空
if grep -q "^Signed-By:\s*$" "$BACKPORTS_FILE"; then
    echo "⚠️  Backports Signed-By field is empty, fixing..."
    
    # 替换空的 Signed-By 行为正确的值
    sed -i 's|^Signed-By:\s*$|Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg|' "$BACKPORTS_FILE"
    
    echo "✓ Fixed Signed-By in debian-backports.sources"
elif ! grep -q "^Signed-By:" "$BACKPORTS_FILE"; then
    echo "⚠️  Backports file missing Signed-By field, adding..."
    
    # 如果完全没有 Signed-By 字段，则添加
    sed -i '1i Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' "$BACKPORTS_FILE"
    
    echo "✓ Added Signed-By to debian-backports.sources"
else
    echo "✓ Signed-By field already configured correctly"
fi

# 更新包列表以验证配置
echo ""
echo "Updating package lists to verify configuration..."
apt-get update

# 完成
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Post-Upgrade Modernization Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Your Debian 13 system has been modernized with:"
echo "  ✓ Cleaned up old packages and cache"
echo "  ✓ Modern deb822 format sources"
echo "  ✓ Proper keyring configuration"
echo ""
echo "You can now use the new APT source files in:"
echo "  - /etc/apt/sources.list.d/debian.sources"
echo "  - /etc/apt/sources.list.d/debian-backports.sources"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Next Step: System Optimization (Optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Would you like to optimize your Debian 13 system now?"
echo ""
echo "This will install and configure:"
echo "  - Essential tools (helix, eza, speedtest, etc.)"
echo "  - BBR network optimization"
echo "  - Security hardening (fail2ban, chrony)"
echo "  - System limits and performance tuning"
echo ""
read -p "Run system optimization script now? (y/yes): " run_optimization

# Convert to lowercase for comparison
run_optimization_lower=$(echo "$run_optimization" | tr '[:upper:]' '[:lower:]')

if [ "$run_optimization_lower" = "y" ] || [ "$run_optimization_lower" = "yes" ]; then
    echo ""
    echo "Downloading and running optimization script..."
    bash <(curl -fsSL https://raw.githubusercontent.com/aoaim/luanqi_bazao/main/linux_script/init_linux.sh)
else
    echo ""
    echo "You can run the optimization script later with:"
    echo "   bash <(curl -fsSL https://raw.githubusercontent.com/aoaim/luanqi_bazao/main/linux_script/init_linux.sh)"
    echo ""
fi
