# Ubuntu Server 24.04.2 LTS (Raspberry Pi 5) Networking Automation

**Script:** `rpi5_net_setup.sh`  
**Last updated:** July 31, 2025

This README explains how to use the rollback-enabled automation script that brings a fresh Ubuntu Server (RPi 5) online quickly, manages Wi‑Fi via NetworkManager, and **prefers Ethernet** when both Ethernet and Wi‑Fi are available. It also describes the rollback options if something goes wrong.


## What the script does

1. **Detects interfaces** (tries to auto-detect `eth*` and `wlan*`).
2. **Gets online fast via Ethernet** (creates a minimal Netplan DHCP config with systemd‑networkd).
3. **Installs prerequisites** (`network-manager`, `rfkill` if missing).
4. **Switches Netplan renderer to NetworkManager** (so Wi‑Fi is managed by NM).
5. **Unblocks and manages Wi‑Fi** (rfkill, radio on, device managed).
6. **Optionally connects to Wi‑Fi** (visible or hidden SSIDs).
7. **Prefers Ethernet over Wi‑Fi** (route metrics + autoconnect priority).
8. **Verifies connectivity** (IP, route, ping `8.8.8.8` and `google.com`).

If any step fails, you can **rollback EVERYTHING** or **rollback to the LAST SUCCESSFUL step** (e.g., undo only preference changes if that’s where it failed).


## Safety & rollback model

- Before making changes, the script:
  - **Backs up current Netplan** YAML to a run-stamped folder.
  - **Exports all NetworkManager connections** to keyfiles.
- Right before changing preference (route metrics/priorities), it **snapshots Ethernet & Wi‑Fi connection profiles** so a **partial rollback** can restore just those settings.
- On failure, you’ll be prompted to choose:
  - **1) Rollback EVERYTHING:** Restore original Netplan + pre-run NetworkManager connections.
  - **2) Rollback to LAST SUCCESSFUL step:** Typically restores pre‑preference connection profiles.
  - **3) Continue without rollback.**

> **Non-interactive mode:** With `--yes` and no explicit `--on-error`, the default is to **rollback everything** for safety.


## Requirements

- Ubuntu Server 22.04/24.04 on **Raspberry Pi 5** (or similar).
- `sudo` privileges.
- Network interface names (examples below assume `enabcm6e0` and `wlan0`).  
  You can discover them with:
  ```bash
  ip -br link
  ```


## Quick start (interactive)

```bash
chmod +x rpi5_net_setup.sh
sudo ./rpi5_net_setup.sh
```

- The script will **prompt** for missing values (Wi‑Fi SSID/PSK, hidden flag).  
- If a step fails, you’ll get a **rollback menu**.


## Non‑interactive usage (hands‑free)

```bash
sudo ./rpi5_net_setup.sh   --eth-if enabcm6e0   --wifi-if wlan0   --ssid "YourSSID"   --psk "YourWiFiPassword"   --on-error partial   --yes
```

- `--yes` suppresses prompts.  
- `--on-error` controls failure behavior: `ask | all | partial | continue` (default: `ask`, but with `--yes` it becomes `all` unless you override).

> **Security tip:** Passing passwords on the command line may leave traces in shell history and process lists. Prefer **interactive entry** (omit `--psk`) or use a protected environment (e.g., run under `tmux` and clear history).


## Command‑line options

| Option | Required | Description |
|---|:---:|---|
| `--eth-if <name>` | ✓ | Ethernet interface (e.g., `eth0`, `enabcm6e0`). |
| `--wifi-if <name>` |  | Wi‑Fi interface (e.g., `wlan0`). Auto‑detected if possible. |
| `--ssid <name>` |  | Wi‑Fi SSID to connect. If omitted, Wi‑Fi setup can be skipped. |
| `--psk <password>` |  | Wi‑Fi password (PSK). If omitted, you’ll be prompted interactively. |
| `--hidden` |  | Mark the SSID as hidden (non‑broadcast). |
| `--on-error <mode>` |  | `ask` (default) \| `all` \| `partial` \| `continue`. |
| `--yes` |  | Non‑interactive (auto‑defaults; on error = `all` unless overridden). |
| `--help` |  | Show usage help. |


## What gets changed

