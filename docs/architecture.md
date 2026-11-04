---
title: Architecture
description: Bus isolation, vehicle-agnostic cores, the vehicle contract, and the Erlang mesh that ties every firmware together.
---

OVCS is a framework for vehicle embedded systems. It makes components from different manufacturers work together in whatever vehicle you build on it. Two ideas shape everything else: each manufacturer's CAN bus stays isolated, and everything vehicle-specific lives in a separate package, a *vehicle package*, that the firmware loads at boot.

> [!NOTE]
> Everything here holds for any vehicle. OVCS1, OVCS Mini and OBD2 appear only as worked examples. See [Framework and vehicles](./framework.md).

## Two ideas

### Bus isolation

Components from different manufacturers use overlapping CAN identifiers. A Nissan Leaf inverter and a Volkswagen Polo ABS module were never meant to share a wire; on one bus their frames would collide. OVCS keeps each manufacturer's bus physically separate. The Vehicle Management System (VMS) is the only node on all of them, and bridges traffic between buses where the vehicle needs it. In the OVCS1 reference vehicle, that is how the Polo's original instrument cluster shows the Leaf motor's RPM.

An internal bus, `ovcs`, carries framework traffic: heartbeats, controller adoption, infotainment and bridge commands. Manufacturer buses run at the bitrate their components require. Which buses exist, and at what speed, is the vehicle's decision; OVCS1's five-bus layout is in [Hardware](./hardware.md).

### The framework knows no vehicle

The cores (`vms_core`, `infotainment_core`, `vision_core`), firmware shells, bridge libraries and shared libraries contain no vehicle-specific code. Every vehicle is a Mix package under `vehicles/<name>/` that implements `OvcsVehicle` and bundles its supervision tree, CAN topology YAMLs and Nerves targets. `VEHICLE`, set to the package's top-level module name, selects it at boot. [Your vehicle package](./vehicle_package.md) follows that selection through the boot sequence.

## Where the line is drawn

| Framework (vehicle-agnostic) | Vehicle (your package) |
|---|---|
| `vms_core`: component drivers, managers, metrics, the `VmsCore.Vehicle` behaviour | `<Vehicle>.Vms.Composer` implementing it |
| `infotainment_core`: layout model, the `InfotainmentCore.Vehicle` behaviour | `<Vehicle>.Infotainment.Composer` (optional) |
| `vision_core`: camera drivers, stereo depth, detector backends, the `VisionCore.Composer` behaviour | `<Vehicle>.Vision.Composer` (optional) |
| VMS, infotainment and vision Phoenix APIs, Vue, React and Flutter dashboards | `children/0`: which drivers and GenServers to supervise |
| Firmware shells (`vms/firmware`, `infotainment/firmware`, `vision/firmware`, `bridges/firmware`) that read `VEHICLE` | Nerves targets per role (`vms_target/0`, `infotainment_target/0`, `vision_target/0`) |
| Bridge libraries (`RadioControlBridge`, `RosBridge`) and the `OvcsBridge` contract | `bridge_firmwares/0`: which bridges to build, on which target |
| Shared CAN frame specs in `ovcs_can` | CAN topology YAMLs under `priv/can/` |
| The generic controller firmware and its adoption protocol | Controller pinout maps (`generic_controllers/0`) |
| The dashboard page and block model | Pages (`dashboard_configuration/0`, `infotainment_configuration/0`) |
| `OvcsBus`, `OvcsBus.Cluster`, the `ovcs` CLI | `.env.exs`: SSH keys, Wi-Fi networks, Phoenix secrets, Zenoh endpoint |

Nothing on the left changes when you add a vehicle. Everything on the right is yours, and `./ovcs new` scaffolds a starting point.

## The roles

A running vehicle is a small fleet of BEAMs:

- **VMS**: the only firmware on the vehicle CAN buses, so all isolation between manufacturers happens there. Raspberry Pi 4 with a multi-CAN SPI hub. See [VMS](./vms/README.md).
- **Infotainment** (optional): the in-car touchscreen on a Raspberry Pi 5, on the `ovcs` bus only.
- **Vision** (optional): stereo depth on a Raspberry Pi 5 or an OKdo Nano C100, and object detection where the Pi 5 has a Hailo-8, publishing ROS 2 topics over Zenoh. No CAN. See [Vision unit](./vision/README.md).
- **Bridges** (zero or more): each ferries data between the `ovcs` bus and a non-CAN world, such as an ExpressLRS radio link or a ROS 2 graph. The vehicle declares which bridges it ships and on which target.
- **Generic controllers**: Arduino R4 Minima boards running one shared firmware. They receive their pinout from the VMS at runtime through an adoption frame. See [Generic controllers](./generic_controllers/README.md).

The Vue dashboard runs off the vehicle, on a laptop, and talks to the VMS API. The Flutter head unit runs on the infotainment Pi 5, bundled into its firmware, and talks to the infotainment API. Both use HTTP and WebSocket and render the pages the vehicle's composers declare. The vision unit's React dashboard is served by its own API, from the unit, and shows its previews and its pipeline's parameters.

### One Erlang mesh, no broker

