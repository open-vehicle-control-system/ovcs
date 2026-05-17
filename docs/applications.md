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
- **Vehicle behaviour** (`lib/vms_core/vehicle.ex`) -- Contract each vehicle's VMS composer must implement: required `children/0`, `can_config_otp_app/0`, `can_config_path/0`, `default_can_mapping/1`; optional `dashboard_configuration/0`, `generic_controllers/0`. The configured composer is resolved via `Application.get_env(:vms_core, :vehicle)` and comes from a vehicle package (e.g. `Ovcs1.Vms.Composer`).
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
| **Key deps** | `cantastic`, `ecto_sqlite3`, `phoenix_pubsub`, `ovcs_bus`, `jason` |

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

A **bridge** is an Elixir library (`bridges/<name>/`) that ferries data between the OVCS CAN bus and some non-CAN world (radio link, ROS2 graph, …). Bridges implement the `OvcsBridge` behaviour and are bundled into the shared `bridges/firmware/` Nerves image. A vehicle declares which bridges to build, and at which Nerves target, via its `bridge_firmwares/0` callback — one Nerves image per entry.

### Bridge Firmware (`bridges/firmware/`)

| | |
|---|---|
| **Module** | `BridgeFirmware` |
| **App name** | `:bridge_firmware` |
| **Targets** | `ovcs_base_can_system_rpi3a`, `ovcs_base_can_system_rpi4`, `ovcs_bridges_system_rpi5` |

Shared Nerves image. Reads `VEHICLE` + `BRIDGE_FIRMWARE_ID` at boot,
looks up the matching entry in the vehicle's `bridge_firmwares/0`, and
supervises each bridge library's `children/0` under `OvcsBridge.Supervisor`.

### Radio Control Bridge (`bridges/radio_control_bridge/`)

| | |
|---|---|
| **Module** | `RadioControlBridge` |
| **Behaviour** | `OvcsBridge` |
| **Key deps** | `cantastic`, `express_lrs`, `msp_osd`, `ovcs_bridge` |

Enables remote control of the vehicle using a MAVLink-compatible RC transmitter (such as ExpressLRS hardware). It:

- Receives MAVLink RC channel data via `MavlinkForwarder`.
- Forwards MSP OSD telemetry data back to the transmitter via `MspOsdForwarder`.
- Translates RC inputs into CAN messages on the OVCS CAN bus.

### ROS Bridge (`bridges/ros_bridge/`)

| | |
|---|---|
| **Module** | `RosBridge` |
| **Behaviour** | `OvcsBridge` |
| **Key deps** | `cantastic`, `zenohex`, `ovcs_bridge`, `ovcs_drivers` |

Provides integration with ROS 2 for autonomous driving research. It:

- Holds a single Zenoh session (`ZenohClient`) and exposes a `publish/4` + `subscribe/4` API to the rest of the bridge. Handles lazy publisher / liveliness-token declaration, reconnect with stable per-publisher GIDs, and subscriber pid monitoring. See [`bridges/ros_bridge/README.md`](../bridges/ros_bridge/README.md) for the wire-format details.
- Publishes a `std_msgs/String` heartbeat onto the ROS 2 graph every 5 s via `RosBridge.Heartbeat`, so consumers can see the BEAM is alive even when no other topic is flowing.
- Subscribes to the ROS 2 `joy` topic via the same `ZenohClient` and forwards `sensor_msgs/Joy` axes onto the CAN bus through `JoyInterpreter` → Cantastic emitters (`ros_control0`/`ros_control1`).
- Publishes `sensor_msgs/Imu` from any `OvcsDrivers.Imu` driver via `RosBridge.ImuPublisher`. The host arm runs the kind-level `OvcsDrivers.Imu.Dummy` stub and the target arm runs `BNO085.I2C` against a physical sensor; swapping in a future ICM-20948 (or any other conforming IMU) is a one-line supervisor change.

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

Each vehicle is a standalone Mix application that bundles its VMS side, optional infotainment side, and optional bridge firmware declarations. A vehicle's top-level module implements the `OvcsVehicle` behaviour and exposes `name/0`, `vms/0`, `can_config_otp_app/0`, `vms_target/0`, plus optional `infotainment/0`, `infotainment_target/0`, and `bridge_firmwares/0`:

