#!/usr/bin/env bash
# -*- coding: utf-8 -*-

# =========================
# 系统检查
# =========================
if [ "$(uname)" != "Linux" ]; then
    echo "错误: 本脚本仅允许在 Linux 系统上执行。"
    exit 1
fi

# 检查是否为 Debian/Ubuntu 系统
if [ ! -f /etc/os-release ]; then
    echo "错误: 无法识别系统类型。"
    exit 1
fi

source /etc/os-release
if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
    echo "错误: 本脚本仅支持 Debian 和 Ubuntu 系统。"
    echo "当前系统: $PRETTY_NAME"
    exit 1
fi

# 检查是否为 root 或有 sudo 权限
if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    echo "错误: 本脚本需要 root 权限或 sudo 权限。"
    exit 1
fi

# =========================
# 配置 & 全局变量
# =========================
TMP_DIR="./tmp_bench_$(date +%s)"

# 清理列表 (记录新安装的依赖，以便脚本结束时清理)
CLEANUP_PKGS=()

# 运行模式标志
RUN_CPU=true
RUN_DISK=true
RUN_NET_INFO=true
RUN_IPERF=true
RUN_TRACE=true
RUN_IP_QUALITY=true
RUN_STREAM=true
RUN_PUBLIC=false
SKIP_V4=false
SKIP_V6=false

# 报告名称前缀 (根据参数动态设置)
REPORT_PREFIX="report"

# 参数解析
for arg in "$@"; do
    case $arg in
        --network|-n)
            RUN_CPU=false
            RUN_DISK=false
            RUN_NET_INFO=true
            RUN_IPERF=true
            RUN_TRACE=true
            RUN_IP_QUALITY=true
            RUN_STREAM=true
            REPORT_PREFIX="network"
            shift
            ;;
        --hardware|-h)
            RUN_CPU=true
            RUN_DISK=true
            RUN_NET_INFO=false
            RUN_IPERF=false
            RUN_TRACE=false
            RUN_IP_QUALITY=false
            RUN_STREAM=false
            REPORT_PREFIX="hardware"
            shift
            ;;
        --nexttrace|-t)
            RUN_CPU=false
            RUN_DISK=false
            RUN_NET_INFO=true
            RUN_IPERF=false
            RUN_TRACE=true
            RUN_IP_QUALITY=false
            RUN_STREAM=false
            REPORT_PREFIX="nexttrace"
            shift
            ;;
        --ip-quality|-i)
            RUN_CPU=false
            RUN_DISK=false
            RUN_NET_INFO=true
            RUN_IPERF=false
            RUN_TRACE=false
            RUN_IP_QUALITY=true
            RUN_STREAM=false
            REPORT_PREFIX="ipquality"
            shift
            ;;
        --stream|-s)
            RUN_CPU=false
            RUN_DISK=false
            RUN_NET_INFO=true
            RUN_IPERF=false
            RUN_TRACE=false
            RUN_IP_QUALITY=false
            RUN_STREAM=true
            REPORT_PREFIX="stream"
            shift
            ;;
        --public|-p)
            RUN_CPU=false
            RUN_DISK=false
            RUN_NET_INFO=true
            RUN_IPERF=false
            RUN_TRACE=false
            RUN_IP_QUALITY=false
            RUN_STREAM=false
            RUN_PUBLIC=true
            REPORT_PREFIX="public"
            shift
            ;;
        -4)
            SKIP_V6=true
            shift
            ;;
        -6)
            SKIP_V4=true
            shift
            ;;
    esac
done

# 生成报告文件名 (参数解析后)
REPORT_FILE="bench_${REPORT_PREFIX}_$(date +%Y%m%d_%H%M%S).md"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
SKYBLUE='\033[0;36m'
NC='\033[0m'

# 测试完成标志
TEST_COMPLETE=false

# 信号捕捉 - 清理临时文件和依赖
cleanup() {
    # 1. 删除临时文件
    rm -rf "$TMP_DIR" 2>/dev/null || true
    
    # 2. 移除脚本安装的依赖 (只清理新安装的)
    if [ "${#CLEANUP_PKGS[@]}" -gt 0 ] 2>/dev/null; then
        echo -e "\n[$(date +%H:%M:%S)] 正在清理新安装的依赖 (${CLEANUP_PKGS[*]}) ..."
        apt-get remove -y "${CLEANUP_PKGS[@]}" >/dev/null 2>&1 || true
        apt-get autoremove -y >/dev/null 2>&1 || true
        echo -e "[清理] 完成"
    fi
}

# 中断处理 - 询问是否保留结果
interrupt_handler() {
    echo ""
    echo -e "${YELLOW}[中断] 检测到 Ctrl+C，测试未完成${NC}"
    
    # 检查报告文件是否存在
    if [ -f "$REPORT_FILE" ]; then
        echo -e "${YELLOW}是否保留已生成的测试结果？${NC}"
        echo -n "输入 y 保留，直接回车删除 (默认: 删除): "
        read -r keep_result </dev/tty 2>/dev/null || keep_result=""
        
        if [ "$keep_result" = "y" ] || [ "$keep_result" = "Y" ] || [ "$keep_result" = "yes" ]; then
            echo -e "${GREEN}[保留] 测试结果已保存到: $REPORT_FILE${NC}"
        else
            rm -f "$REPORT_FILE" 2>/dev/null || true
            echo -e "${YELLOW}[删除] 测试结果已删除${NC}"
        fi
    fi
    
    cleanup
    echo -e "\n[退出] 脚本已终止"
    exit 1
}

trap interrupt_handler INT TERM
trap cleanup EXIT

# =========================
# 工具函数
# =========================
get_time() {
    date "+%H:%M:%S"
}

log() {
    echo -e "[$(get_time)] $1"
}

info() {
    echo -e "[$(get_time)] ${GREEN}$1${NC}"
}

warn() {
    echo -e "[$(get_time)] ${YELLOW}$1${NC}"
}

fail() {
    echo -e "[$(get_time)] ${RED}$1${NC}"
}

calc() {
    awk "BEGIN {printf \"%.2f\", $1}"
}

check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# =========================
# 依赖管理
# =========================
ensure_dependencies() {
    log "正在检查/安装依赖..."
    
    local target_pkgs="curl jq"
    
    # 根据 Flag 添加依赖
    if [ "$RUN_CPU" = "true" ] || [ "$RUN_DISK" = "true" ]; then
        target_pkgs="$target_pkgs sysbench fio"
    fi
    
    if [ "$RUN_IPERF" = "true" ]; then
        target_pkgs="$target_pkgs iperf3"
    fi
    
    local missing_pkgs=""

    # 1. 检查缺失的包
    for pkg in $target_pkgs; do
        if ! check_cmd "$pkg"; then
            missing_pkgs="$missing_pkgs $pkg"
        fi
    done
    
    # 2. 安装缺失的包
    if [ -n "$missing_pkgs" ]; then
        info "安装缺失依赖:$missing_pkgs"
        
        export DEBIAN_FRONTEND=noninteractive
        
        # 更新软件源
        if ! apt-get update -y -q >/dev/null 2>&1; then
            fail "软件源更新失败，请检查网络连接。"
            exit 1
        fi
        
        # 安装依赖包
        if apt-get install -y -q $missing_pkgs >/dev/null 2>&1; then
            # 记录安装的包以便清理
            for p in $missing_pkgs; do CLEANUP_PKGS+=("$p"); done
        else
            fail "依赖安装失败，请检查网络或软件源配置。"
            fail "尝试手动安装: sudo apt-get install $missing_pkgs"
            exit 1
        fi
    fi

    # 3. 二次验证
    local verify_fail=false
    for cmd in curl jq; do
        if ! check_cmd "$cmd"; then
            fail "关键依赖 $cmd 仍未找到，脚本无法继续。"
            verify_fail=true
        fi
    done
    [ "$verify_fail" = "true" ] && exit 1
    
    # 4. Ephemeral Binaries (NextTrace, yt-dlp) - 仅在网络模式需要
    # Ensure TMP_DIR exists for all modes (used by fio, logs, etc)
    mkdir -p "$TMP_DIR"
    
    if [ "$RUN_TRACE" = "true" ] || [ "$RUN_PUBLIC" = "true" ]; then
        local ephemeral_tools=""
        
        if ! check_cmd nexttrace; then
            local arch=$(uname -m)
            local url=""
            # Note: GitHub repo is Case Sensitive: NTrace-core
            [ "$arch" == "x86_64" ] && url="https://github.com/nxtrace/NTrace-core/releases/latest/download/nexttrace_linux_amd64"
            [ "$arch" == "aarch64" ] && url="https://github.com/nxtrace/NTrace-core/releases/latest/download/nexttrace_linux_arm64"
            
            # 使用 -f 避免下载 404 页面
            if [ -n "$url" ] && curl -f -L -s -o "$TMP_DIR/nexttrace" "$url" 2>/dev/null; then
                chmod +x "$TMP_DIR/nexttrace"
                export NEXTTRACE_BIN="$TMP_DIR/nexttrace"
                ephemeral_tools="$ephemeral_tools nexttrace"
            else
                export NEXTTRACE_BIN="false"
            fi
        else
            export NEXTTRACE_BIN="nexttrace"
        fi
        
        # yt-dlp
        if ! check_cmd yt-dlp; then
            if curl -f -L -s -o "$TMP_DIR/yt-dlp" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" 2>/dev/null; then
                chmod +x "$TMP_DIR/yt-dlp"
                export YTDLP_BIN="$TMP_DIR/yt-dlp"
                ephemeral_tools="$ephemeral_tools yt-dlp"
            else
                export YTDLP_BIN="false"
            fi
        else
            export YTDLP_BIN="yt-dlp"
        fi
        
        # 输出下载提示
        [ -n "$ephemeral_tools" ] && info "下载临时工具:$ephemeral_tools"
    else
        # 即使不需要，也设个默认值防报错
        export NEXTTRACE_BIN="false"
        export YTDLP_BIN="false"
    fi

    info "所有依赖已就绪 ✓"
}

# =========================
# 系统信息
# =========================
collect_system_info() {
    log "开始系统信息收集..."
    
    # 1. CPU
    echo "  ├─ 检测 CPU 信息..."
    if check_cmd lscpu; then
        SYS_CPU=$(lscpu | grep "Model name:" | cut -d: -f2 | xargs)
        SYS_CORES=$(lscpu | grep "CPU(s):" | head -n1 | cut -d: -f2 | xargs)
        # Cache
        local l1=$(lscpu | grep "L1" | grep "cache" | head -n1 | awk '{print $3$4}')
        local l2=$(lscpu | grep "L2" | grep "cache" | head -n1 | awk '{print $3$4}')
        local l3=$(lscpu | grep "L3" | grep "cache" | head -n1 | awk '{print $3$4}')
        [ -z "$l1" ] && l1="-"
        [ -z "$l2" ] && l2="-"
        [ -z "$l3" ] && l3="-"
        SYS_CACHE="L1: $l1 / L2: $l2 / L3: $l3"
    else
        SYS_CPU=$(cat /proc/cpuinfo | grep "model name" | head -n1 | cut -d: -f2 | xargs)
        SYS_CORES=$(grep -c ^processor /proc/cpuinfo)
        SYS_CACHE="Unknown"
    fi
    [ -z "$SYS_CPU" ] && SYS_CPU="Unknown"
    echo "  │  └─ CPU: $SYS_CPU ($SYS_CORES vCPU)"
    
    # 2. Virtualization
    echo "  ├─ 检测虚拟化类型..."
    SYS_VIRT=$(systemd-detect-virt 2>/dev/null)
    if [ -z "$SYS_VIRT" ]; then
        SYS_VIRT=$(hostnamectl 2>/dev/null | grep "Virtualization" | cut -d: -f2 | xargs)
    fi
    [ -z "$SYS_VIRT" ] && SYS_VIRT="Physical/Unknown"
    echo "  │  └─ 虚拟化: $SYS_VIRT"
    
    # 3. RAM / SWAP
    echo "  ├─ 检测内存信息..."
    if check_cmd free; then
        local mem_total=$(free -m | awk '/Mem:/ {print $2}')
        local mem_used=$(free -m | awk '/Mem:/ {print $3}')
        local swap_total=$(free -m | awk '/Swap:/ {print $2}')
        local swap_used=$(free -m | awk '/Swap:/ {print $3}')
        SYS_MEM="${mem_used}MiB / ${mem_total}MiB"
        if [ "$swap_total" -eq 0 ]; then
            SYS_SWAP="0 (Disabled)"
        else
            SYS_SWAP="${swap_used}MiB / ${swap_total}MiB"
        fi
    else
        SYS_MEM="Unknown"
        SYS_SWAP="Unknown"
    fi
    echo "  │  └─ 内存: $SYS_MEM"
    
    # 4. Disk
    echo "  ├─ 检测磁盘信息..."
    local root_disk=$(df -h / | tail -n1)
    local disk_total=$(echo "$root_disk" | awk '{print $2}')
    local disk_used=$(echo "$root_disk" | awk '{print $3}')
    local disk_dev=$(echo "$root_disk" | awk '{print $1}')
    SYS_DISK="${disk_used} / ${disk_total} ($disk_dev)"
    echo "  │  └─ 磁盘: $SYS_DISK"
    
    # 5. OS / Kernel（使用脚本开头已加载的 /etc/os-release 变量）
    SYS_OS="${PRETTY_NAME:-$(uname -srm)}"
    SYS_KERNEL=$(uname -r)
    echo "  └─ 系统: $SYS_OS ($SYS_KERNEL)"
    
    # === Streaming Report ===
    {
        echo "## 系统信息"
        echo "| 测试项目 | 测试结果 |"
        echo "| :--- | :--- |"
        echo "| CPU 型号 | $SYS_CPU |"
        echo "| CPU 核心 | $SYS_CORES |"
        echo "| CPU 缓存 | $SYS_CACHE |"
        echo "| 虚拟化类型 | $SYS_VIRT |"
        echo "| 内存使用 | $SYS_MEM |"
        echo "| Swap 使用 | $SYS_SWAP |"
        echo "| 磁盘使用 | $SYS_DISK |"
        echo "| 系统发行版 | $SYS_OS |"
        echo "| 内核版本 | $SYS_KERNEL |"
        echo ""
    } >> "$REPORT_FILE"
}

