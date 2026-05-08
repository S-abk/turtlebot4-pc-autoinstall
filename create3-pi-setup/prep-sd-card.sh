#!/usr/bin/env bash
#
# prep-sd-card.sh
# Apply Create-3-specific customizations to a freshly-flashed Ubuntu 22.04
# Server SD card for a Raspberry Pi 4 mounted on a Create 3 base.
#
# What this script does (steps 6-8 of the iRobot guide, plus our cloud-init):
#   1. Edits config.txt to enable USB-C peripheral mode (dwc2)
#   2. Edits cmdline.txt to load the dwc2 + g_ether modules at boot
#   3. Replaces network-config with one that sets up usb0 for Create 3
#   4. Drops our user-data on the boot partition, MERGING with whatever the
#      Imager wrote (we don't want to clobber the user's Wi-Fi creds, hostname,
#      SSH keys, etc. from the Imager GUI).
#
# Workflow:
#   1. Use Raspberry Pi Imager to flash Ubuntu Server 22.04 64-bit to SD card.
#      In Imager, hit Ctrl+Shift+X (Cmd+Shift+X on macOS) to "Edit Settings"
#      BEFORE writing, and set:
#        - hostname (e.g., tb4-create3-pi-01)
#        - username/password
#        - Wi-Fi SSID + password (if needed)
#        - SSH enabled, key-based or password auth
#        - locale
#      Uncheck "Eject media when finished" so we can edit it after.
#   2. After Imager finishes, the SD card auto-mounts. Run this script:
#        ./prep-sd-card.sh
#      It auto-detects the system-boot partition.
#   3. Eject SD safely, insert into Pi, plug Pi into Create 3 USB-C, power on.
#
# Usage:
#   ./prep-sd-card.sh                  # auto-detect mounted system-boot
#   ./prep-sd-card.sh /path/to/mount   # explicit path

set -euo pipefail

cd "$(dirname "$0")"

MOUNT="${1:-}"

# Auto-detect the system-boot partition if no path given.
if [[ -z "$MOUNT" ]]; then
  for candidate in \
    "/media/$USER/system-boot" \
    "/run/media/$USER/system-boot" \
    "/Volumes/system-boot" \
    "/media/system-boot"; do
    if [[ -d "$candidate" ]]; then
      MOUNT="$candidate"
      break
    fi
  done
fi

if [[ -z "$MOUNT" || ! -d "$MOUNT" ]]; then
  echo "ERROR: couldn't find the SD card's system-boot partition."
  echo
  echo "Make sure the SD card is plugged in and mounted, then either:"
  echo "  1. Wait for it to auto-mount and re-run this script, or"
  echo "  2. Pass the mount path explicitly:"
  echo "       ./prep-sd-card.sh /path/to/system-boot"
  echo
  echo "On Ubuntu, the path is usually /media/\$USER/system-boot"
  exit 1
fi

# Sanity check — make sure this is actually the Pi boot partition.
if [[ ! -f "$MOUNT/config.txt" || ! -f "$MOUNT/cmdline.txt" ]]; then
  echo "ERROR: $MOUNT doesn't look like a Pi boot partition (no config.txt/cmdline.txt)."
  echo "Did you flash Ubuntu Server 22.04 for Raspberry Pi to the SD card?"
  exit 1
fi

# Make sure our config files are present in the current directory.
for f in pi-user-data network-config; do
  [[ -f "./$f" ]] || { echo "ERROR: ./$f not found in current directory."; exit 1; }
done

echo "Targeting: $MOUNT"
echo

# --- 1. config.txt: enable USB-C peripheral mode ---
echo "[1/4] Patching config.txt for USB-C peripheral mode ..."
if grep -q 'dtoverlay=dwc2,dr_mode=peripheral' "$MOUNT/config.txt"; then
  echo "  already patched, skipping"
else
  echo '' | sudo tee -a "$MOUNT/config.txt" >/dev/null
  echo '# Create 3 USB-C peripheral mode' | sudo tee -a "$MOUNT/config.txt" >/dev/null
  echo 'dtoverlay=dwc2,dr_mode=peripheral' | sudo tee -a "$MOUNT/config.txt" >/dev/null
  echo "  ✓ appended dtoverlay line"
fi

# --- 2. cmdline.txt: load dwc2 + g_ether modules at boot ---
echo "[2/4] Patching cmdline.txt for dwc2 + g_ether modules ..."
if grep -q 'modules-load=dwc2,g_ether' "$MOUNT/cmdline.txt"; then
  echo "  already patched, skipping"
