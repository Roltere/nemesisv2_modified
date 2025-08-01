#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Error on line $LINENO"; exit 1' ERR

# ── Ensure root ─────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "This installer must be run as root." >&2
  exit 1
fi

# ── Defaults & CLI flags ────────────────────
hostname="pentest-vm"
username="pentester"
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

exec > >(tee install.log) 2>&1
echo "=== Arch Pentest VM install started: $(date) ==="

loadkeys uk
timedatectl set-ntp true
die() { echo "$*" >&2; exit 1; }

# ── Stage 1: Disk prep ──────────────────────
prepare_disk() {
  echo "--- Preparing disk ---"
  swapoff -a 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true

  if [[ -z "$disk" ]]; then
    disk=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print "/dev/" $1; exit}')
  fi
  [[ -b "$disk" ]] || die "Block device '$disk' not found!"
  echo "Using disk: $disk"

  wipefs -af "$disk"
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

  if [[ "$disk" =~ nvme ]]; then
    disk1="${disk}p1"; disk2="${disk}p2"
  else
    disk1="${disk}1"; disk2="${disk}2"
  fi

  mkdir -p /mnt /mnt/boot
  if [[ -d /sys/firmware/efi/efivars ]]; then
    [[ -b "$disk1" ]] || die "EFI partition $disk1 not found!"
    [[ -b "$disk2" ]] || die "Root partition $disk2 not found!"
    mkfs.fat -F32 "$disk1"
    mkfs."$filesystem" -F "$disk2"
    mount "$disk2" /mnt
    mount "$disk1" /mnt/boot
  else
    [[ -b "$disk1" ]] || die "Root partition $disk1 not found!"
    mkfs."$filesystem" -F "$disk1"
    mount "$disk1" /mnt
  fi
}