# =========================
# 网络信息
# =========================
collect_network_info() {
    log "开始网络信息收集..."
    
    # 使用 ipapi.co，它同时支持 IPv4 和 IPv6 访问
    # 字段映射：ip=IP地址, org=组织, asn=AS号, city=城市, country_code=国家代码
    
    if [ "$SKIP_V4" = "false" ]; then
        echo "  ├─ 查询 IPv4 信息..."
        local v4_json=$(curl -s -4 --max-time 10 https://ipapi.co/json/ 2>/dev/null)
        if [ -n "$v4_json" ] && echo "$v4_json" | jq -e '.ip' >/dev/null 2>&1; then
            HAS_V4="true"
            NET_V4_IP=$(echo "$v4_json" | jq -r '.ip // empty')
            NET_V4_ORG=$(echo "$v4_json" | jq -r '.org // empty')
            NET_V4_ASN=$(echo "$v4_json" | jq -r '.asn // empty' | sed 's/AS//')
            NET_V4_LOC="$(echo "$v4_json" | jq -r '.city // empty'), $(echo "$v4_json" | jq -r '.country_code // empty')"
        else
            HAS_V4=""
            NET_V4_IP="N/A"
            NET_V4_ORG=""
            NET_V4_ASN=""
            NET_V4_LOC=""
        fi
        if [ "$HAS_V4" = "true" ]; then
            if [ "$SKIP_V6" = "true" ]; then
                echo "  └─ IPv4: $NET_V4_IP"
                echo "     ├─ AS${NET_V4_ASN} - ${NET_V4_ORG}"
                echo "     └─ 位置: $NET_V4_LOC"
            else
                echo "  ├─ IPv4: $NET_V4_IP"
                echo "  │  ├─ AS${NET_V4_ASN} - ${NET_V4_ORG}"
                echo "  │  └─ 位置: $NET_V4_LOC"
            fi
        else
            if [ "$SKIP_V6" = "true" ]; then
                echo "  └─ IPv4: N/A"
            else
                echo "  ├─ IPv4: N/A"
            fi
        fi
    fi
    
    if [ "$SKIP_V6" = "false" ]; then
        echo "  ├─ 查询 IPv6 信息..."
        # ipapi.co 支持 IPv6 访问，强制使用 -6 会通过 IPv6 获取信息
        local v6_json=$(curl -s -6 --max-time 10 https://ipapi.co/json/ 2>/dev/null)
        if [ -n "$v6_json" ] && echo "$v6_json" | jq -e '.ip' >/dev/null 2>&1; then
            HAS_V6="true"
            NET_V6_IP=$(echo "$v6_json" | jq -r '.ip // empty')
            NET_V6_ORG=$(echo "$v6_json" | jq -r '.org // empty')
            NET_V6_ASN=$(echo "$v6_json" | jq -r '.asn // empty' | sed 's/AS//')
            NET_V6_LOC="$(echo "$v6_json" | jq -r '.city // empty'), $(echo "$v6_json" | jq -r '.country_code // empty')"
        else
            HAS_V6=""
            NET_V6_IP="N/A"
            NET_V6_ORG=""
            NET_V6_ASN=""
            NET_V6_LOC=""
        fi
        if [ "$HAS_V6" = "true" ]; then
            echo "  └─ IPv6: $NET_V6_IP"
            echo "     ├─ AS${NET_V6_ASN} - ${NET_V6_ORG}"
            echo "     └─ 位置: $NET_V6_LOC"
        else
            echo "  └─ IPv6: N/A"
        fi
    fi

    # === Streaming Report ===
    {
        echo "## 网络信息"
        echo "| 测试项目 | 测试结果 |"
        echo "| :--- | :--- |"
        if [ "$HAS_V4" = "true" ]; then
            local masked_v4=$(echo "$NET_V4_IP" | awk -F. '{print $1"."$2".xx.xx"}')
            echo "| IPv4 - 地址 | $masked_v4 |"
            echo "| IPv4 - AS 信息 | AS$NET_V4_ASN - $NET_V4_ORG |"
            echo "| IPv4 - 地理位置 | $NET_V4_LOC |"
        fi
        if [ "$HAS_V6" = "true" ]; then
            local masked_v6=$(echo "$NET_V6_IP" | awk -F: '{print $1":"$2":xx"}')
            echo "| IPv6 - 地址 | $masked_v6 |"
            echo "| IPv6 - AS 信息 | AS$NET_V6_ASN - $NET_V6_ORG |"
            echo "| IPv6 - 地理位置 | $NET_V6_LOC |"
        fi
        echo ""
    } >> "$REPORT_FILE"
}

# =========================
# IP 质量检测 (仅 IPv4)
# =========================
collect_ip_quality() {
    log "开始 IP 质量检测..."
    
    # 格式化布尔值为 YES/NO
    format_bool_yesno() {
        local val="$1"
        case "$val" in
            "true"|"True"|"TRUE"|"yes"|"1") echo "✅ **YES**" ;;
            "false"|"False"|"FALSE"|"no"|"0") echo "❌ **NO**" ;;
            *) echo "—" ;;
        esac
    }
    
    # 格式化欺诈评分 (0-100, 越低越好)
    format_fraud_score() {
        local score="$1"
        if [ -z "$score" ] || [ "$score" = "null" ]; then
            echo "N/A|—"
            return
        fi
        if [ "$score" -lt 40 ]; then
            echo "$score|🟢 低"
        elif [ "$score" -lt 70 ]; then
            echo "$score|🟡 中"
        else
            echo "$score|🔴 高"
        fi
    }
    
    # 格式化滥用评分 (解析 "0.0078 (Low)" 格式)
    format_abuser_score() {
        local raw="$1"
        if [ -z "$raw" ] || [ "$raw" = "null" ]; then
            echo "N/A|—"
            return
        fi
        # 提取数值和评级
        local num=$(echo "$raw" | awk '{print $1}')
        local level=$(echo "$raw" | grep -oP '\(\K[^)]+')
        
        # 根据评级设置红绿灯 (中文)
        case "$level" in
            "Very Low") echo "$num|🟢 极低" ;;
            "Low") echo "$num|🟢 低" ;;
            "Elevated") echo "$num|🟡 中" ;;
            "High") echo "$num|🟠 高" ;;
            "Very High"|"Critical") echo "$num|🔴 极高" ;;
            *) echo "$num|$level" ;;
        esac
    }
    
    # === 仅 IPv4 检测 ===
    if [ "$HAS_V4" != "true" ]; then
        warn "  └─ 未检测到 IPv4 地址，跳过 IP 质量检测"
        return
    fi
    
    local ip="$NET_V4_IP"
    echo "  ├─ [IPv4] 查询质量信息: $ip"
    
    # 1. ipapi.is - 滥用评分、机房识别、VPN/代理/Tor/爬虫/滥用检测
    echo "  │  ├─ 查询 ipapi.is..."
    local ipapi_json=$(curl -s -4 --max-time 10 "https://api.ipapi.is/?q=$ip" 2>/dev/null)
    
    local ipapi_abuser_score="" ipapi_asn_abuser_score=""
    local ipapi_is_datacenter="" ipapi_datacenter_name=""
    local ipapi_is_vpn="" ipapi_is_proxy="" ipapi_is_tor="" ipapi_is_crawler="" ipapi_is_abuser=""
    local ipapi_company_type="" ipapi_is_mobile="" ipapi_is_bogon="" ipapi_is_satellite=""
    
    if [ -n "$ipapi_json" ] && echo "$ipapi_json" | jq -e '.ip' >/dev/null 2>&1; then
        ipapi_abuser_score=$(echo "$ipapi_json" | jq -r '.company.abuser_score // empty')
        ipapi_asn_abuser_score=$(echo "$ipapi_json" | jq -r '.asn.abuser_score // empty')
        ipapi_is_datacenter=$(echo "$ipapi_json" | jq -r 'if .is_datacenter == null then "" else (.is_datacenter | tostring) end')
        ipapi_datacenter_name=$(echo "$ipapi_json" | jq -r '.datacenter.datacenter // empty')
        ipapi_is_vpn=$(echo "$ipapi_json" | jq -r 'if .is_vpn == null then "" else (.is_vpn | tostring) end')
        ipapi_is_proxy=$(echo "$ipapi_json" | jq -r 'if .is_proxy == null then "" else (.is_proxy | tostring) end')
        ipapi_is_tor=$(echo "$ipapi_json" | jq -r 'if .is_tor == null then "" else (.is_tor | tostring) end')
        ipapi_is_crawler=$(echo "$ipapi_json" | jq -r 'if .is_crawler == null then "" else (.is_crawler | tostring) end')
        ipapi_is_abuser=$(echo "$ipapi_json" | jq -r 'if .is_abuser == null then "" else (.is_abuser | tostring) end')
        ipapi_company_type=$(echo "$ipapi_json" | jq -r '.company.type // empty')
        ipapi_is_mobile=$(echo "$ipapi_json" | jq -r 'if .is_mobile == null then "" else (.is_mobile | tostring) end')
        ipapi_is_bogon=$(echo "$ipapi_json" | jq -r 'if .is_bogon == null then "" else (.is_bogon | tostring) end')
        ipapi_is_satellite=$(echo "$ipapi_json" | jq -r 'if .is_satellite == null then "" else (.is_satellite | tostring) end')
    fi
    
    # 2. ippure - 欺诈评分、原生 IP 识别
    echo "  │  ├─ 查询 ippure.com..."
    local ippure_json=$(curl -s -4 --max-time 10 "https://my.ippure.com/v1/info" 2>/dev/null)
    
    local ippure_fraud_score="" ippure_is_residential=""
    
    if [ -n "$ippure_json" ] && echo "$ippure_json" | jq -e '.ip' >/dev/null 2>&1; then
        ippure_fraud_score=$(echo "$ippure_json" | jq -r '.fraudScore // empty')
        ippure_is_residential=$(echo "$ippure_json" | jq -r 'if .isResidential == null then "" else (.isResidential | tostring) end')
    fi
    
    # === 格式化各项评分 ===
    local fraud_formatted=$(format_fraud_score "$ippure_fraud_score")
    local fraud_val=$(echo "$fraud_formatted" | cut -d'|' -f1)
    local fraud_remark=$(echo "$fraud_formatted" | cut -d'|' -f2)
    
    local abuser_formatted=$(format_abuser_score "$ipapi_abuser_score")
    local abuser_val=$(echo "$abuser_formatted" | cut -d'|' -f1)
    local abuser_remark=$(echo "$abuser_formatted" | cut -d'|' -f2)
    
    local asn_formatted=$(format_abuser_score "$ipapi_asn_abuser_score")
    local asn_val=$(echo "$asn_formatted" | cut -d'|' -f1)
    local asn_remark=$(echo "$asn_formatted" | cut -d'|' -f2)
    
    # === 格式化机房识别结果 ===
    local datacenter_result="" datacenter_remark=""
    if [ "$ipapi_is_datacenter" = "true" ]; then
        datacenter_result="✅ **YES**"
        if [ -n "$ipapi_datacenter_name" ] && [ "$ipapi_datacenter_name" != "null" ]; then
            datacenter_remark="$ipapi_datacenter_name"
        fi
    else
        datacenter_result="❌ **NO**"
        datacenter_remark=""
    fi
    
    # VPN/代理合并检测
    local vpn_proxy_result="false"
    [[ "$ipapi_is_vpn" = "true" || "$ipapi_is_proxy" = "true" ]] && vpn_proxy_result="true"
    
    # === 终端输出关键结果 ===
    echo "  │  ├─ 欺诈评分: ${ippure_fraud_score:-N/A} | 滥用评分: ${ipapi_abuser_score:-N/A}"
    echo "  │  ├─ 组织类型: ${ipapi_company_type:-N/A} | 机房: ${ipapi_is_datacenter:-N/A} | 移动: ${ipapi_is_mobile:-N/A}"
    echo "  │  ├─ VPN/代理: ${vpn_proxy_result} | Tor: ${ipapi_is_tor:-N/A} | 原生: ${ippure_is_residential:-N/A}"
    echo "  │  └─ 检测完成"
    
    # === 生成报告 ===
    {
        echo "## IPv4 质量分析"
        echo ""
        echo "| 检测项目 | 检测结果 | 备注 | 数据来源 |"
        echo "| :--- | :--- | :--- | :--- |"
        # 风险评分
        echo "| 欺诈评分 | $fraud_val | $fraud_remark (越低越好) | ippure.com |"
        echo "| 滥用评分 | $abuser_val | $abuser_remark (越低越好) | ipapi.is |"
        echo "| ASN 信誉 | $asn_val | $asn_remark (越低越好) | ipapi.is |"
        # IP 类型
        # 组织类型中文说明
        local company_type_remark=""
        case "$ipapi_company_type" in
            "hosting") company_type_remark="机房/托管" ;;
            "isp") company_type_remark="运营商/宽带" ;;
            "business") company_type_remark="商业机构" ;;
            "education") company_type_remark="教育机构" ;;
            "government") company_type_remark="政府机构" ;;
            "banking") company_type_remark="金融机构" ;;
            *) company_type_remark="" ;;
        esac
        echo "| 组织类型 | ${ipapi_company_type:-N/A} | $company_type_remark | ipapi.is |"
        echo "| 原生识别 | $(format_bool_yesno "$ippure_is_residential") | | ippure.com |"
        echo "| 机房识别 | $datacenter_result | $datacenter_remark | ipapi.is |"
        echo "| 移动网络 | $(format_bool_yesno "$ipapi_is_mobile") | | ipapi.is |"
        echo "| 卫星网络 | $(format_bool_yesno "$ipapi_is_satellite") | Starlink/Viasat等 | ipapi.is |"
        # 安全标识
        echo "| VPN/代理 | $(format_bool_yesno "$vpn_proxy_result") | | ipapi.is |"
        echo "| Tor 节点 | $(format_bool_yesno "$ipapi_is_tor") | | ipapi.is |"
        echo "| 爬虫检测 | $(format_bool_yesno "$ipapi_is_crawler") | | ipapi.is |"
        echo "| 滥用黑名单 | $(format_bool_yesno "$ipapi_is_abuser") | | ipapi.is |"
        # 其他
        echo "| 保留 IP | $(format_bool_yesno "$ipapi_is_bogon") | | ipapi.is |"
        
        # === 综合评价 ===
        local summary="" summary_icon=""
        local fraud_score_num=${ippure_fraud_score:-100}
        
        # 评价逻辑 (ippure 原生识别优先级高于 ipapi.is 机房识别)
        if [ "$ipapi_is_tor" = "true" ]; then
            summary_icon="🔴"
            summary="Tor 节点，高风险"
        elif [ "$ipapi_is_abuser" = "true" ]; then
            summary_icon="🔴"
            summary="在滥用黑名单中"
        elif [ "$fraud_score_num" -ge 70 ]; then
            summary_icon="🔴"
            summary="欺诈评分过高"
        elif [ "$ippure_is_residential" = "true" ] && [ "$vpn_proxy_result" = "false" ]; then
            # ippure 判定原生优先，即使 ipapi.is 显示机房也信任 ippure
            if [ "$fraud_score_num" -lt 40 ]; then
                summary_icon="🟢"
                summary="优质原生 IP"
            else
                summary_icon="🟡"
                summary="原生家宽 IP，欺诈评分中等"
            fi
        elif [ "$ippure_is_residential" = "true" ] && [ "$vpn_proxy_result" = "true" ]; then
            # 原生但有代理标记
            summary_icon="🟠"
            summary="原生 IP，但检测到代理"
        elif [ "$ipapi_is_datacenter" = "true" ] && [ "$vpn_proxy_result" = "true" ]; then
            summary_icon="🟠"
            summary="机房 IP，有 VPN/代理标记"
        elif [ "$ipapi_is_datacenter" = "true" ]; then
            summary_icon="🟡"
            summary="机房 IP"
        elif [ "$vpn_proxy_result" = "true" ]; then
            summary_icon="🟠"
            summary="检测到 VPN/代理"
        elif [ "$ipapi_is_mobile" = "true" ]; then
            summary_icon="🟡"
            summary="移动网络 IP"
        elif [ "$ipapi_is_satellite" = "true" ]; then
            summary_icon="🟡"
            summary="卫星网络 IP"
        else
            summary_icon="🟢"
            summary="正常 IP"
        fi
        
        echo ""
        echo ""
        echo "> IP 质量评价（由机器生成，仅供参考）：$summary_icon $summary"
        echo ""

    } >> "$REPORT_FILE"
    
    info "  └─ IP 质量检测完成"
}

# =========================
# 性能测试 (CPU/Disk/Net)
# =========================
run_cpu_test() {
    log "开始 CPU 性能测试..."
    if ! check_cmd sysbench; then warn "  └─ sysbench 未安装，跳过"; return; fi
    
    echo "  ├─ 单线程测试 (20秒)..."
    local res_1t=$(sysbench --threads=1 --time=20 --cpu-max-prime=10000 cpu run 2>&1)
    local score_1t=$(echo "$res_1t" | grep "events per second:" | awk '{print $4}')
    echo "  │  └─ 单线程结果: $score_1t events/s"
    
    local score_nt=""
    local multi="1.00"
    if [ "$SYS_CORES" -gt 1 ]; then
        echo "  └─ $SYS_CORES 线程测试 (20秒)..."
        local res_nt=$(sysbench --threads="$SYS_CORES" --time=20 --cpu-max-prime=10000 cpu run 2>&1)
        score_nt=$(echo "$res_nt" | grep "events per second:" | awk '{print $4}')
        multi=$(calc "$score_nt / $score_1t")
        echo "     └─ $SYS_CORES 线程结果: $score_nt events/s (${multi}x)"
    else
        echo "  └─ (单核心，跳过多线程测试)"
    fi
    
    BENCH_CPU_1T="$score_1t"
    BENCH_CPU_NT="${score_nt:-N/A}"
    BENCH_CPU_MULTI="$multi"
    
    # === Streaming Report ===
    {
        echo "## CPU 性能测试"
        echo "| 测试项目 | 测试结果 |"
        echo "| :--- | :--- |"
        echo "| 单线程测试 | $BENCH_CPU_1T |"
        echo "| 多线程测试 | $BENCH_CPU_NT ($BENCH_CPU_MULTI x) |"
        echo ""
    } >> "$REPORT_FILE"
    
    info "  └─ CPU 测试完成"
}

