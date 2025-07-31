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

checkpoint "Installing GNOME and KDE Plasma desktop environments"

# Install GNOME + core apps
install_pacman_tools gnome gnome-tweaks kitty thunar firefox pipewire

# Install KDE Plasma + core KDE apps + SDDM login manager
install_pacman_tools plasma kde-applications sddm

log "Enabling SDDM display manager for session switching"
systemctl enable sddm

# Gnome user config (applies only if session is GNOME)
log "Applying Gnome keyboard/input settings for user $USERNAME"
sudo -u "$USERNAME" dbus-launch --exit-with-session gsettings set org.gnome.desktop.input-sources sources "[(\"xkb\", \"gb\")]"

# Fonts and fastfetch
install_pacman_tools noto-fonts ttf-noto-nerd fastfetch

log "Downloading wallpaper"
mkdir -p /home/"$USERNAME"/Pictures
curl -L https://w.wallhaven.cc/full/rr/wallhaven-rr9kyw.png -o /home/"$USERNAME"/Pictures/wallpaper.png
chown "$USERNAME:$USERNAME" /home/"$USERNAME"/Pictures/wallpaper.png

checkpoint "Desktop environments and theming setup complete"


