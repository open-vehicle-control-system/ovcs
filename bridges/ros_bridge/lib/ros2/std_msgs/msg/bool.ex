defmodule Ros2.StdMsgs.Msg.Bool do
  @moduledoc "ROS 2 `std_msgs/Bool`: one boolean."

  defstruct data: false

  @dds_type "std_msgs::msg::dds_::Bool_"
  @type_hash "RIHS01_feb91e995ff9ebd09c0cb3d2aed18b11077585839fb5db80193b62d74528f6c9"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{data: data}), do: Ros2.Cdr.bool(<<>>, data)
end
