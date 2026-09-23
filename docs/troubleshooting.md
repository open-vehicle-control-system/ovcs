---
title: Troubleshooting
description: The failures newcomers hit most, collected in one place, each with the check that names the cause.
---

Each entry gives the check that names the cause, then the fix. Start with `./ovcs doctor`: it catches the toolchain half of this list on its own. Where an example names OVCS1, OVCS Mini or OBD2, substitute your own application's name, module or channel layout.

## Setup and toolchain

### Firmware builds fail, or an image flashes and then fails at boot

**Check:** `elixir --version` in the repo reports Erlang/OTP **28** and Elixir **1.19**.

**Cause:** Nerves compiles BEAM files with the host OTP and packages them with the target system's runtime; the OTP majors must agree, and nothing checks host against target. **Fix:** `mise install` at the repo root; don't install Elixir any other way. See [Toolchain and OTP](./toolchain_and_otp.md).

### `fwup: command not found`

**Cause:** `fwup` is not in the Debian/Ubuntu repositories. **Fix:** install the `.deb` from its GitHub releases, as in [Getting started](./getting_started.md). On macOS, `brew install fwup`.

### `./ovcs can setup` fails with `modprobe: Operation not permitted` (Bluefin, Silverblue, distrobox)

**Cause:** a rootless container cannot load kernel modules or create network interfaces, `--privileged` or not. **Fix:** provision `vcan` and the interfaces once **on the host**, with the systemd one-shot in [Getting started](./getting_started.md). The CLI then finds them up and does nothing.

### `mise: command not found` inside the distrobox

**Cause:** the host's Homebrew `mise` is not mounted into the container. **Fix:** run the mise installer inside the container, then add `~/.local/bin` to `PATH` and `eval "$(mise activate bash)"` to the container's `~/.bashrc`.

### `git: command not found` or `lsmod: command not found` in a fresh container

**Cause:** minimal Ubuntu images ship neither. **Fix:** `sudo apt install -y git kmod`. `mise run libraries` needs `git`; `./ovcs can setup` needs `kmod`.

## Virtual CAN

### `Cannot find device vcan0`

**Check:** `ip -br link show | grep vcan`.

**Fix:** `./ovcs can setup <app>`. If loading the module fails:

```sh
sudo modprobe can
sudo modprobe can_raw
sudo modprobe vcan
```

`vcan` ships only with standard, non-cloud kernels. On macOS you need a full Linux VM; see [Getting started](./getting_started.md).

### Frames are sent but nothing changes on the dashboard

**Check**, in order:

