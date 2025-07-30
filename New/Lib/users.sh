#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/logging.sh"

checkpoint "User and sudo configuration"

log "Setting timezone, locale, and hostname"
arch-chroot /mnt ln -sf /usr/share/zoneinfo/UTC /etc/localtime
arch-chroot /mnt hwclock --systohc
arch-chroot /mnt sed -i 's/#en_GB.UTF-8/en_GB.UTF-8/' /etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=en_GB.UTF-8" | tee /mnt/etc/locale.conf
echo "$HOSTNAME" | tee /mnt/etc/hostname

log "Enabling NetworkManager"
arch-chroot /mnt systemctl enable NetworkManager

log "Creating user $USERNAME and setting password"
arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | arch-chroot /mnt chpasswd

log "Enabling sudo for wheel group"
arch-chroot /mnt sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Optional: Add SSH key if provided (edit as needed)
if [[ -n "${SSH_KEY:-}" ]]; then
    log "Adding SSH key for $USERNAME"
    arch-chroot /mnt mkdir -p "/home/$USERNAME/.ssh"
    echo "$SSH_KEY" | arch-chroot /mnt tee "/home/$USERNAME/.ssh/authorized_keys"
    arch-chroot /mnt chown "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh/authorized_keys"
    arch-chroot /mnt chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
fi

checkpoint "User setup complete"
