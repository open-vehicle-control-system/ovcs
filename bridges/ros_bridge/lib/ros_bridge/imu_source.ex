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
  Behaviour separating IMU sensor drivers (`BNO085.I2C`,
  `BNO085.Dummy`, future ones) from `RosBridge.ImuPublisher`.

  After `register_listener(pid)`, the driver casts
  `{:imu_reading, %RosBridge.ImuSource.Reading{}}` to `pid` whenever
  a new sample is available. Values are in SI units (m/s² for
  linear acceleration, rad/s for angular velocity, unit-quaternion
  components for orientation) — Q-point conversions and any other
  hardware-specific decoding live in the driver, not the publisher.

  `enable/0` tells the driver to start producing samples. The driver
  owns any hardware-specific gating (e.g. waiting for a chip reset
  to complete before issuing feature commands); callers just call
  `enable/0` once and trust readings to arrive when the device is
  ready.
  """

  @callback register_listener(pid()) :: :ok
  @callback enable() :: :ok
end
