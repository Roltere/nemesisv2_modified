#!/usr/bin/env bash
set -euo pipefail
source ./lib/logging.sh
checkpoint "Starting Nemesis modular install..."
source ./lib/base.sh
source ./lib/disk.sh
source ./lib/bootloader.sh
source ./lib/users.sh
source ./lib/desktop.sh
source ./lib/vmware.sh
checkpoint "Nemesis modular install finished."