defmodule OvcsVehicle do
  @moduledoc """
  Top-level contract for an OVCS vehicle package.

  A vehicle package is a single Mix app that bundles the VMS,
  infotainment, and any bridge firmwares for a vehicle. The
  top-level module implements this behaviour; it exposes the
  side-specific composers so `vms_core`, `infotainment_core`, and
  the shared bridge firmware can dispatch through a single reference
  configured as `:vehicle` in their application environment.

  Bridge firmwares are declared via `bridge_firmwares/0`, which
  returns a map keyed by firmware id. Each entry picks a Nerves
  target and a set of bridge modules to bundle together, so one
  vehicle can run multiple bridge firmwares in parallel (e.g. an
  rpi3a image for radio-control and an rpi5 image for ROS + lidar).
  """

  @type bridge_firmware_id :: String.t()

  @type bridge_firmware :: %{
          required(:target) => atom(),
          required(:bridges) => [module()],
          optional(:can_config_path) => String.t(),
          optional(:default_can_mapping) => %{
            host: String.t(),
            target: String.t()
          }
        }

  @typedoc """
  A vehicle's measured physical geometry, in SI units — metres and
  radians, never millimetres or degrees.

  This exists so `vms_core` can stay free of vehicle-specific code
  while still doing work that needs to know the vehicle's shape.
  Kinematics is the case that forces it: converting a velocity command
  into a steering angle is `atan(wheelbase * omega / v)`, which is the
  same arithmetic for every Ackermann vehicle and a different number
  for each one. Generic code, vehicle-specific data, supplied at
  instantiation.

  Only *measured* quantities belong here. Anything derivable is a
  function — see `min_turning_radius/1` — because a stored derived
  value is one more copy to get wrong, and the copies are the problem
  this type exists to bound.
  """
  @type geometry :: %{
          required(:wheelbase) => float(),
          required(:track) => float(),
          required(:wheel_radius) => float(),
          required(:steering_limit) => float()
        }

  @callback name() :: String.t()
  @callback vms() :: module()
  @callback infotainment() :: module()
  @callback bridge_firmwares() :: %{bridge_firmware_id() => bridge_firmware()}
  @callback can_config_otp_app() :: atom()
  @callback vms_target() :: atom()
  @callback infotainment_target() :: atom()

  @doc """
  The vehicle's measured physical geometry.

  Optional: a package that only ever reads a bus — `Obd2` is one — has
  no geometry to declare, and a vehicle whose numbers have not been
  measured should omit this rather than guess. Components that need it
  take it as an option from the composer, so a missing implementation
  is a compile-time absence rather than a runtime surprise.
  """
  @callback geometry() :: geometry()

  @optional_callbacks [
    infotainment: 0,
    infotainment_target: 0,
    bridge_firmwares: 0,
    geometry: 0
  ]

  @doc """
  Tightest circle the vehicle can drive, in metres: `wheelbase /
  tan(steering_limit)`.

  Derived rather than declared, deliberately. It is the bound every
  velocity command has to respect — a yaw rate above `v / this` asks
  for an arc the steering cannot cut — so it wants a single definition
  rather than a number copied into each caller.

      iex> OvcsVehicle.min_turning_radius(%{wheelbase: 0.324, steering_limit: 0.52})
      0.5658777495831087
  """
  @spec min_turning_radius(geometry()) :: float()
  def min_turning_radius(%{wheelbase: wheelbase, steering_limit: steering_limit})
      when steering_limit > 0 do
    wheelbase / :math.tan(steering_limit)
  end

  @doc """
  Largest yaw rate achievable at `speed`, in rad/s.

  Zero at a standstill, and that is not an edge case to work around —
  an Ackermann vehicle genuinely cannot rotate on the spot. Callers
  that receive `(v = 0, omega != 0)` have to decide what to do about
  it; this only tells them the command is unachievable.

      iex> geometry = %{wheelbase: 0.324, steering_limit: 0.52}
      iex> OvcsVehicle.max_yaw_rate(geometry, 1.0)
      1.767166142752063
      iex> OvcsVehicle.max_yaw_rate(geometry, 0.0)
      0.0
  """
  @spec max_yaw_rate(geometry(), number()) :: float()
  def max_yaw_rate(geometry, speed) do
    abs(speed) / min_turning_radius(geometry)
  end
end
