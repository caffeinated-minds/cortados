#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# cortados.sh — Omarchy-like Arch bootstrap (NO AUR)
# - Robust network/DNS preflight (fixes "Could not resolve host: github.com")
# - Ensures pacman repos are enabled (fixes "target not found: base/..." in many cases)
# - Installs a full, practical workstation stack + DevOps tooling
# - Installs fuzzel as launcher
# - Sets up LazyVim starter (optional detach)
#
# Usage:
#   chmod +x cortados.sh
#   ./cortados.sh
#
# Optional env vars:
#   DETACH_LAZYVIM=1   # remove ~/.config/nvim/.git after cloning (default: 1)
#   FORCE_NM_DNS=1     # force DNS 1.1.1.1/8.8.8.8 via NetworkManager (default: 0)
# ==============================================================================

LOG_PREFIX="[cortados]"
say() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
die() { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

run_sudo() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then sudo "$@"; else "$@"; fi
}

# ------------------------------------------------------------------------------
# Detect OS
# ------------------------------------------------------------------------------
require_arch() {
  [[ -r /etc/os-release ]] || die "/etc/os-release missing"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    arch|endeavouros|manjaro|garuda|artix|arcolinux|cachyos|omarchy) : ;;
    *) die "This script is for Arch/pacman systems. Detected ID=${ID:-unknown}" ;;
  esac
}

# ------------------------------------------------------------------------------
# Network / DNS preflight
# ------------------------------------------------------------------------------
ensure_network_services() {
  say "Ensuring core network services are running..."

  if systemctl list-unit-files 2>/dev/null | grep -q '^NetworkManager\.service'; then
    run_sudo systemctl enable --now NetworkManager >/dev/null 2>&1 || true
  fi

  if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved\.service'; then
    run_sudo systemctl enable --now systemd-resolved >/dev/null 2>&1 || true
    if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
      run_sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || true
    fi
  fi
}

force_nm_dns() {
  command -v nmcli >/dev/null 2>&1 || return 0
  local con
  con="$(nmcli -t -f NAME,TYPE con show --active 2>/dev/null | awk -F: '$2=="wifi"||$2=="ethernet"{print $1; exit}')"
  [[ -n "${con:-}" ]] || return 0

  say "Forcing NetworkManager DNS on '$con' to: 1.1.1.1 8.8.8.8"
  run_sudo nmcli con mod "$con" ipv4.ignore-auto-dns yes || true
  run_sudo nmcli con mod "$con" ipv4.dns "1.1.1.1 8.8.8.8" || true
  run_sudo nmcli con up "$con" >/dev/null 2>&1 || true
}

wait_for_dns() {
  local host="${1:-github.com}"
  local tries="${2:-60}"

  say "Waiting for DNS resolution of ${host} (up to ${tries}s)"
  for ((i=1; i<=tries; i++)); do
    if getent ahosts "$host" >/dev/null 2>&1; then
      say "DNS OK."
      return 0
    fi
    sleep 1
  done

  say "DNS failed. Debug:"
  command -v resolvectl >/dev/null 2>&1 && resolvectl status || true
  cat /etc/resolv.conf || true
  return 1
}

wait_for_http() {
  local url="${1:-https://github.com}"
  local tries="${2:-20}"

  command -v curl >/dev/null 2>&1 || return 0
  say "Checking HTTPS reachability: ${url} (up to ${tries}s)"
  for ((i=1; i<=tries; i++)); do
    if curl -fsSL --max-time 5 "$url" >/dev/null 2>&1; then
      say "HTTPS OK."
      return 0
    fi
    sleep 1
  done
  return 1
}

