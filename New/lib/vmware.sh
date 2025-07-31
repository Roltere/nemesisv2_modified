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

checkpoint "VMware guest integration"

log "Installing open-vm-tools and X drivers"
install_pacman_tools open-vm-tools xf86-input-vmmouse xf86-video-vmware

systemctl enable vmtoolsd || log "WARNING: Could not enable vmtoolsd"
systemctl enable vmware-vmblock-fuse || log "WARNING: Could not enable vmware-vmblock-fuse"

checkpoint "VMware guest tools setup complete"


