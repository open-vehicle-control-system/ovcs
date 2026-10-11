defmodule Ros2.SensorMsgs.Msg.Joy do
  @moduledoc """
  ROS 2 `sensor_msgs/Joy`: a header, `float32[]` axes and `int32[]`
  buttons. Parse only: the bridge consumes joystick commands.
  """
  use Ros2.Common

  defstruct header: nil, axes: [], buttons: []

  # RIHS01 hash for ROS 2 Lyrical; it changes with the distro.
  @dds_type "sensor_msgs::msg::dds_::Joy_"
  @type_hash "RIHS01_0d356c79cad3401e35ffeb75a96a96e08be3ef896b8b83841d73e890989372c5"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def parse(payload) do
    with {:ok, header, payload} <- Ros2.StdMsgs.Msg.Header.parse(payload),
         {:ok, axes, payload} <- parse_float32_array(payload),
         {:ok, buttons, payload} <- parse_int32_array(payload) do
      {:ok,
       %__MODULE__{
         header: header,
         axes: axes,
         buttons: buttons
       }, payload}
    else
      error -> error
    end
  end
end
