# Cortados

Opinionated post-install bootstrap script for **Arch Linux**.

This repository contains a single script that turns a minimal Arch base install into a
keyboard-driven **Hyprland** workstation with an **Omarchy-inspired** workflow.

The goal is:

- predictable
- reproducible
- minimal
- boring (in a good way)

No display manager. No desktop environment. No hidden magic.

---

## What This Does

After a clean Arch install, the script installs and configures:

- Hyprland (Wayland compositor)
- Waybar, mako, walker
- PipeWire + WirePlumber (audio works out of the box)
- iwd (networking, unchanged from base install)
- XDG portals (screensharing, file pickers, desktop integration)
- Omarchy-derived Catppuccin theme assets
- Keyboard-driven workflow and locked keybindings
- Docker and common developer tooling
- Sensible laptop defaults (power profiles, zram, brightness)

Hyprland is launched directly from TTY using `dbus-run-session`.
No display manager is used.

---

## What This Does _Not_ Do

- It does **not** install Arch Linux
- It does **not** manage disks or bootloaders
- It does **not** install a desktop environment
- It does **not** manage personal dotfiles beyond what is required to function

Arch installation is expected to be done first (manually or via `archinstall`).

---

## Requirements

Before running the script, you must have:

- A working Arch Linux base install
- A normal user with `sudo` access
- Network connectivity (wired or via iwd)
- `curl` and `git` available (usually present on base installs)

---

## Usage

After logging into your freshly installed Arch system:

```bash
curl -fsSL https://raw.githubusercontent.com/caffeinated-minds/cortados/main/cortados.sh | bash
```