# ------------------------------------------------------------------------------
# Pacman sanity / repos
# ------------------------------------------------------------------------------
ensure_pacman_repos_enabled() {
  # Common cause of "target not found: base linux ..." is pacman.conf repos commented out.
  local conf="/etc/pacman.conf"
  [[ -f "$conf" ]] || die "Missing $conf"

  say "Ensuring pacman repos are enabled in $conf (core/extra/multilib)…"

  # Uncomment core and extra blocks if commented
  run_sudo sed -i \
    -e 's/^[[:space:]]*#\s*\[core\]/[core]/' \
    -e 's/^[[:space:]]*#\s*Include\s*=\s*\/etc\/pacman\.d\/mirrorlist/Include = \/etc\/pacman.d\/mirrorlist/' \
    -e 's/^[[:space:]]*#\s*\[extra\]/[extra]/' \
    "$conf"

  # Multilib: enable if you want Steam/32-bit libs; safe to enable generally.
  # Uncomment [multilib] and its Include line if present commented.
  run_sudo sed -i \
    -e 's/^[[:space:]]*#\s*\[multilib\]/[multilib]/' \
    -e 's/^[[:space:]]*#\s*Include\s*=\s*\/etc\/pacman\.d\/mirrorlist/Include = \/etc\/pacman.d\/mirrorlist/' \
    "$conf"

  # Refresh db afterwards
  run_sudo pacman -Syy --noconfirm >/dev/null 2>&1 || true
}

pacman_bootstrap() {
  need_cmd pacman

  say "Refreshing keyring + syncing databases…"
  run_sudo pacman -Sy --noconfirm archlinux-keyring >/dev/null 2>&1 || true
  run_sudo pacman -Syyu --noconfirm || true
}

pacman_install() {
  local pkgs=("$@")
  say "Installing packages (${#pkgs[@]}): ${pkgs[*]}"
  run_sudo pacman -S --noconfirm --needed "${pkgs[@]}"
}

# ------------------------------------------------------------------------------
# Git clone with retry
# ------------------------------------------------------------------------------
git_clone_retry() {
  local repo="$1"
  local dest="$2"
  local depth="${3:-1}"
  local n=0
  local max=5

  while true; do
    if [[ -d "$dest/.git" ]]; then
      say "Repo already present: $dest (skipping)"
      return 0
    fi

    if [[ -e "$dest" && ! -d "$dest/.git" ]]; then
      local backup="${dest}.bak.$(date +%Y%m%d%H%M%S)"
      say "Destination exists but is not a git repo. Moving to: $backup"
      mv "$dest" "$backup"
    fi

    say "Cloning: $repo -> $dest"
    if git clone --depth "$depth" "$repo" "$dest"; then
      return 0
    fi

    n=$((n+1))
    if [[ "$n" -ge "$max" ]]; then
      die "Failed to clone after ${max} attempts: $repo"
    fi
    say "Clone failed; retrying in $((n*2))s…"
    sleep $((n*2))
  done
}

# ------------------------------------------------------------------------------
# Packages (NO AUR)
# ------------------------------------------------------------------------------
define_packages() {
  # Core workstation / CLI
  BASE_PKGS=(
    git curl wget ca-certificates
    unzip zip
    gnupg
    openssh
    rsync
    jq yq
    ripgrep fd
    fzf
    bat eza
    btop
    htop
    tmux
    neovim
    shellcheck shfmt
    tree
  )

  # Wayland / Hyprland-ish stack (works fine on Sway too for many tools)
  WAYLAND_PKGS=(
    hyprland
    xdg-desktop-portal xdg-desktop-portal-hyprland
    waybar
    mako
    fuzzel
    wl-clipboard
    grim slurp
    swappy
    brightnessctl
    playerctl
    polkit-gnome
    qt5-wayland qt6-wayland
  )

  # Audio / Bluetooth / Network
  HW_PKGS=(
    pipewire pipewire-alsa pipewire-pulse pipewire-jack
    wireplumber
    pavucontrol
    networkmanager
    bluez bluez-utils
    blueman
  )

  # Fonts / theming basics (keep minimal; you can expand later)
  FONTS_PKGS=(
    ttf-hack-nerd
    noto-fonts noto-fonts-emoji
  )

  # Browser (pick one; Brave is usually AUR, so default to Firefox here)
  BROWSER_PKGS=(
    firefox
  )

  # Terminal
  TERMINAL_PKGS=(
    wezterm
  )

  # DevOps / Platform Engineering tools (repo-only, no AUR)
  DEVOPS_PKGS=(
    terraform
    terragrunt
    kubectl
    kustomize
    helm
    k9s
    kubectx
    stern
    sops
    age
    aws-cli
    azure-cli
    google-cloud-cli
    gh
    python python-pip
    go
    nodejs npm
    docker docker-compose
  )

  # Nice-to-have (still repo-only)
  EXTRAS_PKGS=(
    less
    man-db man-pages
    inetutils
    bind
    traceroute
    openssl
    lazygit
  )
}

