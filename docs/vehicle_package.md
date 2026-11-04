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
| A top-level module (`OvcsVehicle`): name, composer pointers, CAN config app, Nerves targets, bridge firmware map, optional geometry | The firmware shells that boot and read that module: `vms/firmware`, `infotainment/firmware`, `vision/firmware`, `bridges/firmware` |
| A VMS composer (`VmsCore.Vehicle`): which component drivers run, the CAN topology, dashboard pages, controller pinouts | `vms_core` with the component drivers, managers, metrics, and the dashboard API |
| An optional infotainment composer (`InfotainmentCore.Vehicle`): head-unit pages and CAN topology | `infotainment_core`, its API, and the Flutter dashboard |
| Optional bridge firmware entries: which bridge libraries to bundle, on which Pi, with which CAN mapping | The bridge libraries (`RadioControlBridge`, `RosBridge`) and `OvcsBridge.Supervisor` |
| An optional vision composer (`VisionCore.Composer`): cameras, calibration, stereo tuning and an optional detector, for a vision unit on a Raspberry Pi 5 or an OKdo Nano C100 ([Vision unit](./vision/README.md)) | `vision_core`, its API and dashboard, and the Rust Ports for capture, stereo matching, JPEG and detection |
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
- an example in the top-level module's `@moduledoc` for the optional `geometry/0`;
- unless `--no-bridges` is passed, two bridge firmwares in `bridge_firmwares/0` with no components yet, `radio_control` on `ovcs_base_can_system_rpi3a` and `ros` on `ovcs_base_can_system_rpi4`, with their `priv/can/bridges/*.yml`;
- the CAN topology YAMLs and an `.env.exs.example`;
- `priv/firmware/vms/` and `priv/firmware/infotainment/` holding `config.txt`, `cmdline-a.txt` and `cmdline-b.txt` copied from each target's defaults. `fwup.conf` is not copied: it stays shared with the target (see [Toolchain and OTP](./toolchain_and_otp.md#what-the-ab-layout-requires)).

The name must map back to itself through the module name, since the firmware finds the directory with `Macro.underscore/1`: `my_car` becomes `MyCar` and back, but `car_2` would be looked for as `car2`, so `ovcs new` refuses it and suggests the name that works. `--no-infotainment` and `--no-bridges` trim the template; `--display-name` sets the human-readable name, which may not contain `"`, `\` or `#{` since it is written into Elixir strings. Drop the components you don't need, add the ones your hardware needs, fill in the CAN YAMLs under `priv/can/`, then boot it like any vehicle:

```sh
./ovcs run my_car            # every firmware of your vehicle on virtual CAN
./ovcs build my_car vms      # the VMS firmware image for your Nerves target
```

> [!TIP]
> `./ovcs vehicles` lists every discovered vehicle with its Nerves targets; `./ovcs doctor` checks each package's metadata. Run both after scaffolding.

## The five behaviours

