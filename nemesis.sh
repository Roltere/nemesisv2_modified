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

# ── Logging ────────────────────────────────────────────
exec > >(tee install.log) 2>&1
echo "=== Starting Arch-VM install at $(date) ==="

# ── Helpers ────────────────────────────────────────────
die() { echo "$*" >&2; exit 1; }

# ── Stage 1: Prepare Disk ─────────────────────────────
prepare_disk() {
  echo "--- Preparing disk ---"
  swapoff -a
  umount -R /mnt 2>/dev/null || true

  # detect disk if not set
  if [[ -z "$disk" ]]; then
    disk="/dev/$(lsblk -dn -o NAME | head -n1)"
  fi
  echo "Using target disk: $disk"

  # GPT + partitions aligned
  parted --script "$disk" \
    mklabel gpt \
    mkpart primary fat32 1MiB 261MiB \
    set 1 boot on \
    mkpart primary "${filesystem}" 261MiB 100%

  disk1="${disk}1"
  disk2="${disk}2"

  # format
  mkfs.fat -F32 "$disk1"
  mkfs."$filesystem" -F "$disk2"

  mkdir -p /mnt
  mount "$disk2" /mnt
  mkdir -p /mnt/boot
  mount "$disk1" /mnt/boot
}

# ── Stage 2: Swapfile ──────────────────────────────────
setup_swap() {
  echo "--- Setting up ${swap_size} swapfile ---"
  fallocate -l "$swap_size" /mnt/swapfile
  chmod 600 /mnt/swapfile
  mkswap /mnt/swapfile
  swapon /mnt/swapfile
  echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab
}

# ── Stage 3: Install Base System ──────────────────────
install_base() {
  echo "--- Ranking mirrors & installing base ---"
  pacman --noconfirm -Sy --needed reflector
  reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

  pacstrap /mnt base linux-virtual linux-firmware \
    sudo base-devel yay networkmanager systemd-resolvconf \
    openssh git neovim tmux wget p7zip neofetch noto-fonts \
    ttf-noto-nerd fish less ldns open-vm-tools
}

# ── Stage 4: Configure in chroot ──────────────────────
configure_chroot() {
  echo "--- Generating fstab ---"
  genfstab -U /mnt >> /mnt/etc/fstab

  echo "--- Copying stage2 script ---"
  cat > /mnt/nemesis-stage2.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Chroot error on line \$LINENO"; exit 1' ERR

# Variables from host
hostname='"$hostname"'
username='"$username"'
password='"$password"'

# ── Locale & Time ─────────────────────────
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo en_GB.UTF-8 UTF-8 > /etc/locale.gen
locale-gen
echo LANG=en_GB.UTF-8 > /etc/locale.conf
echo KEYMAP=uk > /etc/vconsole.conf

# ── Hostname & Networking ───────────────────
echo "$hostname" > /etc/hostname
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
useradd -m -G wheel "$username"
echo -e "$password\n$password" | passwd "$username"
# force password change on first login
chage -d 0 "$username"
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# ── Bootloader ───────────────────────────────
pacman --noconfirm -Sy grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# ── VM‑specific services ──────────────────────
systemctl enable sshd
systemctl enable vmtoolsd
systemctl enable vmware-vmblock-fuse
systemctl enable vgauth.service
systemctl enable vmhgfs-fuse.service

EOF

  chmod +x /mnt/nemesis-stage2.sh
  echo "--- Entering chroot and running stage2 ---"
  arch-chroot /mnt /nemesis-stage2.sh
}

# ── Stage 5: Cleanup ────────────────────────────────
cleanup() {
  echo "--- Cleaning up ---"
  echo "Checking for busy mounts under /mnt..."
  if lsof +f -- /mnt | grep -q "^"; then
    die "Some files under /mnt are still in use. Cannot unmount safely."
  fi
  rm -f /mnt/nemesis-stage2.sh
  umount -R /mnt
  echo "=== Install finished at $(date) ==="
}

# ── Main flow ───────────────────────────────────────
prepare_disk
setup_swap
install_base
configure_chroot
cleanup
