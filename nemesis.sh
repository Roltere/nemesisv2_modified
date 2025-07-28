#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Error on line $LINENO"; exit 1' ERR

# ── Defaults ───────────────────────────────────────────
hostname="arch-vm"
username="user"
password="Ch4ngeM3!"
swap_size="4G"       # swapfile size
filesystem="ext4"    # root FS
disk=""              # auto-detect if empty

# ── Usage ──────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 [-n hostname] [-u username] [-P password] [-S swap_size] [-f fs] [-d disk]
  -n  Hostname (default: $hostname)
  -u  Username (default: $username)
  -P  User password (default: $password)
  -S  Swapfile size, e.g. 4G (default: $swap_size)
  -f  Root filesystem type (ext4, btrfs, etc.; default: $filesystem)
  -d  Target disk (e.g. /dev/sda; auto-detected if omitted)
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
    h|*) usage ;;
  esac
done

# ── Logging & Environment Prep ────────────────────────
exec > >(tee install.log) 2>&1
echo "=== Starting Arch-VM install at $(date) ==="

# load UK keymap and sync time—crucial before any downloads
loadkeys uk
timedatectl set-ntp true

# ── Helpers ────────────────────────────────────────────
die() { echo "$*" >&2; exit 1; }

# ── Stage 1: Prepare Disk ─────────────────────────────
prepare_disk() {
  echo "--- Preparing disk ---"
  swapoff -a
  umount -R /mnt 2>/dev/null || true

  # detect only real disks
  if [[ -z "$disk" ]]; then
    disk=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{ print "/dev/" $1; exit }')
  fi
  [[ -b "$disk" ]] || die "Target disk '$disk' not found or not a block device!"
  echo "Using target disk: $disk"

  # Create GPT and two aligned partitions
  parted --script "$disk" mklabel gpt
  parted --script "$disk" mkpart primary fat32 1MiB 261MiB
  parted --script "$disk" set 1 boot on
  parted --script "$disk" mkpart primary "$filesystem" 261MiB 100%

  disk1="${disk}1"
  disk2="${disk}2"

  echo "--- Formatting partitions ---"
  mkfs.fat -F32 "$disk1"
  mkfs."$filesystem" -F "$disk2"

  echo "--- Mounting root & EFI ---"
  mkdir -p /mnt /mnt/boot
  mount "$disk2" /mnt
  mount "$disk1" /mnt/boot
}

# ── Stage 2: Swapfile ──────────────────────────────────
setup_swap() {
  echo "--- Creating ${swap_size} swapfile ---"
  fallocate -l "$swap_size" /mnt/swapfile
  chmod 600 /mnt/swapfile
  mkswap /mnt/swapfile
  swapon /mnt/swapfile
}

# ── Stage 3: Install Base System ──────────────────────
install_base() {
  echo "--- Ranking mirrors & installing base ---"
  pacman --noconfirm -Sy --needed reflector
  reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

  pacstrap /mnt \
    base linux-virtual linux-firmware \
    sudo base-devel yay networkmanager systemd-resolvconf \
    openssh git neovim tmux wget p7zip neofetch noto-fonts \
    ttf-noto-nerd fish less ldns open-vm-tools
}

# ── Stage 4: Configure in chroot ──────────────────────
configure_chroot() {
  echo "--- Generating fstab ---"
  genfstab -U /mnt >> /mnt/etc/fstab
  # now that /mnt/etc exists, add swap entry
  echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

  echo "--- Writing stage2 script into chroot ---"
  cat > /mnt/nemesis-stage2.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Chroot error on line \$LINENO"; exit 1' ERR

# Variables from host
hostname="$hostname"
username="$username"
password="$password"

# ── Locale & Time ─────────────────────────
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_GB.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo LANG=en_GB.UTF-8 > /etc/locale.conf
echo KEYMAP=uk > /etc/vconsole.conf

# ── Hostname & Networking ───────────────────
echo "\$hostname" > /etc/hostname
rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl enable systemd-resolved
systemctl enable NetworkManager

# ── Pacman & BlackArch ───────────────────────
sed -i '/#\\[multilib\\]/,/Include/ s/^#//' /etc/pacman.conf
curl https://blackarch.org/strap.sh | sh
echo "Server = https://blackarch.org/blackarch/os/x86_64" > /etc/pacman.d/blackarch-mirrorlist
pacman --noconfirm -Syu

# ── Initramfs (zstd + minimal hooks) ──────────
sed -i 's/^COMPRESSION=.*/COMPRESSION="zstd"/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard keymap consolefont fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# ── Users & SSH ──────────────────────────────
useradd -m -G wheel "\$username"
echo -e "\$password\n\$password" | passwd "\$username"
chage -d 0 "\$username"       # force password change on first login
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# ── Bootloader ───────────────────────────────
pacman --noconfirm -Sy grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig
