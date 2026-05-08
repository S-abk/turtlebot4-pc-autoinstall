#!/usr/bin/env bash
#
# update-usb.sh
# Update user-data and grub.cfg on an already-built USB without rebuilding.
# Use this to tweak hostname, password, packages, etc. without re-copying
# the 2 GB ISO contents.
#
# Usage:
#   ./update-usb.sh /dev/sdX                  # default: hostname tb4-pc, ROS_DOMAIN_ID=0
#   ./update-usb.sh /dev/sdX --pair 7         # tb4-pc-07, ROS_DOMAIN_ID=7
#   ./update-usb.sh /dev/sdX --pair 7 --hostname-prefix tb4-pc
#
# Flags:
#   --pair N               Set hostname suffix and ROS_DOMAIN_ID to N.
#                          N must be 1-100 (Create 3 webserver allows 0-101,
#                          and we reserve 0 for testing/unpaired use).
#                          Hostname becomes <prefix>-NN (zero-padded).
#   --hostname-prefix STR  Override the hostname prefix (default: tb4-pc).
#                          Useful if you have multiple labs/fleets.
#
# Without --pair, the user-data file is written as-is. With --pair, a
# temporary copy is patched and written to the USB, leaving the original
# user-data template untouched for the next PC.

set -euo pipefail

DEV=""
PAIR=""
HOSTNAME_PREFIX="tb4-pc"

# Parse args.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pair)
      PAIR="$2"
      shift 2
      ;;
    --hostname-prefix)
      HOSTNAME_PREFIX="$2"
      shift 2
      ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    /dev/*)
      DEV="$1"
      shift
      ;;
    *)
      echo "ERROR: unknown argument: $1"
      echo "Run with --help for usage."
      exit 1
      ;;
  esac
done

[[ -z "$DEV" ]] && { echo "Usage: $0 /dev/sdX [--pair N] [--hostname-prefix STR]"; exit 1; }
[[ -b "$DEV"  ]] || { echo "ERROR: $DEV is not a block device."; exit 1; }

# Validate --pair.
if [[ -n "$PAIR" ]]; then
  if ! [[ "$PAIR" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --pair must be a number, got: $PAIR"
    exit 1
  fi
  if [[ "$PAIR" -lt 1 || "$PAIR" -gt 100 ]]; then
    echo "ERROR: --pair must be 1-100, got: $PAIR"
    echo "(0 is reserved for testing/unpaired use; >100 isn't supported by Create 3.)"
    exit 1
  fi
fi

if   [[ -b "${DEV}1"  ]]; then PART="${DEV}1"
elif [[ -b "${DEV}p1" ]]; then PART="${DEV}p1"
else echo "ERROR: no partition 1 on $DEV"; exit 1
fi

for f in user-data meta-data; do
  [[ -f "./$f" ]] || { echo "ERROR: ./$f not found in current directory."; exit 1; }
done

# Sanity checks on user-data.
if command -v python3 >/dev/null; then
  python3 -c "import yaml; yaml.safe_load(open('user-data'))" 2>/dev/null \
    || { echo "ERROR: user-data is not valid YAML."; exit 1; }
fi

if grep -q 'REPLACE_ME_WITH_REAL_HASH' user-data; then
  echo "ERROR: user-data still contains the placeholder password hash."
  echo "Generate one with:  mkpasswd -m sha-512"
  exit 1
fi

# Build the user-data we'll actually write. If --pair given, patch a temp copy.
if [[ -n "$PAIR" ]]; then
  PAIR_PADDED=$(printf "%02d" "$PAIR")
  STAGED=$(mktemp /tmp/user-data.XXXXXX)
  cp ./user-data "$STAGED"

  # Replace the hostname line. We assume the template hostname is just the
  # prefix (e.g. "tb4-pc") with no number; this matches our shipped user-data.
  sed -i "s|^\(\s*hostname:\s*\).*$|\1${HOSTNAME_PREFIX}-${PAIR_PADDED}|" "$STAGED"

  # Replace the ROS_DOMAIN_ID. The export is inside a printf string in
  # late-commands, so we look for the literal text and substitute. The
  # default in the template is 0.
  sed -i "s|export ROS_DOMAIN_ID=0|export ROS_DOMAIN_ID=${PAIR}|g" "$STAGED"

  # Verify the patch took. If hostname or domain didn't get replaced, fail loudly.
  if ! grep -q "^\s*hostname:\s*${HOSTNAME_PREFIX}-${PAIR_PADDED}" "$STAGED"; then
    echo "ERROR: failed to substitute hostname in user-data."
    echo "  Expected: '  hostname: ${HOSTNAME_PREFIX}-${PAIR_PADDED}'"
    echo "  Actual:   $(grep '^\s*hostname:' "$STAGED" || echo '(not found)')"
    rm -f "$STAGED"
    exit 1
  fi
  if ! grep -q "export ROS_DOMAIN_ID=${PAIR}" "$STAGED"; then
    echo "ERROR: failed to substitute ROS_DOMAIN_ID in user-data."
    echo "  Make sure your user-data template still has 'export ROS_DOMAIN_ID=0'"
    rm -f "$STAGED"
    exit 1
  fi

  # Re-validate the patched YAML.
  if command -v python3 >/dev/null; then
    python3 -c "import yaml; yaml.safe_load(open('$STAGED'))" 2>/dev/null \
      || { echo "ERROR: patched user-data is not valid YAML (something went wrong with sed)"; rm -f "$STAGED"; exit 1; }
  fi

  USER_DATA_SRC="$STAGED"
  echo "Pair $PAIR: hostname=${HOSTNAME_PREFIX}-${PAIR_PADDED}, ROS_DOMAIN_ID=${PAIR}"
else
  USER_DATA_SRC="./user-data"
  echo "No --pair specified; writing user-data as-is (defaults: hostname=tb4-pc, ROS_DOMAIN_ID=0)"
fi

sudo umount "$PART" 2>/dev/null || true
MNT=$(mktemp -d)
sudo mount "$PART" "$MNT"

# Verify this is actually our installer USB.
if [[ ! -f "$MNT/casper/vmlinuz" ]]; then
  echo "ERROR: $PART doesn't look like an Ubuntu installer USB (no /casper/vmlinuz)."
  echo "Run build-usb.sh from scratch."
  sudo umount "$MNT" || true
  rmdir "$MNT"
  [[ -n "${STAGED:-}" ]] && rm -f "$STAGED"
  exit 1
fi

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

echo "Updating GRUB configs ..."
for cfg in "$MNT/boot/grub/grub.cfg" "$MNT/EFI/boot/grub.cfg" "$MNT/boot/grub/loopback.cfg"; do
  if [[ -d "$(dirname "$cfg")" ]]; then
    echo "$GRUB_BODY" | sudo tee "$cfg" >/dev/null
    echo "  ✓ $cfg"
  fi
done

echo "Updating user-data + meta-data ..."
sudo mkdir -p "$MNT/server"
sudo cp "$USER_DATA_SRC" "$MNT/server/user-data"
sudo cp ./meta-data "$MNT/server/meta-data"

echo "Syncing ..."
sudo sync
sudo umount "$MNT"
rmdir "$MNT"

# Clean up the staged copy if we made one.
[[ -n "${STAGED:-}" ]] && rm -f "$STAGED"

echo "✓ Done. USB updated."
[[ -n "$PAIR" ]] && echo "  Configured for pair $PAIR (${HOSTNAME_PREFIX}-${PAIR_PADDED})."
