# Pairing PCs with robots

In a lab setting, each user PC is typically paired with a specific Create 3 robot. Making the pairing **visible** (in hostnames) and **enforced** (in `ROS_DOMAIN_ID`) saves a lot of debugging when something goes wrong. This doc explains the convention this repo uses and how to apply it across a fleet.

## The convention

For pair number `N` (where `N` is 01, 02, 03, ... up to your fleet size):

| Component | Hostname | `ROS_DOMAIN_ID` |
|---|---|---|
| User PC | `tb4-pc-NN` | `N` |
| Robot's Pi | `tb4-create3-pi-NN` | `N` |
| Create 3 itself | `tb4-create3-NN` (set via webserver) | `N` (set via webserver) |

So the trio that belongs together is `tb4-pc-07` ↔ `tb4-create3-pi-07` ↔ `tb4-create3-07`, all on `ROS_DOMAIN_ID=7`.

**Reserve `ROS_DOMAIN_ID=0`** for ad-hoc testing, demos, or any unpaired use. Anything in 1–100 is fair game for actual pairs (the Create 3 webserver only accepts 0–101).

## Why both hostnames and domain IDs?

- **Hostnames** are for humans — when you're standing in front of 10 identical robots and need to know which one to power-cycle, the LCD screen showing `tb4-create3-07` is what saves you.
- **`ROS_DOMAIN_ID`** is what ROS 2 actually uses to isolate communication. Two pairs on the same physical network with the same domain ID will see each other's topics — leading to "why did robot 4 move when I commanded robot 7?".

Hostname alone won't isolate ROS traffic. Domain ID alone makes the network behavior right but leaves you guessing which robot is which. Use both.

## Setting the pair number per PC

The `update-usb.sh` script accepts a `--pair N` flag that handles the customization for you. This is the recommended workflow:

```bash
# For each PC in turn:
./update-usb.sh /dev/sda --pair 1     # boot PC-01 with this USB
./update-usb.sh /dev/sda --pair 2     # boot PC-02 with this USB
./update-usb.sh /dev/sda --pair 7     # boot PC-07 with this USB
# ...
```

The flag substitutes both the hostname (`tb4-pc-07`) and the `ROS_DOMAIN_ID` (`7`) in a temporary copy of `user-data` before writing it to the USB. Your original template stays untouched. Validation is automatic — the script aborts if the substitutions don't produce valid YAML or the expected output.

If you need a non-default hostname prefix (e.g., for a second lab), pass `--hostname-prefix`:

```bash
./update-usb.sh /dev/sda --pair 7 --hostname-prefix lab2-pc
# → hostname: lab2-pc-07, ROS_DOMAIN_ID=7
```

If you skip `--pair`, you get the unmodified template (`hostname: tb4-pc`, `ROS_DOMAIN_ID=0`) — useful for one-off testing.

### Alternative: post-install via SSH

If you've already booted PCs without `--pair` and want to customize them after the fact:

```bash
ssh [email protected]    # find IP via DHCP table

sudo hostnamectl set-hostname tb4-pc-07
sudo sed -i 's/tb4-pc/tb4-pc-07/g' /etc/hosts
sed -i 's/export ROS_DOMAIN_ID=0/export ROS_DOMAIN_ID=7/' ~/.bashrc

# log out and back in
```

See the `customize-pair.sh` example below for an SSH-loop version.

## Setting the pair number per Pi

For the Pi side, the cleanest path is to set the hostname directly in **Raspberry Pi Imager's "Edit Settings" GUI** (Ctrl+Shift+X) before flashing each card. Imager bakes it into its own `user-data` and the result survives our `prep-sd-card.sh` merge cleanly.

Steps per SD card:
1. In Imager's Edit Settings, set hostname to e.g. `tb4-create3-pi-07` (use a unique pad number per robot).
2. Flash, run `./prep-sd-card.sh`.
3. The `ROS_DOMAIN_ID` defaults to 0 in the cloud-init script. Set it post-boot via SSH (see below) or edit `pi-user-data` before running `prep-sd-card.sh` if you'd rather bake it in.

### Post-install via SSH (recommended for a fleet)

Once the Pi has booted and finished its first-boot ROS install, SSH in:

