#!/usr/bin/env bash
# lib/users.sh

set -euo pipefail

USERNAME="main"    # Change as needed
PASSWORD="changeme"  # Change or generate

log "Adding user $USERNAME..."
arch-chroot /mnt bash -c "
  useradd -m -G wheel,users $USERNAME
  echo '$USERNAME:$PASSWORD' | chpasswd
  echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers
"

checkpoint "User creation complete"
