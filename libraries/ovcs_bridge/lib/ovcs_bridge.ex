defmodule OvcsBridge do
  @moduledoc """
  Contract every OVCS bridge library implements.

  A "bridge" is a focused library (radio-control, ROS, lidar, …)
  that exposes a supervision subtree via `children/0`. The shared
  Nerves firmware at `firmwares/bridge/` composes one or more
  bridges per image — the set is declared per vehicle via
  `OvcsVehicle.bridge_firmwares/0` so a single vehicle can run
  multiple bridge firmwares in parallel (e.g. one rpi3a image for
  radio-control and one rpi5 image for ROS + lidar).

  Keep the behaviour tight — anything vehicle-specific belongs in
  the vehicle's `bridge_firmwares/0` entry (target, CAN config,
  default mapping), not baked into the bridge library.
  """

  @callback children() :: [:supervisor.child_spec() | {module(), term()} | module()]
end
