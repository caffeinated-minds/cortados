#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# cortado.sh — Arch bootstrap (repo-only, no AUR, no Flatpak)
# Single-script, but correctly handles:
#  - root tasks via sudo
#  - user config tasks written to the *real* user home, even if invoked with sudo
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

run_sudo() { if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then sudo "$@"; else "$@"; fi; }

# --- determine real target user/home (critical fix) ---
TARGET_USER="${SUDO_USER:-${USER:-}}"
[[ -n "${TARGET_USER:-}" ]] || die "Could not determine target user."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "${TARGET_HOME:-}" && -d "$TARGET_HOME" ]] || die "Could not determine home for user '$TARGET_USER'."

as_user() {
  # run command as target user with correct HOME
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    run_sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" USER="$TARGET_USER" bash -lc "$*"
  else
    # already user; still enforce HOME/USER for safety
    env HOME="$TARGET_HOME" USER="$TARGET_USER" bash -lc "$*"
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
      run_sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf >/dev/null 2>&1 || true
    fi
  fi
}

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
  say "DNS failed for ${host}. Debug:"
  command -v resolvectl >/dev/null 2>&1 && resolvectl status || true
  cat /etc/resolv.conf || true
  return 1
}

wait_for_http() {
  local url="${1:-https://github.com}" tries="${2:-20}"
  command -v curl >/dev/null 2>&1 || return 0
  say "Checking HTTPS reachability: ${url} (up to ${tries}s)"
  for ((i=1; i<=tries; i++)); do
    curl -fsSL --max-time 5 "$url" >/dev/null 2>&1 && { say "HTTPS OK."; return 0; }
    sleep 1
  done
  return 1
}

is_online() { ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && getent ahosts github.com >/dev/null 2>&1; }

ensure_wifi_autoconnect() {
  command -v nmcli >/dev/null 2>&1 || return 0
  run_sudo systemctl enable --now NetworkManager >/dev/null 2>&1 || true

  local active_wifi_con
  active_wifi_con="$(nmcli -t -f NAME,TYPE con show --active 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
  if [[ -n "${active_wifi_con:-}" ]]; then
    say "Setting autoconnect for active Wi-Fi connection: ${active_wifi_con}"
    nmcli connection modify "${active_wifi_con}" connection.autoconnect yes >/dev/null 2>&1 || true
    nmcli connection modify "${active_wifi_con}" connection.autoconnect-priority 10 >/dev/null 2>&1 || true
  fi

  local wifi_cons
  wifi_cons="$(nmcli -t -f NAME,TYPE con show 2>/dev/null | awk -F: '$2=="wifi"{print $1}')"
  if [[ -n "${wifi_cons:-}" ]]; then
    while IFS= read -r c; do
      [[ -n "$c" ]] && nmcli connection modify "$c" connection.autoconnect yes >/dev/null 2>&1 || true
    done <<<"$wifi_cons"
    say "Ensured autoconnect=yes for saved Wi-Fi profiles."
  fi
}

