#!/usr/bin/env bash
# Ubuntu Server (Raspberry Pi 5) — Networking Automation
# Rollback Edition v5 — Strict ordering + auto-install deps after Ethernet + retries
#
# Changelog:
# - Ethernet first: Bring up Ethernet via Netplan and verify IP + default route + TCP connectivity.
# - Auto-install tools after Ethernet is up (nmcli, rfkill, ping, etc.).
# - Immediate rollback prompt on ANY failure (ALL / LAST SUCCESSFUL / CONTINUE).
# - Wi‑Fi scan and connect each retry up to 3 times with diagnostics between attempts.
#
# Tested on Ubuntu Server 22.04/24.04 for Raspberry Pi 5. Requires sudo/root.

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

# Defaults (overridable via flags)
ETH_IF=""
WIFI_IF=""
SSID=""
PSK=""
HIDDEN="no"
ETH_CON=""
WIFI_CON=""
YES=0
ON_ERROR="ask"  # ask|all|partial|continue

# State for rollback/snapshots
LAST_SUCCESS="NONE"
LAST_SUCCESS_LABEL=""
SNAP_ETH_PREPREF=""
SNAP_WIFI_PREPREF=""
ETH_UUID_PREPREF=""
WIFI_UUID_PREPREF=""
BEFORE_UUIDS_FILE="$STATE_DIR/nm_before_uuids.txt"
NM_BEFORE_DIR="$STATE_DIR/nm_before"
mkdir -p "$NM_BEFORE_DIR" >/dev/null 2>&1 || true

APT_UPDATED=0

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --eth-if <iface>      Ethernet interface (e.g., eth0, enabcm6e0)
  --wifi-if <iface>     Wi‑Fi interface (e.g., wlan0)
  --ssid <name>         Wi‑Fi SSID
  --psk <password>      Wi‑Fi password (PSK)
  --hidden              SSID is hidden (non-broadcast)
  --on-error <mode>     ask|all|partial|continue (default: ask; with --yes, default becomes all)
  --yes                 Non-interactive; accept defaults; on error => all (unless overridden)
  --help                Show this help

Examples:
  $0 --eth-if enabcm6e0 --wifi-if wlan0
  $0 --ssid MyWiFi --psk 'mypassword' --hidden --yes
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

# ---------- Package helpers (post-Ethernet only) ----------

apt_install() {
  # apt_install <pkg1> [pkg2 ...]
  export DEBIAN_FRONTEND=noninteractive
  if [ $APT_UPDATED -eq 0 ]; then
    info "Updating apt package lists ..."
    apt-get update -y >>"$LOG" 2>&1 || { err "apt-get update failed."; return 1; }
    APT_UPDATED=1
  fi
  info "Installing packages: $*"
  apt-get install -y "$@" >>"$LOG" 2>&1 || { err "Failed to install: $*"; return 1; }
  return 0
}

pkg_for_cmd() {
  # Map command to Debian/Ubuntu package
  case "$1" in
    nmcli) echo "network-manager" ;;
    rfkill) echo "rfkill" ;;
    netplan) echo "netplan.io" ;;
    ip) echo "iproute2" ;;
    ping) echo "iputils-ping" ;;
    getent) echo "libc-bin" ;;
    awk) echo "gawk" ;;
    sed) echo "sed" ;;
    grep) echo "grep" ;;
    tee) echo "coreutils" ;;
    systemctl) echo "systemd" ;;
    *) echo "" ;;
  esac
}

ensure_cmd() {
  # ensure_cmd <command>
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  local pkg
  pkg="$(pkg_for_cmd "$cmd")"
  if [ -z "$pkg" ]; then
    err "Required command '$cmd' not found and no package mapping is known."
    return 2
  fi
  apt_install "$pkg" || return 1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "Command '$cmd' still not available after installing '$pkg'."
    return 2
  fi
  ok "Installed '$pkg' to provide '$cmd'."
  return 0
}

need_cmds() {
  # need_cmds <cmd1> <cmd2> ...
  local c
  for c in "$@"; do
    ensure_cmd "$c" || return 1
  done
  return 0
}

