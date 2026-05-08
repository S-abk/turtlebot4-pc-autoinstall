#!/usr/bin/env bash
#
# build-usb.sh
# Build a bootable USB stick that auto-installs Ubuntu 22.04 + ROS 2 Humble
# + TurtleBot 4 desktop tools.
#
# Creates a writable FAT32 USB (not a dd'd ISO), copies the Ubuntu Server
# ISO contents, installs GRUB for UEFI, and embeds the autoinstall config.
# Result is fully zero-touch and works on any UEFI PC.
#
# Usage:
#   ./build-usb.sh /dev/sdX /path/to/ubuntu-22.04.X-live-server-amd64.iso
#
# WARNING: this WIPES /dev/sdX completely.

set -euo pipefail

DEV="${1:-}"
ISO="${2:-}"

if [[ -z "$DEV" || -z "$ISO" ]]; then
  cat <<EOF
Usage: $0 /dev/sdX /path/to/ubuntu-22.04.X-live-server-amd64.iso

  /dev/sdX                  USB stick to write to (will be wiped)
  /path/to/...iso           Ubuntu 22.04 SERVER ISO (not Desktop!)

Identify your USB:  lsblk -d -o NAME,SIZE,MODEL,TRAN

Prerequisites in current directory:  user-data, meta-data
Required packages:  parted dosfstools grub-efi-amd64-bin grub-pc-bin rsync

Get the Ubuntu Server ISO from:
  https://releases.ubuntu.com/22.04/

EOF
  exit 1
fi

[[ -b "$DEV" ]] || { echo "ERROR: $DEV is not a block device."; exit 1; }
[[ -f "$ISO" ]] || { echo "ERROR: ISO file $ISO not found."; exit 1; }

for f in user-data meta-data; do
  [[ -f "./$f" ]] || { echo "ERROR: ./$f not found in current directory."; exit 1; }
done

# Validate user-data is real YAML (catches the most common error early).
if command -v python3 >/dev/null; then
  python3 -c "import yaml; yaml.safe_load(open('user-data'))" 2>/dev/null \
    || { echo "ERROR: user-data is not valid YAML. Fix it before building."; exit 1; }
fi

# Warn on placeholder password.
if grep -q 'REPLACE_ME_WITH_REAL_HASH' user-data; then
  echo "ERROR: user-data still contains the placeholder password hash."
  echo "Generate one with:  mkpasswd -m sha-512"
  echo "Then replace REPLACE_ME_WITH_REAL_HASH... in user-data."
  exit 1
fi

# Required tools.
for t in parted mkfs.vfat grub-install rsync; do
  command -v "$t" >/dev/null || {
    echo "Missing tool: $t"
    echo "Install with: sudo apt install parted dosfstools grub-efi-amd64-bin grub-pc-bin rsync"
    exit 1
  }
done

# Confirm the device looks like a USB stick (not internal disk).
TRAN=$(lsblk -d -no TRAN "$DEV" 2>/dev/null || echo "")
SIZE=$(lsblk -d -no SIZE "$DEV" 2>/dev/null || echo "")
MODEL=$(lsblk -d -no MODEL "$DEV" 2>/dev/null || echo "")

echo
echo "About to WIPE: $DEV  ($SIZE, $MODEL, transport=$TRAN)"
if [[ "$TRAN" != "usb" ]]; then
  echo
  echo "  ⚠  WARNING: $DEV's transport is '$TRAN', not 'usb'."
  echo "     If this is your internal disk you're about to destroy your system."
fi
echo
lsblk "$DEV"
echo
read -rp "Type the FULL device path to confirm wipe: " confirm_dev
[[ "$confirm_dev" == "$DEV" ]] || { echo "Mismatch — aborted."; exit 1; }
read -rp "Type YES to actually wipe and proceed: " confirm
[[ "$confirm" == "YES" ]] || { echo "Aborted."; exit 1; }

# Unmount any existing partitions.
for p in $(lsblk -ln -o NAME "$DEV" | tail -n +2); do
  sudo umount "/dev/$p" 2>/dev/null || true
done

