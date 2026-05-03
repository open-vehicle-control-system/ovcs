# OVCS Documentation

Welcome to the Open Vehicle Control System documentation. For a high-level overview of the project, see the [main README](../README.md).

## Guides

### Getting Started

- [Getting Started](./getting_started.md) -- Prerequisites, environment setup, cloning the repository, and directory structure for system images.

### Understanding the Applications

- [Applications](./applications.md) -- Description of each OVCS application (VMS, Infotainment, Bridges, Controllers), their dependencies, and how to run them locally for development.

### Hardware

- [Hardware Architecture](./hardware_architecture.md) -- Hardware design principles, component layout, CAN bus isolation strategy, and the role of each physical device.
- [Running on Hardware](./running_hardware.md) -- Supported hardware platforms, firmware configuration, deployment scripts, and CAN interface customization.
- [Wiring Reference](../WIRING.md) -- Pin-level wiring notes for the Leaf harness, iBooster, steering pump, and Polo CAN bus.

### Development and Testing

- [Testing CAN Messages](./testing_can_messages.md) -- Simulating CAN traffic with `cansend` and replaying CAN dumps for local development.
- [Testing Generic Controllers](./testing_generic_controllers.md) -- Adopting a controller, testing digital I/O, and using `VmsCore.Controllers.TestController`.
- [OBD2 Diagnostics](./obd2_diagnostics.md) -- Using OVCS as an OBD2 / KWP2000 / UDS scan tool, plus how to extend it for brand-specific Mode 22 DIDs, Mode 21 KWP2000 reads, Mode 31 routines and proprietary CAN broadcasts.

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

### Elixir Applications

| Application | Path | Module | Description |
|-------------|------|--------|-------------|
| Cantastic | `libraries/cantastic/` | `Cantastic` | CAN bus communication library (SocketCAN, YAML config, frame encoding/decoding) |
| VMS Core | `vms/core/` | `VmsCore` | Vehicle management business logic, component drivers, vehicle composers |
| VMS API | `vms/api/` | `VmsApi` | Phoenix JSON API + WebSocket for the debug dashboard |
| VMS Firmware | `vms/firmware/` | `VmsFirmware` | Nerves firmware image for Raspberry Pi 4 |
| Infotainment Core | `infotainment/core/` | `InfotainmentCore` | Infotainment business logic, UI layout, pages and blocks |
| Infotainment API | `infotainment/api/` | `InfotainmentApi` | Phoenix JSON API + WebSocket for the Flutter dashboard |
| Infotainment Firmware | `infotainment/firmware/` | `InfotainmentFirmware` | Nerves firmware image for Raspberry Pi 5 |
| Radio Control Bridge | `bridges/radio_control_bridge/firmware/` | `RadioControlBridgeFirmware` | MAVLink/ExpressLRS RC bridge (Nerves on RPi 3A) |
| ROS Bridge | `bridges/ros_bridge/firmware/` | `ROSBridgeFirmware` | ROS2/Zenoh bridge with IMU (Nerves on RPi 4/5) |

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
