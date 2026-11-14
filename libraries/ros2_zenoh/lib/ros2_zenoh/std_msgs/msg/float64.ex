defmodule Ros2Zenoh.StdMsgs.Msg.Float64 do
  @moduledoc "ROS 2 `std_msgs/Float64`: one float64."

  defstruct data: 0.0

  def msg_definition do
    """
    # This was originally provided as an example message.
    # It is deprecated as of Foxy
    # It is recommended to create your own semantically meaningful message.
    # However if you would like to continue using this please use the equivalent in example_msgs.

    float64 data
    """
  end

  def dependencies, do: []

  @dds_type "std_msgs::msg::dds_::Float64_"
  @type_hash "RIHS01_705ba9c3d1a09df43737eb67095534de36fd426c0587779bda2bc51fe790182a"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{data: data}), do: Ros2Zenoh.Cdr.f64(<<>>, data)
end
