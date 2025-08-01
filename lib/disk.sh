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
        if [ -b "$disk" ]; then
            local size_bytes=$(lsblk -b -d -n -o SIZE "$disk" 2>/dev/null || echo "0")
            local size_gb=$((size_bytes / 1024 / 1024 / 1024))
            
            if [ "$size_gb" -ge 8 ]; then
                log "Found suitable disk: $disk (${size_gb}GB)"
                echo "$disk"
                return 0
            else
                log "Disk $disk too small (${size_gb}GB < 8GB required)"
            fi
        fi
    done
    
    # If no standard disks found, list available block devices
    log "No suitable disk found automatically. Available block devices:"
    lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null || true
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
    
    # Show disk information before partitioning
    log "Disk information before partitioning:"
    lsblk "$DISK" || true
    fdisk -l "$DISK" 2>/dev/null || true
    
    log "Available space check:"
    df -h / /tmp 2>/dev/null || true
    
    log "Unmounting previous mounts if any..."
    umount -R /mnt || true
    log "Partitioning $DISK (GPT, EFI+root)..."
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart ESP fat32 1MiB 301MiB
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart primary ext4 301MiB 100%
    log "Formatting partitions..."
    mkfs.fat -F32 "${DISK}1"
    mkfs.ext4 -F "${DISK}2"
    log "Mounting partitions..."
    mount "${DISK}2" /mnt
    mkdir -p /mnt/boot
    mount "${DISK}1" /mnt/boot
    
    # Show mounted filesystem information
    log "Mounted filesystem information:"
    df -h /mnt /mnt/boot 2>/dev/null || true
    lsblk "$DISK" || true
    
    checkpoint "Disk partitioning and mount complete"
}