---
title: Your vehicle package
description: The OvcsVehicle contract, how VEHICLE selects your package, what each firmware boots, control levels, and the ovcs new scaffold.
---

OVCS is a framework; the **vehicle** you build on it is a package under `vehicles/<name>/` that the framework loads at boot. This guide covers what a vehicle provides, how to scaffold one, how `VEHICLE` selects it, what each firmware does with it at boot, how the BEAMs find each other, and who is allowed to command the vehicle. Read it before creating a vehicle or touching any firmware's `config/`.

> [!NOTE]
> The framework contains no vehicle-specific code. OVCS1, OVCS Mini and OBD2 are the three **reference vehicles** in the repository: worked examples of the contract on this page. Your vehicle needs none of them. See [Framework and vehicles](./framework.md).

## What a vehicle is

A standalone Mix package whose top-level module implements the `OvcsVehicle` behaviour. It is **metadata and composers only**: no `Application` module, nothing runnable on its own. Firmware BEAMs load it through `Code.prepend_path` at boot and ask it what to supervise.

| The vehicle provides | The framework provides |
|---|---|
| A top-level module (`OvcsVehicle`): name, composer pointers, CAN config app, Nerves targets, bridge firmware map, optional geometry | The firmware shells that boot and read that module: `vms/firmware`, `infotainment/firmware`, `bridges/firmware` |
| A VMS composer (`VmsCore.Vehicle`): which component drivers run, the CAN topology, dashboard pages, controller pinouts | `vms_core` with the component drivers, managers, metrics, and the dashboard API |
| An optional infotainment composer (`InfotainmentCore.Vehicle`): head-unit pages and CAN topology | `infotainment_core`, its API, and the Flutter dashboard |
| Optional bridge firmware entries: which bridge libraries to bundle, on which Pi, with which CAN mapping | The bridge libraries (`RadioControlBridge`, `RosBridge`) and `OvcsBridge.Supervisor` |
| CAN YAMLs under `priv/can/` that import shared frame specs | `ovcs_can` frame specifications and Cantastic |
| `.env.exs` with SSH keys, Wi-Fi networks and secrets; SSH host keys | The `ovcs` CLI that builds, burns, uploads and runs any vehicle |

Everything is driven by **one environment variable**, `VEHICLE`, set to the vehicle's top-level module name: `Ovcs1`, `OvcsMini` or `Obd2` for the reference vehicles, whatever `./ovcs new` generated for yours. Bridge firmwares also read `BRIDGE_FIRMWARE_ID` to pick one entry from the vehicle's `bridge_firmwares/0` map.

## Start from the scaffold

Don't copy a reference vehicle. Generate a clean package:

```sh
./ovcs new my_car --vms-target ovcs_base_can_system_rpi4 --infotainment-target ovcs_base_can_system_rpi5
```

This runs `OvcsVehicle.Scaffold.generate/3` against `libraries/ovcs_vehicle/priv/templates/vehicle/` and produces a working VMS plus infotainment vehicle with:

- a minimal `children/0`: one example generic controller (controller id `0`, frames `0x701`, `0x702`, `0x704`), `VmsCore.Status` and a vehicle GenServer;
- examples in the top-level module's `@moduledoc` for the optional `geometry/0` and `bridge_firmwares/0`, the latter with a radio-control bridge and its `radio_control_bridge_config/1`, which boots once copied in and given `priv/can/bridges/radio_control.yml`;
- the CAN topology YAMLs and an `.env.exs.example`;
- `priv/firmware/vms/` and `priv/firmware/infotainment/` holding `config.txt`, `cmdline-a.txt` and `cmdline-b.txt` copied from each target's defaults. `fwup.conf` is not copied: it stays shared with the target (see [Toolchain and OTP](./toolchain_and_otp.md#what-the-ab-layout-requires)).

`--no-infotainment` and `--no-bridges` trim the template; `--display-name` sets the human-readable name. Drop the components you don't need, add the ones your hardware needs, fill in the CAN YAMLs under `priv/can/`, then boot it like any vehicle:

```sh
./ovcs run my_car            # every firmware of your vehicle on virtual CAN
./ovcs build my_car vms      # the VMS firmware image for your Nerves target
```

> [!TIP]
> `./ovcs vehicles` lists every discovered vehicle with its Nerves targets; `./ovcs doctor` checks each package's metadata. Run both after scaffolding.

## The four behaviours

