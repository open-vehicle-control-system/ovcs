defmodule Ros2Zenoh.DefinitionTest do
  @moduledoc """
  The message definitions against ROS 2 Lyrical's `.msg` files in
  `test/support/msg` (provenance in its README), and `Ros2Zenoh.definition/1`
  against rosbag2's algorithm run over those files alone.
  """
  use ExUnit.Case, async: true

  alias Ros2Zenoh.StdMsgs.Msg.{Float64, Header}
  alias Ros2Zenoh.VisualizationMsgs.Msg.MarkerArray

  @fixtures_directory Path.expand("../support/msg", __DIR__)
  @fixtures @fixtures_directory |> Path.join("*/*.msg") |> Path.wildcard() |> Enum.sort()
  @separator String.duplicate("=", 80)

  # The message modules vision/core publishes (`git grep -h "alias Ros2Zenoh" vision/core/lib`,
  # without the services).
  @published [
    Ros2Zenoh.BuiltinInterfaces.Msg.Duration,
    Ros2Zenoh.BuiltinInterfaces.Msg.Time,
    Ros2Zenoh.DiagnosticMsgs.Msg.DiagnosticArray,
    Ros2Zenoh.FoxgloveMsgs.Msg.Color,
    Ros2Zenoh.FoxgloveMsgs.Msg.CompressedVideo,
    Ros2Zenoh.FoxgloveMsgs.Msg.ImageAnnotations,
    Ros2Zenoh.FoxgloveMsgs.Msg.Point2,
    Ros2Zenoh.FoxgloveMsgs.Msg.PointsAnnotation,
    Ros2Zenoh.FoxgloveMsgs.Msg.TextAnnotation,
    Ros2Zenoh.GeometryMsgs.Msg.Point,
    Ros2Zenoh.GeometryMsgs.Msg.Pose,
    Ros2Zenoh.GeometryMsgs.Msg.PoseWithCovariance,
    Ros2Zenoh.GeometryMsgs.Msg.Quaternion,
    Ros2Zenoh.GeometryMsgs.Msg.Transform,
    Ros2Zenoh.GeometryMsgs.Msg.TransformStamped,
    Ros2Zenoh.GeometryMsgs.Msg.Vector3,
    Ros2Zenoh.RosgraphMsgs.Msg.Clock,
    Ros2Zenoh.SensorMsgs.Msg.CameraInfo,
    Ros2Zenoh.SensorMsgs.Msg.CompressedImage,
    Ros2Zenoh.SensorMsgs.Msg.Image,
    Ros2Zenoh.SensorMsgs.Msg.PointCloud2,
    Ros2Zenoh.SensorMsgs.Msg.RegionOfInterest,
    Ros2Zenoh.StdMsgs.Msg.ColorRGBA,
    Ros2Zenoh.StdMsgs.Msg.Float64,
    Ros2Zenoh.StdMsgs.Msg.Header,
    Ros2Zenoh.StdMsgs.Msg.String,
    Ros2Zenoh.StereoMsgs.Msg.DisparityImage,
    Ros2Zenoh.Tf2Msgs.Msg.TFMessage,
    Ros2Zenoh.VisionMsgs.Msg.BoundingBox2D,
    Ros2Zenoh.VisionMsgs.Msg.BoundingBox3D,
    Ros2Zenoh.VisionMsgs.Msg.Detection2D,
    Ros2Zenoh.VisionMsgs.Msg.Detection2DArray,
    Ros2Zenoh.VisionMsgs.Msg.Detection3D,
    Ros2Zenoh.VisionMsgs.Msg.Detection3DArray,
    Ros2Zenoh.VisionMsgs.Msg.ObjectHypothesis,
    Ros2Zenoh.VisionMsgs.Msg.ObjectHypothesisWithPose,
    Ros2Zenoh.VisionMsgs.Msg.Point2D,
    Ros2Zenoh.VisionMsgs.Msg.Pose2D,
    Ros2Zenoh.VisualizationMsgs.Msg.Marker,
    Ros2Zenoh.VisualizationMsgs.Msg.MarkerArray
  ]

  # rosbag2's field type pattern and primitives (rosbag2_cpp's local_message_definition_source.cpp).
  @field_type ~r/(?:^|\n)\s*([a-zA-Z0-9_\/]+)(?:\[[^\]]*\])?\s+/
  @primitives ~w(bool byte char float32 float64 int8 uint8 int16 uint16 int32 uint32 int64 uint64 string)

  describe "msg_definition/0" do
    for path <- @fixtures do
      @path path
      type = path |> Path.relative_to(@fixtures_directory) |> Path.rootname()

      test "is Lyrical's #{type}.msg" do
        assert fixture_module(@path).msg_definition() == File.read!(@path)
      end
    end

    test "exists on every published message module, with its Lyrical fixture" do
      for module <- @published do
        assert Code.ensure_loaded?(module) and function_exported?(module, :msg_definition, 0),
               "#{inspect(module)} has no msg_definition/0"

        assert File.exists?(fixture_path(module)), "#{inspect(module)} has no Lyrical fixture"
      end
    end
  end

  describe "dependencies/0" do
    for path <- @fixtures do
      @path path
      type = path |> Path.relative_to(@fixtures_directory) |> Path.rootname()

      test "lists the types #{type}.msg names, once each, in field order" do
        expected = @path |> File.read!() |> field_types(package(@path)) |> Enum.uniq()

        assert Enum.map(fixture_module(@path).dependencies(), &name/1) == expected
      end
    end
  end

  describe "definition/1" do
    test "is what rosbag2 writes for every published message module" do
      for module <- @published do
        assert Ros2Zenoh.definition(module) == rosbag2_full_text(name(module)),
               "#{inspect(module)}'s definition differs from rosbag2's"
      end
    end

    test "appends a dependency after a blank line and its two-line delimiter" do
      header = File.read!(Path.join(@fixtures_directory, "std_msgs/Header.msg"))
      time = File.read!(Path.join(@fixtures_directory, "builtin_interfaces/Time.msg"))

      assert Ros2Zenoh.definition(Header) ==
               header <> "\n" <> @separator <> "\nMSG: builtin_interfaces/Time\n" <> time
    end

    test "names a type nested three levels down once" do
      definition = Ros2Zenoh.definition(MarkerArray)

      for type <-
            ~w(visualization_msgs/Marker geometry_msgs/Pose geometry_msgs/Point std_msgs/Header) do
        assert occurrences(definition, "\nMSG: #{type}\n") == 1, "MSG: #{type} not exactly once"
      end
    end

    test "is the message's own text when it has no dependency" do
      definition = Ros2Zenoh.definition(Float64)

      assert definition == Float64.msg_definition()
      refute definition =~ @separator
    end
  end

  # rosbag2_cpp's LocalMessageDefinitionSource.get_full_text/1, over the fixtures.
  defp rosbag2_full_text(type) do
    {text, _seen} = rosbag2_append(type, MapSet.new())
    text
  end

  defp rosbag2_append(type, seen) do
    text = File.read!(Path.join(@fixtures_directory, type <> ".msg"))
    [package, _name] = String.split(type, "/")

    text
    |> field_types(package)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce({text, seen}, fn dependency, {full_text, seen} ->
      if MapSet.member?(seen, dependency) do
        {full_text, seen}
      else
        {dependency_text, seen} = rosbag2_append(dependency, MapSet.put(seen, dependency))

        {full_text <> "\n" <> @separator <> "\nMSG: " <> dependency <> "\n" <> dependency_text,
         seen}
      end
    end)
  end

  defp field_types(text, package) do
    @field_type
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.reject(&(&1 in @primitives))
    |> Enum.map(&if(String.contains?(&1, "/"), do: &1, else: package <> "/" <> &1))
  end

  defp fixture_module(path) do
    Module.concat([Ros2Zenoh, Macro.camelize(package(path)), Msg, Path.basename(path, ".msg")])
  end

  defp fixture_path(module), do: Path.join(@fixtures_directory, name(module) <> ".msg")

  defp package(path), do: path |> Path.dirname() |> Path.basename()

  defp name(module) do
    [_root, package, "Msg", type] = Module.split(module)
    Macro.underscore(package) <> "/" <> type
  end

  defp occurrences(text, pattern), do: length(String.split(text, pattern)) - 1
end
