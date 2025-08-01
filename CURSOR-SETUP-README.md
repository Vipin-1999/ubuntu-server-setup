# Cursor IDE Installation Guide for Linux

A comprehensive guide to install **Cursor v1.3.8** (Release Date: 2025-07-31) on ARM64 or x86_64 Ubuntu/Debian systems.

## 📋 Table of Contents

- [Prerequisites](#prerequisites)
- [Installation Steps](#installation-steps)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Uninstallation](#uninstallation)
- [System Requirements](#system-requirements)

## 🔧 Prerequisites

Before installing Cursor IDE, ensure your system meets the following requirements:

### System Requirements
- **OS**: Ubuntu 18.04+ or Debian 9+
- **Architecture**: ARM64 or x86_64
- **RAM**: Minimum 4GB (8GB recommended)
- **Storage**: At least 2GB free space

### Required Dependencies

Install the necessary libraries and tools:

```bash
sudo apt-get update
sudo apt-get install -y \
  libgbm1 \
  libnss3 \
  libxss1 \
  libasound2 \
  libgtk-3-0 \
  libxrandr2 \
  libx11-xcb1 \
  libatk1.0-0 \
  libatk-bridge2.0-0 \
  libglib2.0-0 \
  libsecret-1-0 \
  wget
```

## 🚀 Installation Steps

### Step 1: Create Installation Directory

```bash
sudo mkdir -p /opt/cursor
```

### Step 2: Download Cursor AppImage

**For ARM64 systems:**
```bash
wget https://downloads.cursor.com/production/a1fa6fc7d2c2f520293aad84aaa38d091dee6fef/linux/arm64/Cursor-1.3.8-arm64.AppImage \
  -O /opt/cursor/cursor.AppImage
```

**For x86_64 systems:**
```bash
wget https://downloads.cursor.com/production/a1fa6fc7d2c2f520293aad84aaa38d091dee6fef/linux/x64/Cursor-1.3.8-x86_64.AppImage \
  -O /opt/cursor/cursor.AppImage
```

> **Note**: If the above links are outdated, visit [Cursor AI Downloads](https://github.com/oslook/cursor-ai-downloads) for the latest versions.

### Step 3: Make AppImage Executable

```bash
sudo chmod +x /opt/cursor/cursor.AppImage
```

### Step 4: Extract AppImage

```bash
cd /tmp
/opt/cursor/cursor.AppImage --appimage-extract
```

### Step 5: Merge Extracted Files

```bash
sudo mv /tmp/squashfs-root/* /opt/cursor/
sudo rm -rf /tmp/squashfs-root
```

### Step 6: Fix Sandbox Helper Permissions

```bash
sudo chown root:root /opt/cursor/usr/share/cursor/chrome-sandbox
sudo chmod 4755 /opt/cursor/usr/share/cursor/chrome-sandbox
```

### Step 7: Create CLI Symlink

```bash
sudo ln -sf /opt/cursor/AppRun /usr/local/bin/cursor
```

## ✅ Verification

Test the installation by running:

```bash
cursor --help
```

You should see Cursor's help output. You can also launch Cursor by typing:

```bash
cursor
```

## 🔧 Troubleshooting

### Common Issues

#### Issue: "Permission denied" when running cursor
**Solution:**
```bash
sudo chmod +x /opt/cursor/AppRun
sudo chmod +x /usr/local/bin/cursor
```

#### Issue: "chrome-sandbox" errors
**Solution:**
```bash
sudo chown root:root /opt/cursor/usr/share/cursor/chrome-sandbox
sudo chmod 4755 /opt/cursor/usr/share/cursor/chrome-sandbox
```

#### Issue: Missing dependencies
**Solution:**
```bash
sudo apt-get update
sudo apt-get install -y \
  libgbm1 libnss3 libxss1 libasound2 \
  libgtk-3-0 libxrandr2 libx11-xcb1 \
  libatk1.0-0 libatk-bridge2.0-0 \
  libglib2.0-0 libsecret-1-0
```

#### Issue: AppImage won't extract
**Solution:**
```bash
# Check if AppImage is corrupted
file /opt/cursor/cursor.AppImage

# Re-download if necessary
sudo rm /opt/cursor/cursor.AppImage
# Re-run the download command from Step 2
```

### Debug Mode

To run Cursor with debug information:

```bash
cursor --verbose
```

## 🗑️ Uninstallation

To completely remove Cursor IDE:

```bash
# Remove the installation directory
sudo rm -rf /opt/cursor

# Remove the CLI symlink
sudo rm -f /usr/local/bin/cursor

# Clean up any remaining files
sudo rm -rf ~/.config/Cursor
sudo rm -rf ~/.local/share/Cursor
```

## 🔗 Additional Resources

- [Cursor Official Website](https://cursor.sh/)
- [Cursor Documentation](https://cursor.sh/docs)
- [Cursor AI Downloads Repository](https://github.com/oslook/cursor-ai-downloads)
- [Cursor GitHub Issues](https://github.com/getcursor/cursor/issues)

---

**Last Updated**: August 2025  
**Cursor Version**: 1.3.8  
**Tested On**: Ubuntu 24.04
