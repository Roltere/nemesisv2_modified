#!/usr/bin/env bash
source "$(dirname "$0")/logging.sh"

checkpoint "Partitioning and disk setup"

# Example only: always validate $VM and device detection in real code!
DISK="$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1; exit}')"
log "Using disk: $DISK"

umount -f -l /mnt || true
swapoff -a || true
vgchange -a n lvgroup || true
cryptsetup close cryptlvm || true

log "Partitioning $DISK"
echo "label: gpt" | sfdisk --no-reread --force "$DISK"
sfdisk --no-reread --force "$DISK" <<EOF
,260M,U,*
;
EOF

DISKPART1="${DISK}1"
DISKPART2="${DISK}2"

log "Encrypting $DISKPART2"
echo -n "$LUKS_PASSWORD" | cryptsetup -q luksFormat "$DISKPART2" -
echo -n "$LUKS_PASSWORD" | cryptsetup open "$DISKPART2" cryptlvm -

log "LVM setup"
pvcreate -ffy /dev/mapper/cryptlvm
vgcreate lvgroup /dev/mapper/cryptlvm
lvcreate -y -L 4G lvgroup -n swap
lvcreate -y -l 100%FREE lvgroup -n root

log "Formatting and mounting"
mkfs.ext4 -F /dev/lvgroup/root
mkswap /dev/lvgroup/swap
mount /dev/lvgroup/root /mnt
swapon /dev/lvgroup/swap

mkfs.fat -F32 "$DISKPART1"
mkdir -p /mnt/boot
mount "$DISKPART1" /mnt/boot

checkpoint "Disk setup complete"
