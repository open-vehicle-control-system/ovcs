defmodule Ros2Zenoh do
  @moduledoc """
  ROS 2 messages over Zenoh, without ROS installed: CDR codecs for the
  standard message types (`Ros2Zenoh.<Package>.Msg.<Name>`), the
  `rmw_zenoh` wire format (`Ros2Zenoh.RmwZenoh`), and `Ros2Zenoh.Client`,
  the one Zenoh session a BEAM publishes, subscribes and serves through,
  so that it interoperates with ROS 2 nodes that run `rmw_zenoh`.
  """

  @bulk_messages [
    Ros2Zenoh.SensorMsgs.Msg.CompressedImage,
    Ros2Zenoh.SensorMsgs.Msg.Image,
    Ros2Zenoh.SensorMsgs.Msg.PointCloud2,
    Ros2Zenoh.StereoMsgs.Msg.DisparityImage
  ]

  @doc """
  The Zenoh priority a message module's publisher puts at: `:data_low` for
  images and point clouds, `:data`, Zenoh's default, for every other.
  A router short of bandwidth to a subscriber, a headset on Wi-Fi say,
  sends the higher priorities first and drops a frame rather than make the
  transforms, the odometry and the commands wait behind it.
  """
  @spec priority(module()) :: Zenohex.Session.priority()
  def priority(message_module) when message_module in @bulk_messages, do: :data_low
  def priority(_message_module), do: :data

  @doc "`name` as a full ROS name, with a leading `/`."
  @spec full_name(String.t()) :: String.t()
  def full_name("/" <> _rest = name), do: name
  def full_name(name), do: "/" <> name

  @doc "The ROS type name of a message or service module (`sensor_msgs/msg/Image`), or its module name."
  @spec ros_type(module()) :: String.t()
  def ros_type(module) do
    Code.ensure_loaded(module)

    if function_exported?(module, :dds_type, 0) do
      module.dds_type()
      |> String.replace("::dds_::", "::")
      |> String.replace("::", "/")
      |> String.trim_trailing("_")
    else
      inspect(module)
    end
  end
end
