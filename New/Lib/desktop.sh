#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/logging.sh"

checkpoint "Gnome desktop and theming"

log "Installing Gnome and extras"
arch-chroot /mnt pacman --noconfirm -Syu gnome gnome-tweaks kitty thunar firefox pipewire

log "Enabling GDM"
arch-chroot /mnt systemctl enable gdm

log "Applying Gnome settings (keyboard, fonts, etc)"
arch-chroot /mnt bash -c "
sudo -u $USERNAME dbus-launch --exit-with-session gsettings set org.gnome.desktop.input-sources sources \"[(\\\"xkb\\\", \\\"gb\\\")]\""

# Install theming, shell extensions, fonts etc. Here, only basics for brevity:
log "Installing noto fonts and neofetch"
arch-chroot /mnt pacman --noconfirm -S noto-fonts ttf-noto-nerd neofetch

# Optionally download and set a wallpaper (as per your script)
log "Downloading wallpaper"
arch-chroot /mnt mkdir -p /home/"$USERNAME"/Pictures
arch-chroot /mnt curl -L https://w.wallhaven.cc/full/rr/wallhaven-rr9kyw.png -o /home/"$USERNAME"/Pictures/wallpaper.png
arch-chroot /mnt chown "$USERNAME:$USERNAME" /home/"$USERNAME"/Pictures/wallpaper.png

# Set as wallpaper (requires user login; can be pre-set in Gnome dconf with more advanced scripting)

checkpoint "Desktop environment setup complete"
