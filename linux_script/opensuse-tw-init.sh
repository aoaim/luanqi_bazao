#!/usr/bin/env bash
#
# ==============================================================================
# openSUSE Tumbleweed 开荒脚本
# ==============================================================================
# 支持: openSUSE Tumbleweed
# 功能: 检测镜像延迟并切换源，执行 zypper dup，安装基础工具、Fish、Atuin、Miniforge、Helix、Lazygit
# 会改动: /etc/zypp/repos.d/*.repo, /etc/zypp/repos.d.bak, ~/.config/fish/config.fish,
#          ~/.condarc, ~/.config/helix/languages.toml, ~/.local/bin/*, ~/miniforge
# 说明: 在非 root 但有 sudo 权限的用户下运行
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
WHITE='\033[0;37m'
NC='\033[0m'
BOLD='\033[1m'

DISTRO=""
CODENAME=""
SUDO_CMD=""
HAS_SUDO=false
SELECTED_MIRROR=""

msg() { local c="$1"; shift; echo -e "${c}$*${NC}"; }
info() { msg "$WHITE" "[INFO]" "$*"; }
success() { msg "$GREEN" "[OK]" "$*"; }
warn() { msg "$YELLOW" "[WARN]" "$*"; }
error() { msg "$RED" "[ERROR]" "$*"; exit 1; }

section() {
  local title="$1"
  echo ""
  echo -e "${MAGENTA}>> ${title}${NC}"
}

show_intro() {
  section "Overview"
  echo "  This script will:"
  echo "    1. Detect openSUSE Tumbleweed"
  echo "    2. Test mirror latency and optionally switch repositories"
  echo "    3. Run zypper dup"
  echo "    4. Install essential CLI tools, Fish, Atuin, Miniforge, and Lazygit"
  echo ""
  echo "  This script will modify:"
  echo "    - /etc/zypp/repos.d/*.repo"
  echo "    - /etc/zypp/repos.d.bak"
  echo "    - $HOME/.config/fish/config.fish"
  echo "    - $HOME/.condarc"
  echo "    - $HOME/.local/bin/"
  echo "    - $HOME/miniforge"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

get_sudo() {
  if [ "$HAS_SUDO" = true ]; then return 0; fi
  info "Requesting sudo access..."
  if sudo -v; then
    SUDO_CMD="sudo"
    HAS_SUDO=true
    success "Sudo access granted"
  else
    error "Failed to acquire sudo access"
  fi
}

detect_and_validate_distro() {
  info "Detecting operating system..."

  local id=""
  local id_like=""
  local name=""
  local version=""

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    id="${ID:-}"
    id_like="${ID_LIKE:-}"
    name="${NAME:-}"
    version="${VERSION:-${VERSION_ID:-}}"
    DISTRO="${name:-$id}"
  fi

  # 若 os-release 信息不完整，再尝试 lsb_release 补充
  if [ -z "$DISTRO" ] && command_exists lsb_release; then
    DISTRO="$(lsb_release -is 2>/dev/null || true)"
  fi
  if [ -z "$version" ] && command_exists lsb_release; then
    version="$(lsb_release -ds 2>/dev/null || true)"
  fi

  local judge="${id,,} ${id_like,,} ${DISTRO,,} ${version,,}"
  case "$judge" in
    *opensuse*tumbleweed*|*suse*tumbleweed*)
      CODENAME="tumbleweed"
      ;;
    *)
      error "Only openSUSE Tumbleweed is supported. Current system: ${DISTRO:-unknown} ${version:-}"
      ;;
  esac

  success "Detected openSUSE Tumbleweed"
}

declare -A MIRROR_MAP
MIRROR_MAP["tsinghua"]="https://mirrors.tuna.tsinghua.edu.cn"
MIRROR_MAP["ustc"]="https://mirrors.ustc.edu.cn"
MIRROR_MAP["bfsu"]="https://mirrors.bfsu.edu.cn"

declare -A OPENSUSE_PATHS
OPENSUSE_PATHS["oss"]="/opensuse/tumbleweed/repo/oss/"
OPENSUSE_PATHS["non-oss"]="/opensuse/tumbleweed/repo/non-oss/"
OPENSUSE_PATHS["update"]="/opensuse/update/tumbleweed/"

