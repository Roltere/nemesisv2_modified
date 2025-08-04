#!/usr/bin/env bash

# Use the EXACT method from the working reference implementation
detect_disk() {
    echo "==> Auto-detecting installation disk using reference method..."
    
    # Use the exact command from working nemesis.sh
    local disk
    disk=$(fdisk -l | grep "dev" | grep -o -P "(?=/).*(?=:)" | cut -d$'\n' -f1)
    
    echo "Found disk: $disk"
    echo "$disk"
    return 0
}

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
    # Always assume VM mode for simplicity (like reference does in VM)
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

