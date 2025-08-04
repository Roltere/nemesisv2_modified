#!/usr/bin/env bash

wait_for_devices() {
    log "Waiting for device enumeration to complete..."
    # Wait for udev to settle
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle --timeout=10 2>/dev/null || true
    fi
    sleep 2  # Additional wait for device appearance
}

detect_disk() {
    log "Auto-detecting installation disk using reference method..."
    
    # If TARGET_DISK is set, use it
    if [ -n "${TARGET_DISK:-}" ]; then
        log "Using specified TARGET_DISK: $TARGET_DISK"
        echo "$TARGET_DISK"
        return 0
    fi
    
    # Wait for devices
    wait_for_devices
    
    # Use the exact method from working reference implementation
    log "Using fdisk to find first available disk..."
    local disk
    disk=$(fdisk -l 2>/dev/null | grep "dev" | grep -o -P "(?=/).*(?=:)" | cut -d$'\n' -f1 | head -1)
    
    log "Found disk candidate: '$disk'"
    
    if [ -z "$disk" ]; then
        log "ERROR: No disk found by fdisk"
        log "Available devices:"
        fdisk -l 2>/dev/null | grep "^Disk /dev/" || true
        return 1
    fi
    
    # Basic validation - skip if it's the boot/system disk
    if lsblk -n -o MOUNTPOINT "$disk" 2>/dev/null | grep -q "^/$\|^/boot$\|^/run/archiso\|^/run/miso"; then
        log "ERROR: Found disk $disk is currently the boot/system disk"
        log "Please ensure you have a separate disk for installation"
        return 1
    fi
    
    log "Selected disk: $disk"
    echo "$disk"
    return 0
}

setup_disk() {
    log "Setting up disk partitions..."
    
    # Detect target disk
    if ! DISK=$(detect_disk); then
        log "FATAL: Disk detection failed"
        return 1
    fi
    
    log "Using disk: $DISK"
    
    # Verify accessibility
    if ! fdisk -l "$DISK" >/dev/null 2>&1; then
        log "ERROR: Cannot access disk $DISK"
        return 1
    fi
    
    # Show disk information before partitioning
    log "Disk information before partitioning:"
    lsblk "$DISK" || true
    fdisk -l "$DISK" 2>/dev/null || true
    
    log "Available space check:"
    df -h / /tmp 2>/dev/null || true
    
    log "Unmounting previous mounts if any..."
    umount -R /mnt || true
    
    echo "DEBUG: About to start partitioning $DISK"
    log "Partitioning $DISK (GPT, EFI+root)..."
    
    if ! parted -s "$DISK" mklabel gpt; then
        log "ERROR: Failed to create GPT label on $DISK"
        return 1
    fi
    echo "DEBUG: GPT label created successfully"
    
    if ! parted -s "$DISK" mkpart ESP fat32 1MiB 301MiB; then
        log "ERROR: Failed to create EFI partition"
        return 1
    fi
    echo "DEBUG: EFI partition created"
    
    if ! parted -s "$DISK" set 1 esp on; then
        log "ERROR: Failed to set ESP flag"
        return 1
    fi
    echo "DEBUG: ESP flag set"
    
    if ! parted -s "$DISK" mkpart primary ext4 301MiB 100%; then
        log "ERROR: Failed to create root partition"
        return 1
    fi
    echo "DEBUG: Root partition created"
    
    log "Formatting partitions..."
    if ! mkfs.fat -F32 "${DISK}1"; then
        log "ERROR: Failed to format EFI partition"
        return 1
    fi
    echo "DEBUG: EFI partition formatted"
    
    if ! mkfs.ext4 -F "${DISK}2"; then
        log "ERROR: Failed to format root partition"
        return 1
    fi
    echo "DEBUG: Root partition formatted"
    log "Mounting partitions..."
    
    if ! mount "${DISK}2" /mnt; then
        log "ERROR: Failed to mount root partition"
        return 1
    fi
    echo "DEBUG: Root partition mounted"
    
    if ! mkdir -p /mnt/boot; then
        log "ERROR: Failed to create /mnt/boot directory"
        return 1
    fi
    echo "DEBUG: /mnt/boot directory created"
    
    if ! mount "${DISK}1" /mnt/boot; then
        log "ERROR: Failed to mount EFI partition"
        return 1
    fi
    echo "DEBUG: EFI partition mounted"
    
    # Show mounted filesystem information
    log "Mounted filesystem information:"
    df -h /mnt /mnt/boot 2>/dev/null || true
    lsblk "$DISK" || true
    
    checkpoint "Disk partitioning and mount complete"
}