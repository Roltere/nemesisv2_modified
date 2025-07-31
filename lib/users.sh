#!/usr/bin/env bash
set -euo pipefail
source /root/logging.sh

checkpoint "User and sudo configuration"

log "Setting timezone, locale, and hostname"
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
sed -i 's/#en_GB.UTF-8/en_GB.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_GB.UTF-8" > /etc/locale.conf
echo "\$HOSTNAME" > /etc/hostname

log "Enabling NetworkManager"
systemctl enable NetworkManager

log "Creating user \$USERNAME and setting password"
useradd -m -G wheel -s /bin/bash "\$USERNAME"
echo "\$USERNAME:\$PASSWORD" | chpasswd

log "Enabling sudo for wheel group"
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# mkinitcpio for LVM root
log "Ensuring mkinitcpio.conf has lvm2 hook"
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
log "Regenerating initramfs"
mkinitcpio -P

checkpoint "User setup complete"