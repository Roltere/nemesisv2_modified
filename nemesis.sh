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
  
  parted --script "$disk" mklabel gpt
  parted --script "$disk" mkpart ESP fat32 1MiB 261MiB
  parted --script "$disk" set 1 esp on
  parted --script "$disk" mkpart primary "$filesystem" 261MiB 100%

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

  # Verify partitions exist
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
    if pacstrap -K /mnt \
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

rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable systemd-resolved NetworkManager

echo "--- Configuring pacman ---"
sed -i '/#\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf

echo "--- Setting up BlackArch repository ---"
# Check network connectivity before trying BlackArch
if ping -c 1 blackarch.org >/dev/null 2>&1; then
    # Download and verify BlackArch bootstrap script
    curl -O https://blackarch.org/strap.sh
    if [[ -f strap.sh ]]; then
        echo "7998487a8c2a38b8fd7ef7c5e2e0e0b88d91a0bb sha1sum strap.sh" | sha1sum -c || {
            echo "Warning: BlackArch strap.sh checksum failed, skipping BlackArch setup"
        }
        if sha1sum -c <<<"7998487a8c2a38b8fd7ef7c5e2e0e0b88d91a0bb strap.sh" 2>/dev/null; then
            chmod +x strap.sh && ./strap.sh
            rm -f strap.sh
        fi
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
useradd -m -G wheel -s /bin/fish "\$username"
echo -e "\$password\n\$password" | passwd "\$username"
chage -d 0 "\$username"
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

echo "--- Installing bootloader ---"
pacman --noconfirm -S grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

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
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
cd ..
rm -rf yay

# Install neofetch from AUR
yay --noconfirm -S neofetch
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
