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

# GNOME (optional - comment/remove if only using KDE)
install_pacman_tools gnome gnome-tweaks kitty thunar firefox pipewire

# KDE Plasma (with X11) and SDDM
install_pacman_tools plasma kde-applications sddm plasma-workspace-x11 xorg xorg-xinit xterm

log "Enabling SDDM (display manager for KDE/GNOME)"
systemctl enable sddm

# Force SDDM to use X11 (not Wayland), and set default session to Plasma (X11)
mkdir -p /etc/sddm.conf.d
cat <<EOF > /etc/sddm.conf.d/10-x11.conf
[Autologin]
Session=plasma.desktop

[General]
DisplayServer=x11

[Theme]
Current=catppuccin-mocha
EOF

# Ensure sessions are present (diagnostic)
if ! test -f /usr/share/xsessions/plasma.desktop; then
    log "WARNING: Plasma X11 session not found!"
fi

# User config for GNOME (optional)
log "Applying Gnome keyboard/input settings for user \$USERNAME"
sudo -u "\$USERNAME" dbus-launch --exit-with-session gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'gb')]"

# Fonts and fastfetch
install_pacman_tools noto-fonts ttf-noto-nerd fastfetch

log "Downloading wallpaper"
sudo -u "\$USERNAME" mkdir -p /home/"\$USERNAME"/Pictures
sudo -u "\$USERNAME" curl -L https://w.wallhaven.cc/full/rr/wallhaven-rr9kyw.png -o /home/"\$USERNAME"/Pictures/wallpaper.png

# --- Catppuccin KDE Theme: Install & Apply ---
log "Setting up Catppuccin KDE theme, color scheme, icons"

sudo -u "\$USERNAME" git clone --depth=1 https://github.com/catppuccin/kde.git /home/"\$USERNAME"/catppuccin-kde

sudo -u "\$USERNAME" mkdir -p /home/"\$USERNAME"/.local/share/plasma/desktoptheme/catppuccin-mocha
sudo -u "\$USERNAME" cp -r /home/"\$USERNAME"/catppuccin-kde/themes/Catppuccin-Mocha-Standard-Lavender /home/"\$USERNAME"/.local/share/plasma/desktoptheme/catppuccin-mocha
sudo -u "\$USERNAME" mkdir -p /home/"\$USERNAME"/.local/share/color-schemes
sudo -u "\$USERNAME" cp /home/"\$USERNAME"/catppuccin-kde/color-schemes/Catppuccin-Mocha.colors /home/"\$USERNAME"/.local/share/color-schemes/
sudo -u "\$USERNAME" mkdir -p /home/"\$USERNAME"/.local/share/konsole
sudo -u "\$USERNAME" cp /home/"\$USERNAME"/catppuccin-kde/konsole/Catppuccin-Mocha.colorscheme /home/"\$USERNAME"/.local/share/konsole/
sudo -u "\$USERNAME" mkdir -p /home/"\$USERNAME"/.local/share/aurorae/themes
sudo -u "\$USERNAME" cp -r /home/"\$USERNAME"/catppuccin-kde/aurorae/Catppuccin-Mocha /home/"\$USERNAME"/.local/share/aurorae/themes/

# Papirus icons
install_pacman_tools papirus-icon-theme

sudo -u "\$USERNAME" mkdir -p /home/"\$USERNAME"/.config

cat <<EOF > /home/"\$USERNAME"/.config/kdeglobals
[General]
ColorScheme=Catppuccin-Mocha
[Icons]
Theme=Papirus
EOF

echo -e "[Theme]\nname=catppuccin-mocha" > /home/"\$USERNAME"/.config/plasmarc
echo -e "[org.kde.kdecoration2]\ntheme=Catppuccin-Mocha" > /home/"\$USERNAME"/.config/kwinrc

log "Catppuccin KDE theme applied for user \$USERNAME"

# Ensure file ownership
chown -R "\$USERNAME:\$USERNAME" /home/"\$USERNAME"/catppuccin-kde
chown -R "\$USERNAME:\$USERNAME" /home/"\$USERNAME"/.local/share
chown -R "\$USERNAME:\$USERNAME" /home/"\$USERNAME"/.config
chown "\$USERNAME:\$USERNAME" /home/"\$USERNAME"/Pictures/wallpaper.png

checkpoint "Desktop environments and theming setup complete"
