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

The cores (`vms_core`, `infotainment_core`), firmware shells, bridge libraries and shared libraries contain no vehicle-specific code. Every vehicle is a Mix package under `vehicles/<name>/` that implements `OvcsVehicle` and bundles its supervision tree, CAN topology YAMLs and Nerves targets. `VEHICLE`, set to the package's top-level module name, selects it at boot. [Your vehicle package](./vehicle_package.md) follows that selection through the boot sequence.

## Where the line is drawn

| Framework (vehicle-agnostic) | Vehicle (your package) |
|---|---|
| `vms_core`: component drivers, managers, metrics, the `VmsCore.Vehicle` behaviour | `<Vehicle>.Vms.Composer` implementing it |
| `infotainment_core`: layout model, the `InfotainmentCore.Vehicle` behaviour | `<Vehicle>.Infotainment.Composer` (optional) |
| VMS and infotainment Phoenix APIs, Vue and Flutter dashboards | `children/0`: which drivers and GenServers to supervise |
| Firmware shells (`vms/firmware`, `infotainment/firmware`, `bridges/firmware`) that read `VEHICLE` | Nerves targets per role (`vms_target/0`, `infotainment_target/0`) |
| Bridge libraries (`RadioControlBridge`, `RosBridge`) and the `OvcsBridge` contract | `bridge_firmwares/0`: which bridges to build, on which target |
| Shared CAN frame specs in `ovcs_can` | CAN topology YAMLs under `priv/can/` |
| The generic controller firmware and its adoption protocol | Controller pinout maps (`generic_controllers/0`) |
| The dashboard page and block model | Pages (`dashboard_configuration/0`, `infotainment_configuration/0`) |
| `OvcsBus`, `OvcsBus.Cluster`, the `ovcs` CLI | `.env.exs`: SSH keys, Wi-Fi networks, Phoenix secrets, Zenoh endpoint |

Nothing on the left changes when you add a vehicle. Everything on the right is yours, and `./ovcs new` scaffolds a starting point.

## The roles

A running vehicle is a small fleet of BEAMs:

- **VMS**: the only firmware on the vehicle CAN buses, so all isolation between manufacturers happens there. Raspberry Pi 4 with a multi-CAN SPI hub.
- **Infotainment** (optional): the in-car touchscreen on a Raspberry Pi 5, on the `ovcs` bus only.
- **Bridges** (zero or more): each ferries data between the `ovcs` bus and a non-CAN world, such as an ExpressLRS radio link or a ROS 2 graph. The vehicle declares which bridges it ships and on which target.
- **Generic controllers**: Arduino R4 Minima boards running one shared firmware. They receive their pinout from the VMS at runtime through an adoption frame. See [Generic controllers](./generic_controllers.md).

The Vue dashboard runs off the vehicle, on a laptop, and talks to the VMS API. The Flutter head unit runs on the infotainment Pi 5, bundled into its firmware, and talks to the infotainment API. Both use HTTP and WebSocket and render the pages the vehicle's composers declare.

### One Erlang mesh, no broker

Every BEAM of a running vehicle joins one Erlang-distribution cluster through `OvcsBus.Cluster`: at boot each node calls `Node.connect/1` on its declared peers until the mesh forms. No MQTT broker, no relay.

`OvcsBus.broadcast/2` delivers to subscribers on the local node. Set `config :ovcs_bus, cluster_broadcast: true` to have it reach every node through `Phoenix.PubSub`. It is off by default: a cluster broadcast suspends the publishing process while the link to any peer is saturated, so one slow link can stall a drivetrain component.

The transport is the same in both environments: `./ovcs run <vehicle>` clusters one BEAM per role over loopback; a deployed vehicle clusters one BEAM per Raspberry Pi over the vehicle LAN.

On the host, the CLI starts each BEAM with `--sname <vehicle>-<role> --cookie ovcs`. A Nerves release boots without a node name, so on the first `OvcsBus.Cluster` tick `OvcsBus.Distribution` runs `epmd -daemon` and starts distribution as `nerves@<vehicle>-<role>.local` with long names. The hostname part is the device hostname set by erlinit's `hostname_pattern`, which mdns_lite also advertises. Every release's cookie is `ovcs`, passed to the VM by `-setcookie` in `rel/vm.args.eex`, the same cookie `./ovcs run` and `./ovcs attach` use, so the devices authenticate each other. Starting distribution needs no IP address; a failed start is logged and retried on the next tick.