- **Netplan files** in `/etc/netplan/`  
  - Initially creates `01-dhcp.yaml` for quick Ethernet DHCP.  
  - Later switches to `00-network-manager.yaml` to hand control to NetworkManager.
- **NetworkManager connections** (via `nmcli`)  
  - May create/update profiles for Ethernet and the specified Wi‑Fi.
  - Sets **route metrics** (lower for Ethernet) and **autoconnect priority** (Ethernet > Wi‑Fi).

All originals are **snapshotted** so you can roll back.


## Where snapshots and logs live

- **Run state & snapshots:** `/var/lib/rpi5_net_setup/<YYYYmmdd_HHMMSS>/`
  - `orig_netplan/` — original Netplan YAML copies
  - `nm_before/` — exported pre‑run NM keyfiles (`.nm`)
  - `conn_eth_pre5.nm`, `conn_wifi_pre5.nm` — pre‑preference snapshots
- **Log file:** `/var/log/rpi5_net_setup.log`


## Verifying success

After the script finishes, check:

```bash
# Active connections
nmcli connection show --active

# IP addresses
ip -4 addr

# Routing table (Ethernet should provide the default route when plugged)
ip route

# Connectivity checks
ping -c 3 8.8.8.8
ping -c 3 google.com
```

To view priorities and metrics:

```bash
nmcli -f NAME,TYPE,CONNECTIONS,AUTOCONNECT-PRIORITY con show
nmcli -f NAME,TYPE,IP4.ROUTE-METRIC,IP6.ROUTE-METRIC con show
```

Expected: **Ethernet** has **lower** route metrics (e.g., 100) and **higher** autoconnect priority (e.g., 50) than Wi‑Fi.


## Rollback usage

If a failure occurs mid‑run, you’ll be prompted to choose rollback scope. You can also re‑run the script and it will snapshot again, allowing you to recover to the previous state.

**Manual restore** (optional):  
To manually restore a snapshot later, use the exported keyfiles and Netplan copies from the run folder, e.g.:

```bash
# Restore Netplan
sudo cp /var/lib/rpi5_net_setup/<run>/orig_netplan/*.yaml /etc/netplan/
sudo netplan generate && sudo netplan apply

# Restore NM connections
sudo nmcli con delete --active  # (be careful; or delete specific ones)
sudo nmcli connection import type keyfile file /var/lib/rpi5_net_setup/<run>/nm_before/*.nm
sudo systemctl restart NetworkManager
```

> Replace `<run>` with the specific timestamped folder you want to restore from.


## Tips for headless/SSH setups

- Consider running inside a **`tmux`** or **`screen`** session to avoid losing your shell if the network briefly resets.
- If you’re connected over **Wi‑Fi** when switching renderers, you may temporarily lose network—prefer to run over **Ethernet**.


## Troubleshooting

- **“Permissions … Netplan YAML too open”**  
  The script already sets `root:root` and `chmod 600`. If you edit manually, fix permissions:
  ```bash
  sudo chown root:root /etc/netplan/*.yaml
  sudo chmod 600 /etc/netplan/*.yaml
  ```
- **Wi‑Fi ‘unmanaged’ or ‘unavailable’**  
  Ensure NetworkManager is the renderer and device is managed:
  ```bash
  sudo systemctl restart NetworkManager
  sudo nmcli device set wlan0 managed yes
  rfkill list; sudo rfkill unblock all
  sudo ip link set wlan0 up
  ```
- **Broadcom (brcmf*) firmware messages** on RPi 5  
  Keep firmware updated and power‑cycle after updates:
  ```bash
  sudo apt update && sudo apt full-upgrade -y
  sudo reboot
  ```
- **DNS works intermittently**  
  Check that only one network manager (NetworkManager vs `systemd-networkd`) controls interfaces; let **NetworkManager** manage Wi‑Fi after the switch.


## Idempotency & re‑runs

Running the script multiple times is safe; it creates a new timestamped snapshot each time and only tweaks the settings it manages (Ethernet DHCP, NM renderer, Wi‑Fi connect, and preference metrics/priorities).


## Uninstall / revert to original behavior

Use the **rollback EVERYTHING** option from your latest run’s prompt, or perform a **manual restore** from the snapshot folder you want (see “Manual restore” above).