# ── Stage 2: Base install ───────────────────
install_base() {
  echo "--- Setting up mirrors ---"
  pacman --noconfirm -Sy || die "Failed to sync pacman databases"
  if ! pacman --noconfirm -S --needed reflector; then
    echo "Warning: Could not install reflector, using default mirrors"
  else
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
  local base_pkgs=(
    base linux linux-firmware sudo base-devel
    networkmanager systemd-resolvconf openssh git
    neovim tmux wget p7zip noto-fonts fish less
    bash-completion man-pages man-db pacman-contrib
    linux-headers dosfstools exfatprogs ntfs-3g
    smartmontools hdparm curl rsync cmake make gcc clang
    python python-pip nodejs npm htop
  )
  if lscpu | grep -q "Intel"; then
    base_pkgs+=(intel-ucode)
  elif lscpu | grep -q "AMD"; then
    base_pkgs+=(amd-ucode)
  fi

  local retries=3
  for i in $(seq 1 $retries); do
    if pacstrap /mnt "${base_pkgs[@]}"; then
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

# ── Stage 3: Chroot configuration ───────────
configure_chroot() {
  echo "--- Generating fstab ---"
  genfstab -U /mnt >> /mnt/etc/fstab

  echo "--- Writing chroot script ---"
  cat > /mnt/pentest-stage2.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Chroot error on line \$LINENO"; exit 1' ERR

hostname="$hostname"
username="$username"
password="$password"
swap_size="$swap_size"
disk="$disk"

echo "--- Setting up time and locale ---"
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
systemctl enable systemd-timesyncd.service

echo -e "en_GB.UTF-8 UTF-8\nen_US.UTF-8 UTF-8\nC.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo LANG=en_GB.UTF-8 > /etc/locale.conf
echo -e "KEYMAP=uk\nFONT=ter-116n" > /etc/vconsole.conf

echo "--- Setting up hostname and network ---"
echo "\$hostname" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1     localhost
127.0.1.1   \$hostname.localdomain  \$hostname
HOSTS

# Handle resolv.conf
if [[ -L /etc/resolv.conf ]]; then
    rm -f /etc/resolv.conf
elif [[ -f /etc/resolv.conf ]]; then
    rm -f /etc/resolv.conf || {
        echo "Warning: Could not remove /etc/resolv.conf (busy), trying to overwrite..."
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || {
            echo "Warning: Could not create resolv.conf symlink, using existing file"
        }
    }
fi

if [[ ! -e /etc/resolv.conf ]]; then
    ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi

systemctl enable systemd-resolved NetworkManager

echo "--- Creating swapfile ---"
fallocate -l "\$swap_size" /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile none swap defaults 0 0" >> /etc/fstab

echo "--- Setting up users ---"
useradd -m -G wheel,users,audio,video,storage,network -s /usr/bin/fish "\$username"
echo "\$username:\$password" | chpasswd
echo "root:\$password" | chpasswd
chage -d 0 "\$username"

echo "%wheel ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

echo "--- Installing bootloader ---"
if [[ -d /sys/firmware/efi/efivars ]]; then
    pacman --noconfirm -S grub efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --removable
    grub-mkconfig -o /boot/grub/grub.cfg
else
    pacman --noconfirm -S grub
    grub-install --target=i386-pc "\$disk"
    grub-mkconfig -o /boot/grub/grub.cfg
fi

sed -i 's/^COMPRESSION=.*/COMPRESSION="zstd"/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard keymap consolefont fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

echo "--- Installing GUI packages ---"
pacman --noconfirm -S xorg-server xorg-apps xorg-xinit gnome gdm
pacman --noconfirm -S firefox terminator kitty remmina vlc gimp
systemctl enable gdm

echo "--- Setting up VMware tools (if needed) ---"
if lspci | grep -i vmware >/dev/null 2>&1 || dmesg | grep -i vmware >/dev/null 2>&1; then
    pacman --noconfirm -S open-vm-tools gtkmm3
    systemctl enable vmtoolsd
    for service in vmware-vmblock-fuse vgauth vmhgfs-fuse; do
        if systemctl list-unit-files "\$service.service" >/dev/null 2>&1; then
            systemctl enable "\$service.service"
        fi
    done
fi

echo "--- Setting up BlackArch repository ---"
# ---- BlackArch setup (robust version) ----
pacman --noconfirm -S haveged || true
systemctl enable haveged || true
systemctl start haveged || true
timedatectl set-ntp true
pacman-key --init
pacman-key --populate archlinux
if ping -c 1 blackarch.org; then
    if bash <(curl -s https://blackarch.org/strap.sh) -- --noconfirm; then
        echo "BlackArch setup successful via official installer"
        blackarch_available=true
    else
        curl -s https://blackarch.org/mirrorlist/blackarch-mirrorlist.txt | grep '^Server' > /etc/pacman.d/blackarch-mirrorlist
        if ! grep -q '\\[blackarch\\]' /etc/pacman.conf; then
            echo -e "\n[blackarch]\nInclude = /etc/pacman.d/blackarch-mirrorlist" >> /etc/pacman.conf
        fi
        for i in {1..5}; do
            pacman -Sy --noconfirm blackarch-keyring && break
            sleep 2
        done
        pacman-key --populate blackarch
        blackarch_available=true
    fi
    pacman-key --refresh-keys || true
    pacman -Syyu --noconfirm || true
else
    blackarch_available=false
fi

echo "--- Installing AUR helper (yay) ---"
sudo -u "\$username" bash <<EOYAY
set -euo pipefail
cd /home/\$username
if git clone https://aur.archlinux.org/yay.git; then
    cd yay
    if makepkg -si --noconfirm; then
        cd ..
        rm -rf yay
    else
        cd ..
        rm -rf yay
    fi
fi
EOYAY

echo "--- Installing penetration testing tools ---"
# Official repo tools
official_tools=(
    nmap masscan nikto
    wireshark-qt tcpdump
    aircrack-ng
    binwalk foremost
    docker docker-compose
    gnu-netcat socat
    hashcat john
    python-impacket
    burpsuite
)
for tool in "\${official_tools[@]}"; do
    if pacman --noconfirm -S "\$tool" 2>/dev/null; then
        echo "✓ \$tool installed from official repo"
    else
        echo "⚠ Warning: Failed to install \$tool from official repo"
    fi
done

if systemctl list-unit-files | grep -q docker.service; then
    systemctl enable docker
fi

# AUR tools
if command -v yay >/dev/null 2>&1; then
    aur_tools=(
        gobuster
        ffuf
        sqlmap
        hydra
        medusa
        metasploit
        dirb
        whatweb
        proxychains-ng
        recon-ng
        theharvester
    )
    for tool in "\${aur_tools[@]}"; do
        tool_success=false
        for attempt in {1..3}; do
            if sudo -u "\$username" yay --noconfirm --needed -S "\$tool" 2>/dev/null; then
                echo "✓ \$tool installed from AUR"
                tool_success=true
                break
            else
                echo "Attempt \$attempt to install \$tool from AUR failed, retrying in 5s..."
                sleep 5
            fi
        done
        if [ "\$tool_success" = false ]; then
            echo "⚠ Warning: Failed to install \$tool from AUR after 3 attempts"
        fi
    done
fi

# BlackArch tools
if [[ "\$blackarch_available" == "true" ]]; then
    blackarch_tools=(
        evil-winrm
        responder
        bloodhound
        crackmapexec
        enum4linux
        smbclient
        ldapdomaindump
    )
    for tool in "\${blackarch_tools[@]}"; do
        tool_success=false
        for attempt in {1..3}; do
            if pacman --noconfirm -S "\$tool" 2>/dev/null; then
                echo "✓ \$tool installed from BlackArch"
                tool_success=true
                break
            else
                echo "Attempt \$attempt to install \$tool from BlackArch failed, retrying in 5s..."
                sleep 5
            fi
        done
        if [ "\$tool_success" = false ]; then
            echo "⚠ Warning: Failed to install \$tool from BlackArch after 3 attempts"
        fi
    done
fi

echo "--- Creating workspace structure ---"
mkdir -p /opt/workspace/{wordlists,scripts,tools,projects,loot}
mkdir -p /opt/workspace/tools/{windows,linux,web,mobile}
chown -R "\$username:users" /opt/workspace
chmod -R 755 /opt/workspace

echo "--- Downloading common resources ---"
sudo -u "\$username" bash <<'RESOURCES'
cd /opt/workspace
mkdir -p wordlists tools/{windows,linux} scripts

echo "Downloading SecLists..."
if git clone --depth 1 https://github.com/danielmiessler/SecLists.git wordlists/SecLists; then
    echo "✓ SecLists downloaded successfully"
fi

if wget -q --timeout=30 -O wordlists/rockyou.txt.bz2 "https://download.weakpass.com/wordlists/90/rockyou.txt.bz2"; then
    bunzip2 wordlists/rockyou.txt.bz2 2>/dev/null || echo "⚠ Warning: Failed to extract rockyou.txt.bz2"
elif wget -q --timeout=30 -O wordlists/rockyou.txt "https://github.com/brannondorsey/naive-hashcat/releases/download/data/rockyou.txt"; then
    echo "✓ Downloaded rockyou.txt (plain text, no extraction needed)"
else
    echo "⚠ Warning: Failed to download rockyou.txt from all sources"
fi

wget -q --timeout=30 -O tools/linux/linpeas.sh \
    "https://github.com/carlospolop/PEASS-ng/releases/latest/download/linpeas.sh" || true
wget -q --timeout=30 -O tools/windows/winPEAS.bat \
    "https://github.com/carlospolop/PEASS-ng/releases/latest/download/winPEAS.bat" || true

chmod +x tools/linux/*.sh 2>/dev/null || true

RESOURCES

echo "--- Enabling services ---"
systemctl enable sshd

usermod -aG docker "\$username"
sudo -u "\$username" fish -c "set -U fish_greeting ''"
echo "Stage 2 completed successfully"
EOF

  chmod +x /mnt/pentest-stage2.sh
  echo "--- Entering chroot & running stage2 ---"
  arch-chroot /mnt /pentest-stage2.sh
  rm -f /mnt/pentest-stage2.sh
}

# ── Stage 4: Cleanup ────────────────────────
cleanup() {
  echo "--- Final sync & unmount ---"
  sync
  swapoff /mnt/swapfile 2>/dev/null || true
  umount -R /mnt || echo "Warning: /mnt still busy"
  echo "=== Install finished: $(date) ==="
  echo ""
  echo "🎉 Penetration Testing VM Installation Complete!"
  echo ""
  echo "Next steps:"
  echo "1. Remove the installation media"
  echo "2. Reboot the system"
  echo "3. Login with username: $username"
  echo "4. Change the default password on first login"
  echo "5. Run 'sudo pacman -Syu' to update the system"
  echo ""
  echo "Installed features:"
  echo "• GNOME desktop environment"
  echo "• BlackArch penetration testing repository"
  echo "• Common penetration testing tools"
  echo "• Workspace structure in /opt/workspace"
  echo "• VMware tools (if running in VMware)"
}

echo "🚀 Starting Arch Linux Penetration Testing VM installation..."
echo ""
prepare_disk
install_base
configure_chroot
cleanup
