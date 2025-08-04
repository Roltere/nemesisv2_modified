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
    nic=$(ip link | grep "wl"* | grep -o -P "(?= ).*(?=:)" | sed -e "s/^[[:space:]]*//" | cut -d$'\n' -f 1)
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
disk=$(sudo fdisk -l | grep "dev" | grep -o -P "(?=/).*(?=:)" | cut -d$'\n' -f1)
echo "label: gpt" | sfdisk --no-reread --force $disk
sfdisk --no-reread --force $disk << EOF
,260M,U,*
;
EOF
if [ "$vm" = true ]; then
    diskpart1=${disk}1
    diskpart2=${disk}2
else
    diskpart1=$(sudo fdisk -l | grep "dev" | sed -n "2p" | cut -d " " -f 1)
    diskpart2=$(sudo fdisk -l | grep "dev" | sed -n "3p" | cut -d " " -f 1)
fi

# Create LVM on raw partition (no encryption)
printf "\n\nCreating LVM...\n"
pvcreate -ffy "${diskpart2}"
vgcreate lvgroup "${diskpart2}"

# Partition /root /swap
printf "\n\nConfiguring /root /swap...\n"
lvcreate -y -L 4G lvgroup -n swap
lvcreate -y -l 100%FREE lvgroup -n root
mkfs.ext4 -FF /dev/lvgroup/root
mkswap /dev/lvgroup/swap
mount /dev/lvgroup/root /mnt
swapon /dev/lvgroup/swap

# Partition /boot
printf "\n\nConfiguring /boot...\n"
mkfs.fat -I -F 32 "${diskpart1}"
mkdir /mnt/boot
mount "${diskpart1}" /mnt/boot

# Init installation
printf "\n\nPacstrap installation...\n"
pacman --noconfirm -Sy archlinux-keyring
pacstrap /mnt base linux linux-firmware lvm2 grub efibootmgr
genfstab -U /mnt >> /mnt/etc/fstab

# Create stage 2 script
printf "\n\nCreating stage 2 script..."
cat > /mnt/nemesis.sh << 'EOF'
#!/bin/bash
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
printf "\n\nConfiguring Pacman... \n"
echo "
[multilib]
Include = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
curl https://blackarch.org/strap.sh | sh
echo "Server = https://blackarch.org/blackarch/blackarch/os/x86_64" > /etc/pacman.d/blackarch-mirrorlist
pacman --noconfirm -Syu
pacman --noconfirm -Sy sudo base-devel yay networkmanager systemd-resolvconf openssh git neovim tmux wget p7zip neofetch noto-fonts ttf-noto-nerd fish less ldns

# Set timezone to UTC
printf "\n\nSetting timezone...\n"
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
systemctl enable systemd-timesyncd.service

# Configure localization
printf "\nConfiguring locales...\n"
echo C.UTF-8 UTF-8 > /etc/locale.gen
echo en_US.UTF-8 UTF-8 >> /etc/locale.gen
echo en_GB.UTF-8 UTF-8 >> /etc/locale.gen
locale-gen
echo LANG=en_GB.UTF-8 > /etc/locale.conf
export LANG=en_GB.UTF-8
echo "
KEYMAP=uk
FONT=Goha-16" > /etc/vconsole.conf

# Configure network
printf "\n\nConfiguring network...\n"
echo $hostname > /etc/hostname
rm /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Kill telemetry
echo "
[connectivity]
enabled=false" > /usr/lib/NetworkManager/conf.d/20-connectivity.conf

echo "
MulticastDNS=no
LLMNR=no" >> /etc/systemd/resolved.conf

systemctl enable systemd-resolved.service
systemctl enable NetworkManager.service

# Configure initramfs
printf "\n\nConfiguring initramfs...\n"
echo "HOOKS=(base udev autodetect keyboard keymap consolefont modconf block lvm2 filesystems fsck)" > /etc/mkinitcpio.conf
mkinitcpio -P