run_disk_test() {
    log "开始磁盘性能测试..."
    if ! check_cmd fio; then warn "  └─ fio 未安装，跳过"; return; fi
    
    local testfile="$TMP_DIR/fio_test"
    
    # Detect best available ioengine (libaio preferred, fallback to sync)
    local ioengine="sync"
    if [ -e /sys/module/libaio ] || modinfo libaio >/dev/null 2>&1; then
        ioengine="libaio"
    fi
    
    # Use --minimal output format for reliable parsing (semicolon-delimited)
    # Format: https://fio.readthedocs.io/en/latest/fio_doc.html#minimal-output
    local job_defaults="--ioengine=$ioengine --size=50m --runtime=10 --iodepth=32 --direct=1 --minimal --filename=$testfile"
    
    parse_fio_minimal() {
        local output="$1"
        local type="$2"  # r or w
        local kbps=0
        local iops=0
        
        # fio --minimal 输出可能包含警告信息（如 "note: ..."）
        # 需要过滤掉，只保留以数字开头的数据行
        local data_line=$(echo "$output" | grep '^[0-9]')
        
        # Minimal output is semicolon-delimited
        # Read: field 7 = KB/s, field 8 = IOPS (1-indexed)
        # Write: field 48 = KB/s, field 49 = IOPS (1-indexed)
        if [ -n "$data_line" ]; then
            if [ "$type" = "r" ]; then
                kbps=$(echo "$data_line" | cut -d';' -f7 2>/dev/null)
                iops=$(echo "$data_line" | cut -d';' -f8 2>/dev/null)
            else
                kbps=$(echo "$data_line" | cut -d';' -f48 2>/dev/null)
                iops=$(echo "$data_line" | cut -d';' -f49 2>/dev/null)
            fi
        fi
        
        # Default to 0 if empty
        kbps=${kbps:-0}
        iops=${iops:-0}
        
        # Convert KB/s to MB/s (handle empty/non-numeric values)
        if [[ "$kbps" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            local mbps=$(calc "${kbps}/1024")
        else
            local mbps="0.00"
        fi
        
        if [[ "$iops" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            local iops_int=$(printf "%.0f" "${iops}" 2>/dev/null || echo "0")
        else
            local iops_int="0"
        fi
        
        echo "$mbps MB/s ($iops_int IOPS)"
    }
    
    echo "  ├─ [1/4] 写入测试 (4K) (10秒)..."
    local w4=$(fio --name=w4k --rw=randwrite --bs=4k $job_defaults 2>/dev/null)
    local res_w4=$(parse_fio_minimal "$w4" "w")
    echo "  │  └─ 结果: $res_w4"
    
    echo "  ├─ [2/4] 读取测试 (4K) (10秒)..."
    local r4=$(fio --name=r4k --rw=randread --bs=4k $job_defaults 2>/dev/null)
    local res_r4=$(parse_fio_minimal "$r4" "r")
    echo "  │  └─ 结果: $res_r4"
    
    echo "  ├─ [3/4] 写入测试 (128K) (10秒)..."
    local w128=$(fio --name=w128k --rw=write --bs=128k $job_defaults 2>/dev/null)
    local res_w128=$(parse_fio_minimal "$w128" "w")
    echo "  │  └─ 结果: $res_w128"
    
    echo "  ├─ [4/4] 读取测试 (128K) (10秒)..."
    local r128=$(fio --name=r128k --rw=read --bs=128k $job_defaults 2>/dev/null)
    local res_r128=$(parse_fio_minimal "$r128" "r")
    echo "  │  └─ 结果: $res_r128"
    
    rm -f "$testfile"
    
    BENCH_DISK_W4="$res_w4"
    BENCH_DISK_R4="$res_r4"
    BENCH_DISK_W128="$res_w128"
    BENCH_DISK_R128="$res_r128"
    
    # === Streaming Report ===
    {
        echo "## 磁盘性能测试"
        echo "| 测试项目 | 测试结果 |"
        echo "| :--- | :--- |"
        echo "| 写入测试 (4K) | $BENCH_DISK_W4 |"
        echo "| 读取测试 (4K) | $BENCH_DISK_R4 |"
        echo "| 写入测试 (128K) | $BENCH_DISK_W128 |"
        echo "| 读取测试 (128K) | $BENCH_DISK_R128 |"
        echo ""
    } >> "$REPORT_FILE"
    
    info "  └─ 磁盘测试完成"
}

run_iperf_once() {
    local host="$1"
    local port="$2"
    local parallel="$3"
    local reverse="$4"
    local ipflag="$5"
    local args=("$ipflag" "-c" "$host" "-p" "$port" "-P" "$parallel" "-t" "5")
    [ "$reverse" = "true" ] && args+=("-R")
    
    local ret="busy"
    for i in 1 2; do
        local out
        # Add timeout to prevent hanging on bad nodes
        out=$(timeout 15 iperf3 "${args[@]}" 2>&1)
        if [[ "$out" == *"receiver"* ]]; then
             local line=$(echo "$out" | grep "receiver" | grep "SUM" | tail -n1)
             [ -z "$line" ] && line=$(echo "$out" | grep "receiver" | tail -n1)
             local val=$(echo "$line" | awk '{print $(NF-2)}')
             local unit=$(echo "$line" | awk '{print $(NF-1)}')
             if [ -n "$val" ] && [ "$val" != "0.00" ]; then
                 ret="$val $unit"
                 break
             fi
        fi
        sleep 1
    done
    echo "$ret"
}

run_iperf_test() {
    log "开始网络带宽测试..."
    if ! check_cmd iperf3; then warn "  └─ iperf3 未安装，跳过"; return; fi
    
    local locs=(
        "lon.speedtest.clouvider.net|5200-5209|Clouvider|London, UK (10G)|IPv4|IPv6"
        "iperf-ams-nl.eranium.net|5201-5210|Eranium|Amsterdam, NL (100G)|IPv4|IPv6"
        "speedtest.uztelecom.uz|5200-5209|Uztelecom|Tashkent, UZ (10G)|IPv4|IPv6"
        "speedtest.sin1.sg.leaseweb.net|5201-5210|Leaseweb|Singapore, SG (10G)|IPv4|IPv6"
        "la.speedtest.clouvider.net|5200-5209|Clouvider|Los Angeles, CA, US (10G)|IPv4|IPv6"
        "speedtest.nyc1.us.leaseweb.net|5201-5210|Leaseweb|NYC, NY, US (10G)|IPv4|IPv6"
        "speedtest.sao1.edgoo.net|9204-9240|Edgoo|Sao Paulo, BR (1G)|IPv4|IPv6"
    )
    local locs_cn=(
        "14.119.118.214|5201|青毅云|深圳电信|IPv4"
        "36.150.232.152|5201|青毅云|江苏移动|IPv4"
    )
    
    # === Streaming Report (Header) ===
    {
        echo "## 网络带宽测试"
        echo "| IP 类型 | 运营商 | 服务器位置 | 发送带宽 | 接收带宽 | 延迟 |"
        echo "| :--- | :--- | :--- | :--- | :--- | :--- |"
    } >> "$REPORT_FILE"
    
    echo "  ├─ 国际节点测试..."
    local idx=0
    for entry in "${locs[@]}"; do
        idx=$((idx+1))
        IFS='|' read -r host ports provider loc modes <<< "$entry"
        IFS='-' read -r p0 p1 <<< "$ports"
        for mode in IPv4 IPv6; do
            if [[ "$modes" != *"$mode"* ]]; then continue; fi
            if [ "$mode" == "IPv4" ] && [ "$HAS_V4" != "true" ]; then continue; fi
            if [ "$mode" == "IPv6" ] && [ "$HAS_V6" != "true" ]; then continue; fi
            local ipflag="-4"; [ "$mode" == "IPv6" ] && ipflag="-6"
            
            echo "  │  ├─ [$idx/${#locs[@]}] $provider - $loc ($mode)..."
            local p=$((p0 + RANDOM % (p1 - p0 + 1)))
            local send=$(run_iperf_once "$host" "$p" 8 false "$ipflag")
            p=$((p0 + RANDOM % (p1 - p0 + 1)))
            local recv=$(run_iperf_once "$host" "$p" 8 true "$ipflag")
            local lat="--"
            if [ "$mode" = "IPv4" ]; then lat=$(ping -c 1 -W 1 "$host" 2>/dev/null | grep "time=" | awk -F "time=" '{print $2}' | awk '{print $1}'); else lat=$(ping6 -c 1 -W 1 "$host" 2>/dev/null | grep "time=" | awk -F "time=" '{print $2}' | awk '{print $1}'); fi
            echo "  │  │  └─ 发送: ${send} / 接收: ${recv} / 延迟: ${lat:---} ms"
            
            # Streaming Row
            echo "| $mode | $provider | $loc | $send | $recv | ${lat:---} ms |" >> "$REPORT_FILE"
        done
    done
    
    echo "" >> "$REPORT_FILE"
    
    echo "  ├─ 国内节点测试..."
    
    # === Streaming Report (Domestic Header) ===
    if [ "$HAS_V4" = "true" ] && [ ${#locs_cn[@]} -gt 0 ]; then
        {
            echo "### 国内节点（感谢青毅云提供测试节点）"
            echo "> 🌐 青毅云计算 (YOUTHIDC)  "
            echo "> ⚡️ 国内大带宽独享服务器，IEPL 跨境专线  "
            echo "> 💬 Telegram 群组：https://t.me/YouthIDC  "
            echo "> "
            echo "| 节点 | 线程 | 发送带宽 | 接收带宽 |"
            echo "| :--- | :--- | :--- | :--- |"
        } >> "$REPORT_FILE"
    fi
    
    idx=0
    for entry in "${locs_cn[@]}"; do
        idx=$((idx+1))
        IFS='|' read -r host port provider loc modes <<< "$entry"
        [ "$HAS_V4" != "true" ] && continue
        echo "  │  ├─ [$idx/${#locs_cn[@]}] $provider $loc..."
        local lat=$(ping -c 1 -W 1 "$host" 2>/dev/null | grep "time=" | awk -F "time=" '{print $2}' | awk '{print $1}');
        echo "  │  │  ├─ 单线程..."
        local s1=$(run_iperf_once "$host" "$port" 1 false "-4")
        local r1=$(run_iperf_once "$host" "$port" 1 true "-4")
        echo "  │  │  │  └─ 发送: $s1 / 接收: $r1"
        
        echo "| $provider $loc | 1 | $s1 | $r1 |" >> "$REPORT_FILE"
        
        echo "  │  │  ├─ 8线程..."
        local s8=$(run_iperf_once "$host" "$port" 8 false "-4")
        local r8=$(run_iperf_once "$host" "$port" 8 true "-4")
        echo "  │  │  │  └─ 发送: $s8 / 接收: $r8"
        
        echo "| $provider $loc | 8 | $s8 | $r8 |" >> "$REPORT_FILE"
    done
    
    echo "" >> "$REPORT_FILE"
    info "  └─ 带宽测试完成"

}

# =========================
# 流媒体解锁测试
# =========================
run_stream_test() {
    log "开始流媒体解锁测试..."
    
    # 检查网络可用性
    if [ "$HAS_V4" != "true" ] && [ "$HAS_V6" != "true" ]; then
        warn "  └─ 无可用网络，跳过流媒体测试"
        return
    fi
    
    # 从之前收集的网络信息中提取国家代码
    local country_code=""
    if [ "$HAS_V4" = "true" ] && [ -n "$NET_V4_LOC" ]; then
        country_code=$(echo "$NET_V4_LOC" | awk -F', ' '{print $NF}' | xargs)
    elif [ "$HAS_V6" = "true" ] && [ -n "$NET_V6_LOC" ]; then
        country_code=$(echo "$NET_V6_LOC" | awk -F', ' '{print $NF}' | xargs)
    fi
    
    # RegionRestrictionCheck 的区域 ID 定义:
    # 0=只进行跨国平台检测
    # 1=跨国平台+台湾平台，2=跨国平台+香港平台，3=跨国平台+日本平台
    # 4=跨国平台+北美平台，5=跨国平台+南美平台，6=跨国平台+欧洲平台
    # 7=跨国平台+大洋洲平台，8=跨国平台+韩国平台，9=跨国平台+东南亚平台
    # 10=跨国平台+印度平台，11=跨国平台+非洲平台
    
    local region_id="0"  # 默认仅跨国平台
    local region_name="仅跨国平台"
    local detected_region_id=""
    local detected_region_name=""
    
    # 根据国家代码映射到测试区域
    case "$country_code" in
        # 台湾
        TW) detected_region_id="1"; detected_region_name="跨国平台+台湾平台" ;;
        # 香港
        HK) detected_region_id="2"; detected_region_name="跨国平台+香港平台" ;;
        # 日本
        JP) detected_region_id="3"; detected_region_name="跨国平台+日本平台" ;;
        # 北美 (美国、加拿大、墨西哥)
        US|CA|MX) detected_region_id="4"; detected_region_name="跨国平台+北美平台" ;;
        # 南美
        BR|AR|CL|CO|PE|VE|EC|BO|UY|PY|GY|SR) detected_region_id="5"; detected_region_name="跨国平台+南美平台" ;;
        # 欧洲
        GB|DE|FR|IT|ES|NL|BE|AT|CH|PL|CZ|PT|SE|NO|DK|FI|IE|RO|HU|GR|RU|UA|BY) detected_region_id="6"; detected_region_name="跨国平台+欧洲平台" ;;
        # 大洋洲 (澳大利亚、新西兰等)
        AU|NZ|FJ|PG|NC|PF) detected_region_id="7"; detected_region_name="跨国平台+大洋洲平台" ;;
        # 韩国
        KR) detected_region_id="8"; detected_region_name="跨国平台+韩国平台" ;;
        # 东南亚
        SG|MY|TH|VN|ID|PH|MM|KH|LA|BN) detected_region_id="9"; detected_region_name="跨国平台+东南亚平台" ;;
        # 印度
        IN) detected_region_id="10"; detected_region_name="跨国平台+印度平台" ;;
        # 非洲
        ZA|EG|NG|KE|MA|TN|GH|TZ|UG|ZW|ET) detected_region_id="11"; detected_region_name="跨国平台+非洲平台" ;;
        # 中东 -> 归类到跨国平台
        AE|SA|IL|TR|IR|IQ|KW|QA|BH|OM|JO|LB) detected_region_id=""; detected_region_name="" ;;
        # 中国大陆 -> 归类到跨国平台
        CN) detected_region_id=""; detected_region_name="" ;;
        # 其他/未知
        *) detected_region_id=""; detected_region_name="" ;;
    esac
    
    echo "  ├─ 检测到服务器位置: ${country_code:-未知}"
    
    # 如果检测到了对应的地区，询问用户选择
    if [ -n "$detected_region_id" ]; then
        echo "  ├─ 匹配测试区域: $detected_region_name (ID: $detected_region_id)"
        echo -e "  ├─ ${YELLOW}请选择测试模式:${NC}"
        echo "  │  ├─ [1] $detected_region_name (默认)"
        echo "  │  ├─ [0] 仅跨国平台检测"
        echo -n -e "  │  ├─ ${YELLOW}请输入选项 (5秒后自动选择 [1]): ${NC}"
        read -t 5 -r user_choice </dev/tty 2>/dev/null || { user_choice="1"; echo ""; }
        
        case "$user_choice" in
            0)
                region_id="0"
                region_name="仅跨国平台"
                ;;
            *)
                region_id="$detected_region_id"
                region_name="$detected_region_name"
                ;;
        esac
    else
        echo "  ├─ 未匹配到特定区域，将执行仅跨国平台检测"
        region_id="0"
        region_name="仅跨国平台"
    fi
    
    echo "  │  └─ 选择测试区域: $region_name (ID: $region_id)"
    
    # 调用外部流媒体测试脚本
    # -R: 指定测试区域
    # -M 4: 仅使用 IPv4
    # -M 6: 仅使用 IPv6
    
    # 下载并执行流媒体测试脚本，捕获输出
    local stream_output=""
    local stream_script_url="https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/refs/heads/main/check.sh"
    local stream_tmp_file="$TMP_DIR/stream_output.txt"
    
    # 下载脚本到临时文件
    echo -n "  ├─ 正在下载测试脚本..."
    local stream_script_file="$TMP_DIR/check_stream.sh"
    if ! curl -sL "$stream_script_url" -o "$stream_script_file" 2>/dev/null; then
        echo -e " ${RED}失败${NC}"
        warn "  └─ 流媒体测试失败：无法下载测试脚本"
        return
    fi
    echo -e " ${GREEN}完成${NC}"
    chmod +x "$stream_script_file"
    
    # 定义执行单次测试的函数
    run_single_stream_test() {
        local test_mode="$1"
        local mode_name="$2"
        local output_file="$3"
        
        # 启动后台进度指示器
        echo -n "  ├─ 正在执行 ${mode_name} 测试 "
        local spinner_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local spinner_pid=""
        (
            local i=0
            local start_time=$(date +%s)
            while true; do
                local elapsed=$(($(date +%s) - start_time))
                local mins=$((elapsed / 60))
                local secs=$((elapsed % 60))
                printf "\r  ├─ 正在执行 ${mode_name} 测试 ${spinner_chars:i++%10:1} [%02d:%02d]" "$mins" "$secs"
                sleep 0.2
            done
        ) &
        spinner_pid=$!
        
        # 执行测试
        if command -v script >/dev/null 2>&1; then
            TERM=xterm-256color script -q -c "bash '$stream_script_file' -R '$region_id' -M '$test_mode'" "$output_file" >/dev/null 2>&1
        else
            bash "$stream_script_file" -R "$region_id" -M "$test_mode" > "$output_file" 2>&1
        fi
        
        # 停止进度指示器
        kill $spinner_pid 2>/dev/null
        wait $spinner_pid 2>/dev/null
        
        if [ -f "$output_file" ] && [ -s "$output_file" ]; then
            echo -e "\r  ├─ ${mode_name} 测试完成 ${GREEN}✓${NC}              "
            return 0
        else
            echo -e "\r  ├─ ${mode_name} 测试失败 ${RED}✗${NC}              "
            return 1
        fi
    }
    
    # 分开测试 IPv4 和 IPv6
    local stream_output_v4=""
    local stream_output_v6=""
    local stream_tmp_v4="$TMP_DIR/stream_v4.txt"
    local stream_tmp_v6="$TMP_DIR/stream_v6.txt"
    
    # IPv4 测试
    if [ "$HAS_V4" = "true" ]; then
        if run_single_stream_test "4" "IPv4" "$stream_tmp_v4"; then
            stream_output_v4=$(cat "$stream_tmp_v4" 2>/dev/null)
        fi
        rm -f "$stream_tmp_v4"
    fi
    
    # IPv6 测试
    if [ "$HAS_V6" = "true" ]; then
        if run_single_stream_test "6" "IPv6" "$stream_tmp_v6"; then
            stream_output_v6=$(cat "$stream_tmp_v6" 2>/dev/null)
        fi
        rm -f "$stream_tmp_v6"
    fi
    
    # 清理脚本文件
    rm -f "$stream_script_file"
    
    # 合并输出
    stream_output=""
    if [ -n "$stream_output_v4" ]; then
        stream_output="${stream_output_v4}"
    fi
    if [ -n "$stream_output_v6" ]; then
        stream_output="${stream_output}
