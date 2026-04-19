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
| `VmsCore.Vehicle` | `vms/core/lib/vms_core/vehicle.ex` | VMS composer: supervision `children/0`, CAN config, dashboard, optional `bus_relay/0` / `bus_broker/0`. Implemented by `<Vehicle>.Vms.Composer`. |
| `InfotainmentCore.Vehicle` | `infotainment/core/lib/infotainment_core/vehicle.ex` | Infotainment composer: supervision `children/0`, CAN config, UI layout, optional `bus_relay/0`. Implemented by `<Vehicle>.Infotainment.Composer`. |
| `OvcsBridge` | `libraries/ovcs_bridge/lib/ovcs_bridge.ex` | One per bridge **library** (not per vehicle): `children/0`, optional `relay_messages/0`. Vehicles pick which bridges to bundle via `bridge_firmwares/0`. |

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
   under its root supervisor. Optional MQTT children come from
   `OvcsBus.Mqtt.broker_child_from/1` /
   `OvcsBus.Mqtt.relay_child_from/1` against the composer.

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
- `bus_broker/0` — **optional**; when present, the VMS BEAM hosts a
  Mosquitto instance for the vehicle LAN (see [Bus wiring](#bus-wiring)).
- `bus_relay/0` — **optional**; opts for the MQTT relay that mirrors
  selected bus messages to the broker.

The infotainment composer is the same shape, minus `bus_broker/0`
(only the VMS side hosts the broker) and with
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
      default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"},
      bus_relay: OvcsVehicle.Bus.relay_opts(__MODULE__, "ovcs1-bridge-radio_control")
    },
    "ros" => %{
      target: :ovcs_base_can_system_rpi4,
      bridges: [RosBridge],
      default_can_mapping: %{host: "ovcs:vcan0", target: "ovcs:spi0.0"},
      bus_relay: OvcsVehicle.Bus.relay_opts(__MODULE__, "ovcs1-bridge-ros")
    }
  }
end
```

Each map key becomes a build target (`./ovcs build ovcs1
radio_control`). The shared `bridges/firmware` image is built once per
entry; `OvcsBridge.Supervisor` reads `VEHICLE` + `BRIDGE_FIRMWARE_ID`
at boot, looks up the entry, and supervises each listed bridge's
`children/0` plus (optionally) an MQTT relay.

Bridges as libraries (`bridges/radio_control_bridge`,
`bridges/ros_bridge`) export `children/0` and optional
`relay_messages/0`. The supervisor unions `relay_messages/0` across
bundled bridges so each library travels with its own message contract
— the vehicle doesn't restate it in `bus_relay`.

## Bus wiring

Every firmware image runs a local `OvcsBus` (thin `Phoenix.PubSub`
wrapper). Cross-firmware traffic is opt-in, via MQTT, through
`OvcsBus.Mqtt.Relay` on each firmware connecting to a single
`OvcsBus.Mqtt.Broker` hosted by the VMS.

To avoid restating broker host + topic prefix in every composer and
every bridge entry, use `OvcsVehicle.Bus.relay_opts/3`:

```elixir
# vehicles/<name>/lib/<name>/vms/composer.ex
@impl VmsCore.Vehicle
def bus_relay do
  OvcsVehicle.Bus.relay_opts(<Vehicle>, "<name>-vms",
    topics: [:ready_to_drive, :vms_status]
  )
end
```

The helper reads:

- `broker_host/0` — **required** on the top-level vehicle module.
  Conventionally defined with `Mix.target()` at compile time:

  ```elixir
  @broker_host (if Mix.target() == :host, do: "localhost", else: "<name>-vms.local")
  def broker_host, do: @broker_host
  ```

  Host dev points everyone at `localhost`; deployed Nerves devices
  reach the VMS over mDNS.

- `broker_port/0` — optional callback, defaults to `1884`.
- `topic_prefix/0` — optional callback, defaults to `"ovcs/<dir>/bus"`
  derived from the module name. Override if you need a non-standard
  prefix.

## Host dev vs. deployed

Same code path, two physical topologies:

|  | Host dev (`./ovcs run <vehicle>`) | Deployed Nerves |
|---|---|---|
| BEAMs | Multiple BEAMs on one machine, one per firmware role | One BEAM per physical device |
| Snames | `<vehicle>-vms`, `<vehicle>-infotainment`, `<vehicle>-bridge-<id>` | `nerves@<vehicle>-vms.local`, etc. |
| Mosquitto | Started locally by the VMS BEAM (`bus_broker/0`) on `localhost:1884` | Same — hosted on the VMS device, peers reach it via mDNS |
| CAN interfaces | Virtual (`vcan0`, `vcan1`, …) provisioned by `./ovcs can setup` | Real SPI/CAN hardware; Cantastic sets it up at boot |
| `VEHICLE` env | Set by the CLI when spawning each BEAM | Baked into the release via config.exs at build time |

The `broker_host/0` compile-time branch (`Mix.target() == :host`) is
the one thing that flips between the two modes.

## Scaffolding a new vehicle

```
./ovcs vehicle new my_car --vms-target ovcs_base_can_system_rpi4 --infotainment-target ovcs_base_can_system_rpi5
```

runs `OvcsVehicle.Scaffold.generate/3` against the template at
`libraries/ovcs_vehicle/priv/templates/vehicle/`. The template
produces a working VMS + infotainment vehicle with:

- A minimal `children/0` (one example generic controller + a vehicle
  GenServer).
- `broker_host/0` wired with the host/deploy split.
- Composers calling `OvcsVehicle.Bus.relay_opts/3` so bus plumbing
  works out of the box.
- A commented-out `bridge_firmwares/0` stub ready to uncomment.

Drop components you don't need, add the ones you do, fill in the CAN
YAMLs under `priv/can/`, and `./ovcs run <my_car>` should boot
end-to-end.

## Further reading

- [`libraries/ovcs_vehicle/README.md`](../libraries/ovcs_vehicle/README.md)
  — details on the `OvcsVehicle` behaviour and `ovcs vehicle new`.
- [`libraries/ovcs_bus/README.md`](../libraries/ovcs_bus/README.md) —
  relay/broker design, echo avoidance, runtime config.
- [Applications](./applications.md) — the wider layer split (core /
  api / firmware / dashboard).
- [Running on Hardware](./running_hardware.md) — build/burn/upload
  flows on the CLI and what each env var does.
