#!/usr/bin/env bash
set -euo pipefail

# --- Outside chroot: Partition, format, mount, pacstrap
source ./lib/logging.sh
source ./lib/base.sh
source ./lib/disk.sh

# --- Copy chroot modules and execute them IN ORDER ---
for script in bootloader.sh users.sh desktop.sh vmware.sh; do
    echo ">>> Running $script inside chroot"
    cp "./lib/$script" "/mnt/$script"
    arch-chroot /mnt bash "/$script"
    rm "/mnt/$script"
done

checkpoint "All install modules completed in correct order."
