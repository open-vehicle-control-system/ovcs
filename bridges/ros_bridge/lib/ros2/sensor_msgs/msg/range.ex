defmodule Ros2.SensorMsgs.Msg.Range do
  @moduledoc """
  ROS 2 `sensor_msgs/Range`: one distance from a single-beam ranger.
  Per REP 117, `range` is `:infinity` when nothing is in range and
  `:neg_infinity` when something is closer than `min_range`.
  """

  import Ros2.Cdr
  alias Ros2.BuiltinInterfaces.Msg.Time
  alias Ros2.StdMsgs.Msg.Header

  @ultrasound 0
  @infrared 1

  defstruct header: %Header{},
            radiation_type: :ultrasound,
            field_of_view: 0.0,
            min_range: 0.0,
            max_range: 0.0,
            range: 0.0,
            variance: 0.0

  @dds_type "sensor_msgs::msg::dds_::Range_"
  @type_hash "RIHS01_b42b62562e93cbfe9d42b82fe5994dfa3d63d7d5c90a317981703f7388adff3a"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  # The header is encoded here rather than by `Header.encode/1`, which
  # pads the frame id to 4 bytes: the uint8 that follows sits right
  # after it.
  def encode(%__MODULE__{header: header} = m) do
    Time.encode(header.stamp)
    |> string(header.frame_id)
    |> u8(if m.radiation_type == :infrared, do: @infrared, else: @ultrasound)
    |> f32(m.field_of_view)
    |> f32(m.min_range)
    |> f32(m.max_range)
    |> f32(m.range)
    |> f32(m.variance)
  end
end
