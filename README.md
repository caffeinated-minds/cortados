# cortados

A **minimal, reproducible Arch Linux workstation bootstrap** inspired by Omarchy.

The goal is a **boring, predictable, keyboard-driven system**:
- Wayland + tiling compositor (Hyprland)
- Repo-only packages (no AUR, no Flatpak)
- PipeWire audio (no JACK conflicts)
- Terminal-centric workflow
- Safe to re-run

This repository provides a single script: **`cortados.sh`**.

---

## What this sets up

### Core system
- Hyprland (Wayland compositor)
- Waybar (status bar)
- Fuzzel (launcher)
- Mako (notifications)
- PipeWire + WirePlumber (audio)
- NetworkManager + Bluetooth
- Clipboard, screenshots, brightness, media keys

### Applications
- **Terminal**: Alacritty
- **Browser**: Chromium (default browser set)
- **Editor**: Neovim + LazyVim starter
- Fonts: Hack Nerd Font, Noto (+ emoji)

### CLI / DevOps tooling (best-effort)
Installed only if present in your repos:
- terraform, terragrunt
- kubectl, helm, k9s, kustomize
- docker, docker-compose
- aws-cli, azure-cli
- go, nodejs, python
- jq, yq, ripgrep, fd, fzf, etc.

Missing tools are **skipped**, not fatal.

---

## Design principles

- **No AUR**
- **No Flatpak**
- **No interactive pacman conflicts**
- **Idempotent**: safe to re-run
- Explicit DNS checks before network operations
- Minimal assumptions about the base system

---

## Supported installation methods

### Recommended (most reproducible)

Clone the repo and run locally:

```bash
sudo pacman -S --noconfirm git
git clone https://github.com/<your-username>/cortados.git
cd cortados
chmod +x cortados.sh
./cortados.sh
