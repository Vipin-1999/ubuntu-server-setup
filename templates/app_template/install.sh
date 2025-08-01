#!/usr/bin/env bash
# [Application Name] Installation Script
# Version: [Version]
# Last Updated: [Date]
# Tested On: Ubuntu 22.04, 24.04
#
# This script installs [Application Name] on Ubuntu/Debian systems with
# comprehensive error handling and rollback capabilities.

set -e

# Configuration
VERSION="[Version]"
INSTALL_DIR="[Installation Directory]"
SYMLINK="[Symlink Path]"
LOG="/var/log/[app-name]_install.log"

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

# Backup function
backup_existing() {
  if [ -d "$INSTALL_DIR" ]; then
    local backup_dir="$INSTALL_DIR.backup.$(date +%Y%m%d_%H%M%S)"
    info "Backing up existing installation to $backup_dir"
    mv "$INSTALL_DIR" "$backup_dir"
  fi
}

# Rollback function
rollback() {
  err "Installation failed. Rolling back changes..."
  
  # Remove installation directory
  if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
  fi
  
  # Remove symlink
  if [ -L "$SYMLINK" ]; then
    rm -f "$SYMLINK"
  fi
  
  # Restore backup if exists
  local backup_dir="$INSTALL_DIR.backup.$(date +%Y%m%d_%H%M%S)"
  if [ -d "$backup_dir" ]; then
    mv "$backup_dir" "$INSTALL_DIR"
  fi
  
  err "Rollback complete. Please check the logs at $LOG"
  exit 1
}

# Error handling
trap rollback ERR

# Detect architecture
detect_architecture() {
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)
      PLATFORM="x64"
      ;;
    aarch64|arm64)
      PLATFORM="arm64"
      ;;
    *)
      err "Unsupported architecture: $ARCH"
      exit 1
      ;;
  esac
  info "Detected architecture: $ARCH ($PLATFORM)"
}

# Install dependencies
install_dependencies() {
  info "Installing required dependencies..."
  
  apt-get update
  apt-get install -y \
    [dependency1] \
    [dependency2] \
    [dependency3] \
    wget \
    curl
}

# Download and install
download_and_install() {
  info "Downloading [Application Name] v$VERSION..."
  
  # Create installation directory
  mkdir -p "$INSTALL_DIR"
  
  # Download application
  # [Add download logic here]
  
  # Make executable
  chmod +x "$INSTALL_DIR/[executable-name]"
  
  # Create symlink
  ln -sf "$INSTALL_DIR/[executable-name]" "$SYMLINK"
}

# Verify installation
verify_installation() {
  info "Verifying installation..."
  
  if [ -f "$INSTALL_DIR/[executable-name]" ]; then
    ok "Application binary found"
  else
    err "Application binary not found"
    return 1
  fi
  
  if [ -L "$SYMLINK" ]; then
    ok "Symlink created successfully"
  else
    err "Symlink creation failed"
    return 1
  fi
  
  # Test the application
  if "$SYMLINK" --version >/dev/null 2>&1; then
    ok "Application test successful"
  else
    err "Application test failed"
    return 1
  fi
}

# Main installation function
main() {
  require_root "$@"
  
  info "Starting [Application Name] installation..."
  info "Version: $VERSION"
  info "Log file: $LOG"
  
  # Create log file
  touch "$LOG"
  
  detect_architecture
  backup_existing
  install_dependencies
  download_and_install
  verify_installation
  
  ok "Installation completed successfully!"
  info "You can now run '[Application Name]' to get started."
  info "Log file saved to: $LOG"
}

# Run main function
main "$@" 