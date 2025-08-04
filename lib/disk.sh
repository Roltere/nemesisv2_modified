#!/usr/bin/env bash

detect_disk() {
    log "Auto-detecting installation disk..."
    
    # If TARGET_DISK is set, use it
    if [ -n "${TARGET_DISK:-}" ]; then
        if [ -b "$TARGET_DISK" ]; then
            echo "$TARGET_DISK"
            return 0
        else
            log "WARNING: Specified TARGET_DISK=$TARGET_DISK not found"
        fi
    fi
    
    # Common disk patterns in order of preference
    local disk_candidates=(
        "/dev/sda"      # Traditional SATA/SCSI
        "/dev/nvme0n1"  # NVMe drives
        "/dev/vda"      # Virtio (QEMU/KVM)
        "/dev/xvda"     # Xen virtual disks
        "/dev/mmcblk0"  # eMMC/SD cards
    )
    
    # Find the first available disk with sufficient size (>= 8GB)
    for disk in "${disk_candidates[@]}"; do
        log "Checking disk candidate: $disk"
        if [ -b "$disk" ]; then
            log "Device $disk exists as block device"
            
            # Check if this disk is currently mounted as root or boot (ISO system)
            if lsblk -n -o MOUNTPOINT "$disk" 2>/dev/null | grep -q "^/$\|^/boot$\|^/run/archiso"; then
                log "Skipping $disk: currently mounted as system disk or ISO"
                continue
            fi
            
            local size_bytes=$(lsblk -b -d -n -o SIZE "$disk" 2>/dev/null || echo "0")
            local size_gb=$((size_bytes / 1024 / 1024 / 1024))
            
            if [ "$size_gb" -ge 8 ]; then
                log "Found suitable disk: $disk (${size_gb}GB)"
                echo "$disk"
                return 0
            else
                log "Disk $disk too small (${size_gb}GB < 8GB required)"
            fi
        else
            log "Device $disk does not exist or is not a block device"
        fi
    done
    
    # If no standard disks found, try to find ANY available disk
    log "No standard disk found, searching for any suitable disk..."
    local found_disks=$(lsblk -d -n -o NAME,SIZE,TYPE | grep -v loop | grep -v sr | grep -v rom | grep -v part | head -5)
    log "Found block devices: $found_disks"
    
    # Try to find a suitable disk from lsblk output
    while read -r name size type; do
        local disk="/dev/$name"
        
        # Skip if it's a read-only device or mounted root filesystem
        if [ "$type" = "rom" ] || [ "$type" = "part" ]; then
            log "Skipping $disk: type=$type (not a writable disk)"
            continue
        fi
        
        # Check if this disk is currently mounted as root or boot
        if lsblk -n -o MOUNTPOINT "$disk" 2>/dev/null | grep -q "^/$\|^/boot$\|^/run/archiso"; then
            log "Skipping $disk: currently mounted as system disk or ISO"
            continue
        fi
        
        if [ -b "$disk" ]; then
            local size_bytes=$(lsblk -b -d -n -o SIZE "$disk" 2>/dev/null || echo "0")
            local size_gb=$((size_bytes / 1024 / 1024 / 1024))
            if [ "$size_gb" -ge 8 ]; then
                log "Found alternative suitable disk: $disk (${size_gb}GB, type=$type)"
                echo "$disk"
                return 0
            else
                log "Disk $disk too small: ${size_gb}GB < 8GB required"
            fi
        fi
    done <<< "$found_disks"
    
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
    
    # Verify the detected disk is actually accessible
    if [ ! -b "$DISK" ]; then
        log "ERROR: Detected disk $DISK is not a valid block device!"
        log "Available block devices:"
        ls -la /dev/sd* /dev/nvme* /dev/vd* 2>/dev/null || true
        lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null || true
        return 1
    fi
    log "Verified disk $DISK is accessible as block device"
    
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