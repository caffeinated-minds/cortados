#!/usr/bin/env bash
# cortados.sh — Arch → Hyprland workstation (Omarchy-like), performance-first, reproducible
set -euo pipefail

# ----------------------------
# User-tunable knobs
# ----------------------------
OMARCHY_TAG="${OMARCHY_TAG:-v3.2.3}"      # pin Omarchy theme assets
THEME_NAME="${THEME_NAME:-catppuccin}"    # Omarchy theme folder name
ENABLE_BLUETOOTH="${ENABLE_BLUETOOTH:-1}" # 1=install+enable bluetooth stack
ENABLE_T2="${ENABLE_T2:-0}"               # 1=install T2 Mac packages (only if you know you need them)
INSTALL_LAZYVIM="${INSTALL_LAZYVIM:-1}"   # 1=install LazyVim starter

# ----------------------------
# Logging helpers
# ----------------------------
log() { printf "\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
die() {
  printf "\033[1;31m[x] %s\033[0m\n" "$*"
  exit 1
}

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

  log "Refreshing pacman database"
  sudo pacman -Syu --noconfirm

  log "Ensuring build + download essentials"
  sudo pacman -S --needed --noconfirm base-devel git curl tar

  need_cmd curl
  need_cmd git
}

# ----------------------------
# Package classification helpers
# ----------------------------
pacman_has_pkg() { pacman -Si "$1" >/dev/null 2>&1; }

