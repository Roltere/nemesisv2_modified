#!/usr/bin/env bash
# lib/logging.sh

log() {
    echo "[${0##*/}] $*"
}
checkpoint() {
    echo "=== CHECKPOINT: $* ==="
}
