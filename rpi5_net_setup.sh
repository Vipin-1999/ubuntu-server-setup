#!/usr/bin/env bash
# Ubuntu Server (Raspberry Pi 5) — Network Setup & Wi‑Fi Troubleshooting (with rollback)
# Automates: Ethernet DHCP (quick), switch to NetworkManager, Wi‑Fi setup, prefer Ethernet.
# Rollback: on failure, prompt to rollback ALL or to the LAST SUCCESSFUL step.
# Tested on Ubuntu Server 22.04/24.04. Requires sudo/root.
#
# Changelog:
# - Adds transactional snapshots:
#   * Original Netplan backup
#   * Pre-Step-5 (Prefer Ethernet) NetworkManager connection exports for ETH/WIFI
# - Provides rollback-all and rollback-partial flows.

set -u
umask 022

LOG="/var/log/rpi5_net_setup.log"
STATE_BASE="/var/lib/rpi5_net_setup"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
STATE_DIR="$STATE_BASE/$RUN_ID"
mkdir -p "$STATE_DIR" >/dev/null 2>&1 || true

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*" | tee -a "$LOG"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*" | tee -a "$LOG"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*" | tee -a "$LOG"; }
err()   { echo -e "\033[1;31m[ERROR]\033[0m $*" | tee -a "$LOG"; }
rule()  { echo "------------------------------------------------------------" | tee -a "$LOG"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "This script needs root. Re-running with sudo ..."
    exec sudo -E bash "$0" "$@"
  fi
}

# Defaults (can be overridden)
ETH_IF=""
WIFI_IF=""
SSID=""
PSK=""
HIDDEN="no"
ETH_CON=""
WIFI_CON=""
YES=0
ON_ERROR="ask"  # ask|all|partial|continue

# Track state for partial rollback
LAST_SUCCESS="NONE"
LAST_SUCCESS_LABEL=""
CREATED_WIFI_CON=0  # 1 if we created Wi-Fi connection profile in this run
SNAP_ETH_PRE5=""
SNAP_WIFI_PRE5=""
ETH_UUID_PRE5=""
WIFI_UUID_PRE5=""
# Snapshot of pre-run NM connections
BEFORE_UUIDS_FILE="$STATE_DIR/nm_before_uuids.txt"
NM_BEFORE_DIR="$STATE_DIR/nm_before"
mkdir -p "$NM_BEFORE_DIR"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --eth-if <name>        Ethernet interface (e.g., eth0, enabcm6e0)
  --wifi-if <name>       Wi‑Fi interface (e.g., wlan0)
  --ssid <name>          Wi‑Fi SSID to connect
  --psk <password>       Wi‑Fi password (PSK)
  --hidden               Marks the Wi‑Fi as hidden (non-broadcast)
  --on-error <mode>      ask|all|partial|continue (default: ask)
  --yes                  Non-interactive; accept prompts and proceed (defaults on error: ALL)
  --help                 Show this help

Examples:
  $0 --eth-if enabcm6e0 --wifi-if wlan0
  $0 --ssid MyWiFi --psk 'mypassword' --hidden --yes
  $0 --on-error partial --yes
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --eth-if) ETH_IF="${2:-}"; shift 2;;
      --wifi-if) WIFI_IF="${2:-}"; shift 2;;
      --ssid) SSID="${2:-}"; shift 2;;
      --psk) PSK="${2:-}"; shift 2;;
      --hidden) HIDDEN="yes"; shift 1;;
      --on-error) ON_ERROR="${2:-ask}"; shift 2;;
      --yes) YES=1; shift 1;;
      --help|-h) usage; exit 0;;
      *) err "Unknown option: $1"; usage; exit 1;;
    esac
  done
}