install_pacman() {
  local -a pkgs=("$@")
  ((${#pkgs[@]})) || return 0
  log "Installing (pacman): ${#pkgs[@]} packages"
  sudo pacman -S --needed --noconfirm "${pkgs[@]}"
}

ensure_yay() {
  command -v yay >/dev/null 2>&1 && return 0

  # If yay exists in repos (rare), use it
  if pacman_has_pkg yay; then
    log "Installing yay via pacman"
    sudo pacman -S --needed --noconfirm yay
    return 0
  fi

  # Prefer yay-bin from AUR (prebuilt) to avoid source tarball builds
  log "Bootstrapping yay-bin from AUR"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  # Clone the AUR PKGBUILD for yay-bin (not GitHub source)
  git clone https://aur.archlinux.org/yay-bin.git "$tmpdir/yay-bin"
  (cd "$tmpdir/yay-bin" && makepkg -si --noconfirm)
}

install_aur() {
  local -a pkgs=("$@")
  ((${#pkgs[@]})) || return 0
  ensure_yay
  log "Installing (AUR): ${#pkgs[@]} packages"
  yay -S --needed --noconfirm "${pkgs[@]}"
}

# ----------------------------
# Hardware detection
# ----------------------------
detect_gpu() {
  # Requires pciutils (lspci)
  local out
  out="$(lspci -nn | tr '[:upper:]' '[:lower:]' || true)"
  if echo "$out" | grep -q "nvidia"; then
    echo "nvidia"
    return
  fi
  if echo "$out" | grep -q "intel"; then
    echo "intel"
    return
  fi
  if echo "$out" | grep -q -E "amd|advanced micro devices|ati"; then
    echo "amd"
    return
  fi
  echo "unknown"
}

detect_broadcom_wifi() {
  # Broadcom vendor id commonly 14e4
  local out
  out="$(lspci -nn | tr '[:upper:]' '[:lower:]' || true)"
  echo "$out" | grep -qE "network controller|wireless" && echo "$out" | grep -q "14e4"
}

# ----------------------------
# Phase 1 packages (FROZEN, updated)
# ----------------------------
phase1_packages() {
  local -a pkgs=(
    # Absolute base + essentials for script and detection
    base linux linux-firmware linux-headers
    git wget curl unzip man-db less bash-completion
    pciutils

    # Wayland + Hyprland
    hyprland hypridle hyprlock hyprpicker hyprsunset
    xdg-desktop-portal xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
    qt5-wayland qt6-wayland egl-wayland
    grim slurp wl-clipboard

    # Bar/notifications
    waybar mako swaybg swayosd

    # Audio
    pipewire pipewire-alsa pipewire-pulse wireplumber gst-plugin-pipewire pamixer playerctl

    # Networking
    iwd avahi nss-mdns

    # Fonts
    noto-fonts noto-fonts-emoji ttf-hack-nerd

    # Session/permissions
    polkit-gnome uwsm
  )
  printf "%s\n" "${pkgs[@]}"
}

# ----------------------------
# Phase 2 packages (FROZEN, printing enabled, bluetui included)
# ----------------------------
phase2_packages() {
  local gpu="$1"
  local -a pkgs=(
    # Laptop responsiveness defaults
    power-profiles-daemon zram-generator brightnessctl

    # Printing (enabled out-of-box)
    cups cups-filters cups-browsed cups-pdf system-config-printer
  )

  case "$gpu" in
  nvidia) pkgs+=(nvidia-open-dkms nvidia-utils lib32-nvidia-utils egl-wayland) ;;
  intel) pkgs+=(libva-intel-driver) ;;
  amd) ;;
  *) ;;
  esac

  if detect_broadcom_wifi; then
    pkgs+=(broadcom-wl dkms)
  fi

  if [[ "$ENABLE_BLUETOOTH" == "1" ]]; then
    pkgs+=(bluez bluez-utils bluetui)
  fi

  if [[ "$ENABLE_T2" == "1" ]]; then
    pkgs+=(linux-t2 linux-t2-headers apple-bcm-firmware apple-t2-audio-config t2fanrd tiny-dfr)
  fi

  printf "%s\n" "${pkgs[@]}"
}

# ----------------------------
# Phase 3 packages (FROZEN + brave/alacritty/tmux + docker)
# ----------------------------
phase3_packages() {
  local -a pkgs=(
    # Containers
    docker docker-buildx docker-compose

    # Dev toolchains
    clang llvm cmake ninja pkgconf
    go
    nodejs npm corepack
    python python-pip python-virtualenv
    lua luarocks

    # GUI productivity
    localsend xournalpp pinta

    # Media & creative
    mpv gpu-screen-recorder satty imv

    # CLI QoL
    bat eza btop fastfetch dust lazygit lazydocker tldr zoxide starship

    # Neovim
    neovim

    # Terminal & multiplexer
    alacritty tmux
  )
  printf "%s\n" "${pkgs[@]}"
}

phase3_aur_packages() {
  local -a aur_pkgs=(
    brave-bin
    walker-bin
  )
  printf "%s\n" "${aur_pkgs[@]}"
}

# ----------------------------
# Service enablement
# ----------------------------
enable_services() {
  log "Enabling iwd and Avahi"
  sudo systemctl enable --now iwd.service
  sudo systemctl enable --now avahi-daemon.service

  log "Enabling printing via socket activation (cups.socket)"
  sudo systemctl enable --now cups.socket

  log "Enabling power-profiles-daemon"
  sudo systemctl enable --now power-profiles-daemon.service

  if [[ "$ENABLE_BLUETOOTH" == "1" ]]; then
    log "Enabling Bluetooth"
    sudo systemctl enable --now bluetooth.service
  fi

  log "Enabling Docker"
  sudo systemctl enable --now docker.service
  if ! id -nG "$USER" | grep -qw docker; then
    log "Adding user '$USER' to docker group"
    sudo usermod -aG docker "$USER"
    warn "Log out/in (or reboot) for docker group membership to apply."
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
# TTY -> Hyprland autostart (no display manager)
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
    opts = {
      flavour = "mocha",
      transparent_background = false,
      integrations = {
        cmp = true,
        gitsigns = true,
        native_lsp = { enabled = true },
        telescope = true,
        treesitter = true,
        which_key = true,
      },
    },
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
# Omarchy theme layer
# - Waybar config + style.css copied EXACTLY (from pinned theme)
# - Others best-effort if present
# ----------------------------
apply_omarchy_catppuccin_theme() {
  log "Applying Omarchy theme assets (pinned): ${OMARCHY_TAG} / themes/${THEME_NAME}"

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  local archive_url="https://github.com/basecamp/omarchy/archive/refs/tags/${OMARCHY_TAG}.tar.gz"
  curl -fsSL "$archive_url" -o "$tmpdir/omarchy.tar.gz" || die "Failed to download: $archive_url"
  tar -xzf "$tmpdir/omarchy.tar.gz" -C "$tmpdir"

  local root
  root="$(find "$tmpdir" -maxdepth 1 -type d -name "omarchy-*" | head -n1)"
  [[ -n "$root" ]] || die "Could not locate extracted omarchy directory"

  local theme_dir="$root/themes/${THEME_NAME}"
  [[ -d "$theme_dir" ]] || die "Theme directory not found: $theme_dir"

  # Waybar (EXACT)
  mkdir -p "$HOME/.config/waybar"
  if [[ -f "$theme_dir/waybar/config.jsonc" ]]; then
    cp -f "$theme_dir/waybar/config.jsonc" "$HOME/.config/waybar/config.jsonc"
  fi
  if [[ -f "$theme_dir/waybar/style.css" ]]; then
    cp -f "$theme_dir/waybar/style.css" "$HOME/.config/waybar/style.css"
  fi

  # Mako (best effort)
  if [[ -f "$theme_dir/mako/config" ]]; then
    mkdir -p "$HOME/.config/mako"
    cp -f "$theme_dir/mako/config" "$HOME/.config/mako/config"
  fi

  # Alacritty theme (best effort)
  if [[ -d "$theme_dir/alacritty" ]]; then
    mkdir -p "$HOME/.config/alacritty"
    cp -rf "$theme_dir/alacritty/." "$HOME/.config/alacritty/"
  fi

  # Hyprlock theme (best effort)
  if [[ -f "$theme_dir/hyprlock.conf" ]]; then
    mkdir -p "$HOME/.config/hypr"
    cp -f "$theme_dir/hyprlock.conf" "$HOME/.config/hypr/hyprlock.conf"
  fi

  # Walker theme (best effort)
  if [[ -d "$theme_dir/walker" ]]; then
    mkdir -p "$HOME/.config/walker"
    cp -rf "$theme_dir/walker/." "$HOME/.config/walker/"
  fi

  # Wallpaper (best effort)
  mkdir -p "$HOME/.local/share/backgrounds"
  if compgen -G "$theme_dir/*background*" >/dev/null; then
    local bg
    bg="$(ls -1 "$theme_dir"/*background* 2>/dev/null | head -n1 || true)"
    [[ -n "$bg" ]] && cp -f "$bg" "$HOME/.local/share/backgrounds/current"
  fi

  # Omarchy font (best effort)
  if [[ -f "$root/config/omarchy.ttf" ]]; then
    mkdir -p "$HOME/.local/share/fonts"
    cp -f "$root/config/omarchy.ttf" "$HOME/.local/share/fonts/omarchy.ttf"
  fi
  fc-cache -f >/dev/null 2>&1 || true

  pkill waybar >/dev/null 2>&1 || true
  pkill mako >/dev/null 2>&1 || true

  log "Theme applied (Waybar files copied verbatim where present)."
}

# ----------------------------
# Hyprland config (KEYBINDINGS LOCKED)
# - $mod=ALT, $mod2=SUPER
# - ALT+D walker
# - SUPER+Space XKB layout toggle (grp:win_space_toggle)
# - Webapps (ALT + G/Y/C/W/E/T) in Brave app mode
# ----------------------------
write_hyprland_config() {
  log "Writing Hyprland config (locked bindings + input layout toggle)"

  mkdir -p "$HOME/.config/hypr"
  mkdir -p "$HOME/Pictures/Screenshots"

  cat >"$HOME/.config/hypr/hyprland.conf" <<'EOF'
# cortados hyprland.conf (locked)
$mod  = ALT
$mod2 = SUPER

$term    = alacritty
$menu    = walker
$browser = brave
$webapp  = brave --ozone-platform=wayland --app

# Environment hinting for portals
env = XDG_CURRENT_DESKTOP,Hyprland

# Start required session helpers
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec-once = waybar
exec-once = mako

# Launcher / terminal / browser
bind = $mod, Return, exec, $term
bind = $mod, D, exec, $menu
bind = $mod, B, exec, $browser

# Webapps (Brave app-mode)
bind = $mod, G, exec, $webapp=https://github.com
bind = $mod, Y, exec, $webapp=https://youtube.com
bind = $mod, C, exec, $webapp=https://chatgpt.com
bind = $mod, W, exec, $webapp=https://web.whatsapp.com
bind = $mod, E, exec, $webapp=https://gmail.com
bind = $mod, T, exec, $webapp=https://twitch.com

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

# Lock (avoid conflict with $mod SHIFT+L window-move)
bind = $mod2 SHIFT, L, exec, hyprlock

# Screenshots
bind = , Print, exec, bash -lc 'grim -g "$(slurp)" "$HOME/Pictures/Screenshots/$(date +%F_%H-%M-%S).png"'
bind = $mod, Print, exec, bash -lc 'grim -g "$(slurp)" - | satty -f -'

# Media keys
bind = , XF86AudioRaiseVolume, exec, pamixer -i 5
bind = , XF86AudioLowerVolume, exec, pamixer -d 5
bind = , XF86AudioMute, exec, pamixer -t
bind = , XF86AudioPlay, exec, playerctl play-pause
bind = , XF86AudioNext, exec, playerctl next
bind = , XF86AudioPrev, exec, playerctl previous
bind = , XF86MonBrightnessUp, exec, brightnessctl set +10%
bind = , XF86MonBrightnessDown, exec, brightnessctl set 10%-

# Comfortable layout / minimal blur
general {
  gaps_in = 8
  gaps_out = 12
  border_size = 2
}

decoration {
  rounding = 8
  active_opacity = 1.0
  inactive_opacity = 1.0
  drop_shadow = yes
  shadow_range = 12
  shadow_render_power = 2
  blur {
    enabled = no
  }
}

animations {
  enabled = no
}

# Keyboard layouts (native XKB toggle)
# SUPER+Space toggles layouts via grp:win_space_toggle
input {
  kb_layout  = gb,us
  kb_variant = ,dvorak
  kb_options = grp:win_space_toggle
  follow_mouse = 1
}
EOF
}

# ----------------------------
# Install all phases
# ----------------------------
install_all() {
  local gpu
  gpu="$(detect_gpu)"
  log "Detected GPU: $gpu"

  local -a pac_pkgs=()
  local -a aur_pkgs=()

  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if pacman_has_pkg "$p"; then pac_pkgs+=("$p"); else aur_pkgs+=("$p"); fi
  done < <(phase1_packages)

  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if pacman_has_pkg "$p"; then pac_pkgs+=("$p"); else aur_pkgs+=("$p"); fi
  done < <(phase2_packages "$gpu")

  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if pacman_has_pkg "$p"; then pac_pkgs+=("$p"); else aur_pkgs+=("$p"); fi
  done < <(phase3_packages)

  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    aur_pkgs+=("$p")
  done < <(phase3_aur_packages)

  mapfile -t pac_pkgs < <(printf "%s\n" "${pac_pkgs[@]}" | awk '!seen[$0]++')
  mapfile -t aur_pkgs < <(printf "%s\n" "${aur_pkgs[@]}" | awk '!seen[$0]++')

  install_pacman "${pac_pkgs[@]}"
  install_aur "${aur_pkgs[@]}"

  enable_services
  configure_zram
  configure_tty_autostart
  write_hyprland_config
  install_lazyvim
  apply_omarchy_catppuccin_theme

  log "Done. Reboot recommended."
  warn "If docker group was newly added, log out/in (or reboot) for docker group membership to apply."
}

usage() {
  cat <<EOF
Usage: ./cortados.sh

Environment flags:
  ENABLE_BLUETOOTH=1|0    (default: 1)
  ENABLE_T2=1|0           (default: 0)
  OMARCHY_TAG=vX.Y.Z      (default: v3.2.3)
  THEME_NAME=catppuccin   (default: catppuccin)
  INSTALL_LAZYVIM=1|0     (default: 1)

Example:
  ENABLE_T2=0 ENABLE_BLUETOOTH=1 ./cortados.sh
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
