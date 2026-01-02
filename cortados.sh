#!/usr/bin/env bash
# cortados.sh — Arch → Hyprland workstation (Omarchy-like, minimal, reproducible)
# - pacman-only bootstrap (NO AUR)
# - fuzzel launcher (apps + lock + shutdown + reboot)
# - Catppuccin-like local theming (no Omarchy downloads)
# - TTY autostart via dbus-run-session
# - DevOps tooling included (terraform/k8s/yaml/etc)

set -euo pipefail

# ----------------------------
# User-tunable knobs
# ----------------------------
ENABLE_BLUETOOTH="${ENABLE_BLUETOOTH:-1}"   # 1=install+enable bluetooth stack
ENABLE_DOCKER="${ENABLE_DOCKER:-1}"         # 1=install+enable docker
INSTALL_LAZYVIM="${INSTALL_LAZYVIM:-1}"     # 1=install LazyVim starter
ENABLE_PRINTING="${ENABLE_PRINTING:-1}"     # 1=install cups + printer tools

# ----------------------------
# Logging helpers
# ----------------------------
log()  { printf "\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m[x] %s\033[0m\n" "$*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# ----------------------------
# Preflight
# ----------------------------
preflight() {
  need_cmd pacman
  need_cmd sudo
  need_cmd systemctl

  if [[ "$(id -u)" -eq 0 ]]; then
    die "Run as a normal user with sudo, not as root."
  fi

  # Ensure keyring is sane on fresh installs
  log "Refreshing pacman keyring + syncing databases"
  sudo pacman -Sy --noconfirm archlinux-keyring || true

  log "Full system update"
  sudo pacman -Syu --noconfirm

  log "Ensuring base build + download essentials"
  sudo pacman -S --needed --noconfirm base-devel git curl ca-certificates tar unzip

  need_cmd curl
  need_cmd git
}

# ----------------------------
# Hardware detection
# ----------------------------
detect_gpu() {
  sudo pacman -S --needed --noconfirm pciutils >/dev/null
  local out
  out="$(lspci -nn | tr '[:upper:]' '[:lower:]' || true)"
  if echo "$out" | grep -q "nvidia"; then echo "nvidia"; return; fi
  if echo "$out" | grep -q "intel"; then echo "intel"; return; fi
  if echo "$out" | grep -q -E "amd|advanced micro devices|ati"; then echo "amd"; return; fi
  echo "unknown"
}

# ----------------------------
# Package lists (ONE PER LINE, ALWAYS)
# ----------------------------
packages_base() {
  cat <<'EOF'
base
linux
linux-firmware
linux-headers
bash-completion
man-db
less
git
curl
wget
unzip
tar
pciutils
openssh

# Wayland + Hyprland
hyprland
hypridle
hyprlock
hyprpicker
xdg-desktop-portal-hyprland
xdg-desktop-portal-gtk
qt5-wayland
qt6-wayland
egl-wayland

# Bar/notifications/background/osd
waybar
mako
swaybg
swayosd

# Launcher
fuzzel

# Terminal / basic UX
alacritty
tmux

# Screenshots/clipboard
grim
slurp
wl-clipboard
swappy

# Audio
pipewire
pipewire-alsa
pipewire-pulse
wireplumber
gst-plugin-pipewire
pamixer
playerctl

# Networking (reliable bootstrap)
networkmanager
avahi
nss-mdns

# Fonts
noto-fonts
noto-fonts-emoji
ttf-hack-nerd

# Polkit agent
polkit-gnome

# Laptop defaults
power-profiles-daemon
brightnessctl

# Performance
zram-generator

# CLI QoL
bat
eza
btop
fastfetch
dust
tldr
zoxide
starship

# Dev essentials
neovim
python
python-pip
python-virtualenv
nodejs
npm
corepack
go
jq
yq
EOF
}

packages_gpu_extras() {
  local gpu="$1"
  case "$gpu" in
    nvidia)
      cat <<'EOF'
nvidia-open-dkms
nvidia-utils
lib32-nvidia-utils
EOF
      ;;
    intel)
      cat <<'EOF'
libva-intel-driver
EOF
      ;;
    amd)
      : ;;
    *)
      : ;;
  esac
}

packages_devops() {
  cat <<'EOF'
terraform
kubectl
helm
k9s
kustomize
EOF
}

packages_optional() {
  if [[ "$ENABLE_PRINTING" == "1" ]]; then
    cat <<'EOF'
cups
cups-filters
cups-browsed
cups-pdf
system-config-printer
EOF
  fi

  if [[ "$ENABLE_BLUETOOTH" == "1" ]]; then
    cat <<'EOF'
bluez
bluez-utils
EOF
  fi

  if [[ "$ENABLE_DOCKER" == "1" ]]; then
    cat <<'EOF'
docker
docker-buildx
docker-compose
EOF
  fi
}

