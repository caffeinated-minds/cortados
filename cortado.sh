#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# cortado.sh — Arch bootstrap (repo-only, no AUR, no Flatpak)
#
# Installs:
# - Hyprland stack (Wayland, bar, launcher, notifications, screenshots, clipboard)
# - PipeWire + WirePlumber (no pipewire-jack to avoid jack2 conflicts)
# - NetworkManager + Bluetooth
# - Terminal: Alacritty
# - Browser: Chromium (+ set default)
# - Neovim + LazyVim starter
# - Practical CLI + DevOps tooling (best-effort for repo variance)
#
# Includes:
# - Waybar click actions:
#   - Audio icon -> pavucontrol
#   - Network icon -> nm-connection-editor
#   - Bluetooth icon -> blueman-manager
#
# Wi-Fi reliability:
# - Ensures NetworkManager is enabled/started
# - If offline and nmcli exists, prompts interactively to connect to Wi-Fi
# - After connection, forces the connection to autoconnect on boot
# - Also sets all saved Wi-Fi profiles to autoconnect=yes (safe default)
#
# Usage:
#   chmod +x cortado.sh
#   ./cortado.sh
#
# Optional env vars:
#   DETACH_LAZYVIM=1   # remove ~/.config/nvim/.git after cloning (default: 1)
#   FORCE_NM_DNS=1     # force DNS 1.1.1.1/8.8.8.8 via NetworkManager (default: 0)
# ==============================================================================

LOG_PREFIX="[cortado]"
say() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
die() { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

run_sudo() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then sudo "$@"; else "$@"; fi
}

# ------------------------------------------------------------------------------
# Detect OS
# ------------------------------------------------------------------------------
require_pacman_system() {
  [[ -r /etc/os-release ]] || die "/etc/os-release missing"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    arch|endeavouros|manjaro|garuda|artix|arcolinux|cachyos|omarchy) : ;;
    *) die "This script is for pacman-based systems. Detected ID=${ID:-unknown}" ;;
  esac
  need_cmd pacman
}

