#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# cortado.sh — Arch bootstrap (repo-only, no AUR, no Flatpak)
# Works when run as: curl -fsSL https://.../cortado.sh | bash
#
# Key properties:
# - System tasks run via sudo
# - User configs ALWAYS target the real login user (SUDO_USER if present)
# - No reliance on local repo files
#
# Controls (env vars):
#   ENABLE_AUTOLOGIN=1    # enable auto-login on tty1 for target user (default: 0)
#   ENABLE_AUTOHYPR=1     # auto-start Hyprland on tty1 login (default: 1)
#   FORCE_HYPR_CONF=1     # backup+replace ~/.config/hypr/hyprland.conf (default: 0)
#   FORCE_WAYBAR=1        # backup+replace waybar config/style (default: 0)
#   DETACH_LAZYVIM=1      # remove ~/.config/nvim/.git after cloning (default: 1)
#   FORCE_NM_DNS=1        # force DNS 1.1.1.1/8.8.8.8 via NetworkManager (default: 0)
# ==============================================================================

LOG_PREFIX="[cortado]"
say() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
die() { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# --- sudo that works with curl|bash (stdin not a tty) ---
sudo_preflight() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    [[ -e /dev/tty ]] || die "Need sudo password but no /dev/tty (running non-interactive)."
    sudo -v </dev/tty || die "sudo auth failed"
  else
    sudo -v || die "sudo auth failed"
  fi
}

run_sudo() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if [[ ! -t 0 ]]; then
      sudo "$@" </dev/tty
    else
      sudo "$@"
    fi
  else
    "$@"
  fi
}

# --- determine target user/home (critical for user configs) ---
TARGET_USER="${SUDO_USER:-${USER:-}}"
[[ -n "${TARGET_USER:-}" ]] || die "Could not determine target user."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "${TARGET_HOME:-}" && -d "$TARGET_HOME" ]] || die "Could not determine home for user '$TARGET_USER'."

