#!/usr/bin/env bash
#==============================================================================
# AccessPointToolKit-uninstall.sh — companion uninstaller for APTK
#
# Removes everything AccessPointToolKit (APTK) installs or creates:
#   * apt packages pulled in by the APTK dependency installer (menu 2)
#   * the morrownr/8814au out-of-tree DKMS driver, if it was built
#   * a bettercap binary dropped into /usr/local/bin (GitHub fallback path)
#   * a Kismet built from SOURCE by APTK (unsupported-release path in v1.3:
#     /usr/local/src/kismet, /usr/local/bin/kismet*, ...), plus the
#     kismetwireless.net apt repo file and signing key added by APTK
#   * APTK config, pid dir, and its NetworkManager / gpsd / Kismet edits
#   * ALL capture logs: /var/log/aptk and the legacy /var/log/wardrive
#
# v1.3: added Kismet source-build + apt-repo cleanup (companion to
#       AccessPointToolKit.sh v1.3)
#
# Usage:
#   sudo ./AccessPointToolKit-uninstall.sh [options]
#     -y, --yes        answer yes to every prompt (non-interactive)
#     -n, --dry-run    show what would happen, change nothing
#     -h, --help       this help
#
# Deliberately NOT removed:
#   python3 — core of Ubuntu's own tooling (apt, cloud-init, update-manager);
#             purging it wrecks the OS. APTK only *used* it, never owns it.
#   bluez   — the desktop Bluetooth stack; purging it also tears out
#             gnome-bluetooth/blueman and can break the desktop. If you
#             truly want it gone:  sudo apt-get purge -y bluez
#             then sudo apt-get autoremove --purge -y
#==============================================================================
set -u

DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes)      ASSUME_YES=1 ;;
    -n|--dry-run)  DRY_RUN=1 ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)"; exit 1 ;;
  esac
done

msg()  { printf '%s\n' "$*"; }
ok()   { printf '%s\n' "[+] $*"; }
warn() { printf '%s\n' "[!] $*"; }
err()  { printf '%s\n' "[x] $*"; }

confirm() {
  local ans
  (( ASSUME_YES )) && return 0
  read -rp "$1 [y/N]: " ans
  [[ "${ans:-}" =~ ^[Yy] ]]
}

# run <cmd...> : execute for real, or just print in dry-run mode.
run() {
  if (( DRY_RUN )); then
    msg "DRY-RUN >> $*"
  else
    "$@"
  fi
}

# rmpath <path> : remove a file/dir if it exists (quiet in dry-run either way).
rmpath() {
  [[ -e "$1" ]] || return 0
  run rm -rf "$1"
  (( DRY_RUN )) || ok "removed: $1"
}

hr() { printf '%s\n' "--------------------------------------------------------------"; }

hr
msg " AccessPointToolKit (APTK) uninstaller"
hr
if (( DRY_RUN )); then warn "DRY-RUN MODE — nothing will be changed."; fi

if [[ ${EUID} -ne 0 ]]; then
  err "This script must run as root:  sudo $0"
  exit 1
fi

#------------------------------------------------------------------------------
# 1) Stop anything APTK started
#------------------------------------------------------------------------------
msg ""
msg "[1/7] Stopping running captures and services..."

if pgrep -x kismet >/dev/null 2>&1; then
  warn "Kismet is running — stopping it first."
  run pkill -INT -x kismet
  if ! (( DRY_RUN )); then
    for _ in $(seq 1 10); do pgrep -x kismet >/dev/null 2>&1 || break; sleep 1; done
    pgrep -x kismet >/dev/null 2>&1 && run pkill -TERM -x kismet
  fi
else
  msg "  kismet: not running"
fi
if pgrep -x bettercap >/dev/null 2>&1; then
  run pkill -x bettercap
else
  msg "  bettercap: not running"
fi
if systemctl is-active gpsd >/dev/null 2>&1; then
  run systemctl stop gpsd
  run systemctl disable gpsd 2>/dev/null
else
  msg "  gpsd: not active"
fi

#------------------------------------------------------------------------------
# 2) Restore any monitor-mode interface BEFORE the tools are purged
#------------------------------------------------------------------------------
msg ""
msg "[2/7] Restoring WiFi interfaces to managed mode..."
if command -v iw >/dev/null 2>&1; then
  _restored=0
  for _i in /sys/class/net/*; do
    _if="${_i##*/}"
    if iw dev "$_if" info 2>/dev/null | grep -q "type monitor"; then
      run ip link set "$_if" down
      run iw dev "$_if" set type managed
      run ip link set "$_if" up
      _restored=1
      (( DRY_RUN )) || ok "$_if back in managed mode"
    fi
  done
  (( _restored )) || msg "  no interfaces in monitor mode"
else
  warn "  iw not present — skipping (interfaces left as they are)"
fi

#------------------------------------------------------------------------------
# 3) Remove the out-of-tree 8814au DKMS driver if it was ever built
#------------------------------------------------------------------------------
msg ""
msg "[3/7] DKMS driver check (morrownr/8814au)..."
if command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -q "8814au"; then
  while IFS= read -r _line; do
    case "$_line" in
      *8814au*)
        _mod=$(printf '%s' "$_line" | cut -d, -f1 | tr -d ' ')
        _ver=$(printf '%s' "$_line" | cut -d, -f2 | tr -d ' ')
        [[ -n "$_mod" && -n "$_ver" ]] && run dkms remove "${_mod}/${_ver}" --all
        ;;
    esac
  done < <(dkms status 2>/dev/null)
  run rm -rf /usr/src/8814au-* /usr/src/rtl8814au-* /usr/local/src/8814au
  (( DRY_RUN )) || ok "out-of-tree 8814au driver removed (in-kernel rtw88_8814au untouched)"
