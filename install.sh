#!/usr/bin/env bash
# Temporarily disable -e for debugging
set -uo pipefail

# Redirect output to both screen and log file
exec > >(tee /tmp/install-debug.log)
exec 2>&1

echo "DEBUG: Script starting with debugging enabled"
echo "DEBUG: Output is being logged to /tmp/install-debug.log"

# Load logging functions first
source ./lib/logging.sh

# Load configuration
if [ -f "./config.sh" ]; then
    source ./config.sh
    log "Configuration loaded from config.sh"
else
    log "WARNING: config.sh not found, using defaults"
fi

# Interactive configuration if enabled
if [[ "${INTERACTIVE_MODE:-yes}" == "yes" ]]; then
    interactive_config
fi

# Validate configuration
if ! validate_config; then
    log "ERROR: Configuration validation failed"
    exit 1
fi

# --- Pre-flight checks and error recovery setup ---
source ./lib/preflight.sh

# Define setup_disk function directly (to avoid sourcing issues)
setup_disk() {
    echo "==> Setting up disk using reference implementation approach..."
    
    # Get disk using exact reference method
    disk=$(fdisk -l | grep "dev" | grep -o -P "(?=/).*(?=:)" | cut -d$'\n' -f1)
    
    if [ -z "$disk" ]; then
        echo "ERROR: No disk detected by fdisk"
        echo "Available devices from fdisk:"
        fdisk -l
        return 1
    fi
    
    echo "Using disk: $disk"
    
    # Use reference implementation partitioning approach
    echo "==> Creating GPT partition table..."
    echo "label: gpt" | sfdisk --no-reread --force $disk || {
        echo "ERROR: Failed to create GPT label"
        return 1
    }
    
    echo "==> Creating partitions..."
    sfdisk --no-reread --force $disk << EOF || {
        echo "ERROR: Failed to create partitions"
        return 1
    }
,260M,U,*
;
EOF
    
    # Wait for partitions to appear
    sleep 2
    partprobe $disk 2>/dev/null || true
    
    # Set up partition variables like the reference
    echo "==> Setting up partition variables..."
    diskpart1=${disk}1
    diskpart2=${disk}2
    
    echo "EFI partition: $diskpart1"
    echo "Root partition: $diskpart2"
    
    # Format the partitions
    echo "==> Formatting EFI partition..."
    mkfs.fat -F32 "$diskpart1" || {
        echo "ERROR: Failed to format EFI partition"
        return 1
    }
    
    echo "==> Formatting root partition..."  
    mkfs.ext4 -F "$diskpart2" || {
        echo "ERROR: Failed to format root partition"
        return 1
    }
    
    # Mount the partitions
    echo "==> Mounting partitions..."
    mount "$diskpart2" /mnt || {
        echo "ERROR: Failed to mount root partition"
        return 1
    }
    
    mkdir -p /mnt/boot || {
        echo "ERROR: Failed to create boot directory"
        return 1
    }
    
    mount "$diskpart1" /mnt/boot || {
        echo "ERROR: Failed to mount EFI partition"
        return 1
    }
    
    echo "==> Disk setup complete using reference method."
    echo "Root partition: $diskpart2 mounted at /mnt"
    echo "EFI partition: $diskpart1 mounted at /mnt/boot"
    return 0
}

echo "DEBUG: setup_disk function defined directly in install.sh"

setup_error_handling

# Check for resume capability
RESUME_STATE=$(resume_from_state)
log "Resume state: $RESUME_STATE"

# Run pre-flight checks
if ! preflight_checks; then
    log "Pre-flight checks failed, aborting installation"
    exit 1
fi

# Estimate installation time and set progress tracking
ESTIMATED_TIME=$(estimate_install_time)

# Calculate total steps for progress tracking
TOTAL_INSTALL_STEPS=5  # Base steps: disk, base, bootloader, users, cleanup
if [[ "${DESKTOP_ENV:-gnome}" != "minimal" ]]; then
    ((TOTAL_INSTALL_STEPS++))
fi
if [[ "${INSTALL_VMWARE_TOOLS:-auto}" == "yes" ]] || [[ "${INSTALL_VMWARE_TOOLS:-auto}" == "auto" && -n "$(lspci | grep -i vmware 2>/dev/null || echo '')" ]]; then
    ((TOTAL_INSTALL_STEPS++))
fi
if [[ "${INSTALL_DEV_TOOLS:-no}" == "yes" || "${OPTIMIZE_FOR_VM:-auto}" == "yes" ]]; then
    ((TOTAL_INSTALL_STEPS++))
fi

set_total_steps $TOTAL_INSTALL_STEPS

# Show installation summary
echo ""
echo "=== NEMESIS ARCH INSTALLATION ==="
echo "Target disk: $(detect_disk 2>/dev/null || echo 'Auto-detect')"
echo "Username: ${USERNAME:-main}"
echo "Hostname: ${HOSTNAME:-nemesis-host}"
echo "Desktop: ${DESKTOP_ENV:-gnome}"
echo "Estimated time: ${ESTIMATED_TIME} minutes"
echo "Progress tracking: ${ENABLE_PROGRESS:-yes}"
echo ""

if [[ "${INTERACTIVE_MODE:-yes}" == "yes" ]]; then
    read -p "Continue with installation? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        log "Installation cancelled by user"
        exit 0
    fi
fi

log "Starting Nemesis Arch installation..."

# --- Outside chroot: Partition, format, mount, pacstrap ---
if [[ "$RESUME_STATE" == "START" ]]; then
    echo "DEBUG: About to start disk setup"
    progress "Setting up disk partitions and filesystem..."
    echo "DEBUG: Calling setup_disk function"
    
    if setup_disk; then
        echo "DEBUG: setup_disk completed successfully"
        save_state "DISK_SETUP"
        echo "DEBUG: Saved DISK_SETUP state"
    else
        echo "ERROR: setup_disk failed with exit code $?"
        exit 1
    fi
    echo "DEBUG: Disk setup phase completed"
