defmodule Ros2.SensorMsgs.Msg.Joy do
  @moduledoc false
  use Ros2.Common

  defstruct header: nil, axes: [], buttons: []

  # rmw_zenoh keyexpr metadata for `sensor_msgs/msg/Joy`, so a subscription declares
  # its liveliness token and shows in the ROS graph. The RIHS01 hash was
  # captured against ROS 2 Lyrical via `ros2 topic info -v`. Refresh on
  # distro bumps.
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
