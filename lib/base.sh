#!/usr/bin/env bash
# lib/base.sh

log "Updating keyring and pacman..."
pacman --noconfirm -Sy archlinux-keyring

log "Installing essential packages..."
pacman --noconfirm -Sy sudo base-devel git networkmanager openssh wget curl vim nano less lvm2

log "Enabling networking services..."
systemctl enable NetworkManager
systemctl enable systemd-resolved

log "Base system setup complete."
checkpoint "Base system ready"