latency_color() {
  local ms="$1"
  if [ "$ms" -le 30 ]; then echo "$GREEN"
  elif [ "$ms" -le 80 ]; then echo "$MAGENTA"
  elif [ "$ms" -le 150 ]; then echo "$YELLOW"
  else echo "$RED"; fi
}

pretty_mirror_name() {
  case "$1" in
    tsinghua) echo "Tsinghua" ;;
    ustc) echo "USTC" ;;
    bfsu) echo "BFSU" ;;
    default) echo "Default" ;;
    *) echo "$1" ;;
  esac
}

check_path_latency_ms() {
  local url="$1"
  local code t
  code=$(curl -o /dev/null -s -w "%{http_code}" --connect-timeout 5 -L "$url" || echo "000")
  t=$(curl -o /dev/null -s -w "%{time_total}" --connect-timeout 5 -L "$url" || echo "9.999")

  if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
    awk -v v="$t" 'BEGIN{printf "%d", v*1000}'
    return 0
  fi

  echo "failed"
  return 1
}

measure_url_latency_ms() {
  local url="$1"
  local samples=()
  local i ms total=0

  for i in 1 2 3 4 5; do
    ms=$(check_path_latency_ms "$url") || return 1
    samples+=("$ms")
  done

  IFS=$'\n' samples=($(printf '%s\n' "${samples[@]}" | sort -n))
  unset IFS

  # 去掉最高和最低，保留中间 3 个求均值
  total=$((samples[1] + samples[2] + samples[3]))
  echo $((total / 3))
}

check_mirror_all_paths() {
  local base="$1"
  local total=0 cnt=0

  for k in "${!OPENSUSE_PATHS[@]}"; do
    local u="${base}${OPENSUSE_PATHS[$k]}"
    local ms
    ms=$(measure_url_latency_ms "$u") || return 1
    total=$((total + ms))
    cnt=$((cnt + 1))
  done

  [ "$cnt" -gt 0 ] || return 1
  echo $((total / cnt))
}

select_mirror() {
  info "Testing mirror availability for openSUSE repositories..."

  local mirrors=("tsinghua" "ustc" "bfsu")
  local results=()

  for m in "${mirrors[@]}"; do
    local base="${MIRROR_MAP[$m]}"
    info "Checking $m ($base)..."

    local ms
    if ms=$(check_mirror_all_paths "$base"); then
      results+=("$m|$ms|ok")
      echo -e "    ${GREEN}✓${NC} All required paths are reachable, average latency: ${ms}ms"
    else
      results+=("$m|999999|failed")
      echo -e "    ${RED}✗${NC} Some required paths are unavailable"
    fi
  done

  IFS=$'\n' sorted=($(sort -t'|' -k2 -n <<<"${results[*]}"))
  unset IFS

  echo ""
  echo "  No.  Mirror      Latency   Status"
  echo "  ---  ----------  --------  -----------"
  printf "  %3d  %-10s  %-8s  %-11s\n" 0 "$(pretty_mirror_name default)" "--" "default"

  local i=1
  for row in "${sorted[@]}"; do
    local name ms st
    IFS='|' read -r name ms st <<<"$row"
    if [ "$st" = "ok" ]; then
      local c
      c=$(latency_color "$ms")
      local level="fair"
      [ "$ms" -le 30 ] && level="excellent"
      [ "$ms" -gt 30 ] && [ "$ms" -le 80 ] && level="good"
      [ "$ms" -gt 150 ] && level="slow"
      printf "  %3d  %-10s  " "$i" "$(pretty_mirror_name "$name")"
      printf "${c}%-8s${NC}  ${GREEN}%-11s${NC}\n" "${ms} ms" "$level"
    else
      printf "  %3d  %-10s  ${RED}%-8s${NC}  ${RED}%-11s${NC}\n" "$i" "$(pretty_mirror_name "$name")" "--" "unavailable"
    fi
    i=$((i+1))
  done

  echo ""
  echo -n "Select a mirror [0-${#sorted[@]}] (Enter for 1): "
  read -r choice
  [ -z "$choice" ] && choice=1

  if [ "$choice" = "0" ]; then
    SELECTED_MIRROR="default"
    return 0
  fi

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#sorted[@]}" ]; then
    warn "Invalid selection. Falling back to option 1"
    choice=1
  fi

  local picked="${sorted[$((choice-1))]}"
  local m
  IFS='|' read -r m _ _ <<<"$picked"
  SELECTED_MIRROR="$m"
}