# Configure users
printf "\n\nConfiguring users...\n"
echo "%wheel    ALL=(ALL) ALL" >> /etc/sudoers
useradd -m -G users,wheel $username
echo -e "$password\n$password" | passwd $username
sudo -Hu $username mkdir /home/$username/.ssh
sudo -Hu $username chmod 750 /home/$username/.ssh
mkdir /opt/workspace
chgrp users /opt/workspace
chmod 775 /opt/workspace
chmod g+s /opt/workspace
setfacl -Rdm g:users:rwx /opt/workspace

# Configure bootloader
printf "\n\nConfiguring bootloader...\n"
echo GRUB_DISTRIBUTOR="Arch Nemesis" > /etc/default/grub
grub-install --removable --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --sbat=/usr/share/grub/sbat.csv --modules="all_video boot btrfs cat chain configfile echo efifwsetup efinet ext2 fat font gettext gfxmenu gfxterm gfxterm_background gzio halt help hfsplus iso9660 jpeg keystatus loadenv loopback linux ls lsefi lsefimmap lsefisystab lssal memdisk minicmd normal ntfs part_apple part_msdos part_gpt password_pbkdf2 png probe reboot regexp search search_fs_uuid search_fs_file search_label sleep smbios test true video xfs zfs zfscrypt zfsinfo play cpuid tpm lvm"
sudo -u $username /bin/sh -c "echo $password | yay --sudoflags "-S" --noconfirm -Sy shim-signed sbsigntools"
mv /boot/EFI/BOOT/BOOTx64.EFI /boot/EFI/BOOT/grubx64.efi
cp /usr/share/shim-signed/shimx64.efi /boot/EFI/BOOT/BOOTx64.EFI
cp /usr/share/shim-signed/mmx64.efi /boot/EFI/BOOT/
mkdir /opt/workspace/sb
openssl req -newkey rsa:4096 -nodes -keyout /opt/workspace/sb/MOK.key -new -x509 -sha256 -days 3650 -subj "/CN=MOK/" -out /opt/workspace/sb/MOK.crt
openssl x509 -outform DER -in /opt/workspace/sb/MOK.crt -out /opt/workspace/sb/MOK.cer
sbsign --key /opt/workspace/sb/MOK.key --cert /opt/workspace/sb/MOK.crt --output /boot/vmlinuz-linux /boot/vmlinuz-linux
sbsign --key /opt/workspace/sb/MOK.key --cert /opt/workspace/sb/MOK.crt --output /boot/EFI/BOOT/grubx64.efi /boot/EFI/BOOT/grubx64.efi
mkdir -p /etc/pacman.d/hooks
curl https://raw.githubusercontent.com/cinerieus/nemesisv2/refs/heads/main/config/999-sign_kernel_for_secureboot.hook -o /etc/pacman.d/hooks/999-sign_kernel_for_secureboot.hook
cp /opt/workspace/sb/MOK.cer /boot
chown root:root /opt/workspace/sb
chmod -R 600 /opt/workspace/sb
echo "- Remove /boot/EFI/BOOT/mmx64.efi & /boot/MOK.cer" >> /home/$username/readme.txt

