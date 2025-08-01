#!/usr/bin/env bash
set -euo pipefail

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
source ./lib/logging.sh
source ./lib/preflight.sh

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
    progress "Setting up disk partitions and filesystem..."
    source ./lib/disk.sh
    save_state "DISK_SETUP"
fi

if [[ "$RESUME_STATE" == "START" || "$RESUME_STATE" == "DISK_SETUP" ]]; then
    progress "Installing base system packages..."
    source ./lib/base.sh
    save_state "BASE_INSTALL"
fi

# --- Copy chroot modules and execute them IN ORDER ---
chroot_scripts=()

# Always run bootloader and users
if [[ "$RESUME_STATE" == "START" || "$RESUME_STATE" == "DISK_SETUP" || "$RESUME_STATE" == "BASE_INSTALL" ]]; then
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
    
    arch-chroot /mnt bash "/$script"
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