else
  msg "  no 8814au DKMS module installed"
fi

#------------------------------------------------------------------------------
# 4) Purge the packages APTK's installer added (minus OS-critical ones)
#------------------------------------------------------------------------------
msg ""
msg "[4/7] Purging APTK packages..."
PURGE_PKGS=(
  kismet kismet-logtools kismet-capture-nrf-52840
  bettercap gpsd gpsd-clients
  dkms build-essential libelf-dev bc
  git curl unzip usbutils iw rfkill sqlite3
)
if (( DRY_RUN )); then
  msg "DRY-RUN >> apt-get purge -y ${PURGE_PKGS[*]} linux-headers-$(uname -r)"
else
  # shellcheck disable=SC2086
  apt-get purge -y "${PURGE_PKGS[@]}" "linux-headers-$(uname -r)" || \
    warn "some packages failed to purge — they may already be gone"
  apt-get autoremove --purge -y || true
  ok "packages purged; autoremove done"
fi
msg "  kept: python3 (Ubuntu core tooling) and bluez (desktop BT stack)."
msg "        bluez manual removal: sudo apt-get purge -y bluez"

#------------------------------------------------------------------------------
# 5) Remove APTK files and its edits to system config
#------------------------------------------------------------------------------
msg ""
msg "[5/7] Removing APTK files and config edits..."
# Config files (current + legacy wardrive-console names)
rmpath /etc/aptk.conf
rmpath /etc/wardrive-console.conf
# Runtime pid dir
rmpath /run/aptk
rmpath /run/wardrive-console
# NetworkManager "unmanaged" marks (current + legacy)
rmpath /etc/NetworkManager/conf.d/99-aptk.conf
rmpath /etc/NetworkManager/conf.d/99-wardrive-console.conf
if command -v systemctl >/dev/null 2>&1 && systemctl is-active NetworkManager >/dev/null 2>&1; then
  run systemctl restart NetworkManager
  (( DRY_RUN )) || ok "NetworkManager restarted (adapter managed again)"
fi
# Kismet site config generated by APTK (the kismet package purge removes
# the rest of /etc/kismet that belongs to the package itself)
rmpath /etc/kismet/kismet_site.conf
rmpath /etc/kismet/kismet_site.conf.bak
# gpsd backups taken before APTK edited /etc/default/gpsd
rmpath /etc/default/gpsd.aptk.bak
rmpath /etc/default/gpsd.wardrive.bak
# bettercap installed from the GitHub-release fallback (not owned by apt)
if [[ -x /usr/local/bin/bettercap ]] && ! dpkg -S /usr/local/bin/bettercap >/dev/null 2>&1; then
  rmpath /usr/local/bin/bettercap
fi
# Kismet apt repo + signing key added by APTK v1.3 (signed-by keyring method)
rmpath /etc/apt/sources.list.d/kismet.list
rmpath /etc/apt/keyrings/kismet-archive-keyring.gpg
# Kismet built from SOURCE by APTK v1.3 (unsupported-release path).
# apt purge cannot remove it; clean the documented install locations.
if [[ -d /usr/local/src/kismet ]] || ls /usr/local/bin/kismet_cap_* >/dev/null 2>&1; then
  if confirm "Remove the source-built Kismet (/usr/local/src/kismet + /usr/local/bin/kismet*)?"; then
    rmpath /usr/local/src/kismet
    run rm -fv /usr/local/bin/kismet* /usr/local/share/kismet* /usr/local/etc/kismet* 2>/dev/null
    (( DRY_RUN )) || ok "source-built Kismet removed"
  else
    warn "kept source-built Kismet files in /usr/local"
  fi
fi
# Kismet web UI credentials and state in root's home
if [[ -d /root/.kismet ]]; then
  if confirm "Remove /root/.kismet (Kismet web UI login + session state)?"; then
    rmpath /root/.kismet
  else
    warn "kept /root/.kismet"
  fi
fi

#------------------------------------------------------------------------------
# 6) Delete the capture logs  (this is the point of no return)
#------------------------------------------------------------------------------
msg ""
msg "[6/7] Deleting capture logs..."
for _d in /var/log/aptk /var/log/wardrive; do
  if [[ -d "$_d" ]]; then
    msg "  $_d  ($(du -sh "$_d" 2>/dev/null | cut -f1))"
  fi
done
if [[ -d /var/log/aptk || -d /var/log/wardrive ]]; then
  if confirm "Permanently delete ALL session logs (kismetdb, wiglecsv, reports)?"; then
    rmpath /var/log/aptk
    rmpath /var/log/wardrive
    (( DRY_RUN )) || ok "logs deleted"
  else
    warn "logs kept — remove manually later with:"
    warn "  sudo rm -rf /var/log/aptk /var/log/wardrive"
  fi
else
  msg "  no log directories found"
fi

#------------------------------------------------------------------------------
# 7) Unblock radios, report leftovers
#------------------------------------------------------------------------------
msg ""
msg "[7/7] Restoring radio state and checking leftovers..."
run rfkill unblock all
(( DRY_RUN )) || ok "rfkill: everything unblocked"

if [[ -d /etc/kismet ]]; then
  warn "/etc/kismet still exists — files left by the kismet package or your"
  warn "own edits. Review with:  ls -la /etc/kismet"
fi
msg ""
hr
if (( DRY_RUN )); then
  ok "Dry run complete — rerun without -n/--dry-run to apply for real."
else
  ok "Uninstall complete. APTK packages, files, and logs are gone."
  warn "Recommended: reboot to unload any stale driver/module state."
  warn "The APTK script itself is still wherever you saved it — delete it"
  warn "manually if you no longer want it (e.g. ~/AccessPointToolKit.sh)."
fi
hr
