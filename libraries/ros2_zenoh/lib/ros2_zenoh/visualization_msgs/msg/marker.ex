defmodule Ros2Zenoh.VisualizationMsgs.Msg.Marker do
  @moduledoc """
  ROS 2 `visualization_msgs/Marker` — the message Foxglove's 3D panel
  actually renders for arbitrary annotations. Field order on the wire
  (Lyrical):

      std_msgs/Header header
      string ns
      int32 id
      int32 type
      int32 action
      geometry_msgs/Pose pose
      geometry_msgs/Vector3 scale
      std_msgs/ColorRGBA color
      builtin_interfaces/Duration lifetime
      bool frame_locked
      geometry_msgs/Point[] points
      std_msgs/ColorRGBA[] colors
      string texture_resource
      sensor_msgs/CompressedImage texture
      UVCoordinate[] uv_coordinates
      string text
      string mesh_resource
      MeshFile mesh_file
      bool mesh_use_embedded_materials

  Exposes `append_to/2` rather than `encode/1`, for the reason
  documented at length on `TransformStamped`: CDR aligns relative to
  the **body origin**, not the struct, and `pose` opens with a
  `float64`. Nested in a `MarkerArray` a marker starts at offset 4
  (after the sequence count) and every subsequent element starts
  wherever the previous one ended, so a struct-local `align_to/2`
  computes padding for the wrong offset. That failure is silent on
  the publishing side and shows up only as an undecodable message.

  The two alignment hazards inside this struct:

    * `frame_locked` is a `bool` (alignment 1) immediately before
      `points`, whose sequence count is a u32 — so the buffer needs
      `align_to(4)` between them.
    * a non-empty `Point[]` is a `float64` run and needs
      `align_to(8)` after its count. An **empty** one gets no
      padding at all, matching Fast-CDR's `serialize_array`, which
      returns before aligning when the element count is zero.

  `texture` is a nested `CompressedImage` whose fields are all
  4-aligned, so its struct-local `encode/1` is safe. CDR has no absent
  fields, so a nil texture is encoded as a default-constructed image
  (zero stamp, empty frame_id), as rclpy does: reusing the marker's
  header would add the frame_id's bytes to every marker.
  """
  use Ros2Zenoh.Common

  alias Ros2Zenoh.BuiltinInterfaces.Msg.{Duration, Time}
  alias Ros2Zenoh.GeometryMsgs.Msg.{Point, Pose, Vector3}
  alias Ros2Zenoh.SensorMsgs.Msg.CompressedImage
  alias Ros2Zenoh.StdMsgs.Msg.{ColorRGBA, Header}
  alias Ros2Zenoh.VisualizationMsgs.Msg.{MeshFile, UVCoordinate}

  # `type` values used here. The full set lives in the .msg file;
  # only what we publish is worth mirroring.
  @arrow 0
  @cube 1
  @sphere 2
  @text_view_facing 9

  # `action` values.
  @add 0
  @delete 2
  @delete_all 3

  def arrow, do: @arrow
  def cube, do: @cube
  def sphere, do: @sphere
  def text_view_facing, do: @text_view_facing

  def add, do: @add
  def delete, do: @delete
  def delete_all, do: @delete_all

  defstruct header: nil,
            ns: "",
            id: 0,
            type: @cube,
            action: @add,
            pose: %Pose{},
            scale: %Vector3{},
            color: %ColorRGBA{},
            lifetime: %Duration{},
            frame_locked: false,
            points: [],
            colors: [],
            texture_resource: "",
            texture: nil,
            uv_coordinates: [],
            text: "",
            mesh_resource: "",
            mesh_file: %MeshFile{},
            mesh_use_embedded_materials: false

  def dds_type, do: "visualization_msgs::msg::dds_::Marker_"

  def type_hash,
    do: "RIHS01_45b13ccf791f225962bf74e746f9644518855d783a6f42ba0cc14fde2b4f3ce0"

  @spec append_to(binary(), %__MODULE__{}) :: binary()
  def append_to(buffer, %__MODULE__{} = marker) when is_binary(buffer) do
    buffer
    |> Kernel.<>(Header.encode(marker.header))
    |> Kernel.<>(encode_string(marker.ns))
    |> Kernel.<>(encode_int32(marker.id))
    |> Kernel.<>(encode_int32(marker.type))
    |> Kernel.<>(encode_int32(marker.action))
    # pose opens on a float64.
    |> align_to(8)
    |> Kernel.<>(Pose.encode(marker.pose))
    |> Kernel.<>(Vector3.encode(marker.scale))
    |> Kernel.<>(ColorRGBA.encode(marker.color))
    |> Kernel.<>(Duration.encode(marker.lifetime))
    |> Kernel.<>(encode_bool(marker.frame_locked))
    # bool (alignment 1) -> u32 sequence count.
    |> align_to(4)
    |> append_point_sequence(marker.points)
    |> append_struct_sequence(marker.colors, &ColorRGBA.encode/1)
    |> Kernel.<>(encode_string(marker.texture_resource))
    |> append_texture(marker.texture)
    |> append_struct_sequence(marker.uv_coordinates, &UVCoordinate.encode/1)
    |> Kernel.<>(encode_string(marker.text))
    |> Kernel.<>(encode_string(marker.mesh_resource))
    |> Kernel.<>(MeshFile.encode(marker.mesh_file))
    |> Kernel.<>(encode_bool(marker.mesh_use_embedded_materials))
  end

  # The float64 run is 8-aligned after the count; an empty one is not padded.
  defp append_point_sequence(buffer, []), do: buffer <> encode_uint32(0)

  defp append_point_sequence(buffer, points) do
    Enum.reduce(points, align_to(buffer <> encode_uint32(length(points)), 8), fn point, acc ->
      acc <> Point.encode(point)
    end)
  end

  # For elements aligned to 4 or less, which the u32 count already satisfies.
  defp append_struct_sequence(buffer, values, encode_one) do
    Enum.reduce(values, buffer <> encode_uint32(length(values)), fn value, acc ->
      acc <> encode_one.(value)
    end)
  end

  # A nil texture is a default-constructed image; see the moduledoc.
  defp append_texture(buffer, nil) do
    buffer <>
      CompressedImage.encode(%CompressedImage{
        header: %Header{stamp: %Time{}, frame_id: ""},
        format: "",
        data: <<>>
      })
  end

  defp append_texture(buffer, %CompressedImage{} = texture) do
    buffer <> CompressedImage.encode(texture)
  end
end