| Behaviour | Where | What it is |
|---|---|---|
| `OvcsVehicle` | `libraries/ovcs_vehicle/lib/ovcs_vehicle.ex` | Top-level vehicle module: name, composer pointers, Nerves targets, bridge firmware map. Every `vehicles/<name>/lib/<name>.ex` implements it. |
| `VmsCore.Vehicle` | `vms/core/lib/vms_core/vehicle.ex` | VMS composer: `children/0`, CAN config (`can_config_otp_app/0`, `can_config_path/0`, `default_can_mapping/1`), optional `dashboard_configuration/0` and `generic_controllers/0`. Implemented by `<Vehicle>.Vms.Composer`. |
| `InfotainmentCore.Vehicle` | `infotainment/core/lib/infotainment_core/vehicle.ex` | Infotainment composer: `children/0`, CAN config, optional `infotainment_configuration/0`. Implemented by `<Vehicle>.Infotainment.Composer`. |
| `OvcsBridge` | `libraries/ovcs_bridge/lib/ovcs_bridge.ex` | One per bridge **library** in the framework, not per vehicle: `children/0`, and an optional `apply_runtime_config/2` that `bridges/firmware`'s `runtime.exs` calls before any application starts. Vehicles pick which bridges to bundle via `bridge_firmwares/0`. |

Bridge libraries define their own config behaviour, which your vehicle module implements for each bridge it bundles. Bundling `RadioControlBridge` requires `@behaviour RadioControlBridge` and `radio_control_bridge_config/1` returning `%RadioControlBridge.Config{}`. Bundling `RosBridge` requires `@behaviour RosBridge` and `ros_bridge_config/1` (or `/2`, which also receives the `bridge_firmwares/0` entry id) returning `%RosBridge.Config{}`. The first argument is the arm, `:host` or `:target`.

## Package layout

The OVCS1 reference vehicle, as an example of the shape every vehicle has:

```text
vehicles/ovcs1/
  mix.exs                        firmware path deps (see below)
  lib/ovcs1.ex                   implements OvcsVehicle
  lib/ovcs1/vms.ex               VMS-side GenServer (vehicle-specific state)
  lib/ovcs1/vms/composer.ex      implements VmsCore.Vehicle
  lib/ovcs1/vms/composer/        dashboard pages, generic controllers
  lib/ovcs1/infotainment.ex      infotainment-side GenServer (optional)
  lib/ovcs1/infotainment/composer.ex
  lib/ovcs1/infotainment/composer/
  priv/can/vms.yml               Cantastic topology for the VMS side
  priv/can/infotainment.yml      Cantastic topology for the infotainment side
  priv/can/generic_controller/   per-controller CAN YAMLs
  priv/can/bridges/<id>.yml      per-bridge YAMLs, one per bridge_firmwares entry
  priv/firmware/{vms,infotainment,bridges/<id>}/   boot overrides: config.txt + cmdline-a/b.txt, optional fwup.conf
```

### Why the vehicle depends on the firmwares

`vehicles/<name>/mix.exs` lists `vms_firmware`, `infotainment_firmware` (when the vehicle has an infotainment side) and `bridge_firmware` (when it declares bridges) as path dependencies:

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

This is the entry point for `./ovcs run <vehicle>`: one `mix compile` in the vehicle directory builds every firmware project into `vehicles/<name>/_build/dev/lib/`, so each spawned BEAM is self-contained against that tree. The firmware projects never depend on a vehicle; the dependency points one way, which keeps the framework vehicle-agnostic.

## Boot flow

Each firmware's `config.exs` and `runtime.exs` run in Mix's standard order:

1. **`config/config.exs`**, at compile time and again at each `mix run`, so host development picks up the current environment. Selects Nerves targets, `fwup.conf` overlays, vehicle override directories and, for bridges, the `:ovcs_bridge, :vehicle` and `:firmware_id` application env.
2. **`config/runtime.exs`**, at every boot. The vehicle-specific wiring happens here:

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

   `resolve_side/4` takes the vehicle name baked in by `config.exs` (from `VEHICLE`, default `Ovcs1` on host), prepends the vehicle's ebin (`vehicles/<name>/_build/<env>/lib/<name>/ebin` on host, `<release>/lib/<name>-<vsn>/ebin` on target) and returns `{vehicle, composer}`, or `nil` under `MIX_ENV=test`.
3. **`Application.start/2`** of the core (`VmsCore.Application` or `InfotainmentCore.Application`) reads `:*_core, :vehicle`, calls `composer.children/0`, and supervises the result under its root supervisor. It also supervises `OvcsBus.Cluster`, which connects this BEAM to its siblings.

