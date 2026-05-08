# Troubleshooting

If something goes wrong, here's how to debug it. Order of common failure modes is roughly: USB not booting → autoinstall not picking up config → autoinstall failing partway through.

## The PC boots into the existing OS instead of the USB

**Symptom:** You select the USB in the boot menu but the PC boots its installed Ubuntu/Windows anyway.

Most likely cause: you picked the **non-UEFI** entry. The boot menu often shows two entries for the same USB:

```
UEFI: SanDisk Cruzer ...        ← pick this one
SanDisk Cruzer ...              ← this is legacy BIOS, won't work with our USB
```

If you only see the non-UEFI entry, your firmware has Secure Boot strict mode on (rare) or the USB wasn't built correctly. Disable Secure Boot temporarily and try again.

## Boot succeeds but lands on the language selection menu

**Symptom:** GRUB boots fine, the kernel comes up, then the installer presents the language selection menu (Asturianu / Bahasa / English ...).

This means autoinstall isn't being recognized. Drop into a shell with **`Ctrl-Alt-F2`** on the running installer and check:

```bash
# What kernel command line did GRUB pass?
cat /proc/cmdline
```

Should include `autoinstall ds=nocloud;s=/cdrom/server/`. If not, the GRUB config wasn't picked up — the installer is reading `/EFI/boot/grub.cfg` and yours probably only has the change in `/boot/grub/grub.cfg`. Run `update-usb.sh` to fix both.

```bash
# Did the installer see the user-data?
ls -la /cdrom/server/
```

Should show `user-data` and `meta-data`. If empty, your build didn't copy the autoinstall files.

```bash
# Did cloud-init pick it up?
grep -i nocloud /var/log/cloud-init.log | tail -10
```

Should show `Datasource DataSourceNoCloud [seed=cmdline,...,/cdrom/server/]`. If not, the path in the kernel argument is wrong.

## Subiquity sees the config but every section is "interactive"

**Symptom:** Logs show `apply_autoinstall_config: skipping Locale as interactive`, `skipping Keyboard as interactive`, etc. Installer drops to UI.

Cause: missing `interactive-sections: []` in user-data. Add it as a top-level key inside the `autoinstall:` block.

## Subiquity gets past identity but fails partway through

**Symptom:** The installer runs unattended through several screens, then fails with `An error occurred. Press enter to start a shell.`

**This is almost always an apt failure.** Drop into the shell (`Ctrl-Alt-F2` if needed) and check:

```bash
# What was the actual apt error?
sudo tail -100 /var/log/installer/curtin-install.log

# What does the target's apt source list look like?
sudo cat /target/etc/apt/sources.list

# Try running the failed apt command manually
sudo chroot /target apt-get update
sudo chroot /target apt-get install --download-only -y <package-name>
```

If sources.list shows `file:///cdrom` only, the failure is in the `packages:` step (which uses cdrom-only sources). Move all package installs to `late-commands` (already done in this repo's `user-data`).

If sources.list shows the network sources but apt still fails, it's a network problem:

```bash
ip a              # any interface with an IP?
ip route          # default route?
nslookup archive.ubuntu.com
```

## YAML parse errors in user-data

**Symptom:** Subiquity falls to interactive mode silently. No obvious error in the UI, but the autoinstall log shows `apply_autoinstall_config: skipping X as interactive` for many sections.

Cause: invalid YAML (often a heredoc inside a list item — see `architecture.md`). Validate locally before flashing:

```bash
./validate.sh
```

Or in detail:

```bash
python3 -c "import yaml; yaml.safe_load(open('user-data'))"
```

The most common gotcha: multi-line bash heredocs (`<<EOF ... EOF`) inside `late-commands:` items. YAML's parser misreads them as new top-level keys. Use single-line `printf` instead.

## Install completes but reboots into Ubuntu Server, not Desktop

**Symptom:** Login prompt is text-only with `ubuntu-server@hostname` style.

Cause: `late-commands` failed before `apt install ubuntu-desktop` ran. Check `/var/log/installer/curtin-install.log` from the live system or via SSH (since `openssh-server` was installed early).

Fix: the late-commands run sequentially, so a failure in one halts the rest. Look at the log to find which command failed and why. Most common is a transient network failure during a big apt download.

You can finish the install manually:

```bash
sudo apt update
sudo apt install -y ubuntu-desktop
sudo reboot
```

## Install completes but ROS doesn't work

**Symptom:** PC boots into Desktop but `ros2 topic list` says command not found.

Cause: `late-commands` failed after `ubuntu-desktop` but before ROS install. Check `/var/log/installer/` and the late-commands part of subiquity's log.

Fix manually:

```bash
sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu jammy main" | sudo tee /etc/apt/sources.list.d/ros2.list
sudo apt update
sudo apt install -y ros-humble-desktop ros-humble-turtlebot4-desktop python3-rosdep
sudo rosdep init
rosdep update
echo "" >> ~/.bashrc
echo "# ROS 2 Humble + TurtleBot 4" >> ~/.bashrc
echo "source /opt/ros/humble/setup.bash" >> ~/.bashrc
echo "export RMW_IMPLEMENTATION=rmw_fastrtps_cpp" >> ~/.bashrc
echo "export ROS_DOMAIN_ID=0" >> ~/.bashrc
```

## USB build script fails

**`grub-install: warning: this GPT partition label contains no BIOS Boot Partition`**

Harmless — it's a warning about legacy BIOS support, which we deliberately don't enable. The UEFI install proceeds and that's all we need.

**`grub-install: error: cannot find a GRUB drive for /dev/sdX`**

The USB stick is in some weird state. Reboot your build machine and try again, or run `wipefs -a /dev/sdX` first.

**`mkfs.fat 4.2: bash: mkfs.fat: command not found`**

Install with: `sudo apt install dosfstools`

**rsync warns about "skipping non-regular file"**

Expected. The Ubuntu ISO has 3 symlinks (`/ubuntu`, `/dists/stable`, `/dists/unstable`) that FAT32 doesn't support. They're convenience aliases the installer doesn't need. The `--no-links` flag in the script tells rsync to skip them silently — if you see this warning anyway, your rsync is older and uses different verbose output but the result is the same.

## Recovering after install: setting unique hostnames at scale

If you've installed all 15 PCs and they all boot up as `tb4-pc`, do this on each one:

```bash
# pick a number for each PC (01..15)
sudo hostnamectl set-hostname tb4-pc-NN

# update /etc/hosts so sudo doesn't complain
sudo sed -i "s/tb4-pc/tb4-pc-NN/g" /etc/hosts
```

Or use Ansible if you want to do it from your build machine over SSH for all 15.
