# How this works under the hood

Each design choice in this repo is the result of hitting a wall with the alternative. This doc explains why we do things the way we do — useful if you need to modify the approach or debug something subtle.

## The boot stack

A target PC powered from this USB goes through these layers:

1. **UEFI firmware** loads `/EFI/BOOT/BOOTX64.EFI` from the FAT32 partition (the standard removable-media path). This is a GRUB binary built by `grub-install --removable`.
2. **GRUB** reads its config from `/EFI/boot/grub.cfg` (its own location in the EFI dir, **not** `/boot/grub/grub.cfg`). It boots the Ubuntu Server kernel with `autoinstall ds=nocloud;s=/cdrom/server/` on the kernel command line.
3. **The Ubuntu Server installer (subiquity)** boots, sees `autoinstall` on the kernel cmdline, and looks for cloud-init data at `/cdrom/server/`. It finds `user-data` and `meta-data` there.
4. **Cloud-init** processes the standard cloud-config sections (users, ssh, etc.) and hands the `autoinstall:` block to subiquity.
5. **Subiquity** runs the install according to `autoinstall:` directives — partitioning, base install, package install, late-commands, reboot.

## Why we don't `dd` the ISO

The natural first instinct for "make a bootable USB from an ISO" is `sudo dd if=ubuntu.iso of=/dev/sdX`. That works for unmodified installs but doesn't work for autoinstall, because:

- The result is an ISO9660 filesystem, which is **read-only at the format level**. You can't add `user-data` after flashing.
- Editing the ISO before `dd` (with `xorriso` repacking) breaks the hybrid GPT/MBR boot layout, which makes UEFI firmware refuse to load it.

Our approach: build the USB from scratch with a real FAT32 partition, copy the ISO contents in with `rsync`, and install GRUB to make it bootable. End result: bootable USB with a writable filesystem we can edit at any time.

## Why Server ISO, not Desktop

The Ubuntu 22.04 Desktop installer doesn't honor `autoinstall` directives. Only the Server installer does. The Desktop ISO uses a different installer (Ubiquity) that has no autoinstall support.

Canonical's [official autoinstall-desktop pattern](https://github.com/canonical/autoinstall-desktop) is to use the Server ISO and install `ubuntu-desktop` on top during the install. The end result is functionally identical to a Desktop install — same kernel, same DE, same defaults — just produced by a different installer.

## Why `interactive-sections: []` is mandatory

Without this directive, subiquity defaults individual config sections to "interactive" mode and drops you into the UI, even when the rest of the autoinstall config looks correct. The empty list explicitly says "no sections need human input — run all of them automatically."

This is documented but easy to miss. The symptom is: the installer language menu appears, then the keyboard menu, then the network menu, etc. — autoinstall is technically running, but every step is interactive.

## Why `packages: []` is empty (and we use late-commands instead)

This is the deepest gotcha and the one that cost the most debugging time. Read this carefully.

Subiquity's install flow is:

1. Partition disk
2. Extract base squashfs to target
3. Process `packages:` list — runs `apt-get install --download-only` for each
4. **Restore apt config** — writes `/etc/apt/sources.list` with the network repos and universe enabled
5. Run `late-commands`
6. Reboot

The trap: during step 3, the target's apt source list is hard-coded to `file:///cdrom jammy main restricted` only. **No universe, no multiverse, no network archive.** That apt index only contains a small subset of packages bundled on the Server ISO.

So if you put `ubuntu-desktop` in `packages:`, apt fails with `E: Unable to locate package ubuntu-desktop`. If you put `build-essential` there, it fails the same way. Even some packages that *are* in `main` aren't on the cdrom and fail.

The exit code is a generic `100` and subiquity's UI just says "install failed" with a crash report. The actual apt error is buried in `/var/log/installer/curtin-install.log`.

The fix: leave `packages:` empty. Step 4 (`restore_apt_config`) writes the network sources. Step 5 (`late-commands`) then runs against the target with full network apt access, where `apt install ubuntu-desktop` works exactly like it would on a logged-in system.

This adds ~15 minutes to the install (late-commands has to download packages that would otherwise have been cached during the package phase), but it actually works.

## Why no heredocs in late-commands

YAML's parser doesn't understand bash heredocs. A multi-line `<<EOF ... EOF` block inside a list item gets parsed as new top-level YAML keys. The first line after `<<EOF` becomes the new key, and YAML errors out trying to find a `:`.

```yaml
late-commands:
  - bash -c "cat >> /file <<EOF      # YAML sees: list item containing a string
this is line 1                       # YAML sees: top-level key 'this is line 1'? where's the colon?
EOF"                                 # parse error
```

Use single-line `printf` with explicit `\n` instead:

```yaml
late-commands:
  - bash -c "printf 'line1\nline2\n' >> /file"
```

It's uglier but it parses.

## Why we install GRUB to three config locations

UEFI firmware loads `/EFI/BOOT/BOOTX64.EFI`. That binary then loads its config from a path determined at GRUB build time — and Ubuntu's build of GRUB looks at `/EFI/boot/grub.cfg`, not `/boot/grub/grub.cfg`.

Some build paths (e.g., loop-mounting the USB from another OS) use `/boot/grub/loopback.cfg`. Some legacy fallbacks use `/boot/grub/grub.cfg`.

If you edit only `/boot/grub/grub.cfg` (the obvious-looking one) and not `/EFI/boot/grub.cfg`, your changes are silently ignored when booting via UEFI. We write the same config to all three to be safe.

## Why `geoip: false` in the apt block

By default, subiquity tries to query `geoip.ubuntu.com` to pick the closest mirror. On networks with strict firewalls or slow DNS, this query times out and slows the install by 30+ seconds. Disabling it and pointing directly at `archive.ubuntu.com` is faster and more reliable in environments where the network isn't perfect.

## What's NOT here

Things this repo deliberately doesn't do:

- **Wi-Fi configuration during install** — wired Ethernet is required. We could add a `network:` block with Wi-Fi credentials, but having Wi-Fi passwords in plaintext on the USB is a worse tradeoff than asking users to plug in a cable for 30 minutes.
- **Discovery Server config** — TurtleBot 4 networking depends on your specific topology (Simple Discovery vs. Discovery Server). That's a per-deployment choice; see the [TurtleBot 4 docs](https://turtlebot.github.io/turtlebot4-user-manual/setup/networking.html).
- **Per-PC hostname uniqueness** — every PC boots up as `tb4-pc`. Set unique names with `hostnamectl set-hostname` after install.
- **Robot SD card flashing** — different artifact entirely. Get the Pi image from <http://download.ros.org/downloads/turtlebot4/>.

## Hardware compatibility

Tested on Lenovo desktops with American Megatrends UEFI firmware (2014-era). Should work on any UEFI PC. Legacy BIOS-only machines aren't supported by this build (we don't install the legacy GRUB stage1 because GPT partitioning without a BIOS Boot Partition won't accept it). For legacy BIOS support, the build script would need to create a small (1 MB) BIOS Boot Partition before the FAT32 partition.
