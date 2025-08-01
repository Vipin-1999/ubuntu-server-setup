#!/usr/bin/env bash
set -e

# Configuration
VERSION="1.3.8"
HASH="a1fa6fc7d2c2f520293aad84aaa38d091dee6fef"
INSTALL_DIR="/opt/cursor"
SYMLINK="/usr/local/bin/cursor"

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)
    PLATFORM="x64"
    SUFFIX="x86_64"
    ;;
  aarch64)
    PLATFORM="arm64"
    SUFFIX="aarch64"
    ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

URL="https://downloads.cursor.com/production/$HASH/linux/$PLATFORM/Cursor-$VERSION-$SUFFIX.AppImage"

echo "➡️  Installing Cursor v$VERSION for $ARCH"
echo "📥  Downloading from: $URL"

# Prompt for dependencies
read -p "Install system dependencies? [Y/n]: " RESP
RESP=${RESP:-Y}
if [[ "$RESP" =~ ^[Yy]$ ]]; then
  sudo apt-get update
  sudo apt-get install -y libgbm1 libnss3 libxss1 libasound2 \
    libgtk-3-0 libxrandr2 libx11-xcb1 libatk1.0-0 \
    libatk-bridge2.0-0 libglib2.0-0 libsecret-1-0 wget
fi

# Download & setup
sudo mkdir -p "$INSTALL_DIR"
sudo wget -O "$INSTALL_DIR/cursor.AppImage" "$URL"
sudo chmod +x "$INSTALL_DIR/cursor.AppImage"

# Extract & merge
cd /tmp
"$INSTALL_DIR/cursor.AppImage" --appimage-extract
sudo mv squashfs-root/* "$INSTALL_DIR/"
sudo rm -rf squashfs-root

# Fix sandbox helper
sudo chown root:root "$INSTALL_DIR/usr/share/cursor/chrome-sandbox"
sudo chmod 4755     "$INSTALL_DIR/usr/share/cursor/chrome-sandbox"

# Symlink
sudo ln -sf "$INSTALL_DIR/AppRun" "$SYMLINK"

echo "✅ Installation complete! Run 'cursor' to get started."
