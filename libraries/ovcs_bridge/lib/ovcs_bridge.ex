defmodule OvcsBridge do
  @moduledoc """
  Contract every OVCS bridge library implements.

  A "bridge" is a focused library (radio-control, ROS, lidar, …)
  that exposes a supervision subtree via `children/0`. The shared
  Nerves firmware at `bridges/firmware/` composes one or more
  bridges per image — the set is declared per vehicle via
  `OvcsVehicle.bridge_firmwares/0` so a single vehicle can run
  multiple bridge firmwares in parallel (e.g. one rpi3a image for
  radio-control and one rpi5 image for ROS + lidar).

  Bridge libraries get the local `OvcsBus` pub/sub for free — pulling
  in `ovcs_bridge` brings `ovcs_bus` along, so a bridge child can
  `OvcsBus.subscribe("messages")` / `OvcsBus.broadcast/2` exactly
  like any `vms_core` component. Cross-firmware traffic goes through
  `OvcsBus.Relay.Mqtt` when the vehicle's `bridge_firmwares/0` entry
  declares `:bus_relay` opts.

  Keep the behaviour tight — anything vehicle-specific belongs in
  the vehicle's `bridge_firmwares/0` entry (target, CAN config,
  default mapping, bus relay, …), not baked into the bridge library.
  """

  @callback children() :: [:supervisor.child_spec() | {module(), term()} | module()]

  @doc """
  Optional — bus message names this bridge publishes or consumes on
  the shared relay. The supervisor unions these across every bridge
  bundled in a firmware and passes them as `:topics` to
  `OvcsBus.Relay.Mqtt` (each name becomes an MQTT topic
  `<topic_prefix>/<name>`), so each bridge library travels with its
  own message contract instead of making the vehicle restate it.
  """
  @callback relay_messages() :: [atom()]

  @optional_callbacks [relay_messages: 0]
end
