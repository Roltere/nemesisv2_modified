#!/usr/bin/env bash

setup_base_system() {
    log "Updating keyring and pacman..."
    pacman --noconfirm -Sy archlinux-keyring
    log "Installing essential packages..."
    if ! pacman --noconfirm -Sy sudo base-devel git networkmanager openssh wget curl vim nano less lvm2; then
        log "WARNING: Some essential packages failed to install"
    fi
    log "Enabling networking services..."
    systemctl enable NetworkManager
    systemctl enable systemd-resolved
    log "Base system setup complete."
    checkpoint "Base system ready"
}