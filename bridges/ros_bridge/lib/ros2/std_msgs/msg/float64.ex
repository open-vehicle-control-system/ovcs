defmodule Ros2.StdMsgs.Msg.Float64 do
  @moduledoc "ROS 2 `std_msgs/Float64`: one float64."

  defstruct data: 0.0

  @dds_type "std_msgs::msg::dds_::Float64_"
  @type_hash "RIHS01_705ba9c3d1a09df43737eb67095534de36fd426c0587779bda2bc51fe790182a"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{data: data}), do: Ros2.Cdr.f64(<<>>, data)
end
