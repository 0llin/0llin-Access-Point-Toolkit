#!/usr/bin/env bash
#==============================================================================
# AccessPointToolKit.sh — "APTK"
# A tput full-screen Bash TUI for a Kismet wardriving rig.
#
# Hardware profile:
#   WiFi : Alfa AWUS1900  — Realtek RTL8814AU, USB ID 0bda:8813.
#          Ubuntu 26.04 (kernel 7.x) ships the in-kernel mac80211 driver
#          rtw88_8814au; the out-of-tree morrownr/8814au driver (kernel range
#          5.4–6.18.x) is only the fallback when the in-kernel one is absent.
#   GPS  : VFAN UG-353    — u-blox 7, USB ID 1546:01a7, native cdc_acm,
#          shows up as /dev/ttyACM0, feeds gpsd on localhost:2947.
#   BT   : Techkey BT863 — BT 5.3 + BLE, Realtek chip, in-kernel btusb;
#          BLE survey via bettercap "ble.recon" (Ubuntu universe package).
#   BLE2 : EBYTE E104-BT5040U — Nordic nRF52840, BLE-only, USB CDC serial
#          (NOT an hciX controller). Used as a Kismet BLE sniffer source via
#          kismet-capture-nrf-52840 (needs Nordic Sniffer firmware; the U
#          variant ships nRF Connect firmware, the UA variant ships the
#          sniffer firmware preloaded).
#
# Scope & ethics: PASSIVE RECEPTION ONLY. This script never connects to,
# authenticates with, injects into, or decrypts any third-party network.
# Beacon frames are unencrypted broadcasts — keep the lab inside that scope
# and get written sign-off from your instructor for any off-campus runs.
#
# v1.1 changelog:
#   - Session summary report (sqlite3 queries against kismetdb)
#   - Kismet IDS alert viewer (alerts table: DOS/EXPLOIT/PROBE/SPOOF/SYSTEM)
#   - Structured BLE logging via bettercap events.stream.output (v2 API;
#     the old -O/--log flag was bettercap v1 and does not exist in v2)
#   - Privacy exports: wiglecsv exclusion zone + sanitized kismetdb copy
#   - Per-session collection manifest written next to the logs
#   - EBYTE E104-BT5040U (nRF52840) support: auto-detect by USB VID 1915,
#     Kismet nrf52840 BLE sniffer source, firmware-flash guidance
#
# v1.2 changelog:
#   - Renamed WARDRIVER -> APTK "AccessPointToolKit" (save as
#     AccessPointToolKit.sh); terminal window title set to APTK
#   - Paths renamed: /etc/aptk.conf, /run/aptk, 99-aptk.conf,
#     /var/log/aptk (old wardrive-console paths still cleaned by
#     the companion uninstaller script)
#
# v1.3 changelog:
#   - FIXED menu 2 on releases without packaged Kismet (Ubuntu 26.04
#     "resolute"): base tools (curl, gnupg, ...) are installed FIRST in
#     their own apt transaction, so a missing Kismet package can no longer
#     abort the entire install (that is what broke the bettercap fallback
#     with "curl: command not found")
#   - Kismet install is now staged: if the release codename has an official
#     Kismet apt suite (kali, buster, bullseye, bionic, focal, jammy), the
#     repo is added with the modern signed-by keyring method; otherwise the
#     script offers a source build from kismetwireless.net git (which
#     includes every capture helper, e.g. kismet_cap_nrf_52840)
#   - nrf_kismet_check() now looks for the real helper BINARY
#     (kismet_cap_nrf_52840, underscores) or the installed apt package;
#     the old check ran "command -v kismet-capture-nrf-52840", which is a
#     package name, not a command
#   - write_manifest(): fixed the cut delimiter for PRETTY_NAME
#     (was backslash-quote, produced garbled OS name in the manifest)
#   - GPS detection now keys on the u-blox USB vendor ID (1546) and
#     prefers the stable /dev/serial/by-id path, instead of trusting
#     bare ttyACM ordering (which can swap with the EBYTE dongle)
#
# References:
#   Driver      : https://github.com/morrownr/8814au
#   In-kernel   : https://lwn.net/Articles/1012242/
#   GPS/Kismet  : https://www.kismetwireless.net/docs/readme/gps/gps_intro/
#   WigleCSV    : https://www.kismetwireless.net/docs/readme/logging/wiglecsv/
#   bettercap   : https://www.bettercap.org
#==============================================================================
set -u
shopt -s nullglob

VERSION="1.3"

#------------------------------------------------------------------------------
# Paths & hardware IDs
#------------------------------------------------------------------------------
CONF_FILE="/etc/aptk.conf"
KISMET_SITE="/etc/kismet/kismet_site.conf"
KISMET_WARDDRIVE="/etc/kismet/kismet_wardrive.conf"
GPSD_DEFAULT="/etc/default/gpsd"
NM_UNMANAGED="/etc/NetworkManager/conf.d/99-aptk.conf"
PID_DIR="/run/aptk"
WIFI_USB_ID="0bda:8813"     # Alfa AWUS1900 (RTL8814AU)
GPS_USB_ID="1546:01a7"      # VFAN UG-353 (u-blox 7)

#------------------------------------------------------------------------------
# Persisted settings (saved to CONF_FILE)
#------------------------------------------------------------------------------
LOG_BASE="/var/log/aptk"
WIFI_IF=""
GPS_DEV="/dev/ttyACM0"
BT_HCI=""
NRF_DEV=""                  # EBYTE E104-BT5040U serial path (Kismet BLE sniffer)
LOG_TYPES="kismet,wiglecsv" # recommended: sqlite superset + live map csv
WARDRIVE_MODE=1             # 1 = launch kismet with --override wardrive
HOP_RATE=2                  # channel hops/sec (informational; kismet default)

# Runtime State
SESSION_TITLE=""
KISMET_PID=""
DRIVER_MODE="unknown"

#==============================================================================
# UI helpers (pure bash + tput)
#==============================================================================
init_colors() {
  if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
    C_RESET=$(tput sgr0);  C_BOLD=$(tput bold)
    C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YLW=$(tput setaf 3)
    C_CYN=$(tput setaf 6); C_WHT=$(tput setaf 7)
  else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GRN=""; C_YLW=""; C_CYN=""; C_WHT=""
  fi
}

#------------------------------------------------------------------------------
# APTK banner art (36 cols; letters cyan, beacon waves green)
#------------------------------------------------------------------------------
LOGO_WIDTH=36
LOGO_WAVES=(
"  ) ) )   ) ) )   ) ) )   ) ) )"
"( ( (   ( ( (   ( ( (   ( ( ("
)
LOGO_LINES=(
'  ###     #####     #######   #    #'
' #   #    #    #      ###     #   # '
'#     #   #    #      ###     #  #  '
'#######   #####       ###     ###   '
'#     #   #           ###     #  #  '
'#     #   #           ###     #    #'
)

hr() {
  local w="${COLUMNS:-78}"
  printf '%s' "${C_CYN}"
  printf '=%.0s' $(seq 1 "$w")
  printf '%s\n' "${C_RESET}"
}

msg()  { printf '%s\n' "$*"; }
ok()   { printf '%s\n' "${C_GRN}[+]${C_RESET} $*"; }
warn() { printf '%s\n' "${C_YLW}[!]${C_RESET} $*"; }
err()  { printf '%s\n' "${C_RED}[x]${C_RESET} $*"; }

pause_ui() { printf '\n'; read -rp "Press Enter to return to the menu..."; }
confirm()  { read -rp "$1 [y/N]: " _ans; [[ "${_ans:-}" =~ ^[Yy] ]]; }