# ------------------------------------------------------------------------------
# Network / DNS preflight
# ------------------------------------------------------------------------------
ensure_network_services() {
  say "Ensuring network services are available..."

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
      say "DNS OK: ${host}"
      return 0
    fi
    sleep 1
  done

  say "DNS failed for ${host}. Debug:"
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

is_online() {
  ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && getent ahosts github.com >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# Wi-Fi: ensure saved connections autoconnect (so reboot comes online)
# ------------------------------------------------------------------------------
ensure_wifi_autoconnect() {
  command -v nmcli >/dev/null 2>&1 || return 0

  # Ensure NM is running (no harm if already)
  run_sudo systemctl enable --now NetworkManager >/dev/null 2>&1 || true

  # 1) Make *active* Wi-Fi connection autoconnect with higher priority
  local active_wifi_con
  active_wifi_con="$(
    nmcli -t -f NAME,TYPE con show --active 2>/dev/null \
      | awk -F: '$2=="wifi"{print $1; exit}'
  )"

  if [[ -n "${active_wifi_con:-}" ]]; then
    say "Setting autoconnect for active Wi-Fi connection: ${active_wifi_con}"
    nmcli connection modify "${active_wifi_con}" connection.autoconnect yes >/dev/null 2>&1 || true
    nmcli connection modify "${active_wifi_con}" connection.autoconnect-priority 10 >/dev/null 2>&1 || true
  fi

  # 2) Ensure all saved Wi-Fi connections are set to autoconnect=yes (safe default)
  local wifi_cons
  wifi_cons="$(nmcli -t -f NAME,TYPE con show 2>/dev/null | awk -F: '$2=="wifi"{print $1}')"
  if [[ -n "${wifi_cons:-}" ]]; then
    while IFS= read -r c; do
      [[ -n "$c" ]] || continue
      nmcli connection modify "$c" connection.autoconnect yes >/dev/null 2>&1 || true
    done <<<"$wifi_cons"
    say "Ensured autoconnect=yes for saved Wi-Fi profiles."
  fi
}

# ------------------------------------------------------------------------------
# Interactive Wi-Fi connect (nmcli)
# ------------------------------------------------------------------------------
interactive_wifi_connect_if_offline() {
  command -v nmcli >/dev/null 2>&1 || return 0

  if is_online; then
    say "Network appears online; skipping Wi-Fi prompt."
    ensure_wifi_autoconnect
    return 0
  fi

  if nmcli -t -f TYPE,STATE dev status 2>/dev/null | grep -q '^ethernet:connected'; then
    say "Ethernet connected but DNS/IP check failed; continuing without Wi-Fi prompt."
    return 0
  fi

  local wifi_dev
  wifi_dev="$(nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
  [[ -n "${wifi_dev:-}" ]] || { say "No Wi-Fi device detected; skipping Wi-Fi prompt."; return 0; }

  if command -v rfkill >/dev/null 2>&1; then
    run_sudo rfkill unblock wifi >/dev/null 2>&1 || true
  fi
  nmcli radio wifi on >/dev/null 2>&1 || true

  say "Offline detected. Starting interactive Wi-Fi setup (device: ${wifi_dev})."
  say "Scanning networks..."
  nmcli -f SSID,SECURITY,SIGNAL dev wifi list ifname "${wifi_dev}" || true

  local attempts=0
  local max_attempts=3

  while (( attempts < max_attempts )); do
    attempts=$((attempts+1))

    local ssid sec km psk
    read -r -p "Enter SSID (Wi-Fi name). Leave empty to re-list: " ssid
    if [[ -z "${ssid}" ]]; then
      nmcli -f SSID,SECURITY,SIGNAL dev wifi list ifname "${wifi_dev}" || true
      continue
    fi

    sec="$(nmcli -t -f SSID,SECURITY dev wifi list ifname "${wifi_dev}" 2>/dev/null | awk -F: -v s="${ssid}" '$1==s{print $2; exit}')"
    sec="${sec:-unknown}"

    if [[ "${sec}" == "--" || "${sec}" == "NONE" ]]; then
      say "Detected open network (no password). Connecting..."
      if nmcli dev wifi connect "${ssid}" ifname "${wifi_dev}"; then
        break
      fi
      say "Connect failed. Try again."
      continue
    fi

    if echo "${sec}" | grep -qi 'WPA3'; then
      km="sae"
    else
      km="wpa-psk"
    fi

    read -r -s -p "Enter Wi-Fi password for '${ssid}': " psk
    echo ""

    say "Connecting to '${ssid}' (security: ${sec}, key-mgmt: ${km})..."
    if nmcli dev wifi connect "${ssid}" password "${psk}" ifname "${wifi_dev}" -- 802-11-wireless-security.key-mgmt "${km}"; then
      break
    fi

    say "Connect failed (attempt ${attempts}/${max_attempts})."
  done

  # After connection attempts, ensure it will autoconnect on future boots
  ensure_wifi_autoconnect

  if is_online; then
    say "Online confirmed."
    return 0
  fi

  if [[ "${FORCE_NM_DNS:-0}" == "1" ]]; then
    force_nm_dns
  fi

  if is_online; then
    say "Online confirmed after DNS override."
    return 0
  fi

  die "Still offline after Wi-Fi attempts. Connect to a network, then rerun this script."
}

# ------------------------------------------------------------------------------
# Pacman
# ------------------------------------------------------------------------------
pacman_bootstrap() {
  say "Refreshing keyring + syncing databases…"
  run_sudo pacman -Sy --noconfirm archlinux-keyring >/dev/null 2>&1 || true
  run_sudo pacman -Syyu --noconfirm || true
}

pacman_install_strict() {
  local pkgs=("$@")
  say "Installing (strict) (${#pkgs[@]}): ${pkgs[*]}"
  run_sudo pacman -S --noconfirm --needed "${pkgs[@]}"
}

pacman_install_best_effort() {
  local pkgs=("$@")
  local ok=()
  local missing=()

  for p in "${pkgs[@]}"; do
    if pacman -Si "$p" >/dev/null 2>&1; then
      ok+=("$p")
    else
      missing+=("$p")
    fi
  done

  if ((${#missing[@]} > 0)); then
    say "Skipping missing packages (not in current repos): ${missing[*]}"
  fi

  if ((${#ok[@]} > 0)); then
    say "Installing (best-effort) (${#ok[@]}): ${ok[*]}"
    run_sudo pacman -S --noconfirm --needed "${ok[@]}" || true
  fi
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
      say "Repo already present: $dest (skipping clone)"
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
# Package sets
# ------------------------------------------------------------------------------
define_packages() {
  BASE_PKGS=(
    base-devel
    git curl wget ca-certificates
    unzip zip
    gnupg
    openssh
    rsync
    jq yq
    ripgrep fd
    fzf
    bat eza
    btop htop
    tmux
    neovim
    shellcheck shfmt
    tree
  )

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

  # Audio: PipeWire (no pipewire-jack to avoid jack2 conflicts)
  HW_PKGS=(
    pipewire pipewire-alsa pipewire-pulse
    wireplumber
    pavucontrol
    networkmanager
    network-manager-applet   # provides nm-connection-editor on Arch
    bluez bluez-utils
    blueman
  )

  FONTS_PKGS=(
    ttf-hack-nerd
    noto-fonts noto-fonts-emoji
  )

  TERMINAL_PKGS=( alacritty )
  BROWSER_PKGS=( chromium )

  DEVOPS_PKGS=(
    terraform
    terragrunt
    kubectl
    kustomize
    helm
    k9s
    sops
    age
    aws-cli
    azure-cli
    docker docker-compose
    python python-pip
    go
    nodejs npm
    kubectx
    stern
    lazygit
  )

  EXTRAS_PKGS=(
    less
    man-db man-pages
    inetutils
    bind
    traceroute
    openssl
  )
}

# ------------------------------------------------------------------------------
# Post-install
# ------------------------------------------------------------------------------
enable_services() {
  say "Enabling core services…"
  run_sudo systemctl enable --now NetworkManager >/dev/null 2>&1 || true
  run_sudo systemctl enable --now bluetooth >/dev/null 2>&1 || true

  if systemctl list-unit-files 2>/dev/null | grep -q '^docker\.service'; then
    run_sudo systemctl enable --now docker >/dev/null 2>&1 || true
    if getent group docker >/dev/null 2>&1; then
      if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
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
terminal=alacritty -e
prompt=>
layer=overlay
fields=name,generic,comment,categories,filename,keywords

[border]
width=2
radius=8
EOF
}

setup_waybar_config() {
  local dir="${HOME}/.config/waybar"
  local cfg="${dir}/config.jsonc"
  local css="${dir}/style.css"
  mkdir -p "$dir"

  if [[ -f "$cfg" ]]; then
    say "Waybar config exists: $cfg (skipping)"
  else
    say "Writing Waybar config: $cfg"
    cat >"$cfg" <<'EOF'
{
  "layer": "top",
  "position": "top",
  "spacing": 8,

  "modules-left": ["hyprland/workspaces", "hyprland/window"],
  "modules-center": ["clock"],
  "modules-right": ["pulseaudio", "network", "bluetooth", "tray"],

  "clock": {
    "format": "{:%a %d %b  %H:%M}"
  },

  "pulseaudio": {
    "format": "{icon} {volume}%",
    "format-muted": "󰝟 muted",
    "format-icons": {
      "default": ["󰕿", "󰖀", "󰕾"]
    },
    "on-click": "pavucontrol"
  },

  "network": {
    "format-wifi": "󰤨 {signalStrength}%",
    "format-ethernet": "󰈀",
    "format-disconnected": "󰤭",
    "tooltip-format-wifi": "{essid} ({signalStrength}%)",
    "tooltip-format-ethernet": "{ifname}",
    "on-click": "nm-connection-editor"
  },

  "bluetooth": {
    "format-on": "",
    "format-off": "",
    "format-disabled": "",
    "tooltip-format": "{status}",
    "on-click": "blueman-manager"
  }
}
EOF
  fi

  if [[ -f "$css" ]]; then
    say "Waybar style exists: $css (skipping)"
  else
    say "Writing Waybar style: $css"
    cat >"$css" <<'EOF'
* {
  font-family: "Hack Nerd Font", "Hack", monospace;
  font-size: 12px;
}

window#waybar {
  background: rgba(20, 20, 20, 0.85);
  color: #e6e6e6;
}

#workspaces button {
  padding: 0 8px;
  margin: 4px 2px;
  border-radius: 8px;
}

#pulseaudio, #network, #bluetooth, #tray, #clock {
  padding: 0 10px;
  margin: 4px 0;
  border-radius: 8px;
  background: rgba(255, 255, 255, 0.06);
}
EOF
  fi
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

set_default_browser_chromium() {
  if command -v xdg-settings >/dev/null 2>&1; then
    xdg-settings set default-web-browser chromium.desktop >/dev/null 2>&1 || true
  fi
  if command -v xdg-mime >/dev/null 2>&1; then
    xdg-mime default chromium.desktop x-scheme-handler/http >/dev/null 2>&1 || true
    xdg-mime default chromium.desktop x-scheme-handler/https >/dev/null 2>&1 || true
  fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  require_pacman_system
  need_cmd systemctl
  need_cmd getent

  ensure_network_services

  # If you're offline and nmcli exists, prompt to connect to Wi-Fi.
  # (If you run from minimal base without NM/nmcli, this is a no-op.)
  interactive_wifi_connect_if_offline

  if [[ "${FORCE_NM_DNS:-0}" == "1" ]]; then
    force_nm_dns
  fi

  # Gate on DNS for common bootstrap hosts
  if ! wait_for_dns github.com 30; then
    force_nm_dns
    wait_for_dns github.com 60 || die "DNS not working; connect to network and retry."
  fi
  if ! wait_for_dns raw.githubusercontent.com 30; then
    force_nm_dns
    wait_for_dns raw.githubusercontent.com 60 || die "DNS not working; connect to network and retry."
  fi
  wait_for_http "https://github.com" 10 || say "Warning: HTTPS check failed; continuing."

  pacman_bootstrap
  define_packages

  pacman_install_strict \
    "${BASE_PKGS[@]}" \
    "${WAYLAND_PKGS[@]}" \
    "${HW_PKGS[@]}" \
    "${FONTS_PKGS[@]}" \
    "${TERMINAL_PKGS[@]}" \
    "${BROWSER_PKGS[@]}" \
    "${EXTRAS_PKGS[@]}"

  pacman_install_best_effort "${DEVOPS_PKGS[@]}"

  enable_services

  # After installing NetworkManager stack, enforce autoconnect again
  ensure_wifi_autoconnect

  setup_fuzzel_config
  setup_waybar_config
  setup_lazyvim
  set_default_browser_chromium

  say "Complete."
  say "Wi-Fi on boot:"
  say "  - NetworkManager enabled"
  say "  - Saved Wi-Fi profiles set to autoconnect=yes"
  say "Waybar click actions:"
  say "  Audio -> pavucontrol"
  say "  Network -> nm-connection-editor"
  say "  Bluetooth -> blueman-manager"
  say "If you were added to the docker group: log out/in to use docker without sudo."
  say "Run: nvim (to let plugins install)"
}

main "$@"