```bash
ssh [email protected]    # the Pi's Wi-Fi IP

sudo hostnamectl set-hostname tb4-create3-pi-07     # if you didn't set in Imager
sudo sed -i 's/tb4-create3-pi/tb4-create3-pi-07/g' /etc/hosts
sed -i 's/export ROS_DOMAIN_ID=0/export ROS_DOMAIN_ID=7/' ~/.bashrc
```

## Setting the pair number on the Create 3

The Create 3 has its own webserver UI that handles its hostname and `ROS_DOMAIN_ID`. Steps:

1. Connect to the robot's Wi-Fi setup mode (hold dock button until the LED ring spirals — see [iRobot's provisioning doc](https://iroboteducation.github.io/create3_docs/setup/provision/)).
2. Open the webserver in a browser at the robot's IP.
3. Under **Application Configuration**:
   - Set hostname (e.g., `tb4-create3-07`)
   - Set `ROS_DOMAIN_ID` (e.g., `7`)
   - Set RMW Implementation to **FastRTPS** (matches the PCs and Pi)
4. Apply settings → robot reboots with new config.

## Suggested batch-deploy script

If you have a list of pair numbers, this kind of loop saves a lot of typing:

```bash
#!/usr/bin/env bash
# customize-pair.sh
# Run after a PC and Pi have booted with default config.
# Customizes them as a paired fleet member.

set -e
PAIR_NUM="${1:?Usage: $0 <pair-number> <pc-ip> <pi-ip>}"
PC_IP="${2:?Usage: $0 <pair-number> <pc-ip> <pi-ip>}"
PI_IP="${3:?Usage: $0 <pair-number> <pc-ip> <pi-ip>}"

PAIR_PADDED=$(printf "%02d" "$PAIR_NUM")

echo "Configuring PC at $PC_IP as tb4-pc-$PAIR_PADDED ..."
ssh "turtlebot@$PC_IP" "sudo hostnamectl set-hostname tb4-pc-$PAIR_PADDED && \
  sudo sed -i 's/tb4-pc/tb4-pc-$PAIR_PADDED/g' /etc/hosts && \
  sed -i 's/export ROS_DOMAIN_ID=0/export ROS_DOMAIN_ID=$PAIR_NUM/' ~/.bashrc"

echo "Configuring Pi at $PI_IP as tb4-create3-pi-$PAIR_PADDED ..."
ssh "ubuntu@$PI_IP" "sudo hostnamectl set-hostname tb4-create3-pi-$PAIR_PADDED && \
  sudo sed -i 's/tb4-create3-pi/tb4-create3-pi-$PAIR_PADDED/g' /etc/hosts && \
  sed -i 's/export ROS_DOMAIN_ID=0/export ROS_DOMAIN_ID=$PAIR_NUM/' ~/.bashrc"

echo "✓ Pair $PAIR_PADDED configured on PC and Pi sides."
echo "  Don't forget to set Create 3 ROS_DOMAIN_ID=$PAIR_NUM via its webserver."
```

Usage:
```bash
./customize-pair.sh 7 192.168.1.107 192.168.1.207
```

## Verifying a pair is correctly configured

From the user PC after re-login:

```bash
echo $ROS_DOMAIN_ID            # should match pair number
hostname                       # should be tb4-pc-NN

# Robot should be visible:
ros2 topic list                # should show /odom, /battery_state, etc.

# Confirm topics are coming from THIS pair's robot only:
ros2 node list                 # should not show nodes from other pairs
```

If you see nodes from other pairs, two things to check:
1. Did the Create 3's `ROS_DOMAIN_ID` actually get set via the webserver? (It silently defaults to 0.)
2. Is everything actually using FastRTPS? Check `echo $RMW_IMPLEMENTATION` on each.

## Why not just use namespaces instead of domain IDs?

ROS 2 namespaces are a different mechanism — they prefix topic names (e.g., `/robot7/odom` vs `/robot4/odom`). They work, but:

- Domain IDs **isolate at the DDS layer** so traffic between pairs doesn't even hit each other's network stack. Cleaner separation.
- Domain IDs match how the Create 3 webserver is designed (you set a single domain ID per robot).
- Namespaces require every node to be launched with the namespace argument, which is one more thing to forget.

For paired PC↔robot setups, domain IDs are the right tool. Namespaces are better when one robot has multiple sensor nodes that you want to logically group.