# CUSTOMIZATION
printf "\n\nCustomizing... \n"
# Neovim
sudo -u $username curl https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim -o /home/$username/.local/share/nvim/site/autoload/plug.vim --create-dirs
sudo -u $username curl https://raw.githubusercontent.com/cinerieus/nemesisv2/refs/heads/main/config/init.vim -o /home/$username/.config/nvim/init.vim --create-dirs
sudo -u $username nvim +:PlugInstall +:qa
mkdir -p /root/.local/share/nvim/site/autoload && cp /home/$username/.local/share/nvim/site/autoload/plug.vim /root/.local/share/nvim/site/autoload/plug.vim
mkdir -p /root/.config/nvim && cp /home/$username/.config/nvim/init.vim /root/.config/nvim/init.vim
nvim +:PlugInstall +:qa
# Tmux
sudo -u $username git clone https://github.com/tmux-plugins/tpm /home/$username/.tmux/plugins/tpm
sudo -u $username curl https://raw.githubusercontent.com/cinerieus/nemesisv2/refs/heads/main/config/.tmux.conf -o /home/$username/.tmux.conf
sudo -u $username /home/$username/.tmux/plugins/tpm/scripts/install_plugins.sh
git clone https://github.com/tmux-plugins/tpm /root/.tmux/plugins/tpm
curl https://raw.githubusercontent.com/cinerieus/nemesisv2/refs/heads/main/config/.tmux.conf -o /root/.tmux.conf
/root/.tmux/plugins/tpm/scripts/install_plugins.sh
# Fontconfig
curl https://raw.githubusercontent.com/cinerieus/nemesisv2/refs/heads/main/config/local.conf -o /etc/fonts/local.conf --create-dirs
chmod 755 /etc/fonts
sudo -Hu $username curl https://raw.githubusercontent.com/cinerieus/nemesisv2/refs/heads/main/config/.Xresources -o /home/$username/.Xresources && cp /home/$username/.Xresources /root/.Xresources
sudo -Hu $username xrdb -merge /home/$username/.Xresources && xrdb -merge /home/$username/.Xresources
# Fish
sudo -Hu $username curl https://raw.githubusercontent.com/oh-my-fish/oh-my-fish/master/bin/install > /home/$username/install.fish
sudo -Hu $username fish /home/$username/install.fish --noninteractive && \
mv /home/$username/install.fish /root
sudo -Hu $username git clone https://github.com/cinerieus/theme-sushi.git /home/$username/.local/share/omf/themes/sushi
sudo -Hu $username curl https://raw.githubusercontent.com/cinerieus/nemesis/master/config.fish -o /home/$username/.config/fish/config.fish
sudo -Hu $username fish -c "omf theme sushi"
fish /root/install.fish --noninteractive
rm /root/install.fish
cp -r /home/$username/.local/share/omf/themes/sushi /root/.local/share/omf/themes/
cp -r /home/$username/.config/fish/config.fish /root/.config/fish/config.fish
fish -c "omf theme sushi"
usermod -s /bin/fish $username
usermod -s /bin/fish root

## DESKTOP ENVIRONMENT
# Install Gnome
pacman --noconfirm -Sy gnome vulkan-intel
systemctl enable gdm.service

# Gnome Shell Extensions
sudo -Hu $username /bin/sh -c "echo $password | yay --sudoflags \"-S\" --noconfirm -Sy gnome-shell-extension-blur-my-shell gnome-shell-extension-tilingshell gnome-shell-extension-no-overview gnome-shell-extension-rounded-window-corners-reborn-git catppuccin-cursors-mocha papirus-icon-theme papirus-folders-catppuccin-git wofi adw-gtk-theme gradience kitty thunar firefox libreoffice glib2-devel pipewire-libcamera"
sudo -Hu $username dbus-launch --exit-with-session gsettings set org.gnome.shell enabled-extensions "[\"blur-my-shell@aunetx\", \"no-overview@fthx\", \"rounded-window-corners@fxgn\", \"system-monitor@gnome-shell-extensions.gcampax.github.com\", \"tilingshell@ferrarodomenico.com\", \"user-theme@gnome-shell-extensions.gcampax.github.com\"]"

# [ … rest unchanged … ]

EOF

echo '
# Chroot and run stage 2 script
printf "\n\nRunning stage 2..."
cp -f /etc/resolv.conf /mnt/etc/resolv.conf
chmod +x /mnt/nemesis.sh
arch-chroot /mnt ./nemesis.sh
rm /mnt/nemesis.sh
umount /mnt/boot
umount /mnt
sleep 5
' >> /mnt/nemesis.sh

# Finalize
arch-chroot /mnt bash /nemesis.sh
rm /mnt/nemesis.sh
umount /mnt/boot
umount /mnt
sleep 5
