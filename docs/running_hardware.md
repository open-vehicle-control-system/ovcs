# Running OVCS on Real Hardware

## Supported Hardware

| Component | Hardware Platform | Status |
|-----------|-------------------|--------|
| VMS | Raspberry Pi 4 | Supported |
| Infotainment | Raspberry Pi 5 | Supported |
| Radio Control Bridge | Raspberry Pi 3A | Supported |
| ROS Bridge | Raspberry Pi 4 / 5 | Supported |
| Generic Controller | Arduino R4 Minima | Supported |

## Firmware Overview

### Nerves-based components (VMS, Infotainment, Bridges)

OVCS uses the [Nerves Project](https://nerves-project.org/) to build firmware for the Raspberry Pi targets. Nerves produces a complete Linux system image that boots directly into the Elixir application. In theory, any hardware platform supported by Nerves can run OVCS firmware, though you may need to provide a custom system image with CAN bus support.

OVCS uses custom Nerves systems for each target that include the necessary CAN bus kernel modules and device tree overlays:

| Target | Custom System | Repository |
|--------|--------------|------------|
| RPi 4 (VMS) | `ovcs_base_can_system_rpi4` | [GitHub](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi4) |
| RPi 5 (Infotainment) | `ovcs_base_can_system_rpi5` | [GitHub](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi5) |
| RPi 3A (Radio Control) | `ovcs_base_can_system_rpi3a` | [GitHub](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi3a) |

### Arduino controllers

The generic controller firmware is built with [PlatformIO](https://platformio.org/) and targets the Arduino R4 Minima. Upload it using the Arduino IDE or PlatformIO CLI.

The controllers do not use the Arduino R4 Minima's internal CAN bus interface, to remain hardware-agnostic. Any Arduino-compatible board with EEPROM read/write capabilities and an external CAN transceiver should work.

## Configuring Firmware Targets

By default, firmware targets are set to the OVCS custom Nerves systems. If you need to run on different hardware, update the `@all_targets` list and system dependency in the relevant `mix.exs` file.

Example from `infotainment/firmware/mix.exs`:

```elixir
@all_targets [
  :ovcs_base_can_system_rpi5
]
```

To use a different system, replace `:ovcs_base_can_system_rpi5` with your custom system atom and update the dependency accordingly. See the [Nerves documentation on custom systems](https://hexdocs.pm/nerves/customizing-systems.html) for details.

## Building and Deploying Firmware

OVCS provides the `ovcs` CLI tool at the repository root (a Rust release binary built from `cli/`, committed as `cli/ovcs` and symlinked to `./ovcs`) for building, burning, and uploading firmware. See [`cli/README.md`](../cli/README.md) for the full command reference and implementation notes.

### CLI Usage

```
./ovcs <command> <vehicle> <app> [options]
```

- `<vehicle>` is the snake_case directory name under `vehicles/` (e.g. `ovcs1`, `ovcs_mini`, `obd2`).
- `<app>` is `vms`, `infotainment`, or any bridge firmware id declared in the vehicle's `bridge_firmwares/0` callback (e.g. `radio_control`, `ros`).
- Positional args for `build` / `burn` / `clean` / `upload` are order-independent. Missing values prompt interactively; on a non-tty stdin the command exits with status 2.
- Run `./ovcs --help` or `./ovcs <command> --help` for the full option list.

### Build

Build a firmware image for a specific application and vehicle:

```sh
# Build VMS firmware for OVCS1
./ovcs build ovcs1 vms

# Build Infotainment firmware for OVCS1
./ovcs build ovcs1 infotainment

# Build VMS firmware for OVCS Mini
./ovcs build ovcs_mini vms

# Build a bridge firmware declared in the vehicle (e.g. radio_control)
./ovcs build ovcs1 radio_control
```

### Burn to SD card

Write the firmware image to an SD card (requires the SD card to be inserted):

```sh
./ovcs burn ovcs1 vms
./ovcs burn ovcs1 infotainment
```

### Upload over the network

Push a firmware update to a running Nerves device over SSH:

```sh
# Upload to the default host
./ovcs upload ovcs1 vms

# Upload to a specific host
./ovcs upload ovcs1 infotainment --host 192.168.1.100

# Upload a custom firmware file
./ovcs upload ovcs1 vms --file path/to/custom.fw
```

## Running and attaching at runtime

### Local run mirrors deployed: one BEAM per firmware

`./ovcs run <vehicle>` boots the full deployed topology on one host:

- One BEAM per role: `<vehicle>-vms`, `<vehicle>-infotainment`, and `<vehicle>-bridge-<id>` per bridge firmware. Each BEAM runs the corresponding firmware project (`vms/firmware`, `infotainment/firmware`, `bridges/firmware`) directly against `MIX_TARGET=host`.
- A mosquitto broker on `localhost:1884`, started by the VMS BEAM via `OvcsBus.Mqtt.Broker` — same mechanism as deployed. Every other BEAM connects to it via `OvcsBus.Mqtt.Relay`.
- CAN interfaces are shared host-wide (same vcan0/vcan1/… visible to every BEAM), so `./ovcs can setup` once covers all roles.

Output is line-prefixed per role (`[vms] …`, `[infotainment] …`, `[bridge-ros] …`). For the aggregated split-pane TUI, run `./ovcs attach <vehicle>` in another terminal — it auto-detects the local BEAMs via epmd (node snames starting with `<vehicle>-`) and lights up the same multi-node view used for deployed vehicles.

**Prereqs**: `mosquitto` must be on `PATH` inside the distrobox (it already is in the provisioned `ovcs` distrobox). No other setup needed.

### `./ovcs run` vs `./ovcs attach`

The CLI separates **booting** a vehicle from **observing / driving** it:

- `./ovcs run <vehicle>` — provisions vcan and spawns one BEAM per firmware. Streams raw stdout (line-prefixed per role) to the tty. No TUI, no IEx. Ctrl-C stops all of them.
- `./ovcs attach <vehicle>` — split-pane TUI that connects to a running vehicle, aggregates logs per node, and exposes an IEx shell on each. Auto-detects:
  - **Deployed** (preferred, if reachable): SSHes to each expected Nerves device via `<vehicle>-vms.local` / `<vehicle>-infotainment.local` / `<vehicle>-bridge-<id>.local`, streams logs via `RingLogger.attach()`, and opens an interactive IEx channel per device.
  - **Local dev BEAMs** (fallback): if no device hostnames resolve, it finds every epmd registration matching `<vehicle>-*` and opens one `iex --remsh` per BEAM, the same TUI layout as deployed.
  - Otherwise: exits with a clear error.

### Typical flow

```sh
# Terminal A (dev host)
./ovcs run ovcs1

# Terminal B (same laptop, or a laptop on the vehicle's LAN when deployed)
./ovcs attach ovcs1
```

### TUI hotkeys

- `Tab` — switch focus between the logs pane (left) and the IEx pane (right).
- `Ctrl-N` / `Ctrl-P` — cycle which device the IEx pane drives (deployed mode, multiple devices).
- `F1` … `F9` — jump directly to the Nth device.
- Logs pane: `↑`/`↓`, `PgUp`/`PgDn`, `g`/`G`, `Home`/`End` — scroll / follow tail.
- IEx pane: `Enter` evaluates, `↑`/`↓` walks command history, `Esc` returns focus to logs.
- `Ctrl-C` or `q` — quit attach (the source BEAM / remote devices keep running).

### Prerequisites for deployed attach

- The host's SSH key must be in every firmware's `AUTHORIZED_SSH_KEYS` env at boot (same key that makes `./ovcs upload` work). `attach` authenticates via `ssh-agent` — make sure your agent is running and holds the key (`ssh-add -l` to check).
- Devices must be reachable on the LAN via mDNS (`<vehicle>-<side>.local`). Verify with `ping ovcs1-vms.local` before attaching.
- Non-Nerves bridges (e.g. Arduino generic controllers) have no SSH / IEx — they are skipped automatically.

## Customizing CAN Interfaces

The `CAN_NETWORK_MAPPINGS` environment variable maps logical CAN network names to physical or virtual interfaces. This is used both for local development and when building firmware.

### Format

```
CAN_NETWORK_MAPPINGS=network1:interface1,network2:interface2,...
```

### Interface types

| Prefix | Type | Example | Description |
|--------|------|---------|-------------|
| `can` | Physical CAN | `can0` | Hardware CAN interface |
| `vcan` | Virtual CAN | `vcan0` | Software-only CAN interface (for development) |
| `spi` | SPI-to-CAN | `spi0.0` | CAN via SPI (used on the VMS with the CAN hub board) |

### Examples

**Running the VMS locally** with physical CAN on the OVCS bus and virtual CAN for the rest:

```sh
cd vms/api
CAN_NETWORK_MAPPINGS=ovcs:can0,leaf_drive:vcan1,polo_drive:vcan2,orion_bms:vcan3,misc:vcan4 \
  iex -S mix phx.server
```

**Building VMS firmware** with SPI for the OVCS bus and virtual CAN for testing:

```sh
CAN_NETWORK_MAPPINGS=ovcs:spi0.0,leaf_drive:vcan0,polo_drive:vcan1,orion_bms:vcan2,misc:vcan3 \
  ./ovcs build ovcs1 vms
```

### Available CAN networks

| Network | Used by | Description |
|---------|---------|-------------|
| `ovcs` | OVCS1, OVCS Mini | Internal OVCS communication bus |
| `leaf_drive` | OVCS1 | Nissan Leaf drivetrain |
| `polo_drive` | OVCS1 | VW Polo original systems |
| `orion_bms` | OVCS1 | Orion BMS2 + charger |
| `misc` | OVCS1 | iBooster, steering angle sensor |

## Setting Up Physical CAN Interfaces

For hardware with physical CAN transceivers:

```sh
./scripts/setup_can.sh
```

This configures `can0` and `can1` at 500 kbps. Edit the script to adjust bitrates or add more interfaces as needed.

For virtual CAN interfaces (local development):

```sh
./ovcs can setup <vehicle>
```

The CLI reads the vehicle's `default_can_mapping(:host)` and creates only the vcan interfaces that vehicle actually needs.

Next: [Testing Generic Controllers](./testing_generic_controllers.md)
