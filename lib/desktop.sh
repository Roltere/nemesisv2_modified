#!/usr/bin/env bash
set -euo pipefail
source /root/logging.sh

install_pacman_tools() {
    local tool
    for tool in "\$@'; do
        if pacman --noconfirm -S "\$tool"; then
            log "Successfully installed \$tool"
        else
            log "WARNING: Failed to install \$tool"
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
log "Applying Gnome keyboard/input settings for user \$USERNAME"
sudo -u "\$USERNAME" dbus-launch --exit-with-session gsettings set org.gnome.desktop.input-sources sources "[(\\\"xkb\\\", \\\"gb\\\")]"

# Fonts and fastfetch
install_pacman_tools noto-fonts ttf-noto-nerd fastfetch

log "Downloading wallpaper"
mkdir -p /home/"\$USERNAME"/Pictures
curl -L https://w.wallhaven.cc/full/rr/wallhaven-rr9kyw.png -o /home/"\$USERNAME"/Pictures/wallpaper.png
chown "\$USERNAME:\$USERNAME" /home/"\$USERNAME"/Pictures/wallpaper.png

# --- Catppuccin KDE Theme Install & Apply ---
log "Setting up Catppuccin KDE theme, color scheme, icons"

sudo -u "\$USERNAME" git clone --depth=1 https://github.com/catppuccin/kde.git /home/"\$USERNAME"/catppuccin-kde
chown -R "\$USERNAME:\$USERNAME" /home/"\$USERNAME"/catppuccin-kde

mkdir -p /home/"\$USERNAME"/.local/share/plasma/desktoptheme/catppuccin-mocha
cp -r /home/"\$USERNAME"/catppuccin-kde/themes/Catppuccin-Mocha-Standard-Lavender /home/"\$USERNAME"/.local/share/plasma/desktoptheme/catppuccin-mocha
mkdir -p /home/"\$USERNAME"/.local/share/color-schemes
cp /home/"\$USERNAME"/catppuccin-kde/color-schemes/Catppuccin-Mocha.colors /home/"\$USERNAME"/.local/share/color-schemes/
mkdir -p /home/"\$USERNAME"/.local/share/konsole
cp /home/"\$USERNAME"/catppuccin-kde/konsole/Catppuccin-Mocha.colorscheme /home/"\$USERNAME"/.local/share/konsole/
mkdir -p /home/"\$USERNAME"/.local/share/aurorae/themes
cp -r /home/"\$USERNAME"/catppuccin-kde/aurorae/Catppuccin-Mocha /home/"\$USERNAME"/.local/share/aurorae/themes/
chown -R "\$USERNAME:\$USERNAME" /home/"\$USERNAME"/.local/share

install_pacman_tools papirus-icon-theme

sudo -u "\$USERNAME" mkdir -p /home/"\$USERNAME"/.config

cat <<EOF > /home/"\$USERNAME"/.config/kdeglobals
[General]
ColorScheme=Catppuccin-Mocha
[Icons]
Theme=Papirus
EOF

echo -e "[Theme]\\nname=catppuccin-mocha" > /home/"\$USERNAME"/.config/plasmarc
echo -e "[org.kde.kdecoration2]\\ntheme=Catppuccin-Mocha" > /home/"\$USERNAME"/.config/kwinrc

chown -R "\$USERNAME:\$USERNAME" /home/"\$USERNAME"/.config

log "Catppuccin KDE theme applied for user \$USERNAME"

checkpoint "Desktop environments and theming setup complete"