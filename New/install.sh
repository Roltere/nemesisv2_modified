#!/usr/bin/env bash
set -euo pipefail

export LOGFILE="/tmp/install.log"
rm -f "$LOGFILE"

HOSTNAME="main"
USERNAME="main"
PASSWORD="changeme"

log() { local msg="[$(date '+%F %T')] $*"; echo -e "$msg" | tee -a "$LOGFILE"; }
checkpoint() { log "=== CHECKPOINT: $* ==="; }
fail() { log "ERROR: $*"; exit 1; }
trap 'fail "An unexpected error occurred at line $LINENO."' ERR

log "Starting Arch-Nemesis modular VM install..."
checkpoint "Configuration check"

loadkeys uk

# Partition and LVM (no LUKS)
DISK="/dev/sda"
checkpoint "Partitioning and disk setup"

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

mkfs.fat -F32 "$DISKPART1"
pvcreate -ffy "$DISKPART2"
vgcreate lvgroup "$DISKPART2"
lvcreate -y -L 4G lvgroup -n swap
lvcreate -y -l 100%FREE lvgroup -n root
mkfs.ext4 -F /dev/lvgroup/root
mkswap /dev/lvgroup/swap
mount /dev/lvgroup/root /mnt
swapon /dev/lvgroup/swap
mkdir -p /mnt/boot
mount "$DISKPART1" /mnt/boot

checkpoint "Disk setup complete"

# Pacstrap — all essentials included!
checkpoint "Installing base system"
pacman --noconfirm -Sy archlinux-keyring
pacstrap /mnt base linux linux-firmware lvm2 sudo networkmanager grub efibootmgr nano

log "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

checkpoint "Base system ready"

# Copy chroot modules
checkpoint "Copying chroot scripts"
for file in lib/logging.sh lib/users.sh lib/desktop.sh lib/vmware.sh lib/bootloader.sh; do
    cp "$file" "/mnt/root/$(basename "$file")"
done

# Orchestrator for chrooted stage2
cat <<EOF >/mnt/root/nemesis-stage2.sh
#!/usr/bin/env bash
set -euo pipefail
export LOGFILE="/root/install.log"
export HOSTNAME="$HOSTNAME"
export USERNAME="$USERNAME"
export PASSWORD="$PASSWORD"
source /root/logging.sh

checkpoint "Beginning Stage 2 (chrooted post-install)"

for module in /root/users.sh /root/desktop.sh /root/vmware.sh /root/bootloader.sh; do
    checkpoint "Running \$(basename "\$module") in chroot"
    bash "\$module"
done

log "Stage 2 (chroot) complete. You may reboot."
EOF
chmod +x /mnt/root/nemesis-stage2.sh

checkpoint "Entering chroot for Stage 2 setup"
arch-chroot /mnt bash /root/nemesis-stage2.sh | tee -a "$LOGFILE"

log "Arch-Nemesis VM install complete. You may reboot now. See $LOGFILE for full log."
