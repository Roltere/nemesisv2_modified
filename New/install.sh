#!/usr/bin/env bash
set -euo pipefail

export LOGFILE="/tmp/install.log"
rm -f "$LOGFILE"

source ./lib/logging.sh

log "Starting Arch-Nemesis modular install..."
checkpoint "Configuration check"

# Configuration (edit as needed)
HOSTNAME="DESKTOP-IJ0CNHN"
USERNAME="user"
PASSWORD="Ch4ngeM3!"
LUKS_PASSWORD="1234567890"
VM=true

export HOSTNAME USERNAME PASSWORD LUKS_PASSWORD VM

# Load and execute modules for stage 1
for module in lib/disk.sh lib/base.sh; do
    checkpoint "Running module: $(basename "$module")"
    if [[ -f $module ]]; then
        bash "$module"
    else
        fail "Module $module not found!"
    fi
done

checkpoint "Copying stage2 modules into new system"

# Copy logging utility and stage2 modules into chroot
for file in lib/logging.sh lib/users.sh lib/desktop.sh lib/vmware.sh; do
    cp "$file" "/mnt/root/$(basename "$file")"
done

# Create a single stage2 orchestrator
cat <<'EOF' >/mnt/root/nemesis-stage2.sh
#!/usr/bin/env bash
set -euo pipefail
export LOGFILE="/root/install.log"
source /root/logging.sh

checkpoint "Beginning Stage 2 (chrooted post-install)"

for module in /root/users.sh /root/desktop.sh /root/vmware.sh; do
    checkpoint "Running $(basename "$module") in chroot"
    bash "$module"
done

log "Stage 2 (chroot) complete. You may reboot."

EOF

chmod +x /mnt/root/nemesis-stage2.sh

checkpoint "Entering chroot for Stage 2 setup"

# Run the chrooted stage2 automatically (all output to install.log)
arch-chroot /mnt bash /root/nemesis-stage2.sh | tee -a "$LOGFILE"

log "Arch-Nemesis install complete. You may reboot now. Full log at $LOGFILE"
