#!/usr/bin/env bash
<<<<<<< HEAD
USERNAME="main"
PASSWORD="password"
log "Adding user $USERNAME..."
arch-chroot /mnt bash -c "
  useradd -m -G wheel,users $USERNAME
  echo '$USERNAME:$PASSWORD' | chpasswd
  echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers
"
=======

# Use configuration variables or defaults
USERNAME="${USERNAME:-main}"
USER_PASSWORD="${USER_PASSWORD:-}"
USER_GROUPS="${USER_GROUPS:-wheel,users}"

log "Adding user $USERNAME..."

# Create user with specified groups
useradd -m -G "$USER_GROUPS" "$USERNAME"

# Set password
if [[ -n "$USER_PASSWORD" ]]; then
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
    log "Password set for user $USERNAME"
else
    log "WARNING: No password set for user $USERNAME. Please set manually after installation."
fi

# Enable sudo for wheel group
if ! grep -q "^%wheel" /etc/sudoers; then
    echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers
fi

# Set up user shell
chsh -s /bin/bash "$USERNAME"

>>>>>>> d355b03 (Changing file structure)
checkpoint "User creation complete"