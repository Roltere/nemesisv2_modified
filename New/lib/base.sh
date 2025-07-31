#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/logging.sh"

checkpoint "Base system installation (pacstrap)"

log "Installing archlinux-keyring"
pacman --noconfirm -Sy archlinux-keyring

log "Pacstrap: base system"
pacstrap /mnt base linux linux-firmware lvm2 grub efibootmgr networkmanager sudo neovim git

log "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

log "Preparing stage2 (chroot) script"
cat <<EOF >/mnt/nemesis-stage2.sh
#!/usr/bin/env bash
set -euo pipefail

export HOSTNAME="$HOSTNAME"
export USERNAME="$USERNAME"
export PASSWORD="$PASSWORD"
export LUKS_PASSWORD="$LUKS_PASSWORD"
export VM="$VM"
export LOGFILE="/root/install.log"

source /root/logging.sh

$(cat <<'STAGE2'
# This will be replaced by actual modules (users, desktop, vmware)
# The launcher will copy the other stage2 modules and run them here.
STAGE2
)
EOF
chmod +x /mnt/nemesis-stage2.sh

log "Copying logging utility for use in chroot"
cp "$(dirname "$0")/logging.sh" /mnt/root/logging.sh

checkpoint "Base system ready (proceeding to chroot phase)"
