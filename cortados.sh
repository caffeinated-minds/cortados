#!/usr/bin/env bash
set -euo pipefail

# setup.sh
# Purpose: robust bootstrap with network/DNS preflight + LazyVim starter clone
# Target: Arch/Omarchy-style systems (pacman). Safe to re-run.

LOG_PREFIX="[setup]"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
die() { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

run_sudo() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

# --- Network / DNS preflight -------------------------------------------------

ensure_network_services() {
  say "Ensuring network services are running..."

  # NetworkManager (typical on desktops/laptops)
  if systemctl list-unit-files 2>/dev/null | grep -q '^NetworkManager\.service'; then
    run_sudo systemctl enable --now NetworkManager >/dev/null 2>&1 || true
  fi

  # systemd-resolved (common DNS resolver)
  if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved\.service'; then
    run_sudo systemctl enable --now systemd-resolved >/dev/null 2>&1 || true

    # Ensure /etc/resolv.conf points at the stub (idempotent)
    if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
      run_sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || true
    fi
  fi
}

force_nm_dns() {
  # Pragmatic fallback if auto DNS is broken (captive portals, flaky routers)
  command -v nmcli >/dev/null 2>&1 || return 0

  local con
  con="$(nmcli -t -f NAME,TYPE con show --active 2>/dev/null | awk -F: '$2=="wifi"||$2=="ethernet"{print $1; exit}')"
  [[ -n "${con:-}" ]] || return 0

  say "Applying fallback DNS (1.1.1.1, 8.8.8.8) to active NetworkManager connection: $con"
  run_sudo nmcli con mod "$con" ipv4.ignore-auto-dns yes || true
  run_sudo nmcli con mod "$con" ipv4.dns "1.1.1.1 8.8.8.8" || true
  run_sudo nmcli con up "$con" >/dev/null 2>&1 || true
}

wait_for_dns() {
  local host="${1:-github.com}"
  local tries="${2:-60}"

  say "Waiting for DNS to resolve: ${host} (up to ${tries}s)"
  for ((i=1; i<=tries; i++)); do
    if getent ahosts "$host" >/dev/null 2>&1; then
      say "DNS OK."
      return 0
    fi
    sleep 1
  done

  say "DNS still failing. Debug info:"
  command -v resolvectl >/dev/null 2>&1 && resolvectl status || true
  cat /etc/resolv.conf || true
  return 1
}

wait_for_http() {
  # Optional: confirm outbound HTTPS works (not just DNS)
  local url="${1:-https://github.com}"
  local tries="${2:-30}"

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

# --- Pacman ------------------------------------------------------------------

pacman_bootstrap() {
  need_cmd pacman

  say "Refreshing keyring and syncing package databases..."
  run_sudo pacman -Sy --noconfirm archlinux-keyring >/dev/null 2>&1 || true

  # Full refresh (avoid partial upgrade)
  run_sudo pacman -Syyu --noconfirm || true
}

pacman_install() {
  local pkgs=("$@")
  say "Installing packages: ${pkgs[*]}"
  run_sudo pacman -S --noconfirm --needed "${pkgs[@]}"
}

# --- Git clone with retry -----------------------------------------------------

git_clone_retry() {
  local repo="$1"
  local dest="$2"
  local depth="${3:-1}"

  local n=0
  local max=5

  while true; do
    # If dest exists and is a git repo, skip
    if [[ -d "$dest/.git" ]]; then
      say "Repo already present: $dest (skipping clone)"
      return 0
    fi

    # If dest exists but isn't a git repo, back it up
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

    say "Clone failed; retrying in $((n*2))s..."
    sleep $((n*2))
  done
}

# --- Main --------------------------------------------------------------------

main() {
  need_cmd systemctl
  need_cmd getent

  ensure_network_services

  # First pass: DNS wait
  if ! wait_for_dns github.com 30; then
    # Apply fallback DNS and try again
    force_nm_dns
    wait_for_dns github.com 60 || die "No DNS resolution; fix networking before running this script."
  fi

  # Optional: confirm HTTPS is usable
  wait_for_http "https://github.com" 15 || say "Warning: HTTPS check failed; continuing (git may still fail)."

  pacman_bootstrap
  pacman_install git neovim ripgrep fd curl ca-certificates

  # Correct path is .config (your error showed .confgi)
  local nvim_dir="${HOME}/.config/nvim"
  mkdir -p "${HOME}/.config"

  # LazyVim starter uses .git suffix typically; this avoids redirects
  git_clone_retry "https://github.com/LazyVim/starter.git" "$nvim_dir" 1

  # Optional: remove starter's .git to make it "yours" (common practice)
  # Comment out if you want it to remain as a git repo.
  if [[ -d "$nvim_dir/.git" ]]; then
    say "Removing starter .git directory to detach from template (optional behaviour)"
    rm -rf "$nvim_dir/.git"
  fi

  say "Done."
  say "Next: run 'nvim' to let plugins install."
}

main "$@"