| Package | App | Top-level module |
|---------|-----|------------------|
| `vehicles/ovcs1/` | `:ovcs1` | `Ovcs1` |
| `vehicles/ovcs_mini/` | `:ovcs_mini` | `OvcsMini` (no infotainment side) |
| `vehicles/obd2/` | `:obd2` | `Obd2` (no bridges) |

The side-specific composers (`Ovcs1.Vms.Composer`, `Ovcs1.Infotainment.Composer`, etc.) implement `VmsCore.Vehicle` / `InfotainmentCore.Vehicle`. Each firmware's `runtime.exs` writes the composer (not the top-level module) to `:vms_core, :vehicle` / `:infotainment_core, :vehicle`; the top-level module is the discovery entry point from which composers are fetched. See [Vehicle Parameterisation](./vehicle_parameterisation.md) for the full wiring.

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
| `VEHICLE` | Top-level vehicle module name (case-sensitive) | `Ovcs1`, `OvcsMini`, `Obd2` |
| `CAN_NETWORK_MAPPINGS` | Override the vehicle's `default_can_mapping(:host)` | `ovcs:can0,leaf_drive:vcan1,polo_drive:vcan2` |
| `BRIDGE_FIRMWARE_ID` | (bridge firmware only) Picks one entry from the vehicle's `bridge_firmwares/0` | `radio_control` |

## Local Development

The vehicle package (`vehicles/<name>`) is metadata + composers
only — it has no `Application` module. It *does* Mix-dep on
`vms_firmware`, `infotainment_firmware` (when the vehicle has an
infotainment side), and `bridge_firmware` (when it declares bridges),
so that one `mix compile` under the vehicle directory builds every
firmware it needs into its own `_build` tree. The dep direction is
**vehicle → firmware**, never the reverse; each firmware reaches the
vehicle at boot via `Code.prepend_path`, not as a Mix dep. Each
firmware project (`vms/firmware`, `infotainment/firmware`,
`bridges/firmware`) is parameterised by `VEHICLE` (and, for bridges,
`BRIDGE_FIRMWARE_ID`) via `OvcsVehicle.Firmware.resolve_vehicle/3`.

### One-command boot (recommended)

```sh
./ovcs run ovcs1     # or ovcs_mini, obd2
```

`./ovcs run` provisions the vcan interfaces the vehicle declares,
then spawns one BEAM per firmware from its own project directory
(`MIX_TARGET=host`). You get:

- **VMS API + debug dashboard backend** on `http://localhost:4000`,
  in the `<vehicle>-vms` BEAM.
- **Infotainment API** on `http://localhost:4001`, in the
  `<vehicle>-infotainment` BEAM (vehicles that implement
  `infotainment/0`).
- **One BEAM per bridge firmware**, named `<vehicle>-bridge-<id>`,
  running the bridge's `children/0` against host-side vcan.
- **An Erlang-distribution cluster** stitched together by
  `OvcsBus.Cluster` — each BEAM `Node.connect/1`s the others at
  boot, and `OvcsBus.broadcast/2` fans messages out to every node.
  Same transport in deployed mode.

Dashboards run separately:

```sh
cd vms/dashboard && npm install && npm run dev
cd infotainment/dashboard && flutter run -d linux
```

### Running pieces in isolation

Sometimes you only want VMS (say you're iterating on a component)
or only infotainment. Boot each side from its Phoenix app with the
`VEHICLE` env var:

```sh
cd vms/api && VEHICLE=Ovcs1 mix phx.server
cd infotainment/api && VEHICLE=Ovcs1 mix phx.server
```

### Custom CAN mappings

Override the default host mapping by setting `CAN_NETWORK_MAPPINGS`
before `./ovcs run` (or the per-side `mix phx.server`):

```sh
CAN_NETWORK_MAPPINGS=ovcs:can0,leaf_drive:vcan1,polo_drive:vcan2,orion_bms:vcan3,misc:vcan4 ./ovcs run ovcs1
```

Next: [Testing CAN Messages](./testing_can_messages.md)
