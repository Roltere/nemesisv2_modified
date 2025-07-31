#!/usr/bin/env bash
# lib/vmware.sh

set -euo pipefail

log "Installing VMware Tools and video drivers..."
arch-chroot /mnt bash -c '
  pacman --noconfirm -Sy open-vm-tools xf86-video-vmware xf86-input-vmmouse
  systemctl enable vmtoolsd
  systemctl enable vmware-vmblock-fuse
'

checkpoint "VMware guest enhancements installed"