${stream_output_v6}"
    fi
    
    if [ -z "$stream_output" ]; then
        warn "  └─ 流媒体测试失败：无法获取测试结果"
        return
    fi
    
    info "  └─ 流媒体解锁测试完成"
    
    # === Streaming Report ===
    # 解析流媒体测试结果并转换为表格
    parse_stream_to_table() {
        local output="$1"
        local ip_version="$2"
        
        # 清理 ANSI 颜色代码和控制字符
        local cleaned=$(echo "$output" | \
            sed 's/\x1b\[[0-9;]*m//g' | \
            sed 's/\x1b\[H\x1b\[2J//g' | \
            sed 's/\x1b\[?25[hl]//g' | \
            tr -d '\r')
        
        # 提取当前 IP 版本的测试结果
        local in_section="false"
        local current_category=""
        local last_category=""
        local results=""
        
        while IFS= read -r line; do
            # 检测 IP 版本测试开始
            if echo "$line" | grep -q "正在测试.*$ip_version"; then
                in_section="true"
                continue
            fi
            
            # 检测下一个 IP 版本测试开始（结束当前）
            if [ "$in_section" = "true" ] && echo "$line" | grep -q "正在测试.*IPv[46]"; then
                break
            fi
            
            # 在当前 IP 版本区域内
            if [ "$in_section" = "true" ]; then
                # 匹配区域标题 ===[ xxx ]=== 或 ============[ xxx ]============
                if echo "$line" | grep -qE '=+\[.*\]=+'; then
                    current_category=$(echo "$line" | sed 's/=//g' | sed 's/\[//g' | sed 's/\]//g' | xargs)
                    # 输出分类标题行（用 CATEGORY: 前缀标记）
                    results="${results}CATEGORY:${current_category}|\n"
                    last_category="$current_category"
                    continue
                fi
                
                # 匹配子分类 ---GB--- ---FR--- 等
                if echo "$line" | grep -qE '^-{3}[A-Za-z]+-{3}$'; then
                    current_category=$(echo "$line" | sed 's/-//g')
                    # 输出子分类标题行（用 SUBCATEGORY: 前缀标记）
                    results="${results}SUBCATEGORY:${current_category}|\n"
                    continue
                fi
                
                # 匹配测试结果行（含Tab或多个空格和冒号）
                if echo "$line" | grep -qE '^\s*[A-Za-z0-9+() -]+:\s+' && \
                   ! echo "$line" | grep -qE '脚本适配|您的网络|测试时间|版本|运行次数|t\.me|github|网站|详情'; then
                    # 解析服务名称和状态
                    local service=$(echo "$line" | sed 's/^\s*//' | cut -d':' -f1 | xargs)
                    local status=$(echo "$line" | sed 's/^\s*//' | cut -d':' -f2- | xargs)
                    
                    # 转换状态为图标
                    local icon=""
                    local status_text="$status"
                    
                    if echo "$status" | grep -qiE '^Yes|^Originals Only'; then
                        icon="✅"
                        # 提取区域信息
                        if echo "$status" | grep -qi "Region:"; then
                            status_text=$(echo "$status" | sed 's/Yes/解锁/' | sed 's/(Region: /(/g')
                        else
                            status_text="解锁"
                        fi
                    elif echo "$status" | grep -qiE '^No$|^No |Blocked|不支持'; then
                        icon="❌"
                        status_text="未解锁"
                    elif echo "$status" | grep -qiE 'Failed|Error|错误'; then
                        icon="🔴"
                        status_text="检测失败"
                    elif echo "$status" | grep -qiE 'Not Currently Supported|不支持'; then
                        icon="⚪"
                        status_text="不支持"
                    else
                        icon="🔵"
                        status_text="$status"
                    fi
                    
                    # 添加结果
                    results="${results}${service}|${icon} ${status_text}\n"
                fi
            fi
        done <<< "$cleaned"
        
        echo -e "$results"
    }
    
    {
        echo "## 流媒体解锁测试"
        echo ""
        echo "测试区域: **$region_name**"
        echo ""
        
        # IPv4 结果表格
        if [ -n "$stream_output_v4" ]; then
            echo "### IPv4 解锁测试"
            echo ""
            echo "| 服务 | 状态 |"
            echo "| :--- | :--- |"
            
            # 解析并输出 IPv4 结果
            parse_stream_to_table "$stream_output_v4" "IPv4" | while IFS='|' read -r service status; do
                if [ -n "$service" ]; then
                    # 检测是否为分类标题
                    if [[ "$service" == CATEGORY:* ]]; then
                        local cat_name="${service#CATEGORY:}"
                        echo "| **━━ $cat_name ━━** | |"
                    elif [[ "$service" == SUBCATEGORY:* ]]; then
                        local subcat_name="${service#SUBCATEGORY:}"
                        echo "| **── $subcat_name ──** | |"
                    else
                        echo "| $service | $status |"
                    fi
                fi
            done
            echo ""
        fi
        
        # IPv6 结果表格
        if [ -n "$stream_output_v6" ]; then
            echo "### IPv6 解锁测试"
            echo ""
            echo "| 服务 | 状态 |"
            echo "| :--- | :--- |"
            
            # 解析并输出 IPv6 结果
            parse_stream_to_table "$stream_output_v6" "IPv6" | while IFS='|' read -r service status; do
                if [ -n "$service" ]; then
                    # 检测是否为分类标题
                    if [[ "$service" == CATEGORY:* ]]; then
                        local cat_name="${service#CATEGORY:}"
                        echo "| **━━ $cat_name ━━** | |"
                    elif [[ "$service" == SUBCATEGORY:* ]]; then
                        local subcat_name="${service#SUBCATEGORY:}"
                        echo "| **── $subcat_name ──** | |"
                    else
                        echo "| $service | $status |"
                    fi
                fi
            done
            echo ""
        fi
        
    } >> "$REPORT_FILE"
}

