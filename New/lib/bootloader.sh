#!/usr/bin/env bash
set -euo pipefail
source /root/logging.sh

checkpoint "Installing GRUB EFI bootloader (no LUKS)"

log "Installing GRUB"
pacman --noconfirm -S grub efibootmgr

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

mkdir -p /boot/EFI/BOOT
cp /boot/EFI/GRUB/grubx64.efi /boot/EFI/BOOT/BOOTx64.EFI

grub-mkconfig -o /boot/grub/grub.cfg

checkpoint "GRUB installation complete"
