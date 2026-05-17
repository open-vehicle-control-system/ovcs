# Open Vehicle Control System (OVCS)

An open-source hardware and software platform for vehicle embedded systems, built with [Elixir](https://elixir-lang.org/), [Nerves](https://nerves-project.org/), [Phoenix](https://www.phoenixframework.org/), and [Flutter](https://flutter.dev/).

OVCS tackles vendor parts lock-in in transportation by redesigning the embedded systems in a vehicle. It allows parts from different brands to seamlessly communicate and creates an abstraction layer on top of them that can be standardized, extended, and monitored.

## About

OVCS was started in early 2024 by [Marc Lainez](https://github.com/mlainez), [Loïc Vigneron](https://github.com/loicvigneron), and [Thibault Poncelet](https://github.com/thibaultponcelet) at [Spin42](https://www.spin42.com/). The project was born from a desire to make vehicle embedded computing accessible using simple, off-the-shelf components and high-level programming languages.

The first full-size platform, **OVCS1**, is a 2007 Volkswagen Polo converted to an electric vehicle using a Nissan Leaf AZE0 drivetrain, a Bosch iBooster Gen2 brake system, an Orion BMS2 battery management system, and custom Arduino-based controllers -- all orchestrated by Elixir running on Raspberry Pis via the Nerves framework.

A smaller-scale platform, **OVCS Mini**, replicates the same software and hardware stack on a Traxxas 4WD RC car, enabling safe development and testing of remote control and ROS2 features before deploying to the full-size vehicle.

## Key Features

- **CAN bus abstraction** -- The [Cantastic](./libraries/cantastic) library provides a YAML-driven CAN bus communication layer that handles frame encoding/decoding, signal extraction, and multi-bus routing via Linux SocketCAN.
- **Multi-vendor component integration** -- Seamlessly makes parts from Nissan, Volkswagen, Bosch, Orion, and custom OVCS components work together by isolating and bridging their CAN buses.
- **Vehicle Management System (VMS)** -- The central brain of the vehicle, running on a Raspberry Pi 4, that translates and orchestrates all vehicle components.
- **Infotainment system** -- An in-car touchscreen UI built with Flutter running on a Raspberry Pi 5, providing gear selection, vehicle status, and diagnostics.
- **Remote control** -- Drive the vehicle using a MAVLink-compatible RC transmitter via a dedicated bridge on a Raspberry Pi 3A.
- **ROS2 integration** -- A bridge for Robot Operating System 2 communication, enabling autonomous driving research with IMU data publishing and joystick interpretation.
- **Generic controllers** -- Arduino R4 Minima-based controllers that interface with specific vehicle components via CAN bus, receiving their configuration from the VMS through an over-the-air adoption process.
- **OBD2 diagnostics** -- A diagnostic mode for reading standard OBD2 data from any vehicle.
- **Debug dashboard** -- A real-time Vue.js web dashboard for monitoring vehicle metrics, CAN bus traffic, and component status during development.

## Architecture Overview

OVCS is built around two ideas:

- **Bus isolation.** Components from different manufacturers use overlapping CAN IDs, so each manufacturer's bus is kept separate. The VMS is the only node that touches all of them and bridges traffic where needed.
- **Pluggable vehicle packages.** The cores (`vms_core`, `infotainment_core`) and firmware shells contain zero vehicle-specific code. Each vehicle is a standalone Mix package under `vehicles/<name>/` that bundles its supervision tree, CAN topology, and Nerves targets. Selecting a vehicle at boot is one env var (`VEHICLE`).

```mermaid
flowchart LR
    classDef firmware fill:#dde5ff,stroke:#3344aa,color:#111
    classDef arduino  fill:#fff1d6,stroke:#a07000,color:#111
    classDef bus      fill:#f5f5f5,stroke:#666,color:#333,stroke-dasharray:3 3
    classDef external fill:#e7f6ec,stroke:#2a7a3a,color:#111

    subgraph CLUSTER["Erlang-distribution mesh (OvcsBus)"]
        direction TB
        VMS["VMS<br/>vms_firmware"]:::firmware
        INFO["Infotainment<br/>infotainment_firmware<br/>(optional)"]:::firmware
        BRIDGES["Bridges (0..N)<br/>bridge_firmware"]:::firmware
    end

    CTRL["Generic controllers (0..N)<br/>Arduino R4 Minima"]:::arduino

    OVCS_BUS(["OVCS internal CAN"]):::bus
    VEH_BUSES(["Vehicle CAN buses (0..N)<br/>(isolated, per manufacturer)"]):::bus

    MFG["Manufacturer components<br/>(drivetrain, BMS, brakes, body, …)"]
    HEAD["In-car head-unit UI"]:::external
    DEBUG["Developer dashboard"]:::external
    OUTSIDE["External worlds<br/>(RC link, ROS 2 graph, …)"]:::external

    VMS     --- OVCS_BUS
    INFO    --- OVCS_BUS
    BRIDGES --- OVCS_BUS
    OVCS_BUS --- CTRL

    VMS --- VEH_BUSES --- MFG

    INFO    -. HTTP + WS .- HEAD
    VMS     -. HTTP + WS .- DEBUG
    BRIDGES -. per-bridge transport .- OUTSIDE
```

- **VMS** is the only firmware that touches the vehicle CAN buses, so all message-ID isolation between manufacturers happens there.
- **Infotainment** and **bridges** are optional per vehicle — a vehicle package declares which it ships through its `OvcsVehicle` callbacks.
- **Generic controllers** are reconfigurable Arduino I/O boards. They get their pinout from the VMS at runtime via an adoption frame, so the same firmware runs on every board.
- Every BEAM in a running vehicle (VMS + optional infotainment + each bridge firmware) joins one **Erlang-distribution mesh** via `OvcsBus.Cluster`. `OvcsBus.broadcast/2` fans messages out cluster-wide with no broker. Same transport in `./ovcs run <vehicle>` on a developer laptop and on the deployed vehicle LAN.

See [Hardware Architecture](./docs/hardware_architecture.md) for a concrete instance (OVCS1: five CAN buses, three Arduino controllers, Leaf / Polo / Bosch / Orion components) and [Vehicle Parameterisation](./docs/vehicle_parameterisation.md) for the boot flow.

## Repository Structure

This is a monorepo containing multiple independent applications:

```
ovcs/
+-- vms/                        Vehicle Management System
|   +-- core/                     Elixir library - VMS platform + component drivers (no vehicle code)
|   +-- api/                      Phoenix JSON API + WebSocket server for the debug dashboard
|   +-- dashboard/                Vue.js real-time debug dashboard (Vite + ECharts + TailwindCSS)
|   +-- firmware/                 Nerves firmware targeting Raspberry Pi 4
|
+-- infotainment/               Infotainment System
|   +-- core/                     Elixir library - infotainment platform (no vehicle code)
|   +-- api/                      Phoenix JSON API + WebSocket server for the Flutter dashboard
|   +-- dashboard/                Flutter/Dart in-car touchscreen application
|   +-- firmware/                 Nerves firmware targeting Raspberry Pi 5
|
+-- vehicles/                   Vehicle Packages (pluggable)
|   +-- ovcs1/                    Full-size Polo EV conversion
|   +-- ovcs_mini/                Traxxas RC car platform
|   +-- obd2/                     OBD-II diagnostic mode
|   Each bundles its VMS + infotainment composers and CAN topology.
|
+-- bridges/                    Communication Bridges
|   +-- firmware/                 Shared Nerves image hosting one or more bridges per build
|   +-- radio_control_bridge/     MAVLink RC transmitter bridge library
|   +-- ros_bridge/               Native rmw_zenoh ROS2 bridge library
|
+-- controllers/                Arduino Controllers
|   +-- generic_controller/       PlatformIO C++ project for Arduino R4 Minima
|
+-- libraries/                  Shared Libraries
|   +-- cantastic/                CAN bus communication library (Elixir, SocketCAN)
|   +-- ovcs_can/                 Shared CAN component frame/signal YAMLs
|   +-- ovcs_vehicle/             OvcsVehicle top-level behaviour + scaffold
|   +-- ovcs_bus/                 Cluster-wide pub/sub over Erlang distribution
|   +-- ovcs_bridge/              Behaviour + supervisor for bridge libraries
|   +-- ovcs_drivers/             Hardware chip drivers, grouped by kind (Elixir; currently BNO085 IMU)
|   +-- ovcs_control/             PID controller + input filters
|   +-- express_lrs/              MAVLink v2 telemetry reader (ExpressLRS)
|   +-- msp_osd/                  MSP / DisplayPort OSD stack for MSP-compatible VTXs
|
+-- ros2/                       Docker Compose harness for ROS 2 Jazzy + Zenoh router (peers with ros_bridge)
+-- cli/                        Rust source for the `ovcs` CLI (binary at cli/ovcs)
+-- scripts/                    Utility scripts (setup_can.sh, bind_remote_can.rb, ...)
+-- config/                     Global configuration (e.g. Orion BMS2 .o2bms)
+-- candumps/                   CAN bus capture logs for offline testing and replay
+-- docs/                       Project documentation
+-- ovcs                        Symlink to cli/ovcs (built via `mise run cli`; gitignored)
```

## Supported Vehicles

| Vehicle | Description | Status |
|---------|-------------|--------|
| **OVCS1** | 2007 VW Polo converted to EV with Nissan Leaf AZE0 motor, Bosch iBooster Gen2, Orion BMS2, VW Polo 9N original systems | Drivable (manual + remote) |
| **OVCS Mini** | Traxxas 4WD RC car with the same OVCS software/hardware stack for development and testing | Operational |
| **OBD2** | Diagnostic mode for reading OBD2 data from any vehicle via a standard OBD plug | Operational |

## Technology Stack

| Layer | Technology |
|-------|------------|
| Vehicle control logic | Elixir |
| Embedded firmware | [Nerves](https://nerves-project.org/) (Linux + Erlang/OTP on Raspberry Pi) |
| Web APIs | [Phoenix Framework](https://www.phoenixframework.org/) 1.7 |
| In-car UI | [Flutter](https://flutter.dev/) / Dart |
| Debug dashboard | [Vue.js](https://vuejs.org/) 3 + [Vite](https://vitejs.dev/) + [ECharts](https://echarts.apache.org/) |
| CAN bus communication | [Cantastic](./libraries/cantastic) (Elixir + Linux SocketCAN) |
| Controllers | C++ / [PlatformIO](https://platformio.org/) on Arduino R4 Minima |
| Database | SQLite via [Ecto](https://hexdocs.pm/ecto/Ecto.html) |
| Real-time communication | Phoenix Channels (WebSocket) |
| ROS2 integration | Native [Zenoh](https://zenoh.io/) via `zenohex` (rmw_zenoh wire format), [Foxglove Studio](https://foxglove.dev/) |

## Quick Start

See the [Getting Started guide](./docs/getting_started.md) for full prerequisites and setup (Linux / VM, mise, system packages, fwup, bootstrap, verification).

Once the setup is done:

```sh
# Provision vcan interfaces and spawn one BEAM per firmware
./ovcs run ovcs1                         # VMS + infotainment + bridges

# Attach a split-pane log + IEx TUI (in another terminal)
./ovcs attach ovcs1

# Start the VMS debug dashboard (in yet another terminal)
cd vms/dashboard && npm install && npm run dev
```

`ovcs run` spawns one BEAM per declared firmware: VMS API on `:4000`,
infotainment API on `:4001` (when the vehicle has an infotainment side),
and one BEAM per entry in `bridge_firmwares/0`. They join a single
Erlang-distribution cluster — the same topology as deployed Nerves
devices on the vehicle LAN. See [Applications](./docs/applications.md)
for the per-side breakdown if you prefer running pieces separately.

## Deploy

Build, burn, or OTA-upload firmware via the `ovcs` CLI:

```sh
./ovcs vehicles                          # list discovered vehicles and their Nerves targets
./ovcs build  ovcs1 vms                  # also: infotainment | <bridge-firmware-id>
./ovcs burn   ovcs1 vms
./ovcs upload ovcs1 vms [--host HOST] [--file FILE]
```

## Presentations and Media

| Event | Date | Links |
|-------|------|-------|
| ElixirConf EU 2024 | April 2024 | [Video: Retrofitting a Car and Running it with Elixir](https://www.youtube.com/watch?v=2rL5yIEUU84) -- [Slides](https://github.com/open-vehicle-control-system/presentations/tree/main/ElixirconfEU%20%2019-04-2024) |
| Makilab | November 2024 | [Slides](https://github.com/open-vehicle-control-system/presentations/tree/main/Makilab%204-11-2024) |
| FOSDEM 2025 | February 2025 | [Video: Converting an '07 car to an RC EV using open source software](https://www.youtube.com/watch?v=b74WbEGoPgI) -- [Video: Building a robot from a Traxxas RC car](https://www.youtube.com/watch?v=KSj2oYt7g1E) -- [Slides](https://github.com/open-vehicle-control-system/presentations/tree/main/Fosdem%202-2-2025) |
| OVCS Teaser | 2025 | [Video: Open Vehicle Control System teaser](https://www.youtube.com/watch?v=429IfI6uzBg) |

Subscribe to the [Spin42 Engineering YouTube channel](https://www.youtube.com/@spin42engineering) for video updates, demos, and build logs.

## Documentation

Full documentation is in the [`docs/`](./docs/README.md) directory:

1. [Getting Started](./docs/getting_started.md) — environment setup and installation
2. [Applications](./docs/applications.md) — what each app and library is, plus local-dev
3. [Vehicle Parameterisation](./docs/vehicle_parameterisation.md) — how `VEHICLE` selects a composer and what each firmware boots
4. [Hardware Architecture](./docs/hardware_architecture.md) — physical topology, CAN networks, controllers
5. [Running on Hardware](./docs/running_hardware.md) — firmware build/burn/upload + runtime debugging via the `ovcs` CLI
6. [Testing CAN Messages](./docs/testing_can_messages.md) — simulating CAN traffic
7. [Testing Generic Controllers](./docs/testing_generic_controllers.md) — adopting + verifying generic Arduino controllers

## Disclaimer

OVCS is provided as-is without any warranty. Use it at your own risk. It is not road-certified and therefore does not meet all required criteria to be so. We decline any responsibility for any incident resulting from the usage of OVCS. OVCS is a hobby research project.

## License

[MIT License](./LICENCE.txt) -- Copyright (c) 2026 Spin42 SRL
