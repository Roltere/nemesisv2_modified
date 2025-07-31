#!/usr/bin/env bash
log "Detecting target disk..."
DISK="/dev/sda"
log "Unmounting previous mounts if any..."
umount -R /mnt || true
log "Partitioning $DISK (GPT, EFI+root)..."
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 301MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary ext4 301MiB 100%
log "Formatting partitions..."
mkfs.fat -F32 "${DISK}1"
mkfs.ext4 -F "${DISK}2"
log "Mounting partitions..."
mount "${DISK}2" /mnt
mkdir -p /mnt/boot
mount "${DISK}1" /mnt/boot
checkpoint "Disk partitioning and mount complete"