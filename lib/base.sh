#!/usr/bin/env bash

setup_base_system() {
    log "Checking available space before package installation..."
    df -h / /tmp /mnt 2>/dev/null || true
    
    log "Updating keyring and pacman..."
    if ! pacman --noconfirm -Sy archlinux-keyring; then
        log "ERROR: Failed to update keyring"
        df -h / /tmp 2>/dev/null || true
        return 1
    fi
    
    log "Installing essential packages..."
    if ! pacman --noconfirm -Sy sudo base-devel git networkmanager openssh wget curl vim nano less lvm2; then
        log "WARNING: Some essential packages failed to install"
        log "Checking disk space after failure:"
        df -h / /tmp /mnt 2>/dev/null || true
    fi
    log "Enabling networking services..."
    systemctl enable NetworkManager
    systemctl enable systemd-resolved
    log "Base system setup complete."
    checkpoint "Base system ready"
}