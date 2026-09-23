---
title: Your application package
description: The OvcsVehicle contract, how VEHICLE selects your package, what each firmware boots, control levels, and the ovcs new scaffold.
---

OVCS is a framework; the vehicle you build on it is an **application**: a package under `vehicles/<name>/` that the framework loads at boot. This guide covers what an application provides, how to scaffold one, how `VEHICLE` selects it, what each firmware does with it at boot, how the BEAMs find each other, and who is allowed to command the vehicle. Read it before creating an application or touching any firmware's `config/`.

> [!NOTE]
> The framework contains no vehicle-specific code. OVCS1, OVCS Mini and OBD2 are the three **reference applications** in the repository: worked examples of the contract on this page. Your application needs none of them. See [Framework and applications](https://ovcs.be/docs/framework).

## What an application is

A standalone Mix package whose top-level module implements the `OvcsVehicle` behaviour. It is **metadata and composers only**: no `Application` module, nothing runnable on its own. Firmware BEAMs load it through `Code.prepend_path` at boot and ask it what to supervise.

| The application provides | The framework provides |
|---|---|
| A top-level module (`OvcsVehicle`): name, composer pointers, Nerves targets, bridge firmware map | The firmware shells that boot and read that module: `vms/firmware`, `infotainment/firmware`, `bridges/firmware` |
| A VMS composer (`VmsCore.Vehicle`): which component drivers run, the CAN topology, dashboard pages, controller pinouts | `vms_core` with the component drivers, managers, metrics, and the dashboard API |
| An optional infotainment composer (`InfotainmentCore.Vehicle`): head-unit pages and CAN topology | `infotainment_core`, its API, and the Flutter dashboard |
| Optional bridge firmware entries: which bridge libraries to bundle, on which Pi, with which CAN mapping | The bridge libraries (`RadioControlBridge`, `RosBridge`) and `OvcsBridge.Supervisor` |
| CAN YAMLs under `priv/can/` that import shared frame specs | `ovcs_can` frame specifications and Cantastic |
| `.env.exs` with SSH keys, Wi-Fi networks and secrets; SSH host keys | The `ovcs` CLI that builds, burns, uploads and runs any application |

Everything is driven by **one environment variable**, `VEHICLE`, set to the application's top-level module name: `Ovcs1`, `OvcsMini` or `Obd2` for the reference applications, whatever `./ovcs new` generated for yours. Bridge firmwares also read `BRIDGE_FIRMWARE_ID` to pick one entry from the application's `bridge_firmwares/0` map.

## Start from the scaffold

Don't copy a reference application. Generate a clean package:

```sh
./ovcs new my_car --vms-target ovcs_base_can_system_rpi4 --infotainment-target ovcs_base_can_system_rpi5
```

This runs `OvcsVehicle.Scaffold.generate/3` against `libraries/ovcs_vehicle/priv/templates/vehicle/` and produces a working VMS plus infotainment application with:

- a minimal `children/0`: one example generic controller and a vehicle GenServer;
- a commented-out `bridge_firmwares/0` stub;
- the CAN topology YAMLs, firmware override directories, and an `.env.exs.example`.

`--no-infotainment` and `--no-bridges` trim the template; `--display-name` sets the human-readable name. Drop the components you don't need, add the ones your hardware needs, fill in the CAN YAMLs under `priv/can/`, then boot it like any application:

```sh
./ovcs run my_car            # every firmware of your application on virtual CAN
./ovcs build my_car vms      # the VMS firmware image for your Nerves target
```

> [!TIP]
> `./ovcs vehicles` lists every discovered application with its Nerves targets; `./ovcs doctor` checks each package's metadata. Run both after scaffolding.

## The four behaviours

| Behaviour | Where | What it is |
|---|---|---|
| `OvcsVehicle` | `libraries/ovcs_vehicle/lib/ovcs_vehicle.ex` | Top-level application module: name, composer pointers, Nerves targets, bridge firmware map. Every `vehicles/<name>/lib/<name>.ex` implements it. |
| `VmsCore.Vehicle` | `vms/core/lib/vms_core/vehicle.ex` | VMS composer: `children/0`, CAN config (`can_config_otp_app/0`, `can_config_path/0`, `default_can_mapping/1`), optional `dashboard_configuration/0` and `generic_controllers/0`. Implemented by `<App>.Vms.Composer`. |
| `InfotainmentCore.Vehicle` | `infotainment/core/lib/infotainment_core/vehicle.ex` | Infotainment composer: `children/0`, CAN config, optional `infotainment_configuration/0`. Implemented by `<App>.Infotainment.Composer`. |
| `OvcsBridge` | `libraries/ovcs_bridge/lib/ovcs_bridge.ex` | One per bridge **library** in the framework, not per application: `children/0`. Applications pick which bridges to bundle via `bridge_firmwares/0`. |

## Package layout

The OVCS1 reference application, as an example of the shape every application has:

```text
vehicles/ovcs1/
  mix.exs                        firmware path deps (see below)
  lib/ovcs1.ex                   implements OvcsVehicle
  lib/ovcs1/vms.ex               VMS-side GenServer (application-specific state)
  lib/ovcs1/vms/composer.ex      implements VmsCore.Vehicle
  lib/ovcs1/vms/composer/        dashboard pages, generic controllers
  lib/ovcs1/infotainment.ex      infotainment-side GenServer (optional)
  lib/ovcs1/infotainment/composer.ex
  lib/ovcs1/infotainment/composer/
  priv/can/vms.yml               Cantastic topology for the VMS side
  priv/can/infotainment.yml      Cantastic topology for the infotainment side
  priv/can/generic_controller/   per-controller CAN YAMLs
  priv/can/bridges/<id>.yml      per-bridge YAMLs, one per bridge_firmwares entry
  priv/firmware/{vms,infotainment,bridges}/   per-side firmware overrides (fwup.conf, …)
```

### Why the application depends on the firmwares

`vehicles/<name>/mix.exs` lists `vms_firmware`, `infotainment_firmware` (when the application has an infotainment side) and `bridge_firmware` (when it declares bridges) as path dependencies:

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

This is the entry point for `./ovcs run <app>`: one `mix compile` in the application directory builds every firmware project into `vehicles/<name>/_build/dev/lib/`, so each spawned BEAM is self-contained against that tree. The firmware projects never depend on an application; the dependency points one way, which keeps the framework vehicle-agnostic.

## Boot flow

Each firmware's `config.exs` and `runtime.exs` run in Mix's standard order:

1. **`config/config.exs`**, at compile time and again at each `mix run`, so host development picks up the current environment. Selects Nerves targets, `fwup.conf` overlays, application override directories and, for bridges, the `:ovcs_bridge, :vehicle` and `:firmware_id` application env.
2. **`config/runtime.exs`**, at every boot. The application-specific wiring happens here:

   ```elixir
   case OvcsVehicle.Firmware.resolve_side(
          :vms,
          __DIR__,
          config_env(),
          Application.compile_env(:vms_firmware, :vehicle)
        ) do
     nil ->
       :ok

     {vehicle, vms} ->
       config :vms_core, :vehicle, vms
       config :ovcs_vehicle, :module, vehicle
       config :cantastic, ...
   end
   ```

   `OvcsVehicle.Firmware.resolve_side/4` reads `VEHICLE`, prepends the application's `_build/<env>/lib/<name>/ebin` to the code path, and returns `{vehicle, composer}` for that side, or `nil` without `VEHICLE` or under `MIX_ENV=test`.
3. **`Application.start/2`** of the core (`VmsCore.Application` or `InfotainmentCore.Application`) reads `:*_core, :vehicle`, calls `composer.children/0`, and supervises the result under its root supervisor. It also supervises `OvcsBus.Cluster`, which connects this BEAM to its siblings.

Bridges follow the same pattern with `OvcsBridge.Supervisor` in place of a core application; the entry it reads is `vehicle.bridge_firmwares()[bridge_firmware_id]`.

## What a composer contributes

The VMS composer, `<App>.Vms.Composer`, returns:

- `children/0`: a flat list of child specs, the component drivers your vehicle uses (inverter, BMS, brake booster, steering column, …) plus any application-specific GenServers. The drivers live in `vms_core`; the composer picks and configures them.
- `can_config_otp_app/0` and `can_config_path/0`: where Cantastic loads the application's VMS topology YAML.
- `default_can_mapping(:host | :target)`: network name to interface, for host vcan versus deployed SPI.
- `dashboard_configuration/0` and `generic_controllers/0`, both optional: dashboard pages and controller pinout maps.

The infotainment composer has the same shape, with `infotainment_configuration/0` for the UI layout.

## Bridge firmwares

An application declares its bridge images in the optional `bridge_firmwares/0` callback. From the OVCS1 reference application:

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

Each key becomes a CLI role with the `bridge-` prefix:

```sh
./ovcs build ovcs1 bridge-radio_control
./ovcs build my_car bridge-<id>
```

The shared `bridges/firmware` image is built once per entry. At boot, `OvcsBridge.Supervisor` reads `VEHICLE` and `BRIDGE_FIRMWARE_ID`, looks up the entry, and supervises each listed bridge's `children/0`.

> [!NOTE]
> A bare id such as `radio_control` is rejected, and the error lists the valid roles for that application. The prefix is what tells `build`, `burn` and `upload` to target the bridge image.

## Bus wiring and node names

Every firmware image runs `OvcsBus` (a thin `Phoenix.PubSub` wrapper) and `OvcsBus.Cluster`, which calls `Node.connect/1` against each declared peer on a retry loop until the BEAMs form a distributed Erlang mesh. From then on `OvcsBus.broadcast/2` reaches subscribers on every node. No broker, no relay.

Peer node names come from the application module's declared roles plus the naming convention parsed from `Node.self()`:

| Environment | Node name | Peers differ by |
|---|---|---|
| Host dev | `<app>-<role>@<host>` | sname; all share `<host>` |
| Deployed Nerves | `nerves@<app>-<role>` | mDNS hostname; all share the sname `nerves` |

All releases share `--cookie ovcs`, so nothing beyond what `nerves_pack` provides for `./ovcs attach` is needed.

## Control levels: who commands, and which ROS node

`VmsCore.Managers.ControlLevel` arbitrates between commanders. It reads two independent switches on the radio transmitter, because authority and autonomy are different questions:

| Component | Values | Answers |
|---|---|---|
| `OVCS.RadioControl.RequestedControlLevel` | `:manual` / `:radio` / `:ros` | who has authority |
| `OVCS.RadioControl.RequestedRosCommander` | `:teleop` / `:autonomous` | which ROS node, when ROS does |

`:ros` means the vehicle takes its commands from the ROS bridge, **not** that it drives itself: a human on a gamepad and a planner reach the VMS over the same topics and CAN frames. The commander switch says which of them has the wheel.

Both switches only *request*. The manager refuses unsafe moves: in motion, not ready to drive, or while a fault has forced a lower level. `:ros` is reachable only from `:radio`, so getting there takes two deliberate throws with the middle position in between. A refused request is logged once, with the reason.

### Channel layout

Which transmitter channel each component reads is an application decision. The radio control bridge copies the receiver's channels 1 to 8 onto `0x2A0` and `0x2A1` unchanged, and each composer names the channel every component reads. The two reference applications with radio control use:

| Purpose | OVCS Mini | OVCS1 |
|---|---|---|
| Steering | 1 | 1 |
| Throttle (and `radio_breaking`, the human takeover) | 2 | 2 |
| Control level | 6 | 3 |
| Direction (the reverse button, through `Managers.Gear`) | 7 | 4 |
| ROS commander | 5 | not wired |

Switch positions are 1000, 1500 and 2000 µs with a margin of 100. A position outside every margin falls back to the safe one: `:manual` for the level, `:teleop` for the commander, `:forward` for direction.

The Mini's link is ExpressLRS in MAVLink mode, which forces Hybrid switch mode. Channel 5 is the link's arm channel and only carries 1000 or 2000; channels 6 to 8 are 3-position and reach the bus. Hence the three-position level on 6 and the two-position commander on 5.

### Source maps

Each `requested_*_sources` map in a composer is keyed by level; the `:ros` entry is itself keyed by commander:

```elixir
requested_throttle_sources: %{
  manual: OVCS.ThrottlePedal,
  radio: OVCS.RadioControl.Throttle,
  ros: %{teleop: OVCS.RosActuatorCommand.Throttle, autonomous: OVCS.RosVelocityCommand}
}
```

A hand's throttle usually goes through an `OVCS.InputCurve` first, and the map names the curve: dead zone and expo belong to the hand, one curve per hand, while the actuator only applies its caps. In the OVCS Mini reference application:

```elixir
{OVCS.InputCurve,
 %{
   process_name: Vms.RadioThrottleInputCurve,
   throttle_source: OVCS.RadioControl.Throttle,
   deadzone: @throttle_deadzone,
   expo: @throttle_expo
 }},
...
requested_throttle_sources: %{
  manual: nil,
  radio: Vms.RadioThrottleInputCurve,
  ros: %{teleop: Vms.TeleopThrottleInputCurve, autonomous: OVCS.RosVelocityCommand}
},
radio_breaking_source: OVCS.RadioControl.Throttle
```

A velocity is a physical quantity and is named directly, as is the takeover: `radio_breaking` reads the raw trigger. A hand wired to an actuator without a curve gets no dead zone, and a trigger that drifts at rest creeps the vehicle.

A missing key resolves to `nil`: nothing commands that actuator. That is the safe direction, and it is how an application without a planner is expressed: `ros: %{teleop: ...}` leaves the autonomous position commanding nothing. Such an application also omits `requested_ros_commander_source`, which pins the commander to `:teleop`.

### Driving on the host bench

On the host there is no radio receiver and no controller. The level starts at `default_control_level` (`:manual` in the OVCS Mini reference application, where every source is `nil`); nothing emits `0x2A0`/`0x2A1`, and nothing emits the pulse counter frame `0x709`. Without that frame the speed is unknown, and the manager refuses every mode change with `:speed_unknown`. A bench session synthesises both.

First the speed, as a stream in its own terminal: the frame watcher needs several on-time frames to declare `0x709` alive and drops it as soon as they stop. A count and frequency of zero is a stationary vehicle:

```sh
cangen vcan0 -I 709 -L 4 -D 00000000 -g 10
```

Then the switches, in the Mini's channel layout. `0x2A0` carries channels 1 to 4 as little-endian `uint16`, two bytes each; `0x2A1` carries 5 to 8. 1500 is `DC05`, 2000 is `D007`, 1000 is `E803`:

```sh
# Steering and throttle centred (channels 1 and 2)
cansend vcan0 2A0#DC05DC0500000000

# Level -> :radio (channel 6 = 1500; channel 5 = 1000 keeps :teleop)
cansend vcan0 2A1#E803DC0500000000

# Level -> :ros (channel 6 = 2000). Two steps, in this order.
cansend vcan0 2A1#E803D00700000000

# Optional: hand it to the planner (channel 5 = 2000). Needs a standstill.
cansend vcan0 2A1#D007D00700000000
```

Channels 7 and 8 read as 0 here, outside every margin, so they take the safe fallback. `ready_to_drive` is hardcoded `true` in the Mini (`OvcsMini.Vms`); where it comes from contactors or an inverter, it has to be true as well. For your application, substitute the channels your composer names.

## Host development versus deployed

| | Host dev (`./ovcs run <app>`) | Deployed Nerves |
|---|---|---|
| BEAMs | Several on one machine, one per firmware role | One per physical device |
| Node names | `<app>-<role>@<host>` | `nerves@<app>-<role>.local` |
| Transport | Erlang distribution via loopback | Erlang distribution via mDNS over the vehicle LAN |
| CAN interfaces | Virtual, provisioned by `./ovcs can setup` | Real SPI/CAN hardware, set up by Cantastic at boot |
| `VEHICLE` | Set by the CLI when spawning each BEAM | Baked into the release at build time |

`OvcsBus.Cluster.peers_for/1` handles the naming split; composers don't care which mode they run in.

## Learn from the reference applications

Each demonstrates a different shape. Copy the patterns, not the packages.

- [OVCS1](../vehicles/ovcs1/README.md): every side at once. VMS, infotainment, radio-control and ROS bridges, five isolated CAN buses meeting in the VMS.
- [OVCS Mini](../vehicles/ovcs_mini/README.md): a single `ovcs` bus, no infotainment side, three bridges (radio control, ROS, perception).
- [OBD2](../vehicles/obd2/README.md): no drivetrain and no bridges. VMS and infotainment only, for diagnostics.

## Further reading

- [`libraries/ovcs_vehicle/README.md`](../libraries/ovcs_vehicle/README.md): the `OvcsVehicle` behaviour and `ovcs new`.
- [`libraries/ovcs_bus/README.md`](../libraries/ovcs_bus/README.md): relay design, echo avoidance, runtime config.
- [Applications](./applications.md): the core / API / firmware / dashboard split.
- [Running on hardware](./running_hardware.md): build, burn and upload flows.
