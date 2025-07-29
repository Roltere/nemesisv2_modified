#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Error on line $LINENO"; exit 1' ERR

# ── Ensure root ───────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "This installer must be run as root." >&2
  exit 1
fi

# ── Defaults & CLI flags ───────────────────────────────
hostname="main"
username="main"
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
  -d Target disk (e.g. /dev/sda; auto-detected if omitted)
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
  swapoff -a || true
  umount -R /mnt || true

  if [[ -z "$disk" ]]; then
    disk=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/" $1; exit}')
  fi
  [[ -b "$disk" ]] || die "Block device '$disk' not found!"
  echo "Using disk: $disk"

  wipefs -af "$disk"
  if [[ -d /sys/firmware/efi/efivars ]]; then
    parted --script "$disk" mklabel gpt
    parted --script "$disk" mkpart ESP fat32 1MiB 261MiB
    parted --script "$disk" set 1 esp on
    parted --script "$disk" mkpart primary "$filesystem" 261MiB 100%
  else
    parted --script "$disk" mklabel msdos
    parted --script "$disk" mkpart primary "$filesystem" 1MiB 100%
    parted --script "$disk" set 1 boot on
  fi

  partprobe "$disk"; udevadm settle; sleep 2

  if [[ "$disk" =~ nvme ]]; then
    disk1="${disk}p1"; disk2="${disk}p2"
  else
    disk1="${disk}1"; disk2="${disk}2"
  fi

  mkdir -p /mnt /mnt/boot
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

# ── Stage 2: Base install ────────────────────────────
install_base() {
  echo "--- Preparing mirrors & repos ---"
  if ! command -v reflector >/dev/null; then
    pacman -Sy --noconfirm reflector
  fi
  reflector --protocol https --latest 20 --sort rate --save /etc/pacman.d/mirrorlist || die "reflector failed"

  pacman --noconfirm -Sy || die "Failed to sync databases"

  echo "--- Installing base packages ---"
  local pkgs=(
    base linux linux-firmware sudo base-devel go dhcpcd
    networkmanager systemd-resolvconf openssh git neovim tmux
    wget p7zip noto-fonts fish less ldns bash-completion
    man-pages man-db pacman-contrib linux-headers intel-ucode
    dosfstools exfat-utils ntfs-3g smartmontools hdparm
    nmap net-tools curl httpie rsync cmake make gcc clang
    python python-pip nodejs npm docker docker-compose
    htop atop iotop pavucontrol vlc ffmpeg gimp
    kitty terminator open-vm-tools gtkmm3
    # dstat  <--- removed
  )
  local retries=3
  for i in $(seq 1 $retries); do
    if pacstrap -K /mnt "${pkgs[@]}"; then
      break
    else
      echo "pacstrap failed attempt $i"
      sleep 10
      [[ $i -eq $retries ]] && die "pacstrap failed"
    fi
  done
}


# ── Stage 3: Write install vars for chroot ───────────
write_vars() {
  cat > /mnt/install.conf <<EOF
export HOSTNAME="$hostname"
export USERNAME="$username"
export PASSWORD="$password"
export SWAP_SIZE="$swap_size"
EOF
}