fi

if [[ "$RESUME_STATE" == "START" || "$RESUME_STATE" == "DISK_SETUP" ]]; then
    progress "Installing base system packages..."
    source ./lib/base.sh
    setup_base_system
    save_state "BASE_INSTALL"
fi

if [[ "$RESUME_STATE" == "START" || "$RESUME_STATE" == "DISK_SETUP" || "$RESUME_STATE" == "BASE_INSTALL" ]]; then
    progress "Installing kernel and bootloader packages..."
    source ./lib/bootloader.sh
    # This will call install_base_packages (outside chroot)
    save_state "PACKAGES_INSTALLED"
fi

# --- Copy chroot modules and execute them IN ORDER ---
chroot_scripts=()

# Always run bootloader config and users
if [[ "$RESUME_STATE" == "START" || "$RESUME_STATE" == "DISK_SETUP" || "$RESUME_STATE" == "BASE_INSTALL" || "$RESUME_STATE" == "PACKAGES_INSTALLED" ]]; then
    chroot_scripts+=("bootloader.sh" "users.sh")
fi

# Desktop environment (if not minimal)
if [[ "${DESKTOP_ENV:-gnome}" != "minimal" ]]; then
    if [[ "$RESUME_STATE" == "START" || "$RESUME_STATE" == "DISK_SETUP" || "$RESUME_STATE" == "BASE_INSTALL" || "$RESUME_STATE" == "BOOTLOADER" ]]; then
        chroot_scripts+=("desktop.sh")
    fi
fi

# VMware tools (if enabled)
if [[ "${INSTALL_VMWARE_TOOLS:-auto}" == "yes" ]] || [[ "${INSTALL_VMWARE_TOOLS:-auto}" == "auto" && -n "$(lspci | grep -i vmware)" ]]; then
    if [[ "$RESUME_STATE" == "START" || "$RESUME_STATE" == "DISK_SETUP" || "$RESUME_STATE" == "BASE_INSTALL" || "$RESUME_STATE" == "BOOTLOADER" || "$RESUME_STATE" == "DESKTOP" ]]; then
        chroot_scripts+=("vmware.sh")
    fi
fi

# Post-install features
if [[ "${INSTALL_DEV_TOOLS:-no}" == "yes" || "${OPTIMIZE_FOR_VM:-auto}" == "yes" ]]; then
    chroot_scripts+=("post-install.sh")
fi

for script in "${chroot_scripts[@]}"; do
    script_name="${script%.sh}"
    
    # Update progress with descriptive messages
    case "$script" in
        "bootloader.sh") progress "Configuring bootloader and system settings..." ;;
        "users.sh") progress "Creating user accounts..." ;;
        "desktop.sh") progress "Installing desktop environment..." ;;
        "vmware.sh") progress "Installing VMware guest tools..." ;;
        "post-install.sh") progress "Running post-installation setup..." ;;
        *) progress "Running $script_name..." ;;
    esac
    
    log ">>> Running $script inside chroot"
    cp "./lib/$script" "/mnt/$script"
    
    # Copy additional dependencies
    cp "./lib/logging.sh" "/mnt/logging.sh"
    if [[ "$script" == "desktop.sh" ]]; then
        cp "./lib/desktop-selector.sh" "/mnt/desktop-selector.sh"
    fi
    
    arch-chroot /mnt bash -c "
        export CHROOT_MODE=yes
        export USERNAME='${USERNAME:-main}'
        export USER_PASSWORD='${USER_PASSWORD:-}'
        export USER_GROUPS='${USER_GROUPS:-wheel,users}'
        export HOSTNAME='${HOSTNAME:-nemesis-host}'
        export TIMEZONE='${TIMEZONE:-UTC}'
        export LOCALE='${LOCALE:-en_US.UTF-8}'
        export KEYMAP='${KEYMAP:-us}'
        export DESKTOP_ENV='${DESKTOP_ENV:-gnome}'
        export INSTALL_THEMES='${INSTALL_THEMES:-yes}'
        export DOWNLOAD_WALLPAPER='${DOWNLOAD_WALLPAPER:-yes}'
        export INSTALL_DEV_TOOLS='${INSTALL_DEV_TOOLS:-no}'
        export INSTALL_MEDIA_CODECS='${INSTALL_MEDIA_CODECS:-yes}'
        export OPTIMIZE_FOR_VM='${OPTIMIZE_FOR_VM:-auto}'
        bash /$script
    "
    rm "/mnt/$script"
    
    # Clean up dependencies
    rm -f "/mnt/logging.sh" "/mnt/desktop-selector.sh"
    
    save_state "${script_name^^}"
    monitor_performance
done

progress "Installation completed successfully!" 100
save_state "COMPLETED"

# Show completion summary
TOTAL_TIME=$(($(date +%s) - START_TIME))
MINUTES=$((TOTAL_TIME / 60))
SECONDS=$((TOTAL_TIME % 60))

echo ""
echo "=== INSTALLATION COMPLETE ==="
echo "Total time: ${MINUTES}m ${SECONDS}s"
echo "Username: $USERNAME"
echo "Hostname: $HOSTNAME"
echo "Desktop: ${DESKTOP_ENV:-gnome}"
echo ""
echo "Next steps:"
echo "1. Reboot the system: reboot"
echo "2. Remove installation media"
echo "3. Log in with your user credentials"
echo ""
if [[ -f /tmp/nemesis-install.log ]]; then
    echo "Installation log: /tmp/nemesis-install.log"
fi
checkpoint "All install modules completed in correct order."
