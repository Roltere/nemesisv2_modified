#!/usr/bin/env bash
set -euo pipefail
source /root/logging.sh

checkpoint "VMware guest integration"

log "Installing open-vm-tools and X drivers"
pacman --noconfirm -S open-vm-tools xf86-input-vmmouse xf86-video-vmware
systemctl enable vmtoolsd
systemctl enable vmware-vmblock-fuse

checkpoint "VMware guest tools setup complete"

