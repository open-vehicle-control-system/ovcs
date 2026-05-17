# OVCS Documentation

Index for the Open Vehicle Control System guides. For a high-level project overview, see the [main README](../README.md).

## Guides

### Getting started

- [Getting Started](./getting_started.md) — prerequisites, mise + system packages, fwup, repo bootstrap, virtual CAN, dev verification.

### Understanding the codebase

- [Applications](./applications.md) — what each app and library is, how the layers fit together, and how to run them.
- [Vehicle Parameterisation](./vehicle_parameterisation.md) — how `VEHICLE` selects a composer, how each firmware boots against a vehicle package, and the four behaviours in play (`OvcsVehicle`, `VmsCore.Vehicle`, `InfotainmentCore.Vehicle`, `OvcsBridge`).

### Hardware

- [Hardware Architecture](./hardware_architecture.md) — design principles, component layout, CAN bus topology and bitrates.
- [Running on Hardware](./running_hardware.md) — Nerves targets, the `ovcs` CLI for build / burn / OTA upload, attach / connect for runtime debugging.
- [OVCS1 Wiring Reference](../vehicles/ovcs1/WIRING.md) — pin-level wiring for the OVCS1 vehicle (Leaf harness, iBooster, steering pump, Polo CAN bus).

### Development and testing

- [Testing CAN Messages](./testing_can_messages.md) — simulating CAN traffic with `cansend` and replaying captures from `candumps/`.
- [Testing Generic Controllers](./testing_generic_controllers.md) — adopting a generic Arduino controller and verifying it from the dashboard or IEx.

## Architecture Reference

OVCS is a monorepo of independent Elixir applications, a C++/PlatformIO
project, and frontend apps — **not** an Elixir umbrella. Each app has
its own `mix.exs`. See the [main README](../README.md#repository-structure)
for the full directory tree and [Applications](./applications.md) for
the dependency graph and layer breakdown.

### Shared Libraries

Cross-cutting Elixir libraries under `libraries/`. Each one has its
own README with usage, design notes, and API.

| Library | Path | Module | README |
|---------|------|--------|--------|
| OvcsVehicle | `libraries/ovcs_vehicle/` | `OvcsVehicle` | [README](../libraries/ovcs_vehicle/README.md) — vehicle-package behaviour + `ovcs vehicle new` scaffold |
| OvcsCan | `libraries/ovcs_can/` | `OvcsCan` | [README](../libraries/ovcs_can/README.md) — shared CAN frame YAMLs (`import!:@ovcs_can:…`) |
| OvcsBus | `libraries/ovcs_bus/` | `OvcsBus` | [README](../libraries/ovcs_bus/README.md) — cluster-wide pub/sub over Erlang distribution |
| OvcsBridge | `libraries/ovcs_bridge/` | `OvcsBridge` | [README](../libraries/ovcs_bridge/README.md) — bridge-library contract + firmware supervisor |
| OvcsDrivers | `libraries/ovcs_drivers/` | `OvcsDrivers` | [README](../libraries/ovcs_drivers/README.md) — hardware chip drivers grouped by kind (`OvcsDrivers.Imu`, …); currently BNO085 |
| Cantastic | `libraries/cantastic/` | `Cantastic` | [README](../libraries/cantastic/README.md) — CAN bus library (SocketCAN, YAML config, frame encoding/decoding) |
| ExpressLRS | `libraries/express_lrs/` | `ExpressLrs` | [README](../libraries/express_lrs/README.md) — ExpressLRS MAVLink decoder (used by `radio_control_bridge`) |
| MspOsd | `libraries/msp_osd/` | `MspOsd` | [README](../libraries/msp_osd/README.md) — MSP + DisplayPort stack (v1 jumbo / v2 / v2-over-v1) for pushing OSD to HDZero/Walksnail/DJI VTX |

### Elixir Applications

| Application | Path | Module | Description |
|-------------|------|--------|-------------|
| VMS Core | `vms/core/` | `VmsCore` | Vehicle management business logic, component drivers, vehicle composers |
| VMS API | `vms/api/` | `VmsApi` | Phoenix JSON API + WebSocket for the debug dashboard |
| VMS Firmware | `vms/firmware/` | `VmsFirmware` | Nerves firmware image for Raspberry Pi 4 |
| Infotainment Core | `infotainment/core/` | `InfotainmentCore` | Infotainment business logic, UI layout, pages and blocks |
| Infotainment API | `infotainment/api/` | `InfotainmentApi` | Phoenix JSON API + WebSocket for the Flutter dashboard |
| Infotainment Firmware | `infotainment/firmware/` | `InfotainmentFirmware` | Nerves firmware image for Raspberry Pi 5 |
| Bridge Firmware | `bridges/firmware/` | `BridgeFirmware` | Shared Nerves image (targets `:ovcs_base_can_system_rpi3a`, `:ovcs_base_can_system_rpi4`, `:ovcs_bridges_system_rpi5`); bundles the bridge libraries the active vehicle declares in `bridge_firmwares/0` |
| Radio Control Bridge | `bridges/radio_control_bridge/` | `RadioControlBridge` | MAVLink/ExpressLRS RC bridge library (hosted by `bridge_firmware`) |
| ROS Bridge | `bridges/ros_bridge/` | `RosBridge` | Native rmw_zenoh ROS 2 bridge with BNO085 IMU (hosted by `bridge_firmware`) |

### Non-Elixir Components

| Component | Path | Technology | Description |
|-----------|------|------------|-------------|
| Generic Controller | `controllers/generic_controller/` | C++ / PlatformIO | Arduino R4 Minima firmware for CAN-connected hardware controllers |
| VMS Dashboard | `vms/dashboard/` | Vue.js 3 / Vite | Real-time debug dashboard with charts and metrics |
| Infotainment Dashboard | `infotainment/dashboard/` | Flutter / Dart | In-car touchscreen UI for gear selection, status, and diagnostics |

## External Resources

Presentations and video links live in the
[main README](../README.md#presentations-and-media). Additional pointers:

- [ElixirForum: Driving a car powered with Nerves and Elixir](https://elixirforum.com/t/driving-a-car-powered-with-nerves-and-elixir/71557) -- Project announcement and community discussion
- [GitHub: OVCS Organization](https://github.com/open-vehicle-control-system) -- All repositories (ovcs, base systems, presentations)
- [GitHub: Presentations](https://github.com/open-vehicle-control-system/presentations) -- Slide decks from conference talks