# =========================
# Traceroute
# =========================
create_ix_map() {
    cat << 'EOF' > "$TMP_DIR/ix_ip_map.txt"
187.16.223.20 IX.br (PTT.br) São Paulo
2001:12f8::223:20 IX.br (PTT.br) São Paulo
187.16.220.83 IX.br (PTT.br) São Paulo
2001:12f8::220:83 IX.br (PTT.br) São Paulo
208.115.136.200 Equinix Chicago
2001:504:0:4::2906:2 Equinix Chicago
208.115.136.156 Equinix Chicago
2001:504:0:4::2906:1 Equinix Chicago
187.16.217.185 IX.br (PTT.br) São Paulo
2001:12f8::217:185 IX.br (PTT.br) São Paulo
45.6.52.42 IX.br (PTT.br) Rio de Janeiro
2001:12f8:0:2::42 IX.br (PTT.br) Rio de Janeiro
187.16.223.131 IX.br (PTT.br) São Paulo
2001:12f8::223:131 IX.br (PTT.br) São Paulo
206.126.238.97 Equinix Ashburn
2001:504:0:2::2906:2 Equinix Ashburn
206.223.118.156 Equinix Dallas
2001:504:0:5::2906:1 Equinix Dallas
206.223.118.157 Equinix Dallas
2001:504:0:5::2906:2 Equinix Dallas
206.126.236.238 Equinix Ashburn
2001:504:0:2::2906:1 Equinix Ashburn
45.6.52.189 IX.br (PTT.br) Rio de Janeiro
2001:12f8:0:2::189 IX.br (PTT.br) Rio de Janeiro
36.255.56.111 Equinix Hong Kong
2001:de8:7::2906:2 Equinix Hong Kong
206.41.108.10 FL-IX
2001:504:40:108::1:10 FL-IX
80.81.194.202 DE-CIX Frankfurt
2001:7f8::b5a:0:2 DE-CIX Frankfurt
36.255.56.105 Equinix Hong Kong
2001:de8:7::2906:1 Equinix Hong Kong
45.68.72.55 IX.br (PTT.br) Fortaleza
2001:12f8:0:9::55 IX.br (PTT.br) Fortaleza
45.68.72.56 IX.br (PTT.br) Fortaleza
2001:12f8:0:9::56 IX.br (PTT.br) Fortaleza
206.126.110.127 Digital Realty Atlanta
2001:504:17:110::127 Digital Realty Atlanta
80.81.194.182 DE-CIX Frankfurt
2001:7f8::b5a:0:1 DE-CIX Frankfurt
196.60.8.100 NAPAfrica IX Johannesburg
2001:43f8:6d0::100 NAPAfrica IX Johannesburg
206.126.110.113 Digital Realty Atlanta
2001:504:17:110::113 Digital Realty Atlanta
196.60.8.80 NAPAfrica IX Johannesburg
2001:43f8:6d0::80 NAPAfrica IX Johannesburg
206.41.108.50 FL-IX
2001:504:40:108::1:50 FL-IX
206.81.80.223 SIX Seattle
2001:504:16::223:0:b5a SIX Seattle
206.81.80.222 SIX Seattle
2001:504:16::b5a SIX Seattle
193.203.0.203 VIX
2001:7f8:30:0:2:1:0:2906 VIX
103.27.170.185 DE-CIX Mumbai
2401:7500:fff6::185 DE-CIX Mumbai
206.108.255.35 MICE
2001:504:27::b5a:0:1 MICE
193.203.0.9 VIX
2001:7f8:30:0:1:1:0:2906 VIX
123.255.92.47 HKIX
2001:7fa:0:1::ca28:a22f HKIX
123.255.92.46 HKIX
2001:7fa:0:1::ca28:a22e HKIX
206.223.117.100 Equinix San Jose
2001:504:0:1::2906:3 Equinix San Jose
212.91.0.210 THINX Warsaw
2001:7f8:60::2906:2 THINX Warsaw
206.71.12.13 CIX-ATL
2001:504:40:12::1:13 CIX-ATL
177.52.38.90 IX.br (PTT.br) Porto Alegre
2001:12f8:0:6::2906 IX.br (PTT.br) Porto Alegre
206.53.175.33 IX-Denver
2001:504:58::33 IX-Denver
206.71.12.14 CIX-ATL
2001:504:40:12::1:14 CIX-ATL
101.203.88.117 BBIX Tokyo
2001:de8:c::2906:1 BBIX Tokyo
101.203.88.119 BBIX Tokyo
2001:de8:c::2906:2 BBIX Tokyo
206.53.175.32 IX-Denver
2001:504:58::32 IX-Denver
206.108.255.36 MICE
2001:504:27::b5a:0:2 MICE
203.190.230.110 Equinix Tokyo
2001:de8:5::2906:1 Equinix Tokyo
203.190.230.111 Equinix Tokyo
2001:de8:5::2906:2 Equinix Tokyo
210.173.176.153 JPNAP Tokyo
2001:7fa:7:1::2906:1 JPNAP Tokyo
210.173.176.154 JPNAP Tokyo
2001:7fa:7:1::2906:2 JPNAP Tokyo
206.72.210.226 Any2West
2001:504:13::210:226 Any2West
206.72.210.215 Any2West
2001:504:13::210:215 Any2West
188.93.170.90 LU-CIX
2001:7f8:4c::b5a:1 LU-CIX
188.93.171.90 LU-CIX
2001:7f8:4c::b5a:2 LU-CIX
177.52.38.120 IX.br (PTT.br) Porto Alegre
2001:12f8:0:6::b:2906 IX.br (PTT.br) Porto Alegre
206.126.115.225 Digital Realty New York
2001:504:17:115::225 Digital Realty New York
206.223.116.133 Equinix San Jose
2001:504:0:1::2906:2 Equinix San Jose
27.111.228.200 Equinix Singapore
2001:de8:4::2906:1 Equinix Singapore
27.111.228.210 Equinix Singapore
2001:de8:4::2906:2 Equinix Singapore
195.182.219.195 Equinix Warsaw
2001:7f8:42::a500:2906:2 Equinix Warsaw
195.182.218.195 Equinix Warsaw
2001:7f8:42::a500:2906:1 Equinix Warsaw
103.231.152.77 BBIX Singapore
2001:df5:b800:bb00::2906:4 BBIX Singapore
206.223.123.9 Equinix Los Angeles
2001:504:0:3::2906:1 Equinix Los Angeles
103.26.71.40 MegaIX Melbourne
2001:dea:0:30::28 MegaIX Melbourne
103.231.152.76 BBIX Singapore
2001:df5:b800:bb00::2906:3 BBIX Singapore
195.149.232.183 TPIX PL
2001:7f8:27::2906:1 TPIX PL
103.203.158.74 BBIX Hong Kong
2403:c780:b800:bb00::2906:1 BBIX Hong Kong
103.203.158.75 BBIX Hong Kong
2403:c780:b800:bb00::2906:2 BBIX Hong Kong
193.149.1.73 ESpanix Madrid Lower LAN
2001:7f8:f::76 ESpanix Madrid Lower LAN
89.46.145.207 EPIX.Warszawa
2001:678:3ac::587 EPIX.Warszawa
89.46.145.206 EPIX.Warszawa
2001:678:3ac::586 EPIX.Warszawa
193.149.1.69 ESpanix Madrid Lower LAN
2001:7f8:f::75 ESpanix Madrid Lower LAN
210.171.224.222 JPIX TOKYO
2001:de8:8::2906:2 JPIX TOKYO
206.51.7.37 KCIX
2001:504:1b:1::37 KCIX
194.68.128.43 Netnod Stockholm BLUE -- MTU1500
2001:7f8:d:fe::43 Netnod Stockholm BLUE -- MTU1500
45.127.172.237 Equinix Sydney
2001:de8:6::2906:2 Equinix Sydney
86.104.125.155 InterLAN-IX
2001:7f8:64:225::2906:1 InterLAN-IX
103.16.102.86 SGIX
2001:de8:12:100::86 SGIX
198.32.160.90 NYIIX New York
2001:504:1::a500:2906:1 NYIIX New York
198.32.118.176 Equinix New York
2001:504:f::2906:1 Equinix New York
103.16.102.87 SGIX
2001:de8:12:100::87 SGIX
185.6.36.85 INEX LAN1
2001:7f8:18::85 INEX LAN1
206.51.46.88 Any2Denver
2605:6c00:303:303::88 Any2Denver
206.51.46.98 Any2Denver
2605:6c00:303:303::98 Any2Denver
210.171.224.221 JPIX TOKYO
2001:de8:8::2906:1 JPIX TOKYO
198.32.160.189 NYIIX New York
2001:504:1::a500:2906:2 NYIIX New York
210.173.184.41 JPNAP Osaka
2001:7fa:7:2::2906:1 JPNAP Osaka
206.41.110.25 ChIX
2001:504:41:110::25 ChIX
103.26.68.97 MegaIX Sydney
2001:dea:0:10::61 MegaIX Sydney
218.100.9.60 BBIX Osaka
2001:de8:c:2::2906:1 BBIX Osaka
218.100.9.61 BBIX Osaka
2001:de8:c:2::2906:2 BBIX Osaka
103.246.232.221 JPIX OSAKA
2001:de8:8:6::2906:1 JPIX OSAKA
103.246.232.222 JPIX OSAKA
2001:de8:8:6::2906:2 JPIX OSAKA
198.32.118.121 Equinix New York
2001:504:f::2906:2 Equinix New York
206.80.234.14 PhillyIX
2001:504:90::14 PhillyIX
206.80.234.15 PhillyIX
2001:504:90::15 PhillyIX
80.249.210.250 AMS-IX
2001:7f8:1::a500:2906:1 AMS-IX
80.249.211.250 AMS-IX
2001:7f8:1::a500:2906:2 AMS-IX
103.26.71.65 MegaIX Melbourne
2001:dea:0:30::41 MegaIX Melbourne
103.180.190.27 EdgeIX - Auckland
2001:df0:680:11::1b EdgeIX - Auckland
194.68.123.43 Netnod Stockholm GREEN -- MTU1500
2001:7f8:d:ff::43 Netnod Stockholm GREEN -- MTU1500
37.49.236.194 France-IX Paris
2001:7f8:54::194 France-IX Paris
103.180.190.26 EdgeIX - Auckland
2001:df0:680:11::1a EdgeIX - Auckland
206.197.187.11 SFMIX
2001:504:30::ba00:2906:1 SFMIX
210.173.184.93 JPNAP Osaka
2001:7fa:7:2::2906:2 JPNAP Osaka
185.1.103.77 RoNIX
2001:7f8:49::77 RoNIX
195.66.227.146 LINX LON1
2001:7f8:4::b5a:2 LINX LON1
195.66.227.7 LINX LON1
2001:7f8:4::b5a:1 LINX LON1
195.66.225.16 LINX LON1
2001:7f8:4::b5a:4 LINX LON1
185.1.106.28 Equinix Milan
2001:7f8:c0::2906:1 Equinix Milan
185.1.106.31 Equinix Milan
2001:7f8:c0::2906:2 Equinix Milan
195.66.224.251 LINX LON1
2001:7f8:4::b5a:3 LINX LON1
196.60.96.100 JINX
2001:43f8:1f0::100 JINX
64.191.232.77 Equinix São Paulo
2001:504:0:7::4d Equinix São Paulo
64.191.232.22 Equinix São Paulo
2001:504:0:7::16 Equinix São Paulo
206.223.123.50 Equinix Los Angeles
2001:504:0:3::2906:2 Equinix Los Angeles
218.100.52.114 NSW-IX
2001:7fa:11:4:0:b5a:0:1 NSW-IX
218.100.52.113 NSW-IX
2001:7fa:11:4:0:b5a:0:2 NSW-IX
217.29.66.186 MIX-IT
2001:7f8:b:100:1d1:a5d0:2906:186 MIX-IT
196.60.96.46 JINX
2001:43f8:1f0::46 JINX
217.29.66.187 MIX-IT
2001:7f8:b:100:1d1:a5d0:2906:187 MIX-IT
194.146.118.134 MegaIX Dusseldorf
2001:7f8:8::b5a:0:1 MegaIX Dusseldorf
194.146.118.135 MegaIX Dusseldorf
2001:7f8:8::b5a:0:2 MegaIX Dusseldorf
45.127.172.200 Equinix Sydney
2001:de8:6::2906:1 Equinix Sydney
185.1.114.19 MINAP Milan
2001:7f8:c5::a500:2906:2 MINAP Milan
206.51.7.13 KCIX
2001:504:1b:1::13 KCIX
206.108.236.98 Boston Internet Exchange
2001:504:24:1::b5a:2 Boston Internet Exchange
103.26.68.96 MegaIX Sydney
2001:dea:0:10::60 MegaIX Sydney
185.1.114.18 MINAP Milan
2001:7f8:c5::a500:2906:1 MINAP Milan
74.200.144.78 MUS-IX
2607:f928:144::78 MUS-IX
74.200.144.79 MUS-IX
2607:f928:144::79 MUS-IX
103.27.168.128 DE-CIX Delhi
2400:d180:67::128 DE-CIX Delhi
103.27.168.185 DE-CIX Delhi
2400:d180:67::185 DE-CIX Delhi
194.88.240.35 INEX LAN2
2001:7f8:18:12::35 INEX LAN2
206.108.236.32 Boston Internet Exchange
2001:504:24:1::b5a:1 Boston Internet Exchange
37.49.237.50 France-IX Paris
2001:7f8:54::1:50 France-IX Paris
193.178.185.80 BCIX
2001:7f8:19:1::b5a:1 BCIX
193.201.28.76 Namex Rome
2001:7f8:10::2906 Namex Rome
193.201.28.94 Namex Rome
2001:7f8:10::b:2906 Namex Rome
202.77.88.50 EdgeIX - Sydney
2001:df0:680:5::32 EdgeIX - Sydney
206.82.104.122 DE-CIX New York
2001:504:36::b5a:0:2 DE-CIX New York
206.82.104.81 DE-CIX New York
2001:504:36::b5a:0:1 DE-CIX New York
5.57.80.229 LONAP
2001:7f8:17::b5a:1 LONAP
202.77.88.49 EdgeIX - Sydney
2001:df0:680:5::31 EdgeIX - Sydney
91.206.52.85 SwissIX
2001:7f8:24::55 SwissIX
185.1.186.7 MIX Palermo
2001:7f8:101:7::7 MIX Palermo
62.69.146.35 MegaIX Frankfurt
2001:7f8:8:20:0:b5a:0:2 MegaIX Frankfurt
62.69.146.34 MegaIX Frankfurt
2001:7f8:8:20:0:b5a:0:1 MegaIX Frankfurt
198.32.195.66 NWAX
2620:124:2000::66 NWAX
198.32.195.56 NWAX
2620:124:2000::56 NWAX
185.1.192.116 DE-CIX Madrid
2001:7f8:a0::b5a:0:2 DE-CIX Madrid
185.1.192.26 DE-CIX Madrid
2001:7f8:a0::b5a:0:1 DE-CIX Madrid
192.121.80.33 STHIX - Stockholm
2001:7f8:3e:0:a500:0:2906:2 STHIX - Stockholm
196.223.21.120 KIXP - Nairobi
2001:43f8:60:1::120 KIXP - Nairobi
142.215.8.5 Equinix Rio de Janeiro
2001:504:0:a::2906:1 Equinix Rio de Janeiro
206.83.43.63 QCIX
2001:504:9b::63 QCIX
45.120.248.16 Extreme IX Delhi
2001:df2:1900:1::16 Extreme IX Delhi
45.120.248.28 Extreme IX Delhi
2001:df2:1900:1::28 Extreme IX Delhi
196.223.21.119 KIXP - Nairobi
2001:43f8:60:1::119 KIXP - Nairobi
192.203.154.54 APE
2001:7fa:4:c0cb::9a36 APE
192.203.154.53 APE
2001:7fa:4:c0cb::9a35 APE
142.215.8.6 Equinix Rio de Janeiro
2001:504:0:a::2906:2 Equinix Rio de Janeiro
206.83.43.74 QCIX
2001:504:9b::74 QCIX
192.121.80.237 STHIX - Stockholm
2001:7f8:3e:0:a500:0:2906:1 STHIX - Stockholm
194.116.96.90 TOP-IX
2001:7f8:23:ffff::90 TOP-IX
194.116.96.96 TOP-IX
2001:7f8:23:ffff::96 TOP-IX
103.77.108.144 Extreme IX Mumbai
2001:df2:1900:2::144 Extreme IX Mumbai
103.77.108.143 Extreme IX Mumbai
2001:df2:1900:2::143 Extreme IX Mumbai
194.9.117.87 MegaIX Berlin
2001:7f8:8:5:0:b5a:0:2 MegaIX Berlin
194.9.117.86 MegaIX Berlin
2001:7f8:8:5:0:b5a:0:1 MegaIX Berlin
185.1.102.43 Equinix Frankfurt
2001:7f8:bd::2906:1 Equinix Frankfurt
185.1.109.33 Equinix Dublin
2001:7f8:c3::2906:1 Equinix Dublin
194.53.172.32 BNIX
2001:7f8:26::a500:2906:2 BNIX
194.53.172.31 BNIX
2001:7f8:26::a500:2906:1 BNIX
2001:7f8:b2:0:724:0:2906:0 IXPlay Global Peers
2001:7f8:b2:0:724:0:2906:1 IXPlay Global Peers
206.108.114.31 TPAIX
2001:504:3c::31 TPAIX
193.110.224.32 FICIX 2 (Helsinki)
2001:7f8:7:1::2906:1 FICIX 2 (Helsinki)
185.1.90.91 IXPlay Global Peers
185.1.22.131 Equinix Madrid
2001:7f8:c6::2906:2 Equinix Madrid
223.31.200.7 AMS-IX Mumbai
2001:e48:44:100b:0:a500:2906:1 AMS-IX Mumbai
185.1.22.130 Equinix Madrid
2001:7f8:c6::2906:1 Equinix Madrid
103.156.182.38 NIXI Mumbai
2001:de8:1:1::87 NIXI Mumbai
103.156.182.36 NIXI Mumbai
2001:de8:1:1::88 NIXI Mumbai
185.1.90.15 IXPlay Global Peers
206.83.12.29 STLIX
2001:504:98::29 STLIX
194.42.48.97 Equinix Zurich
2001:7f8:c:8235:194:42:48:97 Equinix Zurich
218.100.44.143 MyIX
2001:de8:10::f5 MyIX
206.83.12.21 STLIX
2001:504:98::21 STLIX
195.42.145.45 Equinix Paris
2001:7f8:43::2906:1 Equinix Paris
185.1.109.3 Equinix Dublin
2001:7f8:c3::2906:2 Equinix Dublin
45.120.251.142 Extreme IX Chennai
2001:df2:1900:3::142 Extreme IX Chennai
45.120.251.141 Extreme IX Chennai
2001:df2:1900:3::141 Extreme IX Chennai
27.254.19.253 CSL Thai-IX Singapore
2404:b0:13:b::2906:1 CSL Thai-IX Singapore
194.42.48.106 Equinix Zurich
2001:7f8:c:8235:194:42:48:106 Equinix Zurich
195.42.145.229 Equinix Paris
2001:7f8:43::2906:2 Equinix Paris
185.1.104.55 Equinix London
2001:7f8:be::2906:1 Equinix London
185.1.104.56 Equinix London
2001:7f8:be::2906:2 Equinix London
185.1.102.56 Equinix Frankfurt
2001:7f8:bd::2906:2 Equinix Frankfurt
185.1.112.20 Equinix Amsterdam
2001:7f8:83::2906:1 Equinix Amsterdam
185.1.112.34 Equinix Amsterdam
2001:7f8:83::2906:2 Equinix Amsterdam
43.243.21.77 AKL-IX (Auckland NZ)
2001:7fa:11:6:0:b5a:0:2 AKL-IX (Auckland NZ)
43.243.21.76 AKL-IX (Auckland NZ)
2001:7fa:11:6:0:b5a:0:1 AKL-IX (Auckland NZ)
43.243.22.72 MegaIX Auckland
2001:dea:0:40::48 MegaIX Auckland
43.243.22.53 MegaIX Auckland
2001:dea:0:40::35 MegaIX Auckland
206.108.114.10 TPAIX
2001:504:3c::a TPAIX
193.239.118.79 NL-ix
2001:7f8:13::a500:2906:2 NL-ix
193.239.117.54 NL-ix
2001:7f8:13::a500:2906:1 NL-ix
212.91.0.208 THINX Warsaw
2001:7f8:60::2906:1 THINX Warsaw
EOF
}

