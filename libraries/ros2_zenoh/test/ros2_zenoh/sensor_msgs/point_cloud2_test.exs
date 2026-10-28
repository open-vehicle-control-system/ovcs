defmodule Ros2Zenoh.SensorMsgs.Msg.PointCloud2Test do
  @moduledoc """
  Byte layout of a two-point cloud built by `cloud/1`. Each PointField
  is 20 bytes, not 16: name 4 + 2, pad 2, offset u32, datatype u8,
  pad 3, count u32.

  ```text
    0  Time                                    ->   8
    8  "stereo_left"  4 + 12 + 0 pad           ->  24
   24  height, width, field count              ->  36
   36  three fields x 20                       ->  96
   96  is_bigendian u8                         ->  97
   97  pad to 4                                -> 100
  100  point_step, row_step, data length       -> 112
  112  data: 2 points x 12                     -> 136
  136  is_dense u8                             -> 137
  ```
  """
  use ExUnit.Case, async: true

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias Ros2Zenoh.SensorMsgs.Msg.{PointCloud2, PointField}
  alias Ros2Zenoh.StdMsgs.Msg.Header

  defp cloud(point_count) do
    %PointCloud2{
      header: %Header{stamp: %Time{sec: 1, nanosec: 2}, frame_id: "stereo_left"},
      height: 1,
      width: point_count,
      fields: PointCloud2.xyz_fields(),
      is_bigendian: 0,
      point_step: PointCloud2.point_step(),
      row_step: point_count * PointCloud2.point_step(),
      data:
        for(
          i <- 1..max(point_count, 1),
          into: <<>>,
          do: <<i * 1.0::little-float-32, i * 2.0::little-float-32, i * 3.0::little-float-32>>
        ),
      is_dense: 1
    }
  end

  test "every uint32 lands on a 4-byte boundary from the body origin" do
    body = PointCloud2.encode(cloud(2))

    assert byte_size(body) == 137

    <<_::binary-size(100), point_step::little-unsigned-32, row_step::little-unsigned-32,
      data_length::little-unsigned-32, _::binary>> = body

    assert point_step == 12
    assert row_step == 24
    assert data_length == 24
  end

  test "field descriptors decode at the offsets a consumer expects" do
    body = PointCloud2.encode(cloud(1))

    # First PointField starts at 36: "x" is 4 + 2 = 6 bytes, padded to
    # 8 before the uint32 offset.
    <<_::binary-size(36), name_length::little-unsigned-32, "x", 0, _padding::binary-size(2),
      offset::little-unsigned-32, datatype::little-unsigned-8, _::binary>> = body

    assert name_length == 2
    assert offset == 0
    assert datatype == PointField.float32()
  end

  test "an empty cloud still encodes a well-formed header" do
    body = PointCloud2.encode(%{cloud(0) | width: 0, row_step: 0, data: <<>>})

    assert <<_::binary-size(100), 12::little-unsigned-32, 0::little-unsigned-32,
             0::little-unsigned-32, 1::little-unsigned-8>> = body

    assert byte_size(body) == 113
  end
end
