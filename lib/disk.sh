#!/usr/bin/env bash

# Set your target disk here (or detect it)
DISK="/dev/sda"

setup_disk() {
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