# 运营商名称规范化函数
# 参数: $1 = 原始运营商名称
# 返回: 规范化后的运营商名称（通过echo）
normalize_isp_name() {
    local isp="$1"
    local isp_lower=$(echo "$isp" | tr '[:upper:]' '[:lower:]')
    
    # === 1. 中国运营商海外分支（必须优先匹配）===
    # 联通海外
    [[ "$isp" == *"联通"*"香港"* || "$isp" == *"联通（香港）"* || "$isp_lower" == *"unicom"*"hong kong"* ]] && { echo "中国联通（香港）"; return; }
    [[ "$isp_lower" == *"chinaunicomglobal"* || "$isp_lower" == *"china unicom global"* ]] && { echo "中国联通（国际）"; return; }
    # 电信海外
    [[ "$isp_lower" == *"ctgnet"* || "$isp_lower" == *"china telecom global"* ]] && { echo "中国电信（国际）"; return; }
    # 移动海外 (CMI = China Mobile International)
    [[ "$isp" == *"移动"*"CMI"* || "$isp" == *"移动 CMI"* || "$isp_lower" == *"cmi.chinamobile"* || "$isp_lower" == *"cmi-int"* || ( "$isp_lower" == *"cmi"* && "$isp_lower" == *"mobile"* ) ]] && { echo "中国移动（国际）"; return; }
    
    # === 2. 港澳运营商 ===
    [[ "$isp" == *"电讯盈科"* || "$isp_lower" == *"pccw"* ]] && { echo "PCCW"; return; }
    [[ "$isp" == *"和记"* || "$isp_lower" == *"hgc"* || "$isp_lower" == *"hutchison"* ]] && { echo "HGC"; return; }
    # 中国移动香港变体
    [[ "$isp" == *"中国移动"*"香港"* || "$isp" == *"中国移动（香港）"* ]] && { echo "中国移动（香港）"; return; }
    [[ "$isp_lower" == *"cmi"* && "$isp_lower" == *"hong kong"* ]] && { echo "中国移动（香港）"; return; }
    
    # === 3. 中国三大运营商（国内，通配符匹配）===
    [[ "$isp" == *"联通"* || "$isp_lower" == *"unicom"* || "$isp_lower" == *"bbn.com.cn"* || "$isp_lower" == *"cuii"* ]] && [[ "$isp" != *"中国联通"* ]] && { echo "中国联通"; return; }
    [[ "$isp" == *"电信"* || "$isp_lower" == *"chinatelecom"* || "$isp_lower" == *"189.cn"* || "$isp_lower" == *"cn2"* || ( "$isp_lower" == *"telecom"* && "$isp_lower" == *"china"* ) ]] && [[ "$isp" != *"中国电信"* ]] && { echo "中国电信"; return; }
    [[ "$isp" == *"移动"* || "$isp_lower" == *"chinamobile"* || "$isp_lower" == *"10086"* || ( "$isp_lower" == *"mobile"* && "$isp_lower" == *"china"* ) ]] && [[ "$isp" != *"中国移动"* ]] && { echo "中国移动"; return; }
    [[ "$isp" == *"地面通"* ]] && { echo "中国电信"; return; }
    # 清理中国运营商特殊后缀
    [[ "$isp" == "中国电信/骨干网" ]] && { echo "中国电信"; return; }
    [[ "$isp" == "中国电信/CN2" ]] && { echo "中国电信/CN2"; return; }
    [[ "$isp" == "中国联通/骨干网" ]] && { echo "中国联通"; return; }
    # 中国移动国际统一格式
    [[ "$isp" == "中国移动国际" ]] && { echo "中国移动（国际）"; return; }
    
    # === 4. 国际运营商 ===
    [[ "$isp_lower" == *"google"* || "$isp" == *"谷歌"* ]] && { echo "Google"; return; }
    [[ "$isp_lower" == *"misaka"* ]] && { echo "Misaka"; return; }
    [[ "$isp_lower" == *"lumen"* || "$isp_lower" == *"level 3"* || "$isp_lower" == *"level3"* || "$isp" == *"世纪互联"* || "$isp" == *"流明"* ]] && { echo "Lumen"; return; }
    [[ "$isp_lower" == *"cogent"* || "$isp_lower" == *"psinet"* ]] && { echo "Cogent"; return; }
    [[ "$isp_lower" == *"zayo"* ]] && { echo "Zayo"; return; }
    [[ "$isp_lower" == *"joint transit"* ]] && { echo "Joint Transit"; return; }
    [[ "$isp_lower" == *"broadband hosting"* ]] && { echo "Broadband Hosting"; return; }
    [[ "$isp_lower" == *"pch"* ]] && { echo "PCH"; return; }
    [[ "$isp_lower" == *"myloc"* ]] && { echo "myLoc"; return; }
    [[ "$isp_lower" == *"wiit.cloud"* ]] && { echo "WIIT"; return; }
    [[ "$isp_lower" == *"lwlcom"* ]] && { echo "LWLcom"; return; }
    [[ "$isp_lower" == *"tinet"* || "$isp_lower" == *"gtt"* ]] && { echo "GTT"; return; }
    [[ "$isp_lower" == *"arelion"* ]] && { echo "Arelion"; return; }
    [[ "$isp_lower" == *"telia"* || "$isp" == *"特利亚"* ]] && { echo "Telia"; return; }
    [[ "$isp_lower" == "provider" ]] && { echo "Telia"; return; }
    [[ "$isp_lower" == *"sparkle"* || "$isp_lower" == *"sea-bone"* || "$isp_lower" == *"tisparkle"* ]] && { echo "Sparkle"; return; }
    [[ "$isp_lower" == *"orange"* || "$isp_lower" == *"france telecom"* || "$isp_lower" == *"oinis"* ]] && { echo "Orange"; return; }
    [[ "$isp_lower" == *"leaseweb"* ]] && { echo "Leaseweb"; return; }
    [[ "$isp_lower" == *"ntt"* || "$isp" == *"日本电报电话"* || "$isp" == *"恩梯梯"* ]] && { echo "NTT"; return; }
    [[ "$isp_lower" == *"tata"* || "$isp" == *"塔塔"* || "$isp_lower" == *"teleglobe"* || "$isp_lower" == *"customers access"* || "$isp_lower" == *"bb internal"* ]] && { echo "Tata"; return; }
    [[ "$isp_lower" == *"hurricane"* || "$isp_lower" == *"he.net"* ]] && { echo "HE"; return; }
    [[ "$isp_lower" == *"cdn77"* ]] && { echo "CDN77"; return; }
    [[ "$isp_lower" == *"readydedis"* ]] && { echo "ReadyDedis"; return; }
    [[ "$isp_lower" == *"host universal"* || "$isp_lower" == *"hostuniversal"* ]] && { echo "HostUniversal"; return; }
    [[ "$isp_lower" == *"retn"* ]] && { echo "RETN"; return; }
    [[ "$isp_lower" == *"equinix"* ]] && { echo "Equinix"; return; }
    [[ "$isp_lower" == *"ipxo"* ]] && { echo "IPXO"; return; }
    [[ "$isp_lower" == *"agis"* || "$isp_lower" == *"gsl networks"* || "$isp_lower" == *"globalsecurelayer"* || "$isp_lower" == *"streamline servers"* ]] && { echo "GSL"; return; }
    [[ "$isp_lower" == *"fastly"* ]] && { echo "Fastly"; return; }
    [[ "$isp_lower" == *"obenet"* || "$isp_lower" == *"obe.net"* || "$isp_lower" == *"obenetwork"* || "$isp_lower" == *"obe infrastructure"* ]] && { echo "Obenet"; return; }
    [[ "$isp_lower" == *"clouvider"* ]] && { echo "Clouvider"; return; }
    [[ "$isp_lower" == *"eranium"* ]] && { echo "Eranium"; return; }
    [[ "$isp_lower" == *"edgoo"* ]] && { echo "Edgoo"; return; }
    [[ "$isp_lower" == *"sprint"* ]] && { echo "Sprint"; return; }
    [[ "$isp_lower" == *"xtom"* ]] && { echo "xTom"; return; }
    [[ "$isp_lower" == *"airband"* ]] && { echo "Airband"; return; }
    [[ "$isp_lower" == *"pccw"* && "$isp" != "PCCW" ]] && { echo "PCCW"; return; }
    
    # === 5. 日本运营商 ===
    [[ "$isp_lower" == *"gmo"* || "$isp_lower" == *"internet.gmo"* ]] && { echo "GMO Internet"; return; }
    [[ "$isp_lower" == *"biglobe"* ]] && { echo "Biglobe"; return; }
    [[ "$isp_lower" == *"kddi"* || "$isp" == *"凯迪迪爱"* || "$isp" == *"日本凯迪迪爱"* || "$isp_lower" == *"dion"* ]] && { echo "KDDI"; return; }
    [[ "$isp_lower" == *"arteria"* || "$isp_lower" == *"arteria-net"* ]] && { echo "ARTERIA"; return; }
    [[ "$isp_lower" == *"softbank"* || "$isp" == *"软银"* ]] && { echo "SoftBank"; return; }
    [[ "$isp_lower" == *"ntt communications"* || "$isp_lower" == *"ntt com"* || "$isp_lower" == *"ocn"* ]] && { echo "NTT"; return; }
    [[ "$isp_lower" == *"iij"* || "$isp_lower" == *"internet initiative japan"* ]] && { echo "IIJ"; return; }
    [[ "$isp_lower" == *"sakura"* ]] && { echo "Sakura"; return; }
    [[ "$isp" == *"日本网络信息中心"* || "$isp_lower" == *"jpnic"* || "$isp_lower" == *"japan network information"* ]] && { echo "JPNIC"; return; }
    
    # === 6. 云厂商与服务商 ===
    [[ "$isp_lower" == *"amazon"* || "$isp" == *"亚马逊"* ]] && { echo "AWS"; return; }
    [[ "$isp_lower" == *"cloudflare"* ]] && { echo "Cloudflare"; return; }
    [[ "$isp_lower" == *"quad9"* ]] && { echo "Quad9"; return; }
    [[ "$isp_lower" == *"telegram"* ]] && { echo "Telegram"; return; }
    [[ "$isp_lower" == *"netflix"* ]] && { echo "Netflix"; return; }
    [[ "$isp_lower" == *"vultr"* || "$isp_lower" == *"constant.com"* || "$isp_lower" == *"as-vultr"* || "$isp_lower" == *"choopa"* ]] && { echo "Vultr"; return; }
    [[ "$isp_lower" == *"servers.com"* ]] && { echo "Servers.com"; return; }
    [[ "$isp_lower" == *"workonline"* ]] && { echo "Workonline"; return; }
    [[ "$isp_lower" == *"verio"* ]] && { echo "NTT"; return; }
    [[ "$isp_lower" == *"sg.gs"* ]] && { echo "SG.GS"; return; }
    [[ "$isp" == *"阿里云"* || "$isp_lower" == *"alibaba"* || "$isp_lower" == *"aliyun"* ]] && { echo "阿里云"; return; }
    [[ "$isp" == *"腾讯"* || "$isp_lower" == *"tencent"* ]] && { echo "腾讯云"; return; }
    [[ "$isp" == *"华为"* || "$isp_lower" == *"huawei"* || "$isp_lower" == *"hwclouds"* ]] && { echo "华为云"; return; }
    [[ "$isp" == *"优刻得"* || "$isp_lower" == *"ucloud"* ]] && { echo "优刻得"; return; }
    [[ "$isp" == *"百度"* || "$isp_lower" == *"baidu"* || "$isp_lower" == *"bce"* ]] && { echo "百度云"; return; }
    [[ "$isp" == *"京东"* || "$isp_lower" == *"jdcloud"* || "$isp_lower" == *"jd cloud"* ]] && { echo "京东云"; return; }
    [[ "$isp" == *"金山"* || "$isp_lower" == *"kingsoft"* || "$isp_lower" == *"ksyun"* ]] && { echo "金山云"; return; }
    [[ "$isp" == *"七牛"* || "$isp_lower" == *"qiniu"* ]] && { echo "七牛"; return; }
    [[ "$isp" == *"又拍"* || "$isp_lower" == *"upyun"* ]] && { echo "又拍云"; return; }
    [[ "$isp" == *"网宿"* || "$isp_lower" == *"wangsu"* || "$isp_lower" == *"chinanetcenter"* ]] && { echo "网宿"; return; }
    [[ "$isp_lower" == *"corenet"* ]] && { echo "CoreNet"; return; }
    [[ "$isp_lower" == *"mejiro"* ]] && { echo "Mejiro"; return; }
    [[ "$isp_lower" == *"nexthop"* ]] && { echo "NextHop"; return; }
    [[ "$isp_lower" == *"digitalocean"* || "$isp_lower" == *"digital ocean"* ]] && { echo "DigitalOcean"; return; }
    [[ "$isp_lower" == *"linode"* || "$isp_lower" == *"akamai"* ]] && { echo "Akamai"; return; }
    [[ "$isp_lower" == *"ovh"* ]] && { echo "OVH"; return; }
    [[ "$isp_lower" == *"hetzner"* ]] && { echo "Hetzner"; return; }
    [[ "$isp_lower" == *"scaleway"* || "$isp_lower" == *"iliad"* ]] && { echo "Scaleway"; return; }
    [[ "$isp_lower" == *"rackspace"* ]] && { echo "Rackspace"; return; }
    [[ "$isp_lower" == *"oracle"* ]] && { echo "Oracle"; return; }
    [[ "$isp_lower" == *"microsoft"* || "$isp_lower" == *"azure"* ]] && { echo "Azure"; return; }
    [[ "$isp_lower" == *"ibm"* || "$isp_lower" == *"softlayer"* ]] && { echo "IBM Cloud"; return; }
    [[ "$isp_lower" == *"verizon"* || "$isp_lower" == *"ans communications"* || "$isp_lower" == *"mci"* || "$isp" == *"威瑞森"* || "$isp" == *"MCI通信"* ]] && { echo "Verizon"; return; }
    [[ "$isp_lower" == *"att"* || "$isp_lower" == *"at&t"* ]] && { echo "AT&T"; return; }
    [[ "$isp_lower" == *"comcast"* ]] && { echo "Comcast"; return; }
    [[ "$isp_lower" == *"centurylink"* ]] && { echo "CenturyLink"; return; }
    [[ "$isp_lower" == *"charter"* || "$isp_lower" == *"spectrum"* ]] && { echo "Charter"; return; }
    [[ "$isp_lower" == *"singtel"* ]] && { echo "Singtel"; return; }
    [[ "$isp_lower" == *"starhub"* ]] && { echo "StarHub"; return; }
    [[ "$isp_lower" == *"m1 limited"* || "$isp_lower" == *"m1.com.sg"* ]] && { echo "M1"; return; }
    [[ "$isp_lower" == *"telstra"* ]] && { echo "Telstra"; return; }
    [[ "$isp_lower" == *"optus"* ]] && { echo "Optus"; return; }
    [[ "$isp_lower" == *"vodafone"* || "$isp" == *"沃达丰"* ]] && { echo "Vodafone"; return; }
    [[ "$isp_lower" == *"deutsche telekom"* || "$isp_lower" == *"dtag"* || "$isp_lower" == *"wholesale.telekom"* ]] && { echo "DTAG"; return; }
    [[ "$isp_lower" == *"british telecom"* || "$isp_lower" == *"bt.net"* ]] && { echo "BT"; return; }
    [[ "$isp_lower" == *"internet utilities"* ]] && { echo "Internet Utilities"; return; }
    [[ "$isp_lower" == *"telefonica"* || "$isp_lower" == *"movistar"* ]] && { echo "Telefonica"; return; }
    [[ "$isp_lower" == *"cht"* || "$isp" == *"中华电信"* || "$isp_lower" == *"hinet"* || "$isp_lower" == *"chunghwa"* ]] && { echo "中华电信"; return; }
    [[ "$isp_lower" == *"taiwan mobile"* || "$isp" == *"台湾大哥大"* ]] && { echo "台湾大哥大"; return; }
    [[ "$isp_lower" == *"fetnet"* || "$isp" == *"远传"* ]] && { echo "远传电信"; return; }
    [[ "$isp_lower" == *"kt corp"* || "$isp_lower" == *"korea telecom"* ]] && { echo "KT"; return; }
    [[ "$isp_lower" == *"sk broadband"* || "$isp_lower" == *"sk telecom"* ]] && { echo "SK"; return; }
    [[ "$isp_lower" == *"lg uplus"* || "$isp_lower" == *"lg u+"* ]] && { echo "LG U+"; return; }
    
    # === 7. 越南运营商 ===
    [[ "$isp_lower" == *"fpt"* || "$isp_lower" == *"fpt telecom"* ]] && { echo "FPT"; return; }
    [[ "$isp" == *"越南互联网络信息中心"* || "$isp_lower" == *"vnnic"* ]] && { echo "VNNIC"; return; }
    [[ "$isp_lower" == *"viettel"* ]] && { echo "Viettel"; return; }
    [[ "$isp_lower" == *"vnpt"* ]] && { echo "VNPT"; return; }
    [[ "$isp_lower" == *"mobifone"* ]] && { echo "MobiFone"; return; }
    
    # === 8. 欧洲托管与运营商 ===
    [[ "$isp_lower" == *"ghostnet"* ]] && { echo "GHOSTnet"; return; }
    [[ "$isp_lower" == *"tube-hosting"* || "$isp_lower" == *"ferdinand zink"* ]] && { echo "Tube-Hosting"; return; }
    [[ "$isp_lower" == *"skylink data center"* ]] && { echo "SkyLink DC"; return; }
    [[ "$isp_lower" == *"global network management"* ]] && { echo "GNM"; return; }
    [[ "$isp_lower" == *"ghita telekom"* ]] && { echo "Ghita Telekom"; return; }
    [[ "$isp_lower" == *"mss-povolzhe"* ]] && { echo "MSS-Povolzhe"; return; }
    [[ "$isp_lower" == *"contabo"* ]] && { echo "Contabo"; return; }
    [[ "$isp_lower" == *"netcup"* ]] && { echo "Netcup"; return; }
    [[ "$isp_lower" == *"ionos"* || "$isp_lower" == *"1&1"* ]] && { echo "IONOS"; return; }
    [[ "$isp_lower" == *"online.net"* || "$isp_lower" == *"online s.a.s"* ]] && { echo "Online.net"; return; }
    [[ "$isp_lower" == *"swisscom"* ]] && { echo "Swisscom"; return; }
    [[ "$isp_lower" == *"proximus"* || "$isp_lower" == *"belgacom"* ]] && { echo "Proximus"; return; }
    [[ "$isp_lower" == *"kpn"* ]] && { echo "KPN"; return; }
    [[ "$isp_lower" == *"telenor"* ]] && { echo "Telenor"; return; }
    [[ "$isp_lower" == *"tele2"* ]] && { echo "Tele2"; return; }
    [[ "$isp_lower" == *"free.fr"* || "$isp_lower" == *"freebox"* ]] && { echo "Free"; return; }
    [[ "$isp_lower" == *"sfr"* ]] && { echo "SFR"; return; }
    [[ "$isp_lower" == *"bouygues"* ]] && { echo "Bouygues"; return; }
    [[ "$isp_lower" == *"jose antonio vazquez quian"* || "$isp_lower" == *"andaina"* ]] && { echo "Andaina"; return; }
    [[ "$isp_lower" == *"r cable"* ]] && { echo "R Cable"; return; }
    [[ "$isp_lower" == *"i3d.net"* || "$isp_lower" == *"i3d net"* ]] && { echo "i3D.net"; return; }
    
    # === 9. 俄罗斯运营商 ===
    [[ "$isp_lower" == *"rostelecom"* ]] && { echo "Rostelecom"; return; }
    [[ "$isp_lower" == *"mts"* ]] && { echo "MTS"; return; }
    [[ "$isp_lower" == *"beeline"* || "$isp_lower" == *"vimpelcom"* ]] && { echo "Beeline"; return; }
    [[ "$isp_lower" == *"megafon"* ]] && { echo "MegaFon"; return; }
    [[ "$isp_lower" == *"yandex"* ]] && { echo "Yandex"; return; }
    [[ "$isp_lower" == *"mail.ru"* || "$isp_lower" == *"vk.com"* ]] && { echo "VK"; return; }
    
    # === 10. 其他亚洲运营商 ===
    [[ "$isp_lower" == *"pldt"* ]] && { echo "PLDT"; return; }
    [[ "$isp_lower" == *"globe"* && "$isp_lower" == *"philippines"* ]] && { echo "Globe"; return; }
    [[ "$isp_lower" == *"true"* && "$isp_lower" == *"thailand"* ]] && { echo "True"; return; }
    [[ "$isp_lower" == *"ais"* || "$isp_lower" == *"advanced info service"* ]] && { echo "AIS"; return; }
    [[ "$isp_lower" == *"telekom malaysia"* || "$isp_lower" == *"tm net"* ]] && { echo "TM"; return; }
    [[ "$isp_lower" == *"maxis"* ]] && { echo "Maxis"; return; }
    [[ "$isp_lower" == *"indosat"* ]] && { echo "Indosat"; return; }
    [[ "$isp_lower" == *"telkomsel"* ]] && { echo "Telkomsel"; return; }
    [[ "$isp_lower" == *"xl axiata"* ]] && { echo "XL Axiata"; return; }
    [[ "$isp_lower" == *"bsnl"* || "$isp_lower" == *"bharat sanchar"* ]] && { echo "BSNL"; return; }
    [[ "$isp_lower" == *"jio"* || "$isp_lower" == *"reliance"* ]] && { echo "Jio"; return; }
    [[ "$isp_lower" == *"airtel"* ]] && { echo "Airtel"; return; }
    
    # === 11. CDN 与托管服务 ===
    [[ "$isp_lower" == *"bunny"* || "$isp_lower" == *"bunnycdn"* ]] && { echo "BunnyCDN"; return; }
    [[ "$isp_lower" == *"stackpath"* || "$isp_lower" == *"highwinds"* ]] && { echo "StackPath"; return; }
    [[ "$isp_lower" == *"keycdn"* ]] && { echo "KeyCDN"; return; }
    [[ "$isp_lower" == *"sucuri"* ]] && { echo "Sucuri"; return; }
    [[ "$isp_lower" == *"incapsula"* || "$isp_lower" == *"imperva"* ]] && { echo "Imperva"; return; }
    [[ "$isp_lower" == *"ddos-guard"* ]] && { echo "DDoS-Guard"; return; }
    [[ "$isp_lower" == *"path.net"* ]] && { echo "Path.net"; return; }
    [[ "$isp_lower" == *"quadranet"* ]] && { echo "QuadraNet"; return; }
    [[ "$isp_lower" == *"psychz"* ]] && { echo "Psychz"; return; }
    [[ "$isp_lower" == *"colocrossing"* ]] && { echo "ColoCrossing"; return; }
    [[ "$isp_lower" == *"hostwinds"* ]] && { echo "Hostwinds"; return; }
    [[ "$isp_lower" == *"kamatera"* ]] && { echo "Kamatera"; return; }
    [[ "$isp_lower" == *"upcloud"* ]] && { echo "UpCloud"; return; }
    [[ "$isp_lower" == *"bandwagonhost"* || "$isp_lower" == *"buyvm"* || "$isp_lower" == *"frantech"* ]] && { echo "BuyVM"; return; }
    [[ "$isp_lower" == *"racknerd"* ]] && { echo "RackNerd"; return; }
    [[ "$isp_lower" == *"greencloud"* ]] && { echo "GreenCloud"; return; }
    [[ "$isp_lower" == *"dmit"* ]] && { echo "DMIT"; return; }
    [[ "$isp_lower" == *"hostdare"* ]] && { echo "HostDare"; return; }
    [[ "$isp_lower" == *"b2 net solutions"* || "$isp_lower" == *"servermania"* ]] && { echo "ServerMania"; return; }
    [[ "$isp_lower" == *"multacom"* ]] && { echo "Multacom"; return; }
    [[ "$isp_lower" == *"cnservers"* ]] && { echo "CNServers"; return; }
    [[ "$isp_lower" == *"terrahost"* ]] && { echo "Terrahost"; return; }
    [[ "$isp_lower" == *"hosteons"* ]] && { echo "Hosteons"; return; }
    [[ "$isp_lower" == *"cloudcone"* ]] && { echo "CloudCone"; return; }
    [[ "$isp_lower" == *"virtono"* ]] && { echo "Virtono"; return; }
    [[ "$isp_lower" == *"crowncloud"* ]] && { echo "CrownCloud"; return; }
    [[ "$isp_lower" == *"ssdnodes"* ]] && { echo "SSD Nodes"; return; }
    [[ "$isp_lower" == *"webtropia"* ]] && { echo "Netcup"; return; }
    [[ "$isp_lower" == *"melbicom"* ]] && { echo "Melbicom"; return; }
    
    # 如果没有匹配，返回原始值
    echo "$isp"
}