echo "[1/7] Wiping partition table ..."
sudo wipefs -a "$DEV"
sudo dd if=/dev/zero of="$DEV" bs=1M count=8 status=none

echo "[2/7] Creating GPT and a single FAT32 partition ..."
sudo parted -s "$DEV" mklabel gpt
sudo parted -s "$DEV" mkpart UBUNTU_TB4 fat32 1MiB 100%
sudo parted -s "$DEV" set 1 esp on
sudo parted -s "$DEV" set 1 boot on
sudo partprobe "$DEV"
sleep 2

if   [[ -b "${DEV}1"  ]]; then PART="${DEV}1"
elif [[ -b "${DEV}p1" ]]; then PART="${DEV}p1"
else echo "ERROR: cannot find partition 1 on $DEV"; exit 1
fi

echo "[3/7] Formatting $PART as FAT32 ..."
sudo mkfs.vfat -F 32 -n UBUNTU_TB4 "$PART"

WORK=$(mktemp -d)
USB_MNT="$WORK/usb"
ISO_MNT="$WORK/iso"
mkdir -p "$USB_MNT" "$ISO_MNT"

echo "[4/7] Mounting USB and ISO ..."
sudo mount "$PART" "$USB_MNT"
sudo mount -o loop,ro "$ISO" "$ISO_MNT"

echo "[5/7] Copying ISO contents to USB (a few minutes) ..."
# --no-links because FAT32 doesn't support symlinks. The 3 symlinks in the
# ISO (/ubuntu, /dists/stable, /dists/unstable) are convenience aliases the
# installer doesn't need.
sudo rsync -ah --info=progress2 --no-links "$ISO_MNT/" "$USB_MNT/"

echo "[6/7] Installing GRUB for UEFI ..."
sudo mkdir -p "$USB_MNT/EFI/BOOT" "$USB_MNT/boot/grub"
sudo grub-install \
  --target=x86_64-efi \
  --efi-directory="$USB_MNT" \
  --boot-directory="$USB_MNT/boot" \
  --removable \
  --recheck \
  --no-nvram

# Write GRUB configs in BOTH locations. UEFI firmware loads /EFI/BOOT/BOOTX64.EFI
# which then reads its config from /EFI/boot/grub.cfg, NOT /boot/grub/grub.cfg.
# Both files need to exist with the autoinstall entry or the firmware will fall
# through to the unmodified one and you'll get an interactive install.
GRUB_BODY='set timeout=5
set default=0

menuentry "Autoinstall TurtleBot4 PC (default)" {
    set gfxpayload=keep
    linux  /casper/vmlinuz quiet autoinstall ds=nocloud\;s=/cdrom/server/ ---
    initrd /casper/initrd
}

menuentry "Try or Install Ubuntu Server (manual)" {
    set gfxpayload=keep
    linux  /casper/vmlinuz quiet ---
    initrd /casper/initrd
}

menuentry "Boot from first hard disk" {
    exit
}'

for cfg in "$USB_MNT/boot/grub/grub.cfg" "$USB_MNT/EFI/boot/grub.cfg" "$USB_MNT/boot/grub/loopback.cfg"; do
  sudo mkdir -p "$(dirname "$cfg")"
  echo "$GRUB_BODY" | sudo tee "$cfg" >/dev/null
done

echo "[7/7] Adding autoinstall config (user-data, meta-data) ..."
sudo mkdir -p "$USB_MNT/server"
sudo cp ./user-data "$USB_MNT/server/user-data"
sudo cp ./meta-data "$USB_MNT/server/meta-data"

echo "Syncing and unmounting (can take 30-60s on slow USB sticks) ..."
sudo sync
sudo umount "$USB_MNT"
sudo umount "$ISO_MNT"
rm -rf "$WORK"

echo
echo "✓ Done. $DEV is ready to boot in UEFI mode."
echo
echo "On each target PC:"
echo "  1. Plug in USB"
echo "  2. Boot menu (F12 / F9 / Esc) → pick the UEFI: entry"
echo "  3. Type 'yes' once when subiquity asks 'Continue with autoinstall?'"
echo "  4. Walk away ~30 minutes"
