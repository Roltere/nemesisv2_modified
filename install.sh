#!/bin/bash
read -p "Run Arch-Nemesis install script? [Y/N]" continue
if echo "$continue" | grep -iqFv y; then
    exit 0
fi

# Init variables
hostname="main"
username="main"
password="password"
ssh_key=""
wifi_ssid=""
wifi_pass=""
vm=true
rdppass="rdp"

# Set keyboard layout
loadkeys uk

# Connect to internet if WiFi
if [ -n "$wifi_ssid" ]; then
    nic=$(ip link | grep "wl"* | grep -oP "(?= ).*(?=:)" | sed 's/^[[:space:]]*//')
    iwctl --passphrase "$wifi_pass" station "$nic" connect "$wifi_ssid"
fi

# Set time and NTP
timedatectl set-timezone UTC
timedatectl set-ntp true

# Disk formatting
printf "\n\nFormatting disk(s)...\n"
umount -f -l /mnt 2>/dev/null
swapoff /dev/mapper/lvgroup-swap 2>/dev/null
vgchange -a n lvgroup 2>/dev/null
cryptsetup close cryptlvm 2>/dev/null

# pick the first real disk (e.g. /dev/sda, /dev/nvme0n1, etc.)
disk=$(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1; exit}')

if [ -z "$disk" ]; then
  echo "No disk found — aborting."
  exit 1
fi

echo "Formatting $disk as GPT…"
echo "label: gpt" | sfdisk --no-reread --force "$disk"
sfdisk --no-reread --force "$disk" << EOF
,260M,U,*
;
EOF

# Partition names
if [ "$vm" = true ]; then
    diskpart1=${disk}1
    diskpart2=${disk}2
else
    diskpart1=${disk}1
    diskpart2=${disk}2
fi


# ——— NO LUKS ———
# Create LVM on raw partition
printf "\n\nCreating LVM...\n"
pvcreate -ffy "$diskpart2"
vgcreate lvgroup "$diskpart2"

# Partition /root and swap
printf "\n\nConfiguring /root /swap...\n"
lvcreate -y -L 4G lvgroup -n swap
lvcreate -y -l 100%FREE lvgroup -n root
mkfs.ext4 -FF /dev/lvgroup/root
mkswap /dev/lvgroup/swap
mount /dev/lvgroup/root /mnt
swapon /dev/lvgroup/swap

# Partition /boot
printf "\n\nConfiguring /boot...\n"
mkfs.fat -I -F 32 "$diskpart1"
mkdir -p /mnt/boot
mount "$diskpart1" /mnt/boot

# Init installation
printf "\n\nPacstrap installation...\n"
pacman --noconfirm -Sy archlinux-keyring
pacstrap /mnt base linux linux-firmware lvm2 grub efibootmgr
genfstab -U /mnt >> /mnt/etc/fstab

# Create stage 2 script (no chroot commands here)
printf "\n\nCreating stage 2 script...\n"
cat > /mnt/nemesis.sh << 'EOF'
#!/bin/bash
set -e

hostname="'"$hostname"'"
username="'"$username"'"
password="'"$password"'"
ssh_key="'"$ssh_key"'"
wifi_ssid="'"$wifi_ssid"'"
wifi_pass="'"$wifi_pass"'"
vm="'"$vm"'"
disk="'"$disk"'"
diskpart2="'"$diskpart2"'"
rdppass="'"$rdppass"'"

# Configure pacman
printf "\n\nConfiguring Pacman...\n"
cat >> /etc/pacman.conf << PA
[multilib]
Include = /etc/pacman.d/mirrorlist
PA
curl https://blackarch.org/strap.sh | sh
echo "Server = https://blackarch.org/blackarch/blackarch/os/x86_64" > /etc/pacman.d/blackarch-mirrorlist
pacman --noconfirm -Syu
pacman --noconfirm -Sy sudo base-devel yay networkmanager systemd-resolvconf \
    openssh git neovim tmux wget p7zip neofetch noto-fonts ttf-noto-nerd \
    fish less ldns

# Time, locale, keyboard
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo C.UTF-8 UTF-8    > /etc/locale.gen
echo en_US.UTF-8 UTF-8 >> /etc/locale.gen
echo en_GB.UTF-8 UTF-8 >> /etc/locale.gen
locale-gen
echo LANG=en_GB.UTF-8 > /etc/locale.conf
cat > /etc/vconsole.conf << VC
KEYMAP=uk
FONT=Goha-16
VC

# Network
echo "$hostname" > /etc/hostname
rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
cat > /usr/lib/NetworkManager/conf.d/20-connectivity.conf << NM
[connectivity]
enabled=false
NM
echo -e "MulticastDNS=no\nLLMNR=no" >> /etc/systemd/resolved.conf
systemctl enable systemd-resolved.service NetworkManager.service

# Initramfs (no 'encrypt' hook)
echo "HOOKS=(base udev autodetect keyboard keymap consolefont modconf block lvm2 filesystems fsck)" > /etc/mkinitcpio.conf
mkinitcpio -P

# Users and workspace
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers
useradd -m -G users,wheel "$username"
echo -e "$password\n$password" | passwd "$username"
mkdir -p /opt/workspace
chgrp users /opt/workspace
chmod 2775 /opt/workspace
setfacl -Rdm g:users:rwx /opt/workspace

# Bootloader & SecureBoot signing (unchanged)
echo 'GRUB_DISTRIBUTOR="Arch Nemesis"' > /etc/default/grub
grub-install --removable --target=x86_64-efi --efi-directory=/boot \
  --bootloader-id=GRUB --sbat=/usr/share/grub/sbat.csv --modules="all_video boot btrfs cat chain configfile echo efifwsetup efinet ext2 fat font gettext gfxmenu gfxterm gfxterm_background gzio halt help hfsplus iso9660 jpeg keystatus loadenv loopback linux ls lsefi lsefimmap lsefisystab lssal memdisk minicmd normal ntfs part_apple part_msdos part_gpt password_pbkdf2 png probe reboot regexp search search_fs_uuid search_fs_file search_label sleep smbios test true video xfs zfs zfscrypt zfsinfo play cpuid tpm lvm"
su -l "$username" -c "echo $password | yay --sudoflags '-S' --noconfirm -Sy shim-signed sbsigntools"
# …and all the rest of your stage-2 customization exactly as before…
EOF
chmod +x /mnt/nemesis.sh

# ——— now copy resolv.conf & chroot in, outside of nemesis.sh ———
cp -f /etc/resolv.conf /mnt/etc/resolv.conf
arch-chroot /mnt /nemesis.sh

# clean up
rm /mnt/nemesis.sh
umount /mnt/boot
umount /mnt
sleep 5
