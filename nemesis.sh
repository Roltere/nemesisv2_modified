#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Error on line $LINENO"; exit 1' ERR

# ── Ensure root ───────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "This installer must be run as root." >&2
  exit 1
fi

# ── Defaults & CLI flags ───────────────────────────────
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

# ── Logging & Prep ────────────────────────────────────
exec > >(tee install.log) 2>&1
echo "=== Arch Pentest VM install started: $(date) ==="

loadkeys uk
timedatectl set-ntp true
die() { echo "$*" >&2; exit 1; }

# ── Stage 1: Disk prep ────────────────────────────────
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
  
  # Check boot mode and partition accordingly
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

  # Robust partition detection
  if [[ "$disk" =~ nvme ]]; then
    disk1="${disk}p1"
    disk2="${disk}p2"
  else
    disk1="${disk}1"
    disk2="${disk}2"
  fi

  mkdir -p /mnt /mnt/boot
  
  if [[ -d /sys/firmware/efi/efivars ]]; then
    # UEFI mode - EFI and root partitions
    [[ -b "$disk1" ]] || die "EFI partition $disk1 not found!"
    [[ -b "$disk2" ]] || die "Root partition $disk2 not found!"
    
    echo "EFI -> $disk1, root -> $disk2"
    mkfs.fat -F32 "$disk1"
    mkfs."$filesystem" -F "$disk2"
    mount "$disk2" /mnt
    mount "$disk1" /mnt/boot
  else
    # BIOS mode - single root partition
    [[ -b "$disk1" ]] || die "Root partition $disk1 not found!"
    
    echo "Root -> $disk1"
    mkfs."$filesystem" -F "$disk1"
    mount "$disk1" /mnt
  fi
}

