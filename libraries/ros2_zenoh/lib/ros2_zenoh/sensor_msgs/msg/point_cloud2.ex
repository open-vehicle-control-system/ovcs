defmodule Ros2Zenoh.SensorMsgs.Msg.PointField do
  @moduledoc """
  ROS 2 `sensor_msgs/PointField`: one column description inside a
  `PointCloud2`. `name` (string), `offset` (u32), `datatype` (u8),
  `count` (u32).

  The `uint8` after a string is the alignment hazard here — see
  `append_to/2`.
  """
  use Ros2Zenoh.Common

  @float32 7

  defstruct name: "", offset: 0, datatype: @float32, count: 1

  def msg_definition do
    """
    # This message holds the description of one point entry in the
    # PointCloud2 message format.
    uint8 INT8    = 1
    uint8 UINT8   = 2
    uint8 INT16   = 3
    uint8 UINT16  = 4
    uint8 INT32   = 5
    uint8 UINT32  = 6
    uint8 FLOAT32 = 7
    uint8 FLOAT64 = 8
    uint8 INT64   = 9
    uint8 UINT64  = 10
    uint8 BOOL    = 11

    # Common PointField names are x, y, z, intensity, rgb, rgba
    string name      # Name of field
    uint32 offset    # Offset from start of point struct
    uint8  datatype  # Datatype enumeration, see above
    uint32 count     # How many elements in the field
    """
  end

  def dependencies, do: []

  def float32, do: @float32

  @doc """
  Appends this field to the running message buffer.

  Takes the accumulated buffer rather than encoding standalone,
  because CDR alignment is relative to the message body's origin. A
  field's own start offset is whatever the preceding fields left, and
  computing padding from zero silently produces a message the receiver
  cannot decode.

  Two alignment steps inside one small struct: `name` is written
  without trailing padding and realigned to 4 for the `uint32`
  `offset`, and `count` is a `uint32` after the `uint8` `datatype`, so
  it needs 4 again.
  """
  @spec append_to(binary(), %__MODULE__{}) :: binary()
  def append_to(buffer, %__MODULE__{name: name, offset: offset, datatype: datatype, count: count})
      when is_binary(buffer) do
    (buffer <> encode_string_unaligned(name))
    |> align_to(4)
    |> Kernel.<>(encode_uint32(offset))
    |> Kernel.<>(encode_uint8(datatype))
    |> align_to(4)
    |> Kernel.<>(encode_uint32(count))
  end
end

defmodule Ros2Zenoh.SensorMsgs.Msg.PointCloud2 do
  @moduledoc """
  ROS 2 `sensor_msgs/PointCloud2`.

  Published alongside the depth image because a depth image is only
  half a measurement: it needs intrinsics, a depth scale, and a viewer
  that knows to unproject it, and each of those fails silently when
  wrong. A point cloud carries
  explicit XYZ in metres — there is nothing left to interpret, and it
  is what an obstacle-processing consumer wants anyway.

  Emitted as `x, y, z` float32 in the *optical* frame of the depth
  image (x right, y down, z forward); `/tf` rotates it into the
  vehicle's axes.
  """
  use Ros2Zenoh.Common

  alias Ros2Zenoh.SensorMsgs.Msg.PointField
  alias Ros2Zenoh.StdMsgs.Msg.Header

  @point_step 12

  defstruct header: nil,
            height: 1,
            width: 0,
            fields: nil,
            is_bigendian: 0,
            point_step: @point_step,
            row_step: 0,
            data: <<>>,
            is_dense: 0

  def msg_definition do
    """
    # This message holds a collection of N-dimensional points, which may
    # contain additional information such as normals, intensity, etc. The
    # point data is stored as a binary blob, its layout described by the
    # contents of the "fields" array.
    #
    # The point cloud data may be organized 2d (image-like) or 1d (unordered).
    # Point clouds organized as 2d images may be produced by camera depth sensors
    # such as stereo or time-of-flight.

    # Time of sensor data acquisition, and the coordinate frame ID (for 3d points).
    std_msgs/Header header

    # 2D structure of the point cloud. If the cloud is unordered, height is
    # 1 and width is the length of the point cloud.
    uint32 height
    uint32 width

    # Describes the channels and their layout in the binary data blob.
    PointField[] fields

    bool    is_bigendian # Is this data bigendian?
    uint32  point_step   # Length of a point in bytes
    uint32  row_step     # Length of a row in bytes
    uint8[] data         # Actual point data, size is (row_step*height)

    bool is_dense        # True if there are no invalid points
    """
  end

  def dependencies, do: [Header, PointField]

  def dds_type, do: "sensor_msgs::msg::dds_::PointCloud2_"

  def type_hash,
    do: "RIHS01_9198cabf7da3796ae6fe19c4cb3bdd3525492988c70522628af5daa124bae2b5"

  def point_step, do: @point_step

  @doc "The xyz-float32 field layout every consumer expects."
  def xyz_fields do
    [
      %PointField{name: "x", offset: 0, datatype: PointField.float32(), count: 1},
      %PointField{name: "y", offset: 4, datatype: PointField.float32(), count: 1},
      %PointField{name: "z", offset: 8, datatype: PointField.float32(), count: 1}
    ]
  end

  def encode(%__MODULE__{} = cloud) do
    fields = cloud.fields || xyz_fields()

    buffer =
      Header.encode(cloud.header) <>
        encode_uint32(cloud.height) <>
        encode_uint32(cloud.width) <>
        encode_uint32(length(fields))

    buffer = Enum.reduce(fields, buffer, &PointField.append_to(&2, &1))

    # is_bigendian is a uint8; point_step is a uint32, so realign.
    (buffer <> encode_uint8(cloud.is_bigendian))
    |> align_to(4)
    |> Kernel.<>(encode_uint32(cloud.point_step))
    |> Kernel.<>(encode_uint32(cloud.row_step))
    |> Kernel.<>(encode_uint32(byte_size(cloud.data)))
    |> Kernel.<>(cloud.data)
    # `data` is a uint8 sequence and `is_dense` a uint8, so no
    # alignment is needed between them.
    |> Kernel.<>(encode_uint8(cloud.is_dense))
  end
end