print_logo() {
  # Full art needs >= 78 columns and >= 36 rows; smaller terminals get a
  # compact one-line title so the menu never wraps or scrolls away.
  local cols rows pad i line
  cols="${COLUMNS:-80}"
  rows=$(tput lines 2>/dev/null || echo 0)
  if (( cols < 78 )) || { (( rows > 0 )) && (( rows < 36 )); }; then
    printf '%s\n' "${C_GRN}~ ) ) ) ~${C_RESET} ${C_BOLD}APTK${C_RESET} ${C_GRN}~ ( ( ( ~${C_RESET}"
    return 0
  fi
  pad=$(( (cols - LOGO_WIDTH) / 2 ))
  (( pad < 1 )) && pad=1
  for i in "${!LOGO_WAVES[@]}"; do
    line="${LOGO_WAVES[$i]}"
    printf '%*s' "$(( pad + (LOGO_WIDTH - ${#line}) / 2 ))" ""
    printf '%s\n' "${C_GRN}${line}${C_RESET}"
  done
  for i in "${!LOGO_LINES[@]}"; do
    line="${LOGO_LINES[$i]}"
    printf '%*s' "$(( pad + (LOGO_WIDTH - ${#line}) / 2 ))" ""
    printf '%s\n' "${C_CYN}${line}${C_RESET}"
  done
  line="AccessPointToolKit v${VERSION} — kismet passive mapping rig"
  printf '%*s' "$(( pad + (LOGO_WIDTH - ${#line}) / 2 ))" ""
  printf '%s\n' "${C_GRN}${line}${C_RESET}"
}

banner() {
  clear
  # Set the terminal window title while the TUI is running.
  printf '\033]0;APTK — AccessPointToolKit\007'
  hr
  print_logo
  hr
  printf '%s\n' " WiFi: AWUS1900 | GPS: UG-353 | BT: BT863 | BLE sniffer: EBYTE BT5040U"
  printf '%s\n' "${C_YLW} PASSIVE CAPTURE ONLY — no connect / inject / decrypt${C_RESET}"
  hr
}

status_line() {
  local sess
  sess="${C_RED}stopped${C_RESET}"
  if kismet_running; then sess="${C_GRN}running${C_RESET}"; fi
  printf ' iface:%s | gps:%s | logs:%s | session:%s\n' \
    "${WIFI_IF:-?}" "${GPS_DEV:-?}" "$LOG_BASE" "$sess"
  hr
}

draw_menu() {
  banner
  status_line
  cat <<EOF
 ${C_BOLD}1${C_RESET})  Pre-flight system check
 ${C_BOLD}2${C_RESET})  Install dependencies (apt + driver + bettercap)
 ${C_BOLD}3${C_RESET})  Configure log path
 ${C_BOLD}4${C_RESET})  GPS: check, configure, start
 ${C_BOLD}5${C_RESET})  Bluetooth: BT863 + EBYTE sniffer / BLE survey
 ${C_BOLD}6${C_RESET})  WiFi adapter: monitor mode, channels, NetworkManager
 ${C_BOLD}7${C_RESET})  Kismet options: source, log types, wardrive mode
 ${C_BOLD}8${C_RESET})  START wardrive session
 ${C_BOLD}9${C_RESET})  Stop session
 ${C_BOLD}10${C_RESET}) Session status
 ${C_BOLD}11${C_RESET}) Analyze & export (report, alerts, privacy)
 ${C_BOLD}12${C_RESET}) Cleanup & restore
 ${C_BOLD}q${C_RESET})  Quit
EOF
  printf '%s' "Select> "
}

#==============================================================================
# Config persistence
#==============================================================================
save_conf() {
  cat > "$CONF_FILE" <<EOF
# AccessPointToolKit settings
LOG_BASE="$LOG_BASE"
WIFI_IF="$WIFI_IF"
GPS_DEV="$GPS_DEV"
BT_HCI="$BT_HCI"
NRF_DEV="$NRF_DEV"
LOG_TYPES="$LOG_TYPES"
WARDRIVE_MODE=$WARDRIVE_MODE
HOP_RATE=$HOP_RATE
EOF
}

load_conf() {
  [[ -s "$CONF_FILE" ]] || return 0
  local f
  f=$(mktemp)
  grep -E '^(LOG_BASE|WIFI_IF|GPS_DEV|BT_HCI|NRF_DEV|LOG_TYPES|WARDRIVE_MODE|HOP_RATE)=' \
    "$CONF_FILE" > "$f" 2>/dev/null || true
  # shellcheck disable=SC1090
  source "$f"
  rm -f "$f"
}

#==============================================================================
# Hardware detection
#==============================================================================
usb_present() { lsusb 2>/dev/null | grep -qi "$1"; }

detect_driver_state() {
  local inkernel=0 oot=0
  modinfo rtw88_8814au >/dev/null 2>&1 && inkernel=1
  modinfo 8814au       >/dev/null 2>&1 && oot=1
  if (( inkernel && oot )); then
    DRIVER_MODE="MIXED (rtw88_8814au + 8814au) — blacklist conflict"
  elif (( inkernel )); then
    DRIVER_MODE="rtw88_8814au (in-kernel)"
  elif (( oot )); then
    DRIVER_MODE="8814au (out-of-tree)"
  else
    DRIVER_MODE="none"
  fi
}

detect_wifi_if() {
  local ifc drv
  WIFI_IF=""
  for ifc in /sys/class/net/*; do
    [[ -e "$ifc/device/driver" ]] || continue
    drv=$(basename "$(readlink -f "$ifc/device/driver")")
    case "$drv" in
      8814au|rtw88_8814au) WIFI_IF="${ifc##*/}"; return 0 ;;
    esac
  done
  return 1
}

detect_gps_dev() {
  # The u-blox 7 GPS also enumerates as USB CDC-ACM and shares /dev/ttyACM*
  # with the EBYTE dongle, so trust the USB vendor ID (1546 = u-blox), not
  # tty ordering. Prefer the stable /dev/serial/by-id path when available,
  # mirroring detect_nrf_dev() below.
  local t vid byid
  for t in /sys/class/tty/ttyACM[0-9]*; do
    [[ -f "$t/device/idVendor" ]] || continue
    vid=$(cat "$t/device/idVendor" 2>/dev/null)
    if [[ "$vid" == "1546" ]]; then
      for byid in /dev/serial/by-id/*; do
        [[ "$(readlink -f "$byid")" == "/dev/${t##*/}" ]] && { GPS_DEV="$byid"; return 0; }
      done
      GPS_DEV="/dev/${t##*/}"
      return 0
    fi
  done
  # Legacy fallback: first ttyACM present (pre-v1.3 behavior)
  local d
  for d in /dev/ttyACM[0-9]*; do
    [[ -e "$d" ]] && { GPS_DEV="$d"; return 0; }
  done
  return 1
}

# The EBYTE E104-BT5040U (Nordic nRF52840) enumerates as a USB CDC-ACM
# serial device — NOT an hciX controller. It shares /dev/ttyACM* with the
# u-blox GPS, so identify it by USB vendor ID instead of tty numbering:
#   1546 = u-blox (GPS)   1915 = Nordic Semiconductor (EBYTE dongle).
# Stable paths under /dev/serial/by-id/ are preferred when available so the
# selection survives re-plug reordering.
detect_nrf_dev() {
  local t vid byid
  for t in /sys/class/tty/ttyACM[0-9]*; do
    [[ -f "$t/device/idVendor" ]] || continue
    vid=$(cat "$t/device/idVendor" 2>/dev/null)
    if [[ "$vid" == "1915" ]]; then
      for byid in /dev/serial/by-id/*; do
        [[ "$(readlink -f "$byid")" == "/dev/${t##*/}" ]] && { NRF_DEV="$byid"; return 0; }
      done
      NRF_DEV="/dev/${t##*/}"
      return 0
    fi
  done
  return 1
}

nrf_kismet_check() {
  # Is the Kismet helper for the nRF52840 serial sniffer available?
  # NOTE: the helper BINARY is kismet_cap_nrf_52840 (underscores); the
  # hyphenated name is the apt PACKAGE. A source build installs the binary
  # only; the apt install provides the package. Accept either.
  command -v kismet_cap_nrf_52840 >/dev/null 2>&1 && return 0
  dpkg-query -W -f='${Status}' kismet-capture-nrf-52840 2>/dev/null \
    | grep -q 'install ok installed'
}

list_hci() {
  local h dev prod count=0
  for h in /sys/class/bluetooth/hci*; do
    count=$((count+1))
    dev=$(readlink -f "$h/device")
    prod="(built-in or unknown)"
    [[ -r "$dev/../product" ]] && prod=$(<"$dev/../product")
    printf '  %-6s %s\n' "${h##*/}" "$prod"
  done
  (( count > 0 )) || { warn "No Bluetooth controllers found (hci*)."; return 1; }
  return 0
}

