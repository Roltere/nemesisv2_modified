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
    log "=== DETECT_DISK FUNCTION START ==="
    log "Auto-detecting installation disk..."
    
    # If TARGET_DISK is set, use it
    if [ -n "${TARGET_DISK:-}" ]; then
        log "DEBUG: TARGET_DISK is set to: $TARGET_DISK"
        wait_for_devices
        if fdisk -l "$TARGET_DISK" >/dev/null 2>&1; then
            log "DEBUG: TARGET_DISK $TARGET_DISK is accessible"
            echo "$TARGET_DISK"
            return 0
        else
            log "WARNING: Specified TARGET_DISK=$TARGET_DISK not found or not accessible"
        fi
    else
        log "DEBUG: No TARGET_DISK environment variable set"
    fi
    
    # Wait for devices to be available
    log "DEBUG: Waiting for devices..."
    wait_for_devices
    
    # Use fdisk -l to discover disks (more reliable in early boot than lsblk)
    log "DEBUG: Scanning for available disks with fdisk..."
    local fdisk_output
    if ! fdisk_output=$(fdisk -l 2>/dev/null); then
        log "ERROR: Cannot run fdisk to enumerate disks"
        return 1
    fi
    
    log "DEBUG: Raw fdisk output (first 10 lines):"
    echo "$fdisk_output" | head -10 | while read line; do
        log "DEBUG:   $line"
    done
    
    # Extract disk device paths from fdisk output
    local available_disks
    available_disks=$(echo "$fdisk_output" | grep "^Disk /dev/" | grep -o "/dev/[^:]*" | head -10)
    
    log "DEBUG: Extracted available_disks: '$available_disks'"
    
    if [ -z "$available_disks" ]; then
        log "ERROR: No disks found by fdisk"
        log "DEBUG: Full fdisk output:"
        echo "$fdisk_output" | while read line; do
            log "DEBUG:   $line"
        done
        return 1
    fi
    
    log "Available disks found by fdisk:"
    echo "$available_disks" | while read disk; do
        local size_info=$(echo "$fdisk_output" | grep "^Disk $disk:" | sed 's/.*: //')
        log "  $disk: $size_info"
    done
    
    # Find first suitable disk
    log "DEBUG: Starting disk candidate evaluation..."
    while read -r disk; do
        [ -z "$disk" ] && continue
        
        log "DEBUG: Checking disk candidate: $disk"
        
        # Skip if mounted as system/ISO disk
        local mount_check
        mount_check=$(lsblk -n -o MOUNTPOINT "$disk" 2>/dev/null || true)
        log "DEBUG: Mount points for $disk: '$mount_check'"
        
        if echo "$mount_check" | grep -q "^/$\|^/boot$\|^/run/archiso\|^/run/miso"; then
            log "DEBUG: Skipping $disk: currently mounted as system disk or ISO"
            continue
        fi
        
        # Get size from fdisk output
        local size_line=$(echo "$fdisk_output" | grep "^Disk $disk:")
        log "DEBUG: Size line for $disk: '$size_line'"
        
        if [ -z "$size_line" ]; then
            log "DEBUG: Skipping $disk: cannot determine size"
            continue
        fi
        
        # Extract size in bytes (fdisk shows various formats, try to parse)
        local size_gb=0
        if echo "$size_line" | grep -q "GiB\|GB"; then
            size_gb=$(echo "$size_line" | grep -o '[0-9]*\.*[0-9]*[[:space:]]*GiB\|GB' | grep -o '[0-9]*\.*[0-9]*' | head -1)
            size_gb=${size_gb%.*}  # Remove decimal part
        elif echo "$size_line" | grep -q "bytes"; then
            local bytes=$(echo "$size_line" | grep -o '[0-9]*[[:space:]]*bytes' | grep -o '[0-9]*')
            size_gb=$((bytes / 1024 / 1024 / 1024))
        fi
        
        log "DEBUG: Calculated size for $disk: ${size_gb}GB"
        
        if [ "$size_gb" -lt 8 ]; then
            log "DEBUG: Skipping $disk: too small (${size_gb}GB < 8GB required)"
            continue
        fi
        
        # Final verification - can we access this disk?
        log "DEBUG: Testing fdisk access to $disk..."
        if fdisk -l "$disk" >/dev/null 2>&1; then
            log "SUCCESS: Selected suitable disk: $disk (${size_gb}GB)"
            echo "$disk"
            return 0
        else
            log "DEBUG: Skipping $disk: not accessible with fdisk"
        fi
    done <<< "$available_disks"
    
    log "DEBUG: No suitable disk found in candidate evaluation"
    
    log "No suitable disk found automatically. Available block devices:"
    lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null || true
    log ""
    log "IMPORTANT: The installer needs a physical disk separate from the ISO."
    log "Common issues:"
    log "  - No additional disk attached (VM needs a second disk)"
    log "  - All disks are too small (minimum 8GB required)"
    log "  - Target disk is currently mounted"
    log ""
    log "To specify a disk manually, set TARGET_DISK environment variable:"
    log "  export TARGET_DISK=/dev/sdX"
    log "  $0"
    log ""
    log "ERROR: Please set TARGET_DISK environment variable to specify disk"
    return 1
}

setup_disk() {
    log "=== DISK SETUP PHASE START ==="
    log "Detecting target disk..."
    
    # First, show what's available for debugging
    log "DEBUG: Current environment check:"
    log "DEBUG: Available disk info from fdisk:"
    fdisk -l 2>/dev/null | grep "^Disk /dev/" | head -10 | while read line; do
        log "DEBUG:   $line"
    done
    
    log "DEBUG: Available disk info from lsblk:"
    lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null | while read line; do
        log "DEBUG:   $line"
    done
    
    # Now try detection
    log "DEBUG: Calling detect_disk function..."
    DISK=$(detect_disk)
    local detect_result=$?
    
    log "DEBUG: detect_disk returned: '$DISK' with exit code: $detect_result"
    
    if [ $detect_result -ne 0 ] || [ -z "$DISK" ]; then
        log "FATAL: Disk detection failed."
        log "detect_disk exit code: $detect_result"
        log "detect_disk output: '$DISK'"
        log "Available disks from fdisk:"
        fdisk -l 2>/dev/null | grep "^Disk /dev/" | head -5
        log "Available disks from lsblk:"
        lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null || true
        log "Please set TARGET_DISK environment variable or ensure a suitable disk is available"
        return 1
    fi
    
    log "SUCCESS: Using detected disk: $DISK"
    
    # Verify the detected disk is accessible using fdisk
    log "Verifying disk $DISK accessibility with fdisk..."
    
    local fdisk_test_output
    fdisk_test_output=$(fdisk -l "$DISK" 2>&1)
    local fdisk_result=$?
    
    log "DEBUG: fdisk -l '$DISK' exit code: $fdisk_result"
    if [ $fdisk_result -ne 0 ]; then
        log "ERROR: Cannot access disk $DISK with fdisk"
        log "fdisk error output: $fdisk_test_output"
        log "Available disks:"
        fdisk -l 2>/dev/null | grep "^Disk /dev/" | head -5
        return 1
    fi
    
    log "SUCCESS: Verified disk $DISK is accessible"
    
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