| Behaviour | Where | What it is |
|---|---|---|
| `OvcsVehicle` | `libraries/ovcs_vehicle/lib/ovcs_vehicle.ex` | Top-level vehicle module: name, composer pointers, Nerves targets, bridge firmware map. Every `vehicles/<name>/lib/<name>.ex` implements it. |
| `VmsCore.Vehicle` | `vms/core/lib/vms_core/vehicle.ex` | VMS composer: `children/0`, CAN config (`can_config_otp_app/0`, `can_config_path/0`, `default_can_mapping/1`), optional `dashboard_configuration/0` and `generic_controllers/0`. Implemented by `<Vehicle>.Vms.Composer`. |
| `InfotainmentCore.Vehicle` | `infotainment/core/lib/infotainment_core/vehicle.ex` | Infotainment composer: `children/0`, CAN config, optional `infotainment_configuration/0`. Implemented by `<Vehicle>.Infotainment.Composer`. |
| `VisionCore.Composer` | `vision/core/lib/vision_core/composer.ex` | Vision composer (optional): `config/1` returning a `VisionCore.Config` per arm, optional `required_files/0`. Implemented by `<Vehicle>.Vision.Composer`. See [Vision unit](#vision-unit). |
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
  priv/firmware/{vms,infotainment,vision,bridges/<id>}/   boot overrides: config.txt + cmdline-a/b.txt, optional fwup.conf
```

A vehicle with a ROS compute node or a simulator model adds three directories beside `lib/`, outside `priv/` because no firmware reads them. The OVCS Mini reference vehicle has all three:

```text
vehicles/ovcs_mini/
  nav2/                          nav2.yaml + behaviour trees: baked into the compute node, mounted by the local stacks
  description/                   the xacro model, its meshes and simulation.yaml, and the URDF expanded from them
  foxglove/                      Foxglove layouts for the vehicle's topics
```

`./ovcs compute push <vehicle> <fleet>` deploys the compute node with your vehicle's `nav2/`, its expanded `description/<vehicle>.urdf` and its meshes; `OVCS_VEHICLE=<vehicle>` in `compose/local/.env` selects it for the local stacks. `mise run urdf` expands the URDF; the model names its meshes under a `mesh_uri` xacro argument, which the framework sets to `package://ovcs_description/meshes`, the scheme Foxglove fetches through `foxglove_bridge`. See [`compose/README.md`](../compose/README.md#what-comes-from-your-vehicle).

### Why the vehicle depends on the firmwares

`vehicles/<name>/mix.exs` lists `vms_firmware`, `infotainment_firmware` (when the vehicle has an infotainment side), `vision_firmware` (when it has a vision unit) and `bridge_firmware` (when it declares bridges) as path dependencies:

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
3. **`Application.start/2`** of the core (`VmsCore.Application` or `InfotainmentCore.Application`) reads `:*_core, :vehicle`, calls `composer.children/0`, and supervises the result under its root supervisor. It also supervises `OvcsBus.Cluster`, which connects this BEAM to its siblings. `VisionCore.Application` reads `:vision_core, :vehicle` the same way, but its composer returns a `VisionCore.Config` rather than children; see [Vision unit](./vision/README.md).

Bridges follow the same pattern with `OvcsBridge.Supervisor` in place of a core application; the entry it reads is `vehicle.bridge_firmwares()[bridge_firmware_id]`.

## What a composer contributes

The VMS composer, `<Vehicle>.Vms.Composer`, returns:

- `children/0`: a flat list of child specs, the component drivers your vehicle uses (inverter, BMS, brake booster, steering column, …) plus any vehicle-specific GenServers. The drivers live in `vms_core`; the composer picks and configures them.
- `can_config_otp_app/0` and `can_config_path/0`: where Cantastic loads the vehicle's VMS topology YAML.
- `default_can_mapping(:host | :target)`: network name to interface, for host vcan versus deployed SPI.
- `dashboard_configuration/0` and `generic_controllers/0`, both optional: dashboard pages and controller pinout maps.

The infotainment composer has the same shape, with `infotainment_configuration/0` for the UI layout.

## Bridge firmwares

A bridge firmware is the Nerves image that hosts your vehicle's extensions next to the `ovcs` bus: bridges such as `RadioControlBridge` and `RosBridge`, and any other child. Your vehicle declares them in the optional `bridge_firmwares/0` callback, one entry per image, each addressed on the CLI as `bridge-<id>`; each bundled bridge reads its configuration from a callback on your vehicle module (see [The five behaviours](#the-five-behaviours)). [Bridge firmwares](./bridges/README.md#bridge-firmwares) covers the entry's keys, the targets and the boot sequence.

## Vision unit

A vehicle with stereo cameras adds two optional callbacks to its top-level module: `vision/0` returns its `VisionCore.Composer`, and `vision_target/0` names the board, `:rpi5` or `:okdo_c100`. The role is addressed as `vision` (`./ovcs build my_car vision`) and its boot files go in `priv/firmware/vision/`. [Opting in](./vision/README.md#opting-in) covers the composer, its configuration arms and its required files.

## Bus wiring and node names

Every firmware image runs `OvcsBus` (a thin `Phoenix.PubSub` wrapper) and `OvcsBus.Cluster`, which calls `Node.connect/1` against each declared peer on a retry loop until the BEAMs form a distributed Erlang mesh. `OvcsBus.broadcast/2` delivers only on its own node: a send across the mesh would make the publishing component wait whenever a link is busy. Components on different boards coordinate over CAN.

Peer node names come from the vehicle module's declared roles plus the naming convention parsed from `Node.self()`:

| Environment | Node name | Peers differ by |
|---|---|---|
| Host dev | `<vehicle>-<role>@<host>`, every underscore a dash (`ovcs-mini-bridge-radio-control@<host>`) | sname; all share `<host>` |
| Deployed Nerves | `nerves@<vehicle>-<role>.local`, likewise dashed (`nerves@ovcs-mini-bridge-radio-control.local`) | hostname; all share the sname `nerves` and the `.local` domain |

On the host, `./ovcs run` names each BEAM with `--sname`. A deployed firmware boots unnamed; `OvcsBus.Distribution` starts distribution on the first cluster tick with long names, after `epmd -daemon`, on the hostname erlinit set from `hostname_pattern`. Peers resolve each other's `.local` names through mdns_lite's DNS bridge, which each firmware's target config enables and puts first in VintageNet's `additional_name_servers`.

Every firmware release sets the cookie `ovcs` in its `mix.exs`, handed to the VM by `-setcookie` in `rel/vm.args.eex`. On the host, `./ovcs run` and `./ovcs attach` use your `~/.erlang.cookie` instead, which the CLI creates with a random value if it is missing.

## Control levels

Who commands the vehicle, the pedals, the radio transmitter or a ROS node, is the VMS's decision: `VmsCore.Managers.ControlLevel` makes it from the switches and source maps your VMS composer configures. [Control levels](./vms/how_it_works.md#control-levels) covers the two switches, the channel layout, the `requested_*_sources` maps and how to drive them on the host bench.

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
- [OVCS Mini](../vehicles/ovcs_mini/README.md): an `ovcs` bus plus a `misc` bus for the VESC, no infotainment side, two bridges (radio control, ROS) and a vision unit.
- [OBD2](../vehicles/obd2/README.md): no drivetrain and no bridges. VMS and infotainment only, for diagnostics.

## Further reading

- [`libraries/ovcs_vehicle/README.md`](../libraries/ovcs_vehicle/README.md): the `OvcsVehicle` behaviour and `ovcs new`.
- [`libraries/ovcs_bus/README.md`](../libraries/ovcs_bus/README.md): the `OvcsBus` API and its Erlang-distribution transport.
- [VMS](./vms/README.md): the core / API / firmware / dashboard split.
- [Running on hardware](./running_hardware.md): build, burn and upload flows.
