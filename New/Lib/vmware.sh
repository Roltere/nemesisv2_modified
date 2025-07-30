#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/logging.sh"

checkpoint "VMWare guest integration"

log "Installing open-vm-tools"
arch-chroot /mnt pacman --noconfirm -S open-vm-tools xf86-input-vmmouse xf86-video-vmware
arch-chroot /mnt systemctl enable vmtoolsd

log "Enabling copy/paste and shared folders"
arch-chroot /mnt systemctl enable vmware-vmblock-fuse

# Optional: configure RDP as per your needs
# log "Configuring RDP for $USERNAME"
# (You can add your RDP setup lines here)

checkpoint "VMware guest tools setup complete"
