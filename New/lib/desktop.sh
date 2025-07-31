#!/usr/bin/env bash
set -euo pipefail
source /root/logging.sh

install_pacman_tools() {
    local tool
    for tool in "$@"; do
        if pacman --noconfirm -S "$tool"; then
            log "Successfully installed $tool"
        else
            log "WARNING: Failed to install $tool"
        fi
    done
}

checkpoint "Gnome desktop and theming"

log "Installing Gnome and extras"
install_pacman_tools gnome gnome-tweaks kitty thunar firefox pipewire

log "Enabling GDM"
systemctl enable gdm

log "Applying Gnome settings (keyboard, fonts, etc)"
sudo -u "$USERNAME" dbus-launch --exit-with-session gsettings set org.gnome.desktop.input-sources sources "[(\"xkb\", \"gb\")]"

log "Installing noto fonts and fastfetch"
install_pacman_tools noto-fonts ttf-noto-nerd fastfetch

log "Downloading wallpaper"
mkdir -p /home/"$USERNAME"/Pictures
curl -L https://w.wallhaven.cc/full/rr/wallhaven-rr9kyw.png -o /home/"$USERNAME"/Pictures/wallpaper.png
chown "$USERNAME:$USERNAME" /home/"$USERNAME"/Pictures/wallpaper.png

checkpoint "Desktop environment setup complete"

