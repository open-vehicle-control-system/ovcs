# OVCS Documentation

Welcome to the Open Vehicle Control System documentation. For a high-level overview of the project, see the [main README](../README.md).

## Guides

### Getting Started

- [Getting Started](./getting_started.md) -- Prerequisites, environment setup, cloning the repository, and directory structure for system images.

### Understanding the Applications

- [Applications](./applications.md) -- Description of each OVCS application (VMS, Infotainment, Bridges, Controllers), their dependencies, and how to run them locally for development.
- [Vehicle Parameterisation](./vehicle_parameterisation.md) -- How `VEHICLE=<Module>` selects the composer, how each firmware boots against a vehicle package, the `OvcsVehicle` / `VmsCore.Vehicle` / `InfotainmentCore.Vehicle` / `OvcsBridge` contracts, and the bus helpers.

### Hardware

- [Hardware Architecture](./hardware_architecture.md) -- Hardware design principles, component layout, CAN bus isolation strategy, and the role of each physical device.
- [Running on Hardware](./running_hardware.md) -- Supported hardware platforms, firmware configuration, deployment scripts, and CAN interface customization.
- [OVCS1 Wiring Reference](../vehicles/ovcs1/WIRING.md) -- Pin-level wiring notes for the OVCS1 vehicle (Leaf harness, iBooster, steering pump, Polo CAN bus).

### Development and Testing

- [Testing CAN Messages](./testing_can_messages.md) -- Simulating CAN traffic with `cansend` and replaying CAN dumps for local development.
- [Testing Generic Controllers](./testing_generic_controllers.md) -- Adopting a controller, testing digital I/O, and using `VmsCore.Controllers.TestController`.

## Architecture Reference

OVCS is a monorepo containing multiple independent Elixir applications, a C++/PlatformIO project, and frontend apps. They are **not** an Elixir umbrella project -- each application has its own `mix.exs` and dependency tree.

### Dependency Graph

```
cantastic (shared CAN bus library)
  |
  +-- vms_core ---------> vms_api ---------> vms_firmware (RPi 4)
  |
  +-- infotainment_core -> infotainment_api -> infotainment_firmware (RPi 5)
  |
  +-- radio_control_bridge_firmware (RPi 3A)
  |
  +-- ros_bridge_firmware (RPi 4/5)
```

### Shared Libraries

Cross-cutting Elixir libraries under `libraries/`. Each one has its
own README with usage, design notes, and API.

| Library | Path | Module | README |
|---------|------|--------|--------|
| OvcsVehicle | `libraries/ovcs_vehicle/` | `OvcsVehicle` | [README](../libraries/ovcs_vehicle/README.md) — vehicle-package behaviour + `ovcs vehicle new` scaffold |
| OvcsCan | `libraries/ovcs_can/` | `OvcsCan` | [README](../libraries/ovcs_can/README.md) — shared CAN frame YAMLs (`import!:@ovcs_can:…`) |
| OvcsBus | `libraries/ovcs_bus/` | `OvcsBus` | [README](../libraries/ovcs_bus/README.md) — local pub/sub + MQTT relay + broker |
| OvcsBridge | `libraries/ovcs_bridge/` | `OvcsBridge` | [README](../libraries/ovcs_bridge/README.md) — bridge-library contract + firmware supervisor |
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
| Bridges Firmware | `bridges/firmware/` | `BridgeFirmware` | Shared Nerves image, parameterised per vehicle to bundle N bridge libraries |
| Radio Control Bridge | `bridges/radio_control_bridge/` | `RadioControlBridge` | MAVLink/ExpressLRS RC bridge library (hosted by `bridges/firmware`) |
| ROS Bridge | `bridges/ros_bridge/` | `RosBridge` | ROS2/Zenoh bridge with IMU (hosted by `bridges/firmware`) |

### Non-Elixir Components

| Component | Path | Technology | Description |
|-----------|------|------------|-------------|
| Generic Controller | `controllers/generic_controller/` | C++ / PlatformIO | Arduino R4 Minima firmware for CAN-connected hardware controllers |
| VMS Dashboard | `vms/dashboard/` | Vue.js 3 / Vite | Real-time debug dashboard with charts and metrics |
| Infotainment Dashboard | `infotainment/dashboard/` | Flutter / Dart | In-car touchscreen UI for gear selection, status, and diagnostics |

## External Resources

### Presentations

| Event | Date | Links |
|-------|------|-------|
| ElixirConf EU 2024 | April 2024 | [Video](https://www.youtube.com/watch?v=2rL5yIEUU84) -- [Slides](https://github.com/open-vehicle-control-system/presentations/tree/main/ElixirconfEU%20%2019-04-2024) |
| Makilab | November 2024 | [Slides](https://github.com/open-vehicle-control-system/presentations/tree/main/Makilab%204-11-2024) |
| FOSDEM 2025 | February 2025 | [Full-size car video](https://www.youtube.com/watch?v=b74WbEGoPgI) -- [RC car video](https://www.youtube.com/watch?v=KSj2oYt7g1E) -- [Slides](https://github.com/open-vehicle-control-system/presentations/tree/main/Fosdem%202-2-2025) |

### Online

- [YouTube: Spin42 Engineering](https://www.youtube.com/@spin42engineering) -- Video updates, demos, and build logs
- [ElixirForum: Driving a car powered with Nerves and Elixir](https://elixirforum.com/t/driving-a-car-powered-with-nerves-and-elixir/71557) -- Project announcement and community discussion
- [GitHub: OVCS Organization](https://github.com/open-vehicle-control-system) -- All repositories (ovcs, base systems, presentations)
- [GitHub: Presentations](https://github.com/open-vehicle-control-system/presentations) -- Slide decks from conference talks
