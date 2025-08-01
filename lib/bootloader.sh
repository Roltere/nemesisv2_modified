#!/usr/bin/env bash

# This function runs outside chroot
install_base_packages() {
    log "Installing bootloader and kernel..."
    if ! pacstrap /mnt grub efibootmgr linux linux-firmware; then
        log "ERROR: Failed to install essential packages"
        exit 1
    fi
    log "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
    checkpoint "Base system packages installed"
}

# This function runs inside chroot
configure_bootloader() {
    log "Configuring system and bootloader..."
    ln -sf /usr/share/zoneinfo/"${TIMEZONE:-UTC}" /etc/localtime
    hwclock --systohc
    echo "${LOCALE:-en_US.UTF-8} UTF-8" > /etc/locale.gen
    locale-gen
    echo "LANG=${LOCALE:-en_US.UTF-8}" > /etc/locale.conf
    echo "${HOSTNAME:-nemesis-host}" > /etc/hostname
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    grub-mkconfig -o /boot/grub/grub.cfg
    checkpoint "Bootloader installation and system config complete"
}

# Call the appropriate function based on context
if [[ "${CHROOT_MODE:-no}" == "yes" ]]; then
    configure_bootloader
else
    install_base_packages
fi