Bridges follow the same pattern with `OvcsBridge.Supervisor` in place of a core application; the entry it reads is `vehicle.bridge_firmwares()[bridge_firmware_id]`.

## What a composer contributes

The VMS composer, `<Vehicle>.Vms.Composer`, returns:

- `children/0`: a flat list of child specs, the component drivers your vehicle uses (inverter, BMS, brake booster, steering column, …) plus any vehicle-specific GenServers. The drivers live in `vms_core`; the composer picks and configures them.
- `can_config_otp_app/0` and `can_config_path/0`: where Cantastic loads the vehicle's VMS topology YAML.
- `default_can_mapping(:host | :target)`: network name to interface, for host vcan versus deployed SPI.
- `dashboard_configuration/0` and `generic_controllers/0`, both optional: dashboard pages and controller pinout maps.

The infotainment composer has the same shape, with `infotainment_configuration/0` for the UI layout.

## Bridge firmwares

A vehicle declares its bridge images in the optional `bridge_firmwares/0` callback. From the OVCS1 reference vehicle:

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

An entry can also list `required_files`, paths relative to your vehicle app, for files a bridge needs but the repository doesn't carry. The OVCS Mini's perception entry names its detection model this way (`required_files: ["priv/models/nanodet_repvgg.hef"]`, fetched by `mise run fetch-models`), and the firmware build fails when one is missing rather than producing an image that boots without it.

The shared `bridges/firmware` image is built once per entry. At boot, `OvcsBridge.Supervisor` reads `VEHICLE` and `BRIDGE_FIRMWARE_ID`, looks up the entry, and supervises each listed bridge's `children/0`.