# ------------------------------------------------------------------------------
# Post-install setup
# ------------------------------------------------------------------------------
enable_services() {
  say "Enabling core services…"
  run_sudo systemctl enable --now NetworkManager >/dev/null 2>&1 || true
  run_sudo systemctl enable --now bluetooth >/dev/null 2>&1 || true

  # Docker group & service (optional but common for DevOps)
  if systemctl list-unit-files 2>/dev/null | grep -q '^docker\.service'; then
    run_sudo systemctl enable --now docker >/dev/null 2>&1 || true
    if getent group docker >/dev/null 2>&1; then
      if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
        : # already in group
      else
        say "Adding user '$USER' to docker group (logout/login required)"
        run_sudo usermod -aG docker "$USER" || true
      fi
    fi
  fi
}

setup_fuzzel_config() {
  local dir="${HOME}/.config/fuzzel"
  local cfg="${dir}/fuzzel.ini"
  mkdir -p "$dir"

  if [[ -f "$cfg" ]]; then
    say "Fuzzel config exists: $cfg (skipping)"
    return 0
  fi

  say "Writing default fuzzel config: $cfg"
  cat >"$cfg" <<'EOF'
[main]
# Minimal launcher behaviour (apps only by default)
terminal=wezterm -e
prompt=>
layer=overlay
fields=name,generic,comment,categories,filename,keywords

[colors]
# Keep defaults; theme can be applied later.

[border]
width=2
radius=8
EOF
}

setup_lazyvim() {
  need_cmd git
  mkdir -p "${HOME}/.config"

  local nvim_dir="${HOME}/.config/nvim"
  git_clone_retry "https://github.com/LazyVim/starter.git" "$nvim_dir" 1

  local detach="${DETACH_LAZYVIM:-1}"
  if [[ "$detach" == "1" && -d "$nvim_dir/.git" ]]; then
    say "Detaching LazyVim starter (removing ${nvim_dir}/.git)"
    rm -rf "$nvim_dir/.git"
  fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  require_arch
  need_cmd systemctl
  need_cmd getent

  ensure_network_services

  if [[ "${FORCE_NM_DNS:-0}" == "1" ]]; then
    force_nm_dns
  fi

  # DNS fix for your exact failure
  if ! wait_for_dns github.com 30; then
    force_nm_dns
    wait_for_dns github.com 60 || die "DNS not working; connect to network and retry."
  fi
  wait_for_http "https://github.com" 15 || say "Warning: HTTPS check failed; continuing."

  ensure_pacman_repos_enabled
  pacman_bootstrap

  define_packages

  # Install full stack (repo-only)
  pacman_install \
    "${BASE_PKGS[@]}" \
    "${WAYLAND_PKGS[@]}" \
    "${HW_PKGS[@]}" \
    "${FONTS_PKGS[@]}" \
    "${BROWSER_PKGS[@]}" \
    "${TERMINAL_PKGS[@]}" \
    "${DEVOPS_PKGS[@]}" \
    "${EXTRAS_PKGS[@]}"

  enable_services
  setup_fuzzel_config
  setup_lazyvim

  say "Complete."
  say "Next: log out/in if you want docker without sudo."
  say "Run: nvim (to let plugins install)"
}

main "$@"
