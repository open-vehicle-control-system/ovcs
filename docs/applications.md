# OVCS Applications

## Overview

OVCS is composed of several independent applications organized in a monorepo. Each application is a standalone Elixir Mix project (or a C++/JavaScript/Dart project) with its own dependencies, configuration, and build pipeline. They reference each other via relative `path:` dependencies -- this is **not** an Elixir umbrella project.

All Elixir applications can be run on a host machine without the target hardware present, using virtual CAN interfaces for local development and testing.

## Application Architecture

Each major system (VMS, Infotainment) follows a three-layer architecture:

```
+------------+     +------------+     +----------------+
|  Firmware  | --> |    API     | --> |     Core       |
| (Nerves)   |     | (Phoenix)  |     | (Business      |
|            |     |            |     |  Logic)        |
+------------+     +------+-----+     +--------+-------+
                          |                    |
                    +-----+------+      +------+-------+
                    |  Dashboard |      |  Cantastic   |
                    | (Vue/Dart) |      | (CAN lib)    |
                    +------------+      +--------------+
```

- **Core** -- Pure Elixir library containing business logic, component drivers, and the `VmsCore.Vehicle` / `InfotainmentCore.Vehicle` behaviours. No vehicle-specific code lives here; each vehicle is its own package under `vehicles/`. No web dependencies.
- **API** -- Phoenix application providing a JSON REST API and WebSocket channels for the dashboard. Depends on Core.
- **Dashboard** -- Frontend application (Vue.js for VMS, Flutter for Infotainment) that connects to the API via HTTP and WebSocket.
- **Firmware** -- Nerves firmware project that packages the API (and transitively, Core) into a deployable image for the target Raspberry Pi.

## Vehicle Management System (VMS)

The VMS is the central brain of the vehicle. It translates and orchestrates all vehicle components, making parts from different manufacturers work together seamlessly. For example, the RPM displayed on the original VW Polo instrument cluster comes from the Nissan Leaf motor.

### VMS Core (`vms/core/`)

| | |
|---|---|
| **Module** | `VmsCore` |
| **App name** | `:vms_core` |
| **Key deps** | `cantastic`, `ecto_sqlite3`, `phoenix_pubsub`, `crc` |

The core library contains:

- **Component drivers** (`lib/vms_core/components/`) -- GenServer processes that manage communication with specific hardware components over CAN bus:
  - `Bosch.IBoosterGen2` -- Brake booster control
  - `Nissan.LeafAze0.Inverter` -- Electric motor inverter
  - `Nissan.LeafAze0.Charger` -- On-board charger
  - `Orion.Bms2` -- Battery management system
  - `Volkswagen.Polo9n.*` -- ABS, dashboard, ignition lock, power steering pump, etc.
  - `Ovcs.GenericController` -- Custom Arduino controller driver
  - `Ovcs.ThrottlePedal`, `Ovcs.SteeringColumn`, `Ovcs.HighVoltageContactors`, etc.
  - `Ovcs.RadioControl.*` -- RC transmitter control (throttle, steering, direction)
  - `Ovcs.RosControl.*` -- ROS2 autonomous control
  - `Traxxas.*` -- RC car motor, steering, and throttle (for OVCS Mini)