interactive_wifi_connect_if_offline() {
  command -v nmcli >/dev/null 2>&1 || return 0
  if is_online; then
    say "Network appears online; skipping Wi-Fi prompt."
    ensure_wifi_autoconnect
    return 0
  fi

  local wifi_dev
  wifi_dev="$(nmcli -t -f DEVICE,TYPE dev status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
  [[ -n "${wifi_dev:-}" ]] || { say "No Wi-Fi device detected; skipping Wi-Fi prompt."; return 0; }

  command -v rfkill >/dev/null 2>&1 && run_sudo rfkill unblock wifi >/dev/null 2>&1 || true
  nmcli radio wifi on >/dev/null 2>&1 || true

  say "Offline detected. Starting interactive Wi-Fi setup (device: ${wifi_dev})."
  nmcli -f SSID,SECURITY,SIGNAL dev wifi list ifname "${wifi_dev}" || true

  local attempts=0 max_attempts=3
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
      say "Open network. Connecting..."
      nmcli dev wifi connect "${ssid}" ifname "${wifi_dev}" && break || { say "Connect failed."; continue; }
    fi

    echo "${sec}" | grep -qi 'WPA3' && km="sae" || km="wpa-psk"
    read -r -s -p "Enter Wi-Fi password for '${ssid}': " psk; echo ""
    say "Connecting to '${ssid}' (key-mgmt: ${km})..."
    nmcli dev wifi connect "${ssid}" password "${psk}" ifname "${wifi_dev}" -- 802-11-wireless-security.key-mgmt "${km}" && break
    say "Connect failed (attempt ${attempts}/${max_attempts})."
  done

  ensure_wifi_autoconnect
  is_online && { say "Online confirmed."; return 0; }

  if [[ "${FORCE_NM_DNS:-0}" == "1" ]]; then
    force_nm_dns
    is_online && { say "Online confirmed after DNS override."; return 0; }
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
pacman_install_strict() { run_sudo pacman -S --noconfirm --needed "$@"; }
pacman_install_best_effort() {
  local ok=() missing=()
  for p in "$@"; do pacman -Si "$p" >/dev/null 2>&1 && ok+=("$p") || missing+=("$p"); done
  ((${#missing[@]})) && say "Skipping missing: ${missing[*]}"
  ((${#ok[@]})) && run_sudo pacman -S --noconfirm --needed "${ok[@]}" || true
}

git_clone_retry() {
  local repo="$1" dest="$2" depth="${3:-1}" n=0 max=5
  while true; do
    [[ -d "$dest/.git" ]] && { say "Repo present: $dest (skip)"; return 0; }
    if [[ -e "$dest" && ! -d "$dest/.git" ]]; then
      local backup="${dest}.bak.$(date +%Y%m%d%H%M%S)"
      say "Destination exists (non-git). Moving to: $backup"
      mv "$dest" "$backup"
    fi
    say "Cloning: $repo -> $dest"
    git clone --depth "$depth" "$repo" "$dest" && return 0
    n=$((n+1)); [[ "$n" -ge "$max" ]] && die "Failed to clone after ${max} attempts: $repo"
    sleep $((n*2))
  done
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
  say "Enabling core services…"
  run_sudo systemctl enable --now NetworkManager >/dev/null 2>&1 || true
  run_sudo systemctl enable --now bluetooth >/dev/null 2>&1 || true

  if systemctl list-unit-files 2>/dev/null | grep -q '^docker\.service'; then
    run_sudo systemctl enable --now docker >/dev/null 2>&1 || true
    if getent group docker >/dev/null 2>&1; then
      if ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
        say "Adding user '$TARGET_USER' to docker group (logout/login required)"
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
# USER CONFIGS (always written to TARGET_HOME as TARGET_USER)
# ------------------------------------------------------------------------------
user_mkdir() { as_user "mkdir -p '$1'"; }

setup_fuzzel_config() {
  local dir="${TARGET_HOME}/.config/fuzzel" cfg="${dir}/fuzzel.ini"
  user_mkdir "$dir"
  as_user "[[ -f '$cfg' ]] && echo 'skip fuzzel (exists)' || cat > '$cfg' <<'EOF'
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
  local dir="${TARGET_HOME}/.config/waybar"
  local cfg="${dir}/config.jsonc"
  local css="${dir}/style.css"
  local force="${FORCE_WAYBAR:-0}"
  user_mkdir "$dir"

  if [[ -f "$cfg" && "$force" == "1" ]]; then
    as_user "cp -a '$cfg' '${cfg}.bak.$(date +%Y%m%d%H%M%S)'"
  fi
  if [[ -f "$css" && "$force" == "1" ]]; then
    as_user "cp -a '$css' '${css}.bak.$(date +%Y%m%d%H%M%S)'"
  fi

  if [[ ! -f "$cfg" || "$force" == "1" ]]; then
    say "Writing Waybar config: $cfg"
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
    say "Writing Waybar style: $css"
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
  as_user "mkdir -p '${TARGET_HOME}/.config'"
  local nvim_dir="${TARGET_HOME}/.config/nvim"
  # clone must run as user to avoid root-owned files
  as_user "python - <<'PY' 2>/dev/null || true
PY"
  as_user "command -v git >/dev/null 2>&1 || exit 0"
  as_user "if [[ -d '$nvim_dir/.git' ]]; then exit 0; fi"
  as_user "git clone --depth 1 https://github.com/LazyVim/starter.git '$nvim_dir' || true"
  if [[ "${DETACH_LAZYVIM:-1}" == "1" ]]; then
    as_user "rm -rf '$nvim_dir/.git' 2>/dev/null || true"
  fi
}

set_default_browser_chromium() {
  as_user "command -v xdg-settings >/dev/null 2>&1 && xdg-settings set default-web-browser chromium.desktop >/dev/null 2>&1 || true"
  as_user "command -v xdg-mime >/dev/null 2>&1 && {
    xdg-mime default chromium.desktop x-scheme-handler/http >/dev/null 2>&1 || true
    xdg-mime default chromium.desktop x-scheme-handler/https >/dev/null 2>&1 || true
  }"
}

setup_hyprland_startup() {
  [[ "${ENABLE_AUTOHYPR:-1}" == "1" ]] || { say "Hyprland autostart disabled."; return 0; }
  local profile="${TARGET_HOME}/.bash_profile"
  local marker="# >>> cortado hyprland autostart >>>"

  # ensure file exists
  as_user "touch '$profile'"

  # add once
  if as_user "grep -qF '$marker' '$profile'"; then
    say "Hyprland autostart already present (skip)."
    return 0
  fi

  say "Adding Hyprland autostart to: $profile"
  as_user "cat >> '$profile' <<'EOF'

# >>> cortado hyprland autostart >>>
# Start Hyprland on TTY1 only, under a D-Bus session
if [[ -z \"\$WAYLAND_DISPLAY\" && \"\${XDG_VTNR:-0}\" -eq 1 ]]; then
  exec dbus-run-session Hyprland
fi
# <<< cortado hyprland autostart <<<
EOF"
}

setup_tty_autologin() {
  [[ "${ENABLE_AUTOLOGIN:-0}" == "1" ]] || { say "Auto-login disabled."; return 0; }
  say "Enabling TTY1 auto-login for user: ${TARGET_USER}"
  run_sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
  run_sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${TARGET_USER} --noclear %I \$TERM
EOF
  run_sudo systemctl daemon-reexec
  run_sudo systemctl restart getty@tty1 >/dev/null 2>&1 || true
}

setup_hyprland_conf() {
  local dir="${TARGET_HOME}/.config/hypr"
  local conf="${dir}/hyprland.conf"
  local force="${FORCE_HYPR_CONF:-0}"
  user_mkdir "$dir"

  if [[ -f "$conf" && "$force" != "1" ]]; then
    say "Hyprland config exists (skip): $conf"
    return 0
  fi

  if [[ -f "$conf" && "$force" == "1" ]]; then
    as_user "cp -a '$conf' '${conf}.bak.$(date +%Y%m%d%H%M%S)'"
  fi

  say "Writing Hyprland config: $conf"
  as_user "cat > '$conf' <<'EOF'
$mod = SUPER
$term = alacritty
$menu = fuzzel
$browser = chromium

# Monitors (may need editing after first start)
monitor=DP-1,3440x1440@60,0x0,1
monitor=eDP-1,preferred,3440x0,1

input {
  kb_layout = gb
  follow_mouse = 1
  touchpad { natural_scroll = true }
}

general {
  gaps_in = 6
  gaps_out = 10
  border_size = 2
  layout = dwindle
}

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

bind = $mod CTRL, H, resizeactive, -40 0
bind = $mod CTRL, L, resizeactive, 40 0
bind = $mod CTRL, K, resizeactive, 0 -40
bind = $mod CTRL, J, resizeactive, 0 40

bind = $mod, 1, workspace, 1
bind = $mod, 2, workspace, 2
bind = $mod, 3, workspace, 3
bind = $mod, 4, workspace, 4
bind = $mod, 5, workspace, 5
bind = $mod, 6, workspace, 6
bind = $mod, 7, workspace, 7
bind = $mod, 8, workspace, 8
bind = $mod, 9, workspace, 9

bind = $mod SHIFT, 1, movetoworkspace, 1
bind = $mod SHIFT, 2, movetoworkspace, 2
bind = $mod SHIFT, 3, movetoworkspace, 3
bind = $mod SHIFT, 4, movetoworkspace, 4
bind = $mod SHIFT, 5, movetoworkspace, 5
bind = $mod SHIFT, 6, movetoworkspace, 6
bind = $mod SHIFT, 7, movetoworkspace, 7
bind = $mod SHIFT, 8, movetoworkspace, 8
bind = $mod SHIFT, 9, movetoworkspace, 9

bindm = $mod, mouse:272, movewindow
bindm = $mod, mouse:273, resizewindow
EOF"
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

  ensure_network_services
  interactive_wifi_connect_if_offline

  [[ "${FORCE_NM_DNS:-0}" == "1" ]] && force_nm_dns || true
  wait_for_dns github.com 30 || { force_nm_dns; wait_for_dns github.com 60 || die "DNS not working; connect to network and retry."; }
  wait_for_dns raw.githubusercontent.com 30 || { force_nm_dns; wait_for_dns raw.githubusercontent.com 60 || die "DNS not working; connect to network and retry."; }
  wait_for_http "https://github.com" 10 || say "Warning: HTTPS check failed; continuing."

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
  ensure_wifi_autoconnect
  setup_bluez_autenable

  # user configs (now guaranteed to land in the right home)
  setup_fuzzel_config
  setup_waybar_config
  setup_lazyvim
  set_default_browser_chromium
  setup_hyprland_conf
  setup_hyprland_startup

  # optional system tweak
  setup_tty_autologin

  say "Complete."
}

main "$@"
