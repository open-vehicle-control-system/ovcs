---
title: Architecture
description: Bus isolation, vehicle-agnostic cores, the application contract, and the Erlang mesh that ties every firmware together.
---

OVCS is a framework for vehicle embedded systems. It makes components from different manufacturers work together in whatever vehicle you build on it. Two ideas shape everything else: each manufacturer's CAN bus stays isolated, and everything vehicle-specific lives in a separate package, an *application*, that the firmware loads at boot.

> [!NOTE]
> Everything here holds for any application. OVCS1, OVCS Mini and OBD2 appear only as worked examples. See [Framework and applications](./framework.md).

## Two ideas

### Bus isolation

Components from different manufacturers use overlapping CAN identifiers. A Nissan Leaf inverter and a Volkswagen Polo ABS module were never meant to share a wire; on one bus their frames would collide. OVCS keeps each manufacturer's bus physically separate. The Vehicle Management System (VMS) is the only node on all of them, and bridges traffic between buses where the application needs it. In the OVCS1 reference application, that is how the Polo's original instrument cluster shows the Leaf motor's RPM.

An internal bus, `ovcs`, carries framework traffic: heartbeats, controller adoption, infotainment and bridge commands. Manufacturer buses run at the bitrate their components require. Which buses exist, and at what speed, is the application's decision; OVCS1's five-bus layout is in [Hardware](./hardware_architecture.md).

### The framework knows no vehicle

The cores (`vms_core`, `infotainment_core`), firmware shells, bridge libraries and shared libraries contain no vehicle-specific code. Every vehicle is an application: a Mix package under `vehicles/<name>/` that implements `OvcsVehicle` and bundles its supervision tree, CAN topology YAMLs and Nerves targets. `VEHICLE`, set to the package's top-level module name, selects it at boot. [Your application package](./vehicle_parameterisation.md) follows that selection through the boot sequence.

## Where the line is drawn

| Framework (vehicle-agnostic) | Application (your package) |
|---|---|
| `vms_core`: component drivers, managers, metrics, the `VmsCore.Vehicle` behaviour | `<App>.Vms.Composer` implementing it |
| `infotainment_core`: layout model, the `InfotainmentCore.Vehicle` behaviour | `<App>.Infotainment.Composer` (optional) |
| VMS and infotainment Phoenix APIs, Vue and Flutter dashboards | `children/0`: which drivers and GenServers to supervise |
| Firmware shells (`vms/firmware`, `infotainment/firmware`, `bridges/firmware`) that read `VEHICLE` | Nerves targets per role (`vms_target/0`, `infotainment_target/0`) |
| Bridge libraries (`RadioControlBridge`, `RosBridge`) and the `OvcsBridge` contract | `bridge_firmwares/0`: which bridges to build, on which target |
| Shared CAN frame specs in `ovcs_can` | CAN topology YAMLs under `priv/can/` |
| The generic controller firmware and its adoption protocol | Controller pinout maps (`generic_controllers/0`) |
| The dashboard page and block model | Pages (`dashboard_configuration/0`, `infotainment_configuration/0`) |
| `OvcsBus`, `OvcsBus.Cluster`, the `ovcs` CLI | `.env.exs`: SSH keys, Wi-Fi networks, Phoenix secrets, Zenoh endpoint |

Nothing on the left changes when you add a vehicle. Everything on the right is yours, and `./ovcs new` scaffolds a starting point.

## The roles

A running application is a small fleet of BEAMs:

- **VMS**: the only firmware on the vehicle CAN buses, so all isolation between manufacturers happens there. Raspberry Pi 4 with a multi-CAN SPI hub.
- **Infotainment** (optional): the in-car touchscreen on a Raspberry Pi 5, on the `ovcs` bus only.
- **Bridges** (zero or more): each ferries data between the `ovcs` bus and a non-CAN world, such as an ExpressLRS radio link or a ROS 2 graph. The application declares which bridges it ships and on which target.
- **Generic controllers**: Arduino R4 Minima boards running one shared firmware. They receive their pinout from the VMS at runtime through an adoption frame. See [Generic controllers](./testing_generic_controllers.md).

The dashboards sit outside the vehicle: the Vue dashboard talks to the VMS API, the Flutter head unit to the infotainment API, both over HTTP and WebSocket. Both render the pages the application's composers declare.

### One Erlang mesh, no broker

Every BEAM of a running application joins one Erlang-distribution cluster through `OvcsBus.Cluster`: at boot each node calls `Node.connect/1` on its declared peers until the mesh forms. `OvcsBus.broadcast/2` then reaches subscribers on every node via `Phoenix.PubSub`. No MQTT broker, no relay.

The transport is the same in both environments: `./ovcs run <app>` clusters one BEAM per role over loopback; a deployed application clusters one BEAM per Raspberry Pi over the vehicle LAN.

> [!NOTE]
> Nothing safety-relevant depends on the mesh. Commands from the radio link or the ROS bridge travel as CAN frames on the `ovcs` bus, where the VMS watches their freshness. The mesh carries metrics, status and coordination.

## Three layers per system

VMS and infotainment share one layered shape. Each layer is its own Mix project referencing the one below through a relative `path:` dependency; this is a monorepo, not an umbrella.

```text
+------------+     +------------+     +----------------+
|  Firmware  | --> |    API     | --> |     Core       |
| (Nerves)   |     | (Phoenix)  |     | (business      |
|            |     |            |     |  logic)        |
+------------+     +------+-----+     +--------+-------+
                          |                    |
                    +-----+------+      +------+-------+
                    |  Dashboard |      |  Cantastic   |
                    | (Vue/Dart) |      |  (CAN lib)   |
                    +------------+      +--------------+
```

