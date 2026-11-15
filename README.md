# 0llin-Access-Point-Toolkit
A full-screen Bash TUI that turns a laptop into a passive Kismet-based  access-point mapping rig (wardriving) — plus a companion uninstaller that  removes every trace from the machine when you are done
Scope & ethics — read first
PASSIVE RECEPTION ONLY. APTK configures hardware and drives

Kismet and

bettercap to listen: it never connects to,

authenticates with, injects into, or decrypts any third-party network.

Beacon frames and BLE advertisements are unencrypted broadcasts.
·	Wardriving law varies by country and jurisdiction — know your local rules

before capturing anything.
·	Classroom/lab use: get written authorization from your instructor before

any off-campus run.
·	Capture logs contain real-world data — other people's MAC addresses,

SSIDs, and GPS coordinates. Treat them as sensitive; use the built-in

privacy exports (exclusion zone, sanitized kismetdb) before sharing.
Hardware profile
Radio	Device	Chip / driver
WiFi	Alfa AWUS1900	RTL8814AU — in-kernel rtw88_8814au, morrownr/8814au fallback
GPS	VFAN UG-353	u-blox 7 via cdc_acm, feeds gpsd
Bluetooth	Techkey BT863	BT 5.3 + BLE via btusb; BLE survey with bettercap ble.recon
BLE sniffer	EBYTE E104-BT5040U	Nordic nRF52840 serial sniffer via kismet-capture-nrf-52840

Other adapters may work, but auto-detection is wired to these USB IDs.
Requirements
·	Ubuntu/Debian with apt and root access (the script self-elevates via sudo)
·	Bash 4.0+ — everything else is installed by menu option 2
Quick start
chmod +x AccessPointToolKit.sh
sudo ./AccessPointToolKit.sh

Typical first run: 1 pre-flight → 2 install → 4 configure GPS →

6 monitor mode → 8 start session → web UI at

http://localhost:2501 → 11 reports and exports.
During a session Kismet writes kismetdb + wiglecsv logs under /var/log/aptk/

(or your configured path), together with a chain-of-custody style collection

manifest documenting the capture parameters.
Menu reference
#	Option
1	Pre-flight system check
2	Install dependencies (apt + driver + bettercap)
3	Configure log path
4	GPS: status, gpsd config, live fix test, cgps
5	Bluetooth: BT863 power/select, EBYTE sniffer, BLE survey
6	WiFi adapter: monitor/managed mode, channels, NetworkManager unmanaged
7	Kismet options: source, log types, wardrive overlay
8	Start session (manifest + kismet_site.conf + Kismet launch)
9	Stop session
10	Session status
11	Analyze & export: summary report, IDS alerts, wiglecsv/kml, privacy exports
12	Cleanup & restore (runtime cleanup; files and logs kept)
q	Quit

Uninstall
sudo ./AccessPointToolKit-uninstall.sh --dry-run   # preview everything first
sudo ./AccessPointToolKit-uninstall.sh             # interactive
sudo ./AccessPointToolKit-uninstall.sh -y          # non-interactive

The uninstaller removes: APTK's apt packages, the out-of-tree 8814au DKMS

driver (if built), the GitHub-fallback bettercap binary, all of APTK's config

edits (/etc/aptk.conf, gpsd, NetworkManager, kismet_site.conf), and all

capture logs (/var/log/aptk, legacy /var/log/wardrive). It deliberately

keeps python3 (Ubuntu core tooling) and bluez (desktop Bluetooth stack)

so the OS and desktop survive.
Disclaimer
Provided for educational and lawful research use only, with no warranty.

You are responsible for complying with local laws and for the data you collect.
License
Released under the MIT License — see L
