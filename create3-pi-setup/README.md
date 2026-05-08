# Create 3 + Raspberry Pi 4 Setup

Automated setup for a Raspberry Pi 4 mounted on an iRobot Create 3 base, running headless Ubuntu Server 22.04 + ROS 2 Humble + iRobot Create 3 message packages.

Companion to the user-PC autoinstall in the parent directory. The user PCs (where you sit and run RViz / teleop / your code) talk to *these* robots over Wi-Fi.

## What you get on each Pi

- Ubuntu Server 22.04 LTS (arm64), headless
- ROS 2 Humble (`ros-humble-ros-base` — the headless variant, no GUI deps)
- `ros-humble-irobot-create-msgs` (the Create 3 message definitions)
- `colcon`, `rosdep` initialized
- `~/.bashrc` configured: `source /opt/ros/humble/setup.bash`, `RMW_IMPLEMENTATION=rmw_fastrtps_cpp`, `ROS_DOMAIN_ID=0`
- USB-C peripheral mode enabled so the Pi can talk to the Create 3
- `usb0` static IP `192.168.186.3/24` (Create 3 expects `.2` on its end)
- NTP enabled (Create 3 syncs time from the Pi)

## Architecture: how this differs from the PC autoinstall

The PC side uses a custom subiquity autoinstall flow because Ubuntu Desktop on x86 is delivered via an installer. The Pi side is fundamentally different: **Ubuntu Server for Raspberry Pi ships as a pre-installed disk image**, so there's no installer to customize. Instead, we use **cloud-init** — Ubuntu Pi images already run cloud-init on first boot to set up your user account, Wi-Fi, etc. (that's what Raspberry Pi Imager's "Edit Settings" GUI is doing under the hood).

We hook the same cloud-init mechanism to also run our ROS install.

There's no equivalent of the autoinstall USB build step — flashing happens through Raspberry Pi Imager (the official, well-supported tool). All we do after Imager finishes is drop a few extra files onto the SD card's boot partition.

## Workflow

### One-time setup (build machine)

Install Raspberry Pi Imager:

```bash
sudo snap install rpi-imager
```

