defmodule RosBridge.ImuSource.Reading do
  @moduledoc """
  One sample from an IMU source, already converted to SI units.
  Drivers emit one of these per axis stream they expose; the
  publisher coalesces the latest of each kind into a
  `sensor_msgs/Imu`.
  """
  @enforce_keys [:kind, :value]
  defstruct [:kind, :value]

  @type kind :: :linear_acceleration | :angular_velocity | :orientation
  @type value :: Ros2.GeometryMsgs.Msg.Vector3.t() | Ros2.GeometryMsgs.Msg.Quaternion.t()
  @type t :: %__MODULE__{kind: kind(), value: value()}
end

defmodule RosBridge.ImuSource do
  @moduledoc """
  Behaviour separating IMU sources (driver adapters, future fusion
  pipelines) from `RosBridge.ImuPublisher`.

  After `register_listener(pid)`, the source casts
  `{:imu_reading, %RosBridge.ImuSource.Reading{}}` to `pid` whenever
  a new sample is available, in ROS-shaped types (`Vector3` /
  `Quaternion`).

  `enable/0` tells the source to start producing samples. The source
  owns any hardware-specific gating; callers just call `enable/0`
  once and trust readings to arrive when the device is ready.
  """

  @callback register_listener(pid()) :: :ok
  @callback enable() :: :ok
end