Erlang's own resolver knows nothing about mDNS. Each firmware enables mdns_lite's DNS bridge on `127.0.0.53` and lists it first in VintageNet's `additional_name_servers`, so a lookup of `<vehicle>-<role>.local` is answered from mDNS. The bridge refuses every other name, and the resolver moves on to the DHCP-supplied servers.

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
- **Firmware**: a Nerves project packaging the API (and Core) into a bootable image. At boot it reads `VEHICLE` and loads the vehicle package.

The vehicle package sits beside these layers: the firmware reaches it through `Code.prepend_path`, and no framework project depends on it. Every Elixir project runs on a host against virtual CAN. The inventory is in [Framework components](./components.md).

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
  value: Decimal.new("45.2"),
  source: VmsCore.Components.Volkswagen.Polo9N.ABS
})

# Receiving it in another component
def handle_info(%Bus.Message{name: :speed, value: speed, source: source}, state)
    when source == state.speed_source do
  {:noreply, %{state | speed: speed}}
end
```

With `:cluster_broadcast` set, a subscriber in a bridge BEAM on another Pi receives it too. The framework ships drivers for the components its reference vehicles use (Leaf inverter, Bosch iBooster, Orion BMS, Polo body modules, VESC motor controller, Traxxas steering, …); your vehicle picks the ones it needs and adds its own the same way.

### Managers

Managers hold framework logic spanning several components:

- `Managers.ControlLevel` arbitrates between commanders. It reads the requested control level (`:manual`, `:radio`, `:ros`) and, under `:ros`, the requested commander (`:teleop`, `:autonomous`), routes throttle, steering and direction from the sources the composer maps to each level, and refuses unsafe moves. Details in [Your vehicle package](./vehicle_package.md#control-levels-who-commands-and-which-ros-node).
- `Managers.Gear` turns the requested direction into a gear and enforces shift constraints.

## The VMS supervision tree

```text
VmsCore.Application                          (framework)
├── VmsCore.Repo               SQLite: throttle calibration and other persisted data
├── Ecto.Migrator              applies pending migrations on boot (skipped when RELEASE_NAME is set)
├── VmsCore.Metrics            aggregates every bus message for the dashboard and API
├── VmsCore.NetworkInterfaces  CAN interface statistics (errors, bus state)
├── OvcsBus.Cluster            connects this BEAM to the vehicle's other firmwares
└── composer children          (your package, selected by VEHICLE)
    ├── VmsCore.Status         VMS heartbeat (0x1A0), ready-to-drive, controller reset (0x1AA)
    ├── Components             hardware drivers (inverter, BMS, brakes, body, …)
    ├── Managers               control level, gear
    └── Generic controllers    Arduino I/O drivers
```

`OvcsBus`'s `Phoenix.PubSub` runs in its own OTP application, `:ovcs_bus`, so every BEAM that depends on the library reaches it by name.

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
| Distribution started by | `./ovcs run`: `--sname` and `--cookie ovcs` | `OvcsBus.Distribution` at runtime; cookie `ovcs` from the release |
| Transport | Erlang distribution over loopback | Erlang distribution over the vehicle LAN, `.local` names resolved through mdns_lite's DNS bridge |
| CAN interfaces | Virtual (`vcan0`, `vcan1`, …), provisioned by `./ovcs can setup` | Real SPI/CAN hardware, set up by Cantastic at boot |
| `VEHICLE` | Set by the CLI for each BEAM | Baked into the release at build time |

## Where next

- [Framework and vehicles](./framework.md): what the framework provides and what a vehicle supplies.
- [Your vehicle package](./vehicle_package.md): how `VEHICLE` selects a vehicle and what each firmware boots.
- [Hardware](./hardware.md): the boards the framework targets, with OVCS1's five buses as a worked example.
- [Framework components](./components.md): every project and library in the monorepo.
