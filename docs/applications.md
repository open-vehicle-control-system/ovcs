---
title: Framework components
description: What the framework ships (cores, APIs, dashboards, firmware shells, bridges, controllers, shared libraries, the CLI) and how to run them on a laptop.
---

OVCS is a monorepo holding the framework's components and, under `vehicles/`, the applications built on it. The framework side is a set of independent projects: Elixir Mix projects, a C++/PlatformIO project, a Vue app, a Flutter app and a Rust CLI. Each has its own dependencies, configuration and build; the Elixir projects reference each other through relative `path:` dependencies. It is **not** an Elixir umbrella. This page is the inventory: what each component is, what it depends on, and how to run it.

> [!NOTE]
> Here, *component* or *project* means a piece of the framework, and *application* means a vehicle package under `vehicles/`. Every component below is vehicle-agnostic. See [Framework and applications](./framework.md).

## The repository

```text
ovcs/
+-- vms/                      FRAMEWORK · Vehicle Management System
|   +-- core/                   Elixir library: VMS platform + component drivers (no vehicle code)
|   +-- api/                    Phoenix JSON API + WebSocket server for the debug dashboard
|   +-- dashboard/              Vue.js real-time debug dashboard (Vite + ECharts + TailwindCSS)
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
+-- controllers/              FRAMEWORK
|   +-- generic_controller/     PlatformIO C++ project for Arduino R4 Minima
+-- libraries/                FRAMEWORK · Shared Elixir libraries (in-tree and sideloaded)
+-- cli/                      FRAMEWORK · Rust source for the `ovcs` CLI
+-- compose/                  FRAMEWORK · Container stacks: compute/ (the vehicle's compute node) and local/
+-- systems/                  Local clones of the Nerves system forks, when you need to patch one
+-- vehicles/                 APPLICATIONS · one package per vehicle
|   +-- ovcs1/                  Reference application: full-size Polo EV conversion
|   +-- ovcs_mini/              Reference application: Traxxas RC car
|   +-- obd2/                   Reference application: OBD2 diagnostic tool
|   +-- <yours>/                Your vehicle, scaffolded by `./ovcs new`
+-- scripts/                  Utility scripts (setup_can.sh, bind_remote_can.rb, …)
+-- candumps/                 Recorded CAN captures, for replay
+-- docs/                     These guides
+-- ovcs                      Symlink to cli/ovcs (built by `mise run cli`; gitignored)
```

Each major system follows the Firmware → API → Core layering described in [Architecture](./architecture.md). Every Elixir project runs on a host machine against virtual CAN interfaces; development needs no hardware.

## Vehicle Management System

The VMS is the central brain of any application: it translates and orchestrates every vehicle component so that parts from different manufacturers cooperate.

### VMS Core

| | |
|---|---|
| **Path** | `vms/core/` |
| **Module** | `VmsCore` |
| **Key deps** | `cantastic`, `ovcs_can`, `ovcs_bus`, `ovcs_control`, `ovcs_vehicle`, `ecto_sqlite3`, `crc`, `decimal` |

- **Component drivers** under `lib/vms_core/components/`: GenServers that each manage one piece of hardware or one input. The framework ships the drivers its reference applications need; an application picks the ones it uses. Module names are `VmsCore.Components.*`, aliased in composers as below:
  - drivetrain and body: `Bosch.IBoosterGen2`, `Nissan.LeafAZE0.Inverter` and `.Charger`, `Evpt.Evpt23Charger`, `Orion.Bms2`, the `Volkswagen.Polo9N.*` body modules (ABS, dashboard, ignition lock, power steering pump, passenger compartment);
  - small vehicles: `Traxxas.MotorController` and `Traxxas.Steering` over PWM, `Vesc.MotorController` over CAN (see [VESC drivetrain](./vesc_drivetrain.md));
  - OVCS inputs and helpers: `OVCS.GenericController`, `OVCS.ThrottlePedal`, `OVCS.SteeringColumn`, `OVCS.HighVoltageContactors`, `OVCS.WaterPump`, `OVCS.PulseRotationSensor`, `OVCS.RotationFusion` (one shaft's rotation from several sensors), `OVCS.VehicleMotion` (speed), `OVCS.InputCurve` (a hand's dead zone and expo);
  - commanders: the `OVCS.RadioControl.*` inputs, and the two ROS command paths, `OVCS.RosActuatorCommand.*` (joystick positions) and `OVCS.RosVelocityCommand` (planner velocity).