install_pacman_all() {
  local gpu="$1"

  # Build one-per-line list, strip comments/empties, de-dupe
  mapfile -t pkgs < <(
    { packages_base; packages_gpu_extras "$gpu"; packages_devops; packages_optional; } \
      | sed 's/#.*$//' \
      | awk 'NF{print $0}' \
      | awk '!seen[$0]++'
  )

  log "Installing (pacman): ${#pkgs[@]} packages"
  sudo pacman -S --needed --noconfirm "${pkgs[@]}"
}

# ----------------------------
# Services
# ----------------------------
enable_services() {
  log "Enabling NetworkManager + Avahi"
  sudo systemctl enable --now NetworkManager.service
  sudo systemctl enable --now avahi-daemon.service

  if [[ "$ENABLE_PRINTING" == "1" ]]; then
    log "Enabling printing via socket activation (cups.socket)"
    sudo systemctl enable --now cups.socket
  fi

  log "Enabling power-profiles-daemon"
  sudo systemctl enable --now power-profiles-daemon.service

  if [[ "$ENABLE_BLUETOOTH" == "1" ]]; then
    log "Enabling Bluetooth"
    sudo systemctl enable --now bluetooth.service
  fi

  if [[ "$ENABLE_DOCKER" == "1" ]]; then
    log "Enabling Docker"
    sudo systemctl enable --now docker.service
    if ! id -nG "$USER" | grep -qw docker; then
      log "Adding user '$USER' to docker group"
      sudo usermod -aG docker "$USER"
      warn "Log out/in (or reboot) for docker group membership to apply."
    fi
  fi
}

# ----------------------------
# ZRAM setup
# ----------------------------
configure_zram() {
  log "Configuring zram-generator"
  sudo mkdir -p /etc/systemd
  sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
swap-priority = 100
EOF

  sudo systemctl daemon-reload
  sudo systemctl restart systemd-zram-setup@zram0.service >/dev/null 2>&1 || true
}

# ----------------------------
# TTY -> Hyprland autostart (dbus-run-session)
# ----------------------------
configure_tty_autostart() {
  log "Configuring TTY autostart for Hyprland on tty1 (dbus-run-session)"

  local profile="$HOME/.bash_profile"
  [[ -f "$HOME/.zprofile" ]] && profile="$HOME/.zprofile"

  if ! grep -q "cortados-autostart-hyprland" "$profile" 2>/dev/null; then
    cat >>"$profile" <<'EOF'

# cortados-autostart-hyprland
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ] && [ "${XDG_VTNR:-}" = "1" ]; then
  exec dbus-run-session Hyprland
fi
EOF
  fi
}

# ----------------------------
# Launcher: fuzzel menu + apps
# ----------------------------
write_launcher_script() {
  log "Installing launcher script (fuzzel: apps/lock/power)"
  mkdir -p "$HOME/.local/bin"

  cat >"$HOME/.local/bin/launcher" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

choice="$(printf "Apps\nLock\nShutdown\nReboot\n" | fuzzel --dmenu --prompt 'Run: ')"

case "$choice" in
  Apps)     exec fuzzel ;;
  Lock)     exec hyprlock ;;
  Shutdown) exec systemctl poweroff ;;
  Reboot)   exec systemctl reboot ;;
  *)        exit 0 ;;
esac
EOF
  chmod +x "$HOME/.local/bin/launcher"
}

# ----------------------------
# Local Catppuccin-like theming (no downloads)
# ----------------------------
write_fuzzel_config() {
  log "Writing fuzzel config (Catppuccin-like defaults)"
  mkdir -p "$HOME/.config/fuzzel"
  cat >"$HOME/.config/fuzzel/fuzzel.ini" <<'EOF'
[main]
font=Hack Nerd Font:size=12
prompt=› 

[colors]
background=1e1e2eff
text=cdd6f4ff
match=89b4faff
selection=313244ff
selection-text=cdd6f4ff
border=89b4faff

[border]
width=2
radius=10
EOF
}

write_mako_config() {
  log "Writing mako config (Catppuccin-like defaults)"
  mkdir -p "$HOME/.config/mako"
  cat >"$HOME/.config/mako/config" <<'EOF'
background-color=#1e1e2e
text-color=#cdd6f4
border-color=#89b4fa
progress-color=over #313244

border-size=2
border-radius=10
padding=10
margin=10
font=Hack Nerd Font 11

default-timeout=5000
ignore-timeout=1

[urgency=high]
border-color=#f38ba8
EOF
}

