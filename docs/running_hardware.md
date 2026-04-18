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

OVCS provides the `ovcs` CLI tool at the repository root (a Node.js bundle under `cli/ovcs.js`, symlinked to `./ovcs`) for building, burning, and uploading firmware. See [`cli/README.md`](../cli/README.md) for the full command reference and implementation notes.

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
