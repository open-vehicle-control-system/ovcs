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

  Bridge libraries get `OvcsBus` pub/sub for free — pulling in
  `ovcs_bridge` brings `ovcs_bus` along, so a bridge child can
  `OvcsBus.subscribe("messages")` / `OvcsBus.broadcast/2` exactly
  like any `vms_core` component. `OvcsBus` is cluster-wide, so any
  broadcast on a bridge BEAM reaches subscribers on the VMS /
  infotainment / other-bridge BEAMs over Erlang distribution.

  Keep the behaviour tight — anything vehicle-specific belongs in
  the vehicle's `bridge_firmwares/0` entry (target, CAN config,
  default mapping, …), not baked into the bridge library.
  """

  @callback children() :: [:supervisor.child_spec() | {module(), term()} | module()]

  @doc """
  Optional hook invoked from `bridges/firmware`'s `config/runtime.exs`
  before any application starts. Bridges that need to stamp
  third-party Application env from per-vehicle config (e.g. a serial
  protocol library that reads its UART pin once at boot) implement
  this; the firmware host walks every bundled bridge and calls the
  callback on whichever ones export it.

  The bridge is responsible for reading its own vehicle config and
  writing whatever env keys its dependencies expect via
  `Application.put_env(app, key, value, persistent: true)`. Keep
  this small — anything that can wait until `children/0` should
  live there instead.
  """
  @callback apply_runtime_config(vehicle :: module(), build_target :: atom()) :: any()

  @optional_callbacks apply_runtime_config: 2
end