snapshot_pre_run_nm() {
  rule
  info "Snapshotting pre-run NetworkManager connections ..."
  nmcli -t -f UUID,NAME,TYPE con show | tee "$BEFORE_UUIDS_FILE" >/dev/null
  # Export each connection as a keyfile
  while IFS=: read -r UUID NAME TYPE; do
    [ -z "$UUID" ] && continue
    # Export to keyfile
    nmcli connection export "$UUID" > "$NM_BEFORE_DIR/${UUID}.nm" 2>>"$LOG" || true
  done < <(nmcli -t -f UUID,NAME,TYPE con show)
  ok "Snapshot saved: $NM_BEFORE_DIR"
}

detect_interfaces() {
  rule
  info "Detecting network interfaces ..."
  if [ -z "$ETH_IF" ]; then
    ETH_IF="$(ip -br link | awk '/^(e(n|th)|enp|eno|ens|enabcm)/{print $1; exit}')"
  fi
  if [ -z "$WIFI_IF" ]; then
    WIFI_IF="$(ip -br link | awk '/^(wl|wlan)/{print $1; exit}')"
  fi
  [ -n "$ETH_IF" ] && ok "Detected Ethernet: $ETH_IF" || warn "No Ethernet interface auto-detected."
  [ -n "$WIFI_IF" ] && ok "Detected Wi‑Fi: $WIFI_IF"   || warn "No Wi‑Fi interface auto-detected."
  rule

  if [ $YES -eq 0 ]; then
    read -r -p "Ethernet interface to use [$ETH_IF]: " ans || true
    ETH_IF="${ans:-$ETH_IF}"
    read -r -p "Wi‑Fi interface to use [$WIFI_IF]: " ans || true
    WIFI_IF="${ans:-$WIFI_IF}"
  fi

  if [ -z "$ETH_IF" ]; then
    err "Ethernet interface not set. Re-run with --eth-if <iface>."
    exit 1
  fi
}

ensure_packages() {
  rule
  info "Ensuring required packages (network-manager, rfkill) ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >>"$LOG" 2>&1 || true
  if ! dpkg -s network-manager >/dev/null 2>&1; then
    apt-get install -y network-manager >>"$LOG" 2>&1 || { err "Failed to install network-manager"; return 1; }
  fi
  if ! dpkg -s rfkill >/dev/null 2>&1; then
    apt-get install -y rfkill >>"$LOG" 2>&1 || { err "Failed to install rfkill"; return 1; }
  fi
  ok "Package check complete."
}

apply_netplan_safe() {
  netplan generate >>"$LOG" 2>&1 || { err "netplan generate failed"; return 1; }
  netplan apply    >>"$LOG" 2>&1 || { err "netplan apply failed"; return 1; }
  return 0
}

