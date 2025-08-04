#!/usr/bin/env bash

detect_disk() {
    echo "==> Auto-detecting installation disk..."
    
    # If TARGET_DISK environment variable is set, use it
    if [ -n "${TARGET_DISK:-}" ]; then
        echo "Using TARGET_DISK: $TARGET_DISK"
        echo "$TARGET_DISK"
        return 0
    fi
    
    # Get all block devices, excluding the ISO/live system
    echo "Scanning for available disks..."
    
    # List all disks and their mount points
    while read -r name size type mountpoint; do
        [ -z "$name" ] && continue
        
        local disk="/dev/$name"
        
        # Skip if not a disk (e.g., partitions, loop devices)
        [ "$type" != "disk" ] && continue
        
        # Skip if mounted as root, boot, or live system
        if echo "$mountpoint" | grep -q "^/$\|^/boot\|/run/archiso\|/run/live"; then
            echo "Skipping $disk: mounted as live system ($mountpoint)"
            continue
        fi
        
        # Check if any partitions are mounted as live system
        local skip_disk=false
        while read -r part_name part_size part_type part_mount; do
            if [[ "$part_name" == "$name"* ]] && echo "$part_mount" | grep -q "^/$\|^/boot\|/run/archiso\|/run/live"; then
                echo "Skipping $disk: partition mounted as live system"
                skip_disk=true
                break
            fi
        done < <(lsblk -rno NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null)
        
        [ "$skip_disk" = true ] && continue
        
        # Check minimum size (8GB) - convert size to GB for comparison
        local size_gb=0
        if [[ "$size" == *"T" ]]; then
            size_gb=$(echo "$size" | sed 's/[^0-9.]//g' | cut -d. -f1)
            size_gb=$((size_gb * 1000))
        elif [[ "$size" == *"G" ]]; then
            size_gb=$(echo "$size" | sed 's/[^0-9.]//g' | cut -d. -f1)
        elif [[ "$size" == *"M" ]]; then
            local size_mb=$(echo "$size" | sed 's/[^0-9.]//g' | cut -d. -f1)
            size_gb=$((size_mb / 1000))
        fi
        
        if [ "$size_gb" -lt 8 ]; then
            echo "Skipping $disk: too small ($size)"
            continue
        fi
        
        echo "Found suitable disk: $disk ($size)"
        echo "$disk"
        return 0
        
    done < <(lsblk -rno NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null)
    
    echo "ERROR: No suitable disk found"
    echo "Available devices:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
    return 1
}

setup_disk() {
    echo "==> Detecting target disk..."
    
    if ! DISK=$(detect_disk); then
        echo "ERROR: Disk detection failed"
        return 1
    fi
    
    echo "==> Starting disk setup for $DISK"

    # 1. Check device exists and is a block device
    if [[ ! -b "$DISK" ]]; then
        echo "ERROR: Device $DISK does not exist or is not a block device."
        return 1
    fi

    # 2. Unmount anything that might be mounted (just in case)
    echo "==> Unmounting possible partitions on $DISK"
    for part in $(ls ${DISK}?* 2>/dev/null); do
        umount "$part" 2>/dev/null || true
        swapoff "$part" 2>/dev/null || true
    done

    # 3. Zap (remove) any partition table/signatures
    echo "==> Wiping partition table on $DISK"
    sgdisk --zap-all "$DISK" || {
        echo "WARNING: sgdisk failed (may be OK if disk is already blank)"
    }

    # 4. Create GPT partition table
    echo "==> Creating GPT partition table on $DISK"
    parted -s "$DISK" mklabel gpt || {
        echo "ERROR: Could not create GPT partition table on $DISK"
        return 1
    }

    # 5. Create single partition (root, 1MiB to 100%)
    echo "==> Creating root partition on $DISK"
    parted -s "$DISK" mkpart primary ext4 1MiB 100% || {
        echo "ERROR: Failed to create root partition"
        return 1
    }

    # 6. Wait for the kernel to pick up the partition
    partprobe "$DISK"
    sleep 2

    # 7. Get the partition name (usually /dev/sda1)
    ROOT_PART="${DISK}1"
    if [[ ! -b "$ROOT_PART" ]]; then
        # Some systems may use e.g. /dev/nvme0n1p1
        ROOT_PART=$(ls ${DISK}?* 2>/dev/null | head -n1)
    fi

    if [[ ! -b "$ROOT_PART" ]]; then
        echo "ERROR: Partition was not created properly."
        return 1
    fi

    # 8. Format as ext4
    echo "==> Formatting $ROOT_PART as ext4"
    mkfs.ext4 -F "$ROOT_PART" || {
        echo "ERROR: Failed to format partition $ROOT_PART"
        return 1
    }

    echo "==> Disk setup complete."
    return 0
}

# Only run if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_disk
fi
