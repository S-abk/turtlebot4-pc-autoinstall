# TurtleBot 4 PC Autoinstall USB

A single bootable USB stick that installs **Ubuntu 22.04 Desktop + ROS 2 Humble + TurtleBot 4 desktop tools** on a fleet of PCs, fully unattended. Designed for labs, classrooms, and TurtleBot 4 user-PC fleets.

Boot any PC from this USB, walk away for ~30 minutes, come back to a fully configured machine ready to talk to a TurtleBot 4.

## What you get on each installed PC

- Ubuntu 22.04 LTS Desktop (GNOME)
- ROS 2 Humble Desktop (`ros-humble-desktop`)
- TurtleBot 4 desktop packages (`ros-humble-turtlebot4-desktop`)
- Pre-configured `~/.bashrc` with ROS environment (`source /opt/ros/humble/setup.bash`, `RMW_IMPLEMENTATION=rmw_fastrtps_cpp`, `ROS_DOMAIN_ID=0`)
- `rosdep` initialized
- SSH server enabled
- Standard dev tools (`build-essential`, `git`, `vim`, `curl`)

> **Scope note:** this builds an installer for the *user/desktop PCs* that control TurtleBot 4 robots. The robot's onboard Raspberry Pi is a separate concern — it gets a pre-built image from Clearpath at <http://download.ros.org/downloads/turtlebot4/> flashed to its microSD card. Don't conflate the two.

## Prerequisites

A Linux build machine (Ubuntu 22.04 works best). Install:

```bash
sudo apt update
sudo apt install parted dosfstools grub-efi-amd64-bin grub-pc-bin rsync whois
```

You'll also need:

- A USB stick, **8 GB or larger** (the Ubuntu Server ISO is ~2 GB and we need room for build artifacts)
- The [Ubuntu 22.04 Server ISO](https://releases.ubuntu.com/22.04/) — `ubuntu-22.04.5-live-server-amd64.iso` or newer point release. **Server, not Desktop** — only the Server ISO honors autoinstall directives.

## Quick start

```bash
git clone https://github.com/S-abk/tb4-pc-autoinstall.git
cd tb4-pc-autoinstall

# 1. Generate a password hash for your install user
mkpasswd -m sha-512
# Copy the entire $6$... output

# 2. Edit user-data
nano user-data
# Replace the password placeholder, set hostname/timezone/SSH key as needed

# 3. Validate the YAML (saves a lot of time vs finding errors at boot)
python3 -c "import yaml; yaml.safe_load(open('user-data'))" && echo "YAML valid"

# 4. Identify your USB stick (look for TRAN=usb)
lsblk -d -o NAME,SIZE,MODEL,TRAN

# 5. Build the USB
chmod +x build-usb.sh
./build-usb.sh /dev/sdX ~/Downloads/ubuntu-22.04.5-live-server-amd64.iso
```

Then for each target PC:
1. Plug the USB in
2. Boot from USB (`F12`/`F9`/`Esc` at power-on, varies by manufacturer)
3. Pick the **`UEFI:`** entry (not the legacy/non-UEFI one)
4. GRUB shows "Autoinstall TurtleBot4 PC" — auto-selects after 5 seconds
5. Type `yes` once when subiquity asks "Continue with autoinstall?"
6. Walk away ~30 minutes
7. PC reboots into Ubuntu Desktop, ready to use

## Use Ethernet during install

The autoinstall pulls ~2 GB of packages (Ubuntu Desktop + ROS 2 + TurtleBot 4) from the network. **Wired Ethernet is essentially required** — Wi-Fi during the installer is unreliable for that volume and the installer can't auto-configure Wi-Fi credentials anyway.

## After install — per-PC tweaks

Each fresh PC boots with hostname `tb4-pc` and `ROS_DOMAIN_ID=0`. For paired PC↔robot deployments (recommended for any lab with more than one robot), set both the hostname and the domain ID per machine. See `docs/pairing.md` for the convention and a batch-deploy script.

Quick version:

```bash
sudo hostnamectl set-hostname tb4-pc-07    # use pair number per machine
sed -i 's/export ROS_DOMAIN_ID=0/export ROS_DOMAIN_ID=7/' ~/.bashrc
```

## Verify the install worked

```bash
# In any new shell after install:
ros2 --version
ros2 pkg list | grep turtlebot4    # should show turtlebot4_* packages
echo $RMW_IMPLEMENTATION           # should print: rmw_fastrtps_cpp
```

If those work, the PC is good.

## Files in this repo

| File | Purpose |
|---|---|
| `README.md` | This file. |
| `user-data` | The autoinstall recipe (cloud-init / subiquity format). **Edit this.** |
| `meta-data` | Required-but-empty cloud-init companion file. |
| `build-usb.sh` | Builds the bootable USB from scratch as writable FAT32 + GRUB. |
| `update-usb.sh` | Updates `user-data` and `grub.cfg` on an already-built USB. |
| `validate.sh` | Validates `user-data` YAML and required files before building. |
| `docs/architecture.md` | How the install actually works under the hood. |
| `docs/troubleshooting.md` | Things that go wrong and how to fix them. |
| `docs/pairing.md` | Convention for pairing user PCs with specific robots in a fleet. |
| `create3-pi-setup/` | Companion setup for Raspberry Pi 4 + iRobot Create 3 robots (the *robots*, not the user PCs). See its own README. |

## Parallelizing the rollout

For more than a few PCs, flash multiple USBs from the same build artifacts and install in parallel. Three sticks running on three PCs simultaneously turns a 7-hour rollout into ~2.5 hours.

You can also save the finished USB as a disk image to rebuild later:

```bash
sudo dd if=/dev/sdX of=tb4-installer-golden.img bs=4M status=progress
```

Stash that image somewhere safe — it's your golden master.

## Why this approach

There are several ways to autoinstall Ubuntu, and most of them have sharp edges. See `docs/architecture.md` for why this specific approach (writable FAT32 USB + Server ISO + late-commands package install) is the one that actually works. Short version: every other approach we tried hit a wall.

## License

MIT — do whatever you want with this. If it saves you a weekend, drop a ⭐ on the repo so others can find it.

## Acknowledgments

Based on Canonical's [autoinstall-desktop](https://github.com/canonical/autoinstall-desktop) pattern, with corrections for the Server-ISO-to-Desktop install path that the official example glosses over.