write_waybar_config() {
  log "Writing waybar config + style (Catppuccin-like defaults)"
  mkdir -p "$HOME/.config/waybar"

  cat >"$HOME/.config/waybar/config.jsonc" <<'EOF'
{
  "layer": "top",
  "position": "top",
  "height": 34,
  "spacing": 8,

  "modules-left": ["hyprland/workspaces", "hyprland/window"],
  "modules-center": ["clock"],
  "modules-right": ["pulseaudio", "network", "bluetooth", "battery", "tray"],

  "hyprland/workspaces": {
    "disable-scroll": true,
    "all-outputs": true,
    "format": "{name}"
  },

  "hyprland/window": {
    "format": "{}",
    "max-length": 50
  },

  "clock": {
    "format": "{:%a %d %b  %H:%M}"
  },

  "pulseaudio": {
    "format": "{icon} {volume}%",
    "format-muted": " muted",
    "format-icons": { "default": ["", ""] }
  },

  "network": {
    "format-wifi": "  {essid}",
    "format-ethernet": "󰈀  wired",
    "format-disconnected": "󰖪  offline"
  },

  "bluetooth": {
    "format": "",
    "format-disabled": " off",
    "format-connected": " {num_connections}"
  },

  "battery": {
    "format": "{icon} {capacity}%",
    "format-charging": " {capacity}%",
    "format-icons": ["", "", "", "", ""]
  },

  "tray": {
    "spacing": 10
  }
}
EOF

  cat >"$HOME/.config/waybar/style.css" <<'EOF'
* {
  border: none;
  border-radius: 0;
  font-family: "Hack Nerd Font", "Hack", monospace;
  font-size: 12px;
  min-height: 0;
}

window#waybar {
  background: rgba(30, 30, 46, 0.92);
  color: #cdd6f4;
}

#workspaces button {
  padding: 0 10px;
  margin: 6px 4px;
  border-radius: 10px;
  background: rgba(49, 50, 68, 0.6);
  color: #cdd6f4;
}

#workspaces button.active {
  background: rgba(137, 180, 250, 0.9);
  color: #1e1e2e;
}

#workspaces button.urgent {
  background: rgba(243, 139, 168, 0.9);
  color: #1e1e2e;
}

#hyprland-window {
  padding: 0 10px;
  margin: 6px 0;
  border-radius: 10px;
  background: rgba(49, 50, 68, 0.35);
}

#clock,
#network,
#pulseaudio,
#bluetooth,
#battery,
#tray {
  padding: 0 10px;
  margin: 6px 0;
  border-radius: 10px;
  background: rgba(49, 50, 68, 0.35);
}
EOF
}

# ----------------------------
# Hyprland config (bindings)
# - $mod=ALT, $mod2=SUPER
# - ALT+D launcher (fuzzel menu)
# - SUPER+Space XKB layout toggle (grp:win_space_toggle)
# ----------------------------
write_hyprland_config() {
  log "Writing Hyprland config"

  mkdir -p "$HOME/.config/hypr"
  mkdir -p "$HOME/Pictures/Screenshots"

  cat >"$HOME/.config/hypr/hyprland.conf" <<'EOF'
$mod  = ALT
$mod2 = SUPER

$term    = alacritty
$menu    = $HOME/.local/bin/launcher
$browser = firefox

exec-once = waybar
exec-once = mako

# Launcher / terminal / browser
bind = $mod, Return, exec, $term
bind = $mod, D, exec, $menu
bind = $mod, B, exec, $browser

# Webapps (open normal tabs in firefox; app-mode requires Brave/Chromium tooling)
bind = $mod, G, exec, firefox https://github.com
bind = $mod, Y, exec, firefox https://youtube.com
bind = $mod, C, exec, firefox https://chatgpt.com
bind = $mod, W, exec, firefox https://web.whatsapp.com
bind = $mod, E, exec, firefox https://gmail.com
bind = $mod, T, exec, firefox https://twitch.com

# Window management
bind = $mod SHIFT, Q, killactive
bind = $mod, F, fullscreen, 1
bind = $mod, S, togglefloating
bind = $mod SHIFT, R, exec, hyprctl reload

# Focus (vim keys)
bind = $mod, H, movefocus, l
bind = $mod, J, movefocus, d
bind = $mod, K, movefocus, u
bind = $mod, L, movefocus, r

# Move windows
bind = $mod SHIFT, H, movewindow, l
bind = $mod SHIFT, J, movewindow, d
bind = $mod SHIFT, K, movewindow, u
bind = $mod SHIFT, L, movewindow, r

# Layout toggles
bind = $mod, V, togglesplit
bind = $mod, P, pseudo

# Lock
bind = $mod SHIFT, X, exec, hyprlock

# Screenshots
bind = , Print, exec, bash -lc 'grim -g "$(slurp)" "$HOME/Pictures/Screenshots/$(date +%F_%H-%M-%S).png"'
bind = $mod, Print, exec, bash -lc 'grim -g "$(slurp)" - | swappy -f -'

# Media keys
bind = , XF86AudioRaiseVolume, exec, pamixer -i 5
bind = , XF86AudioLowerVolume, exec, pamixer -d 5
bind = , XF86AudioMute, exec, pamixer -t
bind = , XF86AudioPlay, exec, playerctl play-pause
bind = , XF86AudioNext, exec, playerctl next
bind = , XF86AudioPrev, exec, playerctl previous
bind = , XF86MonBrightnessUp, exec, brightnessctl set +10%
bind = , XF86MonBrightnessDown, exec, brightnessctl set 10%-

general {
  gaps_in = 8
  gaps_out = 12
  border_size = 2
}

decoration {
  rounding = 10
  active_opacity = 1.0
  inactive_opacity = 1.0
  drop_shadow = yes
  shadow_range = 12
  shadow_render_power = 2
  blur { enabled = no }
}

animations { enabled = no }

# Keyboard layouts (native XKB toggle)
input {
  kb_layout  = gb,us
  kb_variant = ,dvorak
  kb_options = grp:win_space_toggle
  follow_mouse = 1
}
EOF
}