Each bundled bridge reads its configuration from a callback on your vehicle module (see [The four behaviours](#the-four-behaviours)). From the OVCS Mini reference vehicle:

```elixir
@behaviour RadioControlBridge

@impl RadioControlBridge
def radio_control_bridge_config(:host),
  do: %RadioControlBridge.Config{components: []}

def radio_control_bridge_config(:target),
  do: %RadioControlBridge.Config{
    components: [{:mavlink_forwarder, uart_port: "ttySC0", uart_baud_rate: 460_800}]
  }
```

> [!NOTE]
> A bare id such as `radio_control` is rejected, and the error lists the valid roles for that vehicle. The prefix is what tells `build`, `burn` and `upload` to target the bridge image.

## Bus wiring and node names

Every firmware image runs `OvcsBus` (a thin `Phoenix.PubSub` wrapper) and `OvcsBus.Cluster`, which calls `Node.connect/1` against each declared peer on a retry loop until the BEAMs form a distributed Erlang mesh. With `config :ovcs_bus, cluster_broadcast: true`, `OvcsBus.broadcast/2` then reaches subscribers on every node; by default it stays local. No broker, no relay.

Peer node names come from the vehicle module's declared roles plus the naming convention parsed from `Node.self()`:

| Environment | Node name | Peers differ by |
|---|---|---|
| Host dev | `<vehicle>-<role>@<host>`, every underscore a dash (`ovcs-mini-bridge-radio-control@<host>`) | sname; all share `<host>` |
| Deployed Nerves | `nerves@<vehicle>-<role>.local`, likewise dashed (`nerves@ovcs-mini-bridge-radio-control.local`) | hostname; all share the sname `nerves` and the `.local` domain |

On the host, `./ovcs run` names each BEAM with `--sname`. A deployed firmware boots unnamed; `OvcsBus.Distribution` starts distribution on the first cluster tick with long names, after `epmd -daemon`, on the hostname erlinit set from `hostname_pattern`. Peers resolve each other's `.local` names through mdns_lite's DNS bridge, which each firmware's target config enables and puts first in VintageNet's `additional_name_servers`.

Every node uses the cookie `ovcs`: `./ovcs run` and `./ovcs attach` pass `--cookie ovcs`, and each firmware release sets `cookie: "ovcs"` in its `mix.exs`, handed to the VM by `-setcookie` in `rel/vm.args.eex`.

## Control levels: who commands, and which ROS node

`VmsCore.Managers.ControlLevel` arbitrates between commanders. It reads two independent switches on the radio transmitter, because authority and autonomy are different questions:

| Component | Values | Answers |
|---|---|---|
| `OVCS.RadioControl.RequestedControlLevel` | `:manual` / `:radio` / `:ros` | who has authority |
| `OVCS.RadioControl.RequestedRosCommander` | `:teleop` / `:autonomous` | which ROS node, when ROS does |

`:ros` means the vehicle takes its commands from the ROS bridge, **not** that it drives itself: a human on a gamepad and a planner reach the VMS over the same topics and CAN frames. The commander switch says which of them has the wheel.

Both switches only *request*. The manager refuses unsafe moves: in motion, not ready to drive, or while a fault has forced a lower level. `:ros` is reachable only from `:radio`, so getting there takes two deliberate throws with the middle position in between. A refused request is logged once, with the reason.

The radio trigger (`radio_breaking_source`) drops `:ros` to `:radio`, and so does an optional `rotation_fault_source`: a `OVCS.RotationFusion` whose sources disagree (`:cross_check_fault`) means the odometry, and every costmap cell placed with it, can no longer be trusted. Either one forces `:radio` until the switch comes back to `:radio` or below, and `:ros` is refused while it lasts. The OVCS Mini reference vehicle wires its motor rotation fusion there.

### Channel layout

Which transmitter channel each component reads is a vehicle decision. The radio control bridge copies the receiver's channels 1 to 8 onto `0x2A0` and `0x2A1` unchanged, and each composer names the channel every component reads. The two reference vehicles with radio control use:

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

A hand's throttle usually goes through an `OVCS.InputCurve` first, and the map names the curve: dead zone and expo belong to the hand, one curve per hand, while the actuator only applies its caps. In the OVCS Mini reference vehicle:

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

A missing key resolves to `nil`: nothing commands that actuator. That is the safe direction, and it is how a vehicle without a planner is expressed: `ros: %{teleop: ...}` leaves the autonomous position commanding nothing. Such a vehicle also omits `requested_ros_commander_source`, which pins the commander to `:teleop`.

### Driving on the host bench

On the host there is no radio receiver and no controller. The level starts at `default_control_level` (`:manual` in the OVCS Mini reference vehicle, where every source is `nil`); nothing emits `0x2A0`/`0x2A1`, and nothing emits the pulse counter frame `0x709`. Without that frame the speed is unknown, and the manager refuses every mode change with `:speed_unknown`. A bench session synthesises both.

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

Channels 7 and 8 read as 0 here, outside every margin, so they take the safe fallback. `ready_to_drive` is hardcoded `true` in the Mini (`OvcsMini.Vms`); where it comes from contactors or an inverter, it has to be true as well. For your vehicle, substitute the channels your composer names.

## Host development versus deployed

| | Host dev (`./ovcs run <vehicle>`) | Deployed Nerves |
|---|---|---|
| BEAMs | Several on one machine, one per firmware role | One per physical device |
| Node names | `<vehicle>-<role>@<host>` (underscores become dashes) | `nerves@<vehicle>-<role>.local` (likewise) |
| Transport | Erlang distribution via loopback | Erlang distribution over the vehicle LAN, `.local` names resolved through mdns_lite's DNS bridge |
| CAN interfaces | Virtual, provisioned by `./ovcs can setup` | Real SPI/CAN hardware, set up by Cantastic at boot |
| `VEHICLE` | Set by the CLI when spawning each BEAM | Baked into the release at build time |

`OvcsBus.Cluster.peers_for/1` handles the naming split; composers don't care which mode they run in.

## Learn from the reference vehicles

Each demonstrates a different shape. Copy the patterns, not the packages.

- [OVCS1](../vehicles/ovcs1/README.md): every side at once. VMS, infotainment, radio-control and ROS bridges, five isolated CAN buses meeting in the VMS.
- [OVCS Mini](../vehicles/ovcs_mini/README.md): an `ovcs` bus plus a `misc` bus for the VESC, no infotainment side, three bridges (radio control, ROS, perception).
- [OBD2](../vehicles/obd2/README.md): no drivetrain and no bridges. VMS and infotainment only, for diagnostics.

## Further reading

- [`libraries/ovcs_vehicle/README.md`](../libraries/ovcs_vehicle/README.md): the `OvcsVehicle` behaviour and `ovcs new`.
- [`libraries/ovcs_bus/README.md`](../libraries/ovcs_bus/README.md): the `OvcsBus` API and its Erlang-distribution transport.
- [Framework components](./components.md): the core / API / firmware / dashboard split.
- [Running on hardware](./running_hardware.md): build, burn and upload flows.
