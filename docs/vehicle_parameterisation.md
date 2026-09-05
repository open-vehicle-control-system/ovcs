# Vehicle Parameterisation

How OVCS selects which vehicle a firmware image runs and wires the
vehicle-specific supervision tree, CAN topology, and inter-firmware
bus. Read this before editing a vehicle package, adding a new vehicle,
or touching any firmware's `config/`.

## TL;DR

- Everything is driven by **one env var**, `VEHICLE`, whose value is
  the top-level module name of a vehicle package (e.g. `Ovcs1`,
  `OvcsMini`, `Obd2`). Bridges additionally need `BRIDGE_FIRMWARE_ID`
  to pick one entry from the vehicle's `bridge_firmwares/0` map.
- Each firmware loads the vehicle's compiled ebin at boot via
  `Code.prepend_path`, resolves the top-level module from `VEHICLE`,
  calls the right composer callback, and supervises whatever the
  composer returns.
- Vehicle packages live in `vehicles/<name>/`, implement the
  `OvcsVehicle` behaviour, and bundle one VMS composer + optional
  infotainment composer + optional bridge firmware entries.

## The behaviours in play

Four behaviours form the contract between firmwares and vehicles:

| Behaviour | Where | What it is |
|-----------|-------|------------|
| `OvcsVehicle` | `libraries/ovcs_vehicle/lib/ovcs_vehicle.ex` | Top-level vehicle module: name, composer pointers, Nerves targets, bridge firmware map. Every `vehicles/<name>/lib/<name>.ex` implements this. |
| `VmsCore.Vehicle` | `vms/core/lib/vms_core/vehicle.ex` | VMS composer: supervision `children/0`, CAN config (`can_config_otp_app/0` + `can_config_path/0` + `default_can_mapping/1`), optional `dashboard_configuration/0` + `generic_controllers/0`. Implemented by `<Vehicle>.Vms.Composer`. |
| `InfotainmentCore.Vehicle` | `infotainment/core/lib/infotainment_core/vehicle.ex` | Infotainment composer: supervision `children/0`, CAN config, optional `infotainment_configuration/0`. Implemented by `<Vehicle>.Infotainment.Composer`. |
| `OvcsBridge` | `libraries/ovcs_bridge/lib/ovcs_bridge.ex` | One per bridge **library** (not per vehicle): `children/0`. Vehicles pick which bridges to bundle via `bridge_firmwares/0`. |

## Vehicle package layout

```
vehicles/ovcs1/
  mix.exs                        — firmware path deps (see below)
  lib/ovcs1.ex                   — implements OvcsVehicle
  lib/ovcs1/vms.ex               — VMS-side GenServer (vehicle-specific state)
  lib/ovcs1/vms/composer.ex      — implements VmsCore.Vehicle
  lib/ovcs1/vms/composer/        — dashboard pages, generic controllers
  lib/ovcs1/infotainment.ex      — infotainment-side GenServer (optional)
  lib/ovcs1/infotainment/composer.ex
  lib/ovcs1/infotainment/composer/
  priv/can/vms.yml               — Cantastic topology for the VMS side
  priv/can/infotainment.yml      — Cantastic topology for the infotainment side
  priv/can/generic_controller/   — per-controller CAN YAMLs
  priv/can/bridges/<id>.yml      — per-bridge YAMLs (one per bridge_firmwares entry)
  priv/firmware/{vms,infotainment,bridges}/  — per-side firmware overrides (fwup.conf, …)
```