# ── Stage 4: Create chroot script ────────────────────
write_chroot_script() {
  cat > /mnt/nemesis-stage2.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Error on line $LINENO"; exit 1' ERR

[ -f /install.conf ] && source /install.conf

# Time & locale
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
systemctl enable --now systemd-timesyncd.service
echo -e "C.UTF-8 UTF-8\nen_US.UTF-8 UTF-8\nen_GB.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo LANG=en_GB.UTF-8 > /etc/locale.conf
echo -e "KEYMAP=uk\nFONT=Goha-16" > /etc/vconsole.conf

# Hostname & network
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<H
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
H
systemctl enable systemd-resolved NetworkManager sshd
systemctl start systemd-resolved NetworkManager sshd

# Swapfile (create inside the installed system)
fallocate -l "$SWAP_SIZE" /swapfile
chmod 600 /swapfile
mkswap /swapfile
echo "/swapfile none swap defaults 0 0" >> /etc/fstab

# User setup
useradd -m -G wheel,users,audio,video,storage,network -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
echo "root:$PASSWORD" | chpasswd

# Sudoers: wheel can sudo without password (optional, for convenience)
sed -i '/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/s/^# //' /etc/sudoers

# BlackArch repo (optional, remove if not needed)
curl -O https://blackarch.org/strap.sh && bash strap.sh
echo "Server = https://blackarch.org/blackarch/os/x86_64" > /etc/pacman.d/blackarch-mirrorlist

# Full upgrade
pacman --noconfirm -Syu

# Workspace
mkdir -p /opt/workspace/wordlists /opt/workspace/linux /opt/workspace/windows \
         /opt/workspace/peassng /opt/workspace/chisel /opt/workspace/c2/sliver
chgrp users /opt/workspace
chmod 2775 /opt/workspace
setfacl -Rdm g:users:rwx /opt/workspace

# SSH hardening & key (edit as needed)
cat >> /etc/ssh/sshd_config <<S
PermitRootLogin yes
PasswordAuthentication no
MaxAuthTries 10
S
systemctl restart sshd

# VMware autostart
mkdir -p /etc/xdg/autostart
cp /etc/vmware-tools/vmware-user.desktop /etc/xdg/autostart/ || true
systemctl enable vmtoolsd vmware-vmblock-fuse

# GUI + theme
pacman --noconfirm -S xorg-server xorg-apps xorg-xinit gnome gnome-extra gdm
systemctl enable gdm
pacman --noconfirm -S gtk-engine-murrine gnome-themes-extra \
  gnome-shell-extension-user-theme
git clone https://github.com/Fausto-Korpsvart/Catppuccin-GTK-Theme.git \
  /usr/share/themes/Catppuccin
sudo -u "$USERNAME" gsettings set org.gnome.desktop.interface gtk-theme 'Catppuccin' || true
sudo -u "$USERNAME" gsettings set org.gnome.shell.extensions.user-theme name 'Catppuccin' || true
sudo -u "$USERNAME" gsettings set org.gnome.desktop.default-applications.terminal exec 'terminator' || true
sudo -u "$USERNAME" gsettings set org.gnome.desktop.default-applications.terminal exec-arg '-x' || true

# AUR helper
sudo -u "$USERNAME" git clone https://aur.archlinux.org/yay.git /home/$USERNAME/yay
sudo -u "$USERNAME" bash -lc "cd /home/$USERNAME/yay && makepkg -si --noconfirm"
rm -rf /home/$USERNAME/yay

# Attacker toolset
sudo -u "$USERNAME" yay --noconfirm -Sy \
  remmina socat go proxychains-ng nmap masscan impacket metasploit \
  sqlmap john medusa ffuf seclists ldapdomaindump binwalk evil-winrm \
  responder certipy httpx dnsx nuclei subfinder strace apachedirectorystudio

# Wordlists & bins (optional)
wget -O /opt/workspace/wordlists/rockyou.bz2 \
  http://downloads.skullsecurity.org/passwords/rockyou.txt.bz2
wget -O /opt/workspace/windows/binaries.zip \
  https://github.com/interference-security/kali-windows-binaries/archive/refs/heads/master.zip
wget -O /opt/workspace/windows/ghostpack_binaries.zip \
  https://github.com/r3motecontrol/Ghostpack-CompiledBinaries/archive/refs/heads/master.zip
wget -O /opt/workspace/peassng/linpeas.sh \
  https://github.com/carlospolop/PEASS-ng/releases/download/20250401-a1b119bc/linpeas.sh
wget -O /opt/workspace/peassng/winPEAS.bat \
  https://github.com/carlospolop/PEASS-ng/releases/download/20250401-a1b119bc/winPEAS.bat
wget -O /opt/workspace/peassng/winPEASx64.exe \
  https://github.com/carlospolop/PEASS-ng/releases/download/20250401-a1b119bc/winPEASx64.exe
wget -O /opt/workspace/peassng/winPEASx86.exe \
  https://github.com/carlospolop/PEASS-ng/releases/download/20250401-a1b119bc/winPEASx86.exe
7z a /opt/workspace/peassng/peassng.7z /opt/workspace/peassng/*
rm -f /opt/workspace/peassng/linpeas.sh /opt/workspace/peassng/winPEAS*
wget -O /opt/workspace/chisel/chisel_1.9.1_linux_amd64.gz \
  https://github.com/jpillora/chisel/releases/download/v1.9.1/chisel_1.9.1_linux_amd64.gz
wget -O /opt/workspace/chisel/chisel_1.9.1_windows_amd64.gz \
  https://github.com/jpillora/chisel/releases/download/v1.9.1/chisel_1.9.1_windows_amd64.gz
wget -O /opt/workspace/chisel/chisel_1.9.1_windows_386.gz \
  https://github.com/jpillora/chisel/releases/download/v1.9.1/chisel_1.9.1_windows_386.gz
wget -O /opt/workspace/c2/sliver/sliver-server_linux \
  https://github.com/BishopFox/sliver/releases/download/v1.5.43/sliver-server_linux
wget -O /opt/workspace/c2/sliver/sliver-client_linux \
  https://github.com/BishopFox/sliver/releases/download/v1.5.43/sliver-client_linux
7z a /opt/workspace/c2/sliver/sliver.7z /opt/workspace/c2/sliver/*
rm -f /opt/workspace/c2/sliver/sliver-*
EOF

  chmod +x /mnt/nemesis-stage2.sh
}

# ── Stage 5: Chroot config & customization ───────────
configure_chroot() {
  echo "--- Copy DNS into chroot ---"
  cp /etc/resolv.conf /mnt/etc/resolv.conf

  echo "--- fstab generation ---"
  genfstab -U /mnt >> /mnt/etc/fstab

  write_vars
  write_chroot_script

  echo "--- Running stage2 in chroot ---"
  arch-chroot /mnt /nemesis-stage2.sh
}

# ── Stage 6: Cleanup ─────────────────────────────────
cleanup() {
  echo "--- Final sync & unmount ---"
  sync
  umount -R /mnt || echo "/mnt busy"
  echo "=== Install complete: $(date) ==="
}

# ── Main ─────────────────────────────────────────────
prepare_disk
install_base
configure_chroot
cleanup
