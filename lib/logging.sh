#!/usr/bin/env bash
<<<<<<< HEAD
log() { echo "[${0##*/}] $*"; }
checkpoint() { echo "=== CHECKPOINT: $* ==="; }
=======

# Progress tracking variables
TOTAL_STEPS=0
CURRENT_STEP=0
START_TIME=$(date +%s)

log() { 
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [${0##*/}] $*"
}

checkpoint() { 
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] === CHECKPOINT: $* ==="
}

progress() {
    local message="$1"
    local step="${2:-}"
    
    if [[ -n "$step" ]]; then
        CURRENT_STEP="$step"
    else
        ((CURRENT_STEP++))
    fi
    
    if [[ "${ENABLE_PROGRESS:-yes}" == "yes" && $TOTAL_STEPS -gt 0 ]]; then
        local percent=$((CURRENT_STEP * 100 / TOTAL_STEPS))
        local elapsed=$(($(date +%s) - START_TIME))
        local eta=""
        
        if [[ $CURRENT_STEP -gt 0 && $percent -gt 0 ]]; then
            local total_estimated=$((elapsed * 100 / percent))
            local remaining=$((total_estimated - elapsed))
            eta=" (ETA: ${remaining}s)"
        fi
        
        printf "\r\033[K[%3d%%] %s%s" "$percent" "$message" "$eta"
        if [[ $percent -eq 100 ]]; then
            echo ""
        fi
    else
        log "$message"
    fi
}

set_total_steps() {
    TOTAL_STEPS="$1"
    CURRENT_STEP=0
    log "Installation will complete in $TOTAL_STEPS steps"
}

# Enhanced pacman wrapper with progress
pacman_install() {
    local packages=("$@")
    local total=${#packages[@]}
    local current=0
    
    log "Installing $total packages: ${packages[*]}"
    
    # Try to install all packages at once first (faster)
    if pacman --noconfirm -S "${packages[@]}" 2>/dev/null; then
        progress "Installed ${#packages[@]} packages"
        return 0
    fi
    
    # Fall back to individual installation if batch fails
    log "Batch installation failed, trying individual packages..."
    local failed_packages=()
    
    for package in "${packages[@]}"; do
        ((current++))
        if pacman --noconfirm -S "$package" 2>/dev/null; then
            progress "Installed $package ($current/$total)"
        else
            log "WARNING: Failed to install $package"
            failed_packages+=("$package")
        fi
    done
    
    if [[ ${#failed_packages[@]} -gt 0 ]]; then
        log "Failed to install: ${failed_packages[*]}"
        return 1
    fi
    
    return 0
}

# Performance monitoring
monitor_performance() {
    if [[ "${LOG_LEVEL:-info}" == "debug" ]]; then
        local load=$(uptime | awk -F'load average:' '{print $2}' | cut -d, -f1 | xargs)
        local mem_used=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100.0}')
        local disk_used=$(df /mnt 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//' || echo "0")
        
        log "Performance: Load=$load, Memory=${mem_used}%, Disk=${disk_used}%"
    fi
}
>>>>>>> d355b03 (Changing file structure)