get_trace_targets() {
cat << 'EOF'
#GROUP:中国境内目标
北京电信 163 AS4134|ipv4.pek-4134.endpoint.nxtrace.org|ipv6.pek-4134.endpoint.nxtrace.org
北京电信 CN2 AS4809|ipv4.pek-4809.endpoint.nxtrace.org|
北京联通 169 AS4837|ipv4.pek-4837.endpoint.nxtrace.org|ipv6.pek-4837.endpoint.nxtrace.org
北京联通 A网(CNC) AS9929|ipv4.pek-9929.endpoint.nxtrace.org|
北京移动 CMNET AS9808|ipv4.pek-9808.endpoint.nxtrace.org|ipv6.pek-9808.endpoint.nxtrace.org
北京移动 CMIN2 AS58807|ipv4.pek-58807.endpoint.nxtrace.org|
上海电信 163 AS4134|ipv4.sha-4134.endpoint.nxtrace.org|ipv6.sha-4134.endpoint.nxtrace.org
上海电信 CN2 AS4809|ipv4.sha-4809.endpoint.nxtrace.org|
上海联通 169 AS4837|ipv4.sha-4837.endpoint.nxtrace.org|ipv6.sha-4837.endpoint.nxtrace.org
上海联通 A网(CNC) AS9929|ipv4.sha-9929.endpoint.nxtrace.org|ipv6.sha-9929.endpoint.nxtrace.org
上海移动 CMNET AS9808|ipv4.sha-9808.endpoint.nxtrace.org|ipv6.sha-9808.endpoint.nxtrace.org
上海移动 CMIN2 AS58807|ipv4.sha-58807.endpoint.nxtrace.org|
广州电信 163 AS4134|ipv4.can-4134.endpoint.nxtrace.org|ipv6.can-4134.endpoint.nxtrace.org
广州电信 CN2 AS4809|ipv4.can-4809.endpoint.nxtrace.org|
广州联通 169 AS4837|ipv4.can-4837.endpoint.nxtrace.org|ipv6.can-4837.endpoint.nxtrace.org
广州联通 A网(CNC) AS9929|ipv4.can-9929.endpoint.nxtrace.org|
广州移动 CMNET AS9808|ipv4.can-9808.endpoint.nxtrace.org|ipv6.can-9808.endpoint.nxtrace.org
广州移动 CMIN2 AS58807|ipv4.can-58807.endpoint.nxtrace.org|
#GROUP:主要国际网络运营商
Telegram DC5 - Singapore, SG|telegram-dc5.jam114514.me|
Telegram DC4 - Amsterdam, NL|telegram-dc4.jam114514.me|
Telegram DC3 - Miami FL, USA|telegram-dc3.jam114514.me|
Telegram DC2 - Amsterdam, NL|telegram-dc2.jam114514.me|
Telegram DC1 - Miami FL, USA|telegram-dc1.jam114514.me|
AWS 美国加利福尼亚州洛杉矶|aws.us.lax.jam114514.me|aws.us.lax.ipv6.jam114514.me
AWS 美国弗吉尼亚州阿什本|aws.us.iad.jam114514.me|aws.us.iad.ipv6.jam114514.me
AWS 德国黑森州美因河畔法兰克福|aws.de.fra.jam114514.me|aws.de.fra.ipv6.jam114514.me
AWS 新加坡|aws.sg.sgp.jam114514.me|aws.sg.sgp.ipv6.jam114514.me
GCP 美国加利福尼亚州洛杉矶|35.235.110.103|
GCP 美国弗吉尼亚州阿什本|35.221.4.19|
GCP 德国黑森州美因河畔法兰克福|34.40.56.112|
GCP 新加坡|35.187.238.97|
Cogent Communications AS174 - 德国法兰克福|t1.174.de.fra.jam114514.me|t1.174.de.fra.ipv6.jam114514.me
Cogent Communications AS174 - 新加坡|t1.174.sg.sin.jam114514.me|t1.174.sg.sin.ipv6.jam114514.me
Cogent Communications AS174 - 美国洛杉矶|t1.174.us.lax.jam114514.me|t1.174.us.lax.ipv6.jam114514.me
Cogent Communications AS174 - 美国纽约|t1.174.us.nyc.jam114514.me|t1.174.us.nyc.ipv6.jam114514.me
Telia Carrier AS1299 - 德国法兰克福|t1.1299.de.fra.jam114514.me|t1.1299.de.fra.ipv6.jam114514.me
Telia Carrier AS1299 - 新加坡|t1.1299.sg.sin.jam114514.me|t1.1299.sg.sin.ipv6.jam114514.me
Telia Carrier AS1299 - 美国洛杉矶|t1.1299.us.lax.jam114514.me|t1.1299.us.lax.ipv6.jam114514.me
Telia Carrier AS1299 - 美国纽约|t1.1299.us.nyc.jam114514.me|t1.1299.us.nyc.ipv6.jam114514.me
NTT Communications AS2914 - 德国法兰克福|t1.2914.de.fra.jam114514.me|t1.2914.de.fra.ipv6.jam114514.me
NTT Communications AS2914 - 新加坡|t1.2914.sg.sin.jam114514.me|t1.2914.sg.sin.ipv6.jam114514.me
NTT Communications AS2914 - 美国洛杉矶|t1.2914.us.lax.jam114514.me|t1.2914.us.lax.ipv6.jam114514.me
NTT Communications AS2914 - 美国纽约|t1.2914.us.nyc.jam114514.me|t1.2914.us.nyc.ipv6.jam114514.me
GTT Communications AS3257 - 德国法兰克福|t1.3257.de.fra.jam114514.me|t1.3257.de.fra.ipv6.jam114514.me
GTT Communications AS3257 - 新加坡|t1.3257.sg.sin.jam114514.me|t1.3257.sg.sin.ipv6.jam114514.me
GTT Communications AS3257 - 美国洛杉矶|t1.3257.us.lax.jam114514.me|t1.3257.us.lax.ipv6.jam114514.me
GTT Communications AS3257 - 美国纽约|t1.3257.us.nyc.jam114514.me|t1.3257.us.nyc.ipv6.jam114514.me
Level 3 / Lumen AS3356 - 德国法兰克福|t1.3356.de.fra.jam114514.me|
Level 3 / Lumen AS3356 - 新加坡|t1.3356.sg.sin.jam114514.me|
Level 3 / Lumen AS3356 - 美国洛杉矶|t1.3356.us.lax.jam114514.me|
Level 3 / Lumen AS3356 - 美国纽约|t1.3356.us.nyc.jam114514.me|
PCCW Global AS3491 - 德国法兰克福|t1.3491.de.fra.jam114514.me|t1.3491.de.fra.ipv6.jam114514.me
PCCW Global AS3491 - 新加坡|t1.3491.sg.sin.jam114514.me|t1.3491.sg.sin.ipv6.jam114514.me
PCCW Global AS3491 - 美国纽约|t1.3491.us.nyc.jam114514.me|t1.3491.us.nyc.ipv6.jam114514.me
PCCW Global AS3491 - 美国圣何塞|t1.3491.us.sjc.jam114514.me|
Orange AS5511 - 德国法兰克福|t1.5511.de.fra.jam114514.me|t1.5511.de.fra.ipv6.jam114514.me
Orange AS5511 - 新加坡|t1.5511.sg.sin.jam114514.me|t1.5511.sg.sin.ipv6.jam114514.me
Orange AS5511 - 美国洛杉矶|t1.5511.us.lax.jam114514.me|t1.5511.us.lax.ipv6.jam114514.me
Orange AS5511 - 美国纽约|t1.5511.us.nyc.jam114514.me|t1.5511.us.nyc.ipv6.jam114514.me
TATA Communications AS6453 - 德国法兰克福|t1.6453.de.fra.jam114514.me|t1.6453.de.fra.ipv6.jam114514.me
TATA Communications AS6453 - 新加坡|t1.6453.sg.sin.jam114514.me|t1.6453.sg.sin.ipv6.jam114514.me
TATA Communications AS6453 - 美国洛杉矶|t1.6453.us.lax.jam114514.me|t1.6453.us.lax.ipv6.jam114514.me
TATA Communications AS6453 - 美国纽约|t1.6453.us.nyc.jam114514.me|t1.6453.us.nyc.ipv6.jam114514.me
Zayo AS6461 - 德国法兰克福|t1.6461.de.fra.jam114514.me|
Zayo AS6461 - 新加坡|t1.6461.sg.sin.jam114514.me|t1.6461.sg.sin.ipv6.jam114514.me
Zayo AS6461 - 美国洛杉矶|t1.6461.us.lax.jam114514.me|t1.6461.us.lax.ipv6.jam114514.me
Zayo AS6461 - 美国纽约|t1.6461.us.nyc.jam114514.me|t1.6461.us.nyc.ipv6.jam114514.me
Telecom Italia Sparkle AS6762 - 德国法兰克福|t1.6762.de.fra.jam114514.me|t1.6762.de.fra.ipv6.jam114514.me
Telecom Italia Sparkle AS6762 - 新加坡|t1.6762.sg.sin.jam114514.me|t1.6762.sg.sin.ipv6.jam114514.me
Telecom Italia Sparkle AS6762 - 美国洛杉矶|t1.6762.us.lax.jam114514.me|t1.6762.us.lax.ipv6.jam114514.me
Telecom Italia Sparkle AS6762 - 美国纽约|t1.6762.us.nyc.jam114514.me|t1.6762.us.nyc.ipv6.jam114514.me

EOF
}