# ---------- ROLLBACK ----------

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
    netplan generate >>"$LOG" 2>&1 || true
    netplan apply    >>"$LOG" 2>&1 || true
    ok "Netplan restored."
  else
    warn "No original Netplan snapshot found; leaving current Netplan as-is."
  fi

  # Restore NetworkManager connections to pre-run snapshot (if nmcli exists now)
  if command -v nmcli >/dev/null 2>&1 && [ -s "$BEFORE_UUIDS_FILE" ]; then
    mapfile -t BEFORE_UUIDS < <(awk -F: '{print $1}' "$BEFORE_UUIDS_FILE")
    mapfile -t NOW_UUIDS < <(nmcli -t -f UUID con show | awk -F: '{print $1}')
    for u in "${NOW_UUIDS[@]}"; do
      skip=0
      for b in "${BEFORE_UUIDS[@]}"; do
        if [ "$u" = "$b" ]; then skip=1; break; fi
      done
      if [ $skip -eq 0 ]; then nmcli con delete uuid "$u" >>"$LOG" 2>&1 || true; fi
    done
    shopt -s nullglob
    for f in "$NM_BEFORE_DIR"/*.nm; do
      nmcli connection import type keyfile file "$f" >>"$LOG" 2>&1 || true
    done
    shopt -u nullglob
    systemctl restart NetworkManager >>"$LOG" 2>&1 || true
    ok "NetworkManager connections restored to pre-run state."
  else
    warn "nmcli not available or no NM snapshot; skipping connection restore."
  fi

  ok "Rollback ALL complete."
}

restore_preference_snapshot() {
  rule
  warn "Rolling back preference changes to last successful step (preference snapshot) ..."
  if command -v nmcli >/dev/null 2>&1; then
    if [ -n "$ETH_UUID_PREPREF" ] && [ -f "$SNAP_ETH_PREPREF" ]; then
      nmcli con delete uuid "$ETH_UUID_PREPREF" >>"$LOG" 2>&1 || true
      nmcli connection import type keyfile file "$SNAP_ETH_PREPREF" >>"$LOG" 2>&1 || true
    fi
    if [ -n "$WIFI_UUID_PREPREF" ] && [ -f "$SNAP_WIFI_PREPREF" ]; then
      nmcli con delete uuid "$WIFI_UUID_PREPREF" >>"$LOG" 2>&1 || true
      nmcli connection import type keyfile file "$SNAP_WIFI_PREPREF" >>"$LOG" 2>&1 || true
    fi
    systemctl restart NetworkManager >>"$LOG" 2>&1 || true
  fi
  ok "Preference-level rollback complete."
}

rollback_to_last_success() {
  case "$LAST_SUCCESS" in
    PREF_SNAPSHOT|S6|S5|S4|S3|SNAP)
      # If we reached snapshot stages, undo preference if it was taken.
      restore_preference_snapshot
      ;;
    S2|S1)
      warn "Partial rollback at this point does not revert initial Ethernet YAML. Use ALL for full restore."
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

step_retry() {
  # step_retry <ID> <Label> <RETRIES> <command...>
  local id="$1"; local label="$2"; local retries="$3"; shift 3
  local i rc
  for i in $(seq 1 "$retries"); do
    info "$label: attempt $i/$retries"
    "$@"
    rc=$?
    if [ $rc -eq 0 ]; then
      LAST_SUCCESS="$id"
      LAST_SUCCESS_LABEL="$label"
      return 0
    fi
    warn "$label failed on attempt $i/$retries."
    sleep 2
  done
  handle_error "$id" "$label"
}

# ---------- CORE ----------

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
  if [ $any -eq 1 ]; then ok "Original Netplan saved to $dir"; else warn "No existing Netplan YAML found to back up."; fi
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
  if [ -z "$ETH_IF" ]; then err "Ethernet interface not set. Re-run with --eth-if <iface>."; exit 1; fi
}

apply_netplan_safe() {
  netplan generate >>"$LOG" 2>&1 || { err "netplan generate failed"; return 1; }
  netplan apply    >>"$LOG" 2>&1 || { err "netplan apply failed"; return 1; }
  return 0
}

ethernet_dhcp() {
  rule
  info "Step S1: Bring up Ethernet with DHCP (systemd-networkd)"
  # Use only base tools (netplan, ip, bash) before network-dependent package installs
  cat > "/etc/netplan/01-dhcp.yaml" <<YAML
network:
  version: 2
  renderer: networkd
  ethernets:
    ${ETH_IF}:
      dhcp4: true
      optional: true
YAML
  chown root:root /etc/netplan/01-dhcp.yaml
  chmod 600 /etc/netplan/01-dhcp.yaml

  if ! apply_netplan_safe; then
    err "Failed to apply Ethernet DHCP config."
    return 1
  fi

  sleep 2
  info "Verifying Ethernet link/IP/default route/connectivity ..."
  local has_ip has_def
  has_ip=$(ip -4 addr show "$ETH_IF" | awk '/inet /{print $2}' | wc -l)
  has_def=$(ip -4 route show default | wc -l)
  if [ "$has_ip" -gt 0 ]; then ok "IPv4 assigned on $ETH_IF."; else err "No IPv4 address on $ETH_IF."; return 1; fi
  if [ "$has_def" -gt 0 ]; then ok "Default route exists."; else err "No default route."; return 1; fi

  # Connectivity check without requiring 'ping'
  if timeout 3 bash -c 'echo > /dev/tcp/8.8.8.8/53' 2>/dev/null; then
    ok "TCP connectivity test to 8.8.8.8:53 successful."
  else
    err "TCP connectivity test to 8.8.8.8:53 failed."
    return 1
  fi

  # DNS resolution (optional; may fail if resolvers not yet set)
  if command -v getent >/dev/null 2>&1 && getent hosts google.com >/dev/null 2>&1; then
    ok "DNS resolution works (google.com)."
  else
    warn "DNS resolution not confirmed (getent missing or resolver issue)."
  fi

  ok "Ethernet connection successful."
}

install_core_packages() {
  rule
  info "Step S2: Installing core packages likely needed (network-manager, rfkill, iputils-ping)"
  apt_install network-manager rfkill iputils-ping || return 1
  ok "Core packages installed."
}

snapshot_pre_run_nm() {
  rule
  info "Snapshotting pre-run NetworkManager connections ..."
  need_cmds nmcli || return 1
  nmcli -t -f UUID,NAME,TYPE con show | tee "$BEFORE_UUIDS_FILE" >/dev/null
  while IFS=: read -r UUID NAME TYPE; do
    [ -z "$UUID" ] && continue
    nmcli connection export "$UUID" > "$NM_BEFORE_DIR/${UUID}.nm" 2>>"$LOG" || true
  done < <(nmcli -t -f UUID,NAME,TYPE con show)
  ok "Snapshot saved: $NM_BEFORE_DIR"
}

switch_to_networkmanager() {
  rule
  info "Step S3: Switch Netplan renderer to NetworkManager"
  need_cmds netplan nmcli systemctl || return 1

  local backup="/etc/netplan/backup_${RUN_ID}"
  mkdir -p "$backup"
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

  if ! apply_netplan_safe; then
    err "Failed to switch renderer to NetworkManager."
    # Restore immediately
    shopt -s nullglob; mv "$backup"/*.yaml /etc/netplan/ 2>/dev/null || true; shopt -u nullglob
    apply_netplan_safe || true
    return 1
  fi

  systemctl enable NetworkManager >>"$LOG" 2>&1 || true
  systemctl restart NetworkManager >>"$LOG" 2>&1 || true
  ok "NetworkManager active."
}

wifi_unblock_and_manage() {
  rule
  info "Step S4: Ensure Wi‑Fi not blocked and mark device as managed"
  need_cmds nmcli rfkill ip || return 1
  nmcli radio wifi on  >>"$LOG" 2>&1 || true
  rfkill unblock all   >>"$LOG" 2>&1 || true
  if [ -n "$WIFI_IF" ]; then
    ip link set "$WIFI_IF" up >>"$LOG" 2>&1 || true
    nmcli device set "$WIFI_IF" managed yes >>"$LOG" 2>&1 || true
  fi
  nmcli device status | tee -a "$LOG"
  ok "Wi‑Fi radios checked; device managed."
}

wifi_scan_once() {
  # Single attempt helper for step_retry
  rfkill list | tee -a "$LOG" || true
  ip link show "$WIFI_IF" | tee -a "$LOG" || true
  if nmcli dev wifi rescan ifname "$WIFI_IF" >>"$LOG" 2>&1; then
    nmcli -f SSID,BSSID,CHAN,RATE,SIGNAL,SECURITY dev wifi list ifname "$WIFI_IF" | tee -a "$LOG"
    return 0
  fi
  # Prep for next retry
  rfkill unblock all >>"$LOG" 2>&1 || true
  ip link set "$WIFI_IF" up >>"$LOG" 2>&1 || true
  sleep 2
  return 1
}

wifi_scan() {
  rule
  info "Step S5: Wi‑Fi scan (with retries)"
  need_cmds nmcli rfkill ip || return 1
  wifi_scan_once
}

wifi_connect_once() {
  # Single attempt helper for step_retry
  if [ -z "$WIFI_IF" ]; then
    warn "No Wi‑Fi interface specified/detected. Skipping Wi‑Fi setup."
    return 0
  fi

  if [ -z "$SSID" ]; then
    warn "SSID not provided. Skipping Wi‑Fi configuration."
    return 0
  fi

  WIFI_CON="$SSID"
  local connected=0

  if [ "$HIDDEN" = "yes" ]; then
    nmcli con add type wifi ifname "$WIFI_IF" con-name "$WIFI_CON" ssid "$SSID" >>"$LOG" 2>&1 || true
    nmcli con modify "$WIFI_CON" wifi.hidden yes >>"$LOG" 2>&1 || true
    if [ -n "$PSK" ]; then
      nmcli con modify "$WIFI_CON" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK" >>"$LOG" 2>&1 || true
    fi
    if nmcli con up "$WIFI_CON" >>"$LOG" 2>&1; then connected=1; fi
  else
    if nmcli dev wifi connect "$SSID" ${PSK:+password "$PSK"} ifname "$WIFI_IF" >>"$LOG" 2>&1; then
      connected=1
    else
      nmcli con add type wifi ifname "$WIFI_IF" con-name "$WIFI_CON" ssid "$SSID" >>"$LOG" 2>&1 || true
      if [ -n "$PSK" ]; then
        nmcli con modify "$WIFI_CON" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK" >>"$LOG" 2>&1 || true
      fi
      if nmcli con up "$WIFI_CON" >>"$LOG" 2>&1; then connected=1; fi
    fi
  fi

  nmcli device status | tee -a "$LOG" || true
  [ $connected -eq 1 ] && return 0 || return 1
}

wifi_connect() {
  rule
  info "Step S6: Wi‑Fi connection setup (with retries)"
  need_cmds nmcli || return 1

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

  if [ -z "$SSID" ] && [ $YES -eq 0 ]; then
    read -r -p "Enter Wi‑Fi SSID: " SSID || true
  fi
  if [ -z "$SSID" ]; then
    warn "SSID not provided. Skipping Wi‑Fi configuration."
    return 0
  fi

  if [ -z "$PSK" ] && [ $YES -eq 0 ]; then
    read -sr -p "Enter Wi‑Fi password (PSK): " PSK || true
    echo
  fi

  if [ $YES -eq 0 ]; then
    read -r -p "Is the SSID hidden (non-broadcast)? [y/N]: " ans || true
    if [[ "$ans" =~ ^[Yy]$ ]]; then HIDDEN="yes"; else HIDDEN="no"; fi
  fi

  wifi_connect_once
}

snapshot_preference_state() {
  rule
  info "Snapshotting connection profiles before preference changes ..."
  need_cmds nmcli || return 1
  ETH_CON="$(nmcli -t -f NAME,TYPE con show | awk -F: '$2=="ethernet"{print $1; exit}')"
  if [ -z "$ETH_CON" ]; then
    ETH_CON="ethernet-dhcp"
    nmcli con add type ethernet ifname "$ETH_IF" con-name "$ETH_CON" >>"$LOG" 2>&1 || true
  fi
  ETH_UUID_PREPREF="$(nmcli -t -f NAME,UUID con show | awk -F: -v n="$ETH_CON" '$1==n{print $2; exit}')"
  WIFI_CON="${WIFI_CON:-$(nmcli -t -f NAME,TYPE con show | awk -F: '$2=="wifi"{print $1; exit}') }"
  WIFI_UUID_PREPREF="$(nmcli -t -f NAME,UUID con show | awk -F: -v n="$WIFI_CON" '$1==n{print $2; exit}')"

  SNAP_ETH_PREPREF="$STATE_DIR/conn_eth_prepref.nm"
  SNAP_WIFI_PREPREF="$STATE_DIR/conn_wifi_prepref.nm"

  if [ -n "$ETH_UUID_PREPREF" ]; then nmcli connection export "$ETH_UUID_PREPREF" > "$SNAP_ETH_PREPREF" 2>>"$LOG" || true; fi
  if [ -n "$WIFI_UUID_PREPREF" ]; then nmcli connection export "$WIFI_UUID_PREPREF" > "$SNAP_WIFI_PREPREF" 2>>"$LOG" || true; fi
  ok "Preference snapshots saved."
}

prefer_ethernet() {
  rule
  info "Step S7: Prefer Ethernet over Wi‑Fi (route metrics + autoconnect priority)"
  need_cmds nmcli || return 1
  nmcli con modify "$ETH_CON"  ipv4.route-metric 100 ipv6.route-metric 100 >>"$LOG" 2>&1 || return 1
  if [ -n "$WIFI_CON" ]; then
    nmcli con modify "$WIFI_CON" ipv4.route-metric 600 ipv6.route-metric 600 >>"$LOG" 2>&1 || return 1
  fi
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
  need_cmds nmcli ping getent || true
  ip -4 addr show "$ETH_IF" | tee -a "$LOG" || true
  nmcli connection show --active | tee -a "$LOG" || true
  ip route | tee -a "$LOG" || true

  local ok_any=0
  if command -v ping >/dev/null 2>&1 && ping -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
    ok "ICMP to 8.8.8.8 reachable."
    ok_any=1
  else
    warn "Ping to 8.8.8.8 failed or ping not available."
  fi
  if command -v getent >/dev/null 2>&1 && getent hosts google.com >/dev/null 2>&1; then
    ok "DNS resolution works (google.com)."
  else
    warn "DNS resolution check failed."
  fi
  [ $ok_any -eq 1 ] || return 1
}

# ---------- MAIN ----------

main() {
  require_root "$@"
  parse_args "$@"

  rule; info "Ubuntu Server (RPi 5) networking automation — Rollback v5 with auto-install + retries starting ..."; rule

  backup_original_netplan
  detect_interfaces

  # 1) Ethernet must be up and working FIRST (hard requirement).
  step "S1" "Ethernet DHCP bring-up & verification" ethernet_dhcp

  # 2) After connectivity, install core packages (and auto-install later as needed).
  step "S2" "Install core packages" install_core_packages

  # 3) Snapshot NM state (after nmcli exists).
  step "SNAP" "Snapshot pre-run NetworkManager" snapshot_pre_run_nm

  # 4) Switch renderer to NM and proceed with Wi‑Fi.
  step "S3" "Switch to NetworkManager" switch_to_networkmanager
  step "S4" "Wi‑Fi unblock/manage" wifi_unblock_and_manage

  # 5) Retry Wi‑Fi scan and connect up to 3 times each.
  step_retry "S5" "Wi‑Fi scan" 3 wifi_scan
  step_retry "S6" "Wi‑Fi connect" 3 wifi_connect

  # 6) Snapshot connections before preference changes for partial rollback.
  step "PREF_SNAPSHOT" "Snapshot before preference changes" snapshot_preference_state
  step "S7" "Prefer Ethernet" prefer_ethernet
  step "S8" "Final verification" verify_final

  rule; ok "All steps completed successfully. Log saved to $LOG"; rule
}

main "$@"
