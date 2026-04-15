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

  @impl OvcsBridge
  def relay_messages do
    # OvcsBus message names this bridge publishes/consumes on the
    # cross-firmware relay. Optional — default []; empty list
    # means the bridge does not need a relay.
    [:my_bridge_state]
  end
end
```

- `children/0` — required; child specs added to the bridge
  firmware's supervision tree when the bridge is bundled.
- `relay_messages/0` — optional; `OvcsBridge.Supervisor` unions
  these across every bundled bridge and passes them to
  `OvcsBus.Mqtt.Relay` as `:topics`.

## Runtime

`OvcsBridge.Supervisor` is the root for a bridge firmware image.
It reads `:ovcs_bridge` app env (set by `bridges/firmware/config/
config.exs` from `VEHICLE` + `BRIDGE_FIRMWARE_ID`), looks up the
matching entry in `vehicle.bridge_firmwares/0`, and:

1. flat-maps `children/0` from every bundled bridge module;
2. starts `OvcsBus.Mqtt.Relay` when the entry has `:bus_relay`
   (broker/identity from the vehicle, topics unioned from each
   bridge's `relay_messages/0` unless the vehicle overrides);
3. runs everything under `:one_for_one`.

Bridge libraries get the local `OvcsBus` (Phoenix.PubSub) for free
— this lib depends on `ovcs_bus`, so `OvcsBus.subscribe/1` and
`broadcast/2` work out of the box.

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

Unlike the VMS firmware (`vms/api/mix.exs` pulls the active vehicle
via `System.get_env("VEHICLE")` → path dep), the bridges firmware
enumerates bridge libraries explicitly. If bridges were instead
pulled in through the vehicle, they'd bleed into `vms/firmware` and
`infotainment/firmware` releases — both transitively depend on the
vehicle, and target-gating can't separate them when `MIX_TARGET`
matches (e.g. VMS and `ros_bridge` both build for rpi4). Keeping
bridge libs enumerated here keeps the VMS/infotainment releases
lean at the cost of a shared-firmware touch when a new bridge is
added. Target-gating still prevents e.g. rpi3a builds from pulling
ros_bridge's MQTT/Zenoh chain.