gps_fix_mode() {
  # Returns the best TPV mode seen in 25 s: 3=3D fix, 2=2D fix, 1=no fix, empty=no data
  timeout 25 gpspipe -w -n 20 2>/dev/null \
    | grep -o '"mode":[0-9]' | cut -d: -f2 | sort -rn | head -n1
}

kismet_running() { [[ -n "$KISMET_PID" ]] && kill -0 "$KISMET_PID" 2>/dev/null; }

#==============================================================================
# 1) Pre-flight
#==============================================================================
fn_preflight() {
  banner
  ok "OS     : $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
  msg "Kernel : $(uname -r)"
  msg "Driver : $DRIVER_MODE"
  if [[ "$DRIVER_MODE" == MIXED* ]]; then
    warn "Mixed driver state — remove the out-of-tree driver and reboot."
  fi
  usb_present "$WIFI_USB_ID" && ok "AWUS1900 present on USB ($WIFI_USB_ID)" \
                               || err "AWUS1900 NOT found on USB"
  usb_present "$GPS_USB_ID"  && ok "UG-353 present on USB ($GPS_USB_ID)" \
                               || warn "UG-353 GPS not on USB (check cable)"
  [[ -n "$WIFI_IF" ]] && ok "WiFi iface : $WIFI_IF" \
                         || warn "No WiFi interface bound to an 8814AU driver yet"
  [[ -e "$GPS_DEV" ]] && ok "GPS device : $GPS_DEV" \
                        || warn "GPS device $GPS_DEV not present"
  if detect_nrf_dev; then
    ok "EBYTE BT5040U : $NRF_DEV (Kismet BLE sniffer)"
  else
    warn "EBYTE BT5040U : not detected (optional — plug in or ignore)"
  fi
  nrf_kismet_check && ok "tool : kismet_cap_nrf_52840" \
                       || warn "tool : kismet_cap_nrf_52840 MISSING (menu 2)"
  local cmd
  for cmd in kismet kismetdb_to_wiglecsv gpspipe bettercap btmgmt iw sqlite3; do
    command -v "$cmd" >/dev/null 2>&1 && ok "tool : $cmd" \
                                          || warn "tool : $cmd MISSING (menu 2 installs)"
  done
  systemctl is-active gpsd >/dev/null 2>&1 && ok "gpsd : active" \
                                              || warn "gpsd : not active (menu 4)"
  local f; f=$(gps_fix_mode)
  msg "GPS fix : mode=${f:-none} (2/3 = locked, needed for wiglecsv)"
  msg "Log dir : $LOG_BASE ($(du -sh "$LOG_BASE" 2>/dev/null | cut -f1))"
  msg "Disk free: $(df -h "$LOG_BASE" 2>/dev/null | tail -1 | awk '{print $4" of "$2}')"
  pause_ui
}

#==============================================================================
# 2) Dependencies
#==============================================================================
# Kismet publishes official apt suites ONLY for these codenames
# (https://www.kismetwireless.net/docs/readme/packages/). Anything newer
# (e.g. Ubuntu noble/plucky/questing/resolute) has no suite and must be
# built from source: https://www.kismetwireless.net/docs/readme/quickstart/
KISMET_APT_SUITES="kali buster bullseye bionic focal jammy"
KISMET_KEYRING="/etc/apt/keyrings/kismet-archive-keyring.gpg"

os_codename() {
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-unknown}"
}

fn_install_deps() {
  banner
  # --- 1) Base tools FIRST, in their own apt transaction -------------------
  # Everything else (repo keys, bettercap fallback, driver builds) depends
  # on these. Installing them separately means a missing Kismet package can
  # no longer abort the whole transaction like it did in v1.2.
  ok "[1/5] Installing base tools (curl, gnupg, git, apt basics) FIRST..."
  apt-get update
  apt-get install -y \
    curl wget ca-certificates gnupg unzip git software-properties-common \
    usbutils iw rfkill bc sqlite3 python3 \
    gpsd gpsd-clients bluez \
    dkms build-essential libelf-dev \
    "linux-headers-$(uname -r)" \
    || { err "Base tool install failed — check the apt output above."
         pause_ui; return 1; }

  # --- 2) universe repository ----------------------------------------------
  ok "[2/5] Making sure the 'universe' repository is enabled..."
  if command -v add-apt-repository >/dev/null 2>&1; then
    add-apt-repository -y universe || warn "could not toggle universe (may already be on)"
    apt-get update
  fi

  # --- 3) Kismet -------------------------------------------------------------
  ok "[3/5] Installing Kismet..."
  install_kismet || err "Kismet could not be installed — see messages above."

  # --- 4) bettercap ----------------------------------------------------------
  ok "[4/5] Installing bettercap..."
  apt-get install -y bettercap 2>/dev/null || true
  if ! command -v bettercap >/dev/null 2>&1; then
    warn "bettercap not packaged on this release; fetching GitHub release binary..."
    install_bettercap_binary
  fi

  # --- 5) WiFi driver --------------------------------------------------------
  ok "[5/5] WiFi driver check..."
  detect_driver_state
  case "$DRIVER_MODE" in
    "rtw88_8814au (in-kernel)")
      ok "In-kernel rtw88_8814au present — no DKMS build needed."
      ;;
    "8814au (out-of-tree)")
      ok "Out-of-tree 8814au driver already installed."
      ;;
    MIXED*)
      warn "Both rtw88_8814au and 8814au modules found — mixed state."
      warn "Recommended: uninstall the out-of-tree driver, reboot, use in-kernel."
      ;;
    *)
      driver_fallback_offer
      ;;
  esac
  ok "If a driver was installed or blacklisted, REBOOT before wardriving."
  pause_ui
}

#------------------------------------------------------------------------------
# Kismet install, staged by what the release actually supports:
#   a) already installed          -> nothing to do
#   b) codename has an apt suite  -> signed-by keyring + kismetwireless repo
#   c) anything else (26.04 ...)  -> offer a source build
#------------------------------------------------------------------------------
install_kismet() {
  if command -v kismet >/dev/null 2>&1; then
    ok "Kismet already present: $(kismet --version 2>/dev/null | head -n1)"
    return 0
  fi
  local codename suite
  codename="$(os_codename)"
  for suite in $KISMET_APT_SUITES; do
    if [[ "$suite" == "$codename" ]]; then
      install_kismet_apt "$codename" && return 0
      return 1
    fi
  done
  warn "No official Kismet apt suite for '$codename'."
  warn "Supported suites: $KISMET_APT_SUITES"
  msg  "Ubuntu removed Kismet from its own archive years ago, and newer"
  msg  "releases are not covered by the kismetwireless.net repo yet. The"
  msg  "documented path for unsupported releases is a source build:"
  msg  "  https://www.kismetwireless.net/docs/readme/quickstart/"
  msg  "A source build also compiles EVERY capture helper into /usr/local/bin"
  msg  "(kismet_cap_linux_wifi, kismet_cap_nrf_52840, ...)."
  if confirm "Build Kismet from source now? (10-30 min, needs ~2 GB disk)"; then
    kismet_source_build && return 0
    return 1
  fi
  err "Kismet not installed — wardrive sessions cannot start (menu 8)."
  return 1
}

install_kismet_apt() {
  local codename="$1"
  ok "Adding the official Kismet apt repo (suite '$codename')..."
  mkdir -p /etc/apt/keyrings
  if [[ ! -s "$KISMET_KEYRING" ]]; then
    curl -fsSL https://www.kismetwireless.net/repos/kismet-release.gpg.key \
      | gpg --dearmor --yes -o "$KISMET_KEYRING" \
      || { err "Could not fetch/dearmor the Kismet signing key."; return 1; }
    chmod 0644 "$KISMET_KEYRING"
  fi
  printf 'deb [signed-by=%s] https://www.kismetwireless.net/repos/apt/release/%s %s main\n' \
    "$KISMET_KEYRING" "$codename" "$codename" > /etc/apt/sources.list.d/kismet.list
  apt-get update || true
  apt-get install -y kismet kismet-logtools \
    || { err "Kismet apt install failed — check apt output above."; return 1; }
  if apt-cache show kismet-capture-nrf-52840 >/dev/null 2>&1; then
    apt-get install -y kismet-capture-nrf-52840
  else
    warn "kismet-capture-nrf-52840 is not published for this suite — the"
    warn "EBYTE BLE sniffer source will be unavailable (WiFi capture works)."
  fi
  return 0
}

