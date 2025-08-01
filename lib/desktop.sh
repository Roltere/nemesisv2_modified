#!/usr/bin/env bash
set -euo pipefail
source ./logging.sh
source ./desktop-selector.sh

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

# Use the new modular desktop installation
install_desktop_environment
