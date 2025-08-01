# Ubuntu Setup Scripts

A comprehensive collection of automation scripts for setting up Ubuntu systems with various applications and configurations.

## 📁 Project Structure

```
ubuntu-setup/
├── README.md                    # This file - Main project overview
├── applications/                # Application-specific setup scripts
│   ├── cursor/                 # Cursor IDE setup
│   │   ├── README.md          # Cursor installation guide
│   │   └── install.sh         # Cursor installation script
│   └── [future-apps]/         # Future application folders
├── networking/                 # Network configuration scripts
│   ├── README.md              # Network setup documentation
│   └── rpi5_setup.sh         # Raspberry Pi 5 network automation
└── templates/                  # Template files for new setups
    ├── app_template/          # Template for new application setups
    └── script_template.sh     # Template for new scripts
```

## 🚀 Quick Start

### Available Setups

#### 1. **Cursor IDE Setup**
- **Location**: `applications/cursor/`
- **Purpose**: Install Cursor IDE on Ubuntu/Debian systems
- **Usage**: 
  ```bash
  cd applications/cursor/
  sudo ./install.sh
  ```
- **Documentation**: See `applications/cursor/README.md`

#### 2. **Raspberry Pi 5 Network Setup**
- **Location**: `networking/`
- **Purpose**: Automated network configuration for Ubuntu Server on RPi 5
- **Usage**:
  ```bash
  cd networking/
  sudo ./rpi5_setup.sh --eth-if enabcm6e0 --wifi-if wlan0
  ```
- **Documentation**: See `networking/README.md`

## 📋 Adding New Applications

To add a new application setup:

1. **Create a new folder** in `applications/`:
   ```bash
   mkdir applications/your-app-name/
   ```

2. **Copy the template**:
   ```bash
   cp -r templates/app_template/* applications/your-app-name/
   ```

3. **Customize the files**:
   - Update `README.md` with your application's documentation
   - Modify `install.sh` with your installation logic
   - Update metadata in the script header

4. **Update this README** to include your new application

### Template Structure

The `templates/app_template/` contains:
- `README.md` - Documentation template
- `install.sh` - Installation script template
- `uninstall.sh` - Uninstallation script template (optional)

## 🔧 Script Standards

All scripts in this project follow these standards:

- **Error Handling**: Comprehensive error checking and rollback capabilities
- **Logging**: Detailed logging to `/var/log/` or script-specific log files
- **Documentation**: Clear README files with usage examples
- **Safety**: Backup original configurations before making changes
- **Idempotency**: Scripts can be run multiple times safely

## 🛠️ Requirements

- Ubuntu 18.04+ or Debian 9+
- `sudo` privileges
- Internet connectivity (for downloads)

---

**Last Updated**: August 2025  
**Tested On**: Ubuntu 24.04, Raspberry Pi 5 