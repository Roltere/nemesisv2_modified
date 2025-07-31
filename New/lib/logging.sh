#!/usr/bin/env bash
set -euo pipefail

LOGFILE="${LOGFILE:-/root/install.log}"

log() {
    local msg="[$(date '+%F %T')] $*"
    echo -e "$msg" | tee -a "$LOGFILE"
}

checkpoint() {
    log "=== CHECKPOINT: $* ==="
}

fail() {
    log "ERROR: $*"
    exit 1
}

trap 'fail "An unexpected error occurred at line $LINENO."' ERR