- **Vehicle behaviour**, `lib/vms_core/vehicle.ex`: the contract each application's VMS composer implements. Required `children/0`, `can_config_otp_app/0`, `can_config_path/0`, `default_can_mapping/1`; optional `dashboard_configuration/0` and `generic_controllers/0`.
- **Managers** under `lib/vms_core/managers/`: `ControlLevel` (who commands the vehicle) and `Gear`.
- **Metrics**, `lib/vms_core/metrics.ex`: collects bus messages and exposes the latest values to the API.
- **Control loops**: the brake booster and steering column use `OvcsControl.PID` from [`ovcs_control`](#shared-libraries).

CAN topology files are not here: they belong to the application, under `vehicles/<name>/priv/can/`, and import shared frame specs from [`ovcs_can`](#shared-libraries).

### VMS API

| | |
|---|---|
| **Path** | `vms/api/` |
| **Module** | `VmsApi` |
| **Key deps** | `phoenix`, `vms_core`, `bandit`, `cors_plug` |

A Phoenix 1.7 JSON API exposing vehicle data and control actions. Real-time metrics stream over Phoenix Channels (`MetricsChannel`, `NetworkInterfacesChannel`). In development, LiveDashboard is at `/dev/dashboard`.

```text
GET  /api/vehicle                         Vehicle status and info
GET  /api/vehicle/pages                   Dashboard page layout
GET  /api/vehicle/pages/:page_id/blocks   Blocks for a specific page
POST /api/actions                         Dispatch control actions
```

### VMS Dashboard

| | |
|---|---|
| **Path** | `vms/dashboard/` |
| **Technology** | Vue.js 3, Vite, ECharts, TailwindCSS, Pinia |

A single-page app for monitoring and debugging during development. Pages and blocks come from the layout the API serves, so the application's composer decides what appears: real-time line charts, metric tables, action buttons, network-interface monitoring. `./ovcs run` starts it as a dev add-on on `http://localhost:5173` with hot reload; the API on port `4000` serves the last prebuilt bundle.

### VMS Firmware

| | |
|---|---|
| **Path** | `vms/firmware/` |
| **Module** | `VmsFirmware` |
| **Target** | Raspberry Pi 4 (`ovcs_base_can_system_rpi4`) |

The Nerves shell that packages the API and Core for the Pi 4, on a [custom Nerves system](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi4) with CAN-over-SPI support. It contains no vehicle code: at boot it reads `VEHICLE` and loads the application.

## Infotainment system

The in-car UI on a 10-inch touchscreen: gear selection, vehicle status, battery health, settings. An application opts in by implementing `infotainment/0`.

| Layer | Path | Module / tech | Notes |
|---|---|---|---|
| Core | `infotainment/core/` | `InfotainmentCore` | Vehicle behaviour, layout validator, temperature, time settings persisted in SQLite. Deps: `cantastic`, `ovcs_can`, `ovcs_bus`, `ecto_sqlite3`. |
| API | `infotainment/api/` | `InfotainmentApi` | Phoenix 1.7 JSON API with the same page/block model as the VMS API, plus a `MetricsChannel`. Serves on `plug_cowboy`. |
| Dashboard | `infotainment/dashboard/` | Flutter / Dart (Flutter 3.32.8, pinned in `mise.toml`) | Native Linux app: gear selector, speed gauge, battery overview, status grid, settings. Connects through `phoenix_socket`. |
| Firmware | `infotainment/firmware/` | `InfotainmentFirmware` | Nerves shell for the Pi 5 (`ovcs_base_can_system_rpi5`); bundles the Flutter app with [`nerves_flutter_support`](https://hex.pm/packages/nerves_flutter_support). |

## Bridges

A **bridge** is an Elixir library under `bridges/<name>/` that ferries data between the `ovcs` CAN bus and a non-CAN world. Bridge libraries implement the `OvcsBridge` behaviour and are bundled into the shared `bridges/firmware/` Nerves image. An application declares which bridges to build, and on which Nerves target, in its `bridge_firmwares/0` callback: one image per entry, addressed on the CLI as `bridge-<id>`.

### Bridge firmware

| | |
|---|---|
| **Path** | `bridges/firmware/` |
| **Module** | `BridgeFirmware` |
| **Targets** | `ovcs_base_can_system_rpi3a`, `ovcs_base_can_system_rpi4`, `rpi5` |

Reads `VEHICLE` and `BRIDGE_FIRMWARE_ID` at boot, looks up the matching entry in the application's `bridge_firmwares/0`, and supervises each listed bridge's `children/0` under `OvcsBridge.Supervisor`.

### Radio control bridge

| | |
|---|---|
| **Path** | `bridges/radio_control_bridge/` |
| **Module** | `RadioControlBridge` |
| **Key deps** | `cantastic`, `express_lrs`, `msp_osd`, `ovcs_bridge` |

Lets a MAVLink-capable transmitter (an ExpressLRS link in MAVLink mode) drive the vehicle. `MavlinkForwarder` reads MAVLink `RC_CHANNELS_OVERRIDE` from a UART and copies the receiver's channels 1 to 8 onto CAN frames `0x2A0` and `0x2A1`. `MspOsdForwarder`, the telemetry path back to MSP video goggles, is a placeholder not yet wired in. An application selects components through `%RadioControlBridge.Config{}`.

### ROS bridge

| | |
|---|---|
| **Path** | `bridges/ros_bridge/` |
| **Module** | `RosBridge` |
| **Key deps** | `cantastic`, `zenohex`, `ovcs_bridge`, `ovcs_drivers` |

Speaks the `rmw_zenoh` wire format natively over Zenoh, linking nothing from ROS. `ZenohClient` holds one session and exposes publish/subscribe (wire-format details in [`bridges/ros_bridge/README.md`](../bridges/ros_bridge/README.md)). Components an application selects through `%RosBridge.Config{}`:

- a heartbeat on `/ovcs_heartbeat`, and a simulator clock;
- `Consumers.Joy`: a `sensor_msgs/Joy` becomes the `0x2B0` actuator command;
- `Consumers.Velocity`: a planner `Twist` becomes the `0x2B1` velocity command;
- `Publishers.Imu` from any `OvcsDrivers.Imu` driver (`OvcsDrivers.Imu.Dummy` on the host, the BNO085 on target), `Publishers.Odometry`, static transforms;
- a stereo camera pipeline and a Hailo-8 object detector.

How it all connects is in [ROS 2 and the simulator](./ros2_integration.md).

## Compute node

| | |
|---|---|
| **Path** | `compose/compute/` |
| **Technology** | Docker Compose on balenaOS |
| **Deploy** | `balena push` from `compose/compute/` |

The one machine on a vehicle that is not Nerves: a Raspberry Pi 5 with a full Linux userland running the Zenoh router every bridge peers with, `foxglove_bridge`, Nav2, and the Wi-Fi firmware service behind the vehicle's access point. Every image it runs is defined under `compose/compute/images/`; the operator and simulation stacks in `compose/local/` build the same images. The OVCS Mini reference application is the one with a compute node. See [`compose/README.md`](../compose/README.md) for the split and [ROS compute node](./ros_compute_node.md) for the machine.

## Generic controller

| | |
|---|---|
| **Path** | `controllers/generic_controller/` |
| **Technology** | C++ / PlatformIO |
| **Target** | Arduino R4 Minima |

One configurable firmware for every Arduino controller in every application. Pin assignments arrive over CAN through the adoption process, so nothing is hardcoded per board. Supports digital output (with MCP23008 I2C expansion boards for extra pins), analog input, DAC, PWM, external PWM through a PWM hat on the UART, and a pulse counter. All frames are CRC-protected.

| Environment | Purpose |
|---|---|
| `uno_r4_minima_prod` | Production build |
| `uno_r4_minima_debug` | Debug build with serial output |
| `local_test` | Unit tests (Unity framework) |

Flashing and adoption are in [Generic controllers](./testing_generic_controllers.md).

## Shared libraries

Two kinds live side by side under `libraries/`. **In-tree** libraries are framework-internal contracts that evolve with the rest of the code. **Sideloaded** libraries are reusable outside OVCS, so they have their own repositories; they are gitignored here and cloned by `mise run libraries`, which `mise install` runs for you.

| Library | Module | Source | Purpose |
|---|---|---|---|
| `ovcs_vehicle/` | `OvcsVehicle` | [in-tree](../libraries/ovcs_vehicle/README.md) | The top-level behaviour every application implements, and the `ovcs new` scaffold |
| `ovcs_can/` | `OvcsCan` | [in-tree](../libraries/ovcs_can/README.md) | Shared per-component CAN frame YAMLs under `priv/can/components/`, no runtime logic |
| `ovcs_bus/` | `OvcsBus` | [in-tree](../libraries/ovcs_bus/README.md) | Cluster-wide pub/sub over Erlang distribution |
| `ovcs_bridge/` | `OvcsBridge` | [in-tree](../libraries/ovcs_bridge/README.md) | Behaviour and supervisor for bridge libraries |
| `ovcs_drivers/` | `OvcsDrivers` | [in-tree](../libraries/ovcs_drivers/README.md) | Hardware chip drivers grouped by kind; currently the BNO085 IMU |
| `cantastic/` | `Cantastic` | [sideloaded](https://github.com/open-vehicle-control-system/cantastic) | CAN library: YAML frame specs, SocketCAN, emitter/receiver, ISO-TP, OBD2, `socketcand`, received-frame watchdog |
| `express_lrs/` | `ExpressLrs` | [sideloaded](https://github.com/open-vehicle-control-system/express_lrs) | MAVLink decoder for ExpressLRS links |
| `msp_osd/` | `MspOsd` | [sideloaded](https://github.com/open-vehicle-control-system/msp_osd) | MSP / DisplayPort OSD stack for HDZero, Walksnail and DJI VTXs |
| `ovcs_control/` | `OvcsControl` | [sideloaded](https://github.com/open-vehicle-control-system/ovcs_control) | PID controller, input filters, interactive tuning simulator |

An application's topology YAMLs import shared component specs with Cantastic's cross-app syntax:

```yaml
- import!:@ovcs_can:can/components/ovcs/0x1A0_vms_status.yml
```

## Applications: the vehicle packages

An application is a standalone Mix package under `vehicles/<name>/` whose top-level module implements `OvcsVehicle`: `name/0`, `vms/0`, `can_config_otp_app/0`, `vms_target/0`, and optionally `infotainment/0`, `infotainment_target/0`, `bridge_firmwares/0`, `geometry/0`. It bundles the VMS composer, an optional infotainment composer, optional bridge declarations, the CAN topology and per-role firmware overrides. It has no `Application` module: the framework's firmware shells load it at boot.

| Package | Top-level module | What it demonstrates |
|---|---|---|
| `vehicles/ovcs1/` | `Ovcs1` | Full-size EV conversion: VMS on five isolated buses, infotainment, radio-control and ROS bridges, generic controllers |
| `vehicles/ovcs_mini/` | `OvcsMini` | RC car on one bus: no infotainment side; radio-control, ROS and perception bridges; a compute node |
| `vehicles/obd2/` | `Obd2` | Diagnostics only: VMS and infotainment, no bridges, no drivetrain |
| `vehicles/<yours>/` | `<Yours>` | Scaffolded by `./ovcs new`; keep the components you need, drop the rest |

Each firmware's `runtime.exs` writes the side composer (`Ovcs1.Vms.Composer`, for example) into `:vms_core, :vehicle` or `:infotainment_core, :vehicle`. The wiring and the scaffold are in [Your application package](./vehicle_parameterisation.md).

## Environment variables

| Variable | Description | Example |
|---|---|---|
| `VEHICLE` | Top-level module name of the application to load (case-sensitive) | `Ovcs1`, `OvcsMini`, `Obd2`, or your own |
| `CAN_NETWORK_MAPPINGS` | Overrides the application's `default_can_mapping(:host)` | `ovcs:can0,leaf_drive:vcan1,polo_drive:vcan2` |
| `BRIDGE_FIRMWARE_ID` | Bridge firmware only: picks one entry from the application's `bridge_firmwares/0` | `radio_control`, `ros`, `ros_perception` |

## Local development

Host development needs SocketCAN kernel support and `can-utils` (see [Getting started](./getting_started.md)). The application package depends on `vms_firmware`, `infotainment_firmware` (when it has that side) and `bridge_firmware` (when it declares bridges), so one `mix compile` in the package directory builds every framework firmware it needs into its own `_build` tree. The dependency points application → framework, never the reverse: each firmware reaches the application's compiled code at boot through `Code.prepend_path`.

### One-command boot

```sh
./ovcs run ovcs1     # or ovcs_mini, obd2, or your own package's directory name
```

This provisions the application's vcan interfaces (`./ovcs can setup <app>` does only that step), then spawns one BEAM per firmware with `MIX_TARGET=host`:

- the VMS API on `http://localhost:4000`, in the `<app>-vms` BEAM;
- the infotainment API on `http://localhost:4001`, in `<app>-infotainment`, for applications that implement `infotainment/0`;
- one BEAM per bridge firmware, named `<app>-bridge-<id>`;
- an Erlang-distribution cluster stitched together by `OvcsBus.Cluster`: each BEAM `Node.connect/1`s the others, and `OvcsBus.broadcast/2` reaches every node. Deployed firmware uses the same transport.

The Vue dashboard starts alongside as a dev add-on (`--no-addons` skips it). The Flutter dashboard needs its own terminal, because its hot reload is keyboard-driven:

```sh
mise run infotainment-dashboard   # cd infotainment/dashboard && flutter run -d linux
```

### Custom CAN mappings

```sh
CAN_NETWORK_MAPPINGS=ovcs:can0,leaf_drive:vcan1,polo_drive:vcan2,orion_bms:vcan3,misc:vcan4 ./ovcs run ovcs1
```

> [!TIP]
> On a Nerves device, Cantastic brings the physical interfaces up at boot (`setup_can_interfaces: true`). For a physical adapter on a host, `./scripts/setup_can.sh` brings `can0`, `can1` and `can2` up at 500 kbps with `ip link` (needs `sudo`).

## Elsewhere

- [GitHub organisation](https://github.com/open-vehicle-control-system): the Nerves system forks, the sideloaded libraries, the presentations.
- [Elixir Forum thread](https://elixirforum.com/t/driving-a-car-powered-with-nerves-and-elixir/71557): the project announcement and discussion.
- Talks and videos: [Community and talks](./community.md).
