defmodule RosBridge.Timing do
  @moduledoc """
  Time-conversion helpers shared by every publisher in the bridge.

  Most drivers tag their samples with `System.monotonic_time(:nanosecond)`;
  `OvcsDrivers.Lidar.Scan` and `OvcsDrivers.Rangefinder.Sample` carry
  system time and go through `stamp_from_system_time/1`.
  Monotonic time has no relation to wall clock, but every ROS
  message's `std_msgs/Header` expects a wall-clock stamp — otherwise
  downstream `ApproximateTime` matchers (`message_filters`, `tf2`,
  …) compare nonsensical timestamps across topics.

  `system_time_from_monotonic/1` projects a monotonic capture time onto
  wall clock through `System.time_offset/1`, the VM's own offset between
  the two.

  ## Wall clock is not always the target

  Against a simulator it is the wrong clock entirely: Gazebo owns
  time, starts it at zero and advances it with physics, so a
  wall-clock stamp sits most of two decades away from `/tf` and
  `/odom` and any consumer that compares them drops the message.

  So `stamp_from_monotonic/1` asks `RosBridge.Clock` which timescale to
  target. With no simulator clock being followed — a vehicle, and
  every test — the answer is `nil` and the wall-clock path above is
  unchanged. Drivers are unaffected either way: they keep their own
  timescale and this stays the only place that converts.
  """

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time

  @doc """
  Convert a monotonic capture timestamp (in nanoseconds) into a
  wall-clock timestamp (also in nanoseconds).

  The input is an Erlang monotonic timestamp a driver took at
  capture. The output matches `System.system_time(:nanosecond)`.
  """
  def system_time_from_monotonic(monotonic_nanoseconds) when is_integer(monotonic_nanoseconds),
    do: monotonic_nanoseconds + System.time_offset(:nanosecond)

  @doc """
  Convert a monotonic capture timestamp into the timescale this
  bridge is publishing on: simulator time when a `/clock` is being
  followed, wall clock otherwise.
  """
  def ros_time_from_monotonic(monotonic_nanoseconds) when is_integer(monotonic_nanoseconds) do
    case RosBridge.Clock.offset_ns() do
      nil -> system_time_from_monotonic(monotonic_nanoseconds)
      offset_ns -> monotonic_nanoseconds + offset_ns
    end
  end

  @doc """
  Build a `builtin_interfaces/Time` message from a monotonic
  capture timestamp. Most publishers want this directly — they
  have a monotonic timestamp in hand and need a `%Time{sec,
  nanosec}` to drop into a `std_msgs/Header`.
  """
  def stamp_from_monotonic(monotonic_nanoseconds),
    do: stamp(ros_time_from_monotonic(monotonic_nanoseconds))

  @doc """
  `stamp_from_monotonic/1` for a system-time timestamp, which is what
  `OvcsDrivers.Rangefinder.Sample` and `OvcsDrivers.Lidar.Scan` carry.
  """
  def stamp_from_system_time(system_nanoseconds) do
    case RosBridge.Clock.offset_ns() do
      nil -> stamp(system_nanoseconds)
      offset_ns -> stamp(system_nanoseconds - System.time_offset(:nanosecond) + offset_ns)
    end
  end

  # Floored: `nanosec` is unsigned, and simulator time goes negative after a world reset.
  defp stamp(nanoseconds) do
    %Time{
      sec: Integer.floor_div(nanoseconds, 1_000_000_000),
      nanosec: Integer.mod(nanoseconds, 1_000_000_000)
    }
  end
end
