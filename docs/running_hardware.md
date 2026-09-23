---
title: Running on hardware
description: Build, burn and OTA-upload your application's Nerves firmware, keep SSH host keys stable across burns, and attach to the running boards.
---

Everything that runs on your laptop with `./ovcs run` also runs on the vehicle: the same firmware projects, the same application package, the same Erlang cluster. The difference is that each BEAM becomes a Nerves image on its own Raspberry Pi. This guide covers building those images, getting them onto boards, updating them, and watching them run.

The firmware projects, the Nerves systems and the `ovcs` CLI are the framework. Everything that varies per vehicle (the Nerves target of each role, `.env.exs` with its keys and secrets, the SSH host keys, the CAN mapping) belongs to your application under `vehicles/<app>/`. The commands below use the `ovcs1` and `ovcs_mini` reference applications; substitute your own package name and they work unchanged.

## Boards per role

| Role | Board | Nerves system |
|---|---|---|
| VMS | Raspberry Pi 4 | [`ovcs_base_can_system_rpi4`](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi4) |
| Infotainment | Raspberry Pi 5 | [`ovcs_base_can_system_rpi5`](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi5) |
| Radio control bridge | Raspberry Pi 3A | [`ovcs_base_can_system_rpi3a`](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi3a) |
| ROS bridge | Raspberry Pi 4 | [`ovcs_base_can_system_rpi4`](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi4) |
| Perception bridge | Raspberry Pi 5 + Hailo-8 | [`ovcs_bridges_system_rpi5`](https://github.com/open-vehicle-control-system/ovcs_bridges_system_rpi5) |
| Generic controller | Arduino R4 Minima | none (PlatformIO) |

These are the reference applications' choices. The target of each role is an application decision, read from your top-level module: `vms_target/0`, `infotainment_target/0`, and the `:target` key of each `bridge_firmwares/0` entry. To deploy on other hardware, change those values in `vehicles/<app>/lib/<app>.ex` and add the matching system dependency to the firmware project's `mix.exs` (see the [Nerves custom-systems guide](https://hexdocs.pm/nerves/customizing-systems.html)).

The OVCS systems add the CAN kernel modules and device-tree overlays the SPI-CAN hardware needs. The host OTP pinned in `mise.toml` must match the OTP they ship: [Toolchain and OTP](./toolchain_and_otp.md) explains why.

The generic controller firmware is a [PlatformIO](https://platformio.org/) project. It doesn't use the R4's built-in CAN peripheral, so any Arduino-compatible board with EEPROM and an external CAN transceiver works. Flashing and adoption are in [Generic controllers](./testing_generic_controllers.md).

## The `ovcs` CLI

Every build, burn and upload goes through `./ovcs` (built by `mise run cli`, see [Getting started](./getting_started.md#5-build-the-cli-and-check-everything)). The [CLI reference](../cli/README.md) lists every command.

```text
./ovcs <command> <app> <role> [options]
```

- `<app>` is the snake_case directory name of an application under `vehicles/`.
- `<role>` is `vms`, `infotainment`, or `bridge-<id>` for any id in the application's `bridge_firmwares/0` (`bridge-radio_control`, `bridge-ros`, `bridge-ros_perception` in the reference applications). The `bridge-` prefix is required: a bare id is rejected, and the error lists the valid roles.
- The two positional arguments are order-independent. A missing one opens an interactive picker; on a non-tty stdin the command exits with status 2.

## Build

1. **Configure the application's secrets.** Copy `vehicles/<app>/.env.exs.example` to `vehicles/<app>/.env.exs` and fill in `AUTHORIZED_SSH_KEYS` (your SSH public keys), `WIFI_NETWORKS`, and the Phoenix `SECRET_KEY_BASE` and `SIGNING_SALT`. The file is gitignored and shared by every firmware of the application.
2. **Generate stable SSH host keys**, once per application ([below](#stable-ssh-host-keys-across-burns)):

   ```sh
   ./ovcs host-keys generate ovcs1
   ```

3. **Build the image:**

   ```sh
   ./ovcs build ovcs1 vms                    # VMS
   ./ovcs build ovcs1 infotainment           # infotainment
   ./ovcs build ovcs1 bridge-radio_control   # a bridge the application declares
   ./ovcs build --all ovcs1                  # every role, firmware projects in parallel
   ./ovcs build my_car vms                   # the same for your own application
   ```

A VMS build also builds the Vue dashboard and bundles it into the image. The image lands under the firmware project's `_build/<target>_dev/nerves/images/`, for example `vms/firmware/_build/ovcs_base_can_system_rpi4_dev/nerves/images/vms_firmware.fw`.

### Stable SSH host keys across burns

A fresh SD-card burn regenerates the device's SSH host key, so every reflash trips OpenSSH's "REMOTE HOST IDENTIFICATION HAS CHANGED" warning. Persistent keys per role avoid that:

```sh
./ovcs host-keys generate ovcs1
```

This creates an RSA and an ed25519 key pair per role under `vehicles/<app>/priv/host_keys/`: `vms/`, `infotainment/`, and `bridges/<id>/` for each bridge. The files are gitignored. The firmware ships them in the application's `priv` and points `:nerves_ssh, :system_dir` at them at boot. Re-run with `--force` to rotate; `./ovcs doctor` warns about any application missing keys.

To share one identity across a team:

```sh
./ovcs host-keys verify ovcs1                             # exit 1 if any role lacks a full key set
./ovcs host-keys export ovcs1 -o ovcs1-host-keys.tar.gz   # default: ./ovcs1-host-keys.tar.gz
./ovcs host-keys import ovcs1 --from ovcs1-host-keys.tar.gz
```

> [!WARNING]
> The exported archive holds **private** keys: pass it over a trusted channel. `import` refuses to overwrite existing keys unless you add `--force`.

## Burn to an SD card

With the card inserted:

```sh
./ovcs burn ovcs1 vms
./ovcs burn --build ovcs1 vms      # rebuild, then burn
```

## Upload over the network

Push an update to a running device over SSH:

```sh
./ovcs upload ovcs1 vms                                 # to ovcs1-vms.local
./ovcs upload ovcs1 infotainment --host 192.168.1.100   # to a specific address
./ovcs upload ovcs1 vms --file path/to/custom.fw        # a custom image
./ovcs upload --build ovcs1 vms                         # rebuild, then upload
```

The default host is `<app>-<role>.local`, with every underscore turned into a dash: `ovcs-mini-vms.local`, `ovcs1-bridge-radio-control.local`.

## OTA updates via NervesHub

The VMS firmware ships [NervesHubLink](https://hexdocs.pm/nerves_hub_link/), so deployed vehicles can pull signed updates from a self-hosted [NervesHub](https://github.com/nerves-hub/nerves_hub_web) instance instead of being flashed over SSH. It is opt-in per application: set three variables in `vehicles/<app>/.env.exs` before building (`.env.exs.example` has them commented out).

- `NERVES_HUB_HOST`: the instance's device endpoint, a bare hostname (`wss` on port 443) or a full `wss://host:port` URL.
- `NERVES_HUB_PRODUCT_KEY` and `NERVES_HUB_PRODUCT_SECRET`: the shared-secret pair from the product's settings on the instance.

Without `NERVES_HUB_HOST`, the firmware never contacts NervesHub.

**One NervesHub product per application.** The build stamps a product name into the image's `meta-product`, derived from the `VEHICLE` module name: `Ovcs1 - VMS`, `Ovcs Mini - VMS`. NervesHub only accepts firmware whose metadata matches the product it's uploaded to, so create one product per application with that name and put its shared-secret pair in that application's `.env.exs`. A device then only ever sees its own application's firmware.

Publish with the [`nh` CLI](https://github.com/nerves-hub/nerves_hub_cli):

```sh
./ovcs build ovcs1 vms
nh firmware publish \
  vms/firmware/_build/ovcs_base_can_system_rpi4_dev/nerves/images/vms_firmware.fw \
  --product "Ovcs1 - VMS" --key <signing-key> --deploy <deployment>
```

Firmware must be signed: `nh key create <name>` creates a signing key pair and registers the public half on the instance, and `nh firmware publish --key <name>` signs locally, so the private key never leaves your machine. Devices authenticate with the product's shared secret, self-register on first connect (identified by serial number), and fetch the verification keys from the instance, so nothing is baked into the image.

The link also enables health reporting (CPU, memory, disk) and a remote IEx console in the NervesHub UI, open to anyone with access to the product. `nerves_hub_link` starts before the main application, so a vehicle whose application crashes at boot stays reachable for an OTA fix.

## Watching a running vehicle

`./ovcs attach <app>` is the same split-pane TUI whether the application runs on your laptop (`./ovcs run`) or on its boards. It tries the deployed boards first, by probing `<app>-<role>.local` on port 22 for each role, and falls back to local BEAMs registered in `epmd`. Deployed, it streams each board's logs via `RingLogger.attach()` and opens an IEx channel per board. The panes and hotkeys are in the [CLI reference](../cli/README.md#the-attach-tui).

```sh
./ovcs attach ovcs1
```

For a single board, `connect` opens a plain IEx shell. Nerves boards use IEx as their SSH login shell:

```sh
./ovcs connect ovcs1 vms                         # IEx on the VMS Pi
./ovcs connect ovcs1 vms --host 192.168.10.42    # bypass mDNS with a known address
```

Both need:

- your SSH public key in `AUTHORIZED_SSH_KEYS` in `vehicles/<app>/.env.exs` when the firmware was built;
- your private key loaded in `ssh-agent` (`ssh-add -l` to check);
- the boards resolving on the LAN by mDNS. Check with `ping ovcs1-vms.local` first.

On a vehicle with a compute node, the boards' wired addresses sit behind it. An SSH `ProxyJump` block in `~/.ssh/config` makes them reachable from the site Wi-Fi, since `upload` and `connect --host` run `ssh` underneath:

```text
Host 10.42.0.*
    ProxyJump root@COMPUTE_NODE_SITE_ADDRESS:22222
    StrictHostKeyChecking accept-new
```

[Reaching the vehicle network](./ros_compute_node.md#reaching-the-vehicle-network-from-the-site-wi-fi) explains that layout. Arduino controllers have no SSH or IEx and are skipped.

## CAN interfaces

Each side's composer declares which interface carries each CAN network, per environment, in `default_can_mapping/1`: `:host` for `./ovcs run` (virtual `vcan` interfaces), `:target` for the deployed image (`spi` interfaces behind the CAN hub). A bridge declares its own in the `default_can_mapping` of its `bridge_firmwares/0` entry.

| Interface prefix | Type | Example |
|---|---|---|
| `vcan` | Virtual CAN, for development | `vcan0` |
| `can` | Physical CAN interface | `can0` |
| `spi` | CAN via SPI, as on the VMS with the multi-CAN hub | `spi0.0` |

The network names are the application's own. The reference applications declare:

| Network | Declared by | Carries |
|---|---|---|
| `ovcs` | every application | Framework traffic: VMS status, controllers, radio control, ROS commands |
| `leaf_drive` | OVCS1 | Nissan Leaf drivetrain |
| `polo_drive` | OVCS1 | VW Polo original systems |
| `orion_bms` | OVCS1 | Orion BMS2 and charger |
| `misc` | OVCS1, OVCS Mini | OVCS1: iBooster and steering-angle sensor; Mini: the VESC |

### Overriding the mapping

`CAN_NETWORK_MAPPINGS` replaces the composer's mapping when it is set in the environment of a BEAM **at boot**. It takes `network:interface` pairs:

```text
CAN_NETWORK_MAPPINGS=network1:interface1,network2:interface2,...
```

It is read by each firmware's `config/runtime.exs`, so it only works on the host: a deployed image boots without it and uses `default_can_mapping(:target)`. To change a deployed mapping, change the composer.

On the host, every BEAM `./ovcs run` spawns inherits it except the bridges, which always get their own mapping. Cantastic refuses a mapping that names a network its YAML doesn't declare (`CAN Network: '…' is missing from the Yaml configuration`), so the variable suits an application whose sides share their networks. The Mini's VMS, for instance, on a physical `can0` for the `ovcs` bus:

```sh
CAN_NETWORK_MAPPINGS=ovcs:can0,misc:vcan1 ./ovcs run ovcs_mini
```

### Bringing interfaces up

On a Nerves board, Cantastic sets the CAN interfaces up at boot (`setup_can_interfaces: true`); there is no manual step. On the host, `./ovcs can setup <app>` creates the `vcan` interfaces the application's `default_can_mapping(:host)` names. For a Linux machine with physical CAN adapters, `scripts/setup_can.sh` brings `can0`, `can1` and `can2` up at 500 kbps; edit it for other bitrates or interfaces.

## Next steps

- [Generic controllers](./testing_generic_controllers.md): flash and adopt the Arduino boards on the `ovcs` bus.
- [CLI reference](../cli/README.md): every subcommand, and how the attach TUI decodes frames.
- [Toolchain and OTP](./toolchain_and_otp.md): why host and target OTP must agree, and what A/B firmware requires.
- [Troubleshooting](./troubleshooting.md): the failures newcomers hit most.