# ----------------------------
# LazyVim upstream bootstrap + Catppuccin Mocha
# ----------------------------
install_lazyvim() {
  [[ "$INSTALL_LAZYVIM" == "1" ]] || return 0

  log "Installing LazyVim (upstream starter) + Catppuccin Mocha"

  local nvim_dir="$HOME/.config/nvim"
  if [[ -d "$nvim_dir" && ! -d "$nvim_dir/.git" ]]; then
    warn "~/.config/nvim exists and is not a git repo; backing up to ~/.config/nvim.bak"
    rm -rf "$HOME/.config/nvim.bak" || true
    mv "$nvim_dir" "$HOME/.config/nvim.bak"
  fi

  if [[ ! -d "$nvim_dir" ]]; then
    git clone https://github.com/LazyVim/starter "$nvim_dir"
    rm -rf "$nvim_dir/.git"
  fi

  mkdir -p "$nvim_dir/lua/plugins"
  cat >"$nvim_dir/lua/plugins/catppuccin.lua" <<'EOF'
return {
  {
    "catppuccin/nvim",
    name = "catppuccin",
    priority = 1000,
    opts = { flavour = "mocha" },
  },
}
EOF

  mkdir -p "$nvim_dir/lua/config"
  if [[ ! -f "$nvim_dir/lua/config/options.lua" ]]; then
    cat >"$nvim_dir/lua/config/options.lua" <<'EOF'
vim.g.mapleader = " "
vim.o.termguicolors = true
vim.cmd.colorscheme("catppuccin-mocha")
EOF
  else
    if ! grep -q 'catppuccin-mocha' "$nvim_dir/lua/config/options.lua"; then
      echo 'vim.cmd.colorscheme("catppuccin-mocha")' >>"$nvim_dir/lua/config/options.lua"
    fi
  fi
}

# ----------------------------
# Install all
# ----------------------------
install_all() {
  local gpu
  gpu="$(detect_gpu)"
  log "Detected GPU: $gpu"

  install_pacman_all "$gpu"
  enable_services
  configure_zram
  configure_tty_autostart

  write_launcher_script
  write_fuzzel_config
  write_mako_config
  write_waybar_config
  write_hyprland_config

  install_lazyvim

  fc-cache -f >/dev/null 2>&1 || true

  log "Done. Reboot recommended."
  if [[ "$ENABLE_DOCKER" == "1" ]]; then
    warn "If docker group was newly added, log out/in (or reboot) for docker group membership to apply."
  fi
}

usage() {
  cat <<EOF
Usage: ./cortados.sh

Environment flags:
  ENABLE_BLUETOOTH=1|0     (default: 1)
  ENABLE_DOCKER=1|0        (default: 1)
  ENABLE_PRINTING=1|0      (default: 1)
  INSTALL_LAZYVIM=1|0      (default: 1)

EOF
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  preflight
  install_all
}

main "$@"