backup_original_netplan() {
  rule
  info "Backing up current Netplan configuration ..."
  local dir="$STATE_DIR/orig_netplan"
  mkdir -p "$dir"
  shopt -s nullglob
  local any=0
  for y in /etc/netplan/*.yaml; do
    cp -a "$y" "$dir"/
    any=1
  done
  shopt -u nullglob
  if [ $any -eq 1 ]; then
    ok "Original Netplan saved to $dir"
  else
    warn "No existing Netplan YAML found to back up."
  fi
}

ethernet_quick_dhcp() {
  rule
  info "Step S1: Quickest path online — DHCP on Ethernet via systemd-networkd"
  local f="/etc/netplan/01-dhcp.yaml"
  cat > "$f" <<YAML
network:
  version: 2
  renderer: networkd
  ethernets:
    ${ETH_IF}:
      dhcp4: true
      optional: true
YAML
  chown root:root "$f"
  chmod 600 "$f"

  if apply_netplan_safe; then
    ok "Ethernet setup complete."
  else
    err "Failed to apply Ethernet DHCP config."
    return 1
  fi

  info "Verifying Ethernet connectivity ..."
  ip -4 addr show "$ETH_IF" | tee -a "$LOG"
  ip route | tee -a "$LOG"

  if ping -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
    ok "ICMP to 8.8.8.8 reachable."
  else
    warn "Ping to 8.8.8.8 failed."
  fi
  if ping -c 3 -W 3 google.com >/dev/null 2>&1; then
    ok "DNS + ICMP to google.com OK."
    ok "Ethernet connection successful."
  else
    warn "Ping to google.com failed (DNS or connectivity issue)."
  fi
}

switch_to_networkmanager() {
  rule
  info "Step S3: Switching Netplan renderer to NetworkManager"
  local backup="/etc/netplan/backup_${RUN_ID}"
  mkdir -p "$backup"
  # Move any YAML aside (we also saved a copy in STATE_DIR/orig_netplan)
  shopt -s nullglob
  local moved=0
  for y in /etc/netplan/*.yaml; do
    mv "$y" "$backup"/
    moved=1
  done
  shopt -u nullglob
  [ $moved -eq 1 ] && ok "Moved existing YAML to $backup" || warn "No YAML to move."

  local f="/etc/netplan/00-network-manager.yaml"
  cat > "$f" <<'YAML'
network:
  version: 2
  renderer: NetworkManager
YAML
  chown root:root "$f"
  chmod 600 "$f"

  if apply_netplan_safe; then
    ok "Renderer switched to NetworkManager."
  else
    err "Failed to switch renderer to NetworkManager."
    # Attempt immediate restore
    shopt -s nullglob; mv "$backup"/*.yaml /etc/netplan/ 2>/dev/null || true; shopt -u nullglob
    apply_netplan_safe || true
    return 1
  fi

  systemctl enable NetworkManager >>"$LOG" 2>&1 || true
  systemctl restart NetworkManager >>"$LOG" 2>&1 || true
  ok "NetworkManager restarted."
}

wifi_unblock_and_manage() {
  rule
  info "Step S4: Ensure Wi‑Fi not blocked and mark device managed"
  nmcli radio wifi on  >>"$LOG" 2>&1 || true
  rfkill unblock all   >>"$LOG" 2>&1 || true
  if [ -n "$WIFI_IF" ]; then
    ip link set "$WIFI_IF" up >>"$LOG" 2>&1 || true
    nmcli device set "$WIFI_IF" managed yes >>"$LOG" 2>&1 || true
  fi
  nmcli device status | tee -a "$LOG"
  ok "Wi‑Fi radios checked; device managed."
}

wifi_scan() {
  rule
  info "Step S5: Scanning for nearby Wi‑Fi networks"
  if nmcli dev wifi rescan ${WIFI_IF:+ifname "$WIFI_IF"} >>"$LOG" 2>&1; then
    nmcli -f SSID,BSSID,CHAN,RATE,SIGNAL,SECURITY dev wifi list ${WIFI_IF:+ifname "$WIFI_IF"} | tee -a "$LOG"
    ok "Wi‑Fi scan complete."
  else
    warn "Wi‑Fi scan failed (interface unavailable?)."
  fi
}

wifi_connect() {
  rule
  info "Step S6: Wi‑Fi connection setup"
  if [ -z "$WIFI_IF" ]; then
    warn "No Wi‑Fi interface specified/detected. Skipping Wi‑Fi setup."
    return 0
  fi

  if [ $YES -eq 0 ]; then
    read -r -p "Configure Wi‑Fi now? [Y/n]: " ans || true
    ans="${ans:-Y}"
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
      warn "Skipping Wi‑Fi configuration by user choice."
      return 0
    fi
  fi

  if [ -z "$SSID" ]; then
    if [ $YES -eq 0 ]; then
      read -r -p "Enter Wi‑Fi SSID: " SSID || true
    fi
  fi
  if [ -z "$SSID" ]; then
    warn "SSID not provided. Skipping Wi‑Fi configuration."
    return 0
  fi

  if [ -z "$PSK" ]; then
    if [ $YES -eq 0 ]; then
      read -sr -p "Enter Wi‑Fi password (PSK): " PSK || true
      echo
    fi
  fi

  if [ $YES -eq 0 ]; then
    read -r -p "Is the SSID hidden (non-broadcast)? [y/N]: " ans || true
    if [[ "$ans" =~ ^[Yy]$ ]]; then HIDDEN="yes"; else HIDDEN="no"; fi
  fi

  WIFI_CON="$SSID"
  local connected=0
  if [ "$HIDDEN" = "yes" ]; then
    nmcli con add type wifi ifname "$WIFI_IF" con-name "$WIFI_CON" ssid "$SSID" >>"$LOG" 2>&1 && CREATED_WIFI_CON=1 || true
    nmcli con modify "$WIFI_CON" wifi.hidden yes >>"$LOG" 2>&1 || true
    if [ -n "$PSK" ]; then
      nmcli con modify "$WIFI_CON" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK" >>"$LOG" 2>&1 || true
    fi
    if nmcli con up "$WIFI_CON" >>"$LOG" 2>&1; then connected=1; fi
  else
    if nmcli dev wifi connect "$SSID" ${PSK:+password "$PSK"} ifname "$WIFI_IF" >>"$LOG" 2>&1; then
      connected=1
    else
      warn "nmcli connect failed; trying manual profile ..."
      nmcli con add type wifi ifname "$WIFI_IF" con-name "$WIFI_CON" ssid "$SSID" >>"$LOG" 2>&1 && CREATED_WIFI_CON=1 || true
      if [ -n "$PSK" ]; then
        nmcli con modify "$WIFI_CON" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK" >>"$LOG" 2>&1 || true
      fi
      if nmcli con up "$WIFI_CON" >>"$LOG" 2>&1; then connected=1; fi
    fi
  fi

  nmcli device status | tee -a "$LOG"

  if [ $connected -eq 1 ]; then
    ok "Connected to SSID '$SSID'."
    return 0
  else
    err "Failed to connect to SSID '$SSID'."
    return 1
  fi
}

snapshot_prefer_state() {
  # Snapshot ETH and WIFI connections before modifying preference (route-metric, priority)
  rule
  info "Snapshotting current connection profiles before preference changes ..."
  ETH_CON="$(nmcli -t -f NAME,TYPE con show | awk -F: '$2=="ethernet"{print $1; exit}')"
  if [ -z "$ETH_CON" ]; then
    ETH_CON="ethernet-dhcp"
    nmcli con add type ethernet ifname "$ETH_IF" con-name "$ETH_CON" >>"$LOG" 2>&1 || true
  fi
  # Identify UUIDs
  ETH_UUID_PRE5="$(nmcli -t -f NAME,UUID con show | awk -F: -v n="$ETH_CON" '$1==n{print $2; exit}')"
  WIFI_CON="${WIFI_CON:-$(nmcli -t -f NAME,TYPE con show | awk -F: '$2=="wifi"{print $1; exit}') }"
  WIFI_UUID_PRE5="$(nmcli -t -f NAME,UUID con show | awk -F: -v n="$WIFI_CON" '$1==n{print $2; exit}')"

  SNAP_ETH_PRE5="$STATE_DIR/conn_eth_pre5.nm"
  SNAP_WIFI_PRE5="$STATE_DIR/conn_wifi_pre5.nm"

  if [ -n "$ETH_UUID_PRE5" ]; then nmcli connection export "$ETH_UUID_PRE5" > "$SNAP_ETH_PRE5" 2>>"$LOG" || true; fi
  if [ -n "$WIFI_UUID_PRE5" ]; then nmcli connection export "$WIFI_UUID_PRE5" > "$SNAP_WIFI_PRE5" 2>>"$LOG" || true; fi
  ok "Pre-preference snapshots saved."
}

prefer_ethernet() {
  rule
  info "Step S7: Prefer Ethernet over Wi‑Fi (route metrics + autoconnect priority)"
  # Route metrics: lower is preferred
  nmcli con modify "$ETH_CON"  ipv4.route-metric 100 ipv6.route-metric 100 >>"$LOG" 2>&1 || return 1
  if [ -n "$WIFI_CON" ]; then
    nmcli con modify "$WIFI_CON" ipv4.route-metric 600 ipv6.route-metric 600 >>"$LOG" 2>&1 || return 1
  fi
  # Autoconnect priorities
  nmcli con modify "$ETH_CON"  connection.autoconnect yes  connection.autoconnect-priority 50 >>"$LOG" 2>&1 || return 1
  if [ -n "$WIFI_CON" ]; then
    nmcli con modify "$WIFI_CON" connection.autoconnect yes  connection.autoconnect-priority 10 >>"$LOG" 2>&1 || return 1
  fi
  nmcli con up "$ETH_CON" >>"$LOG" 2>&1 || true
  [ -n "$WIFI_CON" ] && nmcli con up "$WIFI_CON" >>"$LOG" 2>&1 || true
  ip route | tee -a "$LOG"
  ok "Preference set: Ethernet should be default when available."
}

verify_final() {
  rule
  info "Step S8: Final verification"
  ip -4 addr show "$ETH_IF" | tee -a "$LOG" || true
  nmcli connection show --active | tee -a "$LOG" || true
  ip route | tee -a "$LOG" || true

  local ok_any=0
  if ping -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
    ok "ICMP to 8.8.8.8 reachable."
    ok_any=1
  else
    warn "Ping to 8.8.8.8 failed."
  fi
  if ping -c 3 -W 3 google.com >/dev/null 2>&1; then
    ok "DNS + ICMP to google.com OK."
    ok_any=1
  else
    warn "Ping to google.com failed."
  fi
  [ $ok_any -eq 1 ] || return 1
}

rollback_all() {
  rule
  warn "Rolling back ALL changes ..."

  # Restore original Netplan
  local dir="$STATE_DIR/orig_netplan"
  if [ -d "$dir" ]; then
    rm -f /etc/netplan/*.yaml 2>/dev/null || true
    shopt -s nullglob
    for y in "$dir"/*.yaml; do
      cp -a "$y" /etc/netplan/
    done
    shopt -u nullglob
    apply_netplan_safe || true
    ok "Netplan restored."
  else
    warn "No original Netplan snapshot found; leaving current Netplan as-is."
  fi

  # Restore NetworkManager connections to pre-run snapshot
  if [ -s "$BEFORE_UUIDS_FILE" ]; then
    # Delete any connection not in BEFORE list
    mapfile -t BEFORE_UUIDS < <(awk -F: '{print $1}' "$BEFORE_UUIDS_FILE")
    mapfile -t NOW_UUIDS < <(nmcli -t -f UUID con show | awk -F: '{print $1}')
    for u in "${NOW_UUIDS[@]}"; do
      skip=0
      for b in "${BEFORE_UUIDS[@]}"; do
        if [ "$u" = "$b" ]; then skip=1; break; fi
      done
      if [ $skip -eq 0 ]; then
        nmcli con delete uuid "$u" >>"$LOG" 2>&1 || true
      fi
    done
    # Re-load all original connections
    shopt -s nullglob
    for f in "$NM_BEFORE_DIR"/*.nm; do
      nmcli connection import type keyfile file "$f" >>"$LOG" 2>&1 || true
    done
    shopt -u nullglob
    ok "NetworkManager connections restored to pre-run state."
  else
    warn "No pre-run NM snapshot found; skipping connection restore."
  fi

  systemctl restart NetworkManager >>"$LOG" 2>&1 || true
  ok "Rollback ALL complete."
}

restore_prefer_snapshot() {
  # Restore only the connection settings we changed in S7
  rule
  warn "Rolling back preference changes to last successful step (pre-S7) ..."
  if [ -n "$ETH_UUID_PRE5" ] && [ -f "$SNAP_ETH_PRE5" ]; then
    nmcli con delete uuid "$ETH_UUID_PRE5" >>"$LOG" 2>&1 || true
    nmcli connection import type keyfile file "$SNAP_ETH_PRE5" >>"$LOG" 2>&1 || true
  fi
  if [ -n "$WIFI_UUID_PRE5" ] && [ -f "$SNAP_WIFI_PRE5" ]; then
    nmcli con delete uuid "$WIFI_UUID_PRE5" >>"$LOG" 2>&1 || true
    nmcli connection import type keyfile file "$SNAP_WIFI_PRE5" >>"$LOG" 2>&1 || true
  fi
  systemctl restart NetworkManager >>"$LOG" 2>&1 || true
  ok "Preference-level rollback complete."
}

rollback_to_last_success() {
  case "$LAST_SUCCESS" in
    S6)
      # Last fully successful step was Wi‑Fi connected; undo only S7 preference tweaks.
      restore_prefer_snapshot
      ;;
    S3|S4|S5)
      # Up to NM switch / Wi‑Fi unblock / scan — nothing persistent beyond NM renderer.
      warn "No partial rollback needed beyond step $LAST_SUCCESS_LABEL."
      ;;
    S1|S2)
      # Only Ethernet DHCP YAML created; nothing more to rollback partially.
      warn "Partial rollback at this point does not revert Ethernet YAML. Use ALL for full restore."
      ;;
    *)
      warn "No known checkpoint to roll back to."
      ;;
  esac
}

handle_error() {
  local step_id="$1"
  local label="$2"

  err "Failure occurred at step $label ($step_id)."
  local choice="$ON_ERROR"

  if [ "$ON_ERROR" = "ask" ] && [ $YES -eq 0 ]; then
    echo
    echo "Choose an action:"
    echo "  1) Rollback EVERYTHING"
    echo "  2) Rollback to LAST SUCCESSFUL step"
    echo "  3) Continue without rollback"
    read -r -p "Enter 1/2/3 [1]: " ans || true
    case "${ans:-1}" in
      1) choice="all";;
      2) choice="partial";;
      3) choice="continue";;
      *) choice="all";;
    esac
  elif [ $YES -eq 1 ] && [ "$ON_ERROR" = "ask" ]; then
    # Non-interactive default
    choice="all"
  fi

  case "$choice" in
    all) rollback_all;;
    partial) rollback_to_last_success;;
    continue) warn "Continuing without rollback per user choice." ;;
    *) rollback_all;;
  esac

  err "Exiting due to failure."
  exit 1
}

step() {
  # step <ID> <Label> <command...>
  local id="$1"; local label="$2"; shift 2
  "$@"
  local rc=$?
  if [ $rc -ne 0 ]; then
    handle_error "$id" "$label"
  fi
  LAST_SUCCESS="$id"
  LAST_SUCCESS_LABEL="$label"
}

main() {
  require_root "$@"
  parse_args "$@"

  rule; info "Ubuntu Server (RPi 5) networking automation (with rollback) starting ..."; rule

  # Pre-run snapshots
  snapshot_pre_run_nm
  backup_original_netplan

  detect_interfaces

  step "S1" "Ethernet DHCP" ethernet_quick_dhcp
  step "S2" "Ensure Packages" ensure_packages
  step "S3" "Switch to NetworkManager" switch_to_networkmanager
  step "S4" "Wi‑Fi unblock/manage" wifi_unblock_and_manage
  step "S5" "Wi‑Fi scan" wifi_scan
  step "S6" "Wi‑Fi connect" wifi_connect

  # Snapshot before preference changes for partial rollback
  snapshot_prefer_state
  step "S7" "Prefer Ethernet" prefer_ethernet
  step "S8" "Final verification" verify_final

  rule; ok "All steps completed successfully. Log saved to $LOG"; rule
}

main "$@"
