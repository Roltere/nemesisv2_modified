#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Error on line $LINENO"; exit 1' ERR

# ── Ensure root ───────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "This installer must be run as root." >&2
  exit 1
fi

# ── Defaults & CLI flags ───────────────────────────────
hostname="arch-vm"
username="user"
password="Ch4ngeM3!"
swap_size="4G"
filesystem="ext4"
disk=""

usage() {
  cat <<EOF
Usage: $0 [-n hostname] [-u username] [-P password] [-S swap_size] [-f fs] [-d disk]
  -n Hostname (default: $hostname)
  -u Username (default: $username)
  -P Password (default: $password)
  -S Swapfile size (e.g. 4G; default: $swap_size)
  -f Root FS type (ext4, btrfs; default: $filesystem)
  -d Target disk (e.g. /dev/sda; auto‑detected if omitted)
EOF
  exit 1
}

while getopts "n:u:P:S:f:d:h" opt; do
  case $opt in
    n) hostname="$OPTARG" ;;
    u) username="$OPTARG" ;;
    P) password="$OPTARG" ;;
    S) swap_size="$OPTARG" ;;
    f) filesystem="$OPTARG" ;;
    d) disk="$OPTARG" ;;
    *) usage ;;
  esac
done

# ── Logging & Prep ────────────────────────────────────
exec > >(tee install.log) 2>&1
echo "=== Arch-VM install started: $(date) ==="

loadkeys uk
timedatectl set-ntp true

die() { echo "$*" >&2; exit 1; }

# ── Stage 1: Disk prep ────────────────────────────────
prepare_disk() {
  echo "--- Preparing disk ---"
  swapoff -a 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true

  # detect only TYPE=="disk"
  if [[ -z "$disk" ]]; then
    disk=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1; exit}')
  fi
  [[ -b "$disk" ]] || die "Block device '$disk' not found!"

  echo "Using disk: $disk"

  # Clear any existing partition table
  wipefs -af "$disk"
  
  # Check if we're in UEFI or BIOS mode
  if [[ -d /sys/firmware/efi/efivars ]]; then
    echo "UEFI mode detected - creating GPT with EFI partition"
    parted --script "$disk" mklabel gpt
    parted --script "$disk" mkpart ESP fat32 1MiB 261MiB
    parted --script "$disk" set 1 esp on
    parted --script "$disk" mkpart primary "$filesystem" 261MiB 100%
  else
    echo "BIOS mode detected - creating MBR with boot partition"
    parted --script "$disk" mklabel msdos
    parted --script "$disk" mkpart primary "$filesystem" 1MiB 100%
    parted --script "$disk" set 1 boot on
  fi

  partprobe "$disk"
  udevadm settle
  sleep 2

  # More robust partition detection
  if [[ "$disk" =~ nvme ]]; then
    disk1="${disk}p1"
    disk2="${disk}p2"
  else
    disk1="${disk}1"
    disk2="${disk}2"
  fi

  # Check boot mode for partition handling
  if [[ -d /sys/firmware/efi/efivars ]]; then
    # UEFI mode - we have EFI and root partitions
    [[ -b "$disk1" ]] || die "EFI partition $disk1 not found!"
    [[ -b "$disk2" ]] || die "Root partition $disk2 not found!"
    
    echo "EFI -> $disk1, root -> $disk2"
    
    echo "--- Formatting partitions ---"
    mkfs.fat -F32 "$disk1"
    mkfs."$filesystem" -F "$disk2"
    
    echo "--- Mounting filesystems ---"
    mkdir -p /mnt
    mount "$disk2" /mnt
    mkdir -p /mnt/boot
    mount "$disk1" /mnt/boot
  else
    # BIOS mode - only root partition
    [[ -b "$disk1" ]] || die "Root partition $disk1 not found!"
    
    echo "Root -> $disk1"
    
    echo "--- Formatting partitions ---"
    mkfs."$filesystem" -F "$disk1"
    
    echo "--- Mounting filesystems ---"
    mkdir -p /mnt
    mount "$disk1" /mnt
  fi
}

