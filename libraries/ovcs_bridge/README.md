# OvcsBridge

Contract + supervision glue for OVCS bridge libraries.

A **bridge** is a focused Elixir library that ferries data between
OVCS and some non-CAN world (radio-control link, ROS2 graph, lidar,
…). Each bridge lives under `bridges/<name>/` and implements the
`OvcsBridge` behaviour. Multiple bridges are composed into a single
Nerves image at `bridges/firmware/`, driven at boot by the active
vehicle's `OvcsVehicle.bridge_firmwares/0` declaration.

## Why a library and not a firmware per bridge

One vehicle often runs several bridge firmwares on different SoCs
(e.g. radio-control on rpi3a, ROS on rpi5). Keeping bridges as
plain libraries means:

- one shared Nerves image (`bridges/firmware/`) handles fwup, rootfs,
  networking — you don't maintain N copies.
- each vehicle composes its own subset of bridges per image via its
  `bridge_firmwares/0` map.
- a bridge library can be bundled into multiple firmware images
  without duplication.

## Behaviour

```elixir
defmodule MyBridge do
  @behaviour OvcsBridge

  @impl OvcsBridge
  def children do
    [
      {MyBridge.SomeWorker, []},
      {MyBridge.AnotherWorker, []}
    ]
  end
end
```

- `children/0` — required; child specs added to the bridge
  firmware's supervision tree when the bridge is bundled.

## Runtime

`OvcsBridge.Supervisor` is the root for a bridge firmware image.
It reads `:ovcs_bridge` app env (set by `bridges/firmware/config/
config.exs` from `VEHICLE` + `BRIDGE_FIRMWARE_ID`), looks up the
matching entry in `vehicle.bridge_firmwares/0`, and:

1. starts `OvcsBus.Cluster` so this BEAM joins the vehicle's
   distributed Erlang mesh;
2. ensures each bundled bridge's OTP application is started
   (no-op on target; explicit on host dev where bridges are
   `runtime: false`);
3. flat-maps `children/0` from every bundled bridge module;
4. runs everything under `:one_for_one`.

Bridge libraries get cluster-wide `OvcsBus` for free — this lib
depends on `ovcs_bus`, so `OvcsBus.subscribe/1` and `broadcast/2`
work out of the box and reach subscribers on every peer BEAM.

## Layout

```
lib/
  ovcs_bridge.ex             — the OvcsBridge behaviour
  ovcs_bridge/
    supervisor.ex            — root supervisor for bridge firmwares
```

## Dependencies

- `ovcs_vehicle` — for the `OvcsVehicle` contract the supervisor
  queries for the active bridge firmware entry.
- `ovcs_bus` — bundles the local pub/sub bus + relay, available
  to every bridge library that transitively depends on this one.

## Why bridge libs are listed in `bridges/firmware/mix.exs`

No firmware depends on a vehicle as a Mix dep — vehicles are reached
at boot via `Code.prepend_path`. That means bridge libraries can't
be pulled in transitively through the vehicle even if we wanted
them to be. Each bridge library is listed directly in
`bridges/firmware/mix.exs`, target-gated so a rpi3a build only
compiles what rpi3a bridges actually need. Adding a new bridge
library is a two-liner there + target-gate entry — the vehicle's
`bridge_firmwares/0` then opts into it per firmware image.
