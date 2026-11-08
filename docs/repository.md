---
title: Repository layout
description: The monorepo's tree, where each component is documented, the shared libraries, the vehicle packages and the environment variables the firmwares read.
---

OVCS is a monorepo holding the framework's components and, under `vehicles/`, the vehicles built on it. The framework side is a set of independent projects: Elixir Mix projects, a C++/PlatformIO project, React apps, a Flutter app and a Rust CLI. Each has its own dependencies, configuration and build; the Elixir projects reference each other through relative `path:` dependencies. It is **not** an Elixir umbrella.

> [!NOTE]
> Here, *component* means a piece of the framework, and *vehicle* means a package under `vehicles/`. Every component is vehicle-agnostic. See [Framework and vehicles](./framework.md).

## The repository

```text
ovcs/
+-- vms/                      FRAMEWORK · Vehicle Management System
|   +-- core/                   Elixir library: VMS platform + component drivers (no vehicle code)
|   +-- api/                    Phoenix JSON API + WebSocket server for the debug dashboard
|   +-- dashboard/              React real-time debug dashboard (Vite + @ovcs/ui + ECharts)
|   +-- firmware/               Nerves firmware shell targeting Raspberry Pi 4
+-- infotainment/             FRAMEWORK · Infotainment system
|   +-- core/                   Elixir library: infotainment platform (no vehicle code)
|   +-- api/                    Phoenix JSON API + WebSocket server for the Flutter dashboard
|   +-- dashboard/              Flutter/Dart in-car touchscreen app
|   +-- firmware/               Nerves firmware shell targeting Raspberry Pi 5
+-- bridges/                  FRAMEWORK · Communication bridges
|   +-- firmware/               Shared Nerves image hosting one or more bridges per build
|   +-- radio_control_bridge/   MAVLink RC transmitter bridge library
|   +-- ros_bridge/             Native rmw_zenoh ROS 2 bridge library
+-- vision/                   FRAMEWORK · Vision unit (stereo depth and detection)
|   +-- core/                   Elixir library: cameras, Nx stereo stages, detectors, Zenoh publishers (no vehicle code)
|   +-- api/                    Phoenix endpoint for the dashboard
|   +-- dashboard/              React dashboard
|   +-- firmware/               Nerves firmware shell targeting Raspberry Pi 5 and OKdo Nano C100
|   +-- rust/                   camera_capture, v4l2_capture, hailo_detect, jpeg_codec and stereo_match Ports
+-- controllers/              FRAMEWORK
|   +-- generic_controller/     PlatformIO C++ project for Arduino R4 Minima
+-- libraries/                FRAMEWORK · Shared Elixir libraries (in-tree and sideloaded)
+-- cli/                      FRAMEWORK · Rust source for the `ovcs` CLI
+-- compose/                  FRAMEWORK · Container stacks: compute/ (the vehicle's compute node) and local/
+-- systems/                  Local clones of the Nerves system forks, when you need to patch one
+-- vehicles/                 VEHICLES · one package per vehicle
|   +-- ovcs1/                  Reference vehicle: full-size Polo EV conversion
|   +-- ovcs_mini/              Reference vehicle: Traxxas RC car
|   +-- obd2/                   Reference vehicle: OBD2 diagnostic tool
|   +-- <yours>/                Your vehicle, scaffolded by `./ovcs new`
+-- scripts/                  Utility scripts (setup_can.sh, bind_remote_can.rb, …)
+-- candumps/                 Recorded CAN captures, for replay
+-- docs/                     These guides
+-- ovcs                      Symlink to cli/ovcs, the binary built by `mise run cli` (binary gitignored, symlink committed)
```

Each major system follows the Firmware → API → Core layering described in [Architecture](./architecture.md). Every Elixir project runs on a host machine against virtual CAN interfaces; development needs no hardware.

## Where each component is documented

| Component | Paths | Guide |
|---|---|---|
| VMS | `vms/{core,api,dashboard,firmware}/` | [VMS](./vms/README.md) |
| Infotainment | `infotainment/{core,api,dashboard,firmware}/` | [Infotainment](./infotainment/README.md) |
| Vision unit | `vision/{core,api,dashboard,firmware,rust}/` | [Vision unit](./vision/README.md) |
| The OVCS bus and its gateway | `libraries/ovcs_bus/`, `libraries/ovcs_bus_gateway/` | [The OVCS bus](./bus/README.md) |
| Bridges | `bridges/`, `libraries/ovcs_bridge/` | [Bridges](./bridges/README.md) |
| Generic controller | `controllers/generic_controller/` | [Generic controllers](./generic_controllers/README.md) |
| Compute node and local stacks | `compose/` | [ROS 2](./ros2/README.md), [ROS compute node](./ros2/compute_node.md) |
| The `ovcs` CLI | `cli/` | [CLI reference](../cli/README.md) |

Each component's own README keeps its developer details: build, tests and source layout.

## Shared libraries

Two kinds live side by side under `libraries/`. **In-tree** libraries are framework-internal contracts that evolve with the rest of the code. **Sideloaded** libraries are reusable outside OVCS, so they have their own repositories; they are gitignored here and cloned by `mise run libraries`, which `mise install` runs for you, at the commits pinned in `scripts/libraries.tsv`. A change to one of them reaches OVCS through a change to its pin.

