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
    log "Auto-detecting installation disk..."
    
    # If TARGET_DISK is set, use it
    if [ -n "${TARGET_DISK:-}" ]; then
        wait_for_devices
        if [ -e "$TARGET_DISK" ] && ([ -b "$TARGET_DISK" ] || lsblk "$TARGET_DISK" >/dev/null 2>&1); then
            echo "$TARGET_DISK"
            return 0
        else
            log "WARNING: Specified TARGET_DISK=$TARGET_DISK not found or not accessible"
        fi
    fi
    
    # Wait for devices to be available
    wait_for_devices
    
    # Get all available block devices dynamically
    log "Scanning for available block devices..."
    local all_devices
    if ! all_devices=$(lsblk -d -n -o NAME,SIZE,TYPE,MODEL 2>/dev/null); then
        log "ERROR: Cannot enumerate block devices with lsblk"
        return 1
    fi
    
    log "Available devices:"
    echo "$all_devices" | while read line; do
        log "  $line"
    done
    
    # Find suitable disks (exclude unwanted types)
    local suitable_candidates=()
    while read -r name size type model; do
        [ -z "$name" ] && continue
        
        local disk="/dev/$name"
        
        # Skip unwanted device types
        case "$type" in
            loop|rom|part) 
                log "Skipping $disk: type=$type (not suitable for installation)"
                continue
                ;;
        esac
        
        # Skip if mounted as system disk
        if lsblk -n -o MOUNTPOINT "$disk" 2>/dev/null | grep -q "^/$\|^/boot$\|^/run/archiso\|^/run/miso"; then
            log "Skipping $disk: currently mounted as system disk or ISO"
            continue
        fi
        
        # Check size requirement
        local size_bytes=$(lsblk -b -d -n -o SIZE "$disk" 2>/dev/null || echo "0")
        local size_gb=$((size_bytes / 1024 / 1024 / 1024))
        
        if [ "$size_gb" -lt 8 ]; then
            log "Skipping $disk: too small (${size_gb}GB < 8GB required)"
            continue
        fi
        
        # Check accessibility
        if [ -e "$disk" ] && ([ -b "$disk" ] || lsblk "$disk" >/dev/null 2>&1); then
            log "Found suitable disk candidate: $disk (${size_gb}GB, type=$type, model=${model:-unknown})"
            suitable_candidates+=("$disk:$size_gb:$type:${model:-unknown}")
        else
            log "Disk $disk exists but not accessible"
        fi
    done <<< "$all_devices"
    
    # If we found suitable candidates, pick the best one
    if [ ${#suitable_candidates[@]} -gt 0 ]; then
        # Sort by preference: prefer non-USB, then by size (largest first)
        local best_disk=""
        local best_size=0
        
        for candidate in "${suitable_candidates[@]}"; do
            IFS=':' read -r disk size type model <<< "$candidate"
            
            # Prefer non-USB devices
            if [[ ! "$model" =~ [Uu][Ss][Bb] ]] && [ "$size" -gt "$best_size" ]; then
                best_disk="$disk"
                best_size="$size"
            elif [ -z "$best_disk" ]; then
                best_disk="$disk"
                best_size="$size"
            fi
        done
        
        if [ -n "$best_disk" ]; then
            log "Selected best disk: $best_disk (${best_size}GB)"
            echo "$best_disk"
            return 0
        fi
    fi
    
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
    log "Detecting target disk..."
    if ! DISK=$(detect_disk); then
        log "FATAL: Disk detection failed. Available disks:"
        lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null || true
        log "Please set TARGET_DISK environment variable or ensure a suitable disk is available"
        return 1
    fi
    log "Using disk: $DISK"
    
    # Verify the detected disk is actually accessible with multiple methods
    log "Verifying disk $DISK accessibility..."
    
    # Method 1: Standard block device test
    if [ ! -b "$DISK" ]; then
        log "WARNING: $DISK failed standard block device test"
        
        # Method 2: Check if device exists and try to access it
        if [ ! -e "$DISK" ]; then
            log "ERROR: Device $DISK does not exist"
            log "Available block devices:"
            ls -la /dev/sd* /dev/nvme* /dev/vd* 2>/dev/null || true
            lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null || true
            return 1
        fi
        
        # Method 3: Try to read device info with udevadm (if available)
        if command -v udevadm >/dev/null 2>&1; then
            log "Checking device with udevadm..."
            if udevadm info --name="$DISK" >/dev/null 2>&1; then
                log "Device $DISK recognized by udev"
            else
                log "WARNING: Device $DISK not recognized by udev"
            fi
        fi
        
        # Method 4: Try to access with lsblk specifically
        if lsblk "$DISK" >/dev/null 2>&1; then
            log "Device $DISK accessible via lsblk - proceeding despite block device test failure"
        else
            log "ERROR: Device $DISK not accessible via lsblk either"
            log "Available block devices:"
            ls -la /dev/sd* /dev/nvme* /dev/vd* 2>/dev/null || true
            lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null || true
            return 1
        fi
    else
        log "Device $DISK passed standard block device test"
    fi
    
    # Final verification: try to get device size
    local device_size
    if device_size=$(lsblk -b -d -n -o SIZE "$DISK" 2>/dev/null); then
        log "Verified disk $DISK is accessible (size: $device_size bytes)"
    else
        log "ERROR: Cannot read size of disk $DISK"
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