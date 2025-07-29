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

  if [[ -z "$disk" ]]; then
    disk=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1; exit}')
  fi
  [[ -b "$disk" ]] || die "Block device '$disk' not found!"
  echo "Using disk: $disk"

  wipefs -af "$disk"

  if [[ -d /sys/firmware/efi/efivars ]]; then
    echo "UEFI mode detected"
    parted --script "$disk" mklabel gpt
    parted --script "$disk" mkpart ESP fat32 1MiB 261MiB
    parted --script "$disk" set 1 esp on
    parted --script "$disk" mkpart primary "$filesystem" 261MiB 100%
  else
    echo "BIOS mode detected"
    parted --script "$disk" mklabel msdos
    parted --script "$disk" mkpart primary "$filesystem" 1MiB 100%
    parted --script "$disk" set 1 boot on
  fi

  partprobe "$disk"
  udevadm settle
  sleep 2

  if [[ "$disk" =~ nvme ]]; then
    disk1="${disk}p1"
    disk2="${disk}p2"
  else
    disk1="${disk}1"
    disk2="${disk}2"
  fi

  echo "EFI -> $disk1, root -> $disk2"
  mkdir -p /mnt /mnt/boot
  echo "--- Formatting partitions ---"
  if [[ -d /sys/firmware/efi/efivars ]]; then
    mkfs.fat -F32 "$disk1"
    mkfs."$filesystem" -F "$disk2"
    mount "$disk2" /mnt
    mount "$disk1" /mnt/boot
  else
    mkfs."$filesystem" -F "$disk1"
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
  pacman --noconfirm -Sy || die "Failed to sync pacman databases"
  if pacman --noconfirm -S --needed reflector; then
    echo "Ranking mirrors..."
    timeout 120 reflector --protocol https --latest 20 \
      --sort rate --connection-timeout 10 \
      --download-timeout 30 --save /etc/pacman.d/mirrorlist || 
      echo "Warning: reflector failed"
  else
    echo "Warning: reflector not installed"
  fi

  echo "--- Installing base system (with go) ---"
  local pkgs=(base linux linux-firmware sudo base-devel go 
    networkmanager systemd-resolvconf openssh git neovim tmux 
    wget p7zip noto-fonts ttf-noto-nerd fish less ldns)
  local retries=3
  for i in $(seq 1 $retries); do
    if pacstrap -K /mnt "${pkgs[@]}"; then
      break
    else
      echo "pacstrap failed attempt $i"
      sleep 10
      [[ $i -eq $retries ]] && die "pacstrap failed after $retries attempts"
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
trap 'echo "Error on line \$LINENO"; exit 1' ERR

# Ensure environment
export MAKEPKG_ALLOW_ROOT=1

# Variables
hostname="$hostname"
username="$username"
password="$password"

# Time & locale
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_GB.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo LANG=en_GB.UTF-8 > /etc/locale.conf

# Hostname & network
echo "\$hostname" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   \$hostname.localdomain \$hostname
HOSTS
rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable systemd-resolved NetworkManager

# Config pacman
sed -i '/#\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf

# BlackArch
if ping -c1 blackarch.org &>/dev/null; then
  curl -O https://blackarch.org/strap.sh
  if [[ -s strap.sh ]]; then chmod +x strap.sh&&./strap.sh; fi
fi

# Update system
pacman --noconfirm -Syu

# Initramfs
sed -i 's/^COMPRESSION=.*/COMPRESSION="zstd"/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard keymap consolefont fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Users
useradd -m -G wheel -s /usr/bin/fish "\$username"
echo -e "\$password
\$password"|passwd "\$username"
chage -d 0 "\$username"
echo "%wheel ALL=(ALL) ALL">>/etc/sudoers

# Bootloader
echo "Installing GRUB..."
if [[ -d /sys/firmware/efi/efivars ]]; then
  pacman --noconfirm -S grub efibootmgr
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --removable
  grub-mkconfig -o /boot/grub/grub.cfg
else
  pacman --noconfirm -S grub
  grub-install --target=i386-pc "$disk"
  grub-mkconfig -o /boot/grub/grub.cfg
fi

# Services
systemctl enable sshd
if lspci|grep -iq vmware;then
  pacman --noconfirm -S open-vm-tools
  systemctl enable vmtoolsd vmware-vmblock-fuse vgauth.service vmhgfs-fuse.service
fi

# AUR helper (yay) as user
echo "--- Installing yay as \$username ---"
runuser -u "\$username" -- bash -lc "cd /home/\$username && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg --noconfirm -si && cd .. && rm -rf yay"

echo "Stage 2 completed successfully"
EOF

  chmod +x /mnt/nemesis-stage2.sh
  echo "--- Entering chroot & running stage2 ---"
  arch-chroot /mnt /nemesis-stage2.sh
}

# ── Stage 5: Cleanup ─────────────────────────────────
cleanup() {
  echo "--- Final sync & unmount ---"
  sync
  swapoff /mnt/swapfile &>/dev/null || true
  umount -R /mnt || echo "Warning: /mnt still busy"
  echo "=== Install finished: $(date) ==="
}

# ── Main ─────────────────────────────────────────────
prepare_disk
setup_swap
install_base
configure_chroot
cleanup