- **Vehicle behaviour** (`lib/vms_core/vehicle.ex`) -- Contract each vehicle's VMS composer must implement (`children/0`, `dashboard_configuration/0`, `generic_controllers/0`, `can_config_otp_app/0`, `can_config_path/0`). The configured composer is resolved via `Application.get_env(:vms_core, :vehicle)` and comes from a vehicle package (e.g. `Ovcs1.Vms.Composer`).
- **Managers** (`lib/vms_core/managers/`) -- Higher-level logic for gear management and control level switching.
- **Bus** (`lib/vms_core/bus.ex`) -- PubSub-based event bus for inter-process communication.
- **Metrics** (`lib/vms_core/metrics.ex`) -- Collects and broadcasts vehicle metrics for the dashboard.
- **PID controller** (`lib/vms_core/pid.ex`) -- Generic PID controller implementation used for motor control loops.
- **CAN configurations** -- Live inside each vehicle package (`vehicles/<name>/priv/can/{vms,infotainment}.yml`). Shared frame and signal specs live in the [`ovcs_can`](#ovcs-can-librariesovcs_can) library and are referenced via Cantastic's `import!:@ovcs_can:...` syntax.

### VMS API (`vms/api/`)

| | |
|---|---|
| **Module** | `VmsApi` |
| **App name** | `:vms_api` |
| **Key deps** | `phoenix`, `vms_core`, `bandit`, `cors_plug` |

A Phoenix 1.7 JSON API server that exposes vehicle data and control actions:

- **REST endpoints** -- Vehicle status, page/block layout for the dashboard, and action dispatch.
- **WebSocket channels** -- Real-time metrics streaming (`MetricsChannel`) and network interface monitoring (`NetworkInterfacesChannel`) via Phoenix Channels.
- **LiveDashboard** -- Available in development mode at `/dev/dashboard` for Erlang VM introspection.

API routes:

```
GET  /api/vehicle           -- Vehicle status and info
GET  /api/vehicle/pages     -- Dashboard page layout
GET  /api/vehicle/pages/:id/blocks -- Blocks for a specific page
POST /api/actions           -- Dispatch control actions
```

### VMS Dashboard (`vms/dashboard/`)

| | |
|---|---|
| **Technology** | Vue.js 3, Vite, ECharts, TailwindCSS, Pinia |
| **Package** | `dashboard` (private npm package) |

A real-time single-page application for monitoring and debugging the vehicle during development:

- Dynamic pages and blocks driven by the API layout system
- Real-time line charts for metrics (throttle, torque, RPM, etc.)
- Real-time data tables for component status
- Network interface monitoring
- Connects to the VMS API via Phoenix WebSocket channels

### VMS Firmware (`vms/firmware/`)

| | |
|---|---|
| **Module** | `VmsFirmware` |
| **App name** | `:vms_firmware` |
| **Target** | Raspberry Pi 4 (`ovcs_base_can_system_rpi4`) |

Nerves firmware image that packages the VMS API (and Core) for deployment to a Raspberry Pi 4. Uses a [custom Nerves system](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi4) with CAN bus support via SPI.

## Infotainment System

The infotainment system provides the in-car user interface on a 10-inch touchscreen. It allows the driver to select gears, view vehicle status, monitor battery health, and adjust settings.

### Infotainment Core (`infotainment/core/`)

| | |
|---|---|
| **Module** | `InfotainmentCore` |
| **App name** | `:infotainment_core` |
| **Key deps** | `cantastic`, `ecto_sqlite3`, `json` |

Similar in structure to VMS Core but focused on the infotainment UI:

- **Vehicle composers** -- Define pages and blocks for the touchscreen UI (gear selector, speed gauge, battery overview, status grid, etc.)
- **Layout validator** -- Validates the page/block layout configuration.
- **Temperature** -- Handles temperature sensor data.
- **Time settings** -- Manages system time preferences (persisted via SQLite).

### Infotainment API (`infotainment/api/`)

| | |
|---|---|
| **Module** | `InfotainmentApi` |
| **App name** | `:infotainment_api` |
| **Key deps** | `phoenix`, `infotainment_core`, `plug_cowboy` |

A Phoenix 1.7 JSON API server with the same page/block layout pattern as the VMS API, but serving the Flutter dashboard. Includes WebSocket channels for real-time metrics updates.

### Infotainment Dashboard (`infotainment/dashboard/`)

| | |
|---|---|
| **Technology** | Flutter / Dart (SDK 3.32.8) |
| **Package** | `dashboard_flutter` |

A native Linux application built with Flutter, designed to run on the Raspberry Pi 5's touchscreen. Features:

- Gear selector interface
- Speed gauge
- Battery overview
- Component status grid
- Settings management
- Connects to the Infotainment API via the `phoenix_socket` Dart package

### Infotainment Firmware (`infotainment/firmware/`)

| | |
|---|---|
| **Module** | `InfotainmentFirmware` |
| **App name** | `:infotainment_firmware` |
| **Target** | Raspberry Pi 5 (`ovcs_base_can_system_rpi5`) |

Nerves firmware image that packages the Infotainment API and the Flutter dashboard for deployment. Uses [`nerves_flutter_support`](https://hex.pm/packages/nerves_flutter_support) to compile and include the Flutter app in the firmware image, and a [custom Nerves system](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi5) with CAN bus and display support.

## Bridges

Bridges are dedicated Nerves devices that provide specific communication capabilities to the OVCS network.

### Radio Control Bridge (`bridges/radio_control_bridge/firmware/`)

| | |
|---|---|
| **Module** | `RadioControlBridgeFirmware` |
| **App name** | `:radio_control_bridge_firmware` |
| **Target** | Raspberry Pi 3A (`ovcs_base_can_system_rpi3a`) |
| **Key deps** | `cantastic`, `express_lrs`, `msp_osd` |

Enables remote control of the vehicle using a MAVLink-compatible RC transmitter (such as ExpressLRS hardware). It:

- Receives MAVLink RC channel data via `MavlinkForwarder`
- Forwards MSP OSD telemetry data back to the transmitter via `MspOsdForwarder`
- Translates RC inputs into CAN messages on the OVCS CAN bus

### ROS Bridge (`bridges/ros_bridge/firmware/`)

| | |
|---|---|
| **Module** | `ROSBridgeFirmware` |
| **App name** | `:ros_bridge_firmware` |
| **Target** | Raspberry Pi 4/5 (`ovcs_base_can_system_rpi4`, `ovcs_bridges_system_rpi5`) |
| **Key deps** | `cantastic`, `emqtt`, `circuits_i2c` |

Provides integration with ROS2 for autonomous driving research. It:

- Publishes IMU data from a BNO085 sensor via I2C (`ImuPublisher`)
- Interprets joystick messages from ROS2 (`JoyInterpreter`)
- Communicates with the ROS2 ecosystem via Zenoh/MQTT bridge (`ZenohMQTTRos2.Dispatcher`)

## Controllers

### Generic Controller (`controllers/generic_controller/`)

| | |
|---|---|
| **Technology** | C++ / PlatformIO |
| **Target** | Arduino R4 Minima |

A single, configurable firmware for Arduino-based controllers that interface with specific vehicle components via CAN bus. Features:

- **Adoption process** -- Controllers receive their pin configuration from the VMS over the OVCS CAN bus (no hardcoded pin assignments)
- **Supported pin types** -- Digital output, analog input, DAC output, PWM output, external PWM (via expansion boards)
- **Expansion boards** -- Support for additional I/O via SPI-connected expansion boards
- **CRC validation** -- All CAN messages are CRC-protected for reliability

Build configurations (defined in `platformio.ini`):
- `uno_r4_minima_prod` -- Production build
- `uno_r4_minima_debug` -- Debug build with serial output
- `local_test` -- Unit tests (Unity test framework)

## Vehicles (`vehicles/`)

Each vehicle is a standalone Mix application that bundles both its VMS and infotainment sides. A vehicle's top-level module implements the `OvcsVehicle` behaviour and exposes `vms/0`, `infotainment/0`, `can_config_otp_app/0`, and `nerves_target/1`:

| Package | App | Top-level module |
|---------|-----|------------------|
| `vehicles/ovcs1/` | `:ovcs1` | `Ovcs1` |
| `vehicles/ovcs_mini/` | `:ovcs_mini` | `OvcsMini` (no infotainment side) |
| `vehicles/obd2/` | `:obd2` | `Obd2` |

The side-specific composers (`Ovcs1.Vms.Composer`, `Ovcs1.Infotainment.Composer`, etc.) implement `VmsCore.Vehicle` / `InfotainmentCore.Vehicle`. Consumers reference only the top-level module in their config and dispatch through it — this prevents the two sides from drifting.

## Shared Libraries

### OvcsVehicle (`libraries/ovcs_vehicle/`)

| | |
|---|---|
| **Module** | `OvcsVehicle` |
| **App name** | `:ovcs_vehicle` |

Defines the top-level behaviour every vehicle package implements.

### OvcsCan (`libraries/ovcs_can/`)

| | |
|---|---|
| **Module** | `OvcsCan` |
| **App name** | `:ovcs_can` |

A data-only library holding the shared CAN component frame and signal YAML definitions consumed by vehicle packages. Contains no runtime logic -- only YAML under `priv/can/components/`. Vehicle topology entry points (`vms.yml`, `infotainment.yml`) and per-vehicle controller wirings live inside each vehicle package's `priv/can/` and import shared components from here via `import!:@ovcs_can:can/components/...`.

### Cantastic (`libraries/cantastic/`)

| | |
|---|---|
| **Module** | `Cantastic` |
| **App name** | `:cantastic` |
| **Key deps** | `yaml_elixir`, `jason`, `decimal` |

The foundational CAN bus communication library used by all Elixir applications. See the [Cantastic README](../libraries/cantastic/README.md) for details.

Key capabilities:
- YAML-driven CAN frame and signal specification
- Raw CAN socket communication via Linux SocketCAN (`AF_CAN`)
- Frame emission (`Emitter`) and reception (`Receiver`)
- Signal encoding/decoding with support for big-endian, little-endian, signed/unsigned, and scaled values
- ISO-TP multi-frame protocol support (`IsotpRequest`)
- `socketcand` support for remote CAN debugging over the network
- Received frame monitoring and watchdog (`ReceivedFrameWatcher`)

## Dependencies

Since OVCS relies on the CAN bus, you need `libsocketcan` kernel support and `can-utils` installed on your host machine. This allows you to create virtual CAN devices for local development.

### Setting up CAN interfaces

For **virtual** CAN interfaces (local development):

```sh
./ovcs can setup <vehicle>
```

For **physical** CAN interfaces (real hardware), Cantastic brings them up at boot via `setup_can_interfaces: true` in the firmware's Cantastic config. For manual setup while SSH'd onto a device:

```sh
./scripts/setup_can.sh
```

### Environment variables

| Variable | Description | Example |
|----------|-------------|---------|
| `CAN_NETWORK_MAPPINGS` | Maps CAN network names to interfaces | `ovcs:can0,leaf_drive:vcan1,polo_drive:vcan2` |
| `VEHICLE` | Top-level vehicle module name (case-sensitive) | `Ovcs1`, `OvcsMini`, `Obd2` |
| `SETUP_CAN_INTERFACE` | Skip automatic CAN interface setup | `true` |

## Local Development

### Running the VMS

```sh
# Terminal 1: Setup the vehicle's virtual CAN interfaces
./ovcs can setup ovcs1

# Terminal 2: Start the VMS API
cd vms/api
mix deps.get
mix phx.server

# Terminal 3: Start the VMS debug dashboard
cd vms/dashboard
npm install
npm run dev
```

### Running the Infotainment

```sh
# Terminal 1: Start the Infotainment API
cd infotainment/api
mix deps.get
mix phx.server

# Terminal 2: Start the Flutter dashboard (requires Flutter SDK)
cd infotainment/dashboard
flutter run -d linux
```

### Running with custom CAN mappings

```sh
cd vms/api
CAN_NETWORK_MAPPINGS=ovcs:can0,leaf_drive:vcan1,polo_drive:vcan2,orion_bms:vcan3,misc:vcan4 iex -S mix phx.server
```

Next: [Testing CAN Messages](./testing_can_messages.md)