| Library | Module | Source | Purpose |
|---|---|---|---|
| `ovcs_vehicle/` | `OvcsVehicle` | [in-tree](../libraries/ovcs_vehicle/README.md) | The top-level behaviour every vehicle implements, and the `ovcs new` scaffold |
| `ovcs_can/` | `OvcsCan` | [in-tree](../libraries/ovcs_can/README.md) | Shared per-component CAN frame YAMLs under `priv/can/components/`, no runtime logic |
| `ovcs_bus/` | `OvcsBus` | [in-tree](../libraries/ovcs_bus/README.md) | Per-firmware pub/sub, and the Erlang mesh joining the firmwares; see [The OVCS bus](./bus/README.md) |
| `ovcs_bridge/` | `OvcsBridge` | [in-tree](../libraries/ovcs_bridge/README.md) | Behaviour and supervisor for bridge libraries |
| `ovcs_bus_gateway/` | `OvcsBusGateway` | [in-tree](../libraries/ovcs_bus_gateway/README.md) | Library exposing the bus over MQTT, HTTP and Phoenix Channels, with a dashboard, run by a bridge firmware; see [Bus gateway](./bus/gateway.md) |
| `ovcs_ui/` | `@ovcs/ui` | [in-tree](../libraries/ovcs_ui/README.md) | Design tokens, Tailwind preset, and React components shared by OVCS web UIs (npm package) |
| `ovcs_drivers/` | `OvcsDrivers` | [in-tree](../libraries/ovcs_drivers/README.md) | Hardware chip drivers grouped by kind: the BNO085 IMU, the RPLIDAR scanning lidar, the A02YYUW ultrasonic rangefinder |
| `cantastic/` | `Cantastic` | [sideloaded](https://github.com/open-vehicle-control-system/cantastic) | CAN library: YAML frame specs, SocketCAN, emitter/receiver, ISO-TP, OBD2, `socketcand`, received-frame watchdog |
| `express_lrs/` | `ExpressLrs` | [sideloaded](https://github.com/open-vehicle-control-system/express_lrs) | MAVLink decoder for ExpressLRS links |
| `msp_osd/` | `MspOsd` | [sideloaded](https://github.com/open-vehicle-control-system/msp_osd) | MSP / DisplayPort OSD stack for HDZero, Walksnail and DJI VTXs |
| `ovcs_control/` | `OvcsControl` | [sideloaded](https://github.com/open-vehicle-control-system/ovcs_control) | PID controller, input filters, interactive tuning simulator |

A vehicle's topology YAMLs import shared component specs with Cantastic's cross-app syntax:

```yaml
- import!:@ovcs_can:can/components/ovcs/0x1A0_vms_status.yml
```

## Vehicle packages

A vehicle is a standalone Mix package under `vehicles/<name>/` whose top-level module implements `OvcsVehicle`: `name/0`, `vms/0`, `can_config_otp_app/0`, `vms_target/0`, and optionally `infotainment/0`, `infotainment_target/0`, `vision/0`, `vision_target/0`, `bridge_firmwares/0`, `geometry/0`. It bundles the VMS composer, an optional infotainment composer, optional bridge declarations, the CAN topology and per-role firmware overrides. It has no `Application` module: the framework's firmware shells load it at boot.

| Package | Top-level module | What it demonstrates |
|---|---|---|
| `vehicles/ovcs1/` | `Ovcs1` | Full-size EV conversion: VMS on five isolated buses, infotainment, radio-control and ROS bridges, generic controllers |
| `vehicles/ovcs_mini/` | `OvcsMini` | RC car on two buses (`ovcs`, and `misc` for the VESC): no infotainment side; the radio control and ROS bridges in two bridge firmwares (`radio_control`, `ros`); a vision unit; a compute node |
| `vehicles/obd2/` | `Obd2` | Diagnostics only: VMS and infotainment, no bridges, no drivetrain |
| `vehicles/<yours>/` | `<Yours>` | Scaffolded by `./ovcs new`; keep the components you need, drop the rest |

Each firmware's `runtime.exs` writes the side composer (`Ovcs1.Vms.Composer`, for example) into `:vms_core, :vehicle`, `:infotainment_core, :vehicle` or `:vision_core, :vehicle`. The wiring and the scaffold are in [Your vehicle package](./vehicle_package.md).

## Environment variables

| Variable | Description | Example |
|---|---|---|
| `VEHICLE` | Top-level module name of the vehicle to load (case-sensitive) | `Ovcs1`, `OvcsMini`, `Obd2`, or your own |
| `CAN_NETWORK_MAPPINGS` | Overrides the vehicle's `default_can_mapping/1` (host or target arm) | `ovcs:can0,leaf_drive:vcan1,polo_drive:vcan2` |
| `BRIDGE_FIRMWARE_ID` | Bridge firmware only: picks one entry from the vehicle's `bridge_firmwares/0` | `radio_control`, `ros` |

## Elsewhere

- [GitHub organisation](https://github.com/open-vehicle-control-system): the Nerves system forks, the sideloaded libraries, the presentations.
- [Elixir Forum thread](https://elixirforum.com/t/driving-a-car-powered-with-nerves-and-elixir/71557): the project announcement and discussion.
- Talks and videos: [Community and talks](./community.md).
