#!/usr/bin/env bash
set -euo pipefail

# Load logging functions first for error tracing
source ./lib/logging.sh

checkpoint "Starting Nemesis modular install..."
chmod +x ./lib/*

source ./lib/base.sh
source ./lib/disk.sh
source ./lib/bootloader.sh
source ./lib/users.sh
source ./lib/desktop.sh
source ./lib/vmware.sh

checkpoint "Nemesis modular install finished."
