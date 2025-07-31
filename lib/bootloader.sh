#!/usr/bin/env bash
# lib/bootloader.sh

set -euo pipefail

log "Installing bootloader and kernel..."
pacstrap /mnt grub efibootmgr linux linux-firmware

log "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

log "Chrooting and configuring bootloader..."
arch-chroot /mnt bash -c '
  ln -sf /usr/share/zoneinfo/UTC /etc/localtime
  hwclock --systohc
  echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
  locale-gen
  echo "LANG=en_US.UTF-8" > /etc/locale.conf
  echo "nemesis-host" > /etc/hostname
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
  grub-mkconfig -o /boot/grub/grub.cfg
'

checkpoint "Bootloader installation and chroot config complete"