# ── Stage 2: Swapfile ─────────────────────────────────
setup_swap() {
  echo "--- Creating ${swap_size} swapfile ---"
  fallocate -l "$swap_size" /mnt/swapfile
  chmod 600 /mnt/swapfile
  mkswap /mnt/swapfile
  swapon /mnt/swapfile
}

# ── Stage 3: Base install ────────────────────────────
install_base() {
  echo "--- Setting up mirrors ---"
  
  # Update pacman databases first
  pacman --noconfirm -Sy || die "Failed to sync pacman databases"
  
  # Install reflector with better error handling
  if ! pacman --noconfirm -S --needed reflector; then
    echo "Warning: Could not install reflector, using default mirrors"
  else
    echo "Ranking mirrors (this may take a while)..."
    # Use more conservative settings for reflector
    if ! timeout 120 reflector \
         --verbose \
         --protocol https \
         --latest 20 \
         --sort rate \
         --connection-timeout 10 \
         --download-timeout 30 \
         --save /etc/pacman.d/mirrorlist; then
      echo "Warning: reflector failed, using existing mirrorlist"
    fi
  fi

  echo "--- Installing base system ---"
  # Retry pacstrap up to 3 times with cleaned package list
  local retries=3
  for i in $(seq 1 $retries); do
    if pacstrap /mnt \
      base linux linux-firmware \
      sudo base-devel networkmanager \
      systemd-resolvconf openssh git neovim tmux \
      wget p7zip noto-fonts ttf-noto-nerd \
      fish less ldns; then
      break
    else
      echo "pacstrap failed on attempt $i/$retries"
      sleep 10
      if [ "$i" -eq "$retries" ]; then 
        die "pacstrap failed after $retries attempts"
      fi
    fi
  done
}

