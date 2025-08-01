#!/usr/bin/env bash
log "Installing VMware Tools and video drivers..."
<<<<<<< HEAD
arch-chroot /mnt bash -c '
  pacman --noconfirm -Sy open-vm-tools xf86-video-vmware xf86-input-vmmouse
  systemctl enable vmtoolsd
  systemctl enable vmware-vmblock-fuse
'
=======
pacman --noconfirm -Sy open-vm-tools xf86-video-vmware xf86-input-vmmouse
systemctl enable vmtoolsd
systemctl enable vmware-vmblock-fuse
>>>>>>> d355b03 (Changing file structure)
checkpoint "VMware guest enhancements installed"