#!/bin/bash
read -p "Run Arch-Nemesis VM install script? [Y/N] " proceed
if ! echo "$proceed" | grep -iq '^y'; then
    exit 0
fi

# ── Variables ───────────────────────────────────────────
hostname="main"
username="main"
password="Ch4ngeM3!"
ssh_key=""      # your public key, if any
wifi_ssid=""    # only if using Wi‑Fi
wifi_pass=""
vm=true
rdppass="rdp"

# ── Keyboard & Network ─────────────────────────────────
loadkeys uk
if [ -n "$wifi_ssid" ]; then
    nic=$(ip link | grep -oP 'wl\w+' | head -n1)
    iwctl --passphrase "$wifi_pass" station "$nic" connect "$wifi_ssid"
fi

timedatectl set-timezone UTC
timedatectl set-ntp true

# ── Partitioning ───────────────────────────────────────
echo -e "\nFormatting disk..."
umount -R /mnt 2>/dev/null
swapoff -a
vgchange -a n 2>/dev/null   # in case an old VG was left around

disk=$(lsblk -dn -o NAME | head -n1)
disk="/dev/$disk"
echo "Using $disk"

# create GPT with two partitions: 1=EFI 260M, 2=root
sfdisk --no-reread --force "$disk" <<EOF
label: gpt
,260M,U,*
;
EOF

diskpart1="${disk}1"
diskpart2="${disk}2"

# ── Filesystems ────────────────────────────────────────
echo -e "\nCreating filesystems..."
mkfs.fat -F32 "$diskpart1"
mkfs.ext4 -F "$diskpart2"

mkdir -p /mnt/boot
mount "$diskpart2" /mnt
mkdir -p /mnt/boot
mount "$diskpart1" /mnt/boot

# ── Swapfile ───────────────────────────────────────────
echo -e "\nSetting up swapfile..."
fallocate -l 4G /mnt/swapfile
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
swapon /mnt/swapfile

# ── Install base system ────────────────────────────────
echo -e "\nPacstrap base system..."
pacman --noconfirm -Sy archlinux-keyring
pacstrap /mnt base linux linux-firmware \
    sudo base-devel yay networkmanager systemd-resolvconf \
    openssh git neovim tmux wget p7zip neofetch noto-fonts \
    ttf-noto-nerd fish less ldns open-vm-tools

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab
# ensure swapfile entry
echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

# ── Stage2 script ──────────────────────────────────────
cat > /mnt/nemesis-stage2.sh <<'EOF'
#!/bin/bash
set -e

hostname="arch-vm"
username="user"
password="Ch4ngeM3!"
ssh_key=""
wifi_ssid=""
wifi_pass=""
vm=true
rdppass="rdp"

# chroot will run this, so we're in /mnt

# ── Pacman & repos ────────────────────────────────────
echo -e "\nConfiguring pacman..."
sed -i '/#\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
curl https://blackarch.org/strap.sh | sh
echo "Server = https://blackarch.org/blackarch/os/x86_64" > /etc/pacman.d/blackarch-mirrorlist
pacman --noconfirm -Syu
pacman --noconfirm -Sy sudo base-devel yay networkmanager \
    systemd-resolvconf openssh git neovim tmux wget p7zip \
    neofetch noto-fonts ttf-noto-nerd fish less ldns \
    open-vm-tools

# ── Time & locale ─────────────────────────────────────
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo -e "en_GB.UTF-8 UTF-8\nC.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo LANG=en_GB.UTF-8 > /etc/locale.conf
echo "KEYMAP=uk" > /etc/vconsole.conf

# ── Network ───────────────────────────────────────────
echo "$hostname" > /etc/hostname
rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable systemd-resolved.service
systemctl enable NetworkManager.service

# ── Initramfs (no encrypt/lvm hooks) ───────────────────
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect keyboard keymap consolefont modconf block filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# ── Users ─────────────────────────────────────────────
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers
useradd -m -G users,wheel $username
echo -e "$password\n$password" | passwd $username
mkdir -p /home/$username/.ssh
chmod 750 /home/$username/.ssh
[ -n "$ssh_key" ] && echo "$ssh_key" > /home/$username/.ssh/authorized_keys \
    && chmod 600 /home/$username/.ssh/authorized_keys \
    && chown $username:$username /home/$username/.ssh/authorized_keys

# ── Bootloader ────────────────────────────────────────
pacman --noconfirm -Sy grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
sed -i '/^GRUB_CMDLINE_LINUX=/d' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# ── VM‑specific tweaks ─────────────────────────────────
if [ "$vm" = true ]; then
    systemctl enable sshd.service
    systemctl enable vmtoolsd.service
    systemctl enable vmware-vmblock-fuse.service
fi

EOF

chmod +x /mnt/nemesis-stage2.sh

# ── Enter chroot ──────────────────────────────────────
echo -e "\nEntering chroot and running stage2..."
arch-chroot /mnt /nemesis-stage2.sh

# ── Cleanup ────────────────────────────────────────────
rm /mnt/nemesis-stage2.sh
umount -R /mnt
echo -e "\nInstallation complete. You can reboot now."
