#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/logging.sh"

checkpoint "Partitioning and disk setup (EFI + LVM, NO LUKS)"

# Detect disk (use /dev/sda as default for VM, adjust as needed)
DISK="/dev/sda"
log "Using disk: $DISK"

umount -f -l /mnt || true
swapoff -a || true
vgchange -a n lvgroup || true

log "Partitioning $DISK"
echo "label: gpt" | sfdisk --no-reread --force "$DISK"
sfdisk --no-reread --force "$DISK" <<EOF
,512M,U,*
;
EOF

DISKPART1="${DISK}1"
DISKPART2="${DISK}2"

log "Formatting EFI partition"
mkfs.fat -F32 "$DISKPART1"

log "Setting up LVM"
pvcreate -ffy "$DISKPART2"
vgcreate lvgroup "$DISKPART2"
lvcreate -y -L 4G lvgroup -n swap
lvcreate -y -l 100%FREE lvgroup -n root

log "Formatting LVM and mounting"
mkfs.ext4 -F /dev/lvgroup/root
mkswap /dev/lvgroup/swap
mount /dev/lvgroup/root /mnt
swapon /dev/lvgroup/swap

mkdir -p /mnt/boot
mount "$DISKPART1" /mnt/boot

checkpoint "Disk setup complete (NO LUKS)"