# ── Stage 4: Chroot config ────────────────────────────
configure_chroot() {
  echo "--- Generating fstab & swap entry ---"
  genfstab -U /mnt >> /mnt/etc/fstab
  echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

  echo "--- Writing stage2 script ---"
  cat > /mnt/nemesis-stage2.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Chroot error on line \$LINENO"; exit 1' ERR

hostname="$hostname"
username="$username"
password="$password"
disk="$disk"

echo "--- Setting up time and locale ---"
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_GB.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo LANG=en_GB.UTF-8 > /etc/locale.conf
echo KEYMAP=uk > /etc/vconsole.conf

echo "--- Setting up hostname and network ---"
echo "\$hostname" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1	localhost
::1		localhost
127.0.1.1	\$hostname.localdomain	\$hostname
HOSTS

# Handle resolv.conf more carefully - it might be busy/mounted
if [[ -L /etc/resolv.conf ]]; then
    # It's already a symlink, just remove it
    rm -f /etc/resolv.conf
elif [[ -f /etc/resolv.conf ]]; then
    # It's a regular file, try to remove it, but don't fail if busy
    rm -f /etc/resolv.conf || {
        echo "Warning: Could not remove /etc/resolv.conf (busy), trying to overwrite..."
        # If we can't remove it, try to make it a symlink anyway
        # This will fail gracefully if the file is truly locked
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || {
            echo "Warning: Could not create resolv.conf symlink, using existing file"
        }
    }
fi

# Only create symlink if we successfully removed the old file or it doesn't exist
if [[ ! -e /etc/resolv.conf ]]; then
    ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi
systemctl enable systemd-resolved NetworkManager

echo "--- Configuring pacman ---"
sed -i '/#\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf

echo "--- Setting up BlackArch repository ---"
# Check network connectivity before trying BlackArch
if ping -c 1 blackarch.org >/dev/null 2>&1; then
    # Download BlackArch bootstrap script
    curl -O https://blackarch.org/strap.sh
    if [[ -f strap.sh ]]; then
        # Note: Checksum verification skipped as it changes frequently
        # Verify it's a reasonable size (not empty/error page)
        if [[ \$(wc -c < strap.sh) -gt 1000 ]]; then
            chmod +x strap.sh && ./strap.sh
            rm -f strap.sh
            echo "BlackArch repository added successfully"
        else
            echo "Warning: BlackArch strap.sh appears invalid, skipping BlackArch setup"
            rm -f strap.sh
        fi
    else
        echo "Warning: Failed to download BlackArch strap.sh"
    fi
else
    echo "Warning: No network connectivity, skipping BlackArch setup"
fi

# Update system
pacman --noconfirm -Syu || echo "Warning: System update failed"

echo "--- Setting up initramfs ---"
sed -i 's/^COMPRESSION=.*/COMPRESSION="zstd"/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard keymap consolefont fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

echo "--- Setting up users ---"
useradd -m -G wheel -s /usr/bin/fish "\$username"
echo -e "\$password\n\$password" | passwd "\$username"
chage -d 0 "\$username"
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

echo "--- Installing bootloader ---"
# Check if we're running in UEFI mode
if [[ -d /sys/firmware/efi/efivars ]]; then
    echo "UEFI mode detected, installing GRUB for UEFI..."
    pacman --noconfirm -S grub efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --removable
    grub-mkconfig -o /boot/grub/grub.cfg
else
    echo "BIOS/Legacy mode detected, installing GRUB for BIOS..."
    pacman --noconfirm -S grub
    
    echo "Installing GRUB to \$disk"
    grub-install --target=i386-pc "\$disk"
    grub-mkconfig -o /boot/grub/grub.cfg
fi

echo "--- Setting up services ---"
systemctl enable sshd

# Only enable VMware tools if we're in a VMware environment
if lspci | grep -i vmware >/dev/null 2>&1 || dmesg | grep -i vmware >/dev/null 2>&1; then
    echo "VMware environment detected, installing VMware tools..."
    if pacman --noconfirm -S open-vm-tools; then
        systemctl enable vmtoolsd vmware-vmblock-fuse
        systemctl enable vgauth.service vmhgfs-fuse.service
    else
        echo "Warning: Failed to install VMware tools"
    fi
else
    echo "Not running in VMware, skipping VMware tools"
fi

echo "--- Installing AUR helper (yay) ---"
# Install yay as the user, not root
sudo -u "\$username" bash <<EOYAY
set -euo pipefail
cd /home/\$username

# Clone yay with error handling
if git clone https://aur.archlinux.org/yay.git; then
    cd yay
    # Build and install yay
    if makepkg -si --noconfirm; then
        cd ..
        rm -rf yay
        echo "yay installed successfully"
        
        # Install neofetch from AUR
        if yay --noconfirm -S neofetch; then
            echo "neofetch installed successfully"
        else
            echo "Warning: Failed to install neofetch"
        fi
    else
        echo "Warning: Failed to build yay"
        cd ..
        rm -rf yay
    fi
else
    echo "Warning: Failed to clone yay repository"
fi
EOYAY

echo "Stage 2 completed successfully"
EOF

  chmod +x /mnt/nemesis-stage2.sh
  echo "--- Entering chroot & running stage2 ---"
  arch-chroot /mnt /nemesis-stage2.sh
  
  # Clean up the stage2 script before unmounting
  rm -f /mnt/nemesis-stage2.sh
}

# ── Stage 5: Cleanup ─────────────────────────────────
cleanup() {
  echo "--- Final sync & unmount ---"
  sync
  swapoff /mnt/swapfile 2>/dev/null || true
  umount -R /mnt || echo "Warning: /mnt still busy"
  echo "=== Install finished: $(date) ==="
  echo ""
  echo "Installation complete! You can now:"
  echo "1. Remove the installation media"
  echo "2. Reboot the system"
  echo "3. Login with username: $username"
  echo "4. Change the default password on first login"
}

# ── Main ─────────────────────────────────────────────
prepare_disk
setup_swap
install_base
configure_chroot
cleanup
