defmodule Ros2Zenoh do
  @moduledoc """
  ROS 2 messages over Zenoh, without ROS installed: CDR codecs for the
  standard message types (`Ros2Zenoh.<Package>.Msg.<Name>`), the
  `rmw_zenoh` wire format (`Ros2Zenoh.RmwZenoh`), and `Ros2Zenoh.Client`,
  the one Zenoh session a BEAM publishes, subscribes and serves through,
  so that it interoperates with ROS 2 nodes that run `rmw_zenoh`.
  """

  @bulk_messages [
    Ros2Zenoh.FoxgloveMsgs.Msg.CompressedVideo,
    Ros2Zenoh.SensorMsgs.Msg.CompressedImage,
    Ros2Zenoh.SensorMsgs.Msg.Image,
    Ros2Zenoh.SensorMsgs.Msg.PointCloud2,
    Ros2Zenoh.StereoMsgs.Msg.DisparityImage
  ]

  @doc """
  The Zenoh priority a message module's publisher puts at: `:data_low` for
  images, videos and point clouds, `:data`, Zenoh's default, for every other.
  A router short of bandwidth to a subscriber, a headset on Wi-Fi say,
  sends the higher priorities first and drops a frame rather than make the
  transforms, the odometry and the commands wait behind it.
  """
  @spec priority(module()) :: Zenohex.Session.priority()
  def priority(message_module) when message_module in @bulk_messages, do: :data_low
  def priority(_message_module), do: :data

  @doc """
  The `ros2msg` schema of a message module, as rosbag2 writes it into an
  MCAP Schema record: the module's `msg_definition/0` (ROS 2 Lyrical's `.msg`
  file, comments included), then each type it depends on, directly or not,
  once, depth-first. Each dependency follows a newline, a line of 80 `=` and
  a line `MSG: <package>/<Type>`. Siblings come in the bytewise order of
  their `<package>/<Type>` names, the order of rosbag2's `std::set`, not in
  field order.

  Sources:

    * rosbag2 0.33.4 (Lyrical): `LocalMessageDefinitionSource::get_full_text`
      and `delimiter` in
      [`rosbag2_cpp/src/rosbag2_cpp/message_definitions/local_message_definition_source.cpp`](https://github.com/ros2/rosbag2/blob/0.33.4/rosbag2_cpp/src/rosbag2_cpp/message_definitions/local_message_definition_source.cpp),
      and `MCAPStorage::create_topic` in
      [`rosbag2_storage_mcap/src/mcap_storage.cpp`](https://github.com/ros2/rosbag2/blob/0.33.4/rosbag2_storage_mcap/src/mcap_storage.cpp),
      which stores that text as the schema's data.
    * The MCAP `ros2msg` and `ros1msg` schema encodings
      (https://mcap.dev/spec/registry): the top-level definition first with
      no delimiter, and a definition for every type the schema names.
  """
  @spec definition(module()) :: String.t()
  def definition(message_module) do
    {definition, _written} = append_dependencies(message_module, [])
    definition
  end

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

  defp append_dependencies(message_module, written) do
    message_module.dependencies()
    |> Enum.sort_by(&definition_name/1)
    |> Enum.reduce({message_module.msg_definition(), written}, fn dependency, {text, written} ->
      if dependency in written do
        {text, written}
      else
        {dependency_text, written} =
          append_dependencies(dependency, [dependency | written])

        {text <> "\n" <> delimiter(dependency) <> dependency_text, written}
      end
    end)
  end

  defp delimiter(message_module),
    do: String.duplicate("=", 80) <> "\nMSG: " <> definition_name(message_module) <> "\n"

  # `Ros2Zenoh.GeometryMsgs.Msg.Pose` -> `geometry_msgs/Pose`, as `.msg` fields name it.
  defp definition_name(message_module) do
    [_root, package, "Msg", type] = Module.split(message_module)
    Macro.underscore(package) <> "/" <> type
  end
end
