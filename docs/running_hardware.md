# Running OVCS on Real Hardware

## Supported Hardware

| Component | Hardware Platform | Status |
|-----------|-------------------|--------|
| VMS | Raspberry Pi 4 (8GB) | Supported |
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

OVCS provides the `ovcs` CLI tool at the repository root for building, burning, and uploading firmware.

### CLI Usage

```
Usage: ./ovcs --command [COMMAND] --vehicle [VEHICLE] --application [APP] (--host [HOST] --file [FILE])

Options:
    -c, --command [COMMAND]     Command: build | burn | upload
    -v, --vehicle [VEHICLE]     Vehicle: ovcs1 | ovcs-mini
    -a, --application [APP]     App: vms | infotainment | radio-control-bridge | ros-bridge
    -h, --host [HOST]           Optional: target host (e.g., nerves.local)
    -f, --file [FILE]           Optional: custom firmware file (e.g., custom.fw)
```

### Build

Build a firmware image for a specific application and vehicle:

```sh
# Build VMS firmware for OVCS1
./ovcs -c build -a vms -v ovcs1

# Build Infotainment firmware for OVCS1
./ovcs -c build -a infotainment -v ovcs1

# Build VMS firmware for OVCS Mini
./ovcs -c build -a vms -v ovcs-mini

# Build Radio Control Bridge
./ovcs -c build -a radio-control-bridge -v ovcs1
```

### Burn to SD card

Write the firmware image to an SD card (requires the SD card to be inserted):

```sh
./ovcs -c burn -a vms -v ovcs1
./ovcs -c burn -a infotainment -v ovcs1
```

### Upload over the network

Push a firmware update to a running Nerves device over SSH:

```sh
# Upload to the default host
./ovcs -c upload -a vms -v ovcs1

# Upload to a specific host
./ovcs -c upload -a infotainment -v ovcs1 -h 192.168.1.100

# Upload a custom firmware file
./ovcs -c upload -a vms -v ovcs1 -f path/to/custom.fw
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
  ./ovcs -c build -a vms -v ovcs1
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
./scripts/setup_virtual_can.sh
```

This creates `vcan0` through `vcan5`.

Next: [Testing Generic Controllers](./testing_generic_controllers.md)