show_opensuse_repos() {
  local stage="${1:-current}"
  echo ""
  echo -e "${MAGENTA}>> Repository snapshot (${stage})${NC}"
  zypper lr -u || true
  echo ""
}

configure_opensuse_mirror() {
  local mirror_name="$1"
  local mirror_host

  case "$mirror_name" in
    tsinghua) mirror_host="mirrors.tuna.tsinghua.edu.cn" ;;
    ustc)     mirror_host="mirrors.ustc.edu.cn" ;;
    bfsu)     mirror_host="mirrors.bfsu.edu.cn" ;;
    *) error "Invalid mirror: $mirror_name" ;;
  esac

  info "Switching openSUSE repositories to: $mirror_name"
  get_sudo
  show_opensuse_repos "before"
  $SUDO_CMD cp -a /etc/zypp/repos.d /etc/zypp/repos.d.bak

  for f in /etc/zypp/repos.d/*.repo; do
    [ -f "$f" ] || continue

    if grep -Eqi '^(baseurl|metalink)=.*(cd|dvd):' "$f"; then
      info "Skipping CD/DVD repo file: $(basename "$f")"
      continue
    fi

    # Do not rewrite third-party OBS repositories such as Fish upstream repo.
    if grep -Eqi '^(baseurl|metalink)=.*(/repositories/|shells:fish:release:4)' "$f"; then
      info "Keeping third-party repo unchanged: $(basename "$f")"
      continue
    fi

    # 情况1: 已是镜像格式 .../opensuse/...
    $SUDO_CMD sed -E -i "s|https?://[^/]+/opensuse/|https://${mirror_host}/opensuse/|g" "$f"
    # 情况2: 官方源格式 download.opensuse.org/... (无 /opensuse 前缀)
    $SUDO_CMD sed -E -i "s|https?://download\.opensuse\.org/|https://${mirror_host}/opensuse/|g" "$f"
    # 统一 https
    $SUDO_CMD sed -E -i "s|http://${mirror_host}|https://${mirror_host}|g" "$f"
  done

  info "Applying repository changes..."

  local enable_repos=("repo-oss" "repo-non-oss" "repo-update" "repo-openh264")
  for r in "${enable_repos[@]}"; do
    $SUDO_CMD zypper mr -e "$r" >/dev/null 2>&1 || true
  done

  local disable_repos=("repo-debug" "repo-source" "repo-update-debug" "repo-update-source")
  for r in "${disable_repos[@]}"; do
    $SUDO_CMD zypper mr -d "$r" >/dev/null 2>&1 || true
  done

  while IFS='|' read -r num alias _; do
    num="$(echo "$num" | xargs)"
    alias="$(echo "$alias" | xargs)"
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    if [[ "$alias" =~ [Cc][Dd] || "$alias" =~ [Dd][Vv][Dd] ]]; then
      $SUDO_CMD zypper mr -d "$alias" >/dev/null 2>&1 || true
    fi
  done < <(zypper lr 2>/dev/null)

  info "Refreshing repository metadata..."
  $SUDO_CMD zypper --non-interactive ref
  show_opensuse_repos "after"
  success "Repository switch completed"
}

update_system() {
  info "Updating system..."
  info "Tumbleweed should be updated with zypper dup"
  get_sudo
  $SUDO_CMD zypper --non-interactive dup
  success "System update completed"
}

install_base_packages() {
  info "Checking and installing essential CLI tools..."
  get_sudo

  local packages=(
    git-core curl wget tree htop nano
    bat fd ripgrep fzf jq
    zip unzip tar gzip bzip2
    vim helix openssh
    net-tools iputils bind-utils traceroute
    less file which
  )

  local need=()
  for p in "${packages[@]}"; do
    if rpm -q "$p" >/dev/null 2>&1; then
      info "Already installed: $p"
    else
      need+=("$p")
    fi
  done

  if [ "${#need[@]}" -gt 0 ]; then
    info "Installing ${#need[@]} missing packages..."
    $SUDO_CMD zypper --non-interactive install "${need[@]}"
  else
    info "All essential CLI tools are already installed"
  fi

  success "Essential CLI tools completed"
}

install_fish() {
  info "Installing Fish..."
  get_sudo

  if ! command_exists fish; then
    info "Adding official Fish repository..."
    $SUDO_CMD zypper rr shells_fish_release_4 >/dev/null 2>&1 || true
    $SUDO_CMD zypper addrepo -f "https://download.opensuse.org/repositories/shells:fish:release:4/openSUSE_Tumbleweed/shells:fish:release:4.repo" || true
    $SUDO_CMD zypper refresh
    $SUDO_CMD zypper --non-interactive install fish
  fi

  if [ "$SHELL" != "$(command -v fish)" ]; then
    $SUDO_CMD chsh -s "$(command -v fish)" "$USER" || true
  fi

  success "Fish setup completed"
}

install_zoxide() {
  if command_exists zoxide; then return 0; fi
  info "Installing zoxide..."

  get_sudo
  if rpm -q zoxide >/dev/null 2>&1; then
    info "zoxide is already installed"
  else
    $SUDO_CMD zypper --non-interactive install zoxide
  fi
}

install_fish_plugins() {
  info "Installing Fish plugins..."

  if ! fish -c "functions -q fisher" >/dev/null 2>&1; then
    info "Installing fisher..."
    mkdir -p "$HOME/.config/fish/functions"
    curl -fsSL "https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish" -o "$HOME/.config/fish/functions/fisher.fish"
  fi

  install_zoxide

  if ! fish -c "fisher list | grep -q 'PatrickF1/fzf.fish'" >/dev/null 2>&1; then
    fish -c "fisher install PatrickF1/fzf.fish"
  fi

  generate_fish_config
  success "Fish plugins completed"
}

generate_fish_config() {
  mkdir -p "$HOME/.config/fish"

  cat > "$HOME/.config/fish/config.fish" <<'EOF'
# fish config generated by linux-init.sh
set -gx EDITOR vim
set -gx VISUAL vim
set -gx XDG_CONFIG_HOME "$HOME/.config"
set -gx XDG_DATA_HOME "$HOME/.local/share"
set -gx XDG_CACHE_HOME "$HOME/.cache"
set -gx LANG en_US.UTF-8
set -gx LC_ALL en_US.UTF-8

fish_add_path "$HOME/.local/bin"

alias ll 'ls -alF --color=auto'
alias la 'ls -A --color=auto'
alias l 'ls -CF --color=auto'
alias .. 'cd ..'
alias ... 'cd ../..'
alias grep 'grep --color=auto'

alias g git
alias gs 'git status'
alias ga 'git add'
alias gc 'git commit'
alias gp 'git push'
alias gl 'git log --oneline --graph --decorate'

if type -q zoxide
    zoxide init fish | source
end

if type -q atuin
    atuin init fish | source
end
EOF
}

install_atuin() {
  info "Installing Atuin..."
  if command_exists atuin; then
    info "Atuin is already installed"
    return 0
  fi

  local tmp
  tmp=$(mktemp -d)
  cd "$tmp"
  curl -sSL https://github.com/atuinsh/atuin/releases/latest/download/atuin-x86_64-unknown-linux-gnu.tar.gz | tar xz
  mkdir -p "$HOME/.local/bin"
  [ -f atuin ] && mv atuin "$HOME/.local/bin/" && chmod +x "$HOME/.local/bin/atuin"
  cd - >/dev/null
  rm -rf "$tmp"

  success "Atuin installation completed"
}

install_miniforge() {
  info "Installing Miniforge..."

  if [ -f "$HOME/miniforge/etc/profile.d/conda.sh" ]; then
    info "Miniforge is already installed"
  else
    local url fallback_url
    case "$SELECTED_MIRROR" in
      tsinghua) url="https://mirrors.tuna.tsinghua.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Linux-x86_64.sh" ;;
      ustc) url="https://mirrors.ustc.edu.cn/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh" ;;
      bfsu) url="https://mirrors.bfsu.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Linux-x86_64.sh" ;;
      *) url="https://mirrors.ustc.edu.cn/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh" ;;
    esac
    fallback_url="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh"

    local tmp
    tmp=$(mktemp -d)
    cd "$tmp"
    curl -fL -o "Miniforge3-Linux-x86_64.sh" "$url" || {
      warn "Mirror download failed, falling back to GitHub"
      curl -fL -o "Miniforge3-Linux-x86_64.sh" "$fallback_url"
    }
    local installer="Miniforge3-Linux-x86_64.sh"
    [ -n "$installer" ] || error "Miniforge download failed"
    bash "$installer" -b -p "$HOME/miniforge"
    cd - >/dev/null
    rm -rf "$tmp"
  fi

  cat > "$HOME/.condarc" <<'EOF'
channels:
  - conda-forge
  - bioconda

default_channels: []
allow_other_channels: false

custom_channels:
  conda-forge: https://mirrors.ustc.edu.cn/anaconda/cloud
  bioconda: https://mirrors.ustc.edu.cn/anaconda/cloud

channel_priority: strict
show_channel_urls: true
solver: libmamba

pinned_packages:
  - r-base=4.5.* # 固定 R 关键版本

remote_connect_timeout_secs: 60.0
remote_read_timeout_secs: 120.0
remote_max_retries: 5
EOF

  if [ -x "$HOME/miniforge/bin/mamba" ]; then
    "$HOME/miniforge/bin/mamba" shell init --shell fish --root-prefix "$HOME/miniforge" >/dev/null 2>&1 || \
      warn "mamba shell init failed; you may need to run it manually"
  fi

  success "Miniforge and .condarc setup completed"
}

install_lazygit() {
  info "Installing Lazygit..."
  if command_exists lazygit; then
    info "Lazygit is already installed"
    return 0
  fi

  local tmp
  tmp=$(mktemp -d)
  cd "$tmp"

  local ver arch
  ver=$(curl -sL "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -oP '"tag_name":\s*"\K[^"]+' || echo "v0.41")
  arch="amd64"
  [ "$(uname -m)" = "aarch64" ] && arch="arm64"

  curl -sSL -O "https://github.com/jesseduffield/lazygit/releases/download/${ver}/lazygit_${ver#v}_Linux_${arch}.tar.gz"
  tar -xzf lazygit_*.tar.gz
  mkdir -p "$HOME/.local/bin"
  mv lazygit "$HOME/.local/bin/"
  chmod +x "$HOME/.local/bin/lazygit"

  cd - >/dev/null
  rm -rf "$tmp"

  success "Lazygit installation completed"
}

final_cleanup() {
  info "Cleaning up..."
  get_sudo
  $SUDO_CMD zypper cc || true
  mkdir -p "$HOME/workspace" "$HOME/projects" "$HOME/.cache/fish" "$HOME/.cache/ccache"
  success "Cleanup completed"
}

show_completion() {
  echo ""
  echo -e "${MAGENTA}>> Done${NC}"
  success "openSUSE bootstrap completed"
  echo "  Mirror: $( [ "$SELECTED_MIRROR" = "default" ] && echo "default (unchanged)" || echo "${MIRROR_MAP[$SELECTED_MIRROR]}" )"
  echo "  Installed: essential CLI tools, fish + fzf.fish + zoxide, atuin, miniforge, lazygit"
  echo "  Next step: sign in again, then run 'fish'"
}

main() {
  clear
  echo ""
  msg "$BOLD$MAGENTA" "openSUSE bootstrap script v1.0"
  msg "$WHITE" "For openSUSE Tumbleweed only"

  show_intro

  section "1/9 Detect system"
  detect_and_validate_distro

  section "2/9 Select mirror"
  select_mirror

  if [ "$SELECTED_MIRROR" != "default" ]; then
    section "3/9 Switch repositories"
    configure_opensuse_mirror "$SELECTED_MIRROR"
  else
    info "Keeping default repositories unchanged"
  fi

  section "4/9 Update system"
  update_system

  section "5/9 Install essential CLI tools"
  install_base_packages

  section "6/9 Configure Fish"
  install_fish
  install_fish_plugins

  section "7/9 Install Atuin"
  install_atuin

  section "8/9 Install Miniforge"
  install_miniforge

  section "9/9 Install helpers"
  install_lazygit

  final_cleanup
  show_completion
}

main "$@"
