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
TMP_DIR="./bench_tmp_$(date +%s)"
REPORT_FILE="bench_$(date +%Y%m%d_%H%M%S).md"

# 运行模式标志
RUN_CPU=true
RUN_DISK=true
RUN_NET_INFO=true
RUN_IPERF=true
RUN_TRACE=true

# 参数解析
for arg in "$@"; do
    case $arg in
        --network|-n)
            RUN_CPU=false
            RUN_DISK=false
            RUN_NET_INFO=true
            RUN_IPERF=true
            RUN_TRACE=true
            shift
            ;;
        --hardware|-h)
            RUN_CPU=true
            RUN_DISK=true
            RUN_NET_INFO=false
            RUN_IPERF=false
            RUN_TRACE=false
            shift
            ;;
        --nexttrace|-nt)
            RUN_CPU=false
            RUN_DISK=false
            RUN_NET_INFO=true
            RUN_IPERF=false
            RUN_TRACE=true
            shift
            ;;
    esac
done

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 信号捕捉
cleanup() {
    # 1. 删除临时文件
    rm -rf "$TMP_DIR"
    
    # 2. 移除脚本安装的依赖
    if [ ${#CLEANUP_PKGS[@]} -gt 0 ]; then
        echo -e "\n[$(get_time)] 正在清理安装的依赖 (${CLEANUP_PKGS[*]}) ..."
        apt-get remove -y "${CLEANUP_PKGS[@]}" >/dev/null 2>&1
        apt-get autoremove -y >/dev/null 2>&1
        echo -e "[$(get_time)] 清理完成"
    fi
}
trap "cleanup; echo -e '\n[退出] 脚本已终止'; exit 1" INT TERM
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
    
    CLEANUP_PKGS=()
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
    
    if [ "$RUN_TRACE" = "true" ]; then
        
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
            else
                export NEXTTRACE_BIN="false"
            fi
        else
            export NEXTTRACE_BIN="nexttrace"
        fi
        
        # yt-dlp
        if ! check_cmd yt-dlp; then
            if curl -L -s -o "$TMP_DIR/yt-dlp" "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" 2>/dev/null; then
                chmod +x "$TMP_DIR/yt-dlp"
                export YTDLP_BIN="$TMP_DIR/yt-dlp"
            else
                export YTDLP_BIN="false"
            fi
        else
            export YTDLP_BIN="yt-dlp"
        fi
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
    echo "  ├─ CPU: $SYS_CPU ($SYS_CORES vCPU)"
    
    # 2. Virtualization
    echo "  ├─ 检测虚拟化类型..."
    SYS_VIRT=$(systemd-detect-virt 2>/dev/null)
    if [ -z "$SYS_VIRT" ]; then
        SYS_VIRT=$(hostnamectl 2>/dev/null | grep "Virtualization" | cut -d: -f2 | xargs)
    fi
    [ -z "$SYS_VIRT" ] && SYS_VIRT="Physical/Unknown"
    echo "  ├─ 虚拟化: $SYS_VIRT"
    
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
    echo "  ├─ 内存: $SYS_MEM"
    
    # 4. Disk
    echo "  ├─ 检测磁盘信息..."
    local root_disk=$(df -h / | tail -n1)
    local disk_total=$(echo "$root_disk" | awk '{print $2}')
    local disk_used=$(echo "$root_disk" | awk '{print $3}')
    local disk_dev=$(echo "$root_disk" | awk '{print $1}')
    SYS_DISK="${disk_used} / ${disk_total} ($disk_dev)"
    echo "  ├─ 磁盘: $SYS_DISK"
    
    # 5. OS / Kernel
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        SYS_OS="$PRETTY_NAME"
    else
        SYS_OS=$(uname -srm)
    fi
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
    echo "  ├─ IPv4: $NET_V4_IP"
    
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
    echo "  └─ IPv6: $NET_V6_IP"

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
# 性能测试 (CPU/Disk/Net)
# =========================
run_cpu_test() {
    log "开始 CPU 性能测试..."
    if ! check_cmd sysbench; then warn "  └─ sysbench 未安装，跳过"; return; fi
    
    echo "  ├─ 单线程测试 (20秒)..."
    local res_1t=$(sysbench --threads=1 --time=20 --cpu-max-prime=10000 cpu run 2>&1)
    local score_1t=$(echo "$res_1t" | grep "events per second:" | awk '{print $4}')
    echo "  ├─ 单线程结果: $score_1t events/s"
    
    local score_nt=""
    local multi="1.00"
    if [ "$SYS_CORES" -gt 1 ]; then
        echo "  ├─ $SYS_CORES 线程测试 (20秒)..."
        local res_nt=$(sysbench --threads="$SYS_CORES" --time=20 --cpu-max-prime=10000 cpu run 2>&1)
        score_nt=$(echo "$res_nt" | grep "events per second:" | awk '{print $4}')
        multi=$(calc "$score_nt / $score_1t")
        echo "  └─ $SYS_CORES 线程结果: $score_nt events/s (${multi}x)"
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
        out=$(iperf3 "${args[@]}" 2>&1)
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
            echo "| $mode | $provider | $loc | $send | $recv | ${lat:---} |" >> "$REPORT_FILE"
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
            echo ""
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
# Traceroute
# =========================
# PLACEHOLDER: create_ix_map function will be appended here.
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

get_trace_targets() {
cat << 'EOF'
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
Cloudflare DNS - Anycast|1.1.1.1|2606:4700:4700::1111
Google DNS - Anycast|8.8.8.8|2001:4860:4860::8888
EOF
}

run_trace_test() {
    log "开始路由追踪测试..."
    
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
        if [ "$HAS_V4" = "true" ]; then v4=$("$YTDLP_BIN" --no-warnings -g -4 "https://www.youtube.com/watch?v=G5RpJwCJDqc" 2>/dev/null | head -n1 | awk -F/ '{print $3}'); [ -n "$v4" ] && dynamic_targets+="YouTube CDN (Dynamic)|$v4|"$'\n'; fi
        if [ "$HAS_V6" = "true" ]; then v6=$("$YTDLP_BIN" --no-warnings -g -6 "https://www.youtube.com/watch?v=G5RpJwCJDqc" 2>/dev/null | head -n1 | awk -F/ '{print $3}'); [ -n "$v6" ] && dynamic_targets+="YouTube CDN (Dynamic)||$v6"$'\n'; fi
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
    
    # === Streaming Report ===
    {
        echo "## 路由追踪"
    } >> "$REPORT_FILE"

    # 读取静态目标
    while IFS= read -r line; do
        [ -n "$line" ] && all_targets+=("$line")
    done <<< "$raw_static"
    
    # 读取动态目标
    while IFS= read -r line; do
        [ -n "$line" ] && all_targets+=("$line")
    done <<< "$dynamic_targets"
    
    local idx=0
    local total=${#all_targets[@]}
    
    if [ "$total" -eq 0 ]; then
        warn "  └─ 未找到任何路由追踪目标"
        return
    fi
    
    for entry in "${all_targets[@]}"; do
        [ -z "$entry" ] && continue
        idx=$((idx+1))
        IFS='|' read -r name ipv4 ipv6 <<< "$entry"
        
        for mode in IPv4 IPv6; do
            local target=""
            [ "$mode" = "IPv4" ] && target="$ipv4"
            [ "$mode" = "IPv6" ] && target="$ipv6"
            
            # 只有当 目标存在 且 (是IPv4且有V4网 OR 是IPv6且有V6网) 时才测试
            if [ -n "$target" ] && { ([ "$mode" = "IPv4" ] && [ "$HAS_V4" = "true" ]) || ([ "$mode" = "IPv6" ] && [ "$HAS_V6" = "true" ]); }; then
                echo "  ├─ [$idx/$total] $name ($mode)..."
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
                    echo "  │  └─ 失败: 无效输出"
                    # Debug: Show what we actually got
                    if [ -z "$raw_output" ]; then
                        echo "  │     (输出为空)"
                    else
                        local clean_out=$(echo "$raw_output" | tr -d '\n' | sed 's/\x1b\[[0-9;]*m//g')
                        echo "  │     (原始内容): ${clean_out:0:100}..."
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
                        # NextTrace JSON: { Hops: [ [probe0, probe1, probe2], [probe0, probe1, probe2], ... ] }
                        # Each Hop is an ARRAY of probes (typically 3). We pick the first successful one.
                        .Hops | to_entries[] |
                        (.key + 1) as $hopnum |
                        .value as $probes |
                        # Select first successful probe, or first probe if none
                        ([$probes[] | select(.Success == true)][0] // $probes[0] // {}) as $p |
                        [
                            $hopnum,
                            ($p.Address.IP // "*"),
                            (if ($p.Geo.asnumber // 0) != 0 then "AS"+($p.Geo.asnumber|tostring) else "AS-" end),
                            ([$p.Geo.country, $p.Geo.city] | map(select(. and . != "")) | join(" ") | if . == "" then "-" else . end),
                            ($p.Geo.isp // $p.Geo.owner // "-"),
                            (if $p.RTT then (($p.RTT / 1000000 * 100 | floor) / 100 | tostring) else "-" end)
                        ] | @tsv
                    ' 2>/dev/null)
                    
                    if [ -n "$rows" ]; then
                        while IFS=$'\t' read -r ttl ip asn loc isp rtt; do
                            [ -z "$ip" ] && continue
                            
                            # IX Check
                            local ix_name=$(grep -F "$ip " "$TMP_DIR/ix_ip_map.txt" 2>/dev/null | head -n1 | cut -d' ' -f2-)
                            [ -n "$ix_name" ] && isp="$isp [$ix_name]"
                            
                            if [ "$rtt" != "-" ] && [ -n "$rtt" ]; then
                                rtt="$rtt"
                            fi
                            table+="| $ttl | $ip | $asn | $loc | $isp | $rtt ms |\n"
                        done <<< "$rows"
                        
                        echo "  │  └─ 追踪完成"
                        
                        # === Streaming Report (Trace Item) ===
                        {
                            echo "### $name ($mode)"
                            echo -e "$table"
                            echo ""
                        } >> "$REPORT_FILE"
                    else
                        echo "  │  └─ 失败: 解析结果为空"
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
    
    # 提示用户可选参数
    echo -e "💡 提示: 使用 -h 仅硬件，-n 仅网络，-nt 仅路由追踪"
    
    # 致谢
    echo -e "✨ 感谢 JamChoi 提供的源代码，由 aoaim 和 Gemini 3.0 Pro 进行改写"
    
    # Initialize Report
    init_report
    log "输出文件: $REPORT_FILE"
    
    # Mode Log
    if [ "$RUN_IPERF" = "false" ] && [ "$RUN_TRACE" = "false" ] && [ "$RUN_NET_INFO" = "false" ]; then log "模式: 仅硬件测试 (--hardware)"; fi
    if [ "$RUN_CPU" = "false" ] && [ "$RUN_DISK" = "false" ]; then log "模式: 仅网络测试 (--network)"; fi
    
    ensure_dependencies
    
    collect_system_info
    
    # 网络相关
    if [ "$RUN_NET_INFO" = "true" ]; then
        collect_network_info
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
    
    if [ "$RUN_TRACE" = "true" ]; then
        run_trace_test
    fi
    
    info "测试完成! 报告已保存至 $REPORT_FILE"
}

main
