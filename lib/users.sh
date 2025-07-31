#!/usr/bin/env bash
USERNAME="main"
PASSWORD="password"
log "Adding user $USERNAME..."
arch-chroot /mnt bash -c "
  useradd -m -G wheel,users $USERNAME
  echo '$USERNAME:$PASSWORD' | chpasswd
  echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers
"
checkpoint "User creation complete"