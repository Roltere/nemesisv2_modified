#!/usr/bin/env bash

# Pre-flight checks and error recovery functions

STATE_FILE="/tmp/nemesis-install-state"
LOG_FILE="/tmp/nemesis-install.log"

save_state() {
    local step="$1"
    echo "$step" > "$STATE_FILE"
    log "State saved: $step"
}

get_last_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "START"
    fi
}

resume_from_state() {
    local last_state=$(get_last_state)
    if [[ "$last_state" != "START" ]]; then
        log "Previous installation detected. Last completed step: $last_state"
        read -p "Resume from last step? [y/N]: " resume
        if [[ "$resume" =~ ^[Yy] ]]; then
            echo "$last_state"
            return 0
        else
            log "Starting fresh installation"
            rm -f "$STATE_FILE"
        fi
    fi
    echo "START"
}

cleanup_failed_install() {
    log "Cleaning up failed installation..."
    umount -R /mnt 2>/dev/null || true
    swapoff -a 2>/dev/null || true
    log "Cleanup complete"
}

preflight_checks() {
    log "=== Running pre-flight checks ==="
    local errors=0
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log "ERROR: This script must be run as root"
        ((errors++))
    fi
    
    # Check if running in UEFI mode
    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        log "WARNING: Not running in UEFI mode. Legacy BIOS installations not fully supported."
    fi
    
    # Check internet connectivity
    log "Checking internet connectivity..."
    if ping -c 1 archlinux.org &>/dev/null; then
        log "Internet connectivity: OK"
    else
        log "WARNING: No internet connectivity detected. Some features may fail."
    fi
    
    # Check available memory
    local mem_mb=$(free -m | awk '/^Mem:/ {print $2}')
    if [[ $mem_mb -lt 1024 ]]; then
        log "WARNING: Low memory detected (${mem_mb}MB). Installation may be slow."
    else
        log "Memory check: OK (${mem_mb}MB available)"
    fi
    
    # Check available disk space in /tmp
    local tmp_space=$(df /tmp | tail -1 | awk '{print $4}')
    if [[ $tmp_space -lt 1048576 ]]; then  # 1GB in KB
        log "WARNING: Low space in /tmp (${tmp_space}KB). Downloads may fail."
    fi
    
    # Check if pacman keyring is initialized
    if pacman-key --list-keys | grep -q "archlinux"; then
        log "Pacman keyring: OK"
    else
        log "Initializing pacman keyring..."
        pacman-key --init
        pacman-key --populate archlinux
    fi
    
    # Validate configuration
    if ! validate_config; then
        log "ERROR: Configuration validation failed"
        ((errors++))
    fi
    
    if [[ $errors -gt 0 ]]; then
        log "Pre-flight checks failed with $errors error(s)"
        return 1
    fi
    
    log "=== All pre-flight checks passed ==="
    return 0
}

estimate_install_time() {
    local desktop="${DESKTOP_ENV:-gnome}"
    local base_time=10  # Base system in minutes
    local desktop_time=0
    
    case "$desktop" in
        "minimal") desktop_time=5 ;;
        "gnome") desktop_time=15 ;;
        "kde") desktop_time=20 ;;
        "both") desktop_time=30 ;;
    esac
    
    local total=$((base_time + desktop_time))
    
    if [[ "${INSTALL_DEV_TOOLS:-no}" == "yes" ]]; then
        total=$((total + 10))
    fi
    
    log "Estimated installation time: $total minutes"
    echo "$total"
}

check_resume_capability() {
    # Check if we can resume from various stages
    if [[ -d /mnt/boot && -d /mnt/etc ]]; then
        log "Found existing installation, resume possible from bootloader stage"
        return 0
    elif [[ -d /mnt/etc ]]; then
        log "Found partial installation, resume possible from disk stage"
        return 0
    fi
    return 1
}

create_recovery_info() {
    local recovery_file="/tmp/nemesis-recovery.sh"
    cat > "$recovery_file" << 'EOF'
#!/bin/bash
# Nemesis Installation Recovery Script
echo "=== Nemesis Recovery ==="
echo "This script can help recover from a failed installation"
echo ""
echo "Available actions:"
echo "1) Clean up mounted filesystems"
echo "2) View installation log"
echo "3) Resume installation"
echo "4) Start fresh installation"
echo ""
read -p "Select action [1-4]: " action

case $action in
    1)
        echo "Unmounting filesystems..."
        umount -R /mnt 2>/dev/null || true
        swapoff -a 2>/dev/null || true
        echo "Cleanup complete"
        ;;
    2)
        if [[ -f /tmp/nemesis-install.log ]]; then
            less /tmp/nemesis-install.log
        else
            echo "No log file found"
        fi
        ;;
    3)
        if [[ -f /tmp/nemesis-install-state ]]; then
            echo "Resuming installation..."
            cd /root/nemesis* && ./install.sh
        else
            echo "No resume state found"
        fi
        ;;
    4)
        rm -f /tmp/nemesis-install-state
        echo "Starting fresh installation..."
        cd /root/nemesis* && ./install.sh
        ;;
esac
EOF
    chmod +x "$recovery_file"
    log "Recovery script created at $recovery_file"
}

# Error handler
handle_error() {
    local exit_code=$?
    local line_number=$1
    
    log "ERROR: Installation failed at line $line_number with exit code $exit_code"
    log "Last completed step: $(get_last_state)"
    
    create_recovery_info
    cleanup_failed_install
    
    echo ""
    echo "Installation failed! Recovery options:"
    echo "1. Run: /tmp/nemesis-recovery.sh"
    echo "2. Check logs: less /tmp/nemesis-install.log"
    echo "3. Resume: ./install.sh (if partial installation exists)"
    
    exit $exit_code
}

# Set up error handling
setup_error_handling() {
    trap 'handle_error $LINENO' ERR
    
    # Redirect all output to log file while still showing on screen
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1
    
    log "Error handling and logging initialized"
}