(Or download from <https://www.raspberrypi.com/software/>.)

### Per SD card

#### 1. Flash with Raspberry Pi Imager

1. Open `rpi-imager`.
2. **Operating System** → "Other general-purpose OS" → "Ubuntu" → **"Ubuntu Server 22.04 LTS (64-bit)"**.
3. **Storage** → pick your SD card.
4. **`Ctrl+Shift+X`** (or click the gear icon) to open "Advanced options". Set:
   - Set hostname (e.g., `tb4-create3-pi-01` — give each robot a unique one)
   - Set username and password (default `ubuntu`/`ubuntu` is fine for a controlled lab)
   - Configure Wi-Fi if needed (SSID, password, country)
   - Enable SSH (key auth recommended for fleet management)
   - Set locale
5. **Uncheck "Eject media when finished"** so we can edit the boot partition afterward.
6. **WRITE** (or NEXT). Takes ~5 minutes.

#### 2. Apply Create 3 customizations

After Imager finishes, the SD card's `system-boot` partition auto-mounts. Then:

```bash
cd create3-pi-setup
chmod +x prep-sd-card.sh
./prep-sd-card.sh
```

The script:
- Adds `dtoverlay=dwc2,dr_mode=peripheral` to `config.txt` (USB-C peripheral mode)
- Adds `modules-load=dwc2,g_ether` to `cmdline.txt` (load USB-C ethernet modules at boot)
- Replaces `network-config` with one that adds `usb0` static IP for the Create 3
- Appends our `pi-user-data` to the Imager's `user-data` so cloud-init runs the ROS install on first boot

It auto-detects the SD card's mount point. If detection fails, pass it explicitly:

```bash
./prep-sd-card.sh /media/$USER/system-boot
```

#### 3. Boot the Pi

1. Eject the SD card safely.
2. Insert into the Raspberry Pi 4.
3. Connect Pi to Create 3 with a USB-C cable (Pi end → Create 3's USB-C port).
4. **Verify the Create 3's adapter board USB/BLE toggle is set to USB.** ([Adapter board reference](https://iroboteducation.github.io/create3_docs/hw/electrical/#adapter-board-overview).)
5. Power on the Create 3 (which now also powers the Pi over USB-C).
6. **First boot takes ~25 minutes** for cloud-init to install ROS 2 and dependencies. The Pi has no monitor by default — be patient. You can SSH in once it has an IP, but `ros2` won't work until the install finishes.

#### 4. Verify

SSH into the Pi (find its IP via your router's DHCP table, or scan with `nmap`):

```bash
ssh ubuntu@<pi-ip>

# Check our marker file (only exists if cloud-init finished successfully):
cat ~/.tb4-pi-setup-complete

# Verify ROS:
ros2 topic list

# You should see Create 3 topics (/odom, /battery_state, /imu, etc.) once
# the Pi can reach the Create 3 over usb0:
ping -c 3 192.168.186.2
```

## Multi-robot deployment

For 5+ robots, the easy path is:

1. Flash all SD cards in batch using a USB hub with multiple readers, or one at a time.
2. **Set unique hostnames** in the Imager GUI for each (e.g., `-01`, `-02`, ... `-15`).
3. Run `prep-sd-card.sh` against each SD card after Imager finishes.
4. Boot all Pis. They'll independently run cloud-init and reach a steady state in ~25 min.

If you want each robot to use a different `ROS_DOMAIN_ID` (recommended when more than one robot+PC pair share the same network), edit `pi-user-data` per-flash, or change `ROS_DOMAIN_ID` in `~/.bashrc` after first boot.

## Matching the Create 3's RMW

The Pi is configured for `rmw_fastrtps_cpp` to match your user PCs.

**The Create 3 robot itself must be configured to match.** On the Create 3:
1. Connect to its Wi-Fi setup mode and find its webserver page (see [iRobot setup docs](https://iroboteducation.github.io/create3_docs/setup/provision/)).
2. In the Application Configuration page, set the RMW to **FastRTPS**.
3. Reboot the Create 3.

Without this, the Pi and Create 3 won't see each other's topics even though the network connection is fine.

## Troubleshooting

**Pi boots but cloud-init never finishes.**
First boot really does take ~25 minutes — be patient. If it's been over an hour, SSH in and check `cloud-init status --long` and `journalctl -u cloud-final`. Most common cause is no internet (the Pi can't reach `packages.ros.org` to download ROS).

**Pi has no internet on first boot.**
Either Wi-Fi creds wrong (re-flash with corrected Imager settings) or no Ethernet. The Create 3 USB-C link doesn't provide internet — it's only the Pi↔robot link. The Pi needs Wi-Fi or its own Ethernet for the ROS install to download.

**`ros2 topic list` shows nothing or hangs.**
Either RMW mismatch (Pi vs Create 3) or the Pi can't reach the Create 3 over usb0:
```bash
ip a show usb0           # should have IP 192.168.186.3
ping 192.168.186.2       # should reach the Create 3
```
If `usb0` doesn't exist, check `dmesg | grep dwc2` — the kernel module should have loaded. If not, the boot edits to `config.txt`/`cmdline.txt` didn't take.

**Marker file `~/.tb4-pi-setup-complete` doesn't exist after boot.**
cloud-init's `runcmd` failed partway. Check `/var/log/cloud-init-output.log` for the failing command. Most common: apt couldn't reach a mirror.

**SSH refuses my password.**
Default Ubuntu Server Pi image forces a password change on first login *if* you didn't set one in Imager. Use the Imager's "Edit Settings" to set the password explicitly.

## Files in this directory

| File | Purpose |
|---|---|
| `README.md` | This file. |
| `pi-user-data` | Cloud-init config for first-boot ROS install. |
| `network-config` | Replaces the SD card's network-config with one that includes the `usb0` Create 3 link. |
| `prep-sd-card.sh` | Applies all customizations to a freshly-flashed SD card. |

## References

- [iRobot Education: Connect Create 3 to Raspberry Pi 4 (Humble)](https://iroboteducation.github.io/create3_docs/setup/pi4humble/) — the doc this is based on
- [Create 3 Multi-Robot Setup](https://iroboteducation.github.io/create3_docs/setup/multi-robot/)
- [Cloud-init NoCloud datasource docs](https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html)
- [Raspberry Pi cloud-init guide](https://ubuntu.com/tutorials/how-to-install-ubuntu-on-your-raspberry-pi)
