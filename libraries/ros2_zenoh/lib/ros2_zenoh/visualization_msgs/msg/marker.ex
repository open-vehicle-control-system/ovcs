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

  def msg_definition do
    """
    # See:
    #  - http://www.ros.org/wiki/rviz/DisplayTypes/Marker
    #  - http://www.ros.org/wiki/rviz/Tutorials/Markers%3A%20Basic%20Shapes
    #
    # for more information on using this message with rviz.

    int32 ARROW=0
    int32 CUBE=1
    int32 SPHERE=2
    int32 CYLINDER=3
    int32 LINE_STRIP=4
    int32 LINE_LIST=5
    int32 CUBE_LIST=6
    int32 SPHERE_LIST=7
    int32 POINTS=8
    int32 TEXT_VIEW_FACING=9
    int32 MESH_RESOURCE=10
    int32 TRIANGLE_LIST=11
    int32 ARROW_STRIP=12

    int32 ADD=0
    int32 MODIFY=0
    int32 DELETE=2
    int32 DELETEALL=3

    # Header for timestamp and frame id.
    std_msgs/Header header
    # Namespace in which to place the object.
    # Used in conjunction with id to create a unique name for the object.
    string ns
    # Object ID used in conjunction with the namespace for manipulating and deleting the object later.
    int32 id
    # Type of object.
    int32 type
    # Action to take; one of:
    #  - 0 add/modify an object
    #  - 1 (deprecated)
    #  - 2 deletes an object (with the given ns and id)
    #  - 3 deletes all objects (or those with the given ns if any)
    int32 action
    # Pose of the object with respect the frame_id specified in the header.
    geometry_msgs/Pose pose
    # Scale of the object; 1,1,1 means default (usually 1 meter square).
    geometry_msgs/Vector3 scale
    # Color of the object; in the range: [0.0-1.0]
    std_msgs/ColorRGBA color
    # How long the object should last before being automatically deleted.
    # 0 indicates forever.
    builtin_interfaces/Duration lifetime
    # If this marker should be frame-locked, i.e. retransformed into its frame every timestep.
    bool frame_locked

    # Only used if the type specified has some use for them (eg. POINTS, LINE_STRIP, ARROW_STRIP, etc.)
    geometry_msgs/Point[] points
    # Only used if the type specified has some use for them (eg. POINTS, LINE_STRIP, etc.)
    # The number of colors provided must either be 0 or equal to the number of points provided.
    # NOTE: alpha is not yet used
    std_msgs/ColorRGBA[] colors

    # Texture resource is a special URI that can either reference a texture file in
    # a format acceptable to (resource retriever)[https://docs.ros.org/en/rolling/p/resource_retriever/]
    # or an embedded texture via a string matching the format:
    #   "embedded://texture_name"
    string texture_resource
    # An image to be loaded into the rendering engine as the texture for this marker.
    # This will be used iff texture_resource is set to embedded.
    sensor_msgs/CompressedImage texture
    # Location of each vertex within the texture; in the range: [0.0-1.0]
    UVCoordinate[] uv_coordinates

    # Only used for text markers
    string text

    # Only used for MESH_RESOURCE markers.
    # Similar to texture_resource, mesh_resource uses resource retriever to load a mesh.
    # Optionally, a mesh file can be sent in-message via the mesh_file field. If doing so,
    # use the following format for mesh_resource:
    #   "embedded://mesh_name"
    string mesh_resource
    MeshFile mesh_file
    bool mesh_use_embedded_materials
    """
  end

  def dependencies,
    do: [
      Header,
      Pose,
      Vector3,
      ColorRGBA,
      Duration,
      Point,
      CompressedImage,
      UVCoordinate,
      MeshFile
    ]

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