# ── Stage 2: Base install ────────────────────────────
install_base() {
  echo "--- Setting up mirrors ---"
  
  # Update pacman databases first
  pacman --noconfirm -Sy || die "Failed to sync pacman databases"
  
  # Install reflector with better error handling
  if ! pacman --noconfirm -S --needed reflector; then
    echo "Warning: Could not install reflector, using default mirrors"
  else
    echo "Ranking mirrors (this may take a while)..."
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
  
  # Core base packages - verified to exist in Arch repos
  local base_pkgs=(
    base linux linux-firmware sudo base-devel
    networkmanager systemd-resolvconf openssh git
    neovim tmux wget p7zip noto-fonts fish less
    bash-completion man-pages man-db pacman-contrib
    linux-headers dosfstools exfatprogs ntfs-3g
    smartmontools hdparm curl rsync cmake make gcc clang
    python python-pip nodejs npm htop
  )
  
  # Detect CPU for microcode
  if lscpu | grep -q "Intel"; then
    base_pkgs+=(intel-ucode)
  elif lscpu | grep -q "AMD"; then
    base_pkgs+=(amd-ucode)
  fi

  # Retry pacstrap up to 3 times
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

# ── Stage 3: Chroot configuration ────────────────────
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
127.0.0.1	localhost
::1		localhost
127.0.1.1	\$hostname.localdomain	\$hostname
HOSTS

# Handle resolv.conf more carefully
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
chage -d 0 "\$username"  # Force password change on first login

# Enable sudo for wheel group
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

echo "--- Installing bootloader ---"
if [[ -d /sys/firmware/efi/efivars ]]; then
    echo "UEFI mode detected, installing GRUB for UEFI..."
    pacman --noconfirm -S grub efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --removable
    grub-mkconfig -o /boot/grub/grub.cfg
else
    echo "BIOS mode detected, installing GRUB for BIOS..."
    pacman --noconfirm -S grub
    echo "Installing GRUB to \$disk"
    grub-install --target=i386-pc "\$disk"
    grub-mkconfig -o /boot/grub/grub.cfg
fi

echo "--- Setting up initramfs ---"
sed -i 's/^COMPRESSION=.*/COMPRESSION="zstd"/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard keymap consolefont fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

echo "--- Installing GUI packages ---"
pacman --noconfirm -S xorg-server xorg-apps xorg-xinit gnome gdm
pacman --noconfirm -S firefox terminator kitty remmina vlc gimp
systemctl enable gdm

echo "--- Setting up VMware tools (if needed) ---"
if lspci | grep -i vmware >/dev/null 2>&1 || dmesg | grep -i vmware >/dev/null 2>&1; then
    echo "VMware environment detected, installing VMware tools..."
    if pacman --noconfirm -S open-vm-tools gtkmm3; then
        systemctl enable vmtoolsd
        
        # Enable optional services only if they exist
        for service in vmware-vmblock-fuse vgauth vmhgfs-fuse; do
            if systemctl list-unit-files "\$service.service" >/dev/null 2>&1; then
                systemctl enable "\$service.service"
                echo "Enabled \$service service"
            else
                echo "Note: \$service service not available"
            fi
        done
        
        echo "VMware tools configured successfully"
    else
        echo "Warning: Failed to install VMware tools"
    fi
else
    echo "Not running in VMware, skipping VMware tools"
fi

echo "--- Setting up BlackArch repository ---"
# Robust BlackArch setup with mirror fallbacks
setup_blackarch() {
    local blackarch_mirrors=(
        "https://ftp.halifax.rwth-aachen.de/blackarch/"
        "https://mirror.hackingand.coffee/blackarch/"
        "https://www.blackarch.org/blackarch/"
        "https://mirrors.dotsrc.org/blackarch/"
        "https://blackarch.mirror.garr.it/blackarch/"
    )
    
    echo "Setting up BlackArch repository..."
    
    # Download and verify BlackArch keyring setup
    local setup_success=false
    for mirror in "\${blackarch_mirrors[@]}"; do
        echo "Trying mirror: \$mirror"
        if curl -f -L --connect-timeout 10 --max-time 30 "\${mirror}strap.sh" -o /tmp/blackarch-strap.sh; then
            if [[ \$(wc -c < /tmp/blackarch-strap.sh) -gt 1000 ]]; then
                chmod +x /tmp/blackarch-strap.sh
                if /tmp/blackarch-strap.sh; then
                    setup_success=true
                    break
                fi
            fi
        fi
        echo "Mirror \$mirror failed, trying next..."
        sleep 2
    done
    
    if [[ "\$setup_success" != "true" ]]; then
        echo "Warning: BlackArch automatic setup failed, setting up manually..."
        
        # Manual BlackArch setup
        curl -f -L --connect-timeout 10 --max-time 30 \
            "https://www.blackarch.org/keyring/blackarch-keyring.pkg.tar.xz" \
            -o /tmp/blackarch-keyring.pkg.tar.xz || {
            echo "Warning: Could not download BlackArch keyring, skipping BlackArch setup"
            return 1
        }
        
        pacman --noconfirm -U /tmp/blackarch-keyring.pkg.tar.xz
        
        # Add BlackArch repository to pacman.conf
        if ! grep -q "\\[blackarch\\]" /etc/pacman.conf; then
            echo -e "\\n[blackarch]\\nServer = https://ftp.halifax.rwth-aachen.de/blackarch/\\\$repo/os/\\\$arch" >> /etc/pacman.conf
        fi
    fi
    
    # Create working BlackArch mirrorlist
    cat > /etc/pacman.d/blackarch-mirrorlist <<MIRRORLIST
# BlackArch Linux Mirror List
Server = https://ftp.halifax.rwth-aachen.de/blackarch/\\\$repo/os/\\\$arch
Server = https://mirror.hackingand.coffee/blackarch/\\\$repo/os/\\\$arch
Server = https://mirrors.dotsrc.org/blackarch/\\\$repo/os/\\\$arch
Server = https://blackarch.mirror.garr.it/blackarch/\\\$repo/os/\\\$arch
Server = https://www.blackarch.org/blackarch/\\\$repo/os/\\\$arch
MIRRORLIST
    
    # Update pacman databases with retries
    local sync_attempts=3
    for i in \$(seq 1 \$sync_attempts); do
        if pacman -Sy; then
            echo "BlackArch repository sync successful"
            return 0
        else
            echo "BlackArch sync attempt \$i failed, retrying..."
            sleep 5
        fi
    done
    
    echo "Warning: BlackArch repository sync failed after \$sync_attempts attempts"
    return 1
}

# Call the BlackArch setup function
setup_blackarch || echo "Continuing without BlackArch repository..."

echo "--- Installing AUR helper (yay) ---"
sudo -u "\$username" bash <<EOYAY
set -euo pipefail
cd /home/\$username

if git clone https://aur.archlinux.org/yay.git; then
    cd yay
    if makepkg -si --noconfirm; then
        cd ..
        rm -rf yay
        echo "yay installed successfully"
    else
        echo "Warning: Failed to build yay"
        cd ..
        rm -rf yay
    fi
else
    echo "Warning: Failed to clone yay repository"
fi
EOYAY

echo "--- Installing penetration testing tools ---"
# Install tools with error handling
install_tool() {
    local tool=\$1
    local package=\$2
    echo "Installing \$tool..."
    if sudo -u "\$username" yay --noconfirm --needed -S "\$package" 2>/dev/null; then
        echo "✓ \$tool installed successfully"
    else
        echo "⚠ Warning: Failed to install \$tool"
    fi
}

# Core penetration testing tools
install_tool "Nmap" "nmap"
install_tool "Masscan" "masscan"  
install_tool "SQLMap" "sqlmap"
install_tool "John the Ripper" "john"
install_tool "Hashcat" "hashcat"
install_tool "Hydra" "hydra"
install_tool "Medusa" "medusa"
install_tool "FFuF" "ffuf"
install_tool "Gobuster" "gobuster"
install_tool "Dirb" "dirb"
install_tool "Nikto" "nikto"
install_tool "Whatweb" "whatweb"
install_tool "Netcat" "gnu-netcat"
install_tool "Socat" "socat"
install_tool "Proxychains" "proxychains-ng"
install_tool "Burp Suite" "burpsuite"
install_tool "OWASP ZAP" "zaproxy"
install_tool "Metasploit" "metasploit"
install_tool "Wireshark" "wireshark-qt"
install_tool "Tcpdump" "tcpdump"
install_tool "Aircrack-ng" "aircrack-ng"
install_tool "Recon-ng" "recon-ng"
install_tool "theHarvester" "theharvester"
install_tool "Maltego" "maltego"

# Additional useful tools
install_tool "Docker" "docker"
install_tool "Docker Compose" "docker-compose"
install_tool "Binwalk" "binwalk"
install_tool "Foremost" "foremost"
install_tool "Volatility" "volatility3"
install_tool "Autopsy" "autopsy"

echo "--- Creating workspace structure ---"
mkdir -p /opt/workspace/{wordlists,scripts,tools,projects,loot}
mkdir -p /opt/workspace/tools/{windows,linux,web,mobile}
chown -R "\$username:users" /opt/workspace
chmod -R 755 /opt/workspace

echo "--- Downloading common resources ---"
# Download popular wordlists
sudo -u "\$username" bash <<WORDLISTS
cd /opt/workspace/wordlists

# SecLists
if git clone https://github.com/danielmiessler/SecLists.git; then
    echo "✓ SecLists downloaded"
else
    echo "⚠ Warning: Failed to download SecLists"
fi

# Common wordlists
wget -q --timeout=30 -O rockyou.txt.gz "https://github.com/brannondorsey/naive-hashcat/releases/download/data/rockyou.txt" || \
    echo "⚠ Warning: Failed to download rockyou.txt"

# Directory/file wordlists
wget -q --timeout=30 -O common.txt "https://raw.githubusercontent.com/digination/dirbuster-ng/master/wordlists/common.txt" || \
    echo "⚠ Warning: Failed to download common.txt"
WORDLISTS

echo "--- Enabling services ---"
systemctl enable sshd docker

echo "--- Final system configuration ---"
# Add user to docker group
usermod -aG docker "\$username"

# Set up fish shell for user
sudo -u "\$username" fish -c "set -U fish_greeting ''"

echo "Stage 2 completed successfully"
EOF

  chmod +x /mnt/pentest-stage2.sh
  echo "--- Entering chroot & running stage2 ---"
  arch-chroot /mnt /pentest-stage2.sh
  
  # Clean up the stage2 script
  rm -f /mnt/pentest-stage2.sh
}

# ── Stage 4: Cleanup ─────────────────────────────────
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

# ── Main ─────────────────────────────────────────────
echo "🚀 Starting Arch Linux Penetration Testing VM installation..."
echo "This will install a full penetration testing environment."
echo ""

prepare_disk
install_base
configure_chroot
cleanup