1. `VEHICLE` is your application's top-level module name, case-sensitive (`Ovcs1`, `OvcsMini`, `Obd2` for the references).
2. `./ovcs can status <app>` lists the interfaces, and `CAN_NETWORK_MAPPINGS` (or the composer's default host mapping) routes the target network to the interface you send on.
3. The frame is one the VMS **receives** on that network. In the OVCS1 reference application, the handbrake frame `0x320` belongs to `polo_drive`, which is `vcan2` on the host. A frame the VMS only emits, such as `0x280`, changes nothing when injected.

## Running locally

### Edits to the dashboard don't show up

**Cause:** `http://localhost:4000` serves the last prebuilt bundle from `vms/api/priv/static/`. **Fix:** open the Vite dev server `./ovcs run` starts as an add-on, usually `http://localhost:5173`.

### The stereo pipeline never starts against the simulator

**Check:** the environment the bridge was started with.

**Cause:** without `BRIDGE_FIRMWARE_ID`, the bridge falls back to the id compiled into the host build (`radio_control`) and silently starts the joy and IMU wiring. **Fix:** `BRIDGE_FIRMWARE_ID=ros_perception` together with `OVCS_SIM=1`, as in [Simulation](../compose/local/simulation/README.md).

### Cantastic dies: "CAN network mappings are missing"

**Cause:** the bridge was started from `bridges/ros_bridge`. The bridge library has no `config/`, so `CAN_NETWORK_MAPPINGS` is never read there. **Fix:** start from `bridges/firmware`, as `./ovcs run` does, with `CAN_NETWORK_MAPPINGS=ovcs:vcan0`.

### The control level never leaves `:manual` on the host

**Cause:** on the host there is no RC receiver and no generic controller, so nothing emits the switch frames (`0x2A0`, `0x2A1`) or the pulse counter (`0x709`). With an unknown speed every mode change is refused with `:speed_unknown`. **Fix:** synthesise both. A speed stream first, in its own terminal (zero count and frequency is a stationary vehicle):

```sh
cangen vcan0 -I 709 -L 4 -D 00000000 -g 10
```

Then the switches, in the OVCS Mini reference application's channel layout. Values are little-endian `uint16` microseconds: 1000 is `E803`, 1500 is `DC05`, 2000 is `D007`.

```sh
cansend vcan0 2A0#DC05DC0500000000   # steering and throttle centred
cansend vcan0 2A1#E803DC0500000000   # channel 6 = 1500: level :radio
cansend vcan0 2A1#E803D00700000000   # channel 6 = 2000: level :ros (only reachable from :radio)
cansend vcan0 2A1#D007D00700000000   # channel 5 = 2000: commander :autonomous (needs a standstill)
```

`ready_to_drive` must be true as well; the Mini hardcodes it. Details in [Your application package](./vehicle_parameterisation.md#driving-on-the-host-bench).

## Generic controllers

### The controller stays in `ADOPTION_REQUIRED`

**Check:** `candump vcan0,700:7FF` (or the `ovcs` bus interface on the vehicle) shows the VMS emitting the configuration frame `0x700` during adoption.

**Fix:** clicking Adopt, or `trigger_action("adopt", …)`, broadcasts the configuration for one second; press the adoption button (pin D2) within it. Check the Arduino's USB serial output for parse errors.

### The controller goes to `VMS_MISSING_ERROR`

**Check:** `candump vcan0,1A0:7FF` shows the VMS heartbeat every 100 ms, and `CAN_NETWORK_MAPPINGS` routes `ovcs` to the interface the controller is on.

**Cause:** every VMS reboot, and so every redeploy, stops the heartbeat longer than the controller tolerates. The VMS resets the controllers itself three seconds after booting, so it usually clears on its own. If not, from IEx on the VMS:

```elixir
VmsCore.Status.trigger_action("reset_status", %{})
```

### The controller goes to `EXPANSION_BOARDS_ERROR`

**Check:** I2C wiring (SDA on A4, SCL on A5) and that the MCP23008 expansion boards answer at `0x20` and `0x21`.

### Flashing fails with `LIBUSB_ERROR_ACCESS` (`Cannot open DFU device 2341:0069`)

**Cause:** no udev rule for the Arduino R4 Minima. **Fix:** add the rule once per host, reload, then replug the board. Double-tap reset if the upload doesn't drop it into DFU.

```sh
sudo tee /etc/udev/rules.d/60-arduino-uno-r4.rules >/dev/null <<'EOF'
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2341", ATTRS{idProduct}=="0069", MODE="0666"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2341", ATTRS{idProduct}=="1002", MODE="0666"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2341", ATTRS{idProduct}=="0369", MODE="0666"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="2341", ATTRS{idProduct}=="1102", MODE="0666"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger
```

## Hardware and deployment

### `REMOTE HOST IDENTIFICATION HAS CHANGED` after every burn

**Cause:** a fresh SD-card burn regenerates the device's SSH host key. **Fix:** generate persistent per-role keys once; the firmware ships them and the identity survives burns.

```sh
./ovcs host-keys generate <app>
./ovcs host-keys verify <app>     # exit 1 if any role is missing keys
```

### The build asks for SSH keys, Wi-Fi or Phoenix secrets

**Cause:** `vehicles/<app>/.env.exs` doesn't exist. **Fix:** copy `.env.exs.example` next to it and fill in `AUTHORIZED_SSH_KEYS`, `WIFI_NETWORKS`, `SECRET_KEY_BASE` and `SIGNING_SALT`. The file is gitignored and shared by every firmware of that application.

### `./ovcs attach` or `connect` cannot reach the device

**Check:** `ping <app>-vms.local` (underscores become dashes: `ovcs-mini-vms.local`) and `ssh-add -l`.

**Cause:** mDNS is not resolving, your key is not loaded in `ssh-agent`, or your public key was not in `AUTHORIZED_SSH_KEYS` when the firmware was built. **Fix:** rebuild with the key, load it into the agent, or bypass mDNS with `./ovcs connect <app> vms --host <ip>`.

### A board's wired `10.42.0.x` address is unreachable from the site Wi-Fi

**Cause:** on a vehicle with a compute node (the OVCS Mini reference application has one), the wired network is NATed and forwards nothing in. **Fix:** join the vehicle's own access point, or hop through the compute node with one block in `~/.ssh/config`. `./ovcs upload` and `./ovcs connect --host` run `ssh` underneath, so they follow it. See [ROS compute node](./ros_compute_node.md).

```text
Host 10.42.0.*
    ProxyJump root@COMPUTE_NODE_SITE_ADDRESS:22222
    StrictHostKeyChecking accept-new
```

### A bridge peers with the wrong Zenoh router, or with `127.0.0.1`

**Cause:** `ZENOH_ENDPOINT_IP` is baked into the bridge firmware **at build time**, not read at boot. A firmware built before the address changed keeps the old one; one built without it falls back to loopback. **Fix:** set it in `vehicles/<app>/.env.exs`, then rebuild and re-upload every `RosBridge` firmware of that application.

## ROS 2 and simulation

### `ros2 topic echo` fails with `unknown tag 'rclpy.topic_endpoint_info.TopicEndpointInfo'`

**Cause:** a `ros2cli` daemon bug. **Fix:** `ros2 topic echo --no-daemon /odom`.

### Nav2 looks healthy but the simulated car doesn't move

**Cause:** Nav2 publishes `TwistStamped`; the Gazebo `/cmd_vel` bridge expects `Twist`, and a bridge fed the wrong type never fires. **Fix:** Nav2 publishes on `/cmd_vel_nav`, which has its own bridge node; the shipped launch files already do this. The mirror image exists on the vehicle: a `TwistStamped` body parsed as `Twist` decodes to denormals near zero, and the bridge warns about surplus bytes. That warning is the tell.

### A `verify-*` task fails on a slower machine with nothing obviously wrong

**Cause:** the verifiers wait for the stack with fixed `sleep`s. **Fix:** rerun with `KEEP_UP=1`, confirm the topics flow, then judge the failure.

### Topics appear on one machine and not another

**Cause:** two Zenoh routers on one LAN. The `standalone` profile of `compose/local/base.yml` stands in for the vehicle's router; with a vehicle present, leave it off. Likewise start one Nav2 profile, never both.

### Stereo depth is empty, or coverage is a few percent

**Cause:** the world has no texture (`empty.sdf` gives SGBM nothing to correlate), or the bridge uses the real Mini's calibration against Gazebo's ideal pinhole. **Fix:** use `workshop.sdf` for anything involving depth, and let `OVCS_SIM=1` select the simulator calibration in `vehicles/ovcs_mini/priv/calibration/sim/`.

### Nav2 drops every point cloud: "the timestamp on the message is earlier than all the data in the transform cache"

**Cause:** one transform stamped with wall-clock time reached `tf2` before the bridge learned the simulator clock. `tf2` prunes relative to its newest entry, and a stamp decades in the future never ages out. **Fix:** `RosBridge.Clock` blocks in `init/1` until the first `/clock` sample, so `:simulator_clock` must come before every component that publishes stamped messages. If you reordered them, put it back. With no `/clock` within 60 s the bridge stays on wall clock for the whole run, by design; restart it once the simulator is up. Background in [ROS 2 and the simulator](./ros2_integration.md).

### The image topic looks dead: one frame every fifteen seconds

**Cause:** raw 480×270 frames at 30 Hz are 11.6 MB/s, and Zenoh drops what the link won't carry. **Fix:** consume the `image_raw/compressed` topics, as the shipped launch files do.

## Still stuck?

[Open an issue](https://github.com/open-vehicle-control-system/ovcs/issues) with the output of `./ovcs doctor` and the exact command that failed, or ask on the [community channels](./community.md).