kismet_source_build() {
  ok "Installing Kismet build dependencies (large list)..."
  apt-get install -y \
    build-essential git pkg-config zlib1g-dev \
    libnl-3-dev libnl-genl-3-dev libcap-dev libpcap-dev libnm-dev libdw-dev \
    libsqlite3-dev libprotobuf-dev libprotobuf-c-dev \
    protobuf-compiler protobuf-c-compiler \
    libusb-1.0-0-dev libwebsockets-dev \
    python3 python3-setuptools python3-protobuf python3-requests \
    python3-numpy python3-serial python3-usb python3-dev python3-websockets \
    || { err "Build dependency install failed."; return 1; }
  # Optional helpers; package names differ between releases, so best-effort.
  local p
  for p in libsensors4-dev libsensors-dev libubertooth-dev libbtbb-dev librtlsdr-dev; do
    apt-get install -y "$p" >/dev/null 2>&1 || true
  done
  local dir="/usr/local/src/kismet"
  if [[ -d "$dir/.git" ]]; then
    ok "Existing Kismet checkout found — updating it..."
    git -C "$dir" pull --ff-only || warn "git pull failed; building the current checkout."
  else
    ok "Cloning Kismet source (large repo, a few minutes)..."
    git clone https://www.kismetwireless.net/git/kismet.git "$dir" \
      || { err "git clone failed."; return 1; }
  fi
  ( cd "$dir" && ./configure && make -j"$(nproc)" && make suidinstall ) \
    || { err "Kismet build failed — read the configure/make output above."
         err "If libwebsockets caused it, retry with: cd $dir && ./configure --disable-libwebsockets && make -j\$(nproc) && make suidinstall"
         return 1; }
  if command -v kismet >/dev/null 2>&1; then
    ok "Kismet built and installed (suidinstall): $(kismet --version 2>/dev/null | head -n1)"
    ok "Capture helpers now in /usr/local/bin: kismet_cap_linux_wifi, kismet_cap_nrf_52840, ..."
    return 0
  fi
  err "'make suidinstall' finished but kismet is not on PATH — check the build log."
  return 1
}

install_bettercap_binary() {
  local url tmp
  tmp=$(mktemp -d)
  url=$(curl -sL https://api.github.com/repos/bettercap/bettercap/releases/latest \
        | grep -o 'https://[^"]*linux_amd64[^"]*\.zip' | head -n1)
  if [[ -z "$url" ]]; then
    err "Could not locate bettercap release URL — install manually."
    rm -rf "$tmp"; return 1
  fi
  curl -sL "$url" -o "$tmp/bc.zip"
  unzip -o "$tmp/bc.zip" -d "$tmp"
  install -m 0755 "$tmp"/bettercap /usr/local/bin/bettercap
  rm -rf "$tmp"
  command -v bettercap >/dev/null 2>&1 && ok "bettercap installed to /usr/local/bin"
}

driver_fallback_offer() {
  warn "No 8814AU driver for kernel $(uname -r)."
  msg  "Ubuntu 26.04 (kernel 7.x) should already carry the in-kernel"
  msg  "rtw88_8814au driver. The out-of-tree morrownr/8814au driver"
  msg  "supports kernels 5.4–6.18.x and may NOT build on kernel 7.x."
  confirm "Attempt to clone and build morrownr/8814au anyway?" || return 0
  local dir="/usr/local/src/8814au"
  git clone https://github.com/morrownr/8814au.git "$dir" \
    || { err "git clone failed"; return 1; }
  ( cd "$dir" && ./install-driver.sh )
}

#==============================================================================
# 3) Log path
#==============================================================================
fn_set_logpath() {
  banner
  msg "Current log path: $LOG_BASE"
  read -rp "New log directory [${LOG_BASE}]: " p
  p="${p:-$LOG_BASE}"
  if ! mkdir -p "$p"; then err "Cannot create $p"; pause_ui; return 1; fi
  if ! touch "$p/.write_test" 2>/dev/null; then
    err "$p is not writable"; pause_ui; return 1
  fi
  rm -f "$p/.write_test"
  LOG_BASE="$p"
  save_conf
  ok "Log path set: $LOG_BASE (written into kismet_site.conf on session start)"
  pause_ui
}

#==============================================================================
# 4) GPS
#==============================================================================
fn_gps_menu() {
  while :; do
    banner
    msg "GPS device: $GPS_DEV  (u-blox 7 via cdc_acm)"
    msg "  1) Show status (gpsd + quick fix test)"
    msg "  2) Configure gpsd for this device and (re)start it"
    msg "  3) Live fix test (25 s)"
    msg "  4) Open cgps live monitor (q to exit)"
    msg "  0) Back"
    read -rp "GPS> " c
    case "$c" in
      1) systemctl is-active gpsd >/dev/null 2>&1 \
           && ok "gpsd active" || warn "gpsd down (option 2)"
         local f; f=$(gps_fix_mode)
         msg "Fix mode: ${f:-none}"
         pause_ui ;;
      2) gps_configure; pause_ui ;;
      3) gps_fix_test; pause_ui ;;
      4) if command -v cgps >/dev/null 2>&1; then cgps; else warn "gpsd-clients missing"; fi ;;
      0) break ;;
      *) ;;
    esac
  done
}

gps_configure() {
  [[ -e "$GPS_DEV" ]] || { err "No GPS device at $GPS_DEV"; return 1; }
  if [[ -f "$GPSD_DEFAULT" ]]; then cp -n "$GPSD_DEFAULT" "${GPSD_DEFAULT}.aptk.bak"; fi
  cat > "$GPSD_DEFAULT" <<EOF
# Managed by AccessPointToolKit
DEVICES="${GPS_DEV}"
USBAUTO="true"
EOF
  systemctl enable gpsd >/dev/null 2>&1
  systemctl restart gpsd
  sleep 2
  if systemctl is-active gpsd >/dev/null 2>&1; then
    ok "gpsd active, reading $GPS_DEV"
  else
    err "gpsd failed to start — check 'journalctl -u gpsd -e'"
  fi
}

gps_fix_test() {
  local m
  msg "Waiting up to 25 s for data (first lock outdoors can take 1–2 min)..."
  m=$(gps_fix_mode)
  case "${m:-}" in
    2|3) ok "GPS fix acquired (mode $m). wiglecsv rows will be populated." ;;
    1)   warn "GPS has data but NO fix yet — puck needs clear sky view." ;;
    *)   err "No data from gpsd — check cable, config, and sky view." ;;
  esac
}

#==============================================================================
# 5) Bluetooth
#==============================================================================
fn_bt_menu() {
  while :; do
    banner
    msg "Bluetooth controllers:"
    list_hci || true
    msg "Selected BT863 controller: ${BT_HCI:-none}"
    msg "EBYTE E104-BT5040U sniffer : ${NRF_DEV:-not configured}"
    nrf_kismet_check && ok "kismet_cap_nrf_52840 installed" \
                       || warn "kismet_cap_nrf_52840 missing (menu 2)"
    msg "  1) Power OFF all controllers (kills the internal/default adapter)"
    msg "  2) Select & power ON the Techkey BT863"
    msg "  3) Start BLE survey (bettercap ble.recon, BT863)"
    msg "  4) Auto-detect & select EBYTE E104-BT5040U (Kismet BLE sniffer)"
    msg "  5) EBYTE firmware help (sniffer flash for the U variant)"
    msg "  0) Back"
    read -rp "BT> " c
    case "$c" in
      1) bt_power_off_all; pause_ui ;;
      2) bt_enable_selected; pause_ui ;;
      3) fn_ble_survey ;;
      4) fn_nrf_select; pause_ui ;;
      5) fn_nrf_firmware_help; pause_ui ;;
      0) break ;;
      *) ;;
    esac
  done
}