as_user() {
  # Run under target user, with correct HOME, even if script is root.
  local cmd="$1"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    run_sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" USER="$TARGET_USER" bash -lc "$cmd"
  else
    env HOME="$TARGET_HOME" USER="$TARGET_USER" bash -lc "$cmd"
  fi
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
# Network / DNS
# ------------------------------------------------------------------------------
ensure_network_services() {
  say "Ensuring network services are available..."
  if systemctl list-unit-files 2>/dev/null | grep -q '^NetworkManager\.service'; then
    run_sudo systemctl enable --now NetworkManager >/dev/null 2>&1 || true
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved\.service'; then
    run_sudo systemctl enable --now systemd-resolved >/dev/null 2>&1 || true
    if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
      run_sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf >/dev/null 2>&1 || true
    fi
  fi
}

is_online() { ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && getent ahosts github.com >/dev/null 2>&1; }

force_nm_dns() {
  command -v nmcli >/dev/null 2>&1 || return 0
  local con
  con="$(nmcli -t -f NAME,TYPE con show --active 2>/dev/null | awk -F: '$2=="wifi"||$2=="ethernet"{print $1; exit}')"
  [[ -n "${con:-}" ]] || return 0
  say "Forcing NetworkManager DNS on '$con' to: 1.1.1.1 8.8.8.8"
  run_sudo nmcli con mod "$con" ipv4.ignore-auto-dns yes >/dev/null 2>&1 || true
  run_sudo nmcli con mod "$con" ipv4.dns "1.1.1.1 8.8.8.8" >/dev/null 2>&1 || true
  run_sudo nmcli con up "$con" >/dev/null 2>&1 || true
}

wait_for_dns() {
  local host="${1:-github.com}" tries="${2:-60}"
  say "Waiting for DNS resolution of ${host} (up to ${tries}s)"
  for ((i=1; i<=tries; i++)); do
    getent ahosts "$host" >/dev/null 2>&1 && { say "DNS OK: ${host}"; return 0; }
    sleep 1
  done
  return 1
}

interactive_wifi_connect_if_offline() {
  command -v nmcli >/dev/null 2>&1 || return 0

  if is_online; then
    say "Online; skipping Wi-Fi prompt."
    return 0
  fi

  local wifi_dev
  wifi_dev="$(nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
  [[ -n "${wifi_dev:-}" ]] || { say "No Wi-Fi device detected; skipping Wi-Fi prompt."; return 0; }

  command -v rfkill >/dev/null 2>&1 && run_sudo rfkill unblock wifi >/dev/null 2>&1 || true
  nmcli radio wifi on >/dev/null 2>&1 || true

  say "Offline detected. Interactive Wi-Fi (device: ${wifi_dev})."
  nmcli -f SSID,SECURITY,SIGNAL dev wifi list ifname "${wifi_dev}" || true

  local attempts=0 max_attempts=3
  while (( attempts < max_attempts )); do
    attempts=$((attempts+1))

    local ssid sec km psk
    read -r -p "SSID (empty to re-list): " ssid
    if [[ -z "${ssid}" ]]; then
      nmcli -f SSID,SECURITY,SIGNAL dev wifi list ifname "${wifi_dev}" || true
      continue
    fi

    sec="$(nmcli -t -f SSID,SECURITY dev wifi list ifname "${wifi_dev}" 2>/dev/null | awk -F: -v s="${ssid}" '$1==s{print $2; exit}')"
    sec="${sec:-unknown}"

    if [[ "${sec}" == "--" || "${sec}" == "NONE" ]]; then
      nmcli dev wifi connect "${ssid}" ifname "${wifi_dev}" && break || continue
    fi

    echo "${sec}" | grep -qi 'WPA3' && km="sae" || km="wpa-psk"
    read -r -s -p "Password for '${ssid}': " psk; echo ""
    nmcli dev wifi connect "${ssid}" password "${psk}" ifname "${wifi_dev}" -- 802-11-wireless-security.key-mgmt "${km}" && break || true
  done

  if ! is_online && [[ "${FORCE_NM_DNS:-0}" == "1" ]]; then
    force_nm_dns
  fi

  is_online || die "Still offline. Connect to a network, then rerun."
}

# ------------------------------------------------------------------------------
# Pacman helpers
# ------------------------------------------------------------------------------
pacman_bootstrap() {
  say "Refreshing keyring + syncing databases…"
  run_sudo pacman -Sy --noconfirm archlinux-keyring >/dev/null 2>&1 || true
  run_sudo pacman -Syyu --noconfirm || true
}
pacman_install_strict() { run_sudo pacman -S --noconfirm --needed "$@"; }
pacman_install_best_effort() {
  local ok=() missing=()
  for p in "$@"; do pacman -Si "$p" >/dev/null 2>&1 && ok+=("$p") || missing+=("$p"); done
  ((${#missing[@]})) && say "Skipping missing: ${missing[*]}"
  ((${#ok[@]})) && run_sudo pacman -S --noconfirm --needed "${ok[@]}" || true
}

# ------------------------------------------------------------------------------
# Package sets
# ------------------------------------------------------------------------------
define_packages() {
  BASE_PKGS=(base-devel git curl wget ca-certificates unzip zip gnupg openssh rsync jq yq ripgrep fd fzf bat eza btop htop tmux neovim shellcheck shfmt tree)
  WAYLAND_PKGS=(hyprland xdg-desktop-portal xdg-desktop-portal-hyprland waybar mako fuzzel wl-clipboard grim slurp swappy brightnessctl playerctl polkit-gnome qt5-wayland qt6-wayland dbus)
  HW_PKGS=(pipewire pipewire-alsa pipewire-pulse wireplumber pavucontrol networkmanager network-manager-applet bluez bluez-utils blueman)
  FONTS_PKGS=(ttf-hack-nerd noto-fonts noto-fonts-emoji)
  TERMINAL_PKGS=(alacritty)
  BROWSER_PKGS=(chromium)
  DEVOPS_PKGS=(terraform terragrunt kubectl kustomize helm k9s sops age aws-cli azure-cli docker docker-compose python python-pip go nodejs npm kubectx stern lazygit)
  EXTRAS_PKGS=(less man-db man-pages inetutils bind traceroute openssl)
}

# ------------------------------------------------------------------------------
# Services and Bluetooth fixes
# ------------------------------------------------------------------------------
enable_services() {
  say "Enabling services…"
  run_sudo systemctl enable --now NetworkManager >/dev/null 2>&1 || true
  run_sudo systemctl enable --now bluetooth >/dev/null 2>&1 || true

  if systemctl list-unit-files 2>/dev/null | grep -q '^docker\.service'; then
    run_sudo systemctl enable --now docker >/dev/null 2>&1 || true
    if getent group docker >/dev/null 2>&1; then
      if ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
        run_sudo usermod -aG docker "$TARGET_USER" || true
      fi
    fi
  fi
}

setup_bluez_autenable() {
  say "Configuring BlueZ AutoEnable (drop-in)"
  run_sudo mkdir -p /etc/bluetooth/main.conf.d
  run_sudo tee /etc/bluetooth/main.conf.d/10-cortado.conf >/dev/null <<'EOF'
[General]
AutoEnable=true
EOF
  run_sudo systemctl restart bluetooth >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# User configs (always into TARGET_HOME)
# ------------------------------------------------------------------------------
setup_fuzzel_config() {
  local dir cfg
  dir="${TARGET_HOME}/.config/fuzzel"
  cfg="${dir}/fuzzel.ini"
  as_user "mkdir -p '$dir'"
  as_user "[[ -f '$cfg' ]] && exit 0
cat > '$cfg' <<'EOF'
[main]
terminal=alacritty -e
prompt=>
layer=overlay
fields=name,generic,comment,categories,filename,keywords

[border]
width=2
radius=8
EOF"
}

setup_waybar_config() {
  local dir cfg css force ts
  dir="${TARGET_HOME}/.config/waybar"
  cfg="${dir}/config.jsonc"
  css="${dir}/style.css"
  force="${FORCE_WAYBAR:-0}"
  ts="$(date +%Y%m%d%H%M%S)"

  as_user "mkdir -p '$dir'"

  if [[ -f "$cfg" && "$force" == "1" ]]; then
    as_user "cp -a '$cfg' '${cfg}.bak.${ts}'"
  fi
  if [[ -f "$css" && "$force" == "1" ]]; then
    as_user "cp -a '$css' '${css}.bak.${ts}'"
  fi

  if [[ ! -f "$cfg" || "$force" == "1" ]]; then
    as_user "cat > '$cfg' <<'EOF'
{
  \"layer\": \"top\",
  \"position\": \"top\",
  \"spacing\": 8,

  \"modules-left\": [\"hyprland/workspaces\", \"hyprland/window\"],
  \"modules-center\": [\"clock\"],
  \"modules-right\": [\"pulseaudio\", \"network\", \"bluetooth\", \"tray\"],

  \"clock\": { \"format\": \"{:%a %d %b  %H:%M}\" },

  \"pulseaudio\": {
    \"format\": \"{icon} {volume}%\",
    \"format-muted\": \"󰝟 muted\",
    \"format-icons\": { \"default\": [\"󰕿\", \"󰖀\", \"󰕾\"] },
    \"on-click\": \"pavucontrol\"
  },

  \"network\": {
    \"format-wifi\": \"󰤨 {signalStrength}%\",
    \"format-ethernet\": \"󰈀\",
    \"format-disconnected\": \"󰤭\",
    \"tooltip-format-wifi\": \"{essid} ({signalStrength}%)\",
    \"tooltip-format-ethernet\": \"{ifname}\",
    \"on-click\": \"nm-connection-editor\"
  },

  \"bluetooth\": {
    \"format-on\": \"\",
    \"format-off\": \"\",
    \"format-disabled\": \"\",
    \"tooltip-format\": \"{status}\",
    \"on-click\": \"blueman-manager\"
  }
}
EOF"
  fi

  if [[ ! -f "$css" || "$force" == "1" ]]; then
    as_user "cat > '$css' <<'EOF'
* { font-family: \"Hack Nerd Font\", \"Hack\", monospace; font-size: 12px; }
window#waybar { background: rgba(20, 20, 20, 0.85); color: #e6e6e6; }
#workspaces button { padding: 0 8px; margin: 4px 2px; border-radius: 8px; }
#pulseaudio, #network, #bluetooth, #tray, #clock {
  padding: 0 10px; margin: 4px 0; border-radius: 8px;
  background: rgba(255, 255, 255, 0.06);
}
EOF"
  fi
}

setup_lazyvim() {
  local nvim_dir
  nvim_dir="${TARGET_HOME}/.config/nvim"
  as_user "command -v git >/dev/null 2>&1 || exit 0
mkdir -p '${TARGET_HOME}/.config'
if [[ -d '${nvim_dir}/.git' || -d '${nvim_dir}' && -f '${nvim_dir}/lua/config/lazy.lua' ]]; then
  exit 0
fi
git clone --depth 1 https://github.com/LazyVim/starter.git '${nvim_dir}' || true
if [[ '${DETACH_LAZYVIM:-1}' == '1' ]]; then
  rm -rf '${nvim_dir}/.git' 2>/dev/null || true
fi"
}

set_default_browser_chromium() {
  as_user "command -v xdg-settings >/dev/null 2>&1 && xdg-settings set default-web-browser chromium.desktop >/dev/null 2>&1 || true
command -v xdg-mime >/dev/null 2>&1 && {
  xdg-mime default chromium.desktop x-scheme-handler/http >/dev/null 2>&1 || true
  xdg-mime default chromium.desktop x-scheme-handler/https >/dev/null 2>&1 || true
}"
}

setup_hyprland_conf() {
  local dir conf force ts
  dir="${TARGET_HOME}/.config/hypr"
  conf="${dir}/hyprland.conf"
  force="${FORCE_HYPR_CONF:-0}"
  ts="$(date +%Y%m%d%H%M%S)"

  as_user "mkdir -p '$dir'"

  if [[ -f "$conf" && "$force" != "1" ]]; then
    return 0
  fi
  if [[ -f "$conf" && "$force" == "1" ]]; then
    as_user "cp -a '$conf' '${conf}.bak.${ts}'"
  fi

  as_user "cat > '$conf' <<'EOF'
$mod = SUPER
$term = alacritty
$menu = fuzzel
$browser = chromium

# Monitors (edit after `hyprctl monitors` if connector names differ)
monitor=DP-1,3440x1440@60,0x0,1
monitor=eDP-1,preferred,3440x0,1

input {
  kb_layout = gb
  follow_mouse = 1
  touchpad { natural_scroll = true }
}

general { gaps_in = 6  gaps_out = 10  border_size = 2  layout = dwindle }
decoration { rounding = 10  blur { enabled = false } }
animations { enabled = false }
misc { disable_hyprland_logo = true  disable_splash_rendering = true }

exec-once = waybar
exec-once = mako
exec-once = blueman-applet
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1

bind = $mod, RETURN, exec, $term
bind = $mod, D, exec, $menu
bind = $mod, B, exec, $browser

bind = $mod, Q, killactive
bind = $mod SHIFT, Q, exit

bind = $mod, F, fullscreen
bind = $mod, SPACE, togglefloating
bind = $mod, P, pseudo
bind = $mod, T, togglesplit

bind = $mod, H, movefocus, l
bind = $mod, L, movefocus, r
bind = $mod, K, movefocus, u
bind = $mod, J, movefocus, d

bind = $mod SHIFT, H, movewindow, l
bind = $mod SHIFT, L, movewindow, r
bind = $mod SHIFT, K, movewindow, u
bind = $mod SHIFT, J, movewindow, d

bindm = $mod, mouse:272, movewindow
bindm = $mod, mouse:273, resizewindow
EOF"
}

setup_hyprland_startup() {
  [[ "${ENABLE_AUTOHYPR:-1}" == "1" ]] || return 0

  local profile marker start_cmd
  profile="${TARGET_HOME}/.bash_profile"
  marker="# >>> cortado hyprland autostart >>>"

  # Prefer start-hyprland to avoid the warning; fallback if missing.
  if command -v start-hyprland >/dev/null 2>&1; then
    start_cmd="exec start-hyprland"
  else
    start_cmd="exec dbus-run-session Hyprland"
  fi

  as_user "touch '$profile'"
  as_user "grep -qF '$marker' '$profile' && exit 0
cat >> '$profile' <<'EOF'

# >>> cortado hyprland autostart >>>
if [[ -z \"\$WAYLAND_DISPLAY\" && \"\${XDG_VTNR:-0}\" -eq 1 ]]; then
  ${start_cmd}
fi
# <<< cortado hyprland autostart <<<
EOF"
}

setup_tty_autologin() {
  [[ "${ENABLE_AUTOLOGIN:-0}" == "1" ]] || return 0
  run_sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
  run_sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${TARGET_USER} --noclear %I \$TERM
EOF
  run_sudo systemctl daemon-reexec
  run_sudo systemctl restart getty@tty1 >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  require_pacman_system
  need_cmd systemctl
  need_cmd getent

  say "Target user: $TARGET_USER"
  say "Target home: $TARGET_HOME"

  sudo_preflight

  ensure_network_services
  interactive_wifi_connect_if_offline

  if ! wait_for_dns github.com 20; then
    [[ "${FORCE_NM_DNS:-0}" == "1" ]] && force_nm_dns
    wait_for_dns github.com 40 || die "DNS still not working."
  fi

  pacman_bootstrap
  define_packages

  say "Installing packages…"
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
  setup_bluez_autenable

  setup_fuzzel_config
  setup_waybar_config
  setup_lazyvim
  set_default_browser_chromium
  setup_hyprland_conf
  setup_hyprland_startup
  setup_tty_autologin

  say "Complete."
}

main "$@"