- **Core**: component drivers, managers, and the `VmsCore.Vehicle` or `InfotainmentCore.Vehicle` behaviour. No web dependencies, no vehicle code.
- **API**: a Phoenix project exposing a JSON API and WebSocket channels. Depends on Core.
- **Dashboard**: Vue for the VMS debug dashboard, Flutter for the head unit.
- **Firmware**: a Nerves project packaging the API (and Core) into a bootable image. At boot it reads `VEHICLE` and loads the application.

The application sits beside these layers: the firmware reaches it through `Code.prepend_path`, and no framework project depends on it. Every Elixir project runs on a host against virtual CAN. The inventory is in [Framework components](./applications.md).

## The component pattern

Every hardware driver in `vms_core` is a GenServer with the same recipe:

1. **Subscribes to CAN frames** with `Cantastic.Receiver.subscribe/3`, receiving `{:handle_frame, %Cantastic.Frame{}}`.
2. **Subscribes to internal messages** with `OvcsBus.subscribe/1`, receiving `%OvcsBus.Message{}`.
3. **Runs a periodic loop**, typically every 10 ms, to emit CAN frames and broadcast its metrics.
4. **Exposes actions** through `trigger_action/2`, so a dashboard button can call into it.

Components never import each other. A component that needs the vehicle speed is told, in the init configuration the composer gives it, which module publishes it, and matches on `source`:

```elixir
alias OvcsBus, as: Bus

# Broadcasting a metric
Bus.broadcast("messages", %Bus.Message{
  name: :speed,
  value: 45.2,
  source: VmsCore.Components.Volkswagen.Polo9N.ABS
})

# Receiving it in another component
def handle_info(%Bus.Message{name: :speed, value: speed, source: source}, state)
    when source == state.abs_source do
  {:noreply, %{state | speed: speed}}
end
```

The broadcast is cluster-wide, so a subscriber in a bridge BEAM on another Pi receives it too. The framework ships drivers for the components its reference applications use (Leaf inverter, Bosch iBooster, Orion BMS, Polo body modules, VESC motor controller, Traxxas steering, …); your application picks the ones it needs and adds its own the same way.

### Managers

Managers hold framework logic spanning several components:

- `Managers.ControlLevel` arbitrates between commanders. It reads the requested control level (`:manual`, `:radio`, `:ros`) and, under `:ros`, the requested commander (`:teleop`, `:autonomous`), routes throttle, steering and direction from the sources the composer maps to each level, and refuses unsafe moves. Details in [Your application package](./vehicle_parameterisation.md#control-levels-who-commands-and-which-ros-node).
- `Managers.Gear` turns the requested direction into a gear and enforces shift constraints.

## The VMS supervision tree

```text
VmsCore.Application                          (framework)
├── VmsCore.Repo               SQLite: throttle calibration and other persisted data
├── Ecto.Migrator              applies pending migrations on boot
├── VmsCore.Metrics            aggregates every bus message for the dashboard and API
├── VmsCore.NetworkInterfaces  CAN interface statistics (errors, bus state)
├── OvcsBus.Cluster            connects this BEAM to the application's other firmwares
└── composer children          (your package, selected by VEHICLE)
    ├── VmsCore.Status         VMS heartbeat (0x1A0), ready-to-drive, controller reset (0x1AA)
    ├── Components             hardware drivers (inverter, BMS, brakes, body, …)
    ├── Managers               control level, gear
    └── Generic controllers    Arduino I/O drivers
```

`OvcsBus`'s `Phoenix.PubSub` runs in its own OTP application, `:ovcs_bus`, so every BEAM that depends on the library reaches it by name.

## Safety mechanisms in the framework

Every application gets these without writing them:

- **HV contactor precharge.** Negative, then precharge, wait for the voltages to equalise, then positive, then drop precharge. Prevents inrush damage.
- **VMS heartbeat watchdog.** Generic controllers shut down every output when the VMS heartbeat (`0x1A0`, every 100 ms) goes missing. They give the VMS 30 s after power-up before that counts.
- **Control-level forcing.** The manual brake forces `:manual` from any other level; the radio brake forces `:ros` back to `:radio`. Mode changes need a standstill and ready-to-drive.
- **Gear-shift safety.** The gear manager checks speed and throttle before a shift.
- **Command freshness.** Both ROS command frames carry a sequence number incremented per ROS sample. When it stops changing, the VMS zeroes the command, whether the bridge died or its input did.

> [!CAUTION]
> OVCS is a hobby research project and is not road-certified. These mechanisms reduce risk during development; they are not a safety case, and an application built on the framework inherits that status.

## Host development versus deployed

| | Host dev (`./ovcs run <app>`) | Deployed Nerves |
|---|---|---|
| BEAMs | Several on one machine, one per firmware role | One per physical device |
| Node names | `<app>-<role>@<host>` | `nerves@<app>-<role>` (underscores become dashes in hostnames) |
| Transport | Erlang distribution over loopback | Erlang distribution over the vehicle LAN |
| CAN interfaces | Virtual (`vcan0`, `vcan1`, …), provisioned by `./ovcs can setup` | Real SPI/CAN hardware, set up by Cantastic at boot |
| `VEHICLE` | Set by the CLI for each BEAM | Baked into the release at build time |

## Where next

- [Framework and applications](./framework.md): what the framework provides and what an application supplies.
- [Your application package](./vehicle_parameterisation.md): how `VEHICLE` selects an application and what each firmware boots.
- [Hardware](./hardware_architecture.md): the boards the framework targets, with OVCS1's five buses as a worked example.
- [Framework components](./applications.md): every project and library in the monorepo.
