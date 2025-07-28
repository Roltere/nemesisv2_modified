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
  swapoff -a
  umount -R /mnt 2>/dev/null || true

  # detect only TYPE=="disk"
  if [[ -z "$disk" ]]; then
    disk=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/"$1; exit}')
  fi
  [[ -b "$disk" ]] || die "Block device '$disk' not found!"

  echo "Using disk: $disk"

  parted --script "$disk" mklabel gpt
  parted --script "$disk" mkpart primary fat32 1MiB 261MiB
  parted --script "$disk" set 1 boot on
  parted --script "$disk" mkpart primary "$filesystem" 261MiB 100%

  partprobe "$disk"
  udevadm settle

  # NVMe-safe: list the partitions created
  mapfile -t parts < <(lsblk -nr -o NAME,TYPE "$disk" | awk '$2=="part"{print "/dev/"$1}')
  disk1="${parts[0]}" || die "Partition 1 not found!"
  disk2="${parts[1]}" || die "Partition 2 not found!"

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
  echo "--- Ranking mirrors & installing base sys ---"
  pacman --noconfirm -Sy --needed reflector
  reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

  pacstrap /mnt \
    base linux-virtual linux-firmware \
    sudo base-devel yay networkmanager \
    systemd-resolvconf openssh git neovim tmux \
    wget p7zip neofetch noto-fonts ttf-noto-nerd \
    fish less ldns open-vm-tools
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

# Time & locale
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_GB.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo LANG=en_GB.UTF-8 > /etc/locale.conf
echo KEYMAP=uk > /etc/vconsole.conf

# Hostname & network
echo "\$hostname" > /etc/hostname
rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable systemd-resolved NetworkManager

# Mirrors & pacman
sed -i '/#\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
curl https://blackarch.org/strap.sh | sh
echo "Server = https://blackarch.org/blackarch/os/x86_64" > /etc/pacman.d/blackarch-mirrorlist
pacman --noconfirm -Syu

# Initramfs (zstd + minimal hooks)
sed -i 's/^COMPRESSION=.*/COMPRESSION="zstd"/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard keymap consolefont fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Users & sudo
useradd -m -G wheel "\$username"
echo -e "\$password\n\$password" | passwd "\$username"
chage -d 0 "\$username"
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Bootloader
pacman --noconfirm -Sy grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# VM tools & shared folders
systemctl enable sshd vmtoolsd vmware-vmblock-fuse vgauth.service vmhgfs-fuse.service
EOF

  chmod +x /mnt/nemesis-stage2.sh
  echo "--- Entering chroot & running stage2 ---"
  arch-chroot /mnt /nemesis-stage2.sh
}

# ── Stage 5: Cleanup ─────────────────────────────────
cleanup() {
  echo "--- Final sync & unmount ---"
  sync
  umount -R /mnt || echo "Warning: /mnt still busy"
  rm -f /mnt/nemesis-stage2.sh
  echo "=== Install finished: $(date) ==="
}

# ── Main ─────────────────────────────────────────────
prepare_disk
setup_swap
install_base
configure_chroot
cleanup