The package is **metadata + composers only**. No `Application` module,
no runnable OTP app. Firmware BEAMs reach it via `Code.prepend_path`
at boot (see [Boot flow](#boot-flow) below).

### Why the vehicle depends on firmware path deps

`vehicles/<name>/mix.exs` lists `vms_firmware`, `infotainment_firmware`
(when the vehicle has an infotainment side), and `bridge_firmware` (when
it declares bridges) as path deps:

```elixir
defp deps do
  [
    {:ovcs_vehicle, path: "../../libraries/ovcs_vehicle"},
    {:vms_firmware, path: "../../vms/firmware"},
    {:infotainment_firmware, path: "../../infotainment/firmware"},
    {:bridge_firmware, path: "../../bridges/firmware"},
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
  ]
end
```

This is the **entry point** for `./ovcs run <vehicle>` — one `mix
compile` under the vehicle directory builds every firmware project's
beams into `vehicles/<name>/_build/dev/lib/`, so each spawned BEAM
(VMS, infotainment, each bridge) is self-contained against that tree.
Firmware projects do **not** depend on the vehicle (the vehicle's
code reaches them via the ebin prepend at boot).

## Boot flow

Each firmware's `config.exs` and `runtime.exs` run in Mix's standard
order:

1. `config/config.exs` — compile-time (at `mix compile`) plus once
   again at each `mix run` so host-dev re-picks up the current env.
   Selects Nerves targets, `fwup.conf` overlays, vehicle override
   directories, and (for bridges) the `:ovcs_bridge, :vehicle` +
   `:firmware_id` app env.
2. `config/runtime.exs` — at every boot. This is where vehicle-specific
   wiring happens:

   ```elixir
   vehicle =
     OvcsVehicle.Firmware.resolve_vehicle(
       __DIR__,
       config_env(),
       Application.compile_env(:vms_firmware, :vehicle)
     )

   if vehicle && config_env() != :test do
     vms = vehicle.vms()
     config :vms_core, :vehicle, vms
     config :cantastic, ...
   end
   ```

   `OvcsVehicle.Firmware.resolve_vehicle/3` (see
   `libraries/ovcs_vehicle/lib/ovcs_vehicle/firmware.ex`) reads
   `VEHICLE`, prepends the vehicle's `_build/<env>/lib/<name>/ebin` to
   the code path, and returns the module atom.

3. `Application.start/2` of the relevant core (`VmsCore.Application`
   or `InfotainmentCore.Application`) — reads `:*_core, :vehicle` from
   app env, calls `composer.children/0`, and supervises everything
   under its root supervisor. Also supervises `OvcsBus.Cluster`
   (driven by `:ovcs_vehicle, :module`) which connects this BEAM to
   its siblings over Erlang distribution — `OvcsBus.broadcast/2`
   then reaches subscribers on every firmware in the cluster.

Bridges follow the same pattern but the supervisor is
`OvcsBridge.Supervisor` (in `libraries/ovcs_bridge/`) instead of a
core Application, and the vehicle entry it cares about comes from
`vehicle.bridge_firmwares()[bridge_firmware_id]`.

## What each composer contributes

The VMS composer (`<Vehicle>.Vms.Composer`) returns:

- `children/0` — flat list of child specs. Vehicle-specific component
  drivers (inverter, BMS, brake booster, steering column, …) + any
  per-vehicle GenServers.
- `can_config_otp_app/0` + `can_config_path/0` — tell Cantastic where
  to load this vehicle's VMS topology YAML.
- `default_can_mapping(:host | :target)` — name→interface mapping
  for host vcan vs. deployed SPI.
- `dashboard_configuration/0`, `generic_controllers/0` — dashboard
  pages and controller pinout maps (both optional).

The infotainment composer is the same shape with
`infotainment_configuration/0` for the UI layout.

## Bridge firmwares

A vehicle declares its bridge firmware images via the optional
`bridge_firmwares/0` callback on the top-level module:

```elixir
@impl OvcsVehicle
def bridge_firmwares do
  %{
    "radio_control" => %{
      target: :ovcs_base_can_system_rpi3a,
      bridges: [RadioControlBridge],
      default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"}
    },
    "ros" => %{
      target: :ovcs_base_can_system_rpi4,
      bridges: [RosBridge],
      default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"}
    }
  }
end
```

Each map key becomes a build target (`./ovcs build ovcs1
radio_control`). The shared `bridges/firmware` image is built once per
entry; `OvcsBridge.Supervisor` reads `VEHICLE` + `BRIDGE_FIRMWARE_ID`
at boot, looks up the entry, and supervises each listed bridge's
`children/0`.

## Bus wiring

Every firmware image runs `OvcsBus` (thin `Phoenix.PubSub` wrapper)
plus `OvcsBus.Cluster` — a boot-time helper that calls
`Node.connect/1` against each declared peer on a retry loop until
the vehicle's BEAMs form a distributed Erlang mesh. Once connected,
`OvcsBus.broadcast/2` fans messages out to subscribers on every
node via `Phoenix.PubSub.broadcast/3` — no MQTT broker, no relay
clients, no separate protocol.

Peer node names come from the vehicle module's declared roles plus
the local node's naming convention (parsed from `Node.self()`):

- Host dev — `<vehicle>-<role>@<host>`, peers share `<host>`.
- Deployed Nerves — `nerves@<vehicle>-<role>`, peers share the
  sname `nerves` and vary by mDNS hostname.

All firmware releases share `--cookie ovcs`, so no authentication
wiring is needed beyond what `nerves_pack` already does for the
remsh / `./ovcs attach` flow.

## Control levels: who commands, and which ROS node

`VmsCore.Managers.ControlLevel` arbitrates between commanders. It
reads two independent switches on the RC transmitter, because
authority and autonomy are different questions:

| Channel | Component | Values |
|---|---|---|
| 3 | `OVCS.RadioControl.RequestedControlLevel` | `:manual` / `:radio` / `:ros` |
| 5 | `OVCS.RadioControl.RequestedRosCommander` | `:teleop` / `:autonomous` |

`:ros` means the vehicle takes its commands from the ROS bridge. It
does **not** mean the vehicle is driving itself: a human on a gamepad
and a planner reach the VMS over the same topics and the same CAN
frames. Which of them has the wheel is channel 5's answer, and it is
why the level is named `:ros` rather than `:autonomous`.

Both switches only *request*. The manager decides, and refuses moves
that are unsafe — in motion, not ready to drive, or while a fault has
forced a lower level. `:ros` is reachable only from `:radio`, so
getting there is two deliberate throws with the middle position in
between. A request it cannot honour is logged once, with the reason.

The full channel convention, shared by every vehicle so a transmitter
set up for one reads the same way on another:

| Channel | Purpose |
|---|---|
| 1 | Steering |
| 2 | Throttle (and `radio_breaking`, the human takeover) |
| 3 | Control level |
| 4 | Direction (OVCS1; unused on Mini) |
| 5 | ROS commander |

### The source maps

Each `requested_*_sources` map in a composer is keyed by level. The
`:ros` entry is itself keyed by commander:

```elixir
requested_throttle_sources: %{
  manual: OVCS.ThrottlePedal,
  radio: OVCS.RadioControl.Throttle,
  ros: %{teleop: OVCS.ROSControl.Throttle, autonomous: OVCS.Ros2Control.Velocity}
}
```

A missing key resolves to `nil`, which means nothing commands that
actuator. That is the safe direction, and it is how a vehicle with no
planner is expressed: `ros: %{teleop: ...}` leaves the autonomous
position commanding nothing rather than falling back to something
nobody asked for. Such a vehicle also omits
`requested_ros_commander_source`, which pins the commander to
`:teleop` outright.

### Driving on the host bench

`Managers.ControlLevel` starts in `default_control_level` — `:manual`
on OVCS Mini, where every source is `nil`, so **nothing commands the
vehicle until channel 3 says otherwise**. On the host there is no RC
receiver: `radio_control_bridge_config(:host)` declares no components,
so nothing emits `0x2A1`/`0x2A0` and the level never leaves `:manual`.
Joystick input still reaches `0x2B0`/`0x2B1` and is discarded.

So a bench session needs the switches synthesised. `0x2A0` carries
channels 1-4 as little-endian `uint16`, two bytes each; `0x2A1`
carries 5-8 the same way. 1500 is `DC05`, 2000 is `D007`, 1000 is
`E803`:

```bash
# Steering and throttle centred, level -> :radio (channel 3 = 1500)
cansend vcan0 2A0#DC05DC05DC050000

# ... then level -> :ros (channel 3 = 2000). Two steps, in this order:
# :ros is only reachable from :radio.
cansend vcan0 2A0#DC05DC05D0070000

# Optional: hand it to the planner rather than the gamepad
# (channel 5 = 2000). Needs a standstill, which the host always is.
cansend vcan0 2A1#D007000000000000
```

`ready_to_drive` is hardcoded `true` on Mini (`OvcsMini.Vms`), so
nothing else is needed there. On a vehicle whose `ready_to_drive`
comes from contactors or an inverter, that has to be true as well.

## Host dev vs. deployed

Same code path, two physical topologies:

|  | Host dev (`./ovcs run <vehicle>`) | Deployed Nerves |
|---|---|---|
| BEAMs | Multiple BEAMs on one machine, one per firmware role | One BEAM per physical device |
| Node names | `<vehicle>-<role>@<host>` (sname per role) | `nerves@<vehicle>-<role>.local` (mDNS hostname per role) |
| Transport | Erlang distribution via loopback | Erlang distribution via mDNS over the vehicle LAN |
| CAN interfaces | Virtual (`vcan0`, `vcan1`, …) provisioned by `./ovcs can setup` | Real SPI/CAN hardware; Cantastic sets it up at boot |
| `VEHICLE` env | Set by the CLI when spawning each BEAM | Baked into the release via config.exs at build time |

`OvcsBus.Cluster.peers_for/1` handles the naming split internally —
composers don't care which mode they're in.

## Scaffolding a new vehicle

```
./ovcs new my_car --vms-target ovcs_base_can_system_rpi4 --infotainment-target ovcs_base_can_system_rpi5
```

runs `OvcsVehicle.Scaffold.generate/3` against the template at
`libraries/ovcs_vehicle/priv/templates/vehicle/`. The template
produces a working VMS + infotainment vehicle with:

- A minimal `children/0` (one example generic controller + a vehicle
  GenServer).
- A commented-out `bridge_firmwares/0` stub ready to uncomment.

Drop components you don't need, add the ones you do, fill in the CAN
YAMLs under `priv/can/`, and `./ovcs run <my_car>` should boot
end-to-end.

## Further reading

- [`libraries/ovcs_vehicle/README.md`](../libraries/ovcs_vehicle/README.md)
  — details on the `OvcsVehicle` behaviour and `ovcs new`.
- [`libraries/ovcs_bus/README.md`](../libraries/ovcs_bus/README.md) —
  relay/broker design, echo avoidance, runtime config.
- [Applications](./applications.md) — the wider layer split (core /
  api / firmware / dashboard).
- [Running on Hardware](./running_hardware.md) — build/burn/upload
  flows on the CLI and what each env var does.