fn_nrf_select() {
  if ! nrf_kismet_check; then
    err "kismet_cap_nrf_52840 not installed — run menu 2 first"; return 1
  fi
  if detect_nrf_dev; then
    ok "EBYTE E104-BT5040U found (Nordic USB VID 1915): $NRF_DEV"
  else
    err "No nRF52840 serial device found (VID 1915). Is the dongle plugged in?"
    return 1
  fi
  if [[ "$NRF_DEV" == "$GPS_DEV" ]]; then
    err "Selected device equals the GPS device — ttyACM ordering may have"
    err "shifted. Re-run menu 4 (GPS) first, then re-detect here."
    return 1
  fi
  save_conf
  msg "Saved. It will be added as a Kismet source on the next session start"
  msg "(BLE devices then land in the same kismetdb/wiglecsv as Wi-Fi)."
}

fn_nrf_firmware_help() {
  msg "EBYTE E104-BT5040U firmware notes:"
  msg ""
  msg " * The U variant ships nRF Connect-compatible firmware; Kismet's"
  msg "   nrf52840 capture source expects the Nordic BLE Sniffer firmware."
  msg " * The UA variant ships the sniffer firmware preloaded."
  msg ""
  msg " Flashing (U variant) — from https://www.nordicsemi.com:"
  msg "  1. Download the nRF Sniffer firmware for nRF52840 Dongle."
  msg "  2. Put the dongle in DFU mode: press RESET, the LED blinks red/green."
  msg "  3. Flash with nRF Connect for Desktop (Programmer) or:"
  msg "       nrfutil dfu usb-serial \\"
  msg "         -pkg sniffer_nrf52840dongle_nrf52840_<ver>.zip \\"
  msg "         -p ${NRF_DEV:-/dev/ttyACM1}"
  msg "  4. Re-plug the dongle, then run option 4 again."
  msg ""
  msg " Verify: the kismet_cap_nrf_52840 helper prints the firmware"
  msg " version when it opens the device."
}

bt_power_off_all() {
  local h count=0
  for h in /sys/class/bluetooth/hci*; do
    btmgmt -i "${h##*/}" power off >/dev/null 2>&1 || true
    msg "  ${h##*/} powered off"
    count=$((count+1))
  done
  rfkill block bluetooth >/dev/null 2>&1 || true
  (( count > 0 )) && ok "All Bluetooth controllers off." \
                    || warn "No controllers found — nothing to power off."
}

bt_enable_selected() {
  local idx
  rfkill unblock bluetooth >/dev/null 2>&1 || true
  read -rp "hci index of the BT863 (e.g. hci1): " idx
  if [[ ! "$idx" =~ ^hci[0-9]+$ ]]; then
    err "Bad index format"; return 1
  fi
  if [[ ! -d "/sys/class/bluetooth/$idx" ]]; then
    err "No such controller: $idx"; return 1
  fi
  BT_HCI="$idx"
  save_conf
  if btmgmt -i "$idx" power on >/dev/null 2>&1; then
    ok "$idx (Techkey BT863) powered on; all others stay off."
  else
    err "Failed to power on $idx — try 'btmgmt -i $idx power on' manually."
  fi
}

fn_ble_survey() {
  if ! command -v bettercap >/dev/null 2>&1; then
    err "bettercap missing — run menu 2 first"; return 1
  fi
  [[ -n "$BT_HCI" ]] || warn "No BT hci selected; bettercap uses the default controller."
  local m log
  read -rp "Survey duration in minutes [10]: " m
  m="${m:-10}"
  [[ "$m" =~ ^[0-9]+$ ]] || m=10
  mkdir -p "$LOG_BASE"
  log="${LOG_BASE}/ble-survey-$(date +%Y%m%d-%H%M%S).log"
  msg "Scanning BLE advertisements for ${m} min -> $log"
  msg "Each discovered device appears as a ble.device.new event. Ctrl+C stops early."
  # Passive observation of BLE advertisement frames only. The event stream
  # (ble.device.new etc.) is written to the log with timestamps via
  # events.stream.output; the module must be cycled when setting the target
  # (bettercap v2 behavior, see bettercap issue #169).
  timeout $((m*60)) bettercap -no-colors \
    -eval "events.stream off; set events.stream.output ${log}; events.stream on; ble.recon on" \
    2>/dev/null
  local found
  found=$(grep -c "ble.device" "$log" 2>/dev/null || true)
  found=${found:-0}
  ok "Survey finished. BLE-related events in $log: $found"
  msg "Last events:"; tail -n 5 "$log" 2>/dev/null | sed 's/^/  /'
}

#==============================================================================
# 6) WiFi adapter
#==============================================================================
fn_wifi_menu() {
  while :; do
    banner
    [[ -n "$WIFI_IF" ]] && msg "Interface: $WIFI_IF" \
                        || warn "AWUS1900 interface not detected (plug it in, then menu 1)"
    iw dev "${WIFI_IF:-wlan99}" info 2>/dev/null | sed 's/^/  /'
    msg ""
    msg "  1) Show full adapter status (iw / ip / driver / modes)"
    msg "  2) Make interface unmanaged by NetworkManager (recommended)"
    msg "  3) Set MONITOR mode"
    msg "  4) Restore MANAGED mode"
    msg "  5) Lock to a fixed channel (advanced; kismet normally hops)"
    msg "  0) Back"
    read -rp "WiFi> " c
    case "$c" in
      1) wifi_info; pause_ui ;;
      2) nm_unmanage; pause_ui ;;
      3) monitor_on;  pause_ui ;;
      4) monitor_off; pause_ui ;;
      5) wifi_set_channel; pause_ui ;;
      0) break ;;
      *) ;;
    esac
  done
}

wifi_info() {
  detect_wifi_if || warn "no 8814au-bound interface found"
  [[ -n "$WIFI_IF" ]] || return 1
  iw dev "$WIFI_IF" info
  ip -br link show "$WIFI_IF"
  msg "Driver: $(basename "$(readlink -f "/sys/class/net/$WIFI_IF/device/driver")")"
  iw list | grep -A8 'Supported interface modes' | head -10
}

nm_unmanage() {
  [[ -n "$WIFI_IF" ]] || { err "Detect the interface first (menu 1)"; return 1; }
  mkdir -p /etc/NetworkManager/conf.d
  cat > "$NM_UNMANAGED" <<EOF
# Managed by AccessPointToolKit — stop NM from touching the capture adapter
[keyfile]
unmanaged-devices=interface-name:${WIFI_IF}
EOF
  systemctl restart NetworkManager
  ok "$WIFI_IF marked unmanaged; NetworkManager restarted."
}

monitor_on() {
  [[ -n "$WIFI_IF" ]] || { err "No interface"; return 1; }
  ip link set "$WIFI_IF" down
  if iw dev "$WIFI_IF" set type monitor; then
    ok "monitor mode set on $WIFI_IF"
  else
    err "monitor mode failed — driver may not support it (check menu 1)"
  fi
  ip link set "$WIFI_IF" up
}

monitor_off() {
  [[ -n "$WIFI_IF" ]] || return 1
  ip link set "$WIFI_IF" down
  iw dev "$WIFI_IF" set type managed 2>/dev/null || true
  ip link set "$WIFI_IF" up
  ok "$WIFI_IF back in managed mode"
}

wifi_set_channel() {
  [[ -n "$WIFI_IF" ]] || { err "No interface"; return 1; }
  read -rp "Channel or frequency (e.g. 6, 36, 5180): " ch
  if iw dev "$WIFI_IF" set channel "$ch"; then
    ok "channel set: $ch"
  else
    err "failed to set channel"
  fi
}

