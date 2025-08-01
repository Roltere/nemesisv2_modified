#!/usr/bin/env bash

# Nemesis Arch Installation Configuration
# Modify these values or set as environment variables

# === USER CONFIGURATION ===
USERNAME="${USERNAME:-main}"
USER_PASSWORD="${USER_PASSWORD:-}"  # Leave empty for interactive prompt
USER_GROUPS="${USER_GROUPS:-wheel,users,audio,video}"

# === SYSTEM CONFIGURATION ===
HOSTNAME="${HOSTNAME:-nemesis-host}"
TIMEZONE="${TIMEZONE:-UTC}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"

# === DISK CONFIGURATION ===
TARGET_DISK="${TARGET_DISK:-}"  # Auto-detect if empty
SWAP_SIZE="${SWAP_SIZE:-2G}"    # Set to "0" to disable swap
ROOT_SIZE="${ROOT_SIZE:-}"      # Use all remaining space if empty

# === DESKTOP ENVIRONMENT ===
DESKTOP_ENV="${DESKTOP_ENV:-ask}"  # Options: gnome, kde, both, minimal, ask
INSTALL_VMWARE_TOOLS="${INSTALL_VMWARE_TOOLS:-auto}"  # auto, yes, no

# === NETWORK CONFIGURATION ===
ENABLE_SSH="${ENABLE_SSH:-yes}"
ENABLE_MULTILIB="${ENABLE_MULTILIB:-yes}"

# === POST-INSTALL FEATURES ===
INSTALL_DEV_TOOLS="${INSTALL_DEV_TOOLS:-ask}"  # Install development packages
INSTALL_MEDIA_CODECS="${INSTALL_MEDIA_CODECS:-yes}"
OPTIMIZE_FOR_VM="${OPTIMIZE_FOR_VM:-auto}"  # VM-specific optimizations

# === THEME CONFIGURATION ===
INSTALL_THEMES="${INSTALL_THEMES:-yes}"
DOWNLOAD_WALLPAPER="${DOWNLOAD_WALLPAPER:-yes}"

# === INSTALLATION OPTIONS ===
INTERACTIVE_MODE="${INTERACTIVE_MODE:-yes}"  # Prompt for missing values
ENABLE_PROGRESS="${ENABLE_PROGRESS:-yes}"    # Show progress indicators
LOG_LEVEL="${LOG_LEVEL:-info}"               # debug, info, warn, error

# Function to validate configuration
validate_config() {
    local errors=0
    
    if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && [[ ${#USERNAME} -le 32 ]]; then
        :  # Valid username
    else
        echo "ERROR: Invalid username '$USERNAME'. Must be lowercase, start with letter/underscore, max 32 chars"
        ((errors++))
    fi
    
    if [[ -n "$TARGET_DISK" ]] && [[ ! "$TARGET_DISK" =~ ^/dev/ ]]; then
        echo "ERROR: TARGET_DISK must start with /dev/ if specified"
        ((errors++))
    fi
    
    if [[ "$DESKTOP_ENV" != "gnome" && "$DESKTOP_ENV" != "kde" && "$DESKTOP_ENV" != "both" && "$DESKTOP_ENV" != "minimal" && "$DESKTOP_ENV" != "ask" ]]; then
        echo "ERROR: DESKTOP_ENV must be one of: gnome, kde, both, minimal, ask"
        ((errors++))
    fi
    
    return $errors
}

# Function to prompt for missing configuration interactively
interactive_config() {
    if [[ "$INTERACTIVE_MODE" != "yes" ]]; then
        return 0
    fi
    
    echo "=== Interactive Configuration ==="
    
    # Username
    if [[ "$USERNAME" == "main" ]]; then
        read -p "Enter username [$USERNAME]: " input
        USERNAME="${input:-$USERNAME}"
    fi
    
    # Password
    if [[ -z "$USER_PASSWORD" ]]; then
        echo "Enter password for user '$USERNAME':"
        read -s USER_PASSWORD
        echo "Confirm password:"
        read -s password_confirm
        if [[ "$USER_PASSWORD" != "$password_confirm" ]]; then
            echo "ERROR: Passwords do not match"
            return 1
        fi
    fi
    
    # Hostname
    read -p "Enter hostname [$HOSTNAME]: " input
    HOSTNAME="${input:-$HOSTNAME}"
    
    # Timezone
    echo "Current timezone: $TIMEZONE"
    read -p "Enter timezone (e.g., America/New_York) [$TIMEZONE]: " input
    TIMEZONE="${input:-$TIMEZONE}"
    
    # Desktop Environment
    if [[ "$DESKTOP_ENV" == "ask" ]]; then
        echo "Select desktop environment:"
        echo "1) GNOME only"
        echo "2) KDE Plasma only" 
        echo "3) Both GNOME and KDE"
        echo "4) Minimal (no desktop)"
        read -p "Choice [1-4]: " choice
        case $choice in
            1) DESKTOP_ENV="gnome" ;;
            2) DESKTOP_ENV="kde" ;;
            3) DESKTOP_ENV="both" ;;
            4) DESKTOP_ENV="minimal" ;;
            *) echo "Invalid choice, using GNOME"; DESKTOP_ENV="gnome" ;;
        esac
    fi
    
    # Development tools
    if [[ "$INSTALL_DEV_TOOLS" == "ask" ]]; then
        read -p "Install development tools (git, docker, nodejs, python)? [y/N]: " input
        if [[ "$input" =~ ^[Yy] ]]; then
            INSTALL_DEV_TOOLS="yes"
        else
            INSTALL_DEV_TOOLS="no"
        fi
    fi
    
    echo "Configuration complete!"
}

# Export all configuration variables
export USERNAME USER_PASSWORD USER_GROUPS
export HOSTNAME TIMEZONE LOCALE KEYMAP
export TARGET_DISK SWAP_SIZE ROOT_SIZE
export DESKTOP_ENV INSTALL_VMWARE_TOOLS
export ENABLE_SSH ENABLE_MULTILIB
export INSTALL_DEV_TOOLS INSTALL_MEDIA_CODECS OPTIMIZE_FOR_VM
export INSTALL_THEMES DOWNLOAD_WALLPAPER
export INTERACTIVE_MODE ENABLE_PROGRESS LOG_LEVEL