#!/usr/bin/env bash
# [Application Name] Uninstallation Script
# Version: [Version]
# Last Updated: [Date]
#
# This script safely removes [Application Name] from Ubuntu/Debian systems.

set -e

# Configuration
INSTALL_DIR="[Installation Directory]"
SYMLINK="[Symlink Path]"
CONFIG_DIR="[Config Directory]"
DATA_DIR="[Data Directory]"
LOG="/var/log/[app-name]_uninstall.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
info()  { echo -e "${BLUE}[INFO]${NC}  $*" | tee -a "$LOG"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*" | tee -a "$LOG"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG"; }

# Check if running as root
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "This script needs root privileges. Re-running with sudo ..."
    exec sudo -E bash "$0" "$@"
  fi
}

# Backup function (optional)
backup_data() {
  if [ -d "$DATA_DIR" ]; then
    local backup_dir="$DATA_DIR.backup.$(date +%Y%m%d_%H%M%S)"
    info "Backing up data directory to $backup_dir"
    cp -r "$DATA_DIR" "$backup_dir"
  fi
}

# Remove application files
remove_application() {
  info "Removing [Application Name] files..."
  
  # Remove installation directory
  if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    ok "Removed installation directory: $INSTALL_DIR"
  else
    warn "Installation directory not found: $INSTALL_DIR"
  fi
  
  # Remove symlink
  if [ -L "$SYMLINK" ]; then
    rm -f "$SYMLINK"
    ok "Removed symlink: $SYMLINK"
  else
    warn "Symlink not found: $SYMLINK"
  fi
}

# Remove configuration files
remove_config() {
  info "Removing configuration files..."
  
  if [ -d "$CONFIG_DIR" ]; then
    rm -rf "$CONFIG_DIR"
    ok "Removed config directory: $CONFIG_DIR"
  else
    warn "Config directory not found: $CONFIG_DIR"
  fi
}

# Remove data files (with confirmation)
remove_data() {
  if [ -d "$DATA_DIR" ]; then
    echo
    read -p "Remove data directory ($DATA_DIR)? This will delete all [Application Name] data. [y/N]: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      rm -rf "$DATA_DIR"
      ok "Removed data directory: $DATA_DIR"
    else
      info "Data directory preserved: $DATA_DIR"
    fi
  else
    warn "Data directory not found: $DATA_DIR"
  fi
}

# Verify removal
verify_removal() {
  info "Verifying removal..."
  
  local errors=0
  
  if [ -d "$INSTALL_DIR" ]; then
    err "Installation directory still exists: $INSTALL_DIR"
    errors=$((errors + 1))
  fi
  
  if [ -L "$SYMLINK" ]; then
    err "Symlink still exists: $SYMLINK"
    errors=$((errors + 1))
  fi
  
  if [ $errors -eq 0 ]; then
    ok "Verification successful - [Application Name] has been removed"
  else
    err "Verification failed - some files may still exist"
    return 1
  fi
}

# Main uninstallation function
main() {
  require_root "$@"
  
  info "Starting [Application Name] uninstallation..."
  info "Log file: $LOG"
  
  # Create log file
  touch "$LOG"
  
  backup_data
  remove_application
  remove_config
  remove_data
  verify_removal
  
  ok "Uninstallation completed successfully!"
  info "Log file saved to: $LOG"
}

# Run main function
main "$@" 