#==============================================================================
# 7) Kismet options
#==============================================================================
fn_kismet_menu() {
  while :; do
    banner
    msg "source=${WIFI_IF:-?}  log_types=$LOG_TYPES  wardrive_mode=$WARDRIVE_MODE"
    [[ -f "$KISMET_WARDDRIVE" ]] && msg "wardrive overlay: present at $KISMET_WARDDRIVE" \
                                || msg "wardrive overlay: not found in /etc/kismet"
    msg "  1) Write /etc/kismet/kismet_site.conf now"
    msg "  2) Choose log format preset"
    msg "  3) Toggle wardrive overlay (--override wardrive)"
    msg "  4) Show Kismet version"
    msg "  0) Back"
    read -rp "Kismet> " c
    case "$c" in
      1) write_kismet_site; pause_ui ;;
      2) logtype_menu; pause_ui ;;
      3) WARDRIVE_MODE=$(( WARDRIVE_MODE ^ 1 )); save_conf
         ok "wardrive overlay toggled to $WARDRIVE_MODE" ;;
      4) kismet --version 2>/dev/null | head -1; pause_ui ;;
      0) break ;;
      *) ;;
    esac
  done
}

write_kismet_site() {
  [[ -n "$WIFI_IF" ]] || { err "WiFi interface not detected"; return 1; }
  mkdir -p /etc/kismet
  if [[ -f "$KISMET_SITE" ]]; then cp -n "$KISMET_SITE" "${KISMET_SITE}.bak"; fi
  cat > "$KISMET_SITE" <<EOF
# Generated by AccessPointToolKit — Kismet site override
# GPS via gpsd (UG-353 on $GPS_DEV). Wiglecsv stays empty without a fix.
gps=gpsd:host=localhost,port=2947

# Capture source: bare interface name lets Kismet auto-detect the source type.
source=${WIFI_IF}

# Session logs land under the configured log path.
log_prefix=${LOG_BASE}

# Chosen log formats (kismetdb is the sqlite superset; wiglecsv feeds maps).
log_types=${LOG_TYPES}
EOF
  if [[ -n "$NRF_DEV" && -e "$NRF_DEV" ]]; then
    cat >> "$KISMET_SITE" <<EOF

# BLE sniffer source: EBYTE E104-BT5040U (nRF52840) via kismet_cap_nrf_52840.
source=nrf52840:device=${NRF_DEV}
EOF
  fi
  ok "Wrote $KISMET_SITE"
}

logtype_menu() {
  banner
  msg "Choose the session log format preset:"
  msg "  1) wiglecsv                 — minimal: AP/BLE locations only"
  msg "  2) kismet,wiglecsv          — RECOMMENDED: sqlite superset + live map csv"
  msg "  3) kismet,pcapng,wiglecsv   — full forensic capture (large files)"
  msg "  4) custom string"
  read -rp "Preset> " p
  case "$p" in
    1) LOG_TYPES="wiglecsv" ;;
    2) LOG_TYPES="kismet,wiglecsv" ;;
    3) LOG_TYPES="kismet,pcapng,wiglecsv" ;;
    4) read -rp "log_types value: " LOG_TYPES ;;
    *) warn "No change."; return 0 ;;
  esac
  save_conf
  ok "LOG_TYPES=$LOG_TYPES (written into kismet_site.conf on session start)"
}

#==============================================================================
# 8/9) Session start & stop
#==============================================================================
# Chain-of-custody style manifest: who, what, where, when, how. A report is
# only defensible if the collection parameters are documented with the data.
write_manifest() {
  local mf="${LOG_BASE}/${SESSION_TITLE}.manifest.txt"
  {
    echo "APTK collection manifest"
    echo "================================"
    echo "session:        $SESSION_TITLE"
    echo "started_utc:    $(date -u '+%Y-%m-%d %H:%M:%S')"
    echo "host:           $(hostname)"
    echo "os:             $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
    echo "kernel:         $(uname -r)"
    echo "wifi_driver:    $DRIVER_MODE"
    echo "wifi_iface:     $WIFI_IF"
    echo "gps_device:     $GPS_DEV"
    echo "bt_hci:         ${BT_HCI:-none}"
    echo "nrf_device:     ${NRF_DEV:-none}"
    echo "log_types:      $LOG_TYPES"
    echo "wardrive_mode:  $WARDRIVE_MODE"
    echo "kismet_version: $(kismet --version 2>/dev/null | head -n1)"
    echo "scope:          passive capture only — no connect / inject / decrypt"
    echo ""
    echo "--- saved config ($CONF_FILE) ---"
    cat "$CONF_FILE" 2>/dev/null
  } > "$mf"
}

fn_start_session() {
  banner
  if ! command -v kismet >/dev/null 2>&1; then
    err "kismet not installed (menu 2)"; pause_ui; return 1
  fi
  if [[ -z "$WIFI_IF" ]]; then
    detect_wifi_if || { err "AWUS1900 interface not detected"; pause_ui; return 1; }
  fi
  usb_present "$WIFI_USB_ID" || warn "AWUS1900 not on lsusb — continuing anyway"
  if systemctl is-active gpsd >/dev/null 2>&1; then
    local f; f=$(gps_fix_mode)
    case "${f:-}" in
      2|3) ok "GPS locked (mode $f)" ;;
      *)   warn "gpsd up but no fix yet — wiglecsv stays EMPTY without a fix" ;;
    esac
  else
    warn "gpsd not active — run menu 4 first or wiglecsv will be empty"
  fi

  mkdir -p "$LOG_BASE" "$PID_DIR"
  SESSION_TITLE="aptk-$(date +%Y%m%d-%H%M%S)"
  write_manifest

  local over=()
  if (( WARDRIVE_MODE )) && [[ -f "$KISMET_WARDDRIVE" ]]; then
    over=(--override wardrive)
  else
    warn "wardrive overlay off/unavailable; kismet_site.conf log settings apply"
  fi

  write_kismet_site || true

  # Kismet command-line -c sources override config sources, so list both.
  local src_args=(-c "$WIFI_IF")
  if [[ -n "$NRF_DEV" && -e "$NRF_DEV" ]]; then
    src_args+=(-c "nrf52840:device=${NRF_DEV}")
    msg "Adding BLE sniffer source: $NRF_DEV"
  fi

  msg "Starting Kismet as '${SESSION_TITLE}'..."
  ( cd "$LOG_BASE" && nohup kismet "${src_args[@]}" "${over[@]}" -t "$SESSION_TITLE" \
      > "${LOG_BASE}/${SESSION_TITLE}.console.log" 2>&1 & \
    echo $! > "${PID_DIR}/kismet.pid" )
  KISMET_PID=$(cat "${PID_DIR}/kismet.pid" 2>/dev/null || echo "")
  sleep 6
  if kismet_running; then
    ok "Kismet running (PID $KISMET_PID)"
    msg " Web UI     : http://localhost:2501"
    msg " Credentials: /root/.kismet/kismet_httpd.conf (auto-generated)"
    msg " Console log: ${LOG_BASE}/${SESSION_TITLE}.console.log"
    msg " Manifest   : ${LOG_BASE}/${SESSION_TITLE}.manifest.txt"
  else
    err "Kismet died at startup. Last console lines:"
    tail -n 25 "${LOG_BASE}/${SESSION_TITLE}.console.log" 2>/dev/null
  fi
  pause_ui
}

stop_session_core() {
  if ! kismet_running; then msg "No active session."; return 0; fi
  kill -INT "$KISMET_PID" 2>/dev/null || kill "$KISMET_PID" 2>/dev/null || true
  local i
  for i in $(seq 1 15); do
    kill -0 "$KISMET_PID" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$KISMET_PID" 2>/dev/null; then
    warn "Still running; sending TERM"
    kill -TERM "$KISMET_PID" 2>/dev/null || true
    sleep 3
  fi
  ok "Session stopped."
  if [[ -n "${SESSION_TITLE:-}" && -f "${LOG_BASE}/${SESSION_TITLE}.manifest.txt" ]]; then
    echo "stopped_utc:    $(date -u '+%Y-%m-%d %H:%M:%S')" >> "${LOG_BASE}/${SESSION_TITLE}.manifest.txt"
  fi
  KISMET_PID=""
  rm -f "${PID_DIR}/kismet.pid"
}

fn_stop_session() {
  banner
  stop_session_core
  if [[ -n "$WIFI_IF" ]]; then
    confirm "Restore managed mode on $WIFI_IF now?" && monitor_off
  fi
  pause_ui
}

