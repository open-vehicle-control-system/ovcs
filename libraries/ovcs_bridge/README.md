# OvcsBridge

Contract + supervision glue for OVCS bridge libraries.

A **bridge** is a focused Elixir library that ferries data between
OVCS and some non-CAN world (radio-control link, ROS2 graph, lidar,
…). Each bridge lives under `bridges/<name>/` and implements the
`OvcsBridge` behaviour. Multiple bridges are composed into a single
Nerves image at `bridges/firmware/`, driven at boot by the active
vehicle's `OvcsVehicle.bridge_firmwares/0` declaration.

The guide, [Bridges](../../docs/bridges/README.md), explains why bridges are libraries,
the bridge firmware entry and the boot sequence; this README keeps the library's
developer details.

## Behaviour

`children/0` (required) and `apply_runtime_config/2` (optional), documented in
`lib/ovcs_bridge.ex`. [Write a bridge](../../docs/bridges/write_a_bridge.md) builds one
end to end.

## Runtime

`OvcsBridge.Supervisor` is the root of a bridge firmware image; [How a bridge firmware boots](../../docs/bridges/README.md#how-a-bridge-firmware-boots)
lists what it starts, in order.

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
- `ovcs_bus` — pub/sub bus, available to every
  bridge library that transitively depends on this one.

## Why bridge libs are listed in `bridges/firmware/mix.exs`

Vehicles are reached at boot through `Code.prepend_path`, never as a Mix dependency, so a
bridge library can't arrive transitively; [List it in the bridge firmware](../../docs/bridges/write_a_bridge.md#list-it-in-the-bridge-firmware)
shows the entry and the target gates.