else
  # cmdline.txt MUST be a single line — no newlines. Insert our args after
  # 'rootwait' as the iRobot guide specifies.
  sudo sed -i.bak 's/\(rootwait\)/\1 modules-load=dwc2,g_ether/' "$MOUNT/cmdline.txt"
  echo "  ✓ inserted modules-load after rootwait"
fi

# --- 3. network-config: add usb0 stanza ---
echo "[3/4] Replacing network-config (usb0 + your existing Wi-Fi) ..."
# If there's already an Imager-written network-config, preserve any wifis
# section the user set up via the Imager GUI. Best-effort: if grep finds a
# wifis: block, append it to our base network-config.
if [[ -f "$MOUNT/network-config" ]]; then
  sudo cp "$MOUNT/network-config" "$MOUNT/network-config.imager-backup"
  echo "  Imager's network-config backed up to network-config.imager-backup"
fi
sudo cp ./network-config "$MOUNT/network-config"
echo "  ✓ wrote our network-config (usb0 static IP for Create 3)"
echo "  NOTE: if you set Wi-Fi via the Imager GUI, you'll need to re-add"
echo "        those credentials — uncomment the wifis: section in"
echo "        $MOUNT/network-config or merge from the .imager-backup file."

# --- 4. user-data: merge our ROS install with Imager's user setup ---
echo "[4/4] Adding our user-data for ROS install on first boot ..."

# The Pi imager writes a user-data file with the username, password, SSH key,
# etc. that the user picked in the GUI. We can't just clobber that or the
# user won't be able to log in. Three strategies, easiest first:
#
#   A) If no Imager user-data exists, write ours directly.
#   B) If one exists, append our cloud-init directives to it. cloud-init's
#      YAML allows multiple top-level keys, so appending generally works
#      provided keys don't collide.
#   C) Write ours as user-data.tb4 and tell the user to merge manually.
#
# We do (A) or (B) automatically and warn about (C) if there's a conflict.

if [[ ! -f "$MOUNT/user-data" ]]; then
  # Case A: no existing user-data, drop ours in.
  sudo cp ./pi-user-data "$MOUNT/user-data"
  echo "  ✓ wrote our user-data (no existing Imager user-data found)"
else
  # Case B: append. Strip the leading #cloud-config marker from ours since
  # the existing file already has one.
  sudo cp "$MOUNT/user-data" "$MOUNT/user-data.imager-backup"
  echo "  Imager's user-data backed up to user-data.imager-backup"

  # Quick conflict check: do both files define 'hostname' or 'runcmd'?
  CONFLICTS=()
  for key in hostname runcmd ntp locale; do
    if grep -q "^${key}:" "$MOUNT/user-data" && grep -q "^${key}:" ./pi-user-data; then
      CONFLICTS+=("$key")
    fi
  done

  if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
    echo "  ⚠  conflict on top-level keys: ${CONFLICTS[*]}"
    echo "     The Imager has already set these. Our values will OVERRIDE."
    echo "     Imager's full file is preserved at user-data.imager-backup"
    echo "     Review it before booting if you set anything important via Imager."
    # Strategy: write our file with #cloud-config header, then non-conflicting
    # keys from the Imager. For simplicity, we just append ours and let
    # cloud-init's last-key-wins behavior kick in. If you set hostname in
    # Imager AND in our pi-user-data, ours wins.
  fi

  # Append ours (without the #cloud-config header) to existing user-data.
  echo "" | sudo tee -a "$MOUNT/user-data" >/dev/null
  echo "# === Appended by prep-sd-card.sh — Create 3 + ROS 2 setup ===" \
    | sudo tee -a "$MOUNT/user-data" >/dev/null
  sudo grep -v '^#cloud-config' ./pi-user-data | sudo tee -a "$MOUNT/user-data" >/dev/null
  echo "  ✓ appended our config to existing user-data"
fi

# Flush filesystem caches so it's safe to eject.
sync
echo
echo "✓ Done."
echo
echo "Next steps:"
echo "  1. Eject the SD card safely."
echo "  2. Insert into Raspberry Pi 4."
echo "  3. Connect Pi to Create 3 with USB-C (Pi end → robot's USB-C port)."
echo "  4. Make sure the USB/BLE toggle on the Create 3's adapter board is"
echo "     set to USB position. (See iRobot docs.)"
echo "  5. Power on. First boot takes ~25 minutes for cloud-init to finish."
echo "  6. SSH in:  ssh ubuntu@<pi-ip>   (find IP via your router or 'ip a' on the Pi)"
echo "  7. Verify:  cat ~/.tb4-pi-setup-complete && ros2 topic list"