#==============================================================================
# 10) Status
#==============================================================================
fn_status() {
  banner
  if kismet_running; then ok "Kismet   : running (PID $KISMET_PID)"
                       else warn "Kismet   : not running"; fi
  if pgrep -x bettercap >/dev/null 2>&1; then ok "bettercap: running"
                                          else msg "bettercap: idle"; fi
  if systemctl is-active gpsd >/dev/null 2>&1; then msg "gpsd     : active"
                                                else warn "gpsd     : down"; fi
  local f; f=$(gps_fix_mode)
  msg "GPS fix  : mode=${f:-none}"
  if [[ -n "$WIFI_IF" ]]; then
    iw dev "$WIFI_IF" info 2>/dev/null | sed 's/^/  /'
  fi
  msg "Log dir  : $LOG_BASE ($(du -sh "$LOG_BASE" 2>/dev/null | cut -f1))"
  df -h "$LOG_BASE" 2>/dev/null | tail -1 | sed 's/^/  /'
  msg "Newest files:"
  ls -lt "$LOG_BASE" 2>/dev/null | head -6 | sed 's/^/  /'
  pause_ui
}

#==============================================================================
# 11) Analyze & export
#==============================================================================
fn_export_menu() {
  while :; do
    banner
    local n=0 f
    msg "Kismet logs in $LOG_BASE:"
    for f in "$LOG_BASE"/*.kismet; do
      msg "  $f"; n=$((n+1))
    done
    (( n == 0 )) && warn "No .kismet (kismetdb) logs found yet."
    msg ""
    msg "  1) Session summary report  (sqlite queries on newest kismetdb)"
    msg "  2) Kismet IDS alerts      (DOS / EXPLOIT / PROBE / SPOOF / SYSTEM)"
    msg "  3) Convert all kismetdb -> wiglecsv (WiGLE/map format)"
    msg "  4) Convert all kismetdb -> kml (Google Earth)"
    msg "  5) Privacy: wiglecsv with exclusion zone (scrub near home)"
    msg "  6) Privacy: sanitized kismetdb copy (strip payloads, redact MACs)"
    msg "  0) Back"
    read -rp "Export> " c
    case "$c" in
      1) fn_report ;;
      2) fn_alerts ;;
      3) export_all kismetdb_to_wiglecsv "wigle.csv" ;;
      4) export_all kismetdb_to_kml "kml" ;;
      5) fn_privacy_exclusion ;;
      6) fn_privacy_sanitize ;;
      0) break ;;
      *) ;;
    esac
  done
}

#------------------------------------------------------------------------------
# 11a) Session summary report — kismetdb is SQLite, so query it directly.
#      Every query tolerates a missing/empty table (old logs degrade
#      gracefully; sqlite3 errors are suppressed per-query).
#------------------------------------------------------------------------------
fn_report() {
  banner
  if ! command -v sqlite3 >/dev/null 2>&1; then
    err "sqlite3 not installed — run menu 2 first"; pause_ui; return 1
  fi
  local f rep
  f=$(ls -t "$LOG_BASE"/*.kismet 2>/dev/null | head -n1)
  if [[ -z "$f" || ! -e "$f" ]]; then
    warn "No .kismet (kismetdb) logs in $LOG_BASE yet."
    pause_ui; return 1
  fi
  rep="${f%.kismet}.report.txt"
  msg "Analyzing $(basename "$f")  ->  $(basename "$rep")"
  echo ""
  {
    echo "APTK session summary"
    echo "source    : $(basename "$f")"
    echo "generated : $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
    echo ""
    echo "[ Time span of observations ]"
    sqlite3 -column "$f" "SELECT datetime(MIN(first_time),'unixepoch') AS first_seen_utc, datetime(MAX(last_time),'unixepoch') AS last_seen_utc FROM devices;" 2>/dev/null
    echo ""
    echo "[ Devices by radio type (phy) ]"
    sqlite3 -column "$f" "SELECT phyname, COUNT(*) AS devices FROM devices GROUP BY phyname ORDER BY devices DESC;" 2>/dev/null
    echo ""
    echo "[ Wi-Fi device types ]"
    sqlite3 -column "$f" "SELECT type, COUNT(*) AS devices FROM devices WHERE phyname='IEEE802.11' GROUP BY type ORDER BY devices DESC;" 2>/dev/null
    echo ""
    echo "[ Signal strength per device, dBm (negative = weaker) ]"
    sqlite3 -column "$f" "SELECT MIN(strongest_signal) AS loudest, CAST(AVG(strongest_signal) AS INT) AS average, MAX(strongest_signal) AS weakest_best FROM devices;" 2>/dev/null
    echo ""
    echo "[ Packets captured ]"
    sqlite3 -column "$f" "SELECT COUNT(*) AS packets, COALESCE(SUM(packet_len),0) AS bytes, ROUND(COALESCE(SUM(packet_len),0)/1048576.0,1) AS mib FROM packets;" 2>/dev/null
    echo ""
    echo "[ EAPOL-tagged frames (passively observed) ]"
    sqlite3 -column "$f" "SELECT COUNT(*) AS eapol_frames FROM packets WHERE tags LIKE '%eapol%';" 2>/dev/null
    echo ""
    echo "[ Channel histogram, MHz (2.4 GHz = 1-14, 5 GHz = 36+) ]"
    sqlite3 -column "$f" "SELECT CAST(ROUND(frequency/1000) AS INT) AS mhz, COUNT(*) AS packets FROM packets WHERE phyname='IEEE802.11' AND frequency > 0 GROUP BY mhz ORDER BY mhz;" 2>/dev/null
    echo ""
    echo "[ Kismet IDS alerts ]"
    sqlite3 -column "$f" "SELECT COUNT(*) AS alerts FROM alerts;" 2>/dev/null
    echo ""
    echo "[ GPS coverage bounds (zeros = no fix during session) ]"
    sqlite3 -column "$f" "SELECT ROUND(MIN(min_lat),6) AS min_lat, ROUND(MIN(min_lon),6) AS min_lon, ROUND(MAX(max_lat),6) AS max_lat, ROUND(MAX(max_lon),6) AS max_lon FROM devices;" 2>/dev/null
    echo ""
    echo "[ Capture datasources ]"
    sqlite3 -column "$f" "SELECT name, interface, typestring FROM datasource;" 2>/dev/null
  } | tee "$rep"
  local csv="${f%.kismet}.wigle.csv"
  if [[ -e "$csv" ]]; then
    echo ""
    fn_wifi_security_stats "$csv" | tee -a "$rep"
  else
    msg "Tip: run option 3 (wiglecsv) on this log, then re-run the report"
    msg "     to add the Wi-Fi security breakdown."
  fi
  ok "Report saved: $rep"
  pause_ui
}

#------------------------------------------------------------------------------
# 11b) Wi-Fi security breakdown from a wiglecsv (AuthMode classification,
#      2.4 vs 5 GHz split, hidden/cloaked SSID count). Real CSV parsing via
#      python3 — quoted SSIDs containing commas are handled correctly.
#------------------------------------------------------------------------------
fn_wifi_security_stats() {
  command -v python3 >/dev/null 2>&1 || { warn "python3 needed for the security breakdown"; return 1; }
  python3 - "$1" <<'PYEOF'
import csv, sys, collections
path = sys.argv[1]
sec = collections.Counter(); band = collections.Counter()
total = 0; hidden = 0
with open(path, newline='', errors='replace') as f:
    if not f.readline().startswith("WigleWifi"):
        f.seek(0)                      # file has no pre-header line
    for row in csv.DictReader(f):
        if (row.get("Type") or "WIFI").upper() != "WIFI":
            continue                   # skip BLE / other radio rows
        auth = row.get("AuthMode") or ""
        total += 1
        if   "WPA3" in auth: sec["WPA3"] += 1
        elif "WPA2" in auth: sec["WPA2"] += 1
        elif "WPA"  in auth: sec["WPA"] += 1
        elif "WEP"  in auth: sec["WEP"] += 1
        else:                sec["OPEN/other"] += 1
        try: ch = int(row.get("Channel") or 0)
        except ValueError: ch = 0
        band["2.4 GHz (ch 1-14)" if 0 < ch <= 14 else "5 GHz"] += 1
        if not (row.get("SSID") or "").strip():
            hidden += 1
print("[ Wi-Fi security breakdown (wiglecsv) ]")
print(f"total AP rows: {total}   hidden/cloaked SSIDs: {hidden}")
for k in ("WPA3", "WPA2", "WPA", "WEP", "OPEN/other"):
    print(f"  {k:<12} {sec[k]:>6}")
for k in ("2.4 GHz (ch 1-14)", "5 GHz"):
    print(f"  {k:<18} {band[k]:>6}")
PYEOF
}

#------------------------------------------------------------------------------
# 11c) IDS alert viewer — Kismet writes detected anomalies (deauth floods,
#      probe floods, spoofed APs, known exploit signatures...) to the alerts
#      table with GPS coordinates, which is evidence-grade documentation.
#------------------------------------------------------------------------------
fn_alerts() {
  banner
  if ! command -v sqlite3 >/dev/null 2>&1; then
    err "sqlite3 not installed — run menu 2 first"; pause_ui; return 1
  fi
  local f count
  f=$(ls -t "$LOG_BASE"/*.kismet 2>/dev/null | head -n1)
  if [[ -z "$f" || ! -e "$f" ]]; then
    warn "No kismetdb logs yet."; pause_ui; return 1
  fi
  count=$(sqlite3 "$f" "SELECT COUNT(*) FROM alerts;" 2>/dev/null)
  count=${count:-0}
  msg "Kismet IDS alerts in $(basename "$f"): $count"
  msg "(categories: DOS / EXPLOIT / PROBE / SPOOF / SYSTEM)"
  echo ""
  if [[ "$count" -gt 0 ]]; then
    sqlite3 -column -header "$f" \
      "SELECT datetime(ts_sec,'unixepoch') AS time_utc, phyname, header, devmac, lat, lon FROM alerts ORDER BY ts_sec;" 2>/dev/null
  else
    ok "No alerts recorded — nothing anomalous detected."
  fi
  pause_ui
}

#------------------------------------------------------------------------------
# 11d) Privacy: wiglecsv export with an exclusion zone. Drops observations
#      within a radius of a sensitive point (e.g. your home) using
#      kismetdb_to_wiglecsv --exclude lat,lon,distance.
#------------------------------------------------------------------------------
fn_privacy_exclusion() {
  banner
  if ! command -v kismetdb_to_wiglecsv >/dev/null 2>&1; then
    err "kismetdb_to_wiglecsv missing (kismet-logtools)"; pause_ui; return 1
  fi
  msg "Export wiglecsv but drop observations near a sensitive location."
  read -rp "Latitude  (e.g. 41.1234): " lat
  read -rp "Longitude (e.g. -73.9876): " lon
  read -rp "Radius in meters (e.g. 200): " dist
  if [[ ! "$lat" =~ ^-?[0-9]+\.?[0-9]*$ || ! "$lon" =~ ^-?[0-9]+\.?[0-9]*$ || ! "$dist" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    err "Invalid coordinates or radius"; pause_ui; return 1
  fi
  local f rc=0
  for f in "$LOG_BASE"/*.kismet; do
    msg "Converting $(basename "$f") (excluding ${dist} m around ${lat},${lon})"
    kismetdb_to_wiglecsv --in "$f" --out "${f%.kismet}.scrubbed.wigle.csv" \
      --exclude "${lat},${lon},${dist}" || rc=1
  done
  if (( rc == 0 )); then ok "Scrubbed wiglecsv exports written to $LOG_BASE"
                    else warn "Some conversions failed."; fi
  pause_ui
}

#------------------------------------------------------------------------------
# 11e) Privacy: sanitized kismetdb copy for sharing — strips packet payloads
#      and redacts MAC columns. Device keys still embed identity; review
#      before releasing the dataset.
#------------------------------------------------------------------------------
fn_privacy_sanitize() {
  banner
  local f copy
  f=$(ls -t "$LOG_BASE"/*.kismet 2>/dev/null | head -n1)
  if [[ -z "$f" || ! -e "$f" ]]; then
    warn "No kismetdb logs yet."; pause_ui; return 1
  fi
  if ! command -v kismetdb_strip_packets >/dev/null 2>&1; then
    err "kismetdb_strip_packets missing (kismet-logtools)"; pause_ui; return 1
  fi
  copy="${f%.kismet}.sanitized.kismet"
  msg "Creating sanitized copy of $(basename "$f") for sharing:"
  msg "  1) strip packet payloads (kismetdb_strip_packets)"
  msg "  2) redact MAC addresses in the copy (sqlite)"
  if ! kismetdb_strip_packets --in "$f" --out "$copy"; then
    err "Strip failed"; pause_ui; return 1
  fi
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$copy" "UPDATE devices SET devmac='00:00:00:00:00:00';
                     UPDATE alerts SET devmac='00:00:00:00:00:00';
                     UPDATE packets SET sourcemac='00:00:00:00:00:00',
                                       destmac='00:00:00:00:00:00',
                                       transmac='00:00:00:00:00:00';" 2>/dev/null || true
  else
    warn "sqlite3 missing — MACs NOT redacted in the copy."
  fi
  ok "Sanitized copy: $copy"
  warn "Device keys (devkey) still embed the original identity — review"
  warn "the dataset before releasing it publicly."
  pause_ui
}

export_all() {
  local tool="$1" ext="$2" f rc=0
  if ! command -v "$tool" >/dev/null 2>&1; then
    err "$tool not installed (kismet-logtools)"; pause_ui; return 1
  fi
  for f in "$LOG_BASE"/*.kismet; do
    msg "Converting $(basename "$f") ..."
    "$tool" --in "$f" --out "${f%.kismet}.${ext}" || rc=1
  done
  if (( rc == 0 )); then ok "Exports written to $LOG_BASE"
                   else warn "Some conversions failed — check kismetdb files."; fi
  pause_ui
}

#==============================================================================
# 12) Cleanup & restore
#==============================================================================
fn_cleanup() {
  banner
  if kismet_running; then
    confirm "Kismet session is running. Stop it now?" && stop_session_core
  fi
  if pgrep -x bettercap >/dev/null 2>&1; then
    confirm "bettercap is running. Kill it?" && pkill -x bettercap
  fi
  if [[ -n "$WIFI_IF" ]]; then
    confirm "Restore managed mode on $WIFI_IF?" && monitor_off
  fi
  if ls /sys/class/bluetooth/hci* >/dev/null 2>&1; then
    if confirm "Power all Bluetooth controllers back on?"; then
      rfkill unblock bluetooth >/dev/null 2>&1 || true
      local h
      for h in /sys/class/bluetooth/hci*; do
        btmgmt -i "${h##*/}" power on >/dev/null 2>&1 || true
      done
      ok "Bluetooth controllers re-enabled."
    fi
  fi
  confirm "Stop gpsd?" && systemctl stop gpsd
  ok "Cleanup done."
  pause_ui
}

#==============================================================================
# Main
#==============================================================================
main() {
  if [[ ${EUID} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -E bash "$0" "$@"
    else
      echo "AccessPointToolKit must run as root."; exit 1
    fi
  fi

  init_colors
  load_conf
  detect_driver_state
  detect_wifi_if || true
  detect_gps_dev || true
  mkdir -p "$PID_DIR"

  trap 'warn "Exiting. Kismet keeps running under nohup — menu 9/12 stops it."' EXIT

  local choice
  while :; do
    draw_menu
    read -r choice
    case "$choice" in
      1)  fn_preflight ;;
      2)  fn_install_deps ;;
      3)  fn_set_logpath ;;
      4)  fn_gps_menu ;;
      5)  fn_bt_menu ;;
      6)  fn_wifi_menu ;;
      7)  fn_kismet_menu ;;
      8)  fn_start_session ;;
      9)  fn_stop_session ;;
      10) fn_status ;;
      11) fn_export_menu ;;
      12) fn_cleanup ;;
      q|Q) confirm "Quit AccessPointToolKit?" && break ;;
      *)  ;;
    esac
  done
  clear
  print_logo
  ok "APTK signing off — drive safe, map responsibly."
}

main "$@"
