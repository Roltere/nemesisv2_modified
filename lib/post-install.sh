#!/usr/bin/env bash
set -euo pipefail
source ./logging.sh

# Post-installation features and optimizations

install_development_tools() {
    if [[ "${INSTALL_DEV_TOOLS:-no}" != "yes" ]]; then
        return 0
    fi
    
    log "Installing development tools..."
    
    local dev_packages=(
        "git" "docker" "docker-compose"
        "nodejs" "npm" "python" "python-pip"
        "code" "vim" "neovim"
        "tmux" "htop" "tree" "jq"
    )
    
    # Install from official repos
    pacman_install git docker docker-compose nodejs npm python python-pip vim neovim tmux htop tree jq
    
    # Enable Docker service
    systemctl enable docker
    usermod -aG docker "$USERNAME"
    
    # Install VS Code from AUR (if available)
    if command -v yay &>/dev/null || command -v paru &>/dev/null; then
        log "Installing Visual Studio Code from AUR..."
        sudo -u "$USERNAME" yay -S --noconfirm visual-studio-code-bin 2>/dev/null || \
        sudo -u "$USERNAME" paru -S --noconfirm visual-studio-code-bin 2>/dev/null || \
        log "WARNING: Could not install VS Code from AUR"
    fi
    
    checkpoint "Development tools installation complete"
}

install_media_codecs() {
    if [[ "${INSTALL_MEDIA_CODECS:-yes}" != "yes" ]]; then
        return 0
    fi
    
    log "Installing media codecs and multimedia support..."
    
    # Enable multilib if requested
    if [[ "${ENABLE_MULTILIB:-yes}" == "yes" ]]; then
        log "Enabling multilib repository..."
        if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
            echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
            pacman -Sy
        fi
    fi
    
    local media_packages=(
        "ffmpeg" "gst-plugins-good" "gst-plugins-bad" "gst-plugins-ugly"
        "libdvdcss" "x264" "x265" "libde265"
        "vlc" "mpv"
    )
    
    pacman_install "${media_packages[@]}"
    
    checkpoint "Media codecs installation complete"
}

optimize_for_virtualization() {
    local should_optimize="${OPTIMIZE_FOR_VM:-auto}"
    
    if [[ "$should_optimize" == "auto" ]]; then
        # Auto-detect virtualization
        if systemd-detect-virt &>/dev/null; then
            local virt_type=$(systemd-detect-virt)
            log "Detected virtualization: $virt_type"
            should_optimize="yes"
        else
            should_optimize="no"
        fi
    fi
    
    if [[ "$should_optimize" != "yes" ]]; then
        return 0
    fi
    
    log "Applying VM optimizations..."
    
    # Reduce swappiness for VMs
    echo "vm.swappiness=10" > /etc/sysctl.d/99-vm-optimization.conf
    
    # Use deadline I/O scheduler for VMs
    echo 'ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]|nvme*", ATTR{queue/scheduler}="mq-deadline"' > /etc/udev/rules.d/60-ioschedulers.rules
    
    # Disable some unnecessary services for VMs
    local vm_disable_services=(
        "bluetooth.service"
        "ModemManager.service"
    )
    
    for service in "${vm_disable_services[@]}"; do
        if systemctl is-enabled "$service" &>/dev/null; then
            systemctl disable "$service"
            log "Disabled $service (not needed in VM)"
        fi
    done
    
    # Install VM guest utilities based on detected hypervisor
    local virt_type=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    case "$virt_type" in
        "vmware")
            pacman_install open-vm-tools xf86-video-vmware xf86-input-vmmouse
            systemctl enable vmtoolsd vmware-vmblock-fuse
            ;;
        "kvm"|"qemu")
            pacman_install qemu-guest-agent spice-vdagent
            systemctl enable qemu-guest-agent
            ;;
        "oracle")
            pacman_install virtualbox-guest-utils
            systemctl enable vboxservice
            ;;
        "microsoft")
            pacman_install hyperv
            systemctl enable hv_fcopy_daemon hv_kvp_daemon hv_vss_daemon
            ;;
    esac
    
    checkpoint "VM optimizations applied"
}

create_user_directories() {
    log "Creating user directories and setting up environment..."
    
    # Create standard user directories
    sudo -u "$USERNAME" mkdir -p /home/"$USERNAME"/{Desktop,Documents,Downloads,Music,Pictures,Videos,Public,Templates}
    
    # Create development directories if dev tools are installed
    if [[ "${INSTALL_DEV_TOOLS:-no}" == "yes" ]]; then
        sudo -u "$USERNAME" mkdir -p /home/"$USERNAME"/{Projects,Scripts,.local/bin}
        
        # Add ~/.local/bin to PATH
        if ! grep -q '~/.local/bin' /home/"$USERNAME"/.bashrc; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/"$USERNAME"/.bashrc
        fi
    fi
    
    # Set up basic shell configuration
    cat > /home/"$USERNAME"/.bashrc << 'EOF'
# ~/.bashrc

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# Aliases
alias ls='ls --color=auto'
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'

# History configuration
HISTCONTROL=ignoreboth
HISTSIZE=1000
HISTFILESIZE=2000

# Check window size after each command
shopt -s checkwinsize

# Enable programmable completion features
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# Custom prompt
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# Add ~/.local/bin to PATH if it exists
if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:$PATH"
fi
EOF
    
    chown "$USERNAME:$USERNAME" /home/"$USERNAME"/.bashrc
    
    checkpoint "User environment setup complete"
}

setup_automatic_updates() {
    if [[ "${ENABLE_AUTO_UPDATES:-no}" == "yes" ]]; then
        log "Setting up automatic security updates..."
        
        # Install and enable systemd timer for updates
        pacman_install pacman-contrib
        
        # Create update script
        cat > /usr/local/bin/auto-update.sh << 'EOF'
#!/bin/bash
# Automatic system update script
exec > /var/log/auto-update.log 2>&1
echo "$(date): Starting automatic update"
pacman -Syu --noconfirm
echo "$(date): Update completed"
EOF
        chmod +x /usr/local/bin/auto-update.sh
        
        # Create systemd service
        cat > /etc/systemd/system/auto-update.service << 'EOF'
[Unit]
Description=Automatic system update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/auto-update.sh
EOF
        
        # Create systemd timer (weekly updates)
        cat > /etc/systemd/system/auto-update.timer << 'EOF'
[Unit]
Description=Run automatic updates weekly
Requires=auto-update.service

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF
        
        systemctl enable auto-update.timer
        log "Automatic updates scheduled weekly"
    fi
}

# Main post-install function
log "Running post-installation setup..."

install_development_tools
install_media_codecs
optimize_for_virtualization
create_user_directories
setup_automatic_updates

checkpoint "Post-installation setup complete"