Every BEAM of a running vehicle joins one Erlang-distribution cluster through `OvcsBus.Cluster`: at boot each node calls `Node.connect/1` on its declared peers until the mesh forms. The nodes talk to each other directly: no broker, no relay between them.

A bus message is delivered on its own node only, so a slow link cannot stall a drivetrain component. `OvcsBus.Forwarder` is the cross-node path of bus traffic, and the [bus gateway](./bus/gateway.md) uses it to carry the bus out of the mesh. See [The OVCS bus](./bus/README.md).

The transport is the same in both environments: `./ovcs run <vehicle>` clusters one BEAM per role over loopback; a deployed vehicle clusters one BEAM per board over the vehicle LAN. [The mesh](./bus/README.md#the-mesh) covers node names, cookies and how `.local` names resolve.

> [!NOTE]
> Nothing safety-relevant depends on the mesh. Commands from the radio link or the ROS bridge travel as CAN frames on the `ovcs` bus, where the VMS watches their freshness. The mesh carries metrics, status and coordination.

## Three layers per system

VMS, infotainment and the vision unit share one layered shape. Each layer is its own Mix project referencing the one below through a relative `path:` dependency; this is a monorepo, not an umbrella.

```text
+------------+     +------------+     +----------------+
|  Firmware  | --> |    API     | --> |     Core       |
| (Nerves)   |     | (Phoenix)  |     | (business      |
|            |     |            |     |  logic)        |
+------------+     +------+-----+     +--------+-------+
                          |                    |
                    +-----+------+      +------+-------+
                    |  Dashboard |      |  Cantastic   |
                    | (Vue,      |      |  (CAN lib)   |
                    |  React,    |      |              |
                    |  Flutter)  |      |              |
                    +------------+      +--------------+
```

- **Core**: component drivers, managers, and the `VmsCore.Vehicle`, `InfotainmentCore.Vehicle` or `VisionCore.Composer` behaviour. No web dependencies, no vehicle code. `vision_core` has no CAN: it talks Zenoh instead of Cantastic.
- **API**: a Phoenix project exposing a JSON API and WebSocket channels. Depends on Core.
- **Dashboard**: Vue for the VMS debug dashboard, React for the vision dashboard, Flutter for the head unit.
- **Firmware**: a Nerves project packaging the API (and Core) into a bootable image. At boot it reads `VEHICLE` and loads the vehicle package.

The vehicle package sits beside these layers: the firmware reaches it through `Code.prepend_path`, and no framework project depends on it. Every Elixir project runs on a host against virtual CAN. The inventory is in [Repository layout](./repository.md).

How the VMS works inside, from its supervision tree to the component pattern every driver follows and the managers, is in [How the VMS works](./vms/how_it_works.md).

## Safety mechanisms in the framework

Every vehicle gets these without writing them:

- **HV contactor precharge.** Negative, then precharge, wait for the voltages to equalise, then positive, then drop precharge. Prevents inrush damage.
- **VMS heartbeat watchdog.** Generic controllers shut down every output when the VMS heartbeat (`0x1A0`, every 100 ms) goes missing. They give the VMS 30 s after power-up before that counts.
- **Control-level forcing.** The manual brake, or losing ready-to-drive, forces `:manual` from any other level; the radio brake forces `:ros` back to `:radio`. Entering `:radio` or `:ros` needs a standstill and ready-to-drive, and `:ros` is reachable only from `:radio`.
- **Gear-shift safety.** The gear manager checks speed and throttle before a shift.
- **Command freshness.** Both ROS command frames carry a sequence number incremented per ROS sample. When it stops changing, the VMS zeroes the command, whether the bridge died or its input did.

> [!CAUTION]
> OVCS is a hobby research project and is not road-certified. These mechanisms reduce risk during development; they are not a safety case, and a vehicle built on the framework inherits that status.

## Host development versus deployed

| | Host dev (`./ovcs run <vehicle>`) | Deployed Nerves |
|---|---|---|
| BEAMs | Several on one machine, one per firmware role | One per physical device |
| Node names | `<vehicle>-<role>@<host>` (short names) | `nerves@<vehicle>-<role>.local` (long names); underscores become dashes in both, e.g. `ovcs-mini-vms` |
| Distribution started by | `./ovcs run`: `--sname`, cookie from `~/.erlang.cookie` | `OvcsBus.Distribution` at runtime; cookie `ovcs` from the release |
| Transport | Erlang distribution over loopback | Erlang distribution over the vehicle LAN, `.local` names resolved through mdns_lite's DNS bridge |
| CAN interfaces | Virtual (`vcan0`, `vcan1`, …), provisioned by `./ovcs can setup` | Real SPI/CAN hardware, set up by Cantastic at boot |
| `VEHICLE` | Set by the CLI for each BEAM | Baked into the release at build time |

## Where next

- [Framework and vehicles](./framework.md): what the framework provides and what a vehicle supplies.
- [Your vehicle package](./vehicle_package.md): how `VEHICLE` selects a vehicle and what each firmware boots.
- [Hardware](./hardware.md): the boards the framework targets, with OVCS1's five buses as a worked example.
- [Repository layout](./repository.md): the monorepo, its libraries, and where each component is documented.