run_trace_test() {
    local public_only="${1:-false}"  # 如果传入 "public_only"，则只测公共服务
    
    if [ "$public_only" = "public_only" ]; then
        log "开始公共服务路由追踪..."
    else
        log "开始路由追踪测试..."
    fi
    
    # 调试信息
    # log "NextTrace Binary: $NEXTTRACE_BIN"
    
    if [ "$NEXTTRACE_BIN" == "false" ] || [ -z "$NEXTTRACE_BIN" ]; then 
        warn "  └─ NextTrace 二进制未找到或下载失败，跳过"; 
        return; 
    fi
    
    if [ ! -x "$NEXTTRACE_BIN" ] && ! command -v "$NEXTTRACE_BIN" >/dev/null 2>&1; then
        warn "  └─ NextTrace ($NEXTTRACE_BIN) 不可执行，跳过";
        return;
    fi
    
    create_ix_map
    
    echo "  ├─ 获取动态 CDN 节点..."
    local dynamic_targets=""
    if [ "$YTDLP_BIN" != "false" ] && [ -x "$YTDLP_BIN" ]; then
        # Try using "Me at the zoo" (jNQXAC9IVRw) and Android client to bypass bot detection
        local yt_video="https://www.youtube.com/watch?v=jNQXAC9IVRw"
        local yt_args="--no-warnings --extractor-args youtube:player_client=android -g"
        
        if [ "$HAS_V4" = "true" ]; then
            # Debug: Capture stderr to see why it fails
            local yt_err="$TMP_DIR/yt_v4.err"
            v4=$("$YTDLP_BIN" $yt_args -4 "$yt_video" 2>"$yt_err" | head -n1 | awk -F/ '{print $3}')
            if [ -n "$v4" ]; then
                 dynamic_targets+="YouTube CDN (Dynamic)|$v4|"$'\n'
            else
                 # If failed, print warning with error content
                 local err_msg=$(cat "$yt_err" | tr '\n' ' ' | cut -c 1-100)
                 warn "  │  └─ YouTube (IPv4) 获取失败: $err_msg"
            fi
            rm -f "$yt_err"
        fi
        if [ "$HAS_V6" = "true" ]; then
            local yt_err="$TMP_DIR/yt_v6.err"
            v6=$("$YTDLP_BIN" $yt_args -6 "$yt_video" 2>"$yt_err" | head -n1 | awk -F/ '{print $3}')
            if [ -n "$v6" ]; then
                dynamic_targets+="YouTube CDN (Dynamic)||$v6"$'\n'
            else
                 local err_msg=$(cat "$yt_err" | tr '\n' ' ' | cut -c 1-100)
                 warn "  │  └─ YouTube (IPv6) 获取失败: $err_msg"
            fi
            rm -f "$yt_err"
        fi
    else
        warn "  │  └─ yt-dlp 未安装或不可执行，跳过 YouTube 测试"
    fi
    # Netflix (Fast.com) - simplified
    local nf_api="https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=5"
    if [ "$HAS_V4" = "true" ]; then 
        local nf=$(curl -s -4 "$nf_api" 2>/dev/null | jq -r '.targets[]|select(.url|contains("ipv4"))|.url' 2>/dev/null | head -n1 | awk -F/ '{print $3}')
        [ -n "$nf" ] && dynamic_targets+="Netflix CDN (Dynamic)|$nf|"$'\n'
    fi
    if [ "$HAS_V6" = "true" ]; then 
        local nf=$(curl -s -6 "$nf_api" 2>/dev/null | jq -r '.targets[]|select(.url|contains("ipv6"))|.url' 2>/dev/null | head -n1 | awk -F/ '{print $3}')
        [ -n "$nf" ] && dynamic_targets+="Netflix CDN (Dynamic)||$nf"$'\n'
    fi
    
    # 构建目标列表
    # 使用 process substitution 可能会在某些环境下有问题，改用字符串读取
    local raw_static=$(get_trace_targets)
    local all_targets=()
    local current_group=""
    
    # === Streaming Report ===
    {
        echo "## 路由追踪"
    } >> "$REPORT_FILE"

    # 首先添加公共服务目标（主要公共服务分组）
    local public_targets=""
    
    # 公共 DNS 服务
    if [ "$HAS_V4" = "true" ]; then
        public_targets+="Cloudflare DNS|1.1.1.1|"$'\n'
        public_targets+="Google DNS|8.8.8.8|"$'\n'
        public_targets+="Quad9 DNS|9.9.9.9|"$'\n'
    fi
    if [ "$HAS_V6" = "true" ]; then
        public_targets+="Cloudflare DNS||2606:4700:4700::1111"$'\n'
        public_targets+="Google DNS||2001:4860:4860::8888"$'\n'
        public_targets+="Quad9 DNS||2620:fe::fe"$'\n'
    fi
    
    # 添加动态 CDN 目标
    public_targets+="$dynamic_targets"
    
    if [ -n "$public_targets" ]; then
        all_targets+=("#GROUP:主要公共服务")
        while IFS= read -r line; do
            [ -n "$line" ] && all_targets+=("$line")
        done <<< "$public_targets"
    fi

    # 然后读取静态目标，处理分组标记（仅在完整模式下）
    if [ "$public_only" != "public_only" ]; then
        while IFS= read -r line; do
            if [ -z "$line" ]; then
                continue
            elif [[ "$line" == "#GROUP:"* ]]; then
                # 从分组标记中提取组名
                current_group="${line#\#GROUP:}"
                # 将分组标记添加到目标数组中
                all_targets+=("#GROUP:$current_group")
            else
                all_targets+=("$line")
            fi
        done <<< "$raw_static"
    fi
    
    local idx=0
    local total=0
    # 计算非分组行的总数
    for entry in "${all_targets[@]}"; do
        [[ "$entry" != "#GROUP:"* ]] && total=$((total+1))
    done
    
    if [ "$total" -eq 0 ]; then
        warn "  └─ 未找到任何路由追踪目标"
        return
    fi
    
    # 使用 C-style loop 来灵活处理数组索引
    for ((i=0; i<${#all_targets[@]}; i++)); do
        entry="${all_targets[$i]}"
        [ -z "$entry" ] && continue
        
        # 处理分组标记
        if [[ "$entry" == "#GROUP:"* ]]; then
            local group_name="${entry#\#GROUP:}"
            # echo ""  <-- Remove empty line to keep tree compact
            echo "  ├── $group_name"
            # 在报告中添加分节标题
            {
                echo ""
                echo "### $group_name"
                echo ""
            } >> "$REPORT_FILE"
            
            # --- 计算该分组的总数 ---
            # 向后扫描直到下一个 #GROUP: 或数组结束
            total=0
            for ((j=i+1; j<${#all_targets[@]}; j++)); do
                local next_entry="${all_targets[$j]}"
                [[ "$next_entry" == "#GROUP:"* ]] && break
                if [ -n "$next_entry" ]; then
                    IFS='|' read -r _t_name _t_v4 _t_v6 <<< "$next_entry"
                    # Count IPv4 test if enabled and target exists
                    if [ -n "$_t_v4" ] && [ "$HAS_V4" = "true" ]; then total=$((total+1)); fi
                    # Count IPv6 test if enabled and target exists
                    if [ -n "$_t_v6" ] && [ "$HAS_V6" = "true" ]; then total=$((total+1)); fi
                fi
            done
            idx=0 # 重置组内序号
            
            continue
        fi
        
        # 如果一开始就没有 Group（防御性编程），先计算一个总数
        if [ "$total" -eq 0 ]; then
             for ((j=i; j<${#all_targets[@]}; j++)); do
                local next_entry="${all_targets[$j]}"
                [[ "$next_entry" == "#GROUP:"* ]] && break
                if [ -n "$next_entry" ]; then
                    IFS='|' read -r _t_name _t_v4 _t_v6 <<< "$next_entry"
                    if [ -n "$_t_v4" ] && [ "$HAS_V4" = "true" ]; then total=$((total+1)); fi
                    if [ -n "$_t_v6" ] && [ "$HAS_V6" = "true" ]; then total=$((total+1)); fi
                fi
            done
        fi
        
        # idx=$((idx+1))  <-- Remove here, increment inside test loop
        IFS='|' read -r name ipv4 ipv6 <<< "$entry"
        
        for mode in IPv4 IPv6; do
            local target=""
            [ "$mode" = "IPv4" ] && target="$ipv4"
            [ "$mode" = "IPv6" ] && target="$ipv6"
            
            # 只有当 目标存在 且 (是IPv4且有V4网 OR 是IPv6且有V6网) 时才测试
            if [ -n "$target" ] && { ([ "$mode" = "IPv4" ] && [ "$HAS_V4" = "true" ]) || ([ "$mode" = "IPv6" ] && [ "$HAS_V6" = "true" ]); }; then
                idx=$((idx+1))
                echo "  │  ├─ [$idx/$total] $name ($mode)..."
                local ipflag="-4"; [ "$mode" == "IPv6" ] && ipflag="-6"
                
                # 运行 nexttrace
                local raw_output=""
                local err_out=""
                # Capture stdout and stderr
                local err_file="$TMP_DIR/nt_err_$idx.log"
                raw_output=$("$NEXTTRACE_BIN" --json $ipflag "$target" 2>"$err_file")
                err_out=$(cat "$err_file" 2>/dev/null)
                rm -f "$err_file"
                
                # Extract JSON part (remove everything before first '{')
                local json=$(echo "$raw_output" | sed 's/^[^{]*//')
                
                # Verify JSON
                if [ -z "$json" ] || ! echo "$json" | jq -e . >/dev/null 2>&1; then
                    echo "  │  │  └─ 失败: 无效输出"
                    # Debug: Show what we actually got
                    if [ -z "$raw_output" ]; then
                        echo "  │  │     (输出为空)"
                    else
                        local clean_out=$(echo "$raw_output" | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g')
                        echo "  │  │     (原始内容): ${clean_out:0:100}..."
                    fi
                    
                    if [ -n "$err_out" ]; then
                        local clean_err=$(echo "$err_out" | sed 's/\x1b\[[0-9;]*m//g' | head -n 1)
                        echo "  │     (错误信息): $clean_err"
                    fi
                else
                    # Parse JSON Result and Build Table
                    # Hops wrapped in list: .[0] or simple array
                    # NextTrace 1.5.0 quirks: sometimes [[hop1, hop2]], sometimes [hop1, hop2]
                    local table="| 跳数 | IP | ASN | 位置 | 运营商 | 延迟 |\n"
                    table+="|---:|:---|:---|:---|:---|---:|\n"
                    
                    local rows=$(echo "$json" | jq -r '
                        # NextTrace JSON: { Hops: [ [probe0, probe1, probe2], ... ] }
                        .Hops | to_entries[] |
                        (.key + 1) as $hopnum |
                        .value as $probes |
                        # 选择第一个成功的探测，如果没有则取第一个
                        ([$probes[] | select(.Success == true)][0] // $probes[0] // {}) as $p |
                        
                        # IP地址：如果为null或空，显示 "*"
                        (if $p.Address then ($p.Address.IP // "*") else "*" end) as $ip |
                        
                        # ASN：只有非空字符串才显示
                        (if $p.Geo and ($p.Geo.asnumber // "") != "" then "AS" + $p.Geo.asnumber else "-" end) as $asn |
                        
                        # 地理位置：国家 省份 城市（过滤空值、去重、去掉"市""省""州"后缀）
                        (if $p.Geo then
                            ([$p.Geo.country, $p.Geo.prov, $p.Geo.city] | map(select(. and . != "") | gsub("市$|省$|州$"; "")) | reduce .[] as $x ([]; if . | index($x) then . else . + [$x] end) | join(" "))
                        else "" end) as $loc_raw |
                        (if $loc_raw == "" then "-" else $loc_raw end) as $loc |
                        
                        # 运营商：优先 isp，其次 owner
                        (if $p.Geo then
                            (if ($p.Geo.isp // "") != "" then $p.Geo.isp
                             elif ($p.Geo.owner // "") != "" then $p.Geo.owner
                             else "-" end)
                        else "-" end) as $isp |
                        
                        # 延迟：RTT 单位是纳秒，转换为毫秒
                        (if $p.RTT and $p.RTT > 0 then
                            (($p.RTT / 1000000 * 100 | floor) / 100 | tostring)
                        else "-" end) as $rtt |
                        
                        [$hopnum, $ip, $asn, $loc, $isp, $rtt] | @tsv
                    ' 2>/dev/null)
                    
                    if [ -n "$rows" ]; then
                        while IFS=$'\t' read -r ttl ip asn loc isp rtt; do
                            [ -z "$ip" ] && continue
                            
                            # 当IP为"*"时显示"-"
                            [ "$ip" = "*" ] && ip="-"
                            
                            # IX Check (只有IP不为"-"时才检查)
                            if [ "$ip" != "-" ]; then
                                local ix_name=$(grep -F "$ip " "$TMP_DIR/ix_ip_map.txt" 2>/dev/null | head -n1 | cut -d' ' -f2-)
                                [ -n "$ix_name" ] && isp="$isp [$ix_name]"
                            fi
                            
                            
                            # 运营商名称规范化
                            isp=$(normalize_isp_name "$isp")
                            # RTT格式：有值时追加ms，无值时显示"-"
                            if [ "$rtt" != "-" ] && [ -n "$rtt" ]; then
                                rtt_display="$rtt ms"
                            else
                                rtt_display="-"
                            fi
                            table+="| $ttl | $ip | $asn | $loc | $isp | $rtt_display |\n"
                        done <<< "$rows"
                        

                        
                        echo "  │  │  └─ 追踪完成"
                        
                        # === Streaming Report (Trace Item) ===
                        {
                            echo "#### $name ($mode)"
                            # 如果是动态 CDN 目标，显示解析到的域名
                            if [[ "$name" == *"Dynamic"* ]]; then
                                echo "命中 CDN 节点: \`$target\`"
                                echo ""
                            fi
                            echo -e "$table"
                            echo ""
                        } >> "$REPORT_FILE"
                    else
                        echo "  │  │  └─ 失败: 解析结果为空"
                        # TRACE_RESULTS+=("### $name ($mode)|> Trace Failed (Parse Error)")
                    fi
                fi
            fi

        done
    done
    
    info "  └─ 路由追踪完成"
}

init_report() {
    > "$REPORT_FILE"
    echo "# Bench Report" >> "$REPORT_FILE"
    echo "Generated at $(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
}

main() {
    clear
    
    # ASCII 艺术字
    echo -e "${GREEN}"
    cat <<'EOF'
  _     _                    ____                  _     
 | |   (_)_ __  _   ___  __ | __ )  ___ _ __   ___| |__  
 | |   | | '_ \| | | \ \/ / |  _ \ / _ | '_ \ / __| '_ \ 
 | |___| | | | | |_| |>  <  | |_) |  __| | | | (__| | | |
 |_____|_|_| |_|\__,_/_/\_\ |____/ \___|_| |_|\___|_| |_|
                                                         
EOF
    echo -e "${NC}"
    
    # 提示用户可选参数
    echo -e "==> 欢迎使用 LinuxBench，这是一个综合的测试工具"
    echo -e "\n--- 可选测试模式："
    echo -e "  -n, --network       综合网络测试"
    echo -e "  -h, --hardware      硬件性能测试"
    echo -e "  -t, --nexttrace     路由追踪"
    echo -e "  -p, --public        公共服务 (DNS + 流媒体 CDN)"
    echo -e "  -i, --ip-quality    IPv4 质量检测"
    echo -e "  -s, --stream        流媒体解锁"
    echo -e "  -4                  仅进行 IPv4 测试"
    echo -e "  -6                  仅进行 IPv6 测试\n"
    
    # 致谢
    echo -e "[*] 感谢 JamChoi 提供的 Python 源码"
    echo -e "[+] 由我驾驶着 Google Antigravity 进行改写和扩展"
    echo -e "[>] 本项目依赖 nxtrace/NTrace-core 进行路由追踪"
    echo -e "[>] 本项目依赖 lmc999/RegionRestrictionCheck 进行流媒体测试"
    echo -e "[i] IP 信息来源于 ipapi.co，ipapi.is 和 ippure.com"
    echo -e "[✓] 测试结束时自动清理，干干净净（我有洁癖）"
    echo -e ""
    
    # Initialize Report
    init_report
    log "输出文件: $REPORT_FILE"
    
    # Mode Log
    # Mode Log
    if [ "$RUN_PUBLIC" = "true" ]; then 
        log "${CYAN}模式: 仅公共服务测试 (-p)${NC}"
    elif [ "$RUN_IPERF" = "false" ] && [ "$RUN_TRACE" = "false" ] && [ "$RUN_NET_INFO" = "false" ]; then 
        log "${CYAN}模式: 仅硬件测试 (-h)${NC}"
    elif [ "$RUN_CPU" = "false" ] && [ "$RUN_DISK" = "false" ] && [ "$RUN_TRACE" = "true" ] && [ "$RUN_IPERF" = "true" ]; then 
        log "${CYAN}模式: 仅网络测试 (-n)${NC}"
    elif [ "$RUN_TRACE" = "true" ] && [ "$RUN_IPERF" = "false" ]; then 
        log "${CYAN}模式: 仅路由追踪 (-t)${NC}"
    elif [ "$RUN_IP_QUALITY" = "true" ] && [ "$RUN_TRACE" = "false" ]; then 
        log "${CYAN}模式: 仅 IP 质量检测 (-i)${NC}"
    elif [ "$RUN_STREAM" = "true" ] && [ "$RUN_TRACE" = "false" ]; then 
        log "${CYAN}模式: 仅流媒体测试 (-s)${NC}"
    fi

    if [ "$SKIP_V6" = "true" ]; then
        log "${CYAN}限制: 仅运行 IPv4 测试 (-4)${NC}"
    elif [ "$SKIP_V4" = "true" ]; then
        log "${CYAN}限制: 仅运行 IPv6 测试 (-6)${NC}"
    fi
    
    ensure_dependencies
    
    collect_system_info
    
    # 网络相关
    if [ "$RUN_NET_INFO" = "true" ]; then
        collect_network_info
    fi
    
    # IP 质量检测
    if [ "$RUN_IP_QUALITY" = "true" ] && [ "$RUN_NET_INFO" = "true" ]; then
        collect_ip_quality
    fi
    
    # 流媒体解锁测试
    if [ "$RUN_STREAM" = "true" ] && [ "$RUN_NET_INFO" = "true" ]; then
        run_stream_test
    fi
    
    # 硬件性能测试
    if [ "$RUN_CPU" = "true" ]; then
        run_cpu_test
    fi
    
    if [ "$RUN_DISK" = "true" ]; then
        run_disk_test
    fi
    
    # 网络性能测试
    if [ "$RUN_IPERF" = "true" ]; then
        run_iperf_test
    fi
    
    # 公共服务测试（只测公共服务，不测其他目标）
    if [ "$RUN_PUBLIC" = "true" ]; then
        run_trace_test "public_only"
    fi
    
    # 路由追踪测试
    if [ "$RUN_TRACE" = "true" ]; then
        run_trace_test
    fi
    
    info "测试完成! 报告已保存至 $REPORT_FILE"
}

main
