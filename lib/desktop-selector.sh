#!/usr/bin/env bash

# Desktop Environment Installation Functions

install_gnome() {
    log "Installing GNOME desktop environment..."
    install_pacman_tools gnome gnome-tweaks gdm
    systemctl enable gdm
    log "GNOME installation complete"
}

install_kde() {
    log "Installing KDE Plasma desktop environment..."
    install_pacman_tools plasma kde-applications sddm plasma-workspace-x11 xorg xorg-xinit
    systemctl enable sddm
    
    # Configure SDDM for X11
    mkdir -p /etc/sddm.conf.d
    cat <<EOF > /etc/sddm.conf.d/10-x11.conf
[General]
DisplayServer=x11
EOF
    log "KDE Plasma installation complete"
}

install_minimal() {
    log "Installing minimal desktop components..."
    install_pacman_tools xorg xorg-xinit i3-wm i3status dmenu xterm
    log "Minimal desktop installation complete"
}

configure_desktop_theme() {
    if [[ "${INSTALL_THEMES:-yes}" != "yes" ]]; then
        return 0
    fi
    
    log "Configuring desktop themes..."
    install_pacman_tools noto-fonts ttf-noto-nerd fastfetch papirus-icon-theme
    
    # Download wallpaper if enabled
    if [[ "${DOWNLOAD_WALLPAPER:-yes}" == "yes" ]]; then
        log "Downloading wallpaper"
        sudo -u "$USERNAME" mkdir -p /home/"$USERNAME"/Pictures
        if sudo -u "$USERNAME" curl -L https://w.wallhaven.cc/full/rr/wallhaven-rr9kyw.png -o /home/"$USERNAME"/Pictures/wallpaper.png; then
            log "Wallpaper downloaded successfully"
        else
            log "WARNING: Failed to download wallpaper, continuing without it"
        fi
    fi
    
    # Install KDE theme if KDE is installed
    if [[ "$DESKTOP_ENV" == "kde" || "$DESKTOP_ENV" == "both" ]]; then
        configure_kde_theme
    fi
}

configure_kde_theme() {
    log "Setting up Catppuccin KDE theme"
    if sudo -u "$USERNAME" git clone --depth=1 https://github.com/catppuccin/kde.git /home/"$USERNAME"/catppuccin-kde; then
        log "Catppuccin theme repository cloned successfully"
        
        # Apply theme files
        sudo -u "$USERNAME" mkdir -p /home/"$USERNAME"/.local/share/plasma/desktoptheme/catppuccin-mocha
        sudo -u "$USERNAME" cp -r /home/"$USERNAME"/catppuccin-kde/themes/Catppuccin-Mocha-Standard-Lavender /home/"$USERNAME"/.local/share/plasma/desktoptheme/catppuccin-mocha
        sudo -u "$USERNAME" mkdir -p /home/"$USERNAME"/.local/share/color-schemes
        sudo -u "$USERNAME" cp /home/"$USERNAME"/catppuccin-kde/color-schemes/Catppuccin-Mocha.colors /home/"$USERNAME"/.local/share/color-schemes/
        sudo -u "$USERNAME" mkdir -p /home/"$USERNAME"/.local/share/konsole
        sudo -u "$USERNAME" cp /home/"$USERNAME"/catppuccin-kde/konsole/Catppuccin-Mocha.colorscheme /home/"$USERNAME"/.local/share/konsole/
        sudo -u "$USERNAME" mkdir -p /home/"$USERNAME"/.local/share/aurorae/themes
        sudo -u "$USERNAME" cp -r /home/"$USERNAME"/catppuccin-kde/aurorae/Catppuccin-Mocha /home/"$USERNAME"/.local/share/aurorae/themes/
        
        # Apply theme configuration
        sudo -u "$USERNAME" mkdir -p /home/"$USERNAME"/.config
        cat <<EOF > /home/"$USERNAME"/.config/kdeglobals
[General]
ColorScheme=Catppuccin-Mocha
[Icons]
Theme=Papirus
EOF
        echo -e "[Theme]\nname=catppuccin-mocha" > /home/"$USERNAME"/.config/plasmarc
        echo -e "[org.kde.kdecoration2]\ntheme=Catppuccin-Mocha" > /home/"$USERNAME"/.config/kwinrc
        
        # Fix ownership
        chown -R "$USERNAME:$USERNAME" /home/"$USERNAME"/catppuccin-kde
        chown -R "$USERNAME:$USERNAME" /home/"$USERNAME"/.local/share
        chown -R "$USERNAME:$USERNAME" /home/"$USERNAME"/.config
        if [[ -f /home/"$USERNAME"/Pictures/wallpaper.png ]]; then
            chown "$USERNAME:$USERNAME" /home/"$USERNAME"/Pictures/wallpaper.png
        fi
        
        log "Catppuccin KDE theme applied for user $USERNAME"
    else
        log "WARNING: Failed to clone Catppuccin theme, skipping theme setup"
    fi
}

# Main desktop installation function
install_desktop_environment() {
    local desktop="${DESKTOP_ENV:-gnome}"
    
    log "Installing desktop environment: $desktop"
    
    case "$desktop" in
        "gnome")
            install_gnome
            ;;
        "kde")
            install_kde
            ;;
        "both")
            install_gnome
            install_kde
            ;;
        "minimal")
            install_minimal
            ;;
        *)
            log "ERROR: Unknown desktop environment: $desktop"
            return 1
            ;;
    esac
    
    # Common desktop packages
    install_pacman_tools firefox kitty thunar pipewire pipewire-pulse
    
    # Configure themes
    configure_desktop_theme
    
    # GNOME-specific settings
    if [[ "$desktop" == "gnome" || "$desktop" == "both" ]]; then
        log "Applying GNOME keyboard/input settings for user $USERNAME"
        sudo -u "$USERNAME" dbus-launch --exit-with-session gsettings set org.gnome.desktop.input-sources sources "[('xkb', '${KEYMAP:-us}')]" || true
    fi
    
    checkpoint "Desktop environment installation